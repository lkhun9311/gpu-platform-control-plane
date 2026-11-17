package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestRunVersionCalibrationWritesTheArtifactVersionBundleReads: a resolved ladder's artifact is what version-bundle freezes λ0 from.
func TestRunVersionCalibrationWritesTheArtifactVersionBundleReads(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	rule := st.Version.Calibration
	dir := t.TempDir()
	// A fake engine whose capacity is 2 req/s: every rung at or below it is stable.
	// Each rung is reported to the runner as RungRunner.Probe does, so the rung evidence a real run writes is written here
	// too.
	runner := &bench.RungRunner{}
	probe := func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		rows, o, cls := fakeRung(t, *st.Version, rate, ordinal, 2)
		runner.OnRung(ordinal, rows, o, cls, nil)
		return cls
	}
	res, err := runVersionCalibration(context.Background(), dir, rule, runner, probe, testIdentity)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Resolved || res.Rate > 2 || res.Rate < 2/rule.TargetRatio {
		t.Fatalf("result %+v, want λ0 just under 2", res)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err != nil {
		t.Fatalf("version-bundle could not freeze the calibration it was given: %v", err)
	}
	if _, err := runVersionCalibration(context.Background(), dir, rule, &bench.RungRunner{}, probe, testIdentity); err == nil || !strings.Contains(err.Error(), "already holds calibration evidence") {
		t.Fatalf("second calibration: %v, want a refusal because the campaign was calibrated", err)
	}
}

// TestRunVersionCalibrationRecordsAnUnresolvedStop: "calibration unresolved, stop" is a registered outcome, so it is written, and version-bundle refuses it.
func TestRunVersionCalibrationRecordsAnUnresolvedStop(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	dir := t.TempDir()
	res, err := runVersionCalibration(context.Background(), dir, st.Version.Calibration, &bench.RungRunner{}, func(context.Context, float64, int) bench.RungClass { return bench.RungInvalid }, testIdentity)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, calibrationArtifactFile))
	if err != nil {
		t.Fatal(err)
	}
	var art bench.CalibrationArtifact
	if err := json.Unmarshal(data, &art); err != nil || art.Resolved || art.Reason == "" || art.Reason != res.Reason {
		t.Fatalf("artifact %+v err %v, want an unresolved record with its reason", art, err)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err == nil || !strings.Contains(err.Error(), "unresolved") {
		t.Fatalf("version-bundle on an unresolved calibration: %v", err)
	}
}

// TestRunVersionCalibrationKeepsEachRungsEvidence runs real rungs against an engine that never drains, so each is invalid and recorded.
func TestRunVersionCalibrationKeepsEachRungsEvidence(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	d := *st.Version
	d.Calibration.DrainSeconds = 1
	dir := t.TempDir()
	busy := func(context.Context) (int, int, error) { return 1, 0, nil }
	runner := &bench.RungRunner{Design: d, Queue: busy, PollEvery: 100 * time.Millisecond}
	res, err := runVersionCalibration(context.Background(), dir, d.Calibration, runner, func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
		return runner.Probe(ctx, rate, ordinal)
	}, testIdentity)
	if err != nil {
		t.Fatal(err)
	}
	if res.Resolved || len(res.Rungs) != d.Calibration.MaxInvalidRetries+1 {
		t.Fatalf("result %+v, want an unresolved stop after %d invalid rungs", res, d.Calibration.MaxInvalidRetries+1)
	}
	for i := 1; i <= len(res.Rungs); i++ {
		data, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("calibration-rung-%d.json", i)))
		if err != nil {
			t.Fatal(err)
		}
		var rec bench.CalibrationRungRecord
		if err := json.Unmarshal(data, &rec); err != nil || rec.Class != bench.RungInvalid || !strings.Contains(rec.Error, "drain") {
			t.Fatalf("rung %d record %+v err %v", i, rec, err)
		}
	}
}

// TestRunVersionCalibrationSendsNothingItCannotRecord: on a paid engine a rung whose evidence cannot be kept is money spent for nothing.
func TestRunVersionCalibrationSendsNothingItCannotRecord(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	rule := st.Version.Calibration
	probes := 0
	counting := func(_ context.Context, rate float64, ordinal int) bench.RungClass { probes++; return bench.RungStable }
	if _, err := runVersionCalibration(context.Background(), filepath.Join(t.TempDir(), "missing"), rule, &bench.RungRunner{}, counting, testIdentity); err == nil || probes != 0 {
		t.Fatalf("missing directory: err %v after %d probes, want a refusal before any", err, probes)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "calibration-rung-2.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	probes = 0
	if _, err := runVersionCalibration(context.Background(), dir, rule, &bench.RungRunner{}, counting, testIdentity); err == nil || probes != 0 {
		t.Fatalf("leftover rung file: err %v after %d probes, want a refusal before any", err, probes)
	}
	// A write that fails mid-ladder stops every later probe.
	dir = t.TempDir()
	runner := &bench.RungRunner{}
	probes = 0
	_, err := runVersionCalibration(context.Background(), dir, rule, runner, func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		probes++
		if ordinal == 2 {
			_ = os.WriteFile(filepath.Join(dir, "calibration-rung-2.json"), []byte("{}"), 0o600)
		}
		runner.OnRung(ordinal, nil, bench.RungObservation{OfferedRate: rate}, bench.RungStable, nil)
		return bench.RungStable
	}, testIdentity)
	if err == nil || probes != 2 {
		t.Fatalf("write failure at rung 2: err %v after %d probes, want an error and no probe after rung 2", err, probes)
	}
}

// TestCalibrationReservationAdmitsOneOfTwoConcurrentRuns: two calibrations of one campaign would load the engine together and corrupt both.
func TestCalibrationReservationAdmitsOneOfTwoConcurrentRuns(t *testing.T) {
	for range 20 {
		dir := t.TempDir()
		results := make(chan error, 2)
		for range 2 {
			go func() { results <- reserveCalibration(dir) }()
		}
		ok := 0
		for range 2 {
			if <-results == nil {
				ok++
			}
		}
		if ok != 1 {
			t.Fatalf("%d of two concurrent calibrations reserved the campaign, want exactly 1", ok)
		}
	}
}

// identityEngine serves treatment t's captured /server_info and /version, which the paid readiness preflight of 2026-11-16 saved (internal/bench/testdata/vllm-runtime).
// edit, if set, changes the /server_info body first; devMode false answers /server_info with 404, as an engine started without VLLM_SERVER_DEV_MODE does.
func identityEngine(t *testing.T, treatment string, devMode bool, edit func([]byte) []byte) *httptest.Server {
	t.Helper()
	dir := filepath.Join("..", "..", "internal", "bench", "testdata", "vllm-runtime")
	si, err := os.ReadFile(filepath.Join(dir, treatment+".server-info.json"))
	if err != nil {
		t.Fatal(err)
	}
	v, err := os.ReadFile(filepath.Join(dir, treatment+".version.json"))
	if err != nil {
		t.Fatal(err)
	}
	if edit != nil {
		si = edit(si)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/server_info" && devMode:
			_, _ = w.Write(si)
		case r.URL.Path == "/version":
			_, _ = w.Write(v)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestCalibrateTreatmentARefusesAnEngineThatIsNotA is #645: B's or C's capacity must never be frozen as A's λ0.
//
// A refused engine gets no rung and leaves the directory empty, so the campaign can still be calibrated against the right engine.
func TestCalibrateTreatmentARefusesAnEngineThatIsNotA(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	otherRevision := func(si []byte) []byte {
		const pinned = `"revision":"aa8e72537993ba99e69dfaafa59ed015b17504d1"`
		if strings.Count(string(si), pinned) != 1 {
			t.Fatalf("the capture does not pin the model revision exactly once")
		}
		return []byte(strings.Replace(string(si), pinned, `"revision":"`+strings.Repeat("e", 40)+`"`, 1))
	}
	for name, c := range map[string]struct {
		srv  *httptest.Server
		want string
	}{
		"B, another release":        {identityEngine(t, bench.TreatmentB, true, nil), "vllmVersion"},
		"C, another release, async": {identityEngine(t, bench.TreatmentC, true, nil), "vllmVersion"},
		"A at another revision":     {identityEngine(t, bench.TreatmentA, true, otherRevision), "revision"},
		"A without dev mode":        {identityEngine(t, bench.TreatmentA, false, nil), "VLLM_SERVER_DEV_MODE"},
	} {
		dir := t.TempDir()
		probes := 0
		counting := func(context.Context, float64, int) bench.RungClass { probes++; return bench.RungStable }
		_, err := calibrateTreatmentA(context.Background(), dir, *st.Version, c.srv.Client(), c.srv.URL, &bench.RungRunner{}, counting)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want a refusal naming %s", name, err, c.want)
		}
		if probes != 0 {
			t.Errorf("%s: %d rungs ran on a refused engine", name, probes)
		}
		if left, _ := os.ReadDir(dir); len(left) != 0 {
			t.Errorf("%s: a refused engine left %d files", name, len(left))
		}
	}
}

// TestCalibrateTreatmentAKeepsWhatItChecked: A's engine is calibrated, and the record of its identity says what the responses did not prove.
func TestCalibrateTreatmentAKeepsWhatItChecked(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	srv := identityEngine(t, bench.TreatmentA, true, nil)
	dir := t.TempDir()
	runner := &bench.RungRunner{}
	probe := func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		cls := bench.RungStable
		if rate > 2 {
			cls = bench.RungUnstable
		}
		runner.OnRung(ordinal, nil, bench.RungObservation{OfferedRate: rate}, cls, nil)
		return cls
	}
	res, err := calibrateTreatmentA(context.Background(), dir, *st.Version, srv.Client(), srv.URL, runner, probe)
	if err != nil || !res.Resolved {
		t.Fatalf("A's own engine: %+v, %v", res, err)
	}
	data, err := os.ReadFile(filepath.Join(dir, bench.CalibrationIdentityFile))
	if err != nil {
		t.Fatal(err)
	}
	var rec calibrationIdentity
	if err := json.Unmarshal(data, &rec); err != nil {
		t.Fatal(err)
	}
	if rec.Treatment != bench.TreatmentA || len(rec.Unproven) == 0 || len(rec.ServerInfo) == 0 || len(rec.Version) == 0 {
		t.Fatalf("identity record %+v, want A's responses and what they leave unproven", rec)
	}
	served, _ := os.ReadFile(filepath.Join("..", "..", "internal", "bench", "testdata", "vllm-runtime", "A.server-info.json"))
	if !bytes.Equal(rec.ServerInfo, served) {
		t.Fatal("the record does not keep the engine's /server_info byte for byte")
	}
	again, err := bench.ParseVLLMRuntime(rec.ServerInfo, rec.Version)
	if err != nil || again.Settings.Diff(rec.Runtime.Settings) != "" || again.InstanceID != rec.Runtime.InstanceID {
		t.Fatalf("the kept responses do not read back as the recorded identity: %v", err)
	}
}

// testIdentity stands in for the identity record in tests of the ladder's own recording, which calibrateTreatmentA's tests cover.
var testIdentity = []byte("{}\n")

// TestRunVersionCalibrationRefusesAnUnidentifiedEngine: the ladder cannot be reached without an identity record to keep beside its rungs.
func TestRunVersionCalibrationRefusesAnUnidentifiedEngine(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	dir := t.TempDir()
	probes := 0
	counting := func(context.Context, float64, int) bench.RungClass { probes++; return bench.RungStable }
	if _, err := runVersionCalibration(context.Background(), dir, st.Version.Calibration, &bench.RungRunner{}, counting, nil); err == nil || probes != 0 {
		t.Fatalf("no identity: err %v after %d probes, want a refusal before any", err, probes)
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatalf("a refused calibration left %d files", len(left))
	}
}

// TestVersionCalibrateChecksTheEngineItIsGiven: the command, not only its helper, refuses C's engine before reserving the campaign.
func TestVersionCalibrateChecksTheEngineItIsGiven(t *testing.T) {
	srv := identityEngine(t, bench.TreatmentC, true, nil)
	dir := t.TempDir()
	var out bytes.Buffer
	err := versionCalibrate([]string{"-dir", dir, "-engine-url", srv.URL, "-metrics-url", srv.URL + "/metrics", "-model", "Qwen/Qwen2.5-3B-Instruct"}, &out)
	if err == nil || !strings.Contains(err.Error(), "not treatment A") {
		t.Fatalf("version-calibrate against C: %v", err)
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatalf("a refused engine left %d files", len(left))
	}
}

// TestCalibrateTreatmentAStopsWhenTheEngineChanges: the engine is read again after every rung, so a replaced engine never decides λ0.
//
// The replacement is A restarted (another instance id) or B behind the same URL; either ends the ladder unresolved.
func TestCalibrateTreatmentAStopsWhenTheEngineChanges(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	dir := filepath.Join("..", "..", "internal", "bench", "testdata", "vllm-runtime")
	read := func(name string) []byte {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	aInfo, aVersion := read("A.server-info.json"), read("A.version.json")
	restarted := []byte(strings.Replace(string(aInfo), `"instance_id":"1794830358496174231"`, `"instance_id":"1794830358496174232"`, 1))
	if bytes.Equal(restarted, aInfo) {
		t.Fatal("the capture does not carry the instance id this test replaces")
	}
	for name, c := range map[string]struct {
		info, version []byte
		want          string
	}{
		"A restarted":      {restarted, aVersion, "instance"},
		"B behind the URL": {read("B.server-info.json"), read("B.version.json"), "vllmVersion"},
	} {
		var reads atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// The first read is the check before the ladder and the second the one after rung 1; the engine changes after that.
			switch {
			case r.URL.Path == "/server_info" && reads.Add(1) <= 2:
				_, _ = w.Write(aInfo)
			case r.URL.Path == "/server_info":
				_, _ = w.Write(c.info)
			case r.URL.Path == "/version" && reads.Load() <= 2:
				_, _ = w.Write(aVersion)
			case r.URL.Path == "/version":
				_, _ = w.Write(c.version)
			default:
				http.NotFound(w, r)
			}
		}))
		runner := &bench.RungRunner{}
		probes := 0
		probe := func(_ context.Context, rate float64, ordinal int) bench.RungClass {
			probes++
			runner.OnRung(ordinal, nil, bench.RungObservation{OfferedRate: rate}, bench.RungStable, nil)
			return bench.RungStable
		}
		res, err := calibrateTreatmentA(context.Background(), t.TempDir(), *st.Version, srv.Client(), srv.URL, runner, probe)
		srv.Close()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if res.Resolved || !strings.Contains(res.Reason, c.want) || probes != 2 {
			t.Errorf("%s: resolved %v after %d probes, reason %q; want an unresolved stop naming %s after rung 2", name, res.Resolved, probes, res.Reason, c.want)
		}
	}
}

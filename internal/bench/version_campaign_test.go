package bench

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fixtureStableRate is λ0 in the campaign fixtures; at 0.6 λ0 six blocks offer 6 x 1.2 x 300 = 2,160 measured requests.
var fixtureStableRate = fixtureLadderRate()

// fixtureLadderRate is the λ0 the registered ladder resolves against an engine stable up to 2 req/s.
func fixtureLadderRate() float64 {
	return versionAsyncDesign().Calibration.Run(func(rate float64, _ int) RungClass {
		if rate > 2.0 {
			return RungUnstable
		}
		return RungStable
	}).Rate
}

// fixtureTrace writes the registered generator's trace for a block and load at the fixture's λ0, and returns its sha256 and measured rows.
//
// The bundle check regenerates every trace, so a fixture that wrote anything else would be refused before the check under test ran.
func fixtureTrace(t *testing.T, path string, block int, load string, windowSeconds int) (string, int) {
	t.Helper()
	d := versionAsyncDesign()
	seed, err := WorkloadSeed(d.CampaignSeed, block, load)
	if err != nil {
		t.Fatal(err)
	}
	rate, err := OfferedRate(load, fixtureStableRate)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := d.VersionTrace(seed, rate, windowSeconds)
	if err != nil {
		t.Fatal(err)
	}
	data := traceBytes(t, rows)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return Checksum(data), d.MeasuredRows(rows, windowSeconds)
}

// writeBundle writes a complete campaign bundle with its calibration artifact and traces into a new directory.
func writeBundle(t *testing.T, mutate func(b *CampaignBundle, dir string)) (string, *CampaignBundle) {
	t.Helper()
	dir := t.TempDir()
	d := frozenVersionDesignFixture()
	ladderEvidence(t, dir, 2.0)
	art, err := os.ReadFile(filepath.Join(dir, CalibrationArtifactFile))
	if err != nil {
		t.Fatal(err)
	}
	b := &CampaignBundle{
		Study: studyVersionFixture, CampaignID: "s1-20261120",
		Model: d.Model, ModelRevision: d.ModelRevision, TokenizerRevision: d.TokenizerRevision,
		ChatTemplateSHA256:       d.ChatTemplateSHA256,
		StableRateRequestsPerSec: fixtureStableRate,
		CalibrationArtifact:      "calibration.json", CalibrationArtifactSHA256: Checksum(art),
		WindowSeconds:   300,
		PriceUSDPerHour: 1.237, PriceSource: "aws-pricing-api", PriceReadAt: "2026-11-20T01:00:00Z",
		OtherChargesUSDPerHour: 0.1,
		Images: map[string]string{
			TreatmentA: d.Engines[TreatmentA].Image, TreatmentB: d.Engines[TreatmentB].Image, TreatmentC: d.Engines[TreatmentC].Image,
		},
	}
	for block := 1; block <= d.PlannedBlocks+d.MaxReplacementBlocks; block++ {
		for _, load := range []string{LoadL060, LoadL090} {
			name := fmt.Sprintf("trace-%d-%s.jsonl", block, load)
			sum, measured := fixtureTrace(t, filepath.Join(dir, name), block, load, b.WindowSeconds)
			seed, _ := WorkloadSeed(d.CampaignSeed, block, load)
			b.Traces = append(b.Traces, BundleTrace{Block: block, Load: load, Path: name, SHA256: sum, Seed: seed, MeasuredRows: measured})
		}
	}
	if mutate != nil {
		mutate(b, dir)
	}
	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "bundle.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path, b
}

// TestLoadCampaignBundleAccepts checks the valid bundle loads, so every refusal below is its mutation's.
func TestLoadCampaignBundleAccepts(t *testing.T) {
	registerFrozenVersionStudy(t)
	path, _ := writeBundle(t, nil)
	b, sum, err := LoadCampaignBundle(path)
	if err != nil {
		t.Fatalf("a valid bundle was refused: %v", err)
	}
	data, _ := os.ReadFile(path)
	if sum != Checksum(data) || b.WindowSeconds != 300 {
		t.Errorf("sum %s window %d", sum, b.WindowSeconds)
	}
}

// TestLoadCampaignBundleRefusals is attack items 8 and 10: the bundle pins contents, not declarations.
func TestLoadCampaignBundleRefusals(t *testing.T) {
	registerFrozenVersionStudy(t)
	rewrite := func(dir, name, from, to string) {
		p := filepath.Join(dir, name)
		data, _ := os.ReadFile(p)
		_ = os.WriteFile(p, []byte(strings.Replace(string(data), from, to, 1)), 0o600)
	}
	for name, c := range map[string]struct {
		mutate func(b *CampaignBundle, dir string)
		want   string
	}{
		"calibration contents edited": {func(_ *CampaignBundle, dir string) {
			rewrite(dir, "calibration.json", `"resolved":true`, `"resolved":false`)
		}, "calibration"},
		// The edit keeps the artifact valid, so only the hash can catch it.
		"calibration bytes edited but still valid": {func(_ *CampaignBundle, dir string) {
			rewrite(dir, "calibration.json", `"resolved":true`, `"resolved": true`)
		}, "hashes"},
		"calibration rate differs": {func(b *CampaignBundle, dir string) {
			art, _ := json.Marshal(CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.5})
			_ = os.WriteFile(filepath.Join(dir, "calibration.json"), art, 0o600)
			b.CalibrationArtifactSHA256 = Checksum(art)
		}, "λ0"},
		"calibration unresolved": {func(b *CampaignBundle, dir string) {
			art, _ := json.Marshal(CalibrationArtifact{Resolved: false, StableRateRequestsPerSec: fixtureStableRate})
			_ = os.WriteFile(filepath.Join(dir, "calibration.json"), art, 0o600)
			b.CalibrationArtifactSHA256 = Checksum(art)
		}, "unresolved"},
		"trace contents edited": {func(_ *CampaignBundle, dir string) {
			rewrite(dir, "trace-2-l090.jsonl", `"index":5,`, `"index":5 ,`)
		}, "trace"},
		"trace seed not the block's":   {func(b *CampaignBundle, _ string) { b.Traces[3].Seed++ }, "seed"},
		"a replacement trace missing":  {func(b *CampaignBundle, _ string) { b.Traces = b.Traces[:len(b.Traces)-1] }, "trace"},
		"declared measured rows wrong": {func(b *CampaignBundle, _ string) { b.Traces[0].MeasuredRows++ }, "measured"},
		// The registration caps the window at 300 s, so a longer one cannot be generated.
		// A bundle can still declare one, and that declaration must be refused.
		"a window the registration cannot pick": {func(b *CampaignBundle, _ string) { b.WindowSeconds = 360 }, "window"},
		"warm-up lacks a length class": {func(b *CampaignBundle, dir string) {
			p := filepath.Join(dir, b.Traces[0].Path)
			data, _ := os.ReadFile(p)
			rows, _ := ReadTrace(bytes.NewReader(data))
			for i := range rows {
				if rows[i].OffsetMs < 60000 && rows[i].PromptLenChars == 10532 {
					rows[i].PromptLenChars = 5183
				}
			}
			var buf bytes.Buffer
			_ = WriteTrace(&buf, rows)
			_ = os.WriteFile(p, buf.Bytes(), 0o600)
			b.Traces[0].SHA256 = Checksum(buf.Bytes())
		}, "warm-up"},
		"an unregistered prompt length": {func(b *CampaignBundle, dir string) {
			p := filepath.Join(dir, b.Traces[1].Path)
			data, _ := os.ReadFile(p)
			edited := strings.Replace(string(data), `"promptLenChars":1174`, `"promptLenChars":1175`, 1)
			_ = os.WriteFile(p, []byte(edited), 0o600)
			b.Traces[1].SHA256 = Checksum([]byte(edited))
		}, "length"},
		"another tokenizer":      {func(b *CampaignBundle, _ string) { b.TokenizerRevision = strings.Repeat("e", 40) }, "tokenizer"},
		"another chat template":  {func(b *CampaignBundle, _ string) { b.ChatTemplateSHA256 = strings.Repeat("e", 64) }, "template"},
		"another model revision": {func(b *CampaignBundle, _ string) { b.ModelRevision = strings.Repeat("e", 40) }, "modelRevision"},
		"no price":               {func(b *CampaignBundle, _ string) { b.PriceUSDPerHour = 0 }, "price"},
		"no price source":        {func(b *CampaignBundle, _ string) { b.PriceSource = "" }, "price"},
		"unparsable price time":  {func(b *CampaignBundle, _ string) { b.PriceReadAt = "yesterday" }, "price"},
		"image not registered": {func(b *CampaignBundle, _ string) {
			b.Images[TreatmentB] = "vllm/vllm-openai@sha256:" + strings.Repeat("d", 64)
		}, "image"},
	} {
		t.Run(name, func(t *testing.T) {
			path, _ := writeBundle(t, c.mutate)
			_, _, err := LoadCampaignBundle(path)
			if err == nil {
				t.Fatal("accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("refusal %q does not mention %q", err, c.want)
			}
		})
	}
	// Unknown and null keys are refused here as in a manifest.
	for name, edit := range map[string][2]string{
		"unknown key": {`"windowSeconds": 300,`, `"windowSeconds": 300, "lambda": 2,`},
		"null value":  {`"priceSource": "aws-pricing-api",`, `"priceSource": null,`},
	} {
		t.Run(name, func(t *testing.T) {
			path, _ := writeBundle(t, nil)
			data, _ := os.ReadFile(path)
			cut := strings.Replace(string(data), edit[0], edit[1], 1)
			if cut == string(data) {
				t.Fatalf("no %q in bundle", edit[0])
			}
			_ = os.WriteFile(path, []byte(cut), 0o600)
			if _, _, err := LoadCampaignBundle(path); err == nil {
				t.Fatal("accepted")
			}
		})
	}
}

// TestLoadCampaignBundleRegeneratesEveryTrace: a trace is the registered generator's output, not whatever passes the row checks.
//
// Each forged trace is rehashed and recounted, and is first shown to pass checkTraceRows, so only regenerating it from its seed can refuse it.
func TestLoadCampaignBundleRegeneratesEveryTrace(t *testing.T) {
	registerFrozenVersionStudy(t)
	d := frozenVersionDesignFixture()
	// The 0.6 λ0 trace of block 2 is replaced, so a higher forged rate cannot shorten the window the bundle declares.
	const forged = 2
	for name, forge := range map[string]func(seed int64, rate float64, window int) []byte{
		"generated at the other load's rate": func(seed int64, _ float64, window int) []byte {
			rate, _ := OfferedRate(LoadL090, fixtureStableRate)
			return traceBytes(t, mustTrace(t)(d.VersionTrace(seed, rate, window)))
		},
		"generated with another input mixture": func(seed int64, rate float64, window int) []byte {
			other := d
			other.InputTokens = slices.Clone(d.InputTokens)
			slices.Reverse(other.InputTokens)
			for i := range other.InputTokens {
				other.InputTokens[i].Weight = d.InputTokens[i].Weight
			}
			return traceBytes(t, mustTrace(t)(other.VersionTrace(seed, rate, window)))
		},
		// ReadTrace ignores an unknown key, so the parsed rows match and only the bytes differ.
		"carrying a key the generator never writes": func(seed int64, rate float64, window int) []byte {
			data := traceBytes(t, mustTrace(t)(d.VersionTrace(seed, rate, window)))
			return []byte(strings.Replace(string(data), `{"index":3,`, `{"index":3,"lambda":9,`, 1))
		},
	} {
		t.Run(name, func(t *testing.T) {
			path, _ := writeBundle(t, func(b *CampaignBundle, dir string) {
				tr := &b.Traces[forged]
				if tr.Block != 2 || tr.Load != LoadL060 {
					t.Fatalf("trace %d is block %d at %s, the forgery expects block 2 at %s", forged, tr.Block, tr.Load, LoadL060)
				}
				rate, _ := OfferedRate(tr.Load, b.StableRateRequestsPerSec)
				data := forge(tr.Seed, rate, b.WindowSeconds)
				original, _ := os.ReadFile(filepath.Join(dir, tr.Path))
				if bytes.Equal(data, original) {
					t.Fatal("the forgery wrote the registered trace")
				}
				rows, err := ReadTrace(bytes.NewReader(data))
				if err != nil {
					t.Fatal(err)
				}
				tr.SHA256, tr.MeasuredRows = Checksum(data), d.MeasuredRows(rows, b.WindowSeconds)
				if err := d.checkTraceRows(*tr, rows, b.WindowSeconds); err != nil {
					t.Fatalf("the forgery already fails the row checks (%v), so it would not show the regeneration", err)
				}
				if err := os.WriteFile(filepath.Join(dir, tr.Path), data, 0o600); err != nil {
					t.Fatal(err)
				}
			})
			_, _, err := LoadCampaignBundle(path)
			if err == nil {
				t.Fatal("a trace the registered generator did not write was accepted")
			}
			if !strings.Contains(err.Error(), "generator") {
				t.Errorf("refusal %q does not say the trace is not the generator's", err)
			}
		})
	}
}

// mustTrace fails the test on a generator error, so a forgery is built from a trace that exists.
func mustTrace(t *testing.T) func([]TraceRow, error) []TraceRow {
	return func(rows []TraceRow, err error) []TraceRow {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return rows
	}
}

// traceBytes is what WriteTrace writes for rows.
func traceBytes(t *testing.T, rows []TraceRow) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := WriteTrace(&buf, rows); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

var t0 = time.Date(2026, 11, 20, 2, 0, 0, 0, time.UTC)

// plannedLedger is six valid blocks of 80 minutes, closed.
func plannedLedger() AttemptLedger {
	l := AttemptLedger{CampaignID: "s1-20261120", Closed: true}
	for b := 1; b <= 6; b++ {
		start := t0.Add(time.Duration(b-1) * 80 * time.Minute)
		l.Attempts = append(l.Attempts, BlockAttempt{Block: b, Status: AttemptValid, StartedAt: start, EndedAt: start.Add(78 * time.Minute)})
	}
	return l
}

func appendAttempt(l AttemptLedger, a BlockAttempt) AttemptLedger {
	last := l.Attempts[len(l.Attempts)-1].EndedAt
	if a.StartedAt.IsZero() {
		a.StartedAt = last.Add(2 * time.Minute)
		a.EndedAt = a.StartedAt.Add(78 * time.Minute)
	}
	l.Attempts = append(l.Attempts, a)
	return l
}

// TestAnalysisSet checks the analysed blocks follow mechanically from the ledger (attack item 9).
func TestAnalysisSet(t *testing.T) {
	d := frozenVersionDesignFixture()
	set, err := d.AnalysisSet(plannedLedger())
	if err != nil || !slices.Equal(set, []int{1, 2, 3, 4, 5, 6}) {
		t.Fatalf("set %v err %v", set, err)
	}

	l := plannedLedger()
	l.Attempts[2].Status, l.Attempts[2].Reason = AttemptInvalid, "dispatch lag p99 14 ms in B-l090"
	l = appendAttempt(l, BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 3})
	set, err = d.AnalysisSet(l)
	if err != nil || !slices.Equal(set, []int{1, 2, 4, 5, 6, 7}) {
		t.Fatalf("replaced block 3: set %v err %v", set, err)
	}
}

// TestAnalysisSetRefusals lists ledgers from which no analysis set may be drawn.
func TestAnalysisSetRefusals(t *testing.T) {
	d := frozenVersionDesignFixture()
	invalid3 := func() AttemptLedger {
		l := plannedLedger()
		l.Attempts[2].Status, l.Attempts[2].Reason = AttemptInvalid, "recorder write error"
		return l
	}
	for name, c := range map[string]struct {
		ledger func() AttemptLedger
		want   string
	}{
		"not archived": {func() AttemptLedger { l := plannedLedger(); l.Closed = false; return l }, "archive"},
		"invalid without a reason": {func() AttemptLedger {
			l := invalid3()
			l.Attempts[2].Reason = ""
			return l
		}, "reason"},
		"a valid block rerun": {func() AttemptLedger {
			return appendAttempt(plannedLedger(), BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 2})
		}, "never rerun"},
		"a replacement run before the last planned block": {func() AttemptLedger {
			l := invalid3()
			last := l.Attempts[5]
			l.Attempts = l.Attempts[:5]
			l = appendAttempt(l, BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 3})
			return appendAttempt(l, BlockAttempt{Block: last.Block, Status: AttemptValid})
		}, "every planned block"},
		"a block attempted twice": {func() AttemptLedger {
			return appendAttempt(invalid3(), BlockAttempt{Block: 3, Status: AttemptValid})
		}, "twice"},
		"replacement before the planned blocks ended": {func() AttemptLedger {
			l := invalid3()
			return appendAttempt(l, BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 3,
				StartedAt: l.Attempts[4].StartedAt, EndedAt: l.Attempts[4].EndedAt})
		}, "after"},
		"an extra valid block beyond the plan": {func() AttemptLedger {
			return appendAttempt(plannedLedger(), BlockAttempt{Block: 7, Status: AttemptValid})
		}, "replac"},
		"a gap in the planned order": {func() AttemptLedger {
			l := plannedLedger()
			l.Attempts = slices.Delete(l.Attempts, 3, 4)
			return l
		}, "order"},
		"an attempt after the campaign stopped": {func() AttemptLedger {
			l := plannedLedger()
			l.Attempts[3].Status, l.Attempts[3].Reason = AttemptStopped, "budget"
			return l
		}, "stopped"},
		"a replacement replacing nothing invalid": {func() AttemptLedger {
			return appendAttempt(invalid3(), BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 9})
		}, "replac"},
		"another campaign's attempt": {func() AttemptLedger {
			l := plannedLedger()
			l.CampaignID = ""
			return l
		}, "campaign"},
		// Block numbers fix the workload seed and both orders, so skipping one would be choosing a workload.
		"a replacement that skips the next block number": {func() AttemptLedger {
			return appendAttempt(invalid3(), BlockAttempt{Block: 8, Status: AttemptValid, Replaces: 3})
		}, "due"},
		"replacements out of order": {func() AttemptLedger {
			l := plannedLedger()
			l.Attempts[1].Status, l.Attempts[1].Reason = AttemptInvalid, "recorder write error"
			l.Attempts[2].Status, l.Attempts[2].Reason = AttemptInvalid, "recorder write error"
			l = appendAttempt(l, BlockAttempt{Block: 8, Status: AttemptValid, Replaces: 2})
			return appendAttempt(l, BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 3})
		}, "due"},
		"an attempt with no recorded times": {func() AttemptLedger {
			l := plannedLedger()
			for i := range l.Attempts {
				l.Attempts[i].StartedAt, l.Attempts[i].EndedAt = time.Time{}, time.Time{}
			}
			return l
		}, "time"},
		"an attempt that ends before it starts": {func() AttemptLedger {
			l := plannedLedger()
			l.Attempts[3].EndedAt = l.Attempts[3].StartedAt.Add(-time.Minute)
			return l
		}, "ends"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := d.AnalysisSet(c.ledger())
			if err == nil {
				t.Fatal("accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("refusal %q does not mention %q", err, c.want)
			}
		})
	}
}

// TestAnalysisSetIncomplete checks a stop or too many invalid blocks gives no verdict, but still names the valid blocks.
func TestAnalysisSetIncomplete(t *testing.T) {
	d := frozenVersionDesignFixture()
	l := plannedLedger()
	l.Attempts = l.Attempts[:5]
	l.Attempts[4].Status, l.Attempts[4].Reason = AttemptStopped, "budget: 3 valid blocks would not fit"
	set, err := d.AnalysisSet(l)
	if err == nil || !strings.Contains(err.Error(), "incomplete") || !slices.Equal(set, []int{1, 2, 3, 4}) {
		t.Fatalf("set %v err %v, want [1 2 3 4] and an incomplete error", set, err)
	}

	l = plannedLedger()
	for _, i := range []int{0, 1, 2} {
		l.Attempts[i].Status, l.Attempts[i].Reason = AttemptInvalid, "external: instance retirement"
	}
	l = appendAttempt(l, BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 1})
	l = appendAttempt(l, BlockAttempt{Block: 8, Status: AttemptValid, Replaces: 2})
	set, err = d.AnalysisSet(l)
	if err == nil || !strings.Contains(err.Error(), "incomplete") || len(set) != 5 {
		t.Fatalf("three invalid blocks and two replacements: set %v err %v", set, err)
	}
}

// campaignCells builds the cells of the ledger's valid blocks against a bundle.
func campaignCells(t *testing.T, b *CampaignBundle, bundleSHA string, blocks []int) []RunManifest {
	t.Helper()
	d := frozenVersionDesignFixture()
	var out []RunManifest
	for _, block := range blocks {
		for _, load := range []string{LoadL060, LoadL090} {
			var tr BundleTrace
			for _, x := range b.Traces {
				if x.Block == block && x.Load == load {
					tr = x
				}
			}
			rate, _ := OfferedRate(load, b.StableRateRequestsPerSec)
			for _, trt := range []string{TreatmentA, TreatmentB, TreatmentC} {
				out = append(out, RunManifest{
					SchemaVersion: ManifestSchemaV3, Study: studyVersionFixture, Arm: VersionStudyArm(trt, load),
					Model: d.Model, TokenizerRev: d.TokenizerRevision, Seed: tr.Seed, TraceChecksum: tr.SHA256,
					Engine: new(d.Engines[trt]),
					Cell: &CellIdentity{
						CampaignID: b.CampaignID, Block: block,
						Position:     slices.Index(ArmOrder(d.CampaignSeed, block), trt) + 1,
						LoadPosition: slices.Index(LoadOrder(block), load) + 1,
						OrderSeed:    d.CampaignSeed, StableRateRequestsPerSec: b.StableRateRequestsPerSec,
						BundleSHA256: bundleSHA, OfferedRequestsPerSec: rate,
					},
				})
			}
		}
	}
	return out
}

// TestCheckVersionCampaign pairs cells only through the bundle and the ledger.
func TestCheckVersionCampaign(t *testing.T) {
	registerFrozenVersionStudy(t)
	path, _ := writeBundle(t, nil)
	b, sum, err := LoadCampaignBundle(path)
	if err != nil {
		t.Fatal(err)
	}
	ledger := plannedLedger()
	set, err := CheckVersionCampaign(b, sum, ledger, campaignCells(t, b, sum, []int{1, 2, 3, 4, 5, 6}))
	if err != nil || !slices.Equal(set, []int{1, 2, 3, 4, 5, 6}) {
		t.Fatalf("set %v err %v", set, err)
	}

	for name, c := range map[string]struct {
		mutate func(cells []RunManifest) []RunManifest
		want   string
	}{
		"a cell replays a trace the bundle does not name": {func(cells []RunManifest) []RunManifest {
			cells[1].TraceChecksum = strings.Repeat("9", 64)
			return cells
		}, "trace"},
		"a cell from another bundle": {func(cells []RunManifest) []RunManifest {
			cells[2].Cell.BundleSHA256 = strings.Repeat("8", 64)
			return cells
		}, "bundle"},
		"a cell at another λ0": {func(cells []RunManifest) []RunManifest {
			cells[2].Cell.StableRateRequestsPerSec = 3
			return cells
		}, "λ0"},
		"a cell under another tokenizer": {func(cells []RunManifest) []RunManifest {
			cells[4].TokenizerRev = strings.Repeat("e", 40)
			return cells
		}, "tokenizer"},
		"a cell under another model": {func(cells []RunManifest) []RunManifest {
			cells[4].Model = "Qwen/Qwen2.5-7B-Instruct"
			return cells
		}, "model"},
		"a valid block missing a cell": {func(cells []RunManifest) []RunManifest { return slices.Delete(cells, 7, 8) }, "missing"},
		"a cell recorded twice":        {func(cells []RunManifest) []RunManifest { return append(cells, cells[3]) }, "twice"},
		"a cell of a block the ledger never attempted": {func(cells []RunManifest) []RunManifest {
			extra := slices.Clone(cells[:1])
			extra[0].Cell = new(*cells[0].Cell)
			extra[0].Cell.Block = 8
			return append(cells, extra...)
		}, "ledger"},
		"a cell of another campaign": {func(cells []RunManifest) []RunManifest {
			cells[5].Cell.CampaignID = "other"
			return cells
		}, "campaign"},
		"a cell of another study": {func(cells []RunManifest) []RunManifest {
			cells[5].Study = StudyHoldCapProductTransfer
			return cells
		}, "study"},
		"a cell without identity": {func(cells []RunManifest) []RunManifest { cells[5].Cell = nil; return cells }, "cell"},
	} {
		t.Run(name, func(t *testing.T) {
			cells := c.mutate(campaignCells(t, b, sum, []int{1, 2, 3, 4, 5, 6}))
			_, err := CheckVersionCampaign(b, sum, ledger, cells)
			if err == nil {
				t.Fatal("accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("refusal %q does not mention %q", err, c.want)
			}
		})
	}
}

// TestCheckVersionCampaignRecountsTheAnalysedPopulation: the window met the floor over the planned traces, and a smaller replacement can undo that.
func TestCheckVersionCampaignRecountsTheAnalysedPopulation(t *testing.T) {
	registerFrozenVersionStudy(t)
	path, _ := writeBundle(t, nil)
	b, sum, err := LoadCampaignBundle(path)
	if err != nil {
		t.Fatal(err)
	}
	d := frozenVersionDesignFixture()
	// 6 x 168 = 1008 meets a floor of 1000; with block 3 replaced by a 158-row trace the analysed blocks offer 998.
	for i := range b.Traces {
		b.Traces[i].MeasuredRows = 168
		if b.Traces[i].Block == 7 {
			b.Traces[i].MeasuredRows = 158
		}
	}
	if d.MinOfferedPopulation != 1000 {
		t.Fatalf("fixture assumes a floor of 1000, the design has %d", d.MinOfferedPopulation)
	}
	ledger := plannedLedger()
	if _, err := CheckVersionCampaign(b, sum, ledger, campaignCells(t, b, sum, []int{1, 2, 3, 4, 5, 6})); err != nil {
		t.Fatalf("planned blocks at 1008 rows per load: %v", err)
	}
	ledger.Attempts[2].Status, ledger.Attempts[2].Reason = AttemptInvalid, "dispatch lag"
	ledger = appendAttempt(ledger, BlockAttempt{Block: 7, Status: AttemptValid, Replaces: 3})
	_, err = CheckVersionCampaign(b, sum, ledger, campaignCells(t, b, sum, []int{1, 2, 4, 5, 6, 7}))
	if err == nil || !strings.Contains(err.Error(), "998") {
		t.Fatalf("err %v, want a refusal naming the 998 analysed requests", err)
	}

	// A stopped campaign is under the floor too, but its valid blocks must survive for the descriptive report.
	stopped := plannedLedger()
	stopped.Attempts = stopped.Attempts[:3]
	stopped.Attempts[2].Status, stopped.Attempts[2].Reason = AttemptStopped, "budget"
	set, err := CheckVersionCampaign(b, sum, stopped, campaignCells(t, b, sum, []int{1, 2}))
	if err == nil || !strings.Contains(err.Error(), "incomplete") || !strings.Contains(err.Error(), "floor") || !slices.Equal(set, []int{1, 2}) {
		t.Fatalf("set %v err %v, want [1 2] with an incomplete-pilot and a floor error", set, err)
	}
}

// TestCompareRuntime checks the running engine against the bundle and the registration.
func TestCompareRuntime(t *testing.T) {
	registerFrozenVersionStudy(t)
	path, _ := writeBundle(t, nil)
	b, _, err := LoadCampaignBundle(path)
	if err != nil {
		t.Fatal(err)
	}
	d := frozenVersionDesignFixture()
	good := func() RuntimeIdentity {
		return RuntimeIdentity{
			VLLMVersion: "v0.32.0", Image: b.Images[TreatmentC], ModelRevision: d.ModelRevision,
			TokenizerRevision: d.TokenizerRevision, ChatTemplateSHA256: d.ChatTemplateSHA256,
			ProfileArgs: d.ReviewedProfileArgs[TreatmentC], Settings: d.Engines[TreatmentC],
		}
	}
	if err := b.CompareRuntime(d, TreatmentC, good()); err != nil {
		t.Fatalf("matching runtime refused: %v", err)
	}
	for name, mutate := range map[string]func(r *RuntimeIdentity){
		"another version":    func(r *RuntimeIdentity) { r.VLLMVersion = "v0.31.0" },
		"another image":      func(r *RuntimeIdentity) { r.Image = b.Images[TreatmentA] },
		"another template":   func(r *RuntimeIdentity) { r.ChatTemplateSHA256 = strings.Repeat("e", 64) },
		"another revision":   func(r *RuntimeIdentity) { r.ModelRevision = strings.Repeat("e", 40) },
		"unreviewed args":    func(r *RuntimeIdentity) { r.ProfileArgs = append(slices.Clone(r.ProfileArgs), "--enforce-eager") },
		"async flag dropped": func(r *RuntimeIdentity) { r.ProfileArgs = r.ProfileArgs[:len(r.ProfileArgs)-1] },
		"no args observed":   func(r *RuntimeIdentity) { r.ProfileArgs = nil },
		"async off on C":     func(r *RuntimeIdentity) { r.Settings.AsyncScheduling = new(false) },
		"another batch size": func(r *RuntimeIdentity) { r.Settings.MaxNumBatchedTokens = 2048 },
	} {
		r := good()
		mutate(&r)
		if err := b.CompareRuntime(d, TreatmentC, r); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// TestClassifyRow is attack item 5: conformance is checked on every completed stream before success is decided.
func TestClassifyRow(t *testing.T) {
	p := *versionStudySampling()
	ok := RowFacts{Dispatched: true, HTTPStatus: 200, StreamCompleted: true, UsagePresent: true,
		PromptTokens: 256, ExpectedPromptTokens: 256, CompletionTokens: 64, CapTokens: 64, FinishReason: "length", ContentFrames: 40}
	for _, c := range []struct {
		name    string
		mutate  func(f *RowFacts)
		want    RowDisposition
		invalid bool
	}{
		{"success", func(*RowFacts) {}, DispositionSuccess, false},
		{"completed without usage", func(f *RowFacts) { f.UsagePresent, f.CompletionTokens = false, 0 }, "", true},
		// A recorder that filled the count from frames must still be refused: presence is checked apart from the count.
		{"no usage chunk but a count", func(f *RowFacts) { f.UsagePresent = false }, "", true},
		{"stopped at eos despite the policy", func(f *RowFacts) { f.FinishReason, f.CompletionTokens = "stop", 30 }, "", true},
		{"prompt tokenized differently", func(f *RowFacts) { f.PromptTokens = 257 }, "", true},
		{"HTTP 503", func(f *RowFacts) { f.HTTPStatus, f.StreamCompleted = 503, false }, DispositionHTTPError, false},
		{"stream broke", func(f *RowFacts) { f.StreamCompleted = false }, DispositionStreamError, false},
		{"timed out", func(f *RowFacts) { f.TimedOut, f.StreamCompleted = true, false }, DispositionTimeout, false},
		{"connection refused", func(f *RowFacts) { f.TransportError, f.HTTPStatus, f.StreamCompleted = true, 0, false }, DispositionTransportError, false},
		{"engine never ready", func(f *RowFacts) { *f = RowFacts{EngineUnavailable: true} }, DispositionEngineUnavailable, false},
		{"not dispatched for no recorded reason", func(f *RowFacts) { *f = RowFacts{} }, "", true},
	} {
		f := ok
		c.mutate(&f)
		got, err := ClassifyRow(p, f)
		if (err != nil) != c.invalid {
			t.Errorf("%s: err %v, want invalid=%v", c.name, err, c.invalid)
			continue
		}
		if !c.invalid && got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
	for _, dsp := range []RowDisposition{DispositionHTTPError, DispositionStreamError, DispositionTimeout, DispositionTransportError, DispositionEngineUnavailable} {
		if !dsp.IsFailure() {
			t.Errorf("%s is not counted as a failure", dsp)
		}
	}
	if DispositionSuccess.IsFailure() {
		t.Errorf("success counted as a failure")
	}
}

// TestGoodRequest checks the per-request SLO test, with a single-frame response never counted good.
func TestGoodRequest(t *testing.T) {
	slo := frozenVersionDesignFixture().SLO
	for _, c := range []struct {
		name         string
		dsp          RowDisposition
		ttft, tpot   float64
		frames, want int
	}{
		{"meets both", DispositionSuccess, 900, 50, 40, 1},
		{"TTFT over", DispositionSuccess, 1001, 50, 40, 0},
		{"TPOT over", DispositionSuccess, 900, 61, 40, 0},
		{"failed", DispositionStreamError, 100, 10, 40, 0},
		{"one content frame, TPOT undefined", DispositionSuccess, 900, 0, 1, 0},
	} {
		if got := GoodRequest(slo, c.dsp, c.ttft, c.tpot, c.frames); (got && c.want == 0) || (!got && c.want == 1) {
			t.Errorf("%s: good %v", c.name, got)
		}
	}
}

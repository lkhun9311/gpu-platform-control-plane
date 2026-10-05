package bench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// Long enough for every session-2 and session-3 trace; the longest, stagger at seed 11, spans 2,378,283 ms.
const ivS3DurationMs = 2400000

// ivTraceBytes generates one trace and returns its serialized bytes, the form a manifest checksums.
func ivTraceBytes(t *testing.T, study string, et EpisodeType, seed int64, warmup bool) ([]TraceRow, string) {
	t.Helper()
	p := EpisodeTraceParams{Study: study, Seed: seed, DurationMs: ivS3DurationMs, Type: et}
	var rows []TraceRow
	var err error
	if warmup {
		rows, err = GenerateEpisodeWarmupTrace(p)
	} else {
		rows, err = GenerateEpisodeTrace(p)
	}
	if err != nil {
		t.Fatalf("%s %s seed %d warmup=%v: %v", study, et, seed, warmup, err)
	}
	var b strings.Builder
	if err := WriteTrace(&b, rows); err != nil {
		t.Fatal(err)
	}
	return rows, b.String()
}

// Session 2's three cells were replayed from these bytes, so session 3's change must not move one of them.
// The hashes are the traceChecksum of the manifests in the session-2 archive hack/m5c-20261005-135632/m5c-run, generated at 0560304 with seed 11.
func TestSessionTwoTracesAreByteIdenticalToTheArchive(t *testing.T) {
	for _, c := range []struct {
		t      EpisodeType
		warmup bool
		sha    string
	}{
		{EpisodeSerial, false, "d7f823ad8b06c597456c570febfcfbd4c66293e2e6cf2b6262be83455dab4f69"},
		{EpisodeBurst, false, "b8e59ce4600d25d53d37c96cb008029942681a600818a2ae4ef8f02f86e45276"},
		{EpisodeStagger, false, "c6fa2a6d0e10344492082dce2016c8743f077c99f21f90ad256dbd4aa29b9aa9"},
		{EpisodeSerial, true, "428e28bf108cd2aee478a85c42e92033e2a12508fc82b329f7d762d69dfc4f7f"},
		{EpisodeBurst, true, "f70e99cc68333852d69132c16f94099260f8905c52f7ef0b36d7f58ec334c9c3"},
		{EpisodeStagger, true, "d48cda79dc5fc88a99a43a136bbe5aa63a1a49514d17c1a56613f76a04362d0e"},
	} {
		_, b := ivTraceBytes(t, StudyInstrumentValidationS2, c.t, 11, c.warmup)
		sum := sha256.Sum256([]byte(b))
		if got := hex.EncodeToString(sum[:]); got != c.sha {
			t.Errorf("session 2 %s trace (warmup=%v) at seed 11 hashes to %s, the archive's is %s", c.t, c.warmup, got, c.sha)
		}
		if strings.Contains(b, "minOutputTokens") {
			t.Errorf("session 2 %s trace (warmup=%v) carries minOutputTokens", c.t, c.warmup)
		}
	}
}

// Session 3 is session 2 with a minimum output on every stagger decoder, and nothing else: same rows, offsets, lengths and caps.
func TestSessionThreeIsSessionTwoPlusTheDecoderMinimum(t *testing.T) {
	for _, et := range EpisodeTypes {
		for _, seed := range []int64{11, 21} {
			for _, warmup := range []bool{false, true} {
				s2, _ := ivTraceBytes(t, StudyInstrumentValidationS2, et, seed, warmup)
				s3, _ := ivTraceBytes(t, StudyInstrumentValidationS3, et, seed, warmup)
				if len(s2) != len(s3) {
					t.Fatalf("%s seed %d warmup=%v: session 3 has %d rows and session 2 %d", et, seed, warmup, len(s3), len(s2))
				}
				decoders := 0
				for i := range s3 {
					wantMin := 0
					if et == EpisodeStagger && s3[i].MaxOutputTokens == 512 {
						wantMin = 512
						decoders++
					}
					if s3[i].MinOutputTokens != wantMin {
						t.Errorf("%s seed %d warmup=%v row %d (cap %d) has minOutputTokens %d, want %d",
							et, seed, warmup, i, s3[i].MaxOutputTokens, s3[i].MinOutputTokens, wantMin)
					}
					stripped := s3[i]
					stripped.MinOutputTokens = 0
					if !reflect.DeepEqual(stripped, s2[i]) {
						t.Errorf("%s seed %d warmup=%v row %d differs from session 2 beyond the minimum: %+v against %+v", et, seed, warmup, i, s3[i], s2[i])
					}
				}
				// The warm-up's one stagger cycle holds 84 decoders and the measured trace far more, so a zero here means the minimum reached no decoder.
				if et == EpisodeStagger && decoders < 84 {
					t.Errorf("%s seed %d warmup=%v: only %d stagger decoders carry the minimum", et, seed, warmup, decoders)
				}
			}
		}
	}
}

func TestSessionThreeRegistration(t *testing.T) {
	s3, ok := LookupStudy(StudyInstrumentValidationS3)
	if !ok {
		t.Fatalf("%s is not registered", StudyInstrumentValidationS3)
	}
	s2, _ := LookupStudy(StudyInstrumentValidationS2)
	if s3.ID != "instrument-validation-s3-2026-10-06" {
		t.Errorf("session 3's id is %q", s3.ID)
	}
	if !reflect.DeepEqual(s3.Arms, s2.Arms) || len(s3.Arms) != 9 {
		t.Errorf("session 3's arms %v are not session 2's nine %v", s3.Arms, s2.Arms)
	}
	if s3.Arrivals != ArrivalsEpisodes || s3.TracesVaryByRepetition {
		t.Errorf("session 3 arrivals %q, traces vary by repetition %v", s3.Arrivals, s3.TracesVaryByRepetition)
	}
	if !IsInstrumentValidationStudy(StudyInstrumentValidationS3) {
		t.Error("session 3 is not an instrument-validation study")
	}
	if _, err := GenerateEpisodeWarmupTrace(EpisodeTraceParams{Study: StudyInstrumentValidationS3, Seed: 11, DurationMs: ivS3DurationMs, Type: EpisodeBurst}); err != nil {
		t.Errorf("session 3 has no warm-up: %v", err)
	}
}

// The plan check refuses a stagger decoder without its minimum and any other row with one, in either direction between the sessions.
func TestSessionThreePlanRefusals(t *testing.T) {
	s3stagger, _ := ivTraceBytes(t, StudyInstrumentValidationS3, EpisodeStagger, 11, false)
	s2stagger, _ := ivTraceBytes(t, StudyInstrumentValidationS2, EpisodeStagger, 11, false)
	s3serial, _ := ivTraceBytes(t, StudyInstrumentValidationS3, EpisodeSerial, 11, false)
	for _, arm := range []string{"stagger-log", "stagger-nolog", "stagger-async"} {
		if err := InstrumentValidationPlanRefusal(StudyInstrumentValidationS3, arm, s3stagger); err != nil {
			t.Errorf("the session-3 stagger trace was refused for %s: %v", arm, err)
		}
	}
	if err := InstrumentValidationPlanRefusal(StudyInstrumentValidationS3, "serial-log", s3serial); err != nil {
		t.Errorf("the session-3 serial trace was refused: %v", err)
	}

	firstWith := func(rows []TraceRow, cap int) int {
		for i, r := range rows {
			if r.MaxOutputTokens == cap {
				return i
			}
		}
		t.Fatalf("no row with cap %d", cap)
		return -1
	}
	withChange := func(rows []TraceRow, i, minOut int) []TraceRow {
		out := append([]TraceRow(nil), rows...)
		out[i].MinOutputTokens = minOut
		return out
	}
	dec := firstWith(s3stagger, 512)
	pre := firstWith(s3stagger, staggerPrefillCap)
	for _, c := range []struct {
		name, study string
		t           EpisodeType
		rows        []TraceRow
		want        string
	}{
		{"one decoder without its minimum", StudyInstrumentValidationS3, EpisodeStagger, withChange(s3stagger, dec, 0),
			fmt.Sprintf("row %d is a stagger decoder with minOutputTokens 0 and study %s registers 512", dec, StudyInstrumentValidationS3)},
		{"one decoder with a different minimum", StudyInstrumentValidationS3, EpisodeStagger, withChange(s3stagger, dec, 511), "minOutputTokens 511"},
		{"a session-2 stagger trace under session 3", StudyInstrumentValidationS3, EpisodeStagger, s2stagger, "registers 512"},
		{"a prefill with a minimum", StudyInstrumentValidationS3, EpisodeStagger, withChange(s3stagger, pre, 16),
			fmt.Sprintf("row %d is not a stagger decoder and carries minOutputTokens 16", pre)},
		{"a serial row with a minimum", StudyInstrumentValidationS3, EpisodeSerial, withChange(s3serial, 0, 1), "is not a stagger decoder"},
		{"a session-3 stagger trace under session 2", StudyInstrumentValidationS2, EpisodeStagger, s3stagger,
			fmt.Sprintf("minOutputTokens 512 and study %s registers 0", StudyInstrumentValidationS2)},
	} {
		if err := EpisodeTraceRefusal(c.study, c.t, c.rows); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
}

// The field is omitted from a trace row without it, and survives a write and a read where it is set.
func TestMinOutputTokensRoundTripsAndIsOmittedWhenZero(t *testing.T) {
	var b strings.Builder
	if err := WriteTrace(&b, []TraceRow{{Index: 0, Tenant: PremiumTenant, PromptLenChars: 10, MaxOutputTokens: 512, MinOutputTokens: 512}, {Index: 1, Tenant: PremiumTenant, PromptLenChars: 10, MaxOutputTokens: 16}}); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(b.String()), "\n")
	if !strings.Contains(lines[0], `"minOutputTokens":512`) || strings.Contains(lines[1], "minOutputTokens") {
		t.Errorf("trace lines: %v", lines)
	}
	rows, err := ReadTrace(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	if rows[0].MinOutputTokens != 512 || rows[1].MinOutputTokens != 0 {
		t.Errorf("read back minOutputTokens %d and %d", rows[0].MinOutputTokens, rows[1].MinOutputTokens)
	}
}

// captureBodies is an engine stand-in that records every request body and answers with one token.
func captureBodies(t *testing.T) (*httptest.Server, func() [][]byte) {
	t.Helper()
	var mu sync.Mutex
	var bodies [][]byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, b)
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"tok\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n")
	}))
	t.Cleanup(srv.Close)
	return srv, func() [][]byte {
		mu.Lock()
		defer mu.Unlock()
		return bodies
	}
}

// A request from a row without a minimum is byte for byte the body every earlier study sent.
func TestARowWithoutAMinimumSendsTheOldBody(t *testing.T) {
	srv, bodies := captureBodies(t)
	sender := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 1, DrainForReuse: true})
	res := sender.Send(context.Background(), TraceRow{Tenant: PremiumTenant, PromptLenChars: 4, MaxOutputTokens: 16}, time.Now().UnixNano())
	if res.HTTPStatus != http.StatusOK {
		t.Fatalf("status %d, error %q", res.HTTPStatus, res.ErrorKind)
	}
	content, _ := json.Marshal(PromptText(4))
	want := `{"model":"m","messages":[{"role":"user","content":` + string(content) + `}],"max_tokens":16,"stream":true,"stream_options":{"include_usage":true}}`
	if got := string(bodies()[0]); got != want {
		t.Errorf("body\n got %s\nwant %s", got, want)
	}
}

// Replaying each session's traces, min_tokens reaches the engine on the stagger decoders of sessions 3 and 4 and on no other request.
// Session 4's conditioning request is a 2,048/16 row and so must not carry it either.
func TestReplaySendsMinTokensOnlyForSessionThreeDecoders(t *testing.T) {
	noSleep := func(context.Context, time.Time) {}
	for _, study := range []string{StudyInstrumentValidationS2, StudyInstrumentValidationS3, StudyInstrumentValidationS4} {
		withDecoderMin := study != StudyInstrumentValidationS2
		for _, et := range EpisodeTypes {
			for _, warmup := range []bool{false, true} {
				rows, _ := ivTraceBytes(t, study, et, 11, warmup)
				srv, bodies := captureBodies(t)
				sender := NewHTTPSender(srv.URL, "m", nil, 30*time.Second, SenderConn{MaxIdleConnsPerHost: 64, DrainForReuse: true})
				raw := Replay(context.Background(), sender, rows, ReplayOptions{Study: study, Arm: string(et) + "-log", sleepUntil: noSleep})
				for _, r := range raw {
					if r.HTTPStatus != http.StatusOK {
						t.Fatalf("%s %s warmup=%v row %d: status %d", study, et, warmup, r.Index, r.HTTPStatus)
					}
				}
				got := bodies()
				if len(got) != len(rows) {
					t.Fatalf("%s %s warmup=%v: %d bodies for %d rows", study, et, warmup, len(got), len(rows))
				}
				withMin := 0
				for _, b := range got {
					var body map[string]json.RawMessage
					if err := json.Unmarshal(b, &body); err != nil {
						t.Fatal(err)
					}
					decoder := withDecoderMin && et == EpisodeStagger && string(body["max_tokens"]) == "512"
					m, present := body["min_tokens"]
					switch {
					case decoder && (!present || string(m) != "512"):
						t.Errorf("%s %s warmup=%v: a decoder was sent min_tokens %s (present %v)", study, et, warmup, m, present)
					case !decoder && present:
						t.Errorf("%s %s warmup=%v: a request with max_tokens %s was sent min_tokens %s", study, et, warmup, body["max_tokens"], m)
					}
					if present {
						withMin++
					}
				}
				if withDecoderMin && et == EpisodeStagger && withMin == 0 {
					t.Errorf("%s %s warmup=%v: no request carried min_tokens", study, et, warmup)
				}
			}
		}
	}
}

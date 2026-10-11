package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"reflect"
	"testing"
)

// Session 3's seven cells were replayed from these bytes, so session 4's change must not move one of them, measured or warm-up.
// The hashes are the traceChecksum of the manifests and warm-up manifests in the session-3 archive hack/m5c-20261005-173703/m5c-run, seed 11.
func TestSessionThreeTracesAreByteIdenticalToTheArchive(t *testing.T) {
	for _, c := range []struct {
		t      EpisodeType
		warmup bool
		sha    string
	}{
		{EpisodeSerial, false, "d7f823ad8b06c597456c570febfcfbd4c66293e2e6cf2b6262be83455dab4f69"},
		{EpisodeBurst, false, "b8e59ce4600d25d53d37c96cb008029942681a600818a2ae4ef8f02f86e45276"},
		{EpisodeStagger, false, "150e62291d05061f5966f117c14151a071cec6b58acae9e6984db94dbde83801"},
		{EpisodeSerial, true, "428e28bf108cd2aee478a85c42e92033e2a12508fc82b329f7d762d69dfc4f7f"},
		{EpisodeBurst, true, "f70e99cc68333852d69132c16f94099260f8905c52f7ef0b36d7f58ec334c9c3"},
		{EpisodeStagger, true, "a40053502629065994940e70f857db721a9c5c33efd94e5a1094e71fc68055b5"},
	} {
		_, b := ivTraceBytes(t, StudyInstrumentValidationS3, c.t, 11, c.warmup)
		sum := sha256.Sum256([]byte(b))
		if got := hex.EncodeToString(sum[:]); got != c.sha {
			t.Errorf("session 3 %s trace (warmup=%v) at seed 11 hashes to %s, the archive's is %s", c.t, c.warmup, got, c.sha)
		}
	}
}

// Section 1 of the session-4 registration changes the warm-up alone, so every measured row is session 3's.
func TestSessionFourMeasuredTracesAreSessionThrees(t *testing.T) {
	for _, et := range EpisodeTypes {
		for _, seed := range []int64{11, 21} {
			s3, _ := ivTraceBytes(t, StudyInstrumentValidationS3, et, seed, false)
			s4, _ := ivTraceBytes(t, StudyInstrumentValidationS4, et, seed, false)
			if !reflect.DeepEqual(s3, s4) {
				t.Errorf("%s seed %d: session 4's measured trace (%d rows) is not session 3's (%d rows)", et, seed, len(s4), len(s3))
			}
		}
	}
}

// The session-4 warm-up is session 3's with one drained 2,048/16 request inserted between the cycle and the two verification requests.
// The rows up to the insertion are session 3's unchanged, so the unscored cycle keeps its order, jitter and decoder minimum.
func TestSessionFourWarmupAddsOneConditioningRequest(t *testing.T) {
	warmGap := homogeneous(1, warmupTokens, warmupCap).gapMs()
	for _, et := range EpisodeTypes {
		for _, seed := range []int64{11, 21} {
			s3, _ := ivTraceBytes(t, StudyInstrumentValidationS3, et, seed, true)
			s4, _ := ivTraceBytes(t, StudyInstrumentValidationS4, et, seed, true)
			n := len(s3)
			if len(s4) != n+1 {
				t.Fatalf("%s seed %d: session 4's warm-up has %d rows and session 3's %d, want one more", et, seed, len(s4), n)
			}
			if !reflect.DeepEqual(s4[:n-2], s3[:n-2]) {
				t.Errorf("%s seed %d: session 4's warm-up differs from session 3's before the verification requests", et, seed)
			}
			// The last three rows are the conditioning request and the two W reads, each a drained 2,048/16 request.
			for i := n - 2; i <= n; i++ {
				r := s4[i]
				if r.Index != i || r.MaxOutputTokens != warmupCap || r.MinOutputTokens != 0 || r.PromptLenChars != s3[n-1].PromptLenChars {
					t.Errorf("%s seed %d row %d is %+v, want a 2,048/16 request like session 3's last", et, seed, i, r)
				}
			}
			// The conditioning request takes the first verification request's slot, and the two after it keep the same drained spacing.
			if s4[n-2].OffsetMs != s3[n-2].OffsetMs {
				t.Errorf("%s seed %d: the conditioning request is at %d ms, session 3's first verification was at %d", et, seed, s4[n-2].OffsetMs, s3[n-2].OffsetMs)
			}
			if d1, d2 := s4[n-1].OffsetMs-s4[n-2].OffsetMs, s4[n].OffsetMs-s4[n-1].OffsetMs; d1 != warmGap || d2 != warmGap || s3[n-1].OffsetMs-s3[n-2].OffsetMs != warmGap {
				t.Errorf("%s seed %d: the last three requests are spaced %d and %d ms, want the drained gap %d", et, seed, d1, d2, warmGap)
			}
		}
	}
}

// The warm-up spans at seed 11 are what the shell's warm-up duration has to hold, so they are pinned and reported.
// Each is session 3's, which is session 2's, plus one drained 2,048/16 gap.
func TestSessionFourWarmupSpansAtSeed11(t *testing.T) {
	warmGap := homogeneous(1, warmupTokens, warmupCap).gapMs()
	for _, c := range []struct {
		t    EpisodeType
		span int64
	}{
		{EpisodeSerial, 89200},
		{EpisodeBurst, 109580},
		{EpisodeStagger, 486800},
	} {
		_, s3, _ := designS3.warmupPlan(11, c.t)
		_, s4, err := designS4.warmupPlan(11, c.t)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("%s at seed 11: session-4 warm-up span %d ms (session 3: %d ms)", c.t, s4, s3)
		if s4 != c.span || s4 != s3+warmGap {
			t.Errorf("%s session-4 warm-up spans %d ms at seed 11, want %d (session 3's %d plus %d)", c.t, s4, c.span, s3, warmGap)
		}
		_, m3, _ := designS3.plan(11, c.t)
		_, m4, _ := designS4.plan(11, c.t)
		if m3 != m4 {
			t.Errorf("%s measured span %d ms in session 4 and %d in session 3", c.t, m4, m3)
		}
	}
}

func TestSessionFourRegistration(t *testing.T) {
	s4, ok := LookupStudy(StudyInstrumentValidationS4)
	if !ok {
		t.Fatalf("%s is not registered", StudyInstrumentValidationS4)
	}
	s3, _ := LookupStudy(StudyInstrumentValidationS3)
	if s4.ID != "instrument-validation-s4-2026-10-06" {
		t.Errorf("session 4's id is %q", s4.ID)
	}
	if !reflect.DeepEqual(s4.Arms, s3.Arms) || len(s4.Arms) != 9 {
		t.Errorf("session 4's arms %v are not session 3's nine %v", s4.Arms, s3.Arms)
	}
	if s4.Arrivals != ArrivalsEpisodes || s4.TracesVaryByRepetition {
		t.Errorf("session 4 arrivals %q, traces vary by repetition %v", s4.Arrivals, s4.TracesVaryByRepetition)
	}
	if !IsInstrumentValidationStudy(StudyInstrumentValidationS4) {
		t.Error("session 4 is not an instrument-validation study")
	}
	// The design differs from session 3's in the study and the conditioning count and nowhere else.
	d := designS4
	d.study, d.warmupConditioning = designS3.study, designS3.warmupConditioning
	if !reflect.DeepEqual(d, designS3) || designS4.warmupConditioning != 1 || designS3.warmupConditioning != 0 || designS2.warmupConditioning != 0 {
		t.Errorf("session 4's design %+v is not session 3's %+v with one conditioning request", designS4, designS3)
	}
	for _, et := range EpisodeTypes {
		rows, _ := ivTraceBytes(t, StudyInstrumentValidationS4, et, 11, false)
		for _, arm := range []string{InstrumentValidationArm(et, instrumentModeLog), InstrumentValidationArm(et, instrumentModeNoLog), InstrumentValidationArm(et, instrumentModeAsync)} {
			if err := InstrumentValidationPlanRefusal(StudyInstrumentValidationS4, arm, rows); err != nil {
				t.Errorf("the session-4 %s trace was refused for %s: %v", et, arm, err)
			}
		}
	}
	if err := MatrixPlanArmSetRefusal(StudyInstrumentValidationS4, []string{"burst-log"}); err == nil {
		t.Error("a session-4 logging arm planned without its pair was not refused")
	}
}

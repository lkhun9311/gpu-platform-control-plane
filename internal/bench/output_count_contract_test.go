package bench

import (
	"strings"
	"testing"
)

// studyEngineTokensFixture is a study registered only for these tests, on the token contract.
//
// No registered study uses OutputCountEngineTokens yet, so the contract is exercised through a fixture rather
// than by re-registering a published study, which is exactly the change the contract exists to avoid.
const studyEngineTokensFixture = "output-count-fixture-engine-tokens"

func registerEngineTokenStudy(t *testing.T) {
	t.Helper()
	studies[studyEngineTokensFixture] = Study{
		ID:          studyEngineTokensFixture,
		Arms:        []string{"off"},
		OutputCount: OutputCountEngineTokens,
	}
	t.Cleanup(func() { delete(studies, studyEngineTokensFixture) })
}

// streamRow is a completed row of frames content frames carrying engine tokens, first to last 70 ms apart.
//
// engine 0 is a row whose stream carried no usage chunk.
func streamRow(index int, study, tenant string, frames, engine int) RawRow {
	const sec = int64(1_000_000_000)
	send := sec + int64(index)*sec
	first := send + 10_000_000
	return RawRow{
		Index: index, Arm: "off", Tenant: tenant, Study: study,
		SendUnixNanos: send, FirstTokenUnixNanos: first, EndUnixNanos: first + 70_000_000,
		OutputTokens: frames, EngineOutputTokens: engine, EstInputTokens: 50, HTTPStatus: 200,
		StreamTerminated: true, TerminationRecorded: true,
	}
}

// TestEngineTokenContractCountsTwoTokensPerFrameAsTokens is the issue's case: four frames of two tokens each.
//
// Under the frame rule this stream reports half its output and a TPOT of 70/3 ms; the engine generated eight
// tokens, so throughput is eight per row and TPOT is 70/7 = 10 ms.
func TestEngineTokenContractCountsTwoTokensPerFrameAsTokens(t *testing.T) {
	registerEngineTokenStudy(t)
	rows := []RawRow{
		streamRow(0, studyEngineTokensFixture, PremiumTenant, 4, 8),
		streamRow(1, studyEngineTokensFixture, NoisyTenant, 4, 8),
		streamRow(2, studyEngineTokensFixture, NoisyTenant, 4, 8),
	}
	s := Summarize("off", rows)

	if s.OutputCount != OutputCountEngineTokens {
		t.Fatalf("contract = %q, want %q", s.OutputCount, OutputCountEngineTokens)
	}
	if s.OutputTokens != 24 {
		t.Errorf("output = %d, want 24 engine tokens (12 frames would be the frame rule)", s.OutputTokens)
	}
	if got, want := s.OutputTokensByTenant[PremiumTenant], int64(8); got != want {
		t.Errorf("premium output = %d, want %d", got, want)
	}
	if s.ActiveSeconds <= 0 {
		t.Fatalf("active seconds = %f, want a positive span", s.ActiveSeconds)
	}
	if got, want := s.OutputTokensPerSecond, 24/s.ActiveSeconds; !closeEnough(got, want) {
		t.Errorf("throughput = %.3f, want %.3f tokens per second", got, want)
	}
	if !closeEnough(s.TPOTMsP99, 10) || !closeEnough(s.TPOTMsP99ByTenant[PremiumTenant], 10) {
		t.Errorf("TPOT p99 = %.3f (premium %.3f), want 10 ms: 70 ms over the seven tokens after the first",
			s.TPOTMsP99, s.TPOTMsP99ByTenant[PremiumTenant])
	}
	if want := 70.0 / 3; !closeEnough(s.InterContentFrameMsP99, want) {
		t.Errorf("inter-content-frame p99 = %.3f, want %.3f: the frame gap is kept under its own name",
			s.InterContentFrameMsP99, want)
	}
	if s.OutputUnmeasuredRows != 0 {
		t.Errorf("unmeasured = %d, want 0", s.OutputUnmeasuredRows)
	}
}

// TestEngineTokenContractCountsARowWithoutUsageAsNotMeasurable checks the row is neither filled nor zeroed.
func TestEngineTokenContractCountsARowWithoutUsageAsNotMeasurable(t *testing.T) {
	registerEngineTokenStudy(t)
	rows := []RawRow{
		streamRow(0, studyEngineTokensFixture, PremiumTenant, 4, 8),
		streamRow(1, studyEngineTokensFixture, NoisyTenant, 5, 0),
	}
	s := Summarize("off", rows)

	if s.OutputUnmeasuredRows != 1 || s.OutputUnmeasuredRowsByTenant[NoisyTenant] != 1 {
		t.Errorf("unmeasured = %d (noisy %d), want 1 on the noisy tenant",
			s.OutputUnmeasuredRows, s.OutputUnmeasuredRowsByTenant[NoisyTenant])
	}
	if s.OutputTokens != 8 {
		t.Errorf("output = %d, want 8: the row without usage must not be filled from its five frames", s.OutputTokens)
	}
	if _, ok := s.OutputTokensByTenant[NoisyTenant]; ok {
		t.Errorf("noisy tenant has an output entry %d, want none: zero is a measurement, absence is not",
			s.OutputTokensByTenant[NoisyTenant])
	}
	if s.OutputTokensPerSecond != 0 {
		t.Errorf("throughput = %.3f, want 0 while a delivered row is unmeasured", s.OutputTokensPerSecond)
	}
	s.SetActiveSeconds(10)
	if s.OutputTokensPerSecond != 0 {
		t.Errorf("throughput after a pooled span = %.3f, want 0", s.OutputTokensPerSecond)
	}
	if _, ok := s.TPOTMsP99ByTenant[NoisyTenant]; ok {
		t.Errorf("noisy TPOT = %.3f, want none: it has no token count to divide by", s.TPOTMsP99ByTenant[NoisyTenant])
	}
	if want := 70.0 / 4; !closeEnough(s.InterContentFrameMsP99ByTenant[NoisyTenant], want) {
		t.Errorf("noisy inter-content-frame p99 = %.3f, want %.3f: frames were observed",
			s.InterContentFrameMsP99ByTenant[NoisyTenant], want)
	}

	report := FormatReport([]ArmSummary{s}, nil, 0)
	for _, want := range []string{"n/m", "not measurable: 1 delivered row(s)", string(OutputCountEngineTokens)} {
		if !strings.Contains(report, want) {
			t.Errorf("report lacks %q:\n%s", want, report)
		}
	}
}

// TestRegisteredStudiesKeepTheFrameRule pins every published study to the contract it was scored under.
//
// Registering the token contract on an existing study would move numbers already published, so a new study
// has to be the one that opts in.
func TestRegisteredStudiesKeepTheFrameRule(t *testing.T) {
	for _, id := range KnownStudyIDs() {
		if got := OutputCountForStudy(id); got != OutputCountContentFrames {
			t.Errorf("study %s counts output under %q, want %q", id, got, OutputCountContentFrames)
		}
	}
	if got := OutputCountForStudy(""); got != OutputCountContentFrames {
		t.Errorf("legacy unlabelled rows count under %q, want %q", got, OutputCountContentFrames)
	}
}

// TestFrameContractRowsScoreAsBefore feeds an old study two tokens per frame and expects the frame numbers.
//
// The engine count is present and disagrees on purpose: an old-contract report must not start reading it.
func TestFrameContractRowsScoreAsBefore(t *testing.T) {
	rows := []RawRow{
		streamRow(0, StudyHoldCapProductTransfer, PremiumTenant, 4, 8),
		streamRow(1, StudyHoldCapProductTransfer, NoisyTenant, 4, 8),
	}
	s := Summarize("off", rows)

	if s.OutputCount != OutputCountContentFrames {
		t.Fatalf("contract = %q, want %q", s.OutputCount, OutputCountContentFrames)
	}
	if s.OutputTokens != 8 {
		t.Errorf("output = %d, want 8 frames", s.OutputTokens)
	}
	if want := 70.0 / 3; !closeEnough(s.TPOTMsP99, want) || !closeEnough(s.InterContentFrameMsP99, want) {
		t.Errorf("TPOT p99 = %.3f, inter-content-frame p99 = %.3f, want both %.3f", s.TPOTMsP99,
			s.InterContentFrameMsP99, want)
	}
	if got, want := s.OutputTokensPerSecond, 8/s.ActiveSeconds; !closeEnough(got, want) {
		t.Errorf("throughput = %.3f, want %.3f", got, want)
	}
	if report := FormatReport([]ArmSummary{s}, nil, 0); strings.Contains(report, "contract") {
		t.Errorf("a frame-contract report gained the contract section, so old reports no longer render as they did:\n%s",
			report)
	}
}

// TestMixedContractsAreRefusedNotSummed checks two units are never added together.
func TestMixedContractsAreRefusedNotSummed(t *testing.T) {
	registerEngineTokenStudy(t)
	rows := []RawRow{
		streamRow(0, StudyHoldCapProductTransfer, PremiumTenant, 4, 8),
		streamRow(1, studyEngineTokensFixture, PremiumTenant, 4, 8),
	}
	s := Summarize("off", rows)

	if s.OutputCount != "" {
		t.Errorf("contract = %q, want empty for rows of two contracts", s.OutputCount)
	}
	if s.OutputTokens != 0 || s.OutputUnmeasuredRows != 2 || s.TPOTMsP99 != 0 {
		t.Errorf("output = %d, unmeasured = %d, TPOT p99 = %.3f; want 0, 2, 0", s.OutputTokens,
			s.OutputUnmeasuredRows, s.TPOTMsP99)
	}
}

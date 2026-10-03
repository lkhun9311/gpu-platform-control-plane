/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package bench

import (
	"fmt"
	"math"
	"math/rand/v2"
	"sort"
	"strings"
)

// httpStatusTooManyRequests is the status the gateway returns when an admission control rejects a request.
const httpStatusTooManyRequests = 429

// httpStatusInputExceedsBurst is the status the gateway returns when a prompt is larger than the bucket can ever hold.
//
// The gateway splits its refusals deliberately: 429 tells the caller to come back later, 413 tells it to send
// something smaller, because a request that cannot fit any bucket would otherwise be retried forever.
const httpStatusInputExceedsBurst = 413

// httpStatusProfileViolation is the status the gateway returns for a body that parses but sits outside the
// registered benchmark request shape.
//
// 422 rather than 400, because the JSON is fine and only the shape is wrong. The refusal happens before the
// guard is consulted, so it belongs with 401 and 403 rather than with the bucket's own refusals: counting it as
// shedding would credit the guard with a decision it never made.
const httpStatusProfileViolation = 422

// httpStatusUnauthorized and httpStatusForbidden are the statuses the gateway returns before admission runs.
const (
	httpStatusUnauthorized = 401
	httpStatusForbidden    = 403
)

// errKindTimeout is the RawRow.ErrorKind the replay client records when a request exceeds its deadline.
const errKindTimeout = "timeout"

// errKindRejected is the RawRow.ErrorKind the replay client records when the gateway refused the request.
//
// Named rather than repeated because the linter counts three occurrences and, more usefully, because the
// vocabulary is closed: replay.go documents it as one of "timeout", "transport", "rejected", "stream".
const errKindRejected = "rejected"

// ArmSummary is the analysis of one arm's raw evidence for one repetition.
//
// Latency percentiles are in milliseconds, computed from the client-side raw timestamps.
// thresholdProbePrefix names the probe tenants the trace generator creates to straddle the guard's
// eligibility threshold. Matching on a prefix rather than an exact pair keeps the report from having to be
// edited every time a probe is added, and keeps the two files from disagreeing about a literal.
const thresholdProbePrefix = "standard-probe-"

// The threshold probes, defined here because the report keys on them and the trace generator builds them.
//
// They lived in cmd/benchharness first, and the test for them transcribed the numbers -- so setting both
// probes to the same length passed everything while silently removing the only traffic that touches the
// threshold. One definition, read by both sides, is what makes that mutation fail.
//
// The gateway scores (chars+3)/4, so these land one point either side of a 4096 threshold: 16,380 scores
// 4,095 and passes an engaged guard, 16,384 scores 4,096 and does not. Four characters apart.
const (
	ProbeUnderTenant = thresholdProbePrefix + "under"
	ProbeOverTenant  = thresholdProbePrefix + "over"
	ProbeUnderChars  = 16_380
	ProbeOverChars   = 16_384
)

// isThresholdProbe reports whether tenant is one of the threshold probes.
func isThresholdProbe(tenant string) bool { return strings.HasPrefix(tenant, thresholdProbePrefix) }

// shedByAdmission reports whether the gateway refused this request as an admission decision.
//
// It reads the status rather than RawRow.ErrorKind because the replay client labelled only 429 "rejected" and
// left 413 under the generic "http", so evidence already on disk carries the wrong label and the status is the
// only field that was right at the time. Scoring off the status lets a finished paid run be re-scored.
//
// Counting only 429 made the arm that shed hardest the one that reported shedding nothing: a static-cap replay
// refused 447 noisy requests with 413 and printed rejected=0, having filed all 447 under Failed instead.
// neverEvaluated reports whether the gateway turned this request away before admission control ran.
//
// Authentication and authorisation are decided ahead of admission, so a request refused there carries no
// information about the guard: the threshold, the bucket, and the cap all never saw it.
// eligibleTier reports whether the tier the gateway recorded admits this row to the gated population.
func eligibleTier(r RawRow) bool {
	return r.Tier == "" || r.Tier == tierStandard
}

// tierStandard is the gateway's name for the tier its admission controls gate.
const tierStandard = "standard"

// admissionUnknown reports whether this request left no record of what the guard decided about it.
//
// A transport error or a timeout means no response arrived, so there are no headers to read and no status to
// classify. It is the admission-side twin of a censored latency observation, and it is treated the same way:
// removed from the measurement rather than guessed at, counted, and disqualifying past a threshold.
func admissionUnknown(r RawRow) bool {
	return r.HTTPStatus == 0 || r.ErrorKind == errKindTimeout
}

func neverEvaluated(r RawRow) bool {
	return r.HTTPStatus == httpStatusUnauthorized || r.HTTPStatus == httpStatusForbidden
}

// shedByAdmission reports whether the guard refused this request.
//
// 413 is TWO different refusals sharing one status code: a prompt larger than the bucket can ever hold, which
// is an admission decision, and a body over the gateway's size cap, which is refused before admission runs.
// Counting both as shedding attributes a payload the caller sent wrong to the bucket, and the admitted-work
// fraction is exactly the number that distinction changes.
//
// The gateway names the admission one in X-Admission-Reason, which the sender records on the row. A 413 with no
// reason therefore did not reach admission: it is a malformed-request outcome, not work the guard declined.
// Rows recorded before the gateway set that header carry no reason either, so this reads a 413 without one as
// pre-admission -- which is the conservative direction for the fraction, since it removes the row from both
// terms rather than crediting the guard with a refusal it may not have made.
func shedByAdmission(r RawRow) bool {
	if r.HTTPStatus == httpStatusTooManyRequests {
		return true
	}
	return r.HTTPStatus == httpStatusInputExceedsBurst && r.AdmissionReason != ""
}

// refusedBeforeAdmission reports whether the gateway turned the request away without the guard seeing it.
//
// 401 and 403 are decided on identity, and a 413 carrying no admission reason is decided on payload size. In
// every case the guard never spoke, so the row belongs in neither term of the admitted-work fraction.
func refusedBeforeAdmission(r RawRow) bool {
	return neverEvaluated(r) ||
		r.HTTPStatus == httpStatusProfileViolation ||
		(r.HTTPStatus == httpStatusInputExceedsBurst && r.AdmissionReason == "")
}

// ProbeOutcome is one probe tenant's admission tally, and the real token cost the estimate stood in for.
type ProbeOutcome struct {
	// Total is how many of this tenant's requests the arm sent.
	Total int
	// Rejected is how many the gateway refused on admission, whether it said 429 or 413.
	Rejected int
	// EstInputTokens is the score the gateway assigned, which is what the threshold is compared against.
	EstInputTokens int
	// Unevaluated is how many the gateway turned away before admission ran, so the threshold never judged them.
	//
	// A probe refused for its credentials is not a probe that passed the threshold, and the difference is the
	// difference between evidence and none. Without this the section printed rejected=0 for probes the guard
	// had never seen, which reads as the threshold having considered them and let them through.
	Unevaluated int
}

type ArmSummary struct {
	// Arm names the condition.
	Arm string
	// Total is every request the trace offered for this arm.
	Total int
	// Completed counts requests that produced a full response (a first token and an end).
	Completed int
	// OfferedExactTokens and AdmittedExactTokens are the admitted-work fraction in the units the design
	// actually specifies: the served tokenizer's own count, not ceil(chars/4).
	//
	// The estimate is not a neutral stand-in. This project's calibration measures it 36 percent low on a
	// 200-character prompt and 30 percent high on a 40,000-character one (10,000 estimated against 7,695 measured), so a fraction built from it weighs
	// the population differently than the criterion says to.
	OfferedExactTokens  int64
	AdmittedExactTokens int64
	// ExactTokensMissing counts eligible requests with no measured count, and ExactTokensContradicted counts
	// those whose engine-reported count disagrees with the trace's.
	//
	// Either one disqualifies the admission-match check. The alternative is to fall back to the estimate,
	// which is how the criterion came to be unevaluated for three paid runs without anyone noticing.
	ExactTokensMissing      int
	ExactTokensContradicted int
	// OutputTokens, OutputTokensPerSecond, TPOTMsP50/P99 and OutputTokensByTenant are what protection cost.
	//
	// Every check in this report is a TTFT ratio, and that is half an answer. The paid run's static-cap arm
	// held the tail at the isolated arm's latency AND at its throughput -- 46.3 output tokens per second
	// against 46.4 -- because it did not make the engine efficient, it discarded the long tenant's work
	// entirely. The unprotected arm ran 24 percent faster in aggregate. None of that was visible.
	//
	// TPOT is the inter-token time a first-token metric cannot see: a guard that protects the first token and
	// wrecks the stream after it would pass every check here. The rows have carried all of this from the
	// start; only the report was not reading it.
	OutputTokens int64
	// ActiveSeconds is the wall clock the ARM occupied, and it is not derivable from pooled rows: a report
	// pools four repetitions separated by washout pauses, so max(end) - min(send) over the pool charges the
	// arm for minutes in which it sent nothing. Summarize fills this from the rows it is given, which is
	// right for one repetition; a caller that pools MUST sum the per-repetition values instead, exactly as
	// it already does for RepetitionCount and MinRepetitionTail.
	ActiveSeconds         float64
	OutputTokensPerSecond float64
	TPOTMsP50             float64
	TPOTMsP99             float64
	// OutputTokensByTenant is the share each tenant actually received, which is how protection-by-discarding
	// is told apart from protection.
	OutputTokensByTenant map[string]int64
	// OutputTokensFromFailedStreams is how much of OutputTokens arrived on a stream that then broke.
	//
	// Those tokens are counted, because the GPU produced them and the tenant received them, and dropping
	// them would understate what a contending tenant got -- the exact quantity the share exists to
	// measure. But a share that is a third truncated streams does not mean what an intact one means, and
	// a quantity may not be described by a cause its ledger does not establish. So the amount is
	// disclosed rather than folded in.
	OutputTokensFromFailedStreams int64
	// OutputTokensFromFailedStreamsByTenant is the same quantity per tenant, which is the form a reading needs.
	//
	// M5-c's reading 2 asks whether the contender's COMPLETED output fell below a fraction of its output
	// under the control. OutputTokensByTenant does not answer that: the sender keeps HTTPStatus at 200 for a
	// stream that broke after its headers arrived, so the tokens it managed to deliver are added there --
	// which is the opposite of what tallyDelivered's own comment says it does. An arm that completes half
	// the contender's responses and breaks the other half after fifteen of sixteen tokens then reports 97
	// percent of the control's output instead of 50, and reading 2 never fires.
	OutputTokensFromFailedStreamsByTenant map[string]int64
	// TPOTMsP50ByTenant and TPOTMsP99ByTenant split the inter-token time by who received it.
	//
	// The arm-wide TPOT above pools every tenant, because it is accumulated before the premium-only filter,
	// and that answers "how did this arm's streams behave". The pre-registered criterion asks something
	// else: whether the PROTECTED tenant paid for its fast first token with a slow stream. On the paid
	// evidence the arm-wide figure is 266.8 ms for arms whose premium and noisy streams need not resemble
	// each other, and quoting it against a premium criterion would describe one tenant with another's
	// number.
	TPOTMsP50ByTenant map[string]float64
	TPOTMsP99ByTenant map[string]float64
	// AdmissionLost is how many ELIGIBLE requests got no admission verdict at all, so the guard's behaviour
	// toward them is unknown.
	//
	// A request that never received an HTTP response was not admitted and was not refused. Counting it as
	// either invents an observation; counting it as admitted -- which is what happened -- let an arm whose
	// traffic died in transport report a perfect admission match on work it never offered.
	AdmissionLost int
	// eligibleScored is how many eligible requests did get a verdict; AdmissionLost is judged against it.
	eligibleScored int
	// Rejected counts admission refusals (HTTP 429 or 413), the load the guard or static cap shed.
	Rejected int
	// TimedOut counts requests recorded with a timeout error kind.
	TimedOut int
	// Failed counts other non-completing requests (transport or stream errors).
	Failed int
	// RepetitionTTFTMsP99 is each repetition's own premium TTFT p99, attached by the caller that knows the
	// split. The price-of-protection run's reading 3 compares a cell's improvement against the CONTROL'S
	// repetition-to-repetition spread, so without these the reading has no threshold and must decline to
	// decide rather than report a cell as failing to beat noise nobody measured.
	RepetitionTTFTMsP99 []float64
	// DispositionByTenant is what happened to each tenant's offered requests, and it exists because a share
	// alone cannot say why a share is small.
	//
	// The price-of-protection run's reading 2 fires only when the contending tenant's missing work was
	// REJECTED OR DISCARDED rather than delayed, and it says why in its own text: a reduced share is equally
	// consistent with work discarded, work delayed past the window, and work starved but still queued, which
	// are three findings and only one of them is deletion. The arm-wide Rejected/TimedOut/Failed counts above
	// cannot separate them per tenant, so a reading built on those would be attributing a quantity to a cause
	// its ledger does not establish -- which is the one thing this package's rules forbid outright.
	DispositionByTenant map[string]Disposition
	// EstInputTokensByTenant is the estimated input tokens each tenant was OFFERED, summed over its rows.
	//
	// It exists because two runs of the same study, at the same rate and the same seed, can send prompts of
	// different length and nothing on the page says so. Measured 2026-10-01: the ninth pilot offered premium
	// prompts of 50 estimated tokens and the CR-driven run offered 294, a 5.9x difference in prefill, and the
	// two produced headline ratios of 27.2x and 23.0x. The registration freezes the rate, the weights, the
	// duration and the seed -- not the prompt length.
	//
	// traceChecksum already made the difference DETECTABLE; it is the sha256 of the trace and the trace
	// records lengths. What it cannot do is make it LEGIBLE: two opaque hashes disagreeing does not tell a
	// reader the prompts grew. promptCorpusSHA cannot either, and is not meant to -- the corpus pins the
	// TEXT, which was identical in both runs.
	//
	// Per tenant rather than per arm, because the premium and contender lengths move independently and the
	// premium one is the study's primary endpoint. The divisor for a mean is DispositionByTenant[t].Offered.
	EstInputTokensByTenant map[string]int64
	// EngineInputTokensByTenant is, per tenant, how many rows reported each DISTINCT engine-reported input
	// token count -- the engine's own prompt_tokens, not the gateway's ceil(chars/4) admission estimate.
	//
	// Kept as a distribution rather than a sum because the question it answers is "did every request carry
	// the declared length", and a sum cannot tell 23,275 rows of 256 from 23,274 of 255 plus one of 23,531.
	//
	// Counted over EVERY offered row rather than the eligible population. The gateway's eligibility rule is
	// tier == standard AND estimate >= threshold, which excludes the premium tier by construction: a check
	// built on the eligible rows could not see 69,825 of the ninth pilot's 71,215 requests, and premium is
	// the study's primary endpoint.
	EngineInputTokensByTenant map[string]map[int]int
	// EngineInputTokensUnreportedByTenant counts, per tenant, offered rows where the engine reported no input
	// token count at all, so "every row agreed" and "no row said anything" cannot read the same.
	EngineInputTokensUnreportedByTenant map[string]int
	// TTFTMsP50/P95/P99 are the time-to-first-token percentiles over COMPLETED requests, in ms.
	TTFTMsP50 float64
	TTFTMsP95 float64
	TTFTMsP99 float64
	// E2EMsP99 is the end-to-end p99 over completed requests, in ms.
	E2EMsP99 float64
	// OfferedInputTokens is the estimated input tokens of every eligible request the trace offered.
	//
	// AdmittedInputTokens is the estimated input tokens of the eligible requests that were NOT rejected.
	//
	// Their ratio is the admitted-work fraction the design uses to check that arm B is admission-matched to arm C.
	OfferedInputTokens  int64
	AdmittedInputTokens int64
	// ThresholdProbe records how the guard's eligibility threshold behaved, keyed by tenant.
	//
	// The rest of this summary cannot show it. Contender and premium traffic sit thousands of tokens either
	// side of the threshold, so their admission outcome is the same for any threshold in a wide range, and a
	// report built only from them describes a guard whose configured number never mattered. The probe
	// tenants straddle it by four characters; this is where their opposite outcomes become visible.
	ThresholdProbe map[string]ProbeOutcome

	// RepetitionCount and MinRepetitionTail describe the arm's repetitions rather than its pooled rows, and
	// they exist because pooling hides a truncated repetition.
	//
	// TailSampleSize is computed over every row in the arm. An arm whose repetitions completed 500, 500, 500
	// and 30 premium requests therefore reports 1,530 -- far above MinTailSamples -- while one quarter of the
	// evidence is a p99 taken over thirty requests, which is that repetition's MAXIMUM. That fourth value is
	// then resampled with equal weight by the incremental bootstrap.
	//
	// The floor is the same number and the same derivation as MinTailSamples, applied per repetition because
	// that is the unit the bootstrap resamples: below 100, nearest-rank p99 lands on the maximum.
	//
	// Zero means the caller did not supply them (Summarize cannot know how its rows were split), and the
	// check is then skipped rather than failing closed on absence -- the harness fills them and the unit
	// tests that build summaries by hand do not.
	RepetitionCount int

	// AnyRepetitionCensored is true when ANY repetition was censored, whatever the pool says.
	//
	// Censoring is a fraction, and pooling averages it away: a repetition that lost 1.50% of its premium
	// requests sits beside two clean ones as 0.75% of the pool, under the 1% bar, and the readings that
	// refuse a censored control never see it. A review reproduced exactly that on the eighth pilot's rows
	// and reading 5 fired on a censored control. Attached by the caller that knows how the rows were split,
	// for the same reason RepetitionCount is.
	AnyRepetitionCensored bool

	// WorstRepetitionServedFractionByTenant is the lowest completed/offered any repetition reached, per tenant.
	//
	// A COUNT and a FRACTION are different questions and the floor only asked the first. Repetitions of
	// 100/139 and 139/139 both clear a hundred-completion floor while the first lost 28% of its load, and a
	// run whose contention was delivered that unevenly cannot be compared against one where it was not.
	// Carried per tenant so the CONTROL is checked too: every ratio in this study is measured against
	// `shared`, and a control that lost a third of its contender load is a weakened denominator.
	WorstRepetitionServedFractionByTenant map[string]float64

	// MinRepetitionCompletedByTenant is the thinnest repetition's completed count, per tenant.
	//
	// MinRepetitionTail answers the same question for the premium tenant only, which left the contender's
	// floor applicable to the POOL and nowhere else. Attached by the caller that knows how the rows were
	// split, for the same reason RepetitionCount is: Summarize sees pooled rows and cannot tell.
	MinRepetitionCompletedByTenant map[string]int

	// MinRepetitionTail is the smallest premium-completion count among the arm's repetitions.
	MinRepetitionTail int

	// Censored is true when more than 1% of the premium requests failed to complete for a non-admission reason -- a timeout OR a transport/stream error -- so the tail is a lower bound rather than an exact p99 (design spec: report it as at least the timeout, never drop it).
	Censored bool
	// TailSampleSize is the number of completed premium requests the tail percentiles were computed over.
	//
	// The pre-registered checks refuse a run whose compared arms have a zero-size tail, so a run that completed nothing cannot be certified as protection.
	TailSampleSize int
}

// eligibleLongThreshold mirrors the guard's standard-long threshold, so admitted-work is measured over the same population the guard and static cap actually gate.
const eligibleLongThreshold = 4096

// Summarize computes one arm's summary from its raw rows.
//
// The tail percentiles are the DESIGN'S PRIMARY ENDPOINT: premium (victim) TTFT p99, so they are computed only over the premium tenant's completed requests, never over the noisy contender whose long prefills would otherwise dominate the tail and let a guard flatter its number by shedding contender load.
//
// The overall completed/rejected/timed-out/failed counts still account for every offered request, so shedding load always shows up as a rejection count.
//
// The admitted-work fractions are measured over the eligible (standard-long) population, which is the contender the controls actually gate.
func Summarize(arm string, rows []RawRow) ArmSummary {
	s := ArmSummary{Arm: arm, Total: len(rows)}
	// Made here rather than lazily inside the row loop, where the other per-tenant maps are made.
	//
	// That loop sits at the gocyclo ceiling: one more `if m == nil` in it took Summarize from 30 to 31 and
	// turned `make lint` red. An empty map for an arm with no rows is harmless -- formatOfferedLoad tests
	// len() -- and a nil map would panic on the first write, so the initialisation cannot simply be dropped.
	s.EstInputTokensByTenant = map[string]int64{}
	s.EngineInputTokensByTenant = map[string]map[int]int{}
	s.EngineInputTokensUnreportedByTenant = map[string]int{}

	// The eligible-population threshold comes from the manifest provenance stamped into the rows, so admitted-work is scored over the same population the guard gated even if the paid run tuned it.
	threshold := eligibleLongThreshold
	if len(rows) > 0 && rows[0].LongThreshold > 0 {
		threshold = rows[0].LongThreshold
	}

	var ttft, e2e, tpot []float64
	tpotByTenant := map[string][]float64{}
	var premiumTotal, premiumTimedOut, premiumLost int
	var firstSend, lastEnd int64
	for _, r := range rows {
		// The wall clock the arm occupied, taken from the rows rather than from a timer the runner kept, so a
		// re-scored evidence file yields the same throughput as the run that produced it.
		if r.SendUnixNanos > 0 && (firstSend == 0 || r.SendUnixNanos < firstSend) {
			firstSend = r.SendUnixNanos
		}
		if r.EndUnixNanos > lastEnd {
			lastEnd = r.EndUnixNanos
		}
		tpot = s.tallyDelivered(r, tpot, tpotByTenant)
		// The declared-load gate's population is every offered request, so this call carries no condition.
		s.tallyEngineInputTokens(r)
		// Admitted-work accounting covers the eligible population, for the admission-match check.
		//
		// The gateway gates on tier == standard AND EstInputTokens >= threshold, and this applies the same
		// rule -- against the tier the gateway itself reported, not one inferred from a tenant name.
		//
		// A row with no tier predates the gateway reporting it and is scored on the threshold alone, as it
		// always was. Treating "not recorded" as "not standard" would empty the eligible population of every
		// run already on disk and silently rewrite its numbers.
		//
		// A request the gateway turned away before admission ran is outside that population entirely, in
		// neither term of the fraction, because the guard never saw it. Counting it as offered-and-admitted
		// scored 737,280 admitted tokens for an arm that admitted nothing: the paid run's probes estimate at
		// exactly the 4,096 threshold, so all 180 of them per arm were eligible, and all 180 were 403.
		if r.EstInputTokens >= threshold && eligibleTier(r) && !refusedBeforeAdmission(r) {
			s.tallyEligibleWork(r)
		}

		// The probe tally is keyed by tenant rather than by a flag on the row, because what makes a request a
		// probe is the prompt length the trace gave it, and the tenant name is where that choice is recorded.
		// Any tenant whose name marks it a probe is counted; the report does not need to know how many there
		// are, only that their outcomes are reported separately from the populations that cannot see the
		// threshold.
		if isThresholdProbe(r.Tenant) {
			if s.ThresholdProbe == nil {
				s.ThresholdProbe = map[string]ProbeOutcome{}
			}
			o := s.ThresholdProbe[r.Tenant]
			o.Total++
			o.EstInputTokens = r.EstInputTokens
			switch {
			// A probe the guard never evaluated is not a probe that passed, and a 413 refused on body size is
			// as unevaluated as a 403: both were decided before admission ran. Reading only 401/403 here left a
			// body-limit refusal in neither bucket while still counting toward Total, so the section showed a
			// probe population larger than the outcomes it could explain.
			case refusedBeforeAdmission(r):
				o.Unevaluated++
			case shedByAdmission(r):
				o.Rejected++
			}
			s.ThresholdProbe[r.Tenant] = o
		}

		// Overall outcome counts cover every offered request, so load shedding is always visible as a rejection.
		// The same verdict is recorded against the tenant, because "why is this tenant's share small" is a
		// different question from "how much did this arm shed", and only the second one is answerable here.
		if s.DispositionByTenant == nil {
			s.DispositionByTenant = map[string]Disposition{}
		}
		// Summed over OFFERED rows, not completed ones: the load is what the trace asked for, and a run that
		// lost requests still offered the prompts it was configured with.
		s.EstInputTokensByTenant[r.Tenant] += int64(r.EstInputTokens)
		d := s.DispositionByTenant[r.Tenant]
		d.Offered++
		switch {
		case r.ErrorKind == errKindTimeout:
			s.TimedOut++
			d.TimedOut++
		case shedByAdmission(r):
			s.Rejected++
			d.Rejected++
		case r.ErrorKind != "":
			s.Failed++
			d.Failed++
		default:
			if _, ok := r.TTFTNanos(); ok {
				s.Completed++
				d.Completed++
			} else {
				s.Failed++
				d.Failed++
			}
		}
		s.DispositionByTenant[r.Tenant] = d

		// The tail is premium-only; the contender's requests never enter the protected metric.
		if r.IsNoisy {
			continue
		}
		premiumTotal++
		if r.ErrorKind == errKindTimeout {
			premiumTimedOut++
			continue
		}
		if shedByAdmission(r) {
			continue
		}
		if r.ErrorKind != "" {
			// A transport or stream error is a LOST OBSERVATION, exactly like a timeout, and it was not
			// counted as one.
			//
			// The censoring rule read only premiumTimedOut, so a run whose premium requests died on
			// connection resets kept an uncensored tail. That is the failure mode of a node going away --
			// a reclaimed Spot instance, an evicted engine Pod, an OOM kill, a network blip -- and none of
			// them produce timeouts. An adversarial review demonstrated it by feeding this function an arm
			// truncated at 120 premium completions with 380 transport failures, and the report printed
			// "all checks passed".
			//
			// An admission refusal stays excluded because a rejection is the treatment, not a lost
			// measurement: shedding is what the guard is for and it is accounted separately in Rejected.
			// That holds for 413 exactly as it does for 429, and reading only 429 here would have censored
			// the tail of any arm whose premium traffic ran into the burst ceiling.
			premiumLost++
			continue
		}
		t, okT := r.TTFTNanos()
		e, okE := r.E2ENanos()
		if !okT || !okE {
			continue
		}
		ttft = append(ttft, nanosToMs(t))
		e2e = append(e2e, nanosToMs(e))
	}

	sort.Float64s(ttft)
	sort.Float64s(e2e)
	s.TailSampleSize = len(ttft)
	s.TTFTMsP50 = percentile(ttft, 0.50)
	s.TTFTMsP95 = percentile(ttft, 0.95)
	s.TTFTMsP99 = percentile(ttft, 0.99)
	s.E2EMsP99 = percentile(e2e, 0.99)

	// The tail is censored when more than 1% of the PREMIUM requests did not complete for a reason other than
	// admission, since those missing requests are exactly the ones a p99 should capture.
	//
	// Timeouts and transport/stream errors are both counted. They are the same thing for this purpose -- a
	// premium request whose latency is unknown and was probably long -- and separating them let a whole class
	// of degraded run through uncensored.
	// >= rather than >, because at exactly one percent the p99 is already gone.
	//
	// A nearest-rank p99 over n observations is the ceil(0.99n)-th, so it rests on the slowest n/100 of them.
	// Losing exactly that many -- 18 of 1,840, which the old boundary waved through -- can remove the entire
	// quantile mass the statistic is made of, and the ones that vanish are the ones that were slow enough to
	// die. The reported p99 then is a p98 wearing the other name.
	s.SetActiveSeconds(nanosToMs(lastEnd-firstSend) / 1000)
	// Sorted here for the same reason ttft and e2e are sorted above: percentile is nearest-rank over an
	// ORDERED slice, and handing it arrival order returns whichever sample happens to sit at that index.
	//
	// This shipped unsorted. The metric's own test used a single observation, and with one sample every
	// ordering is the same ordering, so nothing failed. Three samples arriving as 100, 1, 2 ms reported a
	// p99 of 2 -- not a tail, and not even the second largest value.
	sort.Float64s(tpot)
	s.TPOTMsP50 = percentile(tpot, 0.50)
	s.TPOTMsP99 = percentile(tpot, 0.99)
	if len(tpotByTenant) > 0 {
		s.TPOTMsP50ByTenant = map[string]float64{}
		s.TPOTMsP99ByTenant = map[string]float64{}
		for tenant, samples := range tpotByTenant {
			sort.Float64s(samples)
			s.TPOTMsP50ByTenant[tenant] = percentile(samples, 0.50)
			s.TPOTMsP99ByTenant[tenant] = percentile(samples, 0.99)
		}
	}

	if premiumTotal > 0 && float64(premiumTimedOut+premiumLost)/float64(premiumTotal) >= 0.01 {
		s.Censored = true
	}
	return s
}

// nanosToMs converts a nanosecond duration to fractional milliseconds.
func nanosToMs(n int64) float64 { return float64(n) / 1e6 }

// percentile returns the q-quantile of a sorted slice using nearest-rank, or 0 for an empty slice.
//
// Nearest-rank (rather than interpolation) is used because a tail claim should land on an actually observed latency, not a value that never occurred.
func percentile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if q <= 0 {
		return sorted[0]
	}
	if q >= 1 {
		return sorted[len(sorted)-1]
	}
	// Nearest-rank: the smallest index whose cumulative share reaches q.
	rank := int(math.Ceil(q*float64(len(sorted)))) - 1
	rank = max(rank, 0)
	rank = min(rank, len(sorted)-1)
	return sorted[rank]
}

// CI is a two-sided confidence interval.
type CI struct {
	Lo float64
	Hi float64

	// Valid distinguishes "the interval is [0,0]" from "there is no interval".
	//
	// The zero CI used to be indistinguishable from a computed one, and the incremental gate reads
	// `incrementalCI.Hi < 1.0`. When repetition counts differ between arms the caller skips the bootstrap and
	// leaves the zero value, so Hi is 0.0 and the STRICTEST check in the design passes vacuously -- a
	// truncated run disarms the gate instead of tripping it. Making the zero value invalid by construction is
	// what stops that, rather than relying on every caller to remember.
	Valid bool

	// InvalidReason says WHY there is no usable interval, because the two causes call for different actions.
	//
	// The gate reported "unequal or insufficient repetitions" for every invalid interval, so a run refused
	// for scatter would have sent an operator to check repetition counts that were fine.
	InvalidReason string
}

// BootstrapCI returns a percentile-bootstrap confidence interval for the mean of values.
//
// The design requires a repetition/block-aware bootstrap rather than a naive bootstrap over pooled requests, so values here are the PER-REPETITION statistics (e.g. each repetition's TTFT p99), and this resamples whole repetitions with replacement.
//
// alpha is the two-sided error, so 0.05 yields a 95% interval; iterations sets the resample count; seed makes it reproducible.
func BootstrapCI(values []float64, iterations int, seed int64, alpha float64) CI {
	if len(values) == 0 {
		return CI{}
	}
	if len(values) == 1 {
		// A single repetition cannot bound its own variance, so the interval degenerates to the point estimate
		// -- and a point estimate is not a confidence interval. It is returned for display and marked INVALID,
		// because the incremental gate asks whether the interval's upper bound clears 1.0 and a degenerate
		// "interval" answers that question vacuously. This function said as much in its own comment while
		// returning a value the gate could not tell apart from a real one.
		return CI{Lo: values[0], Hi: values[0]}
	}

	src := rand.NewPCG(uint64(seed), uint64(seed)^0x9e3779b97f4a7c15)
	rng := rand.New(src)

	means := make([]float64, iterations)
	n := len(values)
	for i := range iterations {
		var sum float64
		for range n {
			sum += values[rng.IntN(n)]
		}
		means[i] = sum / float64(n)
	}
	sort.Float64s(means)
	return CI{
		Lo:    percentile(means, alpha/2),
		Hi:    percentile(means, 1-alpha/2),
		Valid: true,
	}
}

// admittedWorkFraction is the eligible EXACT input tokens admitted over those offered, which is the unit the
// design registers the admission-match criterion in.
//
// It used to divide the ESTIMATED totals while ArmSummary already carried the exact ones and the comment on
// those fields already said they were "the admitted-work fraction in the units the design actually specifies".
// The estimate is not a neutral stand-in -- this project's own calibration measures it 36 percent low on a
// 200-character prompt and 30 percent high on a 40,000-character one (10,000 estimated against 7,695 measured) -- so a fraction built from it weighs the
// population differently than the criterion says to. The values were collected, validated, and then discarded
// by the one function that decided the verdict.
//
// A zero denominator returns zero here and is turned into an explicit invalidation by the caller, because a
// fraction of zero and a fraction that could not be computed are different facts and only one of them is a
// measurement.
func admittedWorkFraction(s ArmSummary) float64 {
	if s.OfferedExactTokens == 0 {
		return 0
	}
	return float64(s.AdmittedExactTokens) / float64(s.OfferedExactTokens)
}

// estimateWeightedFraction is the same ratio in the ESTIMATE's unit, kept as a labelled diagnostic.
//
// It is what the report used to certify with, so it stays readable for the artifacts already recorded against
// it -- but it is never the criterion, and nothing reads it to decide a verdict.
func estimateWeightedFraction(s ArmSummary) float64 {
	if s.OfferedInputTokens == 0 {
		return 0
	}
	return float64(s.AdmittedInputTokens) / float64(s.OfferedInputTokens)
}

// Checks holds the pre-registered success criteria and whether each passed.
type Checks struct {
	// AbsoluteProtection is C premium TTFT p99 <= 1.25 x R1 premium TTFT p99.
	AbsoluteProtectionRatio float64
	AbsoluteProtectionPass  bool
	// IncrementalValue is C/B premium TTFT p99, which must be <= 0.90 with the CI upper bound below 1.0.
	IncrementalRatio     float64
	IncrementalRatioCI   CI
	IncrementalValuePass bool
	// AdmissionMatch is |wB - wC| / wC over admitted-work fractions in EXACT tokens, which must be within
	// MatchTolerance.
	AdmissionMatchDelta float64
	AdmissionMatchPass  bool
	// AdmissionNotEvaluable marks the criterion as unanswerable rather than failed.
	//
	// The two are different findings and the report used to print the same 0.000 for both. A run whose exact
	// accounting is incomplete has not shown the arms to be mismatched; it has shown that nobody can say.
	AdmissionNotEvaluable bool
	// EstimateWeightedDelta is the same comparison in the ESTIMATE's unit, carried as a labelled diagnostic
	// because every artifact recorded before this repair was certified on it.
	EstimateWeightedDelta float64
	// Invalid marks a run whose evidence disqualifies the comparison before any check is read, so a degenerate run can never be certified as protection.
	//
	// InvalidReason names why, for the report.
	Invalid       bool
	InvalidReason string
	// OverallPass is true only when the run is valid and every check passed, which is the condition for using the word "protects".
	OverallPass bool
}

// invalidate records a reason a run cannot be certified, keeping every reason rather than the last.
//
// It used to assign, so a run broken three ways reported one problem and an operator fixed them one at a
// time -- paying for a run each round to discover the next.
func (c *Checks) invalidate(reason string) {
	c.Invalid = true
	if c.InvalidReason != "" {
		c.InvalidReason += "; "
	}
	c.InvalidReason += reason
}

// MaxRatioScatter is the per-repetition coefficient of variation past which the incremental interval stops
// meaning what it says.
//
// ⚠️ It is RETAINED PROVISIONALLY and is not a validity boundary for the interval this gate now reads.
//
// The 0.15 was placed between false-PASS rates measured against this package's own BootstrapCI, which
// bootstraps the MEAN of per-repetition ratios (cmd/benchharness/power.go:63). The 2026-10-01 amendment
// replaced that with a paired BLOCK bootstrap of the pooled p99 ratio, and no coverage has been measured for
// the new estimator at any scatter. So "benchharness power" output reproduces the REPLACED statistic and must
// not be cited as validation of the current one.
//
// What still holds is narrow: with everything else fixed, the runs that pass with this rule are a subset of
// those that pass without it, so it cannot raise the rate of a false PASS on one fixed experiment.
//
// The 2026-09-03 pilot measured 0.001 for the contended arms and 0.056 for the isolation-like ones, so this
// is not expected to bind. It exists because the failure mode is a gate that PASSES when it should not, and
// a run is not entitled to assume its variability stayed where the pilot's was.
//
// The full argument, including which earlier claim the amendment withdrew, is beside the test that exercises
// this function in report_test.go -- kept in one place on purpose, because the same correction was already
// written there while this comment still asserted the old justification.
const MaxRatioScatter = 0.15

// RatioScatterTooHigh reports whether per-repetition ratios are too scattered for their bootstrap interval
// to be read as a 95 percent bound.
//
// Fewer than two values have no scatter to measure, and their interval is already invalid for that reason.
func RatioScatterTooHigh(ratios []float64) bool {
	if len(ratios) < 2 {
		return false
	}
	mean := 0.0
	for _, r := range ratios {
		mean += r
	}
	mean /= float64(len(ratios))
	if mean <= 0 {
		return false
	}
	ss := 0.0
	for _, r := range ratios {
		ss += (r - mean) * (r - mean)
	}
	return math.Sqrt(ss/float64(len(ratios)-1))/mean > MaxRatioScatter
}

// MaxLostAdmissionFraction is the share of the eligible population whose admission verdict may go missing
// before the admitted-work fraction stops describing the population it claims to.
//
// The same one percent the tail uses, for the same reason: past it the statistic is reporting on requests it
// never saw.
const MaxLostAdmissionFraction = 0.01

// AdmissionScored is how many eligible requests did get a verdict, the denominator AdmissionLost is judged
// against.
func (s ArmSummary) AdmissionScored() int {
	return s.eligibleScored
}

// MinTailSamples is the smallest premium-completion count at which the reported p99 is not simply the
// largest observation.
//
// It is derived, not chosen. The percentile is nearest-rank: index ceil(0.99*n)-1, clamped to n-1. Solve
// ceil(0.99*n)-1 < n-1 and the smallest integer that satisfies it is 100 -- at n=99 the index lands on 98
// of 0..98, the maximum, and every value below 99 does the same. So a run with fewer than 100 premium
// completions reports its slowest request and calls it a tail.
//
// This mattered because nothing read TailSampleSize. It was computed, stored, asserted on in unit tests,
// and never consulted by any production path: not printed, not gating validity. A sixty-second run at a
// rate the engine cannot serve yields a few dozen completions, and the report would have presented that
// maximum with exactly the authority of a p99 over five thousand.
const MinTailSamples = 100

// EvaluateChecks computes the design's pre-registered checks from the four arms' aggregated p99 values and admission-work fractions.
//
// r1P99, offP99 are provenance context; the checks compare C against R1 (absolute) and against B (incremental). incrementalCI is the bootstrap CI of the C/B ratio, produced by the caller from per-repetition ratios.
func EvaluateChecks(r1, staticCap, kvAware ArmSummary, incrementalCI CI, matchTolerance float64) Checks {
	var c Checks

	// A comparison is disqualified before any check is read if a compared arm completed no premium requests or has a censored tail, since its p99 is then not a real tail.
	for _, s := range []ArmSummary{r1, staticCap, kvAware} {
		if s.TailSampleSize == 0 {
			c.invalidate(fmt.Sprintf("arm %s completed no premium requests, so its tail is undefined", s.Arm))
		}
		if s.TailSampleSize > 0 && s.TailSampleSize < MinTailSamples {
			c.invalidate(fmt.Sprintf("arm %s has %d premium completions, below the %d a nearest-rank p99 needs to be anything other than the maximum",
				s.Arm, s.TailSampleSize, MinTailSamples))
		}
		if s.RepetitionCount > 0 && s.MinRepetitionTail < MinTailSamples {
			c.invalidate(fmt.Sprintf("arm %s has a repetition with %d premium completions, below the %d a nearest-rank p99 needs; pooling its %d rows hides that one repetition's p99 is a maximum",
				s.Arm, s.MinRepetitionTail, MinTailSamples, s.TailSampleSize))
		}
		if s.Censored {
			c.invalidate(fmt.Sprintf("arm %s tail is censored (>1%% of premium requests did not complete), so its p99 is only a lower bound", s.Arm))
		}
		// The criterion is defined over exact tokens, so a population that cannot supply them cannot be
		// scored against it. Refusing is the point: falling back to the estimate is what made three paid
		// runs report a number nobody had asked for.
		if s.ExactTokensMissing > 0 {
			c.invalidate(fmt.Sprintf("arm %s has %d eligible requests with no measured input-token count, and the admission-match criterion is defined over the served tokenizer's own count rather than the ceil(chars/4) estimate", s.Arm, s.ExactTokensMissing))
		}
		if s.ExactTokensContradicted > 0 {
			c.invalidate(fmt.Sprintf("arm %s has %d eligible requests whose engine-reported input-token count disagrees with the trace's measurement, so the trace was stamped against a different tokenizer or a different prompt ran", s.Arm, s.ExactTokensContradicted))
		}
		// An eligible request with no admission verdict is unknown work, not admitted work, and the
		// admitted-work fraction is what the whole matched comparison rests on. The threshold is the tail's:
		// past one percent the fraction is describing a population it could not see.
		if eligible := s.AdmissionLost + s.AdmissionScored(); eligible > 0 &&
			float64(s.AdmissionLost)/float64(eligible) >= MaxLostAdmissionFraction {
			c.invalidate(fmt.Sprintf("arm %s lost the admission verdict for %d of %d eligible requests (>%.0f%%), so its admitted-work fraction is measured over a population it could not see",
				s.Arm, s.AdmissionLost, eligible, MaxLostAdmissionFraction*100))
		}
	}

	if r1.TTFTMsP99 > 0 {
		c.AbsoluteProtectionRatio = kvAware.TTFTMsP99 / r1.TTFTMsP99
		c.AbsoluteProtectionPass = c.AbsoluteProtectionRatio <= 1.25
	}

	if staticCap.TTFTMsP99 > 0 {
		c.IncrementalRatio = kvAware.TTFTMsP99 / staticCap.TTFTMsP99
	}
	c.IncrementalRatioCI = incrementalCI
	// An absent interval fails the gate rather than satisfying it. See the comment on CI.Valid.
	c.IncrementalValuePass = c.IncrementalRatio <= 0.90 && incrementalCI.Valid && incrementalCI.Hi < 1.0
	if !incrementalCI.Valid {
		why := incrementalCI.InvalidReason
		if why == "" {
			why = "unequal or insufficient repetitions"
		}
		c.invalidate("the incremental-value check has no usable confidence interval (" + why + "), so it cannot be evaluated")
	}

	// The criterion is evaluated only where the exact accounting can carry it, and R1 is deliberately exempt:
	// it is the premium-only baseline, so having no eligible standard-long work is its normal state, not a gap.
	for _, s := range []ArmSummary{staticCap, kvAware} {
		switch {
		case s.OfferedExactTokens <= 0:
			c.AdmissionNotEvaluable = true
			c.invalidate(fmt.Sprintf("arm %s offered no measured exact input tokens over its eligible population, so the admission-match criterion has no denominator in the unit the design defines it in", s.Arm))
		case s.AdmittedExactTokens > s.OfferedExactTokens:
			// Admitted work is a subset of offered work by construction, so this is an accounting fault
			// rather than a result, and a ratio above one would be reported as a matched arm.
			c.AdmissionNotEvaluable = true
			c.invalidate(fmt.Sprintf("arm %s admitted %d exact input tokens over an offered total of %d, which cannot happen and means the tallies disagree", s.Arm, s.AdmittedExactTokens, s.OfferedExactTokens))
		}
	}
	wB := admittedWorkFraction(staticCap)
	wC := admittedWorkFraction(kvAware)
	// C's admitted work is the denominator of |wB-wC|/wC. Zero there is not a match of zero, it is a quantity
	// the evidence cannot express, and leaving the delta at zero would have printed 0.000 beside a PASS.
	if kvAware.AdmittedExactTokens <= 0 {
		c.AdmissionNotEvaluable = true
		c.invalidate("arm kv-aware admitted no measured exact input tokens, so |wB-wC|/wC has no denominator and the arms cannot be shown to be admission-matched")
	}
	if !c.AdmissionNotEvaluable && wC > 0 {
		c.AdmissionMatchDelta = math.Abs(wB-wC) / wC
		c.AdmissionMatchPass = c.AdmissionMatchDelta <= matchTolerance
	}
	// Recorded whatever the verdict, because the artifacts already written were certified on this number and a
	// reader comparing them to a new report needs to see both in the same place.
	c.EstimateWeightedDelta = 0
	if ewC := estimateWeightedFraction(kvAware); ewC > 0 {
		c.EstimateWeightedDelta = math.Abs(estimateWeightedFraction(staticCap)-ewC) / ewC
	}

	c.OverallPass = !c.Invalid && c.AbsoluteProtectionPass && c.IncrementalValuePass && c.AdmissionMatchPass
	return c
}

// tallyEligibleWork scores one request of the eligible population into the admitted-work fraction.
//
// Split out of Summarize only to keep that function under the complexity limit; the eligibility test stays
// at the call site because that predicate IS the population definition and belongs where it is read.
func (s *ArmSummary) tallyEligibleWork(r RawRow) {
	if admissionUnknown(r) {
		// Out of both terms. The guard may have admitted this request and the connection died after, or it
		// may never have arrived; the evidence cannot say which, and a fraction built on a guess is worse
		// than one that reports how much it could not see.
		s.AdmissionLost++
		return
	}
	s.eligibleScored++
	s.OfferedInputTokens += int64(r.EstInputTokens)
	if !shedByAdmission(r) {
		s.AdmittedInputTokens += int64(r.EstInputTokens)
	}
	switch {
	case r.ExactInputTokens <= 0:
		s.ExactTokensMissing++
	case r.EngineInputTokens > 0 && r.EngineInputTokens != r.ExactInputTokens:
		s.ExactTokensContradicted++
	default:
		s.OfferedExactTokens += int64(r.ExactInputTokens)
		if !shedByAdmission(r) {
			s.AdmittedExactTokens += int64(r.ExactInputTokens)
		}
	}
}

// tallyEngineInputTokens records one row's engine-reported input-token count against its tenant.
//
// Unconditional, and deliberately OUTSIDE the eligible-population guard its caller applies to the
// admitted-work tallies. This is the only tally whose population is every request the trace offered, and
// that is the whole point: the eligible population is what the admission guard gated, and the declared load
// is what the registration froze. Scoring the second over the first silently drops the premium tier.
//
// The nil-map checks live here rather than at the call site because Summarize's row loop sits at the
// complexity ceiling -- one more `if` in it has already turned `make lint` red once.
func (s *ArmSummary) tallyEngineInputTokens(r RawRow) {
	if r.EngineInputTokens <= 0 {
		// Not a zero-token prompt: a row the engine never answered, or answered without usage accounting.
		// Counted apart from the agreeing rows, because a gate must not call such a population verified.
		s.EngineInputTokensUnreportedByTenant[r.Tenant]++
		return
	}
	seen := s.EngineInputTokensByTenant[r.Tenant]
	if seen == nil {
		seen = map[int]int{}
		s.EngineInputTokensByTenant[r.Tenant] = seen
	}
	seen[r.EngineInputTokens]++
}

// tallyDelivered adds one row's delivered output to the arm's totals, appending its inter-token time.
//
// Split out of Summarize only to keep that function under the complexity limit; it is one step of the same
// loop and holds no state of its own.
func (s *ArmSummary) tallyDelivered(r RawRow, tpot []float64, byTenant map[string][]float64) []float64 {
	// Tokens count only where a response actually produced them; a refusal carries none, and a stream that
	// died partway delivered nothing the client could use.
	if r.OutputTokens <= 0 || r.HTTPStatus != 200 {
		return tpot
	}
	s.OutputTokens += int64(r.OutputTokens)
	if s.OutputTokensByTenant == nil {
		s.OutputTokensByTenant = map[string]int64{}
	}
	s.OutputTokensByTenant[r.Tenant] += int64(r.OutputTokens)
	// A stream that broke partway is not a measurement of inter-token time.
	//
	// The sender keeps HTTPStatus at 200 for these, because the response headers did arrive, and records
	// the failure in ErrorKind instead. EndUnixNanos is then the moment the stream died -- for a timeout,
	// the deadline -- so (end - firstToken) / (tokens - 1) reports the deadline divided by a token count.
	// A 30-second timeout after two tokens enters the tail as a 30,000 ms inter-token time.
	//
	// That matters because reading 1 fails a cell whose TPOT p99 exceeds 1.25x the isolated baseline, so
	// admitting deadlines would fail whichever arm timed out most on a statistic that never described its
	// streams.
	if r.ErrorKind != "" {
		s.OutputTokensFromFailedStreams += int64(r.OutputTokens)
		if s.OutputTokensFromFailedStreamsByTenant == nil {
			s.OutputTokensFromFailedStreamsByTenant = map[string]int64{}
		}
		s.OutputTokensFromFailedStreamsByTenant[r.Tenant] += int64(r.OutputTokens)
		return tpot
	}
	// Inter-token time needs at least two tokens to have a gap between them.
	if r.OutputTokens > 1 && r.FirstTokenUnixNanos > 0 && r.EndUnixNanos > r.FirstTokenUnixNanos {
		v := nanosToMs(r.EndUnixNanos-r.FirstTokenUnixNanos) / float64(r.OutputTokens-1)
		tpot = append(tpot, v)
		byTenant[r.Tenant] = append(byTenant[r.Tenant], v)
	}
	return tpot
}

// SetActiveSeconds records the arm's active wall clock and derives the throughput from it.
//
// The division lives here and nowhere else so that a caller correcting the span for pooled repetitions
// cannot end up with a rate computed from one number and a span printed from another.
func (s *ArmSummary) SetActiveSeconds(seconds float64) {
	s.ActiveSeconds = seconds
	s.OutputTokensPerSecond = 0
	if seconds > 0 {
		s.OutputTokensPerSecond = float64(s.OutputTokens) / seconds
	}
}

// FormatReport renders the summaries and checks as a plain-text report.
//
// It states explicitly when the comparison is invalid (admission match missed) or the tail is censored, so a reader is never handed a clean-looking number that the methodology already disqualified.
// FormatReport renders the measurements, and the criteria only when there were criteria.
//
// checks is a POINTER because "not evaluated" has to be unrepresentable as a zero value. It used to be
// passed by value, and a study whose readings are not implemented was handed an empty Checks{} -- which
// rendered as three lines of `0.000 FAIL` under the heading "Pre-registered checks", followed by
// "VERDICT: not all checks passed". Nothing had been evaluated. The caller was careful and said so on
// stderr, and the page still printed a verdict a skimming reader would take for the study's result.
// A nil pointer cannot be mistaken for a run that failed everything.
// medianOf is the registered median convention: the mean of the two central order statistics for an even
// count, which the design spec's third 2026-09-30 amendment froze "because it makes B and C continuous in
// the observations; taking the lower of the two would bias both arms downward by an amount that depends on
// the spread".
func medianOf(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// formatOfferedLoad renders the per-tenant offered prompt length, as a mean of the estimator's own unit.
//
// Over the UNION of tenants across arms, not the first arm that has any.
//
// The first version took the first arm carrying the map, on the argument that every arm of a frozen matrix
// replays the same premium trace so one arm's figure is the run's. That argument is true for premium and
// silently wrong for the contender: the ISOLATED arm has no contender at all, R1 sorts first, and the line
// printed "premium-1 294 tok" while the contender's 10,645 -- half the prefill work on the card -- was
// missing from a line whose whole job is to say what load was offered.
//
// A tenant whose arms disagree is shown as a RANGE rather than averaged away. Two arms of a frozen matrix
// are supposed to offer the same prompts; if they did not, that is the thing this line exists to surface.
func formatOfferedLoad(summaries []ArmSummary) string {
	means := map[string][]int64{}
	for _, s := range summaries {
		for t, sum := range s.EstInputTokensByTenant {
			if offered := s.DispositionByTenant[t].Offered; offered > 0 {
				means[t] = append(means[t], sum/int64(offered))
			}
		}
	}
	if len(means) == 0 {
		return ""
	}
	tenants := make([]string, 0, len(means))
	for t := range means {
		tenants = append(tenants, t)
	}
	sort.Strings(tenants)
	parts := make([]string, 0, len(tenants))
	for _, t := range tenants {
		v := means[t]
		lo, hi := v[0], v[0]
		for _, x := range v {
			if x < lo {
				lo = x
			}
			if x > hi {
				hi = x
			}
		}
		if lo == hi {
			parts = append(parts, fmt.Sprintf("%s %d tok", t, lo))
			continue
		}
		parts = append(parts, fmt.Sprintf("%s %d-%d tok (ARMS DISAGREE)", t, lo, hi))
	}
	return "offered prompt length (estimated): " + strings.Join(parts, " / ") + "\n\n"
}

func FormatReport(summaries []ArmSummary, checks *Checks, matchTolerance float64) string {
	var b strings.Builder
	b.WriteString("M5-b benchmark report\n\n")
	// reps is printed for the same reason tailN is. The incremental interval below is a bootstrap over
	// REPETITIONS -- BootstrapCI resamples whole repetitions, so the repetition count IS the n of the only
	// interval this study reports. Without it on the page, a CI built from two blocks is typographically
	// indistinguishable from one built from four, and the two mean very different things: with two blocks
	// the nearest-rank 2.5/97.5 percentiles land on the smaller and larger of exactly two numbers, so the
	// printed interval is their range and not a 95% interval at all.
	//
	// A reader who cannot see the block count has no way to tell those apart, which is the same defect the
	// tailN column exists to prevent one level down.
	// The LOAD, printed before the numbers it produced.
	//
	// Without this line two runs of this study are typographically identical on the page while having sent
	// prompts 5.9x apart -- which is how a 27.2x and a 23.0x came to sit in two documents as though they
	// were the same measurement. Estimated tokens rather than characters because the estimator
	// (ceil(chars/4)) has no inverse: 294 tokens is what the arm actually offered, and it is what
	// distinguishes the two runs.
	if load := formatOfferedLoad(summaries); load != "" {
		b.WriteString(load)
	}
	fmt.Fprintf(&b, "%-*s %8s %8s %8s %8s %8s %8s %8s %8s %8s\n", ArmColumnWidth, "arm", "total", "done", "shed", "timeout", "ttftP50", "ttftP95", "ttftP99", "tailN", "reps")
	for _, s := range summaries {
		censored := ""
		if s.Censored {
			censored = " (p99 censored: >1% timeouts, lower bound)"
		}
		// tailN is printed because the p99 beside it is meaningless without it, and because a reader who
		// cannot see the sample count has no way to tell a tail from a maximum.
		thin := ""
		if s.TailSampleSize > 0 && s.TailSampleSize < MinTailSamples {
			thin = fmt.Sprintf(" (p99 is the maximum: %d < %d premium completions)", s.TailSampleSize, MinTailSamples)
		}
		fmt.Fprintf(&b, "%-*s %8d %8d %8d %8d %8.1f %8.1f %8.1f %8d %8d%s%s\n",
			ArmColumnWidth, s.Arm, s.Total, s.Completed, s.Rejected, s.TimedOut, s.TTFTMsP50, s.TTFTMsP95, s.TTFTMsP99, s.TailSampleSize, s.RepetitionCount, censored, thin)
	}
	// What the protection cost, printed beside what it bought.
	//
	// Every check below is a TTFT ratio, and the paid run showed that is half an answer: the arm that held
	// the tail best also served the fewest tokens, because it was discarding one tenant's work rather than
	// making the engine efficient. An arm's throughput and its tenants' shares belong next to its tail.
	// EVERY per-repetition p99, because the registration demands it and a pooled tail hides its sample.
	//
	// The design spec's third 2026-09-30 amendment fixes the reported object as the ratio of MEDIAN
	// per-repetition victim TTFT p99s, and says of the interval: "The report this points at must publish
	// every per-repetition p99 so a reader can see the sample it came from." Nothing printed them. The
	// values existed -- RepetitionTTFTMsP99 is filled by the caller and read by repetitionSpread for a
	// range check -- and went no further than that check.
	//
	// Without this block a reader sees one number per arm and cannot tell five tight repetitions from five
	// scattered ones, which is the whole difference between a measurement and an anecdote. It also makes
	// the registered estimand computable from the page: the median of this row IS baselineP99Ms.
	if any := func() bool {
		for _, s := range summaries {
			if len(s.RepetitionTTFTMsP99) > 0 {
				return true
			}
		}
		return false
	}(); any {
		b.WriteString("\nPer-repetition premium TTFT p99 (ms) -- the sample behind each tail above\n")
		for _, s := range summaries {
			if len(s.RepetitionTTFTMsP99) == 0 {
				continue
			}
			parts := make([]string, 0, len(s.RepetitionTTFTMsP99))
			for _, v := range s.RepetitionTTFTMsP99 {
				parts = append(parts, fmt.Sprintf("%.3f", v))
			}
			med := medianOf(s.RepetitionTTFTMsP99)
			fmt.Fprintf(&b, "%-*s %s   median %.3f\n", ArmColumnWidth, s.Arm, strings.Join(parts, "  "), med)
		}
		b.WriteString("  The median of each row is this arm's registered point estimate. A ratio of two medians\n")
		b.WriteString("  is the registered object; the spread of a row is an OBSERVED RANGE and not an interval.\n")
	}

	// B, C and R themselves, because the block above made them derivable and left the arithmetic to the
	// reader. The amendment names the three fields it freezes, and a page that prints the sample but not the
	// estimand still has nobody computing what the registration decided.
	b.WriteString(FormatRegisteredEstimand(summaries))

	b.WriteString("\nWhat it cost\n")
	// premTPOT99 is printed beside the arm-wide figure because the pre-registered criterion is about the
	// PROTECTED tenant's stream, and the arm-wide number pools every tenant. On the paid evidence they
	// differ by 57 ms on one arm, which is the difference between quoting the right tenant and the wrong one.
	fmt.Fprintf(&b, "%-*s %10s %10s %10s %10s %10s\n", ArmColumnWidth,
		"arm", "out tok/s", "tpotP50", "tpotP99", "premTPOT99", "tenant shares")
	for _, s := range summaries {
		shares := make([]string, 0, len(s.OutputTokensByTenant))
		names := make([]string, 0, len(s.OutputTokensByTenant))
		for n := range s.OutputTokensByTenant {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			if s.OutputTokens > 0 {
				shares = append(shares, fmt.Sprintf("%s %.0f%%", n, 100*float64(s.OutputTokensByTenant[n])/float64(s.OutputTokens)))
			}
		}
		prem := "—"
		if v, ok := s.TPOTMsP99ByTenant[PremiumTenant]; ok {
			prem = fmt.Sprintf("%.1f", v)
		}
		fmt.Fprintf(&b, "%-*s %10.1f %10.1f %10.1f %10s  %s\n",
			ArmColumnWidth,
			s.Arm, s.OutputTokensPerSecond, s.TPOTMsP50, s.TPOTMsP99, prem, strings.Join(shares, " · "))
	}

	// The threshold's own evidence, printed before the checks because it qualifies them: the checks compare
	// arms, and this says whether the number those arms were configured with did any work at all.
	probed := false
	for _, sm := range summaries {
		if len(sm.ThresholdProbe) > 0 {
			probed = true
			break
		}
	}
	unevaluated := false
	if probed {
		b.WriteString("\nEligibility threshold (probe tenants, four characters apart)\n")
		for _, sm := range summaries {
			names := make([]string, 0, len(sm.ThresholdProbe))
			for n := range sm.ThresholdProbe {
				names = append(names, n)
			}
			sort.Strings(names)
			for _, n := range names {
				o := sm.ThresholdProbe[n]
				void := ""
				if o.Unevaluated > 0 {
					unevaluated = true
					void = fmt.Sprintf("  VOID: %d never reached admission (401/403)", o.Unevaluated)
				}
				fmt.Fprintf(&b, "  %-*s %-22s est=%d  sent=%d  rejected=%d%s\n", ArmColumnWidth, sm.Arm, n, o.EstInputTokens, o.Total, o.Rejected, void)
			}
		}
		if unevaluated {
			b.WriteString("  VOID: the gateway turned these probes away on credentials, so the threshold never judged them\n")
			b.WriteString("  and rejected=0 above is the absence of a measurement rather than the threshold letting them\n")
			b.WriteString("  through. This run does not evidence the configured threshold.\n")
		} else {
			b.WriteString("  the estimate is what the threshold compares; the measured real cost of these prompts is\n")
			b.WriteString("  about 3171 tokens, so a rejection here fires on an over-estimate of roughly 29 percent\n")
		}
	} else {
		b.WriteString("\nEligibility threshold: NOT TESTED -- no probe tenant straddled it, so any threshold in a wide\n")
		b.WriteString("  range would have produced these same arms. The configured value is not evidenced by this run.\n")
	}

	if checks == nil {
		// No heading that looks like a results table, and no VERDICT line. The measurements above stand on
		// their own; what must not happen is a reader coming away with a judgement nobody made.
		// Deliberately says nothing about whether the study has criteria of its own. The three checks below
		// are M5-b's, and a study that does not use them may still have readings, which are rendered
		// separately by FormatPriceOfProtection. Claiming here that a run was not evaluated would be the
		// same defect one level along.
		b.WriteString("\nPre-registered checks: NOT APPLICABLE. The three checks above this line are the M5-b\n")
		b.WriteString("  gateway study's, and this evidence is not from it. Nothing here is a verdict on these arms.\n")
		return b.String()
	}

	b.WriteString("\nPre-registered checks (primary endpoint: TTFT p99)\n")
	fmt.Fprintf(&b, "  absolute protection  C/R1 = %.3f  (<= 1.25)  %s\n", checks.AbsoluteProtectionRatio, pass(checks.AbsoluteProtectionPass))
	fmt.Fprintf(&b, "  incremental value    C/B  = %.3f  CI[%.3f, %.3f]  (<= 0.90, CI hi < 1.0)  %s\n",
		checks.IncrementalRatio, checks.IncrementalRatioCI.Lo, checks.IncrementalRatioCI.Hi, pass(checks.IncrementalValuePass))
	if checks.AdmissionNotEvaluable {
		// A numeric delta here would be read as a measurement. There is none: the exact-token accounting the
		// criterion is defined over could not supply one.
		fmt.Fprintf(&b, "  admission match      NOT EVALUABLE in exact tokens  (estimate-weighted |B-C|/C = %.3f, not the criterion)\n", checks.EstimateWeightedDelta)
	} else {
		fmt.Fprintf(&b, "  admission match      |B-C|/C = %.3f  (<= %.3f)  %s  (estimate-weighted %.3f)\n",
			checks.AdmissionMatchDelta, matchTolerance, pass(checks.AdmissionMatchPass), checks.EstimateWeightedDelta)
	}
	if checks.Invalid {
		fmt.Fprintf(&b, "  RUN INVALID: %s\n", checks.InvalidReason)
	}
	b.WriteString("\n")
	switch {
	case checks.Invalid:
		b.WriteString("VERDICT: run invalid; no protection claim is made from this evidence.\n")
	case checks.OverallPass:
		b.WriteString("VERDICT: all checks passed; the guard protects the premium tenant's tail beyond load shedding.\n")
	default:
		b.WriteString("VERDICT: not all checks passed; the word \"protects\" is not used for this run.\n")
	}
	return b.String()
}

// pass renders a boolean as a short marker for the report.
func pass(ok bool) string {
	if ok {
		return "PASS"
	}
	return "FAIL"
}

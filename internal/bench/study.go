package bench

import (
	"fmt"
	"slices"
)

// A Study is one pre-registered experiment: the arms it admits, and the order a report prints them in.
//
// Arm names used to live in one closed map shared by every experiment this repository runs, which was
// fine while there was one experiment. It stops being fine the moment a second one wants a name the
// first already used. M5-b's "off" was the gateway with its admission guard disabled. The
// price-of-protection run's control is the engine at its own default batch budget with no gateway in
// the path at all. Those are different conditions that would produce comparable-looking rows, and the
// pre-registration's own wording invites the confusion by calling the new control "off" as well.
//
// So an arm belongs to a study, the study travels with the evidence, and a report refuses to pool rows
// from two of them. Guarding by name would only work until someone picked a name that collided.
type Study struct {
	// ID is the immutable identifier raw evidence carries.
	//
	// Changing it orphans every record already written, so it is dated rather than versioned by
	// meaning: a study that needs different arms is a different study.
	ID string
	// Arms are the canonical arm names, in the order a report prints them.
	//
	// Order is a property of the study rather than of the names. The price-of-protection sweep wants
	// its isolated ceiling and its control first and its eight cells after, which no sort of those
	// strings produces.
	Arms []string
	// Arrivals is the arrival model the study's pre-registration fixed, or empty where none was registered.
	//
	// Two ladders can carry the same arm names, criterion and rungs and differ only in how their traces were
	// generated, and nothing in a trace file says which. So the model is recorded here, gen-trace refuses
	// flags of the other model for a study that declares one, and hack/m5c-matrix.sh asks this registry
	// rather than keeping a second copy of the answer in a shell variable.
	Arrivals ArrivalModel

	// Frozen is the load tuple the study's pre-registration fixed, or nil where none was frozen.
	//
	// Recorded here for the reason Arrivals is: the registration says these five values are frozen and
	// nothing in the runner compared them, so a paid run could offer any load and file it under this study.
	// Measured on 2026-10-02: four frozen quantities passed the pre-purchase plan check unchanged
	// (premium 200, contender 40000, timeout 30000, caps 8/4), and the CR path enforced only the two
	// lengths -- timeoutMs and both caps came straight from the CR with no comparison at all.
	//
	// The CHARACTERS are stored, not the token counts they were resolved from. Resolving at run time would
	// mean the frozen value follows whatever the resolution table last returned, which is the opposite of
	// freezing: the registration's promise is "the resolved characters are now frozen rather than whatever
	// the resolver last returned". FrozenTuple.Drift compares the two and reports the difference instead.
	Frozen *FrozenTuple

	// FixesOutputAtCap says every request of the study must produce exactly its output cap.
	//
	// The prospective-admission pilot needs it so that a short completion is a failure rather than output
	// silently deleted (design page, "Load"); gen-trace sets each row's MinOutputTokens to its cap, which
	// the trace's checksum then covers. It is a study property rather than a flag, so a trace of that study
	// cannot be generated without it.
	FixesOutputAtCap bool

	// RecordsReplayTiming makes the replay stamp its origin and each request's return on every row, and refuse
	// to run without a request-ID prefix: the pilot joins its rows to the gateway's record by ID, and computes
	// dispatch lag and the processing window from these stamps.
	RecordsReplayTiming bool

	// SenderPoolSize, when set, replaces the pool PoolSizeForTrace derives from each arm's own trace, and the
	// replay refuses any connection mode but pooled.
	//
	// A derived pool differs between a block's arms: the isolation arm's trace has no contenders, so at the
	// pilot's rates it gets about 278 idle connections against the others' 293. The pilot compares its arms'
	// sender configurations and refuses a difference (design page, build item 26), so its pool is one number
	// for every arm, at least the open-loop ceiling of rate × timeout.
	SenderPoolSize int

	// FrozenExactTokens maps each prompt length the study sends, in characters, to the engine's own input-token
	// count for it. gen-trace stamps every row from it and the replay refuses a row that disagrees, so no arm sends
	// a calibration probe; hack/m5c-matrix.sh checks it against the live engine once per session, after the first
	// cell's step log is captured, with requests whose IDs every measurement excludes (design page, build item 18).
	FrozenExactTokens map[int]int

	// MinRepetitions is the fewest repetitions per arm this study's registration permits, or 0 where it
	// registered none.
	//
	// WHY A STUDY AND NOT A CONSTANT. The CRD's own floor is five and api/v1 states its reason in the field
	// comment: "At least five: a p99 from three repetitions is noise, and the report is a median-of-runs
	// WITH A BOOTSTRAP INTERVAL rather than a best run." That reason is about the report's shape. A study
	// that publishes no interval does not inherit it, and forcing five on an exploratory question buys cells
	// to support a statistic the registration refuses to present. Measured 2026-10-04: at the 11.61 min/cell
	// mean, the 2026-10-03 registration's design needs 16 cells at two repetitions and 40 at five, and 40
	// cells is 464.4 minutes against a 280-minute window -- so the floor decides whether the question can be
	// asked at all, which is exactly the kind of decision that belongs in a registration rather than in a
	// shared constant.
	//
	// The shell has NO floor of its own (`REPS="${REPS:-4}"`), and hack/m5c-gpu-session.sh's own comment says
	// "a pilot is REPS=1 and a confirmatory run is REPS=3" while the CRD demands five. internal/bench/plan.go
	// already records that disagreement in a comment. This field is where it stops being a disagreement: the
	// number comes from the study the evidence is filed under, one place, named.
	MinRepetitions int

	// PublishesInterval says whether this study's registration presents an interval on its estimand.
	//
	// It is the companion of MinRepetitions rather than a duplicate of it, because the two can disagree and
	// the disagreement is the bug worth refusing: a study that publishes an interval while permitting two
	// repetitions would print bounds that are just its two observations. Measured 2026-10-04, calling the
	// three interval functions with two values: BootstrapCI returned Lo=3998.000 Hi=4001.000 and
	// PairedRatioCI returned Lo=22.8629 Hi=22.9770, both with an EMPTY InvalidReason -- each refuses only at
	// n==1. A two-point bootstrap has four distinct resamples, so those bounds are the observations
	// themselves, which the 2026-10-03 registration distinguishes in its own words: "the spread of a row is
	// an OBSERVED RANGE and not an interval".
	//
	// ⚠️ It does NOT today gate a publication path, and saying so is the point. FormatRegisteredEstimand
	// prints "No interval is published; see the seventh amendment" and RegisteredEstimand.RatioCI is computed
	// and never rendered; the one interval that does reach a report, Checks.IncrementalRatioCI, belongs to the
	// M5-b gateway study and its arms rather than to repetitions. So this field records what each
	// registration promises and lets a refusal compare the two numbers. A future path that renders an
	// interval has to read it; a path that renders none cannot be made correct by it.
	PublishesInterval bool

	// TracesVaryByRepetition says each repetition replays its own trace, generated from its own seed.
	//
	// Every archive before 2026-10-04 replayed one trace, seed 11, in every repetition, so the spread across
	// repetitions measured the engine on one draw of the arrival process and said nothing about the draw.
	// The model-first registration of that date showed why that matters at low contending load: whether a
	// trace's p99 is 70 ms or 600 ms depends on whether two latency-critical arrivals landed inside one
	// best-effort prefill. A study with this set is refused if two repetitions of an arm share a trace, and
	// its baseline and contended arm are paired by repetition on the latency-critical schedule instead.
	TracesVaryByRepetition bool
}

// FrozenTuple is the five load quantities a pre-registration can freeze.
//
// Five, not four. The output caps are two fields and counting them as one is how a check gets written for
// four of them -- named here so the count is in the type rather than in prose.
type FrozenTuple struct {
	// PremiumPromptChars and ContenderPromptChars are CHARACTERS, as the generator is configured.
	PremiumPromptChars   int
	ContenderPromptChars int
	// PremiumInputTokens and ContenderInputTokens are the declared counts those characters were resolved
	// FROM, kept so a drift between the frozen characters and the current resolution table is reportable.
	PremiumInputTokens    int
	ContenderInputTokens  int
	TimeoutMs             int
	PremiumOutputTokens   int
	ContenderOutputTokens int
}

// Drift names a frozen length whose declared token count no longer resolves to it, or "".
//
// This does NOT update anything. A table that has moved under a frozen registration is a fact a reader has
// to be told, and silently adopting the new number would retire the registration without saying so.
func (f FrozenTuple) Drift() string {
	for _, c := range []struct {
		side   string
		tokens int
		chars  int
	}{
		{"premium", f.PremiumInputTokens, f.PremiumPromptChars},
		{"contender", f.ContenderInputTokens, f.ContenderPromptChars},
	} {
		if c.tokens == 0 {
			continue
		}
		r, ok := ResolveInputTokens(c.tokens)
		if !ok {
			return fmt.Sprintf("%s: the frozen tuple declares %d input tokens and the resolution table no longer carries that count", c.side, c.tokens)
		}
		if r.Chars != c.chars {
			return fmt.Sprintf("%s: the registration froze %d characters for %d tokens and the table now resolves that count to %d", c.side, c.chars, c.tokens, r.Chars)
		}
	}
	return ""
}

// ArrivalModel names how a study's traces assign arrival times, which decides the gen-trace flags that may build them.
type ArrivalModel string

const (
	// ArrivalsWeighted draws every gap at one total rate and picks each arrival's tenant by weight.
	ArrivalsWeighted ArrivalModel = "weighted"
	// ArrivalsIndependent gives each tenant its own Poisson process keyed by its name; see TenantSpec.RatePerSec.
	ArrivalsIndependent ArrivalModel = "independent"
	// ArrivalsEpisodes sends registered episodes into a drained engine; see GenerateEpisodeTrace.
	// It has no rate at all, so gen-trace refuses every rate, weight and per-tenant shape flag for a study that declares it.
	ArrivalsEpisodes ArrivalModel = "episodes"
)

const (
	// StudyM5BGateway is the four-condition gateway experiment M5-b measured: an isolated baseline, the
	// guard disabled, a static admission cap, and the KV-occupancy guard.
	//
	// Evidence written before studies existed carries no identifier at all, and is read as this one.
	StudyM5BGateway = "m5b-gateway-v1"
	// StudyPriceOfProtection is the engine-configuration sweep pre-registered in
	// docs/superpowers/specs/2026-09-05-the-price-of-protection.md.
	//
	// No gateway is in the path. The factors are vLLM's batch budget and its scheduling policy.
	StudyPriceOfProtection = "price-of-protection-2026-09-05"
	// StudySharingMatrix is the M5-c topology matrix pre-registered in
	// docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md.
	//
	// Its arms are TOPOLOGIES, not admission modes, and giving it a study of its own is what lets the report
	// tell them apart. hack/m5c-matrix.sh used to replay every arm as "off" -- the admission vocabulary's
	// name for a disabled guard -- because that was the only arm name the harness would accept for it, and
	// it then had to ship a README telling readers never to run `benchharness report` over the evidence,
	// since pooling would collapse three topologies into one row. Evidence that has to arrive with a warning
	// against using the tool that reads it is evidence one step from being read wrong.
	StudySharingMatrix = "sharing-matrix-2026-09-10"
	// StudyThroughputLadder is the capacity ladder pre-registered in
	// docs/superpowers/specs/2026-09-13-what-the-split-costs-in-throughput.md.
	//
	// It measures the same two topologies as StudySharingMatrix at four offered premium loads, and it is a
	// separate study rather than more repetitions of that one for a reason worth stating: repetitions of the
	// sharing matrix are POOLED, and pooling two different offered loads into one arm summary would produce
	// a p99 for a load that was never offered. Its arm names carry the rung for the same reason -- see
	// ThroughputLadderArm.
	StudyThroughputLadder = "throughput-ladder-2026-09-13"
	// StudyThroughputLadderDown is the second capacity ladder, pre-registered in
	// docs/superpowers/specs/2026-09-13-the-ladder-has-to-search-downward.md.
	//
	// Same arms, same criterion, same readings, different RUNGS: the first ladder climbed from the load the
	// sharing matrix answered, and both topologies already missed the target there by a factor of seven, so
	// it could return nothing but "no qualified operating point at or above the bottom rung". This one places
	// its rungs BELOW that load.
	//
	// A separate study rather than new rungs on the old one for the reason the old one's arm names carry
	// their rung: rung01 means a different offered load in each, and evidence that pooled them would report a
	// p99 for a load nobody offered. The trace-identity refusal would also catch it, but a refusal is not the
	// same as a reader being able to tell two experiments apart.
	StudyThroughputLadderDown = "throughput-ladder-down-2026-09-13"
	// StudyThroughputLadderIndependent is the downward ladder's rungs re-registered under independent
	// arrivals, in docs/superpowers/specs/2026-09-15-a-ladder-whose-contender-holds-still.md.
	//
	// The down ladder solved a contender weight for every rung to hold 139 offers, and the count held while the
	// contender's SCHEDULE changed at every rung, so a rung-to-rung comparison moved two things at once. Here
	// the contender's rows are byte-identical at every rung. It is a separate study because its rung01 trace is
	// not the down ladder's rung01 trace, and pooling the two would report a p99 over two contender schedules.
	StudyThroughputLadderIndependent = "throughput-ladder-independent-2026-09-15"
	// StudyTailCrossingShortLC and StudyTailCrossingLongLC are the two input levels pre-registered in
	// docs/superpowers/specs/2026-10-03-where-the-latency-sensitive-tail-crosses-each-multiple-exploratory.md.
	//
	// TWO STUDIES AND NOT TWO ARMS, for the reason the three ladders give: Study.Frozen is one tuple per
	// study, so a single study cannot declare two latency-critical prompt lengths, and reading 4e holds the
	// engine's reported input-token count against exactly one declared value. Pooling the two levels into
	// one study would also produce a p99 over two prompt lengths -- a statistic for a condition that was
	// never offered, which is the defect the down ladder was split off to avoid.
	//
	// The short level repeats StudySharingMatrix's frozen latency-critical length rather than inventing one,
	// so the two levels differ in that length and in nothing else. Both inherit TimeoutMs 60000: the
	// registration's item 8 records why, and that the inheritance may censor the long level's tail and make
	// the estimand refuse -- a registered outcome of that page, not a defect to work around here.
	//
	// The arrival model IS registered, as independent, and the reason is the design rather than the code.
	// docs/superpowers/specs/2026-10-04-is-length-a-separate-term-in-the-placement-rule-model-first.md
	// replaced the 2026-10-03 design: the latency-critical rate is held and the best-effort rate swept, and a
	// weighted mix draws both tenants from one stream, so every BE level would also have moved the LC
	// arrival times. Independent arrivals keep a repetition's LC schedule identical at every BE level and in
	// the baseline. Until that page, this comment recorded the field as deliberately unset.
	StudyTailCrossingShortLC = "tail-crossing-lc256-2026-10-04"
	StudyTailCrossingLongLC  = "tail-crossing-lc8192-2026-10-04"
	// StudyTailCrossingMidLC is a third input level, 2,048 tokens, registered on 2026-10-05 after the first
	// two were measured, as the out-of-sample test of their result: that the best-effort load a latency-
	// critical tenant tolerates is set by the contender's prefill time and the tenant's own isolated tail,
	// with no separate term for its length. Its curve is predicted by the model and committed before any
	// cell is bought; see the 2026-10-04 model-first registration's amendment of that date.
	StudyTailCrossingMidLC = "tail-crossing-lc2048-2026-10-05"
	// StudyInstrumentValidation is the instrument check registered in
	// docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md.
	//
	// It asks whether the stock engine's iteration log can time a step, so its arms are an episode type crossed with the engine's logging and scheduling mode rather than a load.
	// One tenant, no contender: attribution by order needs every step's composition known by construction.
	StudyInstrumentValidation = "instrument-validation-2026-10-05"
	// StudyInstrumentValidationS2 is the second instrument check, registered in
	// docs/superpowers/specs/2026-10-05-instrument-validation-session-2.md after session 1 failed I1 and I3.
	//
	// A study of its own rather than more blocks of the first, because its episodes differ: held-out serial lengths, a later and jittered stagger trigger, longer decoders and other replicate counts.
	// Pooling the two would score one trace's settings against the other's, and session 1's verdict has to stand on its own evidence.
	StudyInstrumentValidationS2 = "instrument-validation-s2-2026-10-05"
	// StudyInstrumentValidationS3 is the third instrument check, registered in
	// docs/superpowers/specs/2026-10-06-instrument-validation-session-3.md after gate S stopped session 2.
	//
	// A study of its own because its staggered decoders run under different termination semantics, so session 2's three cells are not pooled with it.
	StudyInstrumentValidationS3 = "instrument-validation-s3-2026-10-06"
	// StudyInstrumentValidationS4 is the fourth instrument check, registered in
	// docs/superpowers/specs/2026-10-06-instrument-validation-session-4.md after gate W stopped session 3.
	//
	// A study of its own because its warm-up holds one more request, so its cells were conditioned differently from session 3's seven and are not pooled with them.
	StudyInstrumentValidationS4 = "instrument-validation-s4-2026-10-06"
	// StudyStepBoundary is the step-boundary session, registered in
	// docs/superpowers/specs/2026-10-06-where-the-late-prefill-waits-step-boundary-session.md.
	//
	// A study of its own because its engine carries a new instrument (hack/vllm-plugins/step_logging_scheduler.py),
	// so nothing it measures is pooled with the instrument-validation sessions; its episodes are session 4's.
	StudyStepBoundary = "step-boundary-2026-10-06"
	// StudyStepConfirm confirms the step-time model S1 on settings it never saw, designed in
	// docs/superpowers/specs/2026-10-07-confirming-s1-on-unseen-settings-design.md.
	//
	// A study of its own because its episodes are new settings: the step-boundary study's engine and instrument, a
	// different design, and only the instrumented arms, since the instrument's overhead was established there.
	StudyStepConfirm = "step-confirm-2026-10-07"
	// StudyProspectivePilot is the measurement pilot of prospective admission, scoped in
	// docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md ("The measurement pilot").
	//
	// A study of its own because it measures the apparatus, not the mechanism: it produces no verdict about P
	// against S, and the main study's data are never pooled with it.
	StudyProspectivePilot = "prospective-pilot-2026-10-08"

	// StudyAdmissionDiagnostic is the diagnostic of the engine's per-step prefill cap with the gateway's
	// serial-prefill hold, docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "v25". It
	// shares the pilot's load, lengths, engine and capture, and adds the hold, cap and hold-cap arms.
	StudyAdmissionDiagnostic = "admission-diagnostic-2026-10-10"

	// StudyAdmissionFrontier is v26: hold-cap against a frozen frontier of fixed spacings, each judged on the card by
	// the owner's contender limits, docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md,
	// "v26". It shares the diagnostic's load, lengths, engine and capture; its controls are the gateway's
	// fixed-spacing mode at four spacings, all capped at 384 as hold-cap is.
	StudyAdmissionFrontier = "admission-frontier-2026-10-10"
)

// ArmProspective is the prospective-admission arm; the pilot's other arms reuse the M5-b names.
const ArmProspective = "prospective"

// The engine modes the instrument-validation study crosses with its episode types.
// The on and off arms are I1's paired controls, and the async arm is the published-only control the registration says is never used to fit anything.
const (
	instrumentModeLog   = "log"
	instrumentModeNoLog = "nolog"
	instrumentModeAsync = "async"
	// instrumentModeStep is the logged engine with the step-boundary instrument loaded.
	instrumentModeStep = "step"
)

// InstrumentValidationArm is the canonical name of one cell: an episode type under one engine mode.
func InstrumentValidationArm(t EpisodeType, mode string) string {
	return string(t) + "-" + mode
}

// instrumentValidationArms lists the six sync cells by episode type and then the three async cells, the order the registration buys them.
func instrumentValidationArms() []string {
	arms := make([]string, 0, 3*len(EpisodeTypes))
	for _, t := range EpisodeTypes {
		arms = append(arms, InstrumentValidationArm(t, instrumentModeLog), InstrumentValidationArm(t, instrumentModeNoLog))
	}
	for _, t := range EpisodeTypes {
		arms = append(arms, InstrumentValidationArm(t, instrumentModeAsync))
	}
	return arms
}

// stepBoundaryArms lists the step-boundary session's five arms: serial and burst as logged/instrumented pairs,
// whose difference is the instrument's overhead, and staggered instrumented alone, since that comparison could not
// be powered and the registration declares its staggered results to concern the instrumented engine only.
// stepConfirmArms lists the confirmation's three arms, one per episode type, all instrumented.
func stepConfirmArms() []string {
	return []string{
		InstrumentValidationArm(EpisodeSerial, instrumentModeStep),
		InstrumentValidationArm(EpisodeBurst, instrumentModeStep),
		InstrumentValidationArm(EpisodeStagger, instrumentModeStep),
	}
}

func stepBoundaryArms() []string {
	return []string{
		InstrumentValidationArm(EpisodeSerial, instrumentModeLog), InstrumentValidationArm(EpisodeSerial, instrumentModeStep),
		InstrumentValidationArm(EpisodeBurst, instrumentModeLog), InstrumentValidationArm(EpisodeBurst, instrumentModeStep),
		InstrumentValidationArm(EpisodeStagger, instrumentModeStep),
	}
}

// InstrumentValidationEpisode returns the episode type an instrument-validation arm replays.
//
// Only the type is returned, never the mode, because the generator must not see the mode: the three arms of one type are paired on byte-identical traces.
func InstrumentValidationEpisode(arm string) (EpisodeType, bool) {
	for _, t := range EpisodeTypes {
		for _, m := range []string{instrumentModeLog, instrumentModeNoLog, instrumentModeAsync, instrumentModeStep} {
			if arm == InstrumentValidationArm(t, m) {
				return t, true
			}
		}
	}
	return "", false
}

// The factors the price-of-protection sweep crosses.
//
// 8192 is absent deliberately: the scheduler microtest measured both policies degenerating there
// (11.83x), and 256 is present because the pattern between 512 and 2048 is non-monotone and
// unexplained, so a point below the only budget that worked is worth more than a fourth point above.
var (
	priceOfProtectionBudgets  = []int{256, 512, 1024, 2048}
	priceOfProtectionPolicies = []string{"fcfs", "priority"}
)

// PremiumTenant is the tenant whose tail every pre-registered criterion is about.
//
// Named once because a literal spelled at each use is the copy that eventually differs by a hyphen, and
// this repository has already paid twice for hand-kept copies of a tenant list drifting apart.
const PremiumTenant = "premium-1"

// NoisyTenant is the contending tenant whose work the positive readings require to survive.
//
// It was spelled as a literal in the trace builder and nowhere else, which was fine while nothing read it
// back. The price-of-protection readings compare this tenant's output share against the control's, so the
// name is now load-bearing in two places and belongs beside PremiumTenant for the reason stated above it.
const NoisyTenant = "standard-noisy"

// ArmR1 is the isolated premium baseline every study measures as its ceiling.
//
// It replays the same trace with the contending tenant filtered out, so its record count legitimately
// differs from every other arm's and identity checks have to exclude it.
const ArmR1 = "R1"

// ArmShared and the two sharing arms are the M5-c matrix's topologies.
//
// They live here beside the other studies' arm names, and not in the evaluator that reads them, because the
// registry below has to name them: a study whose arms are declared in the file that scores them cannot be
// registered without that file, and the runner would then be free to write an arm nobody validates.
//
// The spellings are the ones hack/m5c-matrix.sh puts in its output paths, because those paths are what a
// reader has in front of them when they run the report.
const (
	ArmShared      = "shared"
	ArmTimeSlicing = "timeSlicing"
	ArmMPS         = "mps"
)

// ArmDefaultFCFS is the price-of-protection control: the engine at its own default batch budget under
// first-come-first-served, which is what an operator who configures nothing gets.
//
// It is NOT named "off" even though the pre-registration's readings use that word for it. M5-b's "off"
// arm ran through a gateway, and giving the two the same name would make raw evidence from a
// no-gateway run indistinguishable from evidence that crossed a proxy hop.
const ArmDefaultFCFS = "default-fcfs"

// priceOfProtectionArms generates the sweep's arm names from the factors rather than listing them.
//
// A hand-written list of ten strings is a fifth copy of the factor definitions, and this repository has
// already paid twice for hand-kept lists drifting apart. The budget is zero-padded so that lexical
// order is numeric order: b256 would sort after b1024 and put the table in an order no reader expects.
func priceOfProtectionArms() []string {
	arms := make([]string, 0, 2+len(priceOfProtectionBudgets)*len(priceOfProtectionPolicies))
	arms = append(arms, ArmR1, ArmDefaultFCFS)
	for _, budget := range priceOfProtectionBudgets {
		for _, policy := range priceOfProtectionPolicies {
			arms = append(arms, PriceOfProtectionArm(budget, policy))
		}
	}
	return arms
}

// PriceOfProtectionArm is the canonical name of one cell of the sweep.
//
// "mbt" is max_num_batched_tokens, spelled short because the name sits in a fixed-width report column
// and spelled consistently because a reader who has to decode two abbreviations for one factor will
// eventually decode one of them wrong.
func PriceOfProtectionArm(budget int, policy string) string {
	return fmt.Sprintf("mbt-%04d-%s", budget, policy)
}

// ThroughputLadderArm is the canonical name of one cell of the capacity ladder: one topology at one rung.
//
// The rung is IN THE ARM NAME, and that is the point rather than a convenience. An arm summary pools every
// row carrying its name, so two rungs sharing an arm name would be averaged into a p99 for an offered load
// that was never offered -- a plausible wrong number of exactly the class this repository's rules put above
// every other failure. Making the rung part of the identity makes that pooling unrepresentable.
//
// Zero-padded so that lexical order is numeric order, which is what the report's arm column is sorted by.
func ThroughputLadderArm(rung int, topology string) string {
	return fmt.Sprintf("rung%02d-%s", rung, topology)
}

// TailCrossingArm is the canonical name of the tail-crossing studies' contended arm at one best-effort level.
//
// The level is in the name for the reason the ladder's rung is: an arm summary pools every row carrying its
// name, and two BE rates under one name would be a p99 for a load nobody offered. The RATE a level stands
// for lives in the runner and the registration, not here, exactly as the ladder's rung parameters do.
func TailCrossingArm(level int) string {
	return fmt.Sprintf("be%02d-%s", level, ArmShared)
}

// isTailCrossingArm says whether an arm name is one of the tail-crossing studies' BE levels.
func isTailCrossingArm(arm string) bool {
	for level := 1; level <= tailCrossingLevels; level++ {
		if arm == TailCrossingArm(level) {
			return true
		}
	}
	return false
}

// tailCrossingLevels is how many BE levels the tail-crossing studies admit.
//
// The 2026-10-04 registration places three or four levels after the contender's prefill time is measured,
// and its P3 window needs two inside it; six leaves room for that placement without inventing a grid here.
const tailCrossingLevels = 6

// tailCrossingArms is the isolated baseline and one contended arm per BE level.
func tailCrossingArms() []string {
	arms := []string{ArmR1}
	for level := 1; level <= tailCrossingLevels; level++ {
		arms = append(arms, TailCrossingArm(level))
	}
	return arms
}

// IsIsolatedBaseline says whether an arm name is a study's uncontended premium baseline.
//
// It exists because "is this R1" was spelled as a literal string comparison in two places that decide
// something load-bearing: gen-trace filters the contending tenant out of the baseline's trace, and the
// trace-identity check exempts the baseline because its row count legitimately differs. The ladder's
// baseline is called rung04-R1, so both would have looked straight past it -- producing a "baseline" that
// carried the contender, and a refusal that the traces disagree. Neither would have announced itself.
//
// Asking a function rather than comparing a literal is what makes a third study's baseline work by
// construction instead of by somebody remembering these two call sites.
func IsIsolatedBaseline(arm string) bool {
	if arm == ArmR1 {
		return true
	}
	_, topology, ok := parseLadderArmName(arm)
	return ok && topology == ArmR1
}

// ArmComparisonGroup names the set of arms an arm is compared against.
//
// Every study but one offers a single load, so all its arms are one group and the name is empty. The
// capacity ladder offers a different load per rung by design, so its group is the rung: the two topologies
// of rung 1 must replay the same trace as each other and must NOT replay rung 2's -- a ladder whose rungs
// agreed would be four measurements of one load.
//
// The report's trace-identity refusal is written against one group and was correct for every study that
// existed when it was written. It refused the ladder's own evidence the first time the ladder ran.
func ArmComparisonGroup(arm string) string {
	if rung, _, ok := parseLadderArmName(arm); ok {
		return fmt.Sprintf("rung%02d", rung)
	}
	// The instrument check replays a different trace per episode type by design, and the same trace across the modes of one type.
	if t, ok := InstrumentValidationEpisode(arm); ok {
		return string(t)
	}
	return ""
}

// throughputLadderRungs is how many rungs the pre-registration lists.
//
// The rung PARAMETERS -- the arrival rate and the tenant weights -- live in the runner and in the
// pre-registration, not here: this package scores evidence and never generates load. What it needs is only
// how many names to admit.
const throughputLadderRungs = 4

// throughputLadderArms generates the ladder's arm names from the rungs rather than listing sixteen strings.
//
// Every rung admits both topologies and the isolated baseline, even though R1 is bought at ONE rung. Which
// rung that is depends on where the stopping rule fires, which is not known until the run happens, and a
// registry that admitted R1 at only one rung would have to be edited once the ladder chose -- an edit to the
// instrument after seeing data, which is the thing the pre-registration exists to prevent.
func throughputLadderArms() []string {
	arms := make([]string, 0, throughputLadderRungs*3)
	for rung := 1; rung <= throughputLadderRungs; rung++ {
		arms = append(arms,
			ThroughputLadderArm(rung, ArmShared),
			ThroughputLadderArm(rung, ArmTimeSlicing),
			ThroughputLadderArm(rung, ArmR1))
	}
	return arms
}

// studies is the registry every arm name is validated against.
//
// MinRepetitions and PublishesInterval are left UNSET where a registration fixed no repetition floor, and
// that is a value rather than an omission: zero means "this registration does not say", the way a nil
// Frozen means "this registration froze no load". A refusal reading zero must decline to judge rather than
// treat it as a floor of none -- the same distinction FrozenTuple draws, and the reason an empty expectation
// is never a pass anywhere else in this package.
var studies = map[string]Study{
	StudyM5BGateway: {
		ID:   StudyM5BGateway,
		Arms: []string{ArmR1, "off", "static-cap", "kv-aware"},
		// Five, and it is the one study here whose interval actually reaches a printed report:
		// Checks.IncrementalRatioCI is rendered by FormatReport with the gate reading `Hi < 1.0`. Its own
		// amendment fixes the resample count and seed as M5BIncrementalResamples and M5BIncrementalSeed.
		MinRepetitions:    5,
		PublishesInterval: true,
	},
	StudyPriceOfProtection: {
		ID:   StudyPriceOfProtection,
		Arms: priceOfProtectionArms(),
		// Deliberately unset. Its reading 3 compares an improvement against the CONTROL'S observed spread
		// rather than against an interval, and price_of_protection.go says so in its own words -- "by a
		// bootstrap over four blocks being read as a 95% interval. The range is what it claims to be." A
		// floor invented here would be this file asserting something that sweep's registration does not.
	},
	StudySharingMatrix: {
		ID:   StudySharingMatrix,
		Arms: []string{ArmR1, ArmShared, ArmTimeSlicing, ArmMPS},
		// The seventh amendment's "What is frozen, from here", as data.
		//
		// docs/superpowers/specs/2026-07-04-gpusharingbenchmark-crd-design.md froze these five on
		// 2026-10-01. The characters are the values that amendment recorded, not a fresh lookup: see
		// Study.Frozen on why resolving them here would unfreeze them.
		Frozen: &FrozenTuple{
			PremiumPromptChars:    1174,
			ContenderPromptChars:  42579,
			PremiumInputTokens:    256,
			ContenderInputTokens:  8192,
			TimeoutMs:             60000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		// Five, from the CRD floor its CR path enforces (internal/bench/plan.go refuses `repetitions < 5`
		// with "the CRD floor is 5"), and an interval because its third 2026-09-30 amendment fixes the
		// resample count, the seed and the percentile convention for one.
		//
		// ⚠️ That interval is COMPUTED AND NOT PRINTED: FormatRegisteredEstimand renders B, C and R and then
		// says "No interval is published; see the seventh amendment", leaving RegisteredEstimand.RatioCI
		// unrendered. So this records the registration's promise, not today's output. Writing false here
		// would make the two fields agree by denying what the amendment fixed.
		MinRepetitions:    5,
		PublishesInterval: true,
	},
	// The two input levels. The isolated baseline and the shared engine at each BE level, and nothing else,
	// because the registration's D3 sizes this question for the shared engine against the isolated baseline
	// and drops the split topologies: a study that admitted arms it does not buy would let a run file
	// evidence under a condition nobody registered. The shared engine is one arm per BE level since the
	// 2026-10-04 model-first page made the BE rate a factor; see TailCrossingArm.
	//
	// Both tuples are resolved pairs the table already carries -- 256 -> 1,174 and 8,192 -> 42,579 -- so
	// FrozenTuple.Drift has something to compare and neither level drifts the moment it is entered.
	StudyTailCrossingShortLC: {
		ID:       StudyTailCrossingShortLC,
		Arms:     tailCrossingArms(),
		Arrivals: ArrivalsIndependent,
		Frozen: &FrozenTuple{
			PremiumPromptChars:    1174,
			ContenderPromptChars:  42579,
			PremiumInputTokens:    256,
			ContenderInputTokens:  8192,
			TimeoutMs:             60000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		// TWO, and no interval. Decided 2026-10-04 and dated here because the choice is part of the
		// registration rather than a tuning knob: the 2026-10-03 page's D3 says "2 repetitions is an
		// exploratory compromise, not a precision claim -- this page registers no interval and may not
		// present one", and its section 4 says "Repetition-to-repetition variation and estimator uncertainty
		// remain, and this page registers no interval."
		//
		// The pair must be read together. Two repetitions is permitted BECAUSE no interval is presented; a
		// later edit raising PublishesInterval to true without raising this number would publish bounds that
		// are the two observations, which is what the refusal comparing these fields exists to stop.
		//
		// What two repetitions does NOT weaken is the per-cell sample: MinTailSamples is a floor on COMPLETED
		// REQUESTS and is unchanged here, and RegisteredEstimandFor applies it per repetition as well. The
		// even-count median convention is already pinned -- hack/test/check-published-spreads.sh carries a
		// two-repetition fixture whose 10.000 and 13.387 must average to 11.6935.
		MinRepetitions:    2,
		PublishesInterval: false,
		// Superseded on 2026-10-04 by the model-first registration, whose replication is independent
		// traces: two repetitions of one trace would be one draw of the arrival process measured twice.
		TracesVaryByRepetition: true,
	},
	// The long level: the latency-critical tenant carries the SAME per-request length as the contender, which
	// is the contrast this page registers. It is not a claim that a scheduling mechanism changes there.
	StudyTailCrossingLongLC: {
		ID:       StudyTailCrossingLongLC,
		Arms:     tailCrossingArms(),
		Arrivals: ArrivalsIndependent,
		Frozen: &FrozenTuple{
			PremiumPromptChars:    42579,
			ContenderPromptChars:  42579,
			PremiumInputTokens:    8192,
			ContenderInputTokens:  8192,
			TimeoutMs:             60000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		// The same pair as the short level, and for the same registration: the two levels differ in the
		// latency-critical tenant's prompt length and in nothing else, so a different repetition floor would
		// make the contrast between them a contrast between two report shapes as well.
		MinRepetitions:         2,
		PublishesInterval:      false,
		TracesVaryByRepetition: true,
	},
	// The third level: the same design as the other two, at 2,048 latency-critical tokens -- 10,532
	// characters, the smallest length the serving image's tokenizer resolves to exactly that count, in the
	// same sweep that reproduced the other two levels' resolutions unchanged.
	StudyTailCrossingMidLC: {
		ID:       StudyTailCrossingMidLC,
		Arms:     tailCrossingArms(),
		Arrivals: ArrivalsIndependent,
		Frozen: &FrozenTuple{
			PremiumPromptChars:    10532,
			ContenderPromptChars:  42579,
			PremiumInputTokens:    2048,
			ContenderInputTokens:  8192,
			TimeoutMs:             60000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		MinRepetitions:         2,
		PublishesInterval:      false,
		TracesVaryByRepetition: true,
	},
	// No frozen tuple, because the lengths and caps are factors here rather than a load held fixed.
	// No repetition floor and no interval promise on repetitions: the registration's intervals are episode bootstraps within cells, and it fixes three blocks as a session design rather than as a floor this registry could enforce.
	StudyInstrumentValidation: {
		ID:       StudyInstrumentValidation,
		Arms:     instrumentValidationArms(),
		Arrivals: ArrivalsEpisodes,
		// Every block replays the same bytes, as section 4 of the registration says.
		// I1 pairs cells within a block and I5 compares the first block with the last, so a trace that changed between blocks would put a difference of traces into a check for drift of the engine.
		// The modes of one episode type share the trace as well, which ArmComparisonGroup states.
		TracesVaryByRepetition: false,
	},
	// The same nine arms and the same trace policy as session 1, which section 1 of its registration keeps; only the episodes differ, and they live in designS2.
	StudyInstrumentValidationS2: {
		ID:                     StudyInstrumentValidationS2,
		Arms:                   instrumentValidationArms(),
		Arrivals:               ArrivalsEpisodes,
		TracesVaryByRepetition: false,
	},
	// Session 2's arms and trace policy, which section 1 of its registration keeps; only the stagger decoders' minimum output differs, in designS3.
	StudyInstrumentValidationS3: {
		ID:                     StudyInstrumentValidationS3,
		Arms:                   instrumentValidationArms(),
		Arrivals:               ArrivalsEpisodes,
		TracesVaryByRepetition: false,
	},
	// Session 3's arms and trace policy, which section 1 of its registration keeps; only the warm-up's conditioning request differs, in designS4.
	StudyInstrumentValidationS4: {
		ID:                     StudyInstrumentValidationS4,
		Arms:                   instrumentValidationArms(),
		Arrivals:               ArrivalsEpisodes,
		TracesVaryByRepetition: false,
	},
	StudyStepBoundary: {
		ID:                     StudyStepBoundary,
		Arms:                   stepBoundaryArms(),
		Arrivals:               ArrivalsEpisodes,
		TracesVaryByRepetition: false,
	},
	// One seed in every block, as the step-boundary study: the settings are what is new, and the blocks replicate.
	StudyStepConfirm: {
		ID:                     StudyStepConfirm,
		Arms:                   stepConfirmArms(),
		Arrivals:               ArrivalsEpisodes,
		TracesVaryByRepetition: false,
	},
	// Isolation, unshed, static and prospective, in the order the design names them (I, O, S, P).
	// Its prompts are frozen in characters; their exact tokens come from the calibration epoch, so no token count
	// is declared here and Drift has nothing to compare.
	StudyProspectivePilot: {
		ID:       StudyProspectivePilot,
		Arms:     []string{ArmR1, "off", "static-cap", ArmProspective},
		Arrivals: ArrivalsIndependent,
		Frozen: &FrozenTuple{
			PremiumPromptChars:    200,
			ContenderPromptChars:  40000,
			TimeoutMs:             30000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		// Three blocks per stage, as the scope fixes: the main endpoint pools three, and pooling is not linear in
		// the number of blocks. No interval is published, since the pilot judges nothing.
		MinRepetitions:      3,
		FixesOutputAtCap:    true,
		RecordsReplayTiming: true,
		// Each block replays its own trace, from a seed in the registration's frozen list (build item 7).
		TracesVaryByRepetition: true,
		// 600, the gateway's own outbound pool, above the pilot's ceiling of 9.75/s × 30 s ≈ 293.
		SenderPoolSize: 600,
		// The committed calibration's counts (inputlengths.go): 68 tokens for 200 characters, 7,695 for 40,000.
		FrozenExactTokens: map[int]int{200: 68, 40000: 7695},
	},
	// R1 once as the isolated anchor, then off, hold, cap and hold-cap in each of three blocks.
	StudyAdmissionDiagnostic: {
		ID:       StudyAdmissionDiagnostic,
		Arms:     []string{ArmR1, "off", "hold", "cap", "hold-cap"},
		Arrivals: ArrivalsIndependent,
		Frozen: &FrozenTuple{
			PremiumPromptChars:    200,
			ContenderPromptChars:  40000,
			TimeoutMs:             30000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		MinRepetitions:         1,
		FixesOutputAtCap:       true,
		RecordsReplayTiming:    true,
		TracesVaryByRepetition: true,
		SenderPoolSize:         600,
		FrozenExactTokens:      map[int]int{200: 68, 40000: 7695},
	},
	// R1 once as the isolated anchor, then off, hold-cap and the four fixed spacings in each of three blocks.
	StudyAdmissionFrontier: {
		ID:       StudyAdmissionFrontier,
		Arms:     []string{ArmR1, "off", "hold-cap", "fixed-1.62", "fixed-1.66", "fixed-1.70", "fixed-1.74"},
		Arrivals: ArrivalsIndependent,
		Frozen: &FrozenTuple{
			PremiumPromptChars:    200,
			ContenderPromptChars:  40000,
			TimeoutMs:             30000,
			PremiumOutputTokens:   64,
			ContenderOutputTokens: 16,
		},
		MinRepetitions:         1,
		FixesOutputAtCap:       true,
		RecordsReplayTiming:    true,
		TracesVaryByRepetition: true,
		SenderPoolSize:         600,
		FrozenExactTokens:      map[int]int{200: 68, 40000: 7695},
	},
	StudyThroughputLadder: {
		ID:       StudyThroughputLadder,
		Arms:     throughputLadderArms(),
		Arrivals: ArrivalsWeighted,
	},
	StudyThroughputLadderDown: {
		ID:       StudyThroughputLadderDown,
		Arms:     throughputLadderArms(),
		Arrivals: ArrivalsWeighted,
	},
	StudyThroughputLadderIndependent: {
		ID:       StudyThroughputLadderIndependent,
		Arms:     throughputLadderArms(),
		Arrivals: ArrivalsIndependent,
	},
}

// CanonicalStudyID resolves an identifier as recorded to the identifier it means.
//
// Evidence written before the study field existed carries an empty string, and LookupStudy already reads
// that as the gateway experiment. Comparisons have to use the SAME normalization, or a file labelled
// "m5b-gateway-v1" and an unlabelled file from the same experiment are refused as different studies --
// which is what happened, because the pooling check compared the raw strings.
func CanonicalStudyID(id string) string {
	if id == "" {
		return StudyM5BGateway
	}
	return id
}

// LookupStudy returns the study with this ID.
//
// An empty ID is the evidence written before studies existed, and resolves to the M5-b gateway
// experiment, which is the only thing it can be.
func LookupStudy(id string) (Study, bool) {
	if id == "" {
		id = StudyM5BGateway
	}
	s, ok := studies[id]
	return s, ok
}

// KnownStudyIDs lists the registered studies, for a refusal that has to name the alternatives.
func KnownStudyIDs() []string {
	// DERIVED from the registry and then sorted, rather than hand-listed.
	//
	// The hand-written version said it was a list "because a refusal message whose order changes between
	// runs is a refusal message that cannot be tested", which is a real requirement and the wrong fix for
	// it. Sorting satisfies it too, and a hand-kept copy of the registry does not stay a copy: registering
	// the sharing matrix left this returning two of three studies, so the refusal for a mistyped study ID
	// would have listed the alternatives and omitted the one the operator was reaching for. This repository
	// has paid twice for hand-kept lists drifting from what they list.
	ids := make([]string, 0, len(studies))
	for id := range studies {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids
}

// Admits reports whether arm is one of this study's conditions.
func (s Study) Admits(arm string) bool {
	return slices.Contains(s.Arms, arm)
}

// ArmColumnWidth is the width of the report's arm column: the longest arm name any study defines.
//
// It was the literal 12, which fitted M5-b's four names and silently misaligned anything longer --
// "mbt-0512-priority" is 17 characters and would have pushed every column after it out of line in the
// one table a reader actually looks at. Derived from the registry so that adding a study cannot break
// the report by a mechanism nobody thinks to check.
var ArmColumnWidth = widestArmName()

func widestArmName() int {
	w := len("arm")
	for _, s := range studies {
		for _, a := range s.Arms {
			if len(a) > w {
				w = len(a)
			}
		}
	}
	return w
}

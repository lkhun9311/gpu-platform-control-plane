package bench

import (
	"fmt"
	"math"
	"slices"
	"strings"
)

// The A/B/C engine-version pilot, registered in docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md.
//
// This file holds the parts of that registration a program can check: the arms, what may differ between the
// treatments' engines, the loads and their order, the windows, the block order and workload seeds, the phase bounds
// and budget, and which values are still open. The spec is the authority for why each value is what it is.

// The three treatments of the version study.
const (
	// TreatmentA is vLLM v0.27.1 with the validated execution profile, the incumbent every candidate is compared with.
	TreatmentA = "A"
	// TreatmentB is vLLM v0.32.0 with A's settings and async scheduling off, so only the version moves.
	TreatmentB = "B"
	// TreatmentC is B with async scheduling on, so only the scheduler mode moves against B.
	TreatmentC = "C"
)

// The two registered offered loads, as fractions of λ0, treatment A's confirmed stable operating rate.
//
// 1.2 λ0 and bursts are overload exploration and belong to a separate study, so they have no arm here.
const (
	LoadL060 = "l060"
	LoadL090 = "l090"
)

// versionStudyTreatments and versionStudyLoads are the registered factors, in report order.
var (
	versionStudyTreatments = []string{TreatmentA, TreatmentB, TreatmentC}
	versionStudyLoads      = []LoadLevel{{Name: LoadL060, Fraction: 0.6}, {Name: LoadL090, Fraction: 0.9}}
)

// versionStudyPlannedBlocks is six, so every one of the six treatment orders runs exactly once.
const versionStudyPlannedBlocks = 6

// LoadLevel is one registered offered load: a name the arm carries and the fraction of λ0 it offers.
type LoadLevel struct {
	Name     string
	Fraction float64
}

// VersionStudyArm names the arm of one treatment at one load, e.g. "B-l090".
func VersionStudyArm(treatment, load string) string {
	return treatment + "-" + load
}

// ParseVersionStudyArm splits an arm name into its treatment and load, and refuses a name the study does not register.
func ParseVersionStudyArm(arm string) (treatment, load string, ok bool) {
	t, l, found := strings.Cut(arm, "-")
	if !found {
		return "", "", false
	}
	if !slices.Contains(versionStudyTreatments, t) || versionStudyLoad(l) == nil {
		return "", "", false
	}
	return t, l, true
}

// versionStudyLoad returns the registered load of this name, or nil.
func versionStudyLoad(name string) *LoadLevel {
	for i := range versionStudyLoads {
		if versionStudyLoads[i].Name == name {
			return &versionStudyLoads[i]
		}
	}
	return nil
}

// versionStudyArms lists treatment-major, load-minor, which is the order the report prints.
func versionStudyArms() []string {
	arms := make([]string, 0, len(versionStudyTreatments)*len(versionStudyLoads))
	for _, t := range versionStudyTreatments {
		for _, l := range versionStudyLoads {
			arms = append(arms, VersionStudyArm(t, l.Name))
		}
	}
	return arms
}

// versionStudyExactTokens is the engine's input-token count for each prompt length the workload sends, by characters.
//
// The three lengths are 256, 1,024 and 2,048 tokens as hack/input-length-resolution.json resolved them inside the v0.27.1 image.
// The newer image's count is checked against these at preflight, because a changed chat template would change the prefill the arms do.
func versionStudyExactTokens() map[int]int {
	return map[int]int{1174: 256, 5183: 1024, 10532: 2048}
}

// Endpoint names one registered outcome of the version study.
type Endpoint string

// The registered endpoints; the spec defines each one's population and percentile, and DecisionRule.Voting says which decide.
const (
	EndpointTTFTP99 Endpoint = "ttft_p99"
	// EndpointTPOTP99 is over successful requests only, so it is descriptive and never votes (attack item 4).
	EndpointTPOTP99 Endpoint = "tpot_p99"
	EndpointE2EP99  Endpoint = "e2e_p99"
	EndpointGoodput Endpoint = "goodput"
	// EndpointCostPerSLORequest is reported but does not vote: at a fixed offered window it is price divided by goodput.
	EndpointCostPerSLORequest Endpoint = "cost_per_slo_request"
)

// EndpointVersionDecisionSet is the version study's primaryEndpoint.
//
// The study has no single primary metric: its verdict is the registered rule over its voting endpoints and guardrail.
// Naming the rule keeps the manifest field meaning "what the run is judged by", which reproduction compares.
const EndpointVersionDecisionSet = "version-decision-set-v1"

// SLO is the per-request service objective goodput counts against.
type SLO struct {
	// TTFTMs bounds the time from intended arrival to the first content byte.
	TTFTMs float64
	// TPOTMs bounds the request's client-observed time per output token after the first.
	TPOTMs float64
}

// Comparison is one registered contrast, candidate against reference.
type Comparison struct {
	Candidate, Reference string
}

// LengthWeight is one length a workload draws and its probability.
type LengthWeight struct {
	Tokens int
	Weight float64
}

// PhaseBounds are the registered ceilings on each phase's wall time, which the budget is computed from.
//
// A bound is a deadline the runner enforces, not an estimate: a phase that reaches it ends with the outcome the spec registers.
type PhaseBounds struct {
	// SetupSeconds covers instance launch, both image pulls and the model download.
	SetupSeconds int
	// ReadinessSeconds runs from engine process start to /health 200 and every priming request answered.
	ReadinessSeconds int
	// DrainSeconds runs from the last arrival until the engine reports nothing running or waiting.
	DrainSeconds int
	// PreflightSecondsPerTreatment covers one treatment's start, readiness and preflight requests.
	PreflightSecondsPerTreatment int
	// TeardownSeconds is held back at the end of the deadline for teardown to finish.
	TeardownSeconds int
}

// VersionStudyDesign is the part of the version study's registration a program can enforce.
type VersionStudyDesign struct {
	// Model, ModelRevision and TokenizerRevision pin what every arm serves; the controller passes one revision as both.
	Model             string
	ModelRevision     string
	TokenizerRevision string
	// ChatTemplateSHA256 is the template hack/input-length-resolution.json measured the frozen token counts under.
	ChatTemplateSHA256 string
	// Engines is the engine each treatment must run, compared field by field with every manifest.
	Engines map[string]EngineSettings
	// EngineFlagReviews maps B and C to the sha256 of the effective-argument record the engine-path track reviewed for the v0.32.0 image.
	//
	// Empty until that track has read the image's own flags and confirmed each registered setting maps to one; this registration does not guess them.
	EngineFlagReviews map[string]string
	// Primary selects a deployment, Fallback selects only when Primary does not adopt, and Explanatory never selects.
	Primary, Fallback, Explanatory Comparison
	// CampaignSeed fixes every block's treatment order and workload before any run, so neither can be redrawn after a bad block.
	CampaignSeed int64
	// PlannedBlocks is how many valid blocks the analysis needs, and MaxReplacementBlocks how many invalid ones may be replaced.
	PlannedBlocks        int
	MaxReplacementBlocks int
	// WarmupSeconds is the warm-up at the cell's own offered rate before every measurement window.
	WarmupSeconds int
	// MinMeasureSeconds and MaxMeasureSeconds bound the window ChooseWindow picks from the generated traces.
	MinMeasureSeconds int
	MaxMeasureSeconds int
	// MinOfferedPopulation is the fewest measured requests the planned blocks' traces must offer per load.
	MinOfferedPopulation int
	// TimeoutMs is the whole-request deadline every arm is sent with.
	TimeoutMs int
	// DispatchLagP99Ms and DispatchLagMaxMs bound transport-write time minus intended arrival in a valid cell.
	DispatchLagP99Ms float64
	DispatchLagMaxMs float64
	// InputTokens and OutputTokens are the workload's length mixtures, drawn independently per request.
	InputTokens  []LengthWeight
	OutputTokens []LengthWeight
	// SLO is the owner's per-request objective.
	SLO SLO
	// Decision is the pilot decision heuristic.
	Decision DecisionRule
	// Calibration is the ladder that finds λ0.
	Calibration CalibrationRule
	// Bounds are the phase ceilings.
	Bounds PhaseBounds
	// BudgetUSD is the session cap and ReserveUSD what is held back beyond the bounded phases.
	BudgetUSD  float64
	ReserveUSD float64
}

// versionAsyncDesign returns a fresh copy of the registered design, so a caller cannot edit the registry through it.
func versionAsyncDesign() VersionStudyDesign {
	return VersionStudyDesign{
		Model:              "Qwen/Qwen2.5-3B-Instruct",
		ModelRevision:      "aa8e72537993ba99e69dfaafa59ed015b17504d1",
		TokenizerRevision:  "aa8e72537993ba99e69dfaafa59ed015b17504d1",
		ChatTemplateSHA256: "cd8e9439f0570856fd70470bf8889ebd8b5d1107207f67a5efb46e342330527f",
		Engines: map[string]EngineSettings{
			TreatmentA: versionStudyEngine("v0.27.1", "vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967", false),
			// The owner chose v0.32.0; the engine-path track pinned the digest Docker Hub's v0.32.0 tag resolved to on 2026-11-15.
			TreatmentB: versionStudyEngine("v0.32.0", "vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34", false),
			TreatmentC: versionStudyEngine("v0.32.0", "vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34", true),
		},
		// The sha256 of hack/engine-flag-reviews/vllm-v0.32.0-async-{off,on}.json, which the controller's rendering is tested against.
		EngineFlagReviews: map[string]string{
			TreatmentB: "a3c54f90e6e3650966b6734f748d627fc291381374f726d606242c950c98a6f2",
			TreatmentC: "a51d414bae84b38910962259cb42dec8fc98c83c90ba8a4cd2676afa928806fc",
		},
		Primary:              Comparison{Candidate: TreatmentC, Reference: TreatmentA},
		Fallback:             Comparison{Candidate: TreatmentB, Reference: TreatmentA},
		Explanatory:          Comparison{Candidate: TreatmentC, Reference: TreatmentB},
		CampaignSeed:         20261115,
		PlannedBlocks:        versionStudyPlannedBlocks,
		MaxReplacementBlocks: 2,
		WarmupSeconds:        60,
		MinMeasureSeconds:    300,
		MaxMeasureSeconds:    1800,
		MinOfferedPopulation: 1000,
		TimeoutMs:            60000,
		DispatchLagP99Ms:     10,
		DispatchLagMaxMs:     100,
		InputTokens:          []LengthWeight{{256, 0.5}, {1024, 0.3}, {2048, 0.2}},
		OutputTokens:         []LengthWeight{{64, 0.5}, {256, 0.5}},
		SLO:                  SLO{TTFTMs: 1000, TPOTMs: 60},
		Decision: DecisionRule{
			Voting:               []Endpoint{EndpointTTFTP99, EndpointE2EP99, EndpointGoodput},
			BenefitEndpoints:     []Endpoint{EndpointE2EP99},
			MinWorthwhileBenefit: 0.10,
			ToleratedLoss:        map[Endpoint]float64{EndpointTTFTP99: 0.10, EndpointE2EP99: 0.10, EndpointGoodput: 0.10},
			MaxFailureFraction:   0.005,
			IntervalLevel:        0.90,
		},
		Calibration: CalibrationRule{
			StartRate: 0.5, Growth: 1.5, MaxExpansion: 12,
			FallbackFactor: 0.5, MaxFallback: 2,
			TargetRatio: 1.05, MaxRefine: 6,
			Confirmations: 2, MaxStepDowns: 2, MaxInvalidRetries: 2,
			Tolerance: 0.02, OutstandingSlackMin: 3, MaxFailureFraction: 0.005,
			WarmupSeconds: 60, WindowSeconds: 180, DrainSeconds: 120,
		},
		Bounds: PhaseBounds{
			SetupSeconds:                 2700,
			ReadinessSeconds:             600,
			DrainSeconds:                 120,
			PreflightSecondsPerTreatment: 900,
			TeardownSeconds:              600,
		},
		BudgetUSD:  20,
		ReserveUSD: 2,
	}
}

// versionStudyEngine builds every treatment from one profile, so the treatments cannot drift in a setting nobody meant to change.
//
// The settings are internal/controller's measuredA10GArgs with prefix caching off, which is the profile named v0.27.1-a10g.
func versionStudyEngine(version, image string, async bool) EngineSettings {
	return EngineSettings{
		VLLMVersion:          version,
		Image:                image,
		Dtype:                "half",
		MaxModelLen:          16384,
		MaxNumSeqs:           64,
		MaxNumBatchedTokens:  512,
		GPUMemoryUtilization: "0.90",
		PrefixCaching:        new(false),
		SchedulingPolicy:     "priority",
		AsyncScheduling:      new(async),
	}
}

// Unfrozen lists the registered values still open, in a fixed order.
//
// λ0, the window and the price are not here: the session measures or reads them by registered procedures and freezes them in the campaign bundle.
func (d VersionStudyDesign) Unfrozen() []string {
	var out []string
	for _, t := range versionStudyTreatments {
		if d.Engines[t].VLLMVersion == "" {
			out = append(out, "treatment "+t+" vLLM version")
		}
		if d.Engines[t].Image == "" {
			out = append(out, "treatment "+t+" image digest (engine-path track)")
		}
		if review, ok := d.EngineFlagReviews[t]; ok && !isSHA256Hex(review) {
			out = append(out, "treatment "+t+" flag review (engine-path track)")
		}
	}
	return out
}

// PreflightRefusal refuses to run any cell while a registered value is open.
func (d VersionStudyDesign) PreflightRefusal() error {
	if u := d.Unfrozen(); len(u) > 0 {
		return fmt.Errorf("the version study is not frozen; still open: %s", strings.Join(u, ", "))
	}
	return nil
}

// LoadOrder is the order a block runs its two loads in, the same for every treatment of the block.
//
// Odd blocks run l060 first and even blocks l090 first, so each load follows the other in half the planned blocks.
// A fixed order would let "l090 after l060" stand for "l090", and carry-over need not cancel between versions (attack item 11).
func LoadOrder(block int) []string {
	switch {
	case block < 1:
		return nil
	case block%2 == 1:
		return []string{LoadL060, LoadL090}
	default:
		return []string{LoadL090, LoadL060}
	}
}

// Phase is which part of a cell a request belongs to, decided by its intended arrival.
type Phase string

const (
	// PhaseWarmup requests are sent and never scored.
	PhaseWarmup Phase = "warmup"
	// PhaseMeasure requests are the population every endpoint is computed over.
	PhaseMeasure Phase = "measure"
	// PhaseOutside is an offset no registered trace may carry.
	PhaseOutside Phase = "outside"
)

// PhaseOf classifies a trace row by its intended arrival offset, for a frozen window of windowSeconds.
//
// The boundary is the intended arrival and never the completion time.
// Filtering by completion would drop exactly the slow requests that arrived during warm-up and finished inside the window, and keep the reverse, differently per arm.
func (d VersionStudyDesign) PhaseOf(offsetMs int64, windowSeconds int) Phase {
	warm := int64(d.WarmupSeconds) * 1000
	end := warm + int64(windowSeconds)*1000
	switch {
	case offsetMs < 0 || windowSeconds <= 0:
		return PhaseOutside
	case offsetMs < warm:
		return PhaseWarmup
	case offsetMs < end:
		return PhaseMeasure
	default:
		return PhaseOutside
	}
}

// ChooseWindow picks the measurement window from the seeded traces alone, before anything is measured.
//
// measured returns how many rows of the planned block's trace at a load fall in a window of the given length.
// The window grows in 60 s steps from the minimum until the planned blocks offer MinOfferedPopulation measured requests at
// every load, so the floor is met by the traces themselves rather than expected from a rate (attack item 10).
// It never looks at an outcome, and a window over the maximum stops the session instead of being stretched.
func (d VersionStudyDesign) ChooseWindow(measured func(block int, load string, windowSeconds int) (int, error)) (int, error) {
	for w := d.MinMeasureSeconds; w <= d.MaxMeasureSeconds; w += 60 {
		ok := true
		for _, l := range versionStudyLoads {
			total := 0
			for b := 1; b <= d.PlannedBlocks; b++ {
				n, err := measured(b, l.Name, w)
				if err != nil {
					return 0, err
				}
				total += n
			}
			if total < d.MinOfferedPopulation {
				ok = false
			}
		}
		if ok {
			return w, nil
		}
	}
	return 0, fmt.Errorf("no window up to %d s offers %d measured requests per load over %d blocks; λ0 is too low for this design",
		d.MaxMeasureSeconds, d.MinOfferedPopulation, d.PlannedBlocks)
}

// OfferedRate is the arrival rate of a load at λ0, or an error for an unregistered load or a rate that is not positive.
func OfferedRate(load string, stableRate float64) (float64, error) {
	l := versionStudyLoad(load)
	if l == nil {
		return 0, fmt.Errorf("load %q is not one of the version study's registered loads", load)
	}
	if !(stableRate > 0) || math.IsInf(stableRate, 0) {
		return 0, fmt.Errorf("λ0 %v is not a confirmed positive rate", stableRate)
	}
	return l.Fraction * stableRate, nil
}

// BlockBoundSeconds is a block's ceiling for a window: per treatment, two engine starts and two cells.
//
// Two starts, because an engine that does not drain by the deadline is restarted before the next load.
func (d VersionStudyDesign) BlockBoundSeconds(windowSeconds int) int {
	cell := d.WarmupSeconds + windowSeconds + d.Bounds.DrainSeconds
	return len(versionStudyTreatments) * (2*d.Bounds.ReadinessSeconds + 2*cell)
}

// usd is the cost of seconds at a session rate in dollars per hour.
func usd(seconds int, ratePerHour float64) float64 {
	return float64(seconds) / 3600 * ratePerHour
}

// MayStartBlock says whether the session can still afford every valid block it needs, not merely the next one.
//
// ratePerHour is the instance price plus the other session charges per hour; validStillNeeded counts the valid blocks
// missing from the planned total. Each is charged at its bound, and teardown and the reserve are held back (attack item 13).
func (d VersionStudyDesign) MayStartBlock(spentUSD, ratePerHour float64, validStillNeeded, windowSeconds int) bool {
	if !(ratePerHour > 0) || math.IsInf(ratePerHour, 0) || math.IsNaN(spentUSD) || spentUSD < 0 || validStillNeeded < 1 || windowSeconds <= 0 {
		return false
	}
	need := float64(validStillNeeded)*usd(d.BlockBoundSeconds(windowSeconds), ratePerHour) +
		usd(d.Bounds.TeardownSeconds, ratePerHour) + d.ReserveUSD
	return spentUSD+need <= d.BudgetUSD
}

// SessionBoundSeconds is the whole session's ceiling: setup, calibration, three preflights, the planned blocks and teardown.
func (d VersionStudyDesign) SessionBoundSeconds(windowSeconds int) int {
	return d.Bounds.SetupSeconds + d.Calibration.MaxSeconds() + len(versionStudyTreatments)*d.Bounds.PreflightSecondsPerTreatment +
		d.PlannedBlocks*d.BlockBoundSeconds(windowSeconds) + d.Bounds.TeardownSeconds
}

// TeardownDeadlineSeconds is how long after launch teardown must begin, whatever phase is running.
//
// It covers setup and calibration too: the cap less the reserve, at the session rate, less the teardown bound.
func (d VersionStudyDesign) TeardownDeadlineSeconds(ratePerHour float64) int {
	if !(ratePerHour > 0) || math.IsInf(ratePerHour, 0) {
		return 0
	}
	return int((d.BudgetUSD-d.ReserveUSD)/ratePerHour*3600) - d.Bounds.TeardownSeconds
}

// splitmix64 is the generator behind the block order and the workload seeds.
//
// It is written out rather than taken from math/rand, whose algorithms carry no promise of stable output across releases.
// A registered campaign's order must be the same when it is checked a year later.
func splitmix64(x uint64) uint64 {
	x += 0x9e3779b97f4a7c15
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
}

// allTreatmentOrders lists the six orders of A, B and C lexically, the base list ArmOrder shuffles.
var allTreatmentOrders = [][]string{
	{TreatmentA, TreatmentB, TreatmentC},
	{TreatmentA, TreatmentC, TreatmentB},
	{TreatmentB, TreatmentA, TreatmentC},
	{TreatmentB, TreatmentC, TreatmentA},
	{TreatmentC, TreatmentA, TreatmentB},
	{TreatmentC, TreatmentB, TreatmentA},
}

// ArmOrder is the order block (counting from 1) visits the treatments in.
//
// The six orders are shuffled once by the campaign seed and dealt to blocks in turn, so the six planned blocks run every
// order exactly once and each treatment holds each position twice.
// A block before 1 has no order and gets nil.
func ArmOrder(seed int64, block int) []string {
	if block < 1 {
		return nil
	}
	orders := make([][]string, len(allTreatmentOrders))
	copy(orders, allTreatmentOrders)
	state := uint64(seed)
	for i := len(orders) - 1; i > 0; i-- {
		state = splitmix64(state)
		j := int(state % uint64(i+1))
		orders[i], orders[j] = orders[j], orders[i]
	}
	return append([]string(nil), orders[(block-1)%len(orders)]...)
}

// WorkloadSeed is the trace seed of one block at one load, shared by every treatment in that block.
//
// One seed per block and load is what makes a block a paired comparison: the three treatments see the same requests.
// Different blocks get different seeds, so the spread across blocks covers the draw of the arrival process too.
func WorkloadSeed(campaignSeed int64, block int, load string) (int64, error) {
	if block < 1 {
		return 0, fmt.Errorf("block %d: blocks count from 1", block)
	}
	idx := -1
	for i, l := range versionStudyLoads {
		if l.Name == load {
			idx = i
		}
	}
	if idx < 0 {
		return 0, fmt.Errorf("load %q is not one of the version study's registered loads", load)
	}
	s := splitmix64(uint64(campaignSeed))
	s = splitmix64(s ^ uint64(block))
	s = splitmix64(s ^ uint64(idx+1)<<32)
	// The sign bit is cleared because gen-trace and the manifest carry the seed as a signed integer.
	return int64(s & math.MaxInt64), nil
}

// EngineSettings is the engine a cell ran, typed so that a setting the manifest does not name is refused rather than ignored.
//
// The two booleans are pointers so an omitted setting reads as missing and not as false.
type EngineSettings struct {
	// VLLMVersion is the release tag, recorded beside the digest so a reader does not have to resolve one.
	VLLMVersion string `json:"vllmVersion"`
	// Image is the engine image pinned by digest; a mirror of the same digest is accepted.
	Image               string `json:"image"`
	Dtype               string `json:"dtype"`
	MaxModelLen         int    `json:"maxModelLen"`
	MaxNumSeqs          int    `json:"maxNumSeqs"`
	MaxNumBatchedTokens int    `json:"maxNumBatchedTokens"`
	// GPUMemoryUtilization is a decimal string for the reason MatchTolerance is: it round-trips exactly.
	GPUMemoryUtilization string `json:"gpuMemoryUtilization"`
	PrefixCaching        *bool  `json:"prefixCaching"`
	SchedulingPolicy     string `json:"schedulingPolicy"`
	AsyncScheduling      *bool  `json:"asyncScheduling"`
}

// imageDigest is the part of an image reference after '@', or "" for a reference not pinned by digest.
func imageDigest(ref string) string {
	if !digestPinned(ref) {
		return ""
	}
	return ref[strings.Index(ref, "@")+1:]
}

// Diff names the first setting in which got differs from e, or "".
//
// Images are compared by digest, so a mirror of the registered image is the same engine.
func (e EngineSettings) Diff(got EngineSettings) string {
	boolStr := func(b *bool) string {
		if b == nil {
			return "unset"
		}
		return fmt.Sprint(*b)
	}
	for _, c := range []struct {
		name      string
		want, got string
	}{
		{"vllmVersion", e.VLLMVersion, got.VLLMVersion},
		{"image digest", imageDigest(e.Image), imageDigest(got.Image)},
		{"dtype", e.Dtype, got.Dtype},
		{"maxModelLen", fmt.Sprint(e.MaxModelLen), fmt.Sprint(got.MaxModelLen)},
		{"maxNumSeqs", fmt.Sprint(e.MaxNumSeqs), fmt.Sprint(got.MaxNumSeqs)},
		{"maxNumBatchedTokens", fmt.Sprint(e.MaxNumBatchedTokens), fmt.Sprint(got.MaxNumBatchedTokens)},
		{"gpuMemoryUtilization", e.GPUMemoryUtilization, got.GPUMemoryUtilization},
		{"prefixCaching", boolStr(e.PrefixCaching), boolStr(got.PrefixCaching)},
		{"schedulingPolicy", e.SchedulingPolicy, got.SchedulingPolicy},
		{"asyncScheduling", boolStr(e.AsyncScheduling), boolStr(got.AsyncScheduling)},
	} {
		if c.want != c.got {
			return fmt.Sprintf("%s is %q, registered %q", c.name, c.got, c.want)
		}
	}
	return ""
}

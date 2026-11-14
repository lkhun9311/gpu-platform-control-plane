package bench

import (
	"fmt"
	"math"
	"slices"
	"strings"
)

// The A/B/C engine-version study, registered in docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md.
//
// This file holds the parts of that registration a program can check: the arms, what may differ between the
// treatments' engines, the loads, the windows, the block order and workload seeds, and which owner decisions are
// still open. The spec is the authority for why each value is what it is.

// The three treatments of the version study.
const (
	// TreatmentA is vLLM v0.27.1 with the validated execution profile, the reference every candidate is compared with.
	TreatmentA = "A"
	// TreatmentB is a newer pinned vLLM with A's settings and async scheduling off, so only the version moves.
	TreatmentB = "B"
	// TreatmentC is B with async scheduling on, so only the scheduler mode moves against B.
	TreatmentC = "C"
)

// The two registered offered loads, as fractions of the capacity λ0 measured on treatment A.
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

// versionStudyPlannedBlocks is the registered block count; the spec gives why five and not more.
const versionStudyPlannedBlocks = 5

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

// The five registered endpoints; the spec defines each one's population and percentile.
const (
	EndpointTTFTP99 Endpoint = "ttft_p99"
	EndpointTPOTP99 Endpoint = "tpot_p99"
	EndpointE2EP99  Endpoint = "e2e_p99"
	EndpointGoodput Endpoint = "goodput"
	// EndpointCostPerSLORequest is reported but does not vote: at a fixed offered window it is price divided by goodput.
	EndpointCostPerSLORequest Endpoint = "cost_per_slo_request"
)

// EndpointVersionDecisionSet is the version study's primaryEndpoint.
//
// The study has no single primary metric: its verdict is the registered rule over four voting endpoints.
// Naming the rule keeps the manifest field meaning "what the run is judged by", which reproduction compares.
const EndpointVersionDecisionSet = "version-decision-set-v1"

// votingEndpoints are the endpoints the decision rule reads, each of which needs a frozen margin.
var votingEndpoints = []Endpoint{EndpointTTFTP99, EndpointTPOTP99, EndpointE2EP99, EndpointGoodput}

// SLO is the per-request service objective goodput counts against; zero means not yet decided.
type SLO struct {
	// TTFTMs bounds the time from intended arrival to the first content byte.
	TTFTMs float64
	// TPOTMs bounds the request's mean time per output token after the first.
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
	// Comparisons are the contrasts the decision rule is applied to.
	Comparisons []Comparison
	// CampaignSeed fixes every block's treatment order and workload before any run, so neither can be redrawn after a bad block.
	CampaignSeed int64
	// PlannedBlocks is how many complete blocks the analysis needs, and MaxReplacementBlocks how many invalid ones may be replaced.
	PlannedBlocks        int
	MaxReplacementBlocks int
	// WarmupSeconds is the warm-up at the cell's own offered rate before every measurement window.
	WarmupSeconds int
	// MinMeasureSeconds is the shortest measurement window; MeasureSeconds lengthens it to reach MinTailSamples.
	MinMeasureSeconds int
	// MinTailSamples is the fewest requests a pooled p99 may rest on, per arm and load, over the planned blocks.
	MinTailSamples int
	// TimeoutMs is the whole-request deadline every arm is sent with.
	TimeoutMs int
	// DispatchLagP99Ms and DispatchLagMaxMs bound transport-write time minus intended arrival in a valid cell.
	DispatchLagP99Ms float64
	DispatchLagMaxMs float64
	// InputTokens and OutputTokens are the workload's length mixtures, drawn independently per request.
	InputTokens  []LengthWeight
	OutputTokens []LengthWeight
	// SLO and Margins are owner decisions; zero means undecided, and PreflightRefusal refuses until both are set.
	SLO SLO
	// Margins are the practical-equivalence margins, as relative changes of each endpoint's ratio.
	Margins map[Endpoint]float64
	// IntervalLevel and Resamples fix the block bootstrap.
	IntervalLevel float64
	Resamples     int
	// BudgetUSD is the session cap and ReserveUSD what is held back for teardown and the instance's last partial hour.
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
			// The newer version is the owner's choice and is not invented here; an empty value refuses every B and C manifest.
			TreatmentB: versionStudyEngine("", "", false),
			TreatmentC: versionStudyEngine("", "", true),
		},
		Comparisons: []Comparison{
			{Candidate: TreatmentB, Reference: TreatmentA},
			{Candidate: TreatmentC, Reference: TreatmentB},
			{Candidate: TreatmentC, Reference: TreatmentA},
		},
		CampaignSeed:         20261115,
		PlannedBlocks:        versionStudyPlannedBlocks,
		MaxReplacementBlocks: 2,
		WarmupSeconds:        60,
		MinMeasureSeconds:    300,
		MinTailSamples:       1000,
		TimeoutMs:            60000,
		DispatchLagP99Ms:     10,
		DispatchLagMaxMs:     100,
		InputTokens:          []LengthWeight{{256, 0.5}, {1024, 0.3}, {2048, 0.2}},
		OutputTokens:         []LengthWeight{{64, 0.5}, {256, 0.5}},
		Margins:              map[Endpoint]float64{},
		IntervalLevel:        0.90,
		Resamples:            10000,
		BudgetUSD:            20,
		ReserveUSD:           2,
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

// Unfrozen lists the registered values that are still owner decisions, in a fixed order.
//
// λ0 is not here: it is measured inside the session by the registered procedure and frozen in a calibration artifact every cell names.
func (d VersionStudyDesign) Unfrozen() []string {
	var out []string
	for _, t := range versionStudyTreatments {
		e := d.Engines[t]
		if e.VLLMVersion == "" {
			out = append(out, "treatment "+t+" vLLM version")
		}
		if e.Image == "" {
			out = append(out, "treatment "+t+" image digest")
		}
	}
	if !(d.SLO.TTFTMs > 0) || math.IsInf(d.SLO.TTFTMs, 0) {
		out = append(out, "SLO TTFT")
	}
	if !(d.SLO.TPOTMs > 0) || math.IsInf(d.SLO.TPOTMs, 0) {
		out = append(out, "SLO TPOT")
	}
	for _, e := range votingEndpoints {
		if m := d.Margins[e]; !(m > 0 && m < 1) {
			out = append(out, "equivalence margin "+string(e))
		}
	}
	return out
}

// PreflightRefusal refuses to run any cell while a registered value is undecided.
//
// A run under an unfrozen SLO or margin could be judged by numbers chosen after its results were seen.
func (d VersionStudyDesign) PreflightRefusal() error {
	if u := d.Unfrozen(); len(u) > 0 {
		return fmt.Errorf("the version study is not frozen; still undecided: %s", strings.Join(u, ", "))
	}
	return nil
}

// MeasureSeconds is the measurement window for a measured capacity, or 0 when the capacity is not a positive number.
//
// The window is the same at both loads, so it is sized for the lower one: the planned blocks at 0.6 λ0 must offer MinTailSamples requests.
func (d VersionStudyDesign) MeasureSeconds(capacityPerSec float64) int {
	if !(capacityPerSec > 0) || math.IsInf(capacityPerSec, 0) {
		return 0
	}
	lowest := math.Inf(1)
	for _, l := range versionStudyLoads {
		lowest = math.Min(lowest, l.Fraction)
	}
	need := int(math.Ceil(float64(d.MinTailSamples) / (float64(d.PlannedBlocks) * lowest * capacityPerSec)))
	return max(d.MinMeasureSeconds, need)
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

// PhaseOf classifies a trace row by its intended arrival offset.
//
// The boundary is the intended arrival and never the completion time.
// Filtering by completion would drop exactly the slow requests that arrived during warm-up and finished inside the window, and keep the reverse, differently per arm.
func (d VersionStudyDesign) PhaseOf(offsetMs int64, capacityPerSec float64) Phase {
	warm := int64(d.WarmupSeconds) * 1000
	end := warm + int64(d.MeasureSeconds(capacityPerSec))*1000
	switch {
	case offsetMs < 0:
		return PhaseOutside
	case offsetMs < warm:
		return PhaseWarmup
	case offsetMs < end:
		return PhaseMeasure
	default:
		return PhaseOutside
	}
}

// OfferedRate is the arrival rate of a load at a measured capacity, or an error for an unregistered load.
func OfferedRate(load string, capacityPerSec float64) (float64, error) {
	l := versionStudyLoad(load)
	if l == nil {
		return 0, fmt.Errorf("load %q is not one of the version study's registered loads", load)
	}
	if !(capacityPerSec > 0) || math.IsInf(capacityPerSec, 0) {
		return 0, fmt.Errorf("capacity %v is not a measured positive rate", capacityPerSec)
	}
	return l.Fraction * capacityPerSec, nil
}

// MayStartBlock says whether one more block fits under the cap.
//
// worstBlockUSD is the larger of the planning estimate and the costliest block completed so far, so it is never zero.
// A zero or negative estimate is refused, because it would let every block start.
func (d VersionStudyDesign) MayStartBlock(spentUSD, worstBlockUSD float64) bool {
	if !(worstBlockUSD > 0) || math.IsNaN(spentUSD) || math.IsInf(spentUSD, 0) || math.IsInf(worstBlockUSD, 0) {
		return false
	}
	return spentUSD+worstBlockUSD <= d.BudgetUSD-d.ReserveUSD
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
// The six orders are shuffled once by the campaign seed and dealt to blocks in turn, so the first six blocks never repeat an order.
// Five blocks cannot balance three treatments over three positions exactly; dealing without replacement is the closest a fixed count gets.
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

// CheckVersionCampaign checks that a version-study campaign's valid cells pair into blocks, and returns the complete blocks.
//
// Each manifest has already passed LoadManifest, which checks one cell against the registration.
// What one cell cannot show is how cells relate: that the treatments of a block replayed the same workload, that no two
// blocks replayed the same one, and that every cell was priced against one λ0 (audit findings 2, 3, 17 and 21).
// Pairing reads the identity the manifest recorded before execution, never a file name.
//
// The caller passes only cells its validity rules kept; a block with any cell left out is incomplete and is not analysed.
// Fewer complete blocks than the registration plans is an error, because the analysis is then not confirmatory and may
// not publish adopt, equivalent or reject (audit finding 14); the complete blocks are still returned for a descriptive report.
func CheckVersionCampaign(cells []RunManifest) ([]int, error) {
	if len(cells) == 0 {
		return nil, fmt.Errorf("no cells to pair")
	}
	st, ok := LookupStudy(cells[0].Study)
	if !ok || st.Version == nil {
		return nil, fmt.Errorf("study %q is not a version study", cells[0].Study)
	}
	type cellKey struct {
		block int
		arm   string
	}
	type blockLoad struct {
		block int
		load  string
	}
	var ref *RunManifest
	seen := map[cellKey]bool{}
	traceOf := map[blockLoad]string{}
	ownerOf := map[string]blockLoad{}
	perBlock := map[int]int{}
	for i := range cells {
		m := &cells[i]
		if m.Study != st.ID {
			return nil, fmt.Errorf("cell %d (%s) belongs to study %s and the campaign to %s", i, m.Arm, m.Study, st.ID)
		}
		_, load, ok := ParseVersionStudyArm(m.Arm)
		if !ok {
			return nil, fmt.Errorf("cell %d: arm %q is not one of the version study's arms", i, m.Arm)
		}
		if m.Cell == nil {
			return nil, fmt.Errorf("cell %d (%s) carries no cell identity, so it cannot be placed in a block", i, m.Arm)
		}
		if ref == nil {
			ref = m
		}
		switch {
		case m.Cell.CampaignID != ref.Cell.CampaignID:
			return nil, fmt.Errorf("cell %d (%s) is from campaign %q and the first cell from %q", i, m.Arm, m.Cell.CampaignID, ref.Cell.CampaignID)
		case m.Cell.CapacityRequestsPerSec != ref.Cell.CapacityRequestsPerSec || m.Cell.CapacityArtifactSHA256 != ref.Cell.CapacityArtifactSHA256:
			// One λ0 for every treatment is the registered design; two would make 0.9 λ0 different offered work per arm.
			return nil, fmt.Errorf("cell %d (%s) derives its load from capacity %v (%s) and the first cell from %v (%s)", i, m.Arm,
				m.Cell.CapacityRequestsPerSec, m.Cell.CapacityArtifactSHA256, ref.Cell.CapacityRequestsPerSec, ref.Cell.CapacityArtifactSHA256)
		case m.Model != ref.Model:
			return nil, fmt.Errorf("cell %d (%s) served model %q and the first cell %q", i, m.Arm, m.Model, ref.Model)
		case m.TokenizerRev != ref.TokenizerRev:
			return nil, fmt.Errorf("cell %d (%s) names tokenizer %q and the first cell %q", i, m.Arm, m.TokenizerRev, ref.TokenizerRev)
		}
		k := cellKey{m.Cell.Block, m.Arm}
		if seen[k] {
			return nil, fmt.Errorf("block %d arm %s is recorded twice; a rerun replaces a block, it does not add to one", k.block, k.arm)
		}
		seen[k] = true
		perBlock[k.block]++

		bl := blockLoad{m.Cell.Block, load}
		if prev, ok := traceOf[bl]; ok && prev != m.TraceChecksum {
			return nil, fmt.Errorf("block %d at %s: %s replays trace %s and another treatment replays %s; a block's treatments share one workload",
				bl.block, load, m.Arm, m.TraceChecksum, prev)
		}
		traceOf[bl] = m.TraceChecksum
		if other, ok := ownerOf[m.TraceChecksum]; ok && other != bl {
			return nil, fmt.Errorf("blocks %d (%s) and %d (%s) replay the same trace %s; each block draws its own workload",
				other.block, other.load, bl.block, bl.load, m.TraceChecksum)
		}
		ownerOf[m.TraceChecksum] = bl
	}
	var complete []int
	for block, n := range perBlock {
		if n == len(st.Arms) {
			complete = append(complete, block)
		}
	}
	slices.Sort(complete)
	if len(complete) < st.Version.PlannedBlocks {
		return complete, fmt.Errorf("not confirmatory: %d complete block(s) %v of the registered %d; no adopt, equivalent or reject verdict may be published",
			len(complete), complete, st.Version.PlannedBlocks)
	}
	return complete, nil
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

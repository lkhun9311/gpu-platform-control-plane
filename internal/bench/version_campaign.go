package bench

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"time"

	"sigs.k8s.io/yaml"
)

// The version pilot's frozen campaign bundle, its attempt ledger, and the per-request classification the analysis applies.
// Registered in docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md.

// CalibrationArtifact is the file calibration writes before block 1; the bundle pins its bytes.
type CalibrationArtifact struct {
	Resolved                 bool              `json:"resolved"`
	StableRateRequestsPerSec float64           `json:"stableRateRequestsPerSec"`
	Reason                   string            `json:"reason,omitempty"`
	Rungs                    []CalibrationRung `json:"rungs,omitempty"`
}

// BundleTrace is one pre-generated workload: the trace every treatment of a block replays at a load.
type BundleTrace struct {
	Block        int    `json:"block"`
	Load         string `json:"load"`
	Path         string `json:"path"`
	SHA256       string `json:"sha256"`
	Seed         int64  `json:"seed"`
	MeasuredRows int    `json:"measuredRows"`
}

// CampaignBundle freezes everything a campaign's cells are compared against, written after calibration and before block 1.
//
// Every cell's manifest names the bundle's sha256, so a cell cannot be paired with a bundle it was not run under (attack item 8).
type CampaignBundle struct {
	Study                    string  `json:"study"`
	CampaignID               string  `json:"campaignId"`
	Model                    string  `json:"model"`
	ModelRevision            string  `json:"modelRevision"`
	TokenizerRevision        string  `json:"tokenizerRevision"`
	ChatTemplateSHA256       string  `json:"chatTemplateSHA256"`
	StableRateRequestsPerSec float64 `json:"stableRateRequestsPerSec"`
	// CalibrationArtifact is a path relative to the bundle, and its sha256 is recomputed from the file's bytes.
	CalibrationArtifact       string `json:"calibrationArtifact"`
	CalibrationArtifactSHA256 string `json:"calibrationArtifactSHA256"`
	WindowSeconds             int    `json:"windowSeconds"`
	// PriceUSDPerHour is the instance's on-demand price as read at PriceReadAt from PriceSource; OtherChargesUSDPerHour the rest of the session's rate.
	PriceUSDPerHour        float64 `json:"priceUSDPerHour"`
	PriceSource            string  `json:"priceSource"`
	PriceReadAt            string  `json:"priceReadAt"`
	OtherChargesUSDPerHour float64 `json:"otherChargesUSDPerHour"`
	// Images maps each treatment to the digest-pinned image it runs.
	Images map[string]string `json:"images"`
	// Traces holds one trace per block and load, the replacement blocks' included, all generated before block 1.
	Traces []BundleTrace `json:"traces"`
}

// LoadCampaignBundle reads a bundle, verifies every file it names by content, and returns it with its own sha256.
func LoadCampaignBundle(path string) (*CampaignBundle, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("read bundle %s: %w", path, err)
	}
	var b CampaignBundle
	if err := yaml.UnmarshalStrict(data, &b); err != nil {
		return nil, "", fmt.Errorf("parse bundle %s: %w", path, err)
	}
	if err := checkBundleKeys(data); err != nil {
		return nil, "", fmt.Errorf("bundle %s: %w", path, err)
	}
	if err := b.verify(filepath.Dir(path)); err != nil {
		return nil, "", fmt.Errorf("bundle %s: %w", path, err)
	}
	return &b, Checksum(data), nil
}

// checkBundleKeys refuses unknown, wrong-case, null and missing keys, at the top and in every trace entry.
func checkBundleKeys(data []byte) error {
	var raw map[string]any
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return err
	}
	if err := checkKeys("bundle", raw, reflect.TypeFor[CampaignBundle](), true); err != nil {
		return err
	}
	traces, _ := raw["traces"].([]any)
	for i, t := range traces {
		m, ok := t.(map[string]any)
		if !ok {
			return fmt.Errorf("traces[%d] is not an object", i)
		}
		if err := checkKeys(fmt.Sprintf("traces[%d]", i), m, reflect.TypeFor[BundleTrace](), true); err != nil {
			return err
		}
	}
	return nil
}

func (b *CampaignBundle) verify(dir string) error {
	st, ok := LookupStudy(b.Study)
	if !ok || st.Version == nil || st.Sampling == nil {
		return fmt.Errorf("study %q is not a version study", b.Study)
	}
	d := st.Version
	if err := d.PreflightRefusal(); err != nil {
		return err
	}
	switch {
	case b.CampaignID == "":
		return fmt.Errorf("campaignId is empty")
	case b.Model != d.Model:
		return fmt.Errorf("model %q is not the registered %q", b.Model, d.Model)
	case b.ModelRevision != d.ModelRevision:
		return fmt.Errorf("modelRevision %q is not the registered %q", b.ModelRevision, d.ModelRevision)
	case b.TokenizerRevision != d.TokenizerRevision:
		return fmt.Errorf("tokenizerRevision %q is not the registered %q", b.TokenizerRevision, d.TokenizerRevision)
	case b.ChatTemplateSHA256 != d.ChatTemplateSHA256:
		return fmt.Errorf("chat template %q is not the registered %q", b.ChatTemplateSHA256, d.ChatTemplateSHA256)
	case !(b.PriceUSDPerHour > 0) || math.IsInf(b.PriceUSDPerHour, 0) || b.PriceSource == "":
		return fmt.Errorf("price %v from %q is not a read price", b.PriceUSDPerHour, b.PriceSource)
	case !(b.OtherChargesUSDPerHour >= 0) || math.IsInf(b.OtherChargesUSDPerHour, 0):
		return fmt.Errorf("otherChargesUSDPerHour %v is not a non-negative rate", b.OtherChargesUSDPerHour)
	}
	if _, err := time.Parse(time.RFC3339, b.PriceReadAt); err != nil {
		return fmt.Errorf("priceReadAt %q: %w", b.PriceReadAt, err)
	}
	for _, t := range versionStudyTreatments {
		ref := b.Images[t]
		if !digestPinned(ref) || imageDigest(ref) != imageDigest(d.Engines[t].Image) {
			return fmt.Errorf("image of treatment %s %q is not the registered %q", t, ref, d.Engines[t].Image)
		}
	}
	if err := b.verifyCalibration(dir, *d, *st.Sampling); err != nil {
		return err
	}
	return b.verifyTraces(dir, d)
}

// verifyCalibration recomputes the artifact's hash from its bytes and reads λ0 back from it.
func (b *CampaignBundle) verifyCalibration(dir string, d VersionStudyDesign, sampling SamplingPolicy) error {
	data, err := os.ReadFile(filepath.Join(dir, b.CalibrationArtifact))
	if err != nil {
		return fmt.Errorf("calibration artifact: %w", err)
	}
	if sum := Checksum(data); sum != b.CalibrationArtifactSHA256 {
		return fmt.Errorf("calibration artifact hashes to %s, the bundle declares %s", sum, b.CalibrationArtifactSHA256)
	}
	var art CalibrationArtifact
	if err := yaml.UnmarshalStrict(data, &art); err != nil {
		return fmt.Errorf("calibration artifact: %w", err)
	}
	if !art.Resolved {
		return fmt.Errorf("calibration was unresolved (%s); the session stops without a λ0", art.Reason)
	}
	if art.StableRateRequestsPerSec != b.StableRateRequestsPerSec || !(b.StableRateRequestsPerSec > 0) {
		return fmt.Errorf("λ0 %v in the bundle is not the artifact's %v", b.StableRateRequestsPerSec, art.StableRateRequestsPerSec)
	}
	if err := d.VerifyCalibrationEvidence(filepath.Dir(filepath.Join(dir, b.CalibrationArtifact)), sampling, art); err != nil {
		return fmt.Errorf("calibration artifact: %w", err)
	}
	return nil
}

// verifyTraces checks every block's traces by content, then that the window is the one ChooseWindow picks from them.
func (b *CampaignBundle) verifyTraces(dir string, d *VersionStudyDesign) error {
	type key struct {
		block int
		load  string
	}
	rows := map[key][]TraceRow{}
	for _, t := range b.Traces {
		k := key{t.Block, t.Load}
		if _, dup := rows[k]; dup {
			return fmt.Errorf("trace for block %d at %s is listed twice", t.Block, t.Load)
		}
		seed, err := WorkloadSeed(d.CampaignSeed, t.Block, t.Load)
		if err != nil {
			return fmt.Errorf("trace %s: %w", t.Path, err)
		}
		if t.Seed != seed {
			return fmt.Errorf("trace %s declares seed %d; block %d at %s is seeded %d", t.Path, t.Seed, t.Block, t.Load, seed)
		}
		// Hashed and parsed from the same bytes, so what is checked is what is read (audit 26).
		data, err := os.ReadFile(filepath.Join(dir, t.Path))
		if err != nil {
			return fmt.Errorf("trace %s: %w", t.Path, err)
		}
		if sum := Checksum(data); sum != t.SHA256 {
			return fmt.Errorf("trace %s hashes to %s, the bundle declares %s", t.Path, sum, t.SHA256)
		}
		rs, err := ReadTrace(bytes.NewReader(data))
		if err != nil {
			return fmt.Errorf("trace %s: %w", t.Path, err)
		}
		if err := d.checkTraceRows(t, rs, b.WindowSeconds); err != nil {
			return fmt.Errorf("trace %s: %w", t.Path, err)
		}
		rows[k] = rs
	}
	for block := 1; block <= d.PlannedBlocks+d.MaxReplacementBlocks; block++ {
		for _, l := range versionStudyLoads {
			if _, ok := rows[key{block, l.Name}]; !ok {
				return fmt.Errorf("no trace for block %d at %s; replacement traces are generated with the planned ones", block, l.Name)
			}
		}
	}
	// The window must be the shortest the traces themselves support, so it was not stretched after the fact.
	// This relies on the generator being prefix-stable: a shorter window's trace is a prefix of a longer one's.
	w, err := d.ChooseWindow(func(block int, load string, window int) (int, error) {
		n := 0
		for _, r := range rows[key{block, load}] {
			if d.PhaseOf(r.OffsetMs, window) == PhaseMeasure {
				n++
			}
		}
		return n, nil
	})
	if err != nil {
		return err
	}
	if w != b.WindowSeconds {
		return fmt.Errorf("window %d s is not the %d s the traces choose", b.WindowSeconds, w)
	}
	return nil
}

// checkTraceRows checks one trace's rows against the registered workload and its declared measured population.
func (d *VersionStudyDesign) checkTraceRows(t BundleTrace, rows []TraceRow, windowSeconds int) error {
	exact := versionStudyExactTokens()
	tokensOf := func(chars int) int { return exact[chars] }
	inputs := make([]int, 0, len(d.InputTokens))
	outputs := make([]int, 0, len(d.OutputTokens))
	for _, lw := range d.InputTokens {
		inputs = append(inputs, lw.Tokens)
	}
	for _, lw := range d.OutputTokens {
		outputs = append(outputs, lw.Tokens)
	}
	type class struct{ in, out int }
	warm := map[class]bool{}
	measured := 0
	var prev int64 = -1
	for i, r := range rows {
		if r.Index != i || r.OffsetMs < prev {
			return fmt.Errorf("row %d is out of order", i)
		}
		prev = r.OffsetMs
		in := tokensOf(r.PromptLenChars)
		if !slices.Contains(inputs, in) || !slices.Contains(outputs, r.MaxOutputTokens) {
			return fmt.Errorf("row %d has prompt length %d characters and output cap %d, not a registered length", i, r.PromptLenChars, r.MaxOutputTokens)
		}
		switch d.PhaseOf(r.OffsetMs, windowSeconds) {
		case PhaseWarmup:
			warm[class{in, r.MaxOutputTokens}] = true
		case PhaseMeasure:
			measured++
		default:
			return fmt.Errorf("row %d at %d ms is outside warm-up and window", i, r.OffsetMs)
		}
	}
	if measured != t.MeasuredRows {
		return fmt.Errorf("%d measured rows, the bundle declares %d", measured, t.MeasuredRows)
	}
	// Warm-up qualifies only if it exercised every request shape the window will send (attack item 11).
	for _, in := range inputs {
		for _, out := range outputs {
			if !warm[class{in, out}] {
				return fmt.Errorf("warm-up never sends %d input and %d output tokens, so it does not qualify", in, out)
			}
		}
	}
	return nil
}

// RuntimeIdentity is what the running engine reports about itself, read by the engine-path track at every start.
type RuntimeIdentity struct {
	// Model and Tokenizer are what the engine loaded; the controller passes no --tokenizer, so both must be the registered model.
	Model     string
	Tokenizer string
	// InstanceID names the engine process the identity was read from, so a restarted or replaced engine is told apart; the registration does not fix it.
	InstanceID         string
	VLLMVersion        string
	Image              string
	ModelRevision      string
	TokenizerRevision  string
	ChatTemplateSHA256 string
	// ProfileArgs are the engine's profile arguments as observed on the running process, normalised by ParseProfileArgs.
	//
	// They are compared with the registration's ReviewedProfileArgs; the review file's own hash is provenance, not something an argv can match.
	ProfileArgs []string
	// Settings are the registered settings as read back from the running engine.
	Settings EngineSettings
	// Unproven names the identity fields the reader could not observe, which it left empty (UnprovenImage, UnprovenChatTemplate, UnprovenProfileArgs).
	//
	// CheckRuntime refuses an identity with any; only CheckObservedRuntime accepts them, and returns them so the caller records the gap.
	Unproven []string
}

// CompareRuntime refuses an engine that is not the one the bundle and the registration name.
func (b *CampaignBundle) CompareRuntime(d VersionStudyDesign, treatment string, rt RuntimeIdentity) error {
	switch {
	case rt.ModelRevision != b.ModelRevision:
		return fmt.Errorf("engine serves model revision %q, the bundle %q", rt.ModelRevision, b.ModelRevision)
	case rt.TokenizerRevision != b.TokenizerRevision:
		return fmt.Errorf("engine uses tokenizer %q, the bundle %q", rt.TokenizerRevision, b.TokenizerRevision)
	case rt.ChatTemplateSHA256 != b.ChatTemplateSHA256:
		return fmt.Errorf("engine applies chat template %q, the bundle %q", rt.ChatTemplateSHA256, b.ChatTemplateSHA256)
	}
	if imageDigest(rt.Image) != imageDigest(b.Images[treatment]) {
		return fmt.Errorf("engine of treatment %s runs %q, the bundle froze %q", treatment, rt.Image, b.Images[treatment])
	}
	return d.CheckRuntime(treatment, rt)
}

// AttemptStatus is how a block attempt ended.
type AttemptStatus string

const (
	// AttemptValid passed every invalidation rule in every cell.
	AttemptValid AttemptStatus = "valid"
	// AttemptInvalid failed an invalidation rule; its reason is recorded and it may be replaced once.
	AttemptInvalid AttemptStatus = "invalid"
	// AttemptStopped was cut short by the budget or the deadline; nothing runs after it.
	AttemptStopped AttemptStatus = "stopped"
)

// BlockAttempt is one ledger entry, written when the attempt ends and never edited.
type BlockAttempt struct {
	Block     int
	Status    AttemptStatus
	Reason    string
	StartedAt time.Time
	EndedAt   time.Time
	// Replaces names the invalid block this attempt replaces, or 0 for a planned block.
	Replaces int
}

// AttemptLedger is every block attempt of a campaign; Closed is set when it is archived, before any verdict is computed.
type AttemptLedger struct {
	CampaignID string
	Attempts   []BlockAttempt
	Closed     bool
	// RecorderFaults are the journal's own write failures; any one ends the campaign as an incomplete pilot (the stop rules).
	RecorderFaults []string
}

// AnalysisSet derives the analysed blocks from the ledger alone (attack item 9).
//
// Planned blocks run in order; a replacement names an invalid block, runs after every planned block has ended, and no block runs twice.
// So a valid block is never rerun and there is never a choice between valid blocks.
// Fewer valid blocks than planned is an error that still returns them, for a descriptive report with no verdict.
func (d VersionStudyDesign) AnalysisSet(l AttemptLedger) ([]int, error) {
	valid, err := d.analysedBlocks(l)
	// A failed archive leaves every block valid, so only the ledger's own record of the failure keeps the stop rule.
	if len(l.RecorderFaults) > 0 && (valid != nil || err == nil) {
		return valid, errors.Join(err, fmt.Errorf("incomplete pilot: the campaign stopped on a recorder failure (%s); no adopt, equivalent or reject is computed",
			strings.Join(l.RecorderFaults, "; ")))
	}
	return valid, err
}

// analysedBlocks applies the ledger's ordering and replacement rules.
func (d VersionStudyDesign) analysedBlocks(l AttemptLedger) ([]int, error) {
	if !l.Closed {
		return nil, fmt.Errorf("the ledger is not archived; archive it before computing anything from it")
	}
	if l.CampaignID == "" {
		return nil, fmt.Errorf("the ledger names no campaign")
	}
	byBlock := map[int]BlockAttempt{}
	var plannedEnd time.Time
	replaced := map[int]bool{}
	stopped := false
	next := 1
	var valid []int
	for i, a := range l.Attempts {
		if stopped {
			return nil, fmt.Errorf("block %d was attempted after the campaign stopped", a.Block)
		}
		if _, dup := byBlock[a.Block]; dup {
			return nil, fmt.Errorf("block %d is attempted twice; a block is replaced under a new number, never rerun", a.Block)
		}
		// Unrecorded or reversed times would let the overlap check below pass on records that establish no sequence at all.
		if a.StartedAt.IsZero() || a.EndedAt.IsZero() {
			return nil, fmt.Errorf("block %d has no recorded start or end time, so the ledger cannot show the attempts ran in sequence", a.Block)
		}
		if !a.EndedAt.After(a.StartedAt) {
			return nil, fmt.Errorf("block %d ends at %s, not after it starts at %s", a.Block, a.EndedAt.Format(time.RFC3339), a.StartedAt.Format(time.RFC3339))
		}
		if i > 0 && a.StartedAt.Before(l.Attempts[i-1].EndedAt) {
			return nil, fmt.Errorf("block %d started before the previous attempt ended; attempts run one after another", a.Block)
		}
		switch a.Status {
		case AttemptValid:
		case AttemptInvalid, AttemptStopped:
			if a.Reason == "" {
				return nil, fmt.Errorf("block %d is %s with no recorded reason", a.Block, a.Status)
			}
		default:
			return nil, fmt.Errorf("block %d has status %q", a.Block, a.Status)
		}
		if a.Block <= d.PlannedBlocks {
			if a.Block != next || a.Replaces != 0 {
				return nil, fmt.Errorf("planned block %d is out of order; block %d was due", a.Block, next)
			}
			next++
			if a.EndedAt.After(plannedEnd) {
				plannedEnd = a.EndedAt
			}
		} else {
			target, ok := byBlock[a.Replaces]
			switch {
			case a.Block > d.PlannedBlocks+d.MaxReplacementBlocks:
				return nil, fmt.Errorf("block %d is beyond the %d replacements allowed", a.Block, d.MaxReplacementBlocks)
			case a.Replaces == 0 || !ok:
				return nil, fmt.Errorf("block %d is beyond the plan and replaces no attempted block", a.Block)
			case target.Status == AttemptValid:
				return nil, fmt.Errorf("block %d replaces block %d, which was valid; a valid block is never rerun", a.Block, a.Replaces)
			case target.Status != AttemptInvalid || replaced[a.Replaces]:
				return nil, fmt.Errorf("block %d replaces block %d, which is not an unreplaced invalid attempt", a.Block, a.Replaces)
			case next <= d.PlannedBlocks || a.StartedAt.Before(plannedEnd):
				return nil, fmt.Errorf("block %d must start after every planned block has ended", a.Block)
			}
			// The block number fixes the replacement's workload seed and both orders, so a skipped number would be a chosen workload.
			if a.Block != next {
				return nil, fmt.Errorf("replacement block %d is out of order; block %d was due", a.Block, next)
			}
			next++
			replaced[a.Replaces] = true
		}
		byBlock[a.Block] = a
		switch a.Status {
		case AttemptValid:
			valid = append(valid, a.Block)
		case AttemptStopped:
			stopped = true
		}
	}
	if len(valid) != d.PlannedBlocks {
		return valid, fmt.Errorf("incomplete pilot: %d valid block(s) %v of the planned %d; no adopt, equivalent or reject is computed",
			len(valid), valid, d.PlannedBlocks)
	}
	return valid, nil
}

// CheckVersionCampaign pairs a campaign's cells through its bundle and ledger, and returns the analysed blocks.
//
// Each manifest has already passed LoadManifest.
// What one cell cannot show is how cells relate: that each replayed the bundle's trace for its block and load, under the
// bundle's λ0, model and tokenizer, and that every valid block is whole (audit findings 2, 3, 17 and 21).
// Pairing reads the identity the manifest recorded before execution, never a file name.
func CheckVersionCampaign(b *CampaignBundle, bundleSHA string, ledger AttemptLedger, cells []RunManifest) ([]int, error) {
	st, ok := LookupStudy(b.Study)
	if !ok || st.Version == nil || st.Sampling == nil {
		return nil, fmt.Errorf("study %q is not a version study", b.Study)
	}
	d := st.Version
	if ledger.CampaignID != b.CampaignID {
		return nil, fmt.Errorf("ledger is for campaign %q and the bundle for %q", ledger.CampaignID, b.CampaignID)
	}
	set, setErr := d.AnalysisSet(ledger)
	if set == nil && setErr != nil {
		return nil, setErr
	}
	attempted := map[int]AttemptStatus{}
	for _, a := range ledger.Attempts {
		attempted[a.Block] = a.Status
	}
	trace := map[[2]any]string{}
	for _, t := range b.Traces {
		trace[[2]any{t.Block, t.Load}] = t.SHA256
	}
	type cellKey struct {
		block int
		arm   string
	}
	seen := map[cellKey]bool{}
	for i := range cells {
		m := &cells[i]
		_, load, ok := ParseVersionStudyArm(m.Arm)
		switch {
		case m.Study != b.Study:
			return nil, fmt.Errorf("cell %d (%s) belongs to study %s and the campaign to %s", i, m.Arm, m.Study, b.Study)
		case !ok:
			return nil, fmt.Errorf("cell %d: arm %q is not one of the version study's arms", i, m.Arm)
		case m.Cell == nil:
			return nil, fmt.Errorf("cell %d (%s) carries no cell identity, so it cannot be placed in a block", i, m.Arm)
		case m.Cell.CampaignID != b.CampaignID:
			return nil, fmt.Errorf("cell %d (%s) is from campaign %q, the bundle from %q", i, m.Arm, m.Cell.CampaignID, b.CampaignID)
		}
		if _, ok := attempted[m.Cell.Block]; !ok {
			return nil, fmt.Errorf("cell %d (%s) is in block %d, which the ledger never attempted", i, m.Arm, m.Cell.Block)
		}
		switch {
		case m.Cell.BundleSHA256 != bundleSHA:
			return nil, fmt.Errorf("cell %d (%s) was run under bundle %s, not %s", i, m.Arm, m.Cell.BundleSHA256, bundleSHA)
		case m.Cell.StableRateRequestsPerSec != b.StableRateRequestsPerSec:
			return nil, fmt.Errorf("cell %d (%s) derives its load from λ0 %v, the bundle froze %v", i, m.Arm, m.Cell.StableRateRequestsPerSec, b.StableRateRequestsPerSec)
		case m.Model != b.Model:
			return nil, fmt.Errorf("cell %d (%s) served model %q, the bundle %q", i, m.Arm, m.Model, b.Model)
		case m.TokenizerRev != b.TokenizerRevision:
			return nil, fmt.Errorf("cell %d (%s) names tokenizer %q, the bundle %q", i, m.Arm, m.TokenizerRev, b.TokenizerRevision)
		case m.TraceChecksum != trace[[2]any{m.Cell.Block, load}]:
			return nil, fmt.Errorf("cell %d (%s) replayed trace %s, not the bundle's for block %d at %s", i, m.Arm, m.TraceChecksum, m.Cell.Block, load)
		}
		k := cellKey{m.Cell.Block, m.Arm}
		if seen[k] {
			return nil, fmt.Errorf("block %d arm %s is recorded twice", k.block, k.arm)
		}
		seen[k] = true
	}
	for _, block := range set {
		for _, arm := range st.Arms {
			if !seen[cellKey{block, arm}] {
				return nil, fmt.Errorf("valid block %d is missing its %s cell", block, arm)
			}
		}
	}
	// The window met the floor over the planned blocks' traces; a replacement's trace may offer fewer rows, so recount what is analysed.
	rows := map[[2]any]int{}
	for _, t := range b.Traces {
		rows[[2]any{t.Block, t.Load}] = t.MeasuredRows
	}
	for _, l := range versionStudyLoads {
		total := 0
		for _, block := range set {
			total += rows[[2]any{block, l.Name}]
		}
		// The shortfall bars a verdict, not the descriptive report, so the paired valid blocks are returned with the error.
		if total < d.MinOfferedPopulation {
			return set, errors.Join(setErr, fmt.Errorf("the analysed blocks %v offer %d measured requests at %s, below the registered floor of %d; no verdict is computed",
				set, total, l.Name, d.MinOfferedPopulation))
		}
	}
	return set, setErr
}

// RowDisposition is the one terminal outcome every scheduled request has.
type RowDisposition string

const (
	DispositionSuccess        RowDisposition = "success"
	DispositionHTTPError      RowDisposition = "http-error"
	DispositionStreamError    RowDisposition = "stream-error"
	DispositionTimeout        RowDisposition = "timeout"
	DispositionTransportError RowDisposition = "transport-error"
	// DispositionEngineUnavailable is a scheduled request never dispatched because the engine missed its readiness deadline.
	//
	// It is the arm's failure, not a hole in the schedule: the request is accounted for without pretending it was sent.
	DispositionEngineUnavailable RowDisposition = "engine-unavailable"
)

// IsFailure says whether the disposition counts against the reliability guardrail.
func (d RowDisposition) IsFailure() bool {
	return d != DispositionSuccess
}

// RowFacts is what the recorder observed for one scheduled request.
type RowFacts struct {
	Dispatched        bool
	EngineUnavailable bool
	HTTPStatus        int
	// StreamCompleted is a stream that ended with [DONE].
	StreamCompleted bool
	TimedOut        bool
	TransportError  bool
	UsagePresent    bool
	PromptTokens    int
	// ExpectedPromptTokens is the registered count for the row's prompt length.
	ExpectedPromptTokens int
	CompletionTokens     int
	CapTokens            int
	FinishReason         string
	ContentFrames        int
}

// ClassifyRow gives one request its disposition, or an error when the row shows the protocol was not followed.
//
// Conformance is checked on every stream that completed, before success is decided (attack item 5).
// Checking it only on successful rows was circular: success was defined to include it, so no successful row could fail it.
// A nonconforming row invalidates its cell; it is never reclassified as a failure of the arm.
func ClassifyRow(p SamplingPolicy, f RowFacts) (RowDisposition, error) {
	switch {
	case !f.Dispatched && f.EngineUnavailable:
		return DispositionEngineUnavailable, nil
	case !f.Dispatched:
		return "", fmt.Errorf("a scheduled request was not dispatched and the engine was not recorded unavailable")
	case f.TimedOut:
		return DispositionTimeout, nil
	case f.TransportError:
		return DispositionTransportError, nil
	case f.HTTPStatus != 200:
		return DispositionHTTPError, nil
	case !f.StreamCompleted:
		return DispositionStreamError, nil
	}
	if !f.UsagePresent {
		return "", fmt.Errorf("a completed stream carried no usage, so its output cannot be counted")
	}
	if f.ExpectedPromptTokens <= 0 || f.PromptTokens != f.ExpectedPromptTokens {
		return "", fmt.Errorf("prompt tokenized to %d tokens, registered %d", f.PromptTokens, f.ExpectedPromptTokens)
	}
	if err := p.CheckCompletion(f.CapTokens, f.CompletionTokens, f.FinishReason); err != nil {
		return "", err
	}
	return DispositionSuccess, nil
}

// GoodRequest says whether one request counts toward goodput.
//
// A response delivered in fewer than two content frames has no client-observed TPOT, and is not counted good rather than given a TPOT of zero (attack item 12).
func GoodRequest(slo SLO, d RowDisposition, ttftMs, tpotMs float64, contentFrames int) bool {
	return d == DispositionSuccess && contentFrames >= 2 && ttftMs <= slo.TTFTMs && tpotMs <= slo.TPOTMs
}

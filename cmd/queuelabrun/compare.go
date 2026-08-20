package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// comparisonSchemaVersion is versioned for the same reason the run record's is: a consumer classifies on the
// fields below, and a reworded or re-derived field would silently become a different claim.
const comparisonSchemaVersion = 1

// comparison is what a SET of records supports about the difference between their arms.
//
// It exists because the runs were reproducible and the conclusion was not. Every record in ex/ carries its
// own verdict, its own ledger and enough to re-derive its own numbers; the sentence those records were
// gathered to support — that honouring SIGTERM discards work and ignoring it defeats the reclaim — lived in
// a markdown file and in ad-hoc arithmetic typed at a shell. Nobody could reproduce the CONCLUSION from the
// artifacts, only the runs, and a lab whose conclusion is not an artifact is a lab that publishes prose.
//
// What it deliberately does NOT do is inference. There is no p-value here, no interval, and no threshold on
// how many runs make a difference real, because this build has no basis for one: the runs are not sampled
// from anything and their variance has never been characterised. It answers exactly three questions, each of
// which the records can actually settle — is the difference bigger than what the instrument could see, is
// the arm confounded with the order the runs were taken in, and how many runs are behind each arm — and it
// says "not resolved" whenever the first answer is no. Returning "not resolved" is its main job, not its
// failure mode.
type comparison struct {
	SchemaVersion int `json:"schemaVersion"`
	// Dose is the regime every contributing record shared. Records from different regimes measure different
	// quantities, so a comparison across them is refused rather than reported.
	Dose string `json:"dose"`
	// Arms summarises each arm's contributing runs.
	Arms []armSummary `json:"arms"`
	// FloorSeconds is the coarsest resolution any contributing run had, and it governs the whole comparison:
	// a set of runs cannot distinguish something more finely than its worst-resolved member could.
	FloorSeconds float64 `json:"floorSeconds"`
	// Bounded is false when any contributing run bounded nothing, in which case nothing here is resolved.
	// The zero value is the safe one: an unbounded comparison resolves nothing.
	Bounded bool `json:"bounded"`
	// Interleaved is whether the arms alternate in the order the runs were actually taken.
	//
	// When false, every difference below is confounded with time: node warming, image cache state and any
	// drift in the cluster all move together with the arm, and nothing in the numbers can separate them.
	Interleaved bool `json:"interleaved"`
	// DeviceEvidence is the weakest axis among the contributing runs, because a comparison can establish
	// device work only if every run behind it did. One run that observed nothing makes the whole document a
	// statement about seconds of RESERVATION, and stating the strongest contributor's value instead would
	// launder that run's silence through its neighbours.
	DeviceEvidence string `json:"deviceEvidence"`
	// Findings is one entry per quantity and arm pair.
	Findings []finding `json:"findings"`
	// Note states, in the document, what this comparison is not.
	Note string `json:"note"`
}

// armSummary is one arm's contribution, including when its runs were taken.
//
// The time span is here rather than only in the interleaving verdict because the alternation test is coarse:
// four runs alternating A,B,A,B pass it, and so do six where the last two A runs were taken six hours after
// everything else. The span lets a reader see that without the tool having to invent a rule about how far
// apart is too far.
type armSummary struct {
	Arm    string   `json:"arm"`
	N      int      `json:"n"`
	RunIDs []string `json:"runIDs"`
	// WastedGPUSecondsMean, Min and Max describe this arm's runs. The spread is reported rather than a
	// standard deviation because two or three runs do not describe a distribution and a summary statistic
	// would imply they do.
	WastedGPUSecondsMean float64 `json:"wastedGPUSecondsMean"`
	WastedGPUSecondsMin  float64 `json:"wastedGPUSecondsMin"`
	WastedGPUSecondsMax  float64 `json:"wastedGPUSecondsMax"`
	// OwnerWaitSecondsMean is the quota owner's admission-to-running wait, averaged over this arm's runs, and
	// OwnerWaitRuns is how many of them restored their owner at all. The count is carried rather than implied
	// because a mean over a subset of the arm is a different statistic from a mean over the arm, and the run
	// where the owner never came back is the one a reader most needs to know about.
	OwnerWaitSecondsMean float64 `json:"ownerWaitSecondsMean,omitempty"`
	OwnerWaitSecondsMin  float64 `json:"ownerWaitSecondsMin,omitempty"`
	OwnerWaitSecondsMax  float64 `json:"ownerWaitSecondsMax,omitempty"`
	OwnerWaitRuns        int     `json:"ownerWaitRuns"`
	FirstStartedAt       string  `json:"firstStartedAt"`
	LastStartedAt        string  `json:"lastStartedAt"`
}

// finding is one quantity compared across one pair of arms.
type finding struct {
	Quantity string  `json:"quantity"`
	ArmA     string  `json:"armA"`
	ArmB     string  `json:"armB"`
	ValueA   float64 `json:"valueA"`
	ValueB   float64 `json:"valueB"`
	// DifferenceSeconds is |ValueA - ValueB|.
	DifferenceSeconds float64 `json:"differenceSeconds"`
	// Resolved is the only claim this document makes about the difference, and it is a claim about the
	// INSTRUMENT rather than about the world: true means the difference is larger than the coarsest
	// resolution among the contributing runs, so the harness could see it at all.
	Resolved bool `json:"resolved"`
	// Statement is the sentence a reader may quote. It is generated from the fields above so that it cannot
	// drift from them, which is exactly how the retracted claim survived review the first time.
	Statement string `json:"statement"`
}

// compareRecords builds the comparison, or refuses.
//
// Refusal rather than exclusion is the rule, and it is worth stating why, because dropping the offending
// records and comparing the rest is friendlier and wrong. The record set is named explicitly by whoever runs
// this; silently narrowing it produces a document whose file list does not describe the evidence behind it,
// which is the reproducibility this tool exists to provide. An operator who wants a subset names the subset.
func compareRecords(recs []runRecord) (comparison, error) {
	if len(recs) < 2 {
		return comparison{}, fmt.Errorf("a comparison needs at least 2 records, got %d", len(recs))
	}
	dose := recs[0].Dose
	for _, r := range recs {
		if r.Validity.Verdict != verdictAdmissible {
			return comparison{}, fmt.Errorf("run %q has verdict %q: a comparison is built only from records "+
				"whose own gates passed, and excluding it silently would leave this document's file list "+
				"describing evidence it does not contain", r.RunID, r.Validity.Verdict)
		}
		if r.Measurement == nil {
			return comparison{}, fmt.Errorf("run %q carries no measurement", r.RunID)
		}
		if r.Dose != dose {
			return comparison{}, fmt.Errorf("run %q is dose %q and run %q is dose %q: the two regimes measure "+
				"different quantities, so a difference between them answers no single question",
				recs[0].RunID, dose, r.RunID, r.Dose)
		}
	}

	byArm := map[string][]runRecord{}
	for _, r := range recs {
		byArm[r.Arm] = append(byArm[r.Arm], r)
	}
	if len(byArm) < 2 {
		return comparison{}, fmt.Errorf("every record is arm %q: there is nothing to compare", recs[0].Arm)
	}

	floorNs, bounded := pooledFloorNs(recs)
	c := comparison{
		SchemaVersion:  comparisonSchemaVersion,
		Dose:           dose,
		FloorSeconds:   float64(floorNs) / float64(time.Second),
		Bounded:        bounded,
		Interleaved:    armsInterleave(recs),
		DeviceEvidence: pooledDeviceEvidence(recs),
		Note: "this document reports whether a difference exceeded the coarsest resolution among the runs " +
			"behind it, whether the arms were interleaved in time, and how many runs each arm has. It makes " +
			"no claim of statistical significance and establishes no effect: these runs are not a sample of " +
			"anything and their variance has never been characterised",
	}

	arms := make([]string, 0, len(byArm))
	for a := range byArm {
		arms = append(arms, a)
	}
	sort.Strings(arms)
	for _, a := range arms {
		c.Arms = append(c.Arms, summariseArm(a, byArm[a]))
	}
	for i := 0; i < len(c.Arms); i++ {
		for j := i + 1; j < len(c.Arms); j++ {
			c.Findings = append(c.Findings, compareWaste(c.Arms[i], c.Arms[j], floorNs, bounded, c.Interleaved))
			c.Findings = append(c.Findings, compareOwnerWait(c.Arms[i], c.Arms[j], floorNs, bounded, c.Interleaved))
		}
	}
	return c, nil
}

// pooledDeviceEvidence is the weakest axis among the contributors, for the same reason the floor is the
// coarsest: a set of runs establishes only what its weakest member did.
func pooledDeviceEvidence(recs []runRecord) string {
	for _, r := range recs {
		if r.Validity.DeviceEvidence != deviceWorkObserved {
			return deviceNotObserved
		}
	}
	return deviceWorkObserved
}

// pooledFloorNs is the coarsest floor among the contributing runs, and false when any of them had none.
//
// The maximum rather than a mean or the best one: a set of runs cannot distinguish anything more finely than
// its worst-resolved member, because that member's number is in every difference it contributes to. And a
// single unbounded run makes the whole comparison unbounded for the same reason — there is no bound to pool.
func pooledFloorNs(recs []runRecord) (int64, bool) {
	var worst int64
	for _, r := range recs {
		if r.Measurement.Resolution == nil {
			return 0, false
		}
		if f := r.Measurement.Resolution.ResolvedToNs; f > worst {
			worst = f
		}
	}
	return worst, worst > 0
}

// armsInterleave reports whether the arms alternate in the order the runs were started.
//
// The test is that the sorted sequence of arms contains more consecutive blocks than there are arms, which
// is exactly the condition that some arm was returned to after another had run. Four runs taken A,B,A,B give
// four blocks over two arms and interleave; the same four taken A,A,B,B give two blocks over two arms and do
// not, and in that second case every difference between them is confounded with whatever changed over the
// morning.
//
// A record without a start time makes the answer unknown, and unknown is reported as not interleaved: the
// confounding either happened or cannot be ruled out, and those two are the same for a reader deciding how
// much to trust the difference.
func armsInterleave(recs []runRecord) bool {
	type started struct {
		at  time.Time
		arm string
	}
	seq := make([]started, 0, len(recs))
	distinct := map[string]struct{}{}
	for _, r := range recs {
		t, err := time.Parse(time.RFC3339, r.StartedAt)
		if err != nil {
			return false
		}
		seq = append(seq, started{at: t, arm: r.Arm})
		distinct[r.Arm] = struct{}{}
	}
	sort.Slice(seq, func(i, j int) bool { return seq[i].at.Before(seq[j].at) })
	blocks := 0
	for i, s := range seq {
		if i == 0 || seq[i-1].arm != s.arm {
			blocks++
		}
	}
	return blocks > len(distinct)
}

// summariseArm reduces one arm's runs to what a comparison may say about them.
func summariseArm(arm string, recs []runRecord) armSummary {
	sort.Slice(recs, func(i, j int) bool { return recs[i].StartedAt < recs[j].StartedAt })
	s := armSummary{
		Arm:                 arm,
		N:                   len(recs),
		WastedGPUSecondsMin: recs[0].Measurement.WastedGPUSeconds,
		WastedGPUSecondsMax: recs[0].Measurement.WastedGPUSeconds,
		FirstStartedAt:      recs[0].StartedAt,
		LastStartedAt:       recs[len(recs)-1].StartedAt,
	}
	var sum float64
	for _, r := range recs {
		s.RunIDs = append(s.RunIDs, r.RunID)
		w := r.Measurement.WastedGPUSeconds
		sum += w
		if w < s.WastedGPUSecondsMin {
			s.WastedGPUSecondsMin = w
		}
		if w > s.WastedGPUSecondsMax {
			s.WastedGPUSecondsMax = w
		}
	}
	s.WastedGPUSecondsMean = sum / float64(len(recs))

	var waitSum float64
	for _, r := range recs {
		if r.Measurement.OwnerAdmitToReadyNs == nil {
			continue
		}
		w := float64(*r.Measurement.OwnerAdmitToReadyNs) / float64(time.Second)
		if s.OwnerWaitRuns == 0 {
			s.OwnerWaitSecondsMin, s.OwnerWaitSecondsMax = w, w
		}
		if w < s.OwnerWaitSecondsMin {
			s.OwnerWaitSecondsMin = w
		}
		if w > s.OwnerWaitSecondsMax {
			s.OwnerWaitSecondsMax = w
		}
		waitSum += w
		s.OwnerWaitRuns++
	}
	if s.OwnerWaitRuns > 0 {
		s.OwnerWaitSecondsMean = waitSum / float64(s.OwnerWaitRuns)
	}
	return s
}

// compareWaste states what the two arms' discarded work supports, and nothing beyond it.
func compareWaste(a, b armSummary, floorNs int64, bounded, interleaved bool) finding {
	diff := a.WastedGPUSecondsMean - b.WastedGPUSecondsMean
	if diff < 0 {
		diff = -diff
	}
	f := finding{
		Quantity:          "wastedGPUSeconds",
		ArmA:              a.Arm,
		ArmB:              b.Arm,
		ValueA:            a.WastedGPUSecondsMean,
		ValueB:            b.WastedGPUSecondsMean,
		DifferenceSeconds: diff,
		Resolved:          bounded && diff > float64(floorNs)/float64(time.Second),
	}
	f.Statement = wasteStatement(f, floorNs, bounded, interleaved, a, b)
	return f
}

// wasteStatement writes the one sentence a reader may quote, from the fields beside it.
//
// It is generated rather than written by hand because the failure this whole file exists to prevent is a
// sentence that outlives the numbers it was true of. A hand-written line saying "honouring SIGTERM costs 41
// GPU-seconds" stayed correct-looking after the harness learned it could not resolve the residual inside it.
func wasteStatement(f finding, floorNs int64, bounded, interleaved bool, a, b armSummary) string {
	var sb strings.Builder
	if !bounded {
		fmt.Fprintf(&sb, "NOT RESOLVED: a contributing run bounded nothing, so the %.1f s gap between %s and %s "+
			"is not known to be larger than what the harness could see", f.DifferenceSeconds, f.ArmA, f.ArmB)
		return sb.String()
	}
	floor := float64(floorNs) / float64(time.Second)
	if !f.Resolved {
		fmt.Fprintf(&sb, "NOT RESOLVED: %s and %s differ by %.3f s, which is inside this comparison's %.3f s "+
			"floor. No number of repetitions changes that -- a resolution limit is not a noise level",
			f.ArmA, f.ArmB, f.DifferenceSeconds, floor)
		return sb.String()
	}
	fmt.Fprintf(&sb, "%s discarded %.1f GPU-s and %s discarded %.1f, a difference of %.1f s against a %.3f s "+
		"floor, over n=%d and n=%d runs", f.ArmA, f.ValueA, f.ArmB, f.ValueB, f.DifferenceSeconds, floor, a.N, b.N)
	if !interleaved {
		sb.WriteString(". CONFOUNDED: the arms did not alternate in time, so this difference moves together " +
			"with everything else that changed between the two blocks of runs")
	}
	return sb.String()
}

// compareOwnerWait states what the two arms cost the quota OWNER, which is the only quantity here that a
// platform promises anybody.
//
// The discarded seconds beside it are the borrower's loss: real, and not a service-level objective. "Your
// reclaimed capacity comes back within X" is, and this is X.
func compareOwnerWait(a, b armSummary, floorNs int64, bounded, interleaved bool) finding {
	f := finding{Quantity: "ownerAdmitToReadySeconds", ArmA: a.Arm, ArmB: b.Arm}
	if a.OwnerWaitRuns == 0 || b.OwnerWaitRuns == 0 {
		f.Statement = fmt.Sprintf("NOT COMPUTED: %s restored its owner in %d of %d runs and %s in %d of %d; "+
			"an arm whose owner never came back has no wait to average, and averaging the others would "+
			"report the best case of an arm defined by its worst",
			a.Arm, a.OwnerWaitRuns, a.N, b.Arm, b.OwnerWaitRuns, b.N)
		return f
	}
	f.ValueA, f.ValueB = a.OwnerWaitSecondsMean, b.OwnerWaitSecondsMean
	diff := f.ValueA - f.ValueB
	if diff < 0 {
		diff = -diff
	}
	f.DifferenceSeconds = diff
	f.Resolved = bounded && diff > float64(floorNs)/float64(time.Second)
	floor := float64(floorNs) / float64(time.Second)
	switch {
	case !bounded:
		f.Statement = fmt.Sprintf("NOT RESOLVED: a contributing run bounded nothing, so the %.1f s gap "+
			"between %s and %s is not known to be larger than what the harness could see", diff, a.Arm, b.Arm)
	case !f.Resolved:
		f.Statement = fmt.Sprintf("NOT RESOLVED: the owner waited %.3f s under %s and %.3f s under %s, a "+
			"difference inside this comparison's %.3f s floor", f.ValueA, a.Arm, f.ValueB, b.Arm, floor)
	default:
		f.Statement = fmt.Sprintf("the quota owner waited %.3f s under %s and %.3f s under %s -- a difference "+
			"of %.1f s against a %.3f s floor, over n=%d and n=%d restored runs. This is the number a "+
			"reclaim promise is judged on; the discarded seconds beside it are the borrower's loss",
			f.ValueA, a.Arm, f.ValueB, b.Arm, diff, floor, a.OwnerWaitRuns, b.OwnerWaitRuns)
	}
	if f.Resolved && !interleaved {
		f.Statement += ". CONFOUNDED: the arms did not alternate in time"
	}
	return f
}

// renderComparison prints the comparison, leading with what it does not establish.
//
// The order is the argument. A reader who stops after the first screen should have read the limits, not the
// headline, because the headline is the part that travels into a slide unaccompanied.
func renderComparison(c comparison) string {
	var b strings.Builder
	fmt.Fprintf(&b, "===== COMPARISON (dose %s) =====\n", c.Dose)
	if !c.Bounded {
		b.WriteString("UNBOUNDED: a contributing run carried no resolution, so nothing below is resolved\n")
	} else {
		fmt.Fprintf(&b, "floor=%.3fs -- the coarsest resolution among the contributing runs\n", c.FloorSeconds)
	}
	if !c.Interleaved {
		b.WriteString("NOT INTERLEAVED: the arms did not alternate in time, so every difference below is " +
			"confounded with the order the runs were taken in\n")
	} else {
		b.WriteString("interleaved: the arms alternated in time\n")
	}
	b.WriteString("no effect is claimed: this tool reports resolution and confounding, not inference\n")
	if c.DeviceEvidence != deviceWorkObserved {
		b.WriteString("device: NOT OBSERVED -- every GPU-second below is a second of RESERVATION. No run " +
			"behind this comparison established that a device did work, so nothing here is a statement " +
			"about GPU computation\n")
	}
	for _, a := range c.Arms {
		fmt.Fprintf(&b, "  %-9s n=%d waste mean=%.3f min=%.3f max=%.3f runs=%s\n    %s .. %s\n",
			a.Arm, a.N, a.WastedGPUSecondsMean, a.WastedGPUSecondsMin, a.WastedGPUSecondsMax,
			strings.Join(a.RunIDs, ","), a.FirstStartedAt, a.LastStartedAt)
		if a.OwnerWaitRuns == 0 {
			fmt.Fprintf(&b, "    ownerWait: NONE of %d runs restored the quota owner\n", a.N)
			continue
		}
		fmt.Fprintf(&b, "    ownerWait mean=%.3f min=%.3f max=%.3f over %d of %d runs\n",
			a.OwnerWaitSecondsMean, a.OwnerWaitSecondsMin, a.OwnerWaitSecondsMax, a.OwnerWaitRuns, a.N)
	}
	for _, f := range c.Findings {
		fmt.Fprintf(&b, "  [%s] %s\n", f.Quantity, f.Statement)
	}
	return b.String()
}

// runCompare is the -compare mode: read the named records, compare them, print and optionally persist.
//
// It writes the document only when asked, and the flag's help says what declining costs: a comparison that
// exists on a terminal and nowhere else is exactly the state this file was written to end.
func runCompare(spec, outPath string, doseCheck bool) error {
	paths, err := expandRecordSpec(spec)
	if err != nil {
		return err
	}
	recs := make([]runRecord, 0, len(paths))
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			return fmt.Errorf("read %s: %w", p, err)
		}
		r, err := decodeRunRecord(b)
		if err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		recs = append(recs, r)
	}
	var doc any
	if doseCheck {
		d, err := checkDoseSensitivity(recs)
		if err != nil {
			return err
		}
		fmt.Print(renderDoseSensitivity(d))
		doc = d
	} else {
		c, err := compareRecords(recs)
		if err != nil {
			return err
		}
		fmt.Print(renderComparison(c))
		doc = c
	}
	if outPath == "" {
		return nil
	}
	b, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("encode comparison: %w", err)
	}
	if err := os.WriteFile(outPath, append(b, '\n'), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", outPath, err)
	}
	fmt.Fprintln(os.Stderr, "  comparison:", outPath)
	return nil
}

// expandRecordSpec turns a comma-separated list of paths or globs into the files to read.
//
// A glob matching nothing is an error rather than an empty contribution, because the shell-quoted pattern
// that silently matches no files is how a comparison ends up built from half the runs its author believed
// they had passed it.
func expandRecordSpec(spec string) ([]string, error) {
	var out []string
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		matches, err := filepath.Glob(part)
		if err != nil {
			return nil, fmt.Errorf("bad pattern %q: %w", part, err)
		}
		if len(matches) == 0 {
			return nil, fmt.Errorf("%q matched no files", part)
		}
		out = append(out, matches...)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("-compare named no files")
	}
	sort.Strings(out)
	return out, nil
}

// doseSensitivity is whether a quantity moves with the protocol's dose.
//
// It is a separate document from comparison because it answers a separate question, and because compareRecords
// REFUSES to pool records from two dose regimes -- correctly, since the regimes measure different quantities
// and a difference between them answers nothing. That refusal is right about the borrower's discarded seconds,
// which the trace determines outright, and it is too coarse for the owner's wait: whether THAT moves with the
// dose is not an assumption to be protected, it is the question.
//
// It exists because the answer decides whether the real-GPU session has a baseline at all. A GPU workload will
// not have this one's service time, so any quantity the dose determines cannot be differenced against these
// runs. A quantity that does not move with it can.
type doseSensitivity struct {
	SchemaVersion int    `json:"schemaVersion"`
	Arm           string `json:"arm"`
	// Doses is one entry per regime, each summarising that regime's runs of this arm.
	Doses []doseGroup `json:"doses"`
	// FloorSeconds is the coarsest resolution among every contributing run.
	FloorSeconds float64 `json:"floorSeconds"`
	Bounded      bool    `json:"bounded"`
	// SpreadSeconds is the largest gap between any two regimes' mean owner wait.
	SpreadSeconds float64 `json:"spreadSeconds"`
	// MovesWithDose is true when that spread EXCEEDS the floor, meaning the harness can see the quantity
	// responding to the dose. False means it could not see a response, which is not the same as proving there
	// is none -- Statement says which of the two this is.
	MovesWithDose bool   `json:"movesWithDose"`
	Statement     string `json:"statement"`
}

// doseGroup is one regime's runs of the arm under test.
type doseGroup struct {
	Dose                 string   `json:"dose"`
	N                    int      `json:"n"`
	RunIDs               []string `json:"runIDs"`
	OwnerWaitSecondsMean float64  `json:"ownerWaitSecondsMean"`
	OwnerWaitRuns        int      `json:"ownerWaitRuns"`
}

// checkDoseSensitivity builds the document, or refuses.
func checkDoseSensitivity(recs []runRecord) (doseSensitivity, error) {
	if len(recs) < 2 {
		return doseSensitivity{}, fmt.Errorf("a dose-sensitivity check needs at least 2 records, got %d", len(recs))
	}
	arm := recs[0].Arm
	byDose := map[string][]runRecord{}
	for _, r := range recs {
		if r.Validity.Verdict != verdictAdmissible {
			return doseSensitivity{}, fmt.Errorf("run %q has verdict %q", r.RunID, r.Validity.Verdict)
		}
		if r.Measurement == nil {
			return doseSensitivity{}, fmt.Errorf("run %q carries no measurement", r.RunID)
		}
		// One arm only. Pooling arms here would measure the arm difference and call it a dose response, which
		// is the confusion this whole document exists to keep out of the GPU session's baseline.
		if r.Arm != arm {
			return doseSensitivity{}, fmt.Errorf("run %q is arm %q and run %q is arm %q: a dose-sensitivity "+
				"check varies the dose and holds the arm fixed, or it measures the arms and calls it a dose",
				recs[0].RunID, arm, r.RunID, r.Arm)
		}
		byDose[r.Dose] = append(byDose[r.Dose], r)
	}
	if len(byDose) < 2 {
		return doseSensitivity{}, fmt.Errorf("every record is dose %q: nothing varies", recs[0].Dose)
	}

	floorNs, bounded := pooledFloorNs(recs)
	d := doseSensitivity{SchemaVersion: comparisonSchemaVersion, Arm: arm,
		FloorSeconds: float64(floorNs) / float64(time.Second), Bounded: bounded}

	doses := make([]string, 0, len(byDose))
	for k := range byDose {
		doses = append(doses, k)
	}
	sort.Strings(doses)
	for _, dose := range doses {
		g := doseGroup{Dose: dose}
		var sum float64
		for _, r := range byDose[dose] {
			g.N++
			g.RunIDs = append(g.RunIDs, r.RunID)
			if r.Measurement.OwnerAdmitToReadyNs == nil {
				continue
			}
			sum += float64(*r.Measurement.OwnerAdmitToReadyNs) / float64(time.Second)
			g.OwnerWaitRuns++
		}
		if g.OwnerWaitRuns == 0 {
			return doseSensitivity{}, fmt.Errorf("no run of dose %q restored its owner, so there is no wait "+
				"to test against the dose", dose)
		}
		g.OwnerWaitSecondsMean = sum / float64(g.OwnerWaitRuns)
		d.Doses = append(d.Doses, g)
	}

	lo, hi := d.Doses[0].OwnerWaitSecondsMean, d.Doses[0].OwnerWaitSecondsMean
	for _, g := range d.Doses {
		if g.OwnerWaitSecondsMean < lo {
			lo = g.OwnerWaitSecondsMean
		}
		if g.OwnerWaitSecondsMean > hi {
			hi = g.OwnerWaitSecondsMean
		}
	}
	d.SpreadSeconds = hi - lo
	d.MovesWithDose = bounded && d.SpreadSeconds > d.FloorSeconds
	switch {
	case !bounded:
		d.Statement = "UNBOUNDED: a contributing run bounded nothing, so no conclusion about the dose follows"
	case d.MovesWithDose:
		d.Statement = fmt.Sprintf("the owner's wait under %s moves %.3f s across %d dose regimes, which "+
			"EXCEEDS the %.3f s floor: this quantity responds to the dose and cannot serve as a baseline for "+
			"a session whose workload has a different service time",
			arm, d.SpreadSeconds, len(d.Doses), d.FloorSeconds)
	default:
		d.Statement = fmt.Sprintf("the owner's wait under %s moves %.3f s across %d dose regimes, INSIDE the "+
			"%.3f s floor. The harness cannot see it responding to the dose -- which is not proof that it does "+
			"not, and is the condition a baseline needs: a quantity the dose determines could not be "+
			"differenced against a session whose workload has a different service time",
			arm, d.SpreadSeconds, len(d.Doses), d.FloorSeconds)
	}
	return d, nil
}

// renderDoseSensitivity prints the check, leading with the statement rather than the numbers.
func renderDoseSensitivity(d doseSensitivity) string {
	var b strings.Builder
	fmt.Fprintf(&b, "===== DOSE SENSITIVITY (arm %s) =====\n%s\n", d.Arm, d.Statement)
	for _, g := range d.Doses {
		fmt.Fprintf(&b, "  %-16s n=%d ownerWait mean=%.3f over %d restored runs=%s\n",
			g.Dose, g.N, g.OwnerWaitSecondsMean, g.OwnerWaitRuns, strings.Join(g.RunIDs, ","))
	}
	return b.String()
}

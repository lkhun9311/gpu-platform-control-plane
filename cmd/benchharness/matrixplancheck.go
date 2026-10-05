package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// matrixPlanCheck asks of one planned frozen-matrix cell what the readings will ask of its evidence.
//
// It takes the generated trace rather than counts on the command line, for the reason ladder-plan-check
// gives: the thing being checked is the artefact the run will actually replay and not a number somebody
// typed twice.
//
// --arms is the whole planned arm list and is checked on EVERY cell rather than once. The set-level question
// -- is the isolated baseline in the plan at all -- cannot be answered from a single cell's trace, and a
// shell that has to remember to ask it once somewhere else is a shell that can forget to.
func matrixPlanCheck(args []string) error {
	fs := flag.NewFlagSet("matrix-plan-check", flag.ExitOnError)
	trace := fs.String("trace", "", "the generated trace file to check")
	study := fs.String("study", "", "the study the cell belongs to")
	arm := fs.String("arm", "", "the arm name the cell will record")
	arms := fs.String("arms", "", "every arm the run plans to buy, space separated")
	// --reproduces names the archive this run claims to repeat, and is empty for a run that claims nothing.
	//
	// It exists because a registration said "reproduction" and nothing checked it: the 2026-10-02 run was
	// registered as a five-repetition reproduction of the 2026-09-13 pilot and offered a 294-token premium
	// prompt against that pilot's 50. Every check above passed it, because they ask whether a cell is
	// SCORABLE and not whether it is the same load as a named prior run.
	//
	// Empty is not a silent pass: a plan that makes no reproduction claim has nothing to compare, and the
	// claim lives in the registration. What this flag closes is the case where the claim IS made.
	reproduces := fs.String("reproduces", "", "a prior run's m5c-run directory this plan claims to reproduce; refuses before launch when the offered load differs")
	manifest := fs.String("manifest", "", "the manifest gen-trace wrote beside --trace; required with --reproduces")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// --arms is required rather than defaulted to the cell's own arm.
	//
	// A default would turn "the caller forgot to pass the plan" into "the plan is this one cell", and the
	// set-level refusal would pass on a matrix that has no isolated baseline in it.
	if *trace == "" || *study == "" || *arm == "" || *arms == "" {
		return fmt.Errorf("--trace, --study, --arm and --arms are all required")
	}
	tf, err := os.Open(*trace)
	if err != nil {
		return fmt.Errorf("open trace %s: %w", *trace, err)
	}
	defer func() { _ = tf.Close() }()
	rows, err := bench.ReadTrace(tf)
	if err != nil {
		return fmt.Errorf("read trace %s: %w", *trace, err)
	}
	premium, contender := 0, 0
	for _, r := range rows {
		switch r.Tenant {
		case bench.PremiumTenant:
			premium++
		case bench.NoisyTenant:
			contender++
		}
	}
	if perr := bench.MatrixPlanArmSetRefusal(*study, strings.Fields(*arms)); perr != nil {
		return perr
	}
	// The instrument check is scored on episodes, so the premium floor below would refuse a valid serial trace for being short.
	// It returns here rather than falling through, which also keeps --reproduces off a study that has no prior run to repeat.
	if *study == bench.StudyInstrumentValidation {
		if *reproduces != "" {
			return fmt.Errorf("--reproduces is not defined for study %s, which has no prior run whose load it could repeat", *study)
		}
		if perr := bench.InstrumentValidationPlanRefusal(*arm, rows); perr != nil {
			return fmt.Errorf("%s: %w", *arm, perr)
		}
		fmt.Printf("%s: %d premium, %d contender -- %d complete cycles, scorable\n", *arm, premium, contender, bench.EpisodeCycles)
		return nil
	}
	if perr := bench.MatrixPlanRefusal(*study, *arm, premium); perr != nil {
		return fmt.Errorf("%s: %w", *arm, perr)
	}

	// The reproduction claim is checked LAST, because the refusals above are about this plan on its own.
	//
	// A cell that cannot be scored is wrong whatever it claims to repeat, and reporting "not a reproduction"
	// for a plan that was never scorable would name the second-most-useful fact.
	// An EXPLICITLY empty --reproduces is a caller's mistake, not a claim of nothing.
	//
	// Without this, `--reproduces ""` and omitting the flag behave identically, so a shell that meant to pass
	// an archive and interpolated an unset variable claims nothing and passes. A mutation proved it: making
	// the matrix pass `--reproduces "${REPRODUCES:-}"` unconditionally changed no test. Distinguishing
	// "absent" from "present and empty" is the same rule this repository applies to every other check.
	explicit := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "reproduces" {
			explicit = true
		}
	})
	if explicit && *reproduces == "" {
		return fmt.Errorf("--reproduces was passed with an empty value; omit the flag to claim no reproduction, or name the archive this plan repeats")
	}

	if *reproduces != "" {
		if *manifest == "" {
			return fmt.Errorf("--reproduces needs --manifest: the claim is about the load this plan would offer, and the manifest beside --trace is what records it")
		}
		pm, err := bench.LoadManifest(*manifest)
		if err != nil {
			return fmt.Errorf("read the planned manifest %s: %w", *manifest, err)
		}
		// The manifest has to describe the trace this check just counted.
		//
		// Nothing tied them before, and a review found it on 2026-10-02: --trace was read for the sample
		// floors and --manifest was loaded separately for the reproduction comparison, so a caller could
		// pass one cell's trace and another cell's manifest -- or a hand-written manifest naming a load
		// nobody generated -- and both halves would pass while describing different things.
		//
		// The manifest's own checksum is the binding, because LoadManifest has already verified it against
		// the file the manifest names. Comparing it to this trace's bytes asks the one question that
		// matters: is the artefact I counted the artefact this claim is about?
		traceSum, err := bench.ChecksumFile(*trace)
		if err != nil {
			return fmt.Errorf("checksum the trace %s: %w", *trace, err)
		}
		if traceSum != pm.TraceChecksum {
			return fmt.Errorf("--trace %s hashes to %s and --manifest %s records traceChecksum %s, so the manifest does not describe the trace this check counted; pass the manifest gen-trace wrote beside this trace",
				*trace, traceSum, *manifest, pm.TraceChecksum)
		}
		if pm.Arm != *arm {
			return fmt.Errorf("--arm is %s and --manifest %s records arm %s, so the reproduction claim is about a different cell than the one being checked",
				*arm, *manifest, pm.Arm)
		}
		if pm.Study != *study {
			return fmt.Errorf("--study is %s and --manifest %s records study %s, so the plan and the manifest disagree about which registration scores this cell",
				*study, *manifest, pm.Study)
		}
		target, err := bench.ReproductionFactsFromArchive(*reproduces)
		if err != nil {
			return fmt.Errorf("read the target run at %s: %w", *reproduces, err)
		}
		pf := bench.ReproductionFactsOf(*pm)
		if rerr := bench.ReproductionRefusal(target, map[string]bench.ReproductionFacts{pf.Arm: pf}); rerr != nil {
			return fmt.Errorf("%s does not reproduce %s: %w", *arm, *reproduces, rerr)
		}
		fmt.Printf("%s: %d premium, %d contender -- scorable, and matches %s\n", *arm, premium, contender, *reproduces)
		return nil
	}

	fmt.Printf("%s: %d premium, %d contender -- scorable\n", *arm, premium, contender)
	return nil
}

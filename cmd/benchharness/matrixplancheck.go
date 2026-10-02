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
	if perr := bench.MatrixPlanRefusal(*study, *arm, premium); perr != nil {
		return fmt.Errorf("%s: %w", *arm, perr)
	}
	fmt.Printf("%s: %d premium, %d contender -- scorable\n", *arm, premium, contender)
	return nil
}

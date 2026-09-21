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

package queuelab

import (
	"fmt"
	"math"
	"os/exec"
	"regexp"
	"strings"
	"testing"
)

// The oracle predicts a Python program's arithmetic from Go, and the only check worth having is the one that
// runs that Python.
//
// Every other assertion here is about Go agreeing with itself. submit_test.go already states the principle
// for this package: a textual check "a program with a syntax error on line 40 satisfies perfectly", and "a
// convention with no test is a convention that breaks on the next edit to either side, silently". The
// convention under test is heavier than a string format -- it is that two languages' float64 arithmetic
// agrees to the bit -- and it was verified by hand once before this file existed. A hand check does not
// survive the next edit.

func TestTheOracleReadsItsParametersFromTheShippedScript(t *testing.T) {
	p, err := ScriptAccumulatorParams()
	if err != nil {
		t.Fatalf("the oracle cannot find the accumulator in the workload it predicts: %v", err)
	}
	// Asserted against the values the script carries today, so a change to either side is visible here rather
	// than only in a run. The point is not the numbers; it is that the two sides still agree on them.
	if p.StepsPerIteration != 50000 {
		t.Errorf("StepsPerIteration = %d, want 50000", p.StepsPerIteration)
	}
	if p.Growth != 1.0000001 {
		t.Errorf("Growth = %v, want 1.0000001", p.Growth)
	}
	if p.Mod != accumulatorMod {
		t.Errorf("Mod = %v, want %v", p.Mod, accumulatorMod)
	}
}

func TestTheOracleRefusesAScriptItCannotRead(t *testing.T) {
	// The refusal matters more than the success: a version that fell back to the constants would keep
	// answering after the script stopped agreeing with it, and its answers would look exactly as authoritative.
	saved := accumulatorStepPattern
	defer func() { accumulatorStepPattern = saved }()
	accumulatorStepPattern = regexp.MustCompile(`this text is not in the workload`)

	if _, err := ScriptAccumulatorParams(); err == nil {
		t.Fatal("the oracle answered for a script whose accumulator it could not find")
	}
}

func TestZeroIterationsIsTheSeedAndNegativeIsAnError(t *testing.T) {
	p := AccumulatorParams{StepsPerIteration: 50000, Growth: 1.0000001, Mod: accumulatorMod}

	got, err := AccumulatorAfter(p, 0)
	if err != nil {
		t.Fatalf("zero iterations: %v", err)
	}
	if got != accumulatorSeed {
		t.Errorf("after 0 iterations = %v, want the seed %v", got, accumulatorSeed)
	}
	if _, err := AccumulatorAfter(p, -1); err == nil {
		t.Error("a negative iteration count was answered rather than refused")
	}
}

func TestTheSameWorkComparisonIsExact(t *testing.T) {
	p := AccumulatorParams{StepsPerIteration: 50000, Growth: 1.0000001, Mod: accumulatorMod}
	want, err := AccumulatorAfter(p, 3)
	if err != nil {
		t.Fatal(err)
	}

	ok, err := ResumedTheSameWork(p, 3, want)
	if err != nil || !ok {
		t.Fatalf("an exact match was rejected: ok=%v err=%v", ok, err)
	}
	// One ULP away is a different sequence of steps, which is the case a tolerance would wave through.
	near := math.Nextafter(want, math.Inf(1))
	ok, err = ResumedTheSameWork(p, 3, near)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Errorf("a value one ULP from the prediction was accepted as the same work")
	}
}

// TestTheOraclePredictsWhatThePythonWorkloadActuallyComputes is the only test here that could fail for a
// reason outside this file, and that is why it exists.
//
// It executes the accumulator loop as the shipped script spells it, in the interpreter that runs it on the
// cluster, and compares BIT PATTERNS rather than values -- two doubles that print alike can differ in the
// last place, and the oracle's comparison is exact.
func TestTheOraclePredictsWhatThePythonWorkloadActuallyComputes(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skipf("no python3 on this host, so the shipped arithmetic cannot be executed here: %v", err)
	}
	p, err := ScriptAccumulatorParams()
	if err != nil {
		t.Fatal(err)
	}

	for _, iterations := range []int{0, 1, 2, 10} {
		want, err := AccumulatorAfter(p, iterations)
		if err != nil {
			t.Fatal(err)
		}
		// The loop is spelled from the extracted parameters, so this runs what the script says rather than
		// what this test remembers.
		prog := fmt.Sprintf(`import struct
x=%v
for _ in range(%d):
    for _ in range(%d): x=(x*%v)%%%v
print(struct.pack('>d',x).hex())`, accumulatorSeed, iterations, p.StepsPerIteration, p.Growth, p.Mod)

		out, err := exec.Command(python, "-c", prog).Output()
		if err != nil {
			t.Fatalf("running the shipped arithmetic for %d iterations: %v", iterations, err)
		}
		gotBits := strings.TrimSpace(string(out))
		wantBits := fmt.Sprintf("%016x", math.Float64bits(want))
		if gotBits != wantBits {
			t.Errorf("after %d iterations python has %s and the oracle predicts %s",
				iterations, gotBits, wantBits)
		}
	}
}

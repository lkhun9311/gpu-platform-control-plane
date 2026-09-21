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
	"regexp"
	"strconv"
)

// The oracle Stage C needs, built before the arm that will feed it.
//
// docs/superpowers/specs/2026-09-21-stage-c-resume-arm-pre-registration.md registers what a resuming arm
// costs and names the oracle it requires: a resumed run must be able to say it did the SAME work, not merely
// work of the same shape. The workload's CPU path already carries a quantity that answers that -- the
// accumulator advanced once per inner step -- and this predicts it.
//
// NOTHING FEEDS THIS YET, and saying so is the point. The workload reports "iters=N kind=K dev=D duty=Q" and
// no accumulator, so there is currently no value to compare a prediction against. Adding one changes the
// rendered command, which changes canaryKey.PodTemplateHash, which expires every node's qualification -- the
// cost the pre-registration exists to have declared in advance. This file is the half that costs nothing:
// the prediction is written and pinned to the shipped script now, so that when the template does change, the
// change is one small commit against a checked oracle rather than two unreviewed things at once.
//
// It is here rather than in internal/exputil because that package "deliberately carries no
// experiment-specific schema". Replicating one workload's arithmetic is exactly that.

// accumulatorSeed and accumulatorMod mirror the workload's `x=1.0` and its modulus.
//
// They are Go-side copies of values that live in a Python string, which is the drift this package already
// guards elsewhere: workloadPeriod reads PERIOD out of the script rather than restating it, because "a period
// changed in one place and restated in another is a test measuring a window that no longer contains what it
// thinks it does". The same argument applies with more force here, since a silent divergence would not fail a
// test -- it would produce an oracle that disagrees with a correctly resumed run and calls it wrong.
//
// So these are not the authority. ScriptAccumulatorParams reads the authority out of the script itself, and
// the spec file pins the two together against Python's own output.
const (
	accumulatorSeed = 1.0
	accumulatorMod  = 1000000.0
)

// accumulatorStepPattern matches the workload's inner loop, capturing its step count and growth factor.
//
// Anchored on the whole statement rather than on the numbers alone, so a second loop appearing in the script
// cannot be matched by accident and reported as this one.
var accumulatorStepPattern = regexp.MustCompile(
	`for _ in range\((\d+)\): x=\(x\*([0-9.]+)\)%([0-9.]+)`)

// AccumulatorParams is the shipped workload's CPU arithmetic, read from the script it actually runs.
type AccumulatorParams struct {
	// StepsPerIteration is how many multiply-and-wrap steps one reported iteration performs.
	StepsPerIteration int
	// Growth is the per-step multiplier.
	Growth float64
	// Mod is the wrap-around modulus.
	Mod float64
}

// ScriptAccumulatorParams extracts the accumulator's parameters from the shipped workload.
//
// It returns an error rather than falling back to the constants above, because a fallback would let the
// oracle keep answering after the script stopped agreeing with it -- which is the failure this whole file is
// arranged to prevent. An oracle that cannot find what it predicts must refuse, not guess.
func ScriptAccumulatorParams() (AccumulatorParams, error) {
	m := accumulatorStepPattern.FindStringSubmatch(workloadScript)
	if m == nil {
		return AccumulatorParams{}, fmt.Errorf("the workload declares no accumulator loop this oracle recognises")
	}
	steps, err := strconv.Atoi(m[1])
	if err != nil || steps <= 0 {
		return AccumulatorParams{}, fmt.Errorf("accumulator step count %q is not usable", m[1])
	}
	growth, err := strconv.ParseFloat(m[2], 64)
	if err != nil || growth <= 1 {
		return AccumulatorParams{}, fmt.Errorf("accumulator growth %q is not usable", m[2])
	}
	mod, err := strconv.ParseFloat(m[3], 64)
	if err != nil || mod <= 0 {
		return AccumulatorParams{}, fmt.Errorf("accumulator modulus %q is not usable", m[3])
	}
	return AccumulatorParams{StepsPerIteration: steps, Growth: growth, Mod: mod}, nil
}

// AccumulatorAfter is the value the workload's CPU path holds after iterations completed iterations.
//
// The loop is written in the script's order deliberately: float64 is IEEE 754 in both languages, so the same
// operations in the same sequence agree to the bit, and a "simplification" that batched the multiplications
// or used math.Pow would not. Measured rather than assumed -- the spec runs the shipped Python and compares
// the bit patterns.
//
// A negative count is an error rather than a zero, because "no iterations" and "a count that cannot be right"
// are different statements and only one of them means the seed value.
func AccumulatorAfter(p AccumulatorParams, iterations int) (float64, error) {
	if iterations < 0 {
		return 0, fmt.Errorf("cannot predict the accumulator after %d iterations", iterations)
	}
	// The nesting mirrors the script's: an outer loop per reported iteration, an inner one per step. Only the
	// loop SPELLING is modernised here -- the operation and its order are the script's, and reassociating or
	// batching them would break the bit-for-bit agreement the spec pins.
	x := accumulatorSeed
	for range iterations {
		for range p.StepsPerIteration {
			x = math.Mod(x*p.Growth, p.Mod)
		}
	}
	return x, nil
}

// ResumedTheSameWork reports whether a resumed run's accumulator is the one its iteration count implies.
//
// EXACT equality, not a tolerance. The comparison is between two IEEE 754 doubles produced by the identical
// operation sequence, so they are equal or the run did not do the work it claims -- and a tolerance here
// would accept precisely the case this oracle exists to catch, a resume that replayed a different number of
// steps and landed nearby.
//
// It says nothing about the device path. There the loop calls the kernel and never touches x, so a resumed
// run and a control would both report the seed and this would agree for the wrong reason. The
// pre-registration therefore scopes Stage C to the CPU path and refuses a device-path verdict; callers must
// not reach here with a run whose reported kind is the device one.
func ResumedTheSameWork(p AccumulatorParams, iterations int, reported float64) (bool, error) {
	want, err := AccumulatorAfter(p, iterations)
	if err != nil {
		return false, err
	}
	return want == reported, nil
}

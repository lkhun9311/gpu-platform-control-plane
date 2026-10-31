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

package gpufault

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ScoreSession scores every repetition under dir/reps and reads dir/smoke.env for arms the smoke cell stopped.
//
// A repetition directory that cannot be read at all is an error for the session, not a skipped repetition:
// the verdict counts valid repetitions, and one that silently vanished would raise no flag anywhere.
func ScoreSession(dir string) (Report, error) {
	entries, err := os.ReadDir(filepath.Join(dir, "reps"))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return Report{}, err
	}
	var cells []CellResult
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		c, err := ScoreCell(filepath.Join(dir, "reps", e.Name()))
		if err != nil {
			return Report{}, fmt.Errorf("repetition %s: %w", e.Name(), err)
		}
		cells = append(cells, c)
	}
	sort.Slice(cells, func(i, j int) bool { return cells[i].Dir < cells[j].Dir })
	notRun := map[string]bool{}
	smoke, err := readEnv(filepath.Join(dir, "smoke.env"))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// The rehearsal has a smoke step too; a session without one never established its injection.
		r := Judge(cells, notRun)
		r.Refuse = append(r.Refuse, "no smoke.env: the session never recorded whether injection reaches the exporter")
		r.Label = "REFUSED"
		return r, nil
	case err != nil:
		return Report{}, err
	}
	for _, arm := range Arms {
		if v := smoke["arm_"+arm]; v != "run" {
			notRun[arm] = true
		}
	}
	r := Judge(cells, notRun)
	for _, name := range StaleChecks {
		r.Checks = append(r.Checks, judgeStaleCheck(filepath.Join(dir, "checks", name), name))
	}
	r.Checks = append(r.Checks, judgeRecoveryCheck(filepath.Join(dir, "checks", "recovery")))
	return r, nil
}

// RecoveryImage is the CUDA sample run 3's amendment pins; a card session that ran anything else ran another check.
const RecoveryImage = "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0@sha256:7c7540bdf1f942d4fb6db97069fd6c289471b54ac29e3c7fcdf914cf77af7d41"

// RecoveryBudgetSeconds is the time the amendment gives the recovery job from submission to completion.
const RecoveryBudgetSeconds = 180

// recoveryMarker is what NVIDIA's vectorAdd prints once it has checked the kernel's result on the card.
const recoveryMarker = "Test PASSED"

// judgeRecoveryCheck reads the check run 3's amendment registers: after a latched fault is cleared by a fresh zero
// reading, the platform puts a CUDA training job back on the node and the card runs it.
//
// A check that was not reached is NOT-REACHED, never FAIL, because no clause was read; a session from before the
// amendment has no record at all and is NOT-RUN.
func judgeRecoveryCheck(dir string) CheckResult {
	const name = "recovery"
	env, err := readEnv(filepath.Join(dir, "check.env"))
	if err != nil {
		return CheckResult{Name: name, Verdict: "NOT-RUN", Reasons: []string{err.Error()}}
	}
	if env["reached"] != "true" {
		why := "stale-latched never gave its zero reading"
		if env["reason"] == "deadline" {
			why = "the checks phase had too little time left to begin it"
		}
		return CheckResult{Name: name, Verdict: "NOT-REACHED", Reasons: []string{why}}
	}
	c := CheckResult{Name: name, Verdict: "PASS"}
	expect := func(ok bool, f string, a ...any) {
		if !ok {
			c.Verdict = "FAIL"
			c.Reasons = append(c.Reasons, fmt.Sprintf(f, a...))
		}
	}
	card := env["mode"] == "dcgm"
	expect(env["clear"] == "yes", "R1: the target was not clear after stale-latched's zero reading")
	if card {
		expect(env["exporter_recreated"] == "yes", "R2: the exporter on the target is %q, not a new Pod (recreated %s)", env["exporter_pod"], env["exporter_recreated"])
		expect(env["image"] == RecoveryImage, "R4: the job ran %q, not the registered %s", env["image"], RecoveryImage)
	}
	expect(env["allocatable"] == "1", "R3: the target's allocatable nvidia.com/gpu is %q, want 1", env["allocatable"])
	expect(env["submitted"] == "yes", "R4: the job was never submitted")
	expect(env["job_pods"] == "1", "R4: the job has %s Pods, want exactly one", env["job_pods"])
	expect(env["job_phase"] == "Succeeded" && env["exit_code"] == "0", "R4: the job's Pod is %q with exit code %q", env["job_phase"], env["exit_code"])
	expect(env["job_node"] != "" && env["job_node"] == env["target"], "R4: the job ran on %q, not on the target %q", env["job_node"], env["target"])
	log, err := os.ReadFile(filepath.Join(dir, "job.log"))
	expect(err == nil && strings.Contains(string(log), recoveryMarker), "R4: the job's log does not say %q", recoveryMarker)
	// The bound is the registration's, not the record's: a runner given another budget ran another check.
	expect(env["budget_s"] == strconv.Itoa(RecoveryBudgetSeconds), "R4: the runner gave the job %q s, not the registered %d s", env["budget_s"], RecoveryBudgetSeconds)
	submit, errS := strconv.ParseFloat(env["t_submit"], 64)
	finished, errF := time.Parse(time.RFC3339, env["t_finished"])
	if errS != nil || errF != nil {
		expect(false, "R4: the submission or completion time is unreadable: %q, %q", env["t_submit"], env["t_finished"])
	} else {
		// finishedAt has whole seconds, so the completion is taken as the end of its second: an upper end, as every
		// other figure in this study is.
		took := float64(finished.Unix()+1) - submit
		expect(took <= RecoveryBudgetSeconds, "R4: the job finished %.0f s after its submission, beyond the registered %d s", took, RecoveryBudgetSeconds)
	}
	if !card {
		c.Reasons = append(c.Reasons, "rehearsal: the job was the study's busybox printing the marker, not CUDA on a card")
	}
	return c
}

// StaleChecks are the two registered cells that take the exporter away with the operator running.
var StaleChecks = []string{"stale-healthy", "stale-latched"}

// staleSignalReasons are the GPUSignal reasons that mean "no fresh reading", as the controller writes them.
var staleSignalReasons = map[string]bool{"Stale": true, "NoExporter": true, "ScrapeFailed": true, "AmbiguousExporter": true, "NoCards": true}

// judgeStaleCheck compares what the runner recorded with what the registration says must hold:
// without a fresh reading the platform neither sets nor clears a fault, and says so in GPUSignal.
func judgeStaleCheck(dir, name string) CheckResult {
	c := CheckResult{Name: name, Verdict: "PASS"}
	env, err := readEnv(filepath.Join(dir, "check.env"))
	if err != nil {
		return CheckResult{Name: name, Verdict: "NOT-RUN", Reasons: []string{err.Error()}}
	}
	expect := func(ok bool, f string, a ...any) {
		if !ok {
			c.Verdict = "FAIL"
			c.Reasons = append(c.Reasons, fmt.Sprintf(f, a...))
		}
	}
	expect(env["during_signal_status"] == "False" && staleSignalReasons[env["during_signal_reason"]],
		"GPUSignal while the exporter was away: %s/%s, want False with a no-reading reason", env["during_signal_status"], env["during_signal_reason"])
	switch name {
	case "stale-healthy":
		expect(env["during_healthy_status"] == "Unknown", "GPUHealthy %q while away, want Unknown, never True", env["during_healthy_status"])
		expect(env["during_taint"] == "absent" && env["during_latched"] == "", "stale data set a fault: taint %s, latched %q", env["during_taint"], env["during_latched"])
	case "stale-latched":
		expect(env["before_latched"] != "", "the fault was never latched before the exporter was taken away")
		expect(env["during_healthy_status"] == "False" && env["during_taint"] == "present" && env["during_latched"] == env["before_latched"],
			"stale data released the fault: GPUHealthy %s, taint %s, latched %q", env["during_healthy_status"], env["during_taint"], env["during_latched"])
		// The runner writes the after_* lines only once it has injected zero, so their absence is a step that did
		// not run, which fails the clause but is not a reading that failed to clear.
		_, reached := env["after_taint"]
		switch {
		case !reached:
			expect(false, "the clearing step was never reached: no fresh zero reading was given after the exporter left (see the runner's log)")
		case env["zero_given"] == "no":
			// Sessions before run 3 do not record zero_given, and are read as they were.
			expect(false, "the clearing step was never reached: injecting the zero reading failed (see the runner's log)")
		default:
			expect(env["after_latched"] == "" && env["after_taint"] == "absent",
				"a fresh zero reading did not clear it: latched %q, taint %s", env["after_latched"], env["after_taint"])
		}
	}
	return c
}

// String renders the report for a terminal and for the evidence directory.
func (r Report) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "GPU FAULT REACTION: %s\n", r.Label)
	for _, s := range r.Refuse {
		fmt.Fprintf(&b, "  refused: %s\n", s)
	}
	fmt.Fprintf(&b, "P5 (allocatable unchanged by injection): %s\n", r.P5)
	for _, a := range r.Arms {
		fmt.Fprintf(&b, "arm %-6s %-22s valid %d of %d\n", a.Arm, a.Verdict, a.Valid, a.Total)
		hops := make([]string, 0, len(a.Summary))
		for h := range a.Summary {
			hops = append(hops, h)
		}
		sort.Strings(hops)
		for _, h := range hops {
			s := a.Summary[h]
			fmt.Fprintf(&b, "    %-14s median %8.3f s  min %8.3f  max %8.3f   (upper ends)\n", h, s[0], s[1], s[2])
		}
		for _, reason := range a.Reasons {
			fmt.Fprintf(&b, "    - %s\n", reason)
		}
	}
	for _, c := range r.Checks {
		fmt.Fprintf(&b, "check %-14s %s\n", c.Name, c.Verdict)
		for _, reason := range c.Reasons {
			fmt.Fprintf(&b, "    - %s\n", reason)
		}
	}
	return b.String()
}

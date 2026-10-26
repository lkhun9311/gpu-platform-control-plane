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
	"strings"
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
	return r, nil
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
		expect(env["after_latched"] == "" && env["after_taint"] == "absent",
			"a fresh zero reading did not clear it: latched %q, taint %s", env["after_latched"], env["after_taint"])
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

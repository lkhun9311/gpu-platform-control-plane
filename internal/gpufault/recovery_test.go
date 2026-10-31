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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// recoveryOnCard is what the runner records when every clause of run 3's recovery check holds on the card.
const recoveryOnCard = "reached=true\nmode=dcgm\ntarget=m5cgpu-worker\nclear=yes\nt_clear=1000.5\n" +
	"exporter_pod=dcgm-exporter-new\nexporter_recreated=yes\nallocatable=1\nsubmitted=yes\n" +
	"image=" + RecoveryImage + "\nt_submit=1700000000.250\nt_end=1700000020.0\njob_pods=1\njob_phase=Succeeded\n" +
	"job_node=m5cgpu-worker\nexit_code=0\nt_scheduled=2023-11-14T22:13:21Z\nt_finished=2023-11-14T22:13:30Z\nbudget_s=180\n"

func recoveryCheck(t *testing.T, env, log string) CheckResult {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "recovery")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if env != "" {
		if err := os.WriteFile(filepath.Join(dir, "check.env"), []byte(env), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if log != "" {
		if err := os.WriteFile(filepath.Join(dir, "job.log"), []byte(log), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return judgeRecoveryCheck(dir)
}

func TestRecoveryCheckPassesOnlyWhenEveryClauseHolds(t *testing.T) {
	passed := "[Vector addition of 50000 elements]\nCopy input data from the host memory to the CUDA device\nTest PASSED\nDone\n"
	if c := recoveryCheck(t, recoveryOnCard, passed); c.Verdict != "PASS" || len(c.Reasons) != 0 {
		t.Fatalf("every clause held, read as %s %v", c.Verdict, c.Reasons)
	}
	// Each clause, broken alone, must fail the check and be named.
	for _, tc := range []struct{ name, from, to, log, want string }{
		{"not clear", "clear=yes", "clear=no", passed, "R1"},
		{"exporter did not return", "exporter_recreated=yes", "exporter_recreated=no", passed, "R2"},
		{"no device", "allocatable=1", "allocatable=0", passed, "R3"},
		{"never submitted", "submitted=yes", "submitted=no", passed, "never submitted"},
		{"retried", "job_pods=1", "job_pods=2", passed, "exactly one"},
		{"failed", "job_phase=Succeeded", "job_phase=Failed", passed, "exit code"},
		{"non-zero exit", "exit_code=0", "exit_code=1", passed, "exit code"},
		{"ran on the healthy node", "job_node=m5cgpu-worker", "job_node=m5cgpu-control-plane", passed, "not on the target"},
		{"no node", "job_node=m5cgpu-worker", "job_node=", passed, "not on the target"},
		{"another image", "image=" + RecoveryImage, "image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0", passed, "not the registered"},
		{"no marker", "", "", "Test FAILED\n", "does not say"},
		{"too late", "t_finished=2023-11-14T22:13:30Z", "t_finished=2023-11-14T22:16:30Z", passed, "beyond the registered"},
		// Submitted at …:20.250 and finished in the second that starts at …:16:20 (179.75 s later): the end of that
		// second is 180.75 s, past the budget, and only the upper end may be compared.
		{"late inside its last second", "t_finished=2023-11-14T22:13:30Z", "t_finished=2023-11-14T22:16:20Z", passed, "beyond the registered"},
		{"unreadable time", "t_finished=2023-11-14T22:13:30Z", "t_finished=", passed, "unreadable"},
		// A runner that gave itself 300 s and finished at 200 s ran another check than the one registered.
		{"a budget of its own", "budget_s=180\n", "budget_s=300\n", passed, "not the registered 180"},
		{"late under a budget of its own", "t_finished=2023-11-14T22:13:30Z\nbudget_s=180", "t_finished=2023-11-14T22:16:40Z\nbudget_s=300", passed, "beyond the registered 180"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := recoveryOnCard
			if tc.from != "" {
				if !strings.Contains(env, tc.from) {
					t.Fatalf("the fixture has no %q to break", tc.from)
				}
				env = strings.Replace(env, tc.from, tc.to, 1)
			}
			c := recoveryCheck(t, env, tc.log)
			if c.Verdict != "FAIL" || !strings.Contains(strings.Join(c.Reasons, "; "), tc.want) {
				t.Fatalf("read as %s %v, want FAIL naming %q", c.Verdict, c.Reasons, tc.want)
			}
		})
	}
}

// A step that did not run is never a clause that failed, and a session from before the amendment has no record.
func TestRecoveryCheckNamesWhatDidNotRun(t *testing.T) {
	if c := recoveryCheck(t, "reached=false\n", ""); c.Verdict != "NOT-REACHED" || !strings.Contains(c.Reasons[0], "zero reading") {
		t.Fatalf("not reached read as %s %v", c.Verdict, c.Reasons)
	}
	if c := recoveryCheck(t, "reached=false\nreason=deadline\n", ""); c.Verdict != "NOT-REACHED" || !strings.Contains(c.Reasons[0], "too little time") {
		t.Fatalf("cut by the deadline read as %s %v", c.Verdict, c.Reasons)
	}
	if c := recoveryCheck(t, "", ""); c.Verdict != "NOT-RUN" {
		t.Fatalf("no record read as %s %v", c.Verdict, c.Reasons)
	}
}

// The rehearsal has no card: its exporter is toggled in place and its job is busybox, so the clauses only a card can
// meet are not asked of it, and the check says the program was not CUDA.
func TestRecoveryCheckOnTheRehearsalSaysItWasNotCUDA(t *testing.T) {
	env := strings.NewReplacer("mode=dcgm", "mode=fake", "exporter_recreated=yes", "exporter_recreated=fake",
		"image="+RecoveryImage, "image=gpufault-job:busybox").Replace(recoveryOnCard)
	c := recoveryCheck(t, env, "rehearsal, not CUDA\nTest PASSED\n")
	if c.Verdict != "PASS" || !strings.Contains(strings.Join(c.Reasons, "; "), "not CUDA") {
		t.Fatalf("rehearsal read as %s %v", c.Verdict, c.Reasons)
	}
}

// The image is pinned in the instance runner, which pulls and runs it, and here, where the scorer refuses any other;
// a change to one alone would make every card session fail R4, or pass a check the amendment did not register.
func TestRecoveryImageIsTheOneTheRunnerPins(t *testing.T) {
	for _, p := range []string{"../../hack/gpu-fault-instance.sh", "../../docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md"} {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		digest := RecoveryImage[strings.Index(RecoveryImage, "@")+1:]
		if !strings.Contains(string(b), digest) {
			t.Fatalf("%s does not carry the scorer's digest %s", p, digest)
		}
	}
	b, err := os.ReadFile("../../hack/gpu-fault-instance.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "GF_RECOVERY_IMAGE="+RecoveryImage+"\n") {
		t.Fatalf("the instance runner does not export GF_RECOVERY_IMAGE=%s", RecoveryImage)
	}
	lib, err := os.ReadFile("../../hack/lib/gpu-fault.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(lib), "\nGF_RECOVERY_S="+strconv.Itoa(RecoveryBudgetSeconds)+"\n") {
		t.Fatalf("hack/lib/gpu-fault.sh does not give the job the scorer's %d s", RecoveryBudgetSeconds)
	}
}

// A zero reading that was never injected cannot have cleared anything, and must not be described as one that did not.
func TestStaleLatchedNamesAZeroThatWasNeverInjected(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "stale-latched")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	env := "before_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\nduring_signal_status=False\nduring_signal_reason=NoExporter\n" +
		"during_healthy_status=False\nduring_taint=present\nduring_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\n" +
		"zero_given=no\nafter_latched=\nafter_taint=absent\n"
	if err := os.WriteFile(filepath.Join(dir, "check.env"), []byte(env), 0o644); err != nil {
		t.Fatal(err)
	}
	c := judgeStaleCheck(dir, "stale-latched")
	if reasons := strings.Join(c.Reasons, "; "); c.Verdict != "FAIL" || !strings.Contains(reasons, "injecting the zero reading failed") {
		t.Fatalf("read as %s %q", c.Verdict, reasons)
	}
}

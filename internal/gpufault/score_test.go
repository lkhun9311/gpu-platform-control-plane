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
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// t0 is the end of the injection call in every fixture; the hops are placed from it as a real repetition's would be.
var t0 = time.Date(2026, 10, 27, 3, 0, 10, 500_000_000, time.UTC)

func at(d time.Duration) time.Time { return t0.Add(d) }
func ns(t time.Time) string        { return t.Format(time.RFC3339Nano) }
func ep(t time.Time) string        { return fmt.Sprintf("%d.%09d", t.Unix(), t.Nanosecond()) }
func whole(d time.Duration) metav1.Time {
	return metav1.NewTime(at(d).Truncate(time.Second))
}

// cellFixture is one repetition's evidence, valid by default, that a test bends to make one rule fire.
type cellFixture struct {
	env       map[string]string
	probe     []string
	nhs       []platformv1.NodeHealth
	nodes     []corev1.Node
	wls       []kueuev1beta1.Workload
	jobs      []batchv1.Job
	pods      []corev1.Pod
	watchLogs map[string]string
}

func faultFixture(arm string) *cellFixture {
	inj := armInjection[arm]
	fp := "GPU-a/" + inj.field + "=" + inj.value
	f := &cellFixture{env: map[string]string{
		"mode": "fake", "arm": arm, "rep": "1", "block": "1", "job": "train-1", "target": "w1", "healthy": "w2",
		"uuid": "GPU-a", "field": fieldID(inj.field), "value": inj.value, "baseline": "0", "readback": inj.value,
		"t_inject_start": ep(at(-100 * time.Millisecond)), "t_inject_end": ep(t0), "t_rb": ep(at(150 * time.Millisecond)),
		"t_window_end": ep(at(120 * time.Second)), "pre_state": "ok", "alloc_before": "1", "alloc_after": "1",
	}}
	f.watchLogs = map[string]string{}
	for _, s := range streams {
		f.watchLogs[s] = "start " + ep(at(-5*time.Second)) + "\nend " + ep(at(130*time.Second)) + " 143\n"
	}
	f.probe = []string{ep(at(-50*time.Millisecond)) + "\t0", ep(at(700*time.Millisecond)) + "\t" + inj.value}
	clean := platformv1.NodeHealth{Name: "nh-w1", Annotations: map[string]string{
		annReading:   "GPU-a/DCGM_FI_DEV_XID_ERRORS=0,GPU-a/DCGM_FI_DEV_ECC_DBE_VOL_TOTAL=0,GPU-a/DCGM_FI_DEV_ECC_SBE_VOL_TOTAL=0",
		annReadingAt: ns(at(-time.Minute))}, Spec: platformv1.NodeHealthSpec{NodeName: "w1"}}
	latched := *clean.DeepCopy()
	latched.Annotations[annFingerprint] = fp
	latched.Annotations[annObservedAt] = ns(at(1200 * time.Millisecond))
	tainted := *latched.DeepCopy()
	tainted.Annotations[annTaintedAt] = ns(at(1230 * time.Millisecond))
	tainted.Status.Conditions = []metav1.Condition{{Type: condGPUHealthy, Status: metav1.ConditionFalse, Reason: "XidError"}}
	f.nhs = []platformv1.NodeHealth{clean, latched, tainted}
	node := corev1.Node{Name: "w1"}
	nodeT := *node.DeepCopy()
	nodeT.Spec.Taints = []corev1.Taint{{Key: taintKey, Value: "true", Effect: corev1.TaintEffectNoSchedule}}
	f.nodes = []corev1.Node{node, nodeT}

	own := []metav1.OwnerReference{{Kind: "Job", Name: "train-1", APIVersion: "batch/v1", UID: "u"}}
	wl := kueuev1beta1.Workload{Name: "job-train-1-abc", OwnerReferences: own}
	wl.Status.Conditions = []metav1.Condition{{Type: kueuev1beta1.WorkloadQuotaReserved, Status: metav1.ConditionTrue, LastTransitionTime: whole(-30 * time.Second)}}
	deact := *wl.DeepCopy()
	deact.Spec.Active = new(false)
	deact.Annotations = map[string]string{annDeactivatedAt: ns(at(1250 * time.Millisecond)), annWLFingerprint: fp}
	evicted := *deact.DeepCopy()
	evicted.Status.Conditions = []metav1.Condition{
		{Type: kueuev1beta1.WorkloadEvicted, Status: metav1.ConditionTrue, Reason: "Deactivated", LastTransitionTime: whole(1300 * time.Millisecond)},
		{Type: kueuev1beta1.WorkloadQuotaReserved, Status: metav1.ConditionTrue, LastTransitionTime: whole(-30 * time.Second)},
	}
	released := *evicted.DeepCopy()
	released.Status.Conditions[1] = metav1.Condition{Type: kueuev1beta1.WorkloadQuotaReserved, Status: metav1.ConditionFalse, LastTransitionTime: whole(2 * time.Second)}
	react := *released.DeepCopy()
	react.Spec.Active = new(true)
	react.Annotations[annReactivatedAt] = ns(at(2500 * time.Millisecond))
	readmitted := *react.DeepCopy()
	readmitted.Status.Conditions[1] = metav1.Condition{Type: kueuev1beta1.WorkloadQuotaReserved, Status: metav1.ConditionTrue, LastTransitionTime: whole(3 * time.Second)}
	f.wls = []kueuev1beta1.Workload{wl, deact, evicted, released, react, readmitted}

	j := batchv1.Job{Name: "train-1"}
	js := *j.DeepCopy()
	js.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobSuspended, Status: corev1.ConditionTrue, LastTransitionTime: whole(1400 * time.Millisecond)}}
	f.jobs = []batchv1.Job{j, js}

	old := corev1.Pod{Name: "train-1-a", CreationTimestamp: whole(-40 * time.Second), Spec: corev1.PodSpec{NodeName: "w1"}}
	old.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionTrue, LastTransitionTime: whole(-40 * time.Second)}}
	oldT := *old.DeepCopy()
	oldT.Status.ContainerStatuses = []corev1.ContainerStatus{{State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
		StartedAt: whole(-12 * time.Second), FinishedAt: whole(2 * time.Second), ExitCode: 143}}}}
	newP := corev1.Pod{Name: "train-1-b", CreationTimestamp: whole(3 * time.Second), Spec: corev1.PodSpec{NodeName: "w2"}}
	newP.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionTrue, LastTransitionTime: whole(3 * time.Second)}}
	newR := *newP.DeepCopy()
	newR.Status.ContainerStatuses = []corev1.ContainerStatus{{State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: whole(4 * time.Second)}}}}
	f.pods = []corev1.Pod{old, oldT, newP, newR}

	switch arm {
	case "benign":
		seen := *clean.DeepCopy()
		seen.Annotations[annReading] = "GPU-a/DCGM_FI_DEV_XID_ERRORS=0,GPU-a/DCGM_FI_DEV_ECC_DBE_VOL_TOTAL=0,GPU-a/DCGM_FI_DEV_ECC_SBE_VOL_TOTAL=1"
		seen.Annotations[annReadingAt] = ns(at(1100 * time.Millisecond))
		f.nhs, f.nodes, f.wls, f.jobs, f.pods = []platformv1.NodeHealth{clean, seen}, []corev1.Node{node}, []kueuev1beta1.Workload{wl}, []batchv1.Job{j}, []corev1.Pod{old}
	case "none":
		f.env["readback"], f.env["value"] = "0", ""
		f.env["t_sentinel_start"], f.env["sentinel_value"] = ep(at(121*time.Second)), "7"
		seen := *clean.DeepCopy()
		seen.Annotations[annReading] = "GPU-a/DCGM_FI_DEV_XID_ERRORS=0,GPU-a/DCGM_FI_DEV_ECC_DBE_VOL_TOTAL=0,GPU-a/DCGM_FI_DEV_ECC_SBE_VOL_TOTAL=7"
		seen.Annotations[annReadingAt] = ns(at(122 * time.Second))
		f.nhs, f.nodes, f.wls, f.jobs, f.pods = []platformv1.NodeHealth{clean, seen}, []corev1.Node{node}, []kueuev1beta1.Workload{wl}, []batchv1.Job{j}, []corev1.Pod{old}
	}
	return f
}

func writeStream[T any](t *testing.T, path string, objs []T) {
	t.Helper()
	var b strings.Builder
	for _, o := range objs {
		j, err := json.MarshalIndent(o, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		b.Write(j)
		b.WriteString("\n")
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *cellFixture) write(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var env strings.Builder
	for k, v := range f.env {
		env.WriteString(k + "=" + v + "\n")
	}
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, "cell.env"), []byte(env.String()), 0o644))
	must(os.WriteFile(filepath.Join(dir, "probe.tsv"), []byte(strings.Join(f.probe, "\n")+"\n"), 0o644))
	writeStream(t, filepath.Join(dir, "watch-nodehealth.json"), f.nhs)
	writeStream(t, filepath.Join(dir, "watch-node.json"), f.nodes)
	writeStream(t, filepath.Join(dir, "watch-workload.json"), f.wls)
	writeStream(t, filepath.Join(dir, "watch-job.json"), f.jobs)
	writeStream(t, filepath.Join(dir, "watch-pods.json"), f.pods)
	for s, body := range f.watchLogs {
		must(os.WriteFile(filepath.Join(dir, "watch-"+s+".log"), []byte(body), 0o644))
	}
	return dir
}

func score(t *testing.T, f *cellFixture) CellResult {
	t.Helper()
	c, err := ScoreCell(f.write(t, t.TempDir()))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestScoreCellReadsEveryHopOfAValidFaultRepetition(t *testing.T) {
	c := score(t, faultFixture("xid"))
	if !c.Valid() || len(c.Failed) != 0 {
		t.Fatalf("invalid %v failed %v", c.Invalid, c.Failed)
	}
	approx := func(name string, lo, hi float64) {
		t.Helper()
		h := c.Hops[name]
		if h == nil || h.Lo < lo-1e-6 || h.Lo > lo+1e-6 || h.Hi < hi-1e-6 || h.Hi > hi+1e-6 {
			t.Errorf("%s = %+v, want [%v, %v]", name, h, lo, hi)
		}
	}
	// Detection is bracketed by the injection call, 0.1 s long: [1.2, 1.3].
	approx("detect", 1.2, 1.3)
	approx("taint", 0.03, 0.03)
	approx("evict_request", 0.02, 0.02)
	approx("exporter_lag", 0.7, 0.8)
	// Evicted is stamped 11 s (truncated from 11.8); t_deact is 11.75: [-0.75, 0.25].
	approx("kueue_evict", -0.75, 0.25)
	approx("job_suspend", -0.75, 0.25)
	// Released at 12 s and re-reserved at 13 s, both truncated: [0, 2].
	approx("readmit", 0, 2)
	// Placed at 13 s truncated, against the injection bracket [10.4, 10.5]: [2.5, 3.6].
	approx("end_to_end", 2.5, 3.6)
	// The displaced container ran from 58 s to 12 s, 14 s, each end truncated.
	approx("lost_work", 13, 15)
}

// Each validity rule, made to fire on an otherwise valid repetition: a rule that cannot fail is not a rule.
func TestScoreCellValidityRulesEachFire(t *testing.T) {
	cases := map[string]struct {
		arm  string
		bend func(*cellFixture)
	}{
		"V1: readback":       {"xid", func(f *cellFixture) { f.env["readback"] = "0" }},
		"V1: field":          {"xid", func(f *cellFixture) { f.env["field"] = "311" }},
		"V2: pre-state":      {"xid", func(f *cellFixture) { f.env["pre_state"] = "taint present before injection" }},
		"V3: missing stream": {"xid", func(f *cellFixture) { f.jobs = nil }},
		"V3: watch ended inside the window": {"xid", func(f *cellFixture) {
			f.watchLogs["pods"] = "start " + ep(at(-5*time.Second)) + "\nend " + ep(at(30*time.Second)) + " 1\nstart " + ep(at(31*time.Second)) + "\n"
		}},
		// A watch whose first run was killed before it could write its end record still shows two starts.
		"V3: watch restarted with no end recorded": {"xid", func(f *cellFixture) {
			f.watchLogs["pods"] = "start " + ep(at(-5*time.Second)) + "\nstart " + ep(at(31*time.Second)) + "\nend " + ep(at(130*time.Second)) + " 143\n"
		}},
		"V3: watch started after the injection": {"none", func(f *cellFixture) {
			f.watchLogs["node"] = "start " + ep(at(time.Second)) + "\n"
		}},
		// A wrapper that died after its start record leaves no end, and a quiet control over that watch was valid
		// (codex audit, 2026-10-28). Mutation that turns it red: stop requiring an end record.
		"V3: watch with no end recorded": {"none", func(f *cellFixture) {
			f.watchLogs["node"] = "start " + ep(at(-5*time.Second)) + "\n"
		}},
		// Mutation that turns it red: drop the window end from the stamp-order check.
		"V3: window ends before the injection": {"xid", func(f *cellFixture) {
			f.env["t_window_end"] = ep(at(-time.Second))
		}},
		"V5: probe never saw it": {"xid", func(f *cellFixture) { f.probe = f.probe[:1] }},
		"V6: mode":               {"xid", func(f *cellFixture) { f.env["mode"] = "" }},
		"V7: benign value never read by the operator": {"benign", func(f *cellFixture) { f.nhs = f.nhs[:1] }},
		"V7: no sentinel":         {"none", func(f *cellFixture) { delete(f.env, "sentinel_value") }},
		"V7: sentinel never read": {"none", func(f *cellFixture) { f.nhs = f.nhs[:1] }},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			f := faultFixture(tc.arm)
			tc.bend(f)
			c := score(t, f)
			if c.Valid() {
				t.Fatalf("valid; hops %v actions %v", c.Hops, c.Actions)
			}
			if !strings.HasPrefix(c.Invalid[0], strings.SplitN(name, ":", 2)[0]) {
				t.Fatalf("fired %v, want %s", c.Invalid, name)
			}
		})
	}
}

// A platform that does the wrong thing is a result, scored against a predicate, never an invalid repetition.
func TestScoreCellFailuresAreResults(t *testing.T) {
	cases := map[string]func(*cellFixture){
		"P2-missing: no deactivated":                   func(f *cellFixture) { f.wls = f.wls[:1] },
		"attribution":                                  func(f *cellFixture) { f.nhs[1].Annotations[annFingerprint] = "GPU-a/DCGM_FI_DEV_XID_ERRORS=48" },
		"P2-order: tainted-at is recorded and no Node": func(f *cellFixture) { f.nodes = f.nodes[:1] },
		"P2-order: observed-at precedes": func(f *cellFixture) {
			f.nhs[1].Annotations[annObservedAt] = ns(at(-time.Second))
			f.nhs[2].Annotations[annObservedAt] = ns(at(-time.Second))
		},
		"P3-late": func(f *cellFixture) {
			f.pods[2].Status.Conditions[0].LastTransitionTime = whole(130 * time.Second)
		},
		"P3-wrong-node": func(f *cellFixture) {
			again := *f.pods[2].DeepCopy()
			again.Name, again.Spec.NodeName = "train-1-c", "w1"
			f.pods = append(f.pods, again)
		},
	}
	for name, bend := range cases {
		t.Run(name, func(t *testing.T) {
			f := faultFixture("ecc")
			bend(f)
			c := score(t, f)
			if !c.Valid() {
				t.Fatalf("invalid: %v", c.Invalid)
			}
			if len(c.Failed) == 0 || !strings.HasPrefix(c.Failed[0], name) {
				t.Fatalf("failed %v, want %s", c.Failed, name)
			}
		})
	}
}

func TestScoreCellCountsControlActions(t *testing.T) {
	for _, arm := range []string{"benign", "none"} {
		if c := score(t, faultFixture(arm)); !c.Valid() || len(c.Actions) != 0 {
			t.Fatalf("%s quiet: valid=%v invalid=%v actions=%v", arm, c.Valid(), c.Invalid, c.Actions)
		}
		f := faultFixture(arm)
		f.nodes[0].Spec.Taints = []corev1.Taint{{Key: taintKey, Effect: corev1.TaintEffectNoSchedule}}
		if c := score(t, f); len(c.Actions) != 1 {
			t.Fatalf("%s tainted: actions %v", arm, c.Actions)
		}
	}
}

func session(t *testing.T, smoke string, bend map[string]func(*cellFixture)) string {
	t.Helper()
	dir := t.TempDir()
	if smoke != "" {
		if err := os.WriteFile(filepath.Join(dir, "smoke.env"), []byte(smoke), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for i, arm := range Arms {
		for rep := 1; rep <= 5; rep++ {
			f := faultFixture(arm)
			f.env["rep"] = fmt.Sprint(rep)
			if b := bend[arm]; b != nil && rep == 1 {
				b(f)
			}
			f.write(t, filepath.Join(dir, "reps", fmt.Sprintf("%02d-%s", i*5+rep, arm)))
		}
	}
	return dir
}

const allRun = "arm_xid=run\narm_ecc=run\narm_benign=run\narm_none=run\n"

func TestJudgeVerdicts(t *testing.T) {
	r, err := ScoreSession(session(t, allRun, nil))
	if err != nil {
		t.Fatal(err)
	}
	if r.Label != "REHEARSAL" {
		t.Fatalf("a fake-exporter session labelled %q", r.Label)
	}
	want := map[string]string{"xid": "REACTED", "ecc": "REACTED", "benign": "QUIET", "none": "QUIET"}
	for _, a := range r.Arms {
		if a.Verdict != want[a.Arm] || a.Valid != 5 {
			t.Errorf("%s: %s with %d valid, want %s (%v)", a.Arm, a.Verdict, a.Valid, want[a.Arm], a.Reasons)
		}
	}

	// Detection at 2.95 to 3.05 s, wholly above the 2.8 s bound, with every later hop moved after it.
	slow := func(f *cellFixture) {
		for i := range f.nhs {
			if f.nhs[i].Annotations[annFingerprint] != "" {
				f.nhs[i].Annotations[annObservedAt] = ns(at(2950 * time.Millisecond))
				if _, ok := f.nhs[i].Annotations[annTaintedAt]; ok {
					f.nhs[i].Annotations[annTaintedAt] = ns(at(2960 * time.Millisecond))
				}
			}
		}
		for i := range f.wls {
			if f.wls[i].Annotations[annDeactivatedAt] != "" {
				f.wls[i].Annotations[annDeactivatedAt] = ns(at(2970 * time.Millisecond))
			}
			for j := range f.wls[i].Status.Conditions {
				if f.wls[i].Status.Conditions[j].Type == kueuev1beta1.WorkloadEvicted {
					f.wls[i].Status.Conditions[j].LastTransitionTime = whole(3 * time.Second)
				}
			}
		}
		f.jobs[1].Status.Conditions[0].LastTransitionTime = whole(3 * time.Second)
	}
	fp := func(f *cellFixture) { f.nodes[0].Spec.Taints = []corev1.Taint{{Key: taintKey}} }
	noPlace := func(f *cellFixture) { f.pods = f.pods[:2] }
	r, err = ScoreSession(session(t, "arm_xid=run\narm_ecc=run\narm_benign=run\narm_none=skipped\n",
		map[string]func(*cellFixture){"xid": slow, "ecc": noPlace, "benign": fp}))
	if err != nil {
		t.Fatal(err)
	}
	want = map[string]string{"xid": "REACTED-OUTSIDE-BOUND", "ecc": "FAILED", "benign": "FALSE-POSITIVE", "none": "NOT-RUN"}
	for _, a := range r.Arms {
		if a.Verdict != want[a.Arm] {
			t.Errorf("%s: %s, want %s (%v)", a.Arm, a.Verdict, want[a.Arm], a.Reasons)
		}
	}
}

func TestJudgeRefusals(t *testing.T) {
	// Three invalid of five leaves two: UNJUDGED.
	dir := session(t, allRun, nil)
	for _, rep := range []string{"01-xid", "02-xid", "03-xid"} {
		f := faultFixture("xid")
		f.env["pre_state"] = "no"
		f.write(t, filepath.Join(dir, "reps", rep))
	}
	r, err := ScoreSession(dir)
	if err != nil {
		t.Fatal(err)
	}
	if r.Arms[0].Verdict != "UNJUDGED" {
		t.Fatalf("xid with two valid: %s", r.Arms[0].Verdict)
	}
	// No smoke record: the session is refused whatever its repetitions say.
	if r, err := ScoreSession(session(t, "", nil)); err != nil || r.Label != "REFUSED" {
		t.Fatalf("no smoke.env: %s %v", r.Label, err)
	}
	// Mixed exporters cannot be one session.
	dir = session(t, allRun, map[string]func(*cellFixture){"none": func(f *cellFixture) { f.env["mode"] = "dcgm" }})
	if r, _ := ScoreSession(dir); r.Label != "REFUSED" {
		t.Fatalf("mixed modes: %s", r.Label)
	}
	// A dcgm session where allocatable moved fails P5 and keeps its arms.
	dir = t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "smoke.env"), []byte(allRun), 0o644); err != nil {
		t.Fatal(err)
	}
	for i, arm := range Arms {
		for rep := 1; rep <= 5; rep++ {
			f := faultFixture(arm)
			f.env["mode"] = "dcgm"
			if arm == "xid" && rep == 1 {
				f.env["alloc_after"] = "0"
			}
			f.write(t, filepath.Join(dir, "reps", fmt.Sprintf("%02d-%s", i*5+rep, arm)))
		}
	}
	r, _ = ScoreSession(dir)
	if r.Label != "RESULT" || !strings.HasPrefix(r.P5, "FAILED") || r.Arms[0].Verdict != "REACTED" {
		t.Fatalf("label %s p5 %s xid %s", r.Label, r.P5, r.Arms[0].Verdict)
	}
}

func TestStaleChecks(t *testing.T) {
	write := func(t *testing.T, dir, name, body string) {
		t.Helper()
		p := filepath.Join(dir, "checks", name)
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(p, "check.env"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	healthy := "during_signal_status=False\nduring_signal_reason=NoExporter\nduring_healthy_status=Unknown\nduring_taint=absent\nduring_latched=\n"
	latched := "before_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\nduring_signal_status=False\nduring_signal_reason=ScrapeFailed\n" +
		"during_healthy_status=False\nduring_taint=present\nduring_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\nafter_latched=\nafter_taint=absent\n"
	dir := session(t, allRun, nil)
	write(t, dir, "stale-healthy", healthy)
	write(t, dir, "stale-latched", latched)
	r, _ := ScoreSession(dir)
	stale := map[string]bool{}
	for _, name := range StaleChecks {
		stale[name] = true
	}
	for _, c := range r.Checks {
		if stale[c.Name] && c.Verdict != "PASS" {
			t.Fatalf("%s: %s %v", c.Name, c.Verdict, c.Reasons)
		}
	}
	// Each expectation, broken: stale data that reads healthy, and stale data that releases a fault.
	for name, body := range map[string]string{
		"stale-healthy": strings.Replace(healthy, "during_healthy_status=Unknown", "during_healthy_status=True", 1),
		"stale-latched": strings.Replace(latched, "during_taint=present", "during_taint=absent", 1),
	} {
		dir := session(t, allRun, nil)
		write(t, dir, name, body)
		r, _ := ScoreSession(dir)
		for _, c := range r.Checks {
			if c.Name == name && c.Verdict != "FAIL" {
				t.Fatalf("%s broken read as %s", name, c.Verdict)
			}
		}
	}
}

// A clearing step that never ran is a FAIL of the clause, but its reason must not describe a reading.
//
// Paid run 2 recorded no after_* lines because the exporter never came back, and the scorer printed
// "a fresh zero reading did not clear it" for a zero that was never injected.
func TestStaleLatchedNamesAClearingStepThatNeverRan(t *testing.T) {
	during := "before_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\nduring_signal_status=False\nduring_signal_reason=NoExporter\n" +
		"during_healthy_status=False\nduring_taint=present\nduring_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\n"
	for _, tc := range []struct {
		name, after, want, not string
	}{
		{"never reached", "", "never reached", "did not clear"},
		{"reached and still latched", "after_latched=GPU-a/DCGM_FI_DEV_XID_ERRORS=79\nafter_taint=present\n", "did not clear", "never reached"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := session(t, allRun, nil)
			p := filepath.Join(dir, "checks", "stale-latched")
			if err := os.MkdirAll(p, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(p, "check.env"), []byte(during+tc.after), 0o644); err != nil {
				t.Fatal(err)
			}
			r, _ := ScoreSession(dir)
			for _, c := range r.Checks {
				if c.Name != "stale-latched" {
					continue
				}
				reasons := strings.Join(c.Reasons, "; ")
				if c.Verdict != "FAIL" || !strings.Contains(reasons, tc.want) || strings.Contains(reasons, tc.not) {
					t.Fatalf("read as %s %q, want FAIL naming %q and not %q", c.Verdict, reasons, tc.want, tc.not)
				}
				return
			}
			t.Fatal("no stale-latched check in the report")
		})
	}
}

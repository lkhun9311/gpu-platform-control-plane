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
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The registered values the scorer judges against; each one's basis is in the registration.
const (
	// DetectBoundSeconds is P1, an idealised bound: one 1.0 s exporter collection, one 1.0 s scrape period and
	// one 0.8 s scrape timeout, with collection, publication and scheduling taking no time and no scrape failing.
	DetectBoundSeconds = 1.0 + 1.0 + 0.8
	// WindowSeconds is W, the observation window from the end of the injection call.
	WindowSeconds = 120.0
	// MinValidReps is the least number of valid repetitions an arm is judged on.
	MinValidReps = 3
	// truncationSlack is how far below zero a hop may read before the single clock is contradicted: whole-second
	// Kubernetes fields are truncated, so a true order can read up to one second backwards.
	truncationSlack = 1.0
)

// The annotation and taint names the platform writes, as the controller defines them.
// They are repeated here, not imported, because the scorer reads evidence and must not depend on the code it judges.
const (
	annFingerprint   = "gpufault.platform.lkhun9311.github.io/fingerprint"
	annObservedAt    = "gpufault.platform.lkhun9311.github.io/observed-at"
	annTaintedAt     = "gpufault.platform.lkhun9311.github.io/tainted-at"
	annReading       = "gpufault.platform.lkhun9311.github.io/reading"
	annReadingAt     = "gpufault.platform.lkhun9311.github.io/reading-at"
	annDeactivatedAt = "gpufault.platform.lkhun9311.github.io/deactivated-at"
	annWLFingerprint = "gpufault.platform.lkhun9311.github.io/deactivated-fingerprint"
	annReactivatedAt = "gpufault.platform.lkhun9311.github.io/reactivated-at"
	taintKey         = "platform.lkhun9311.github.io/gpu-fault"
	condGPUHealthy   = "GPUHealthy"
)

// Arms, and the field and value each injects.
var armInjection = map[string]struct {
	field string
	value string
	fault bool
}{
	"xid":    {FieldXid, "79", true},
	"ecc":    {FieldECCDoubleBit, "1", true},
	"benign": {FieldECCSingleBit, "1", false},
	armNone:  {FieldXid, "", false},
}

// armNone is the arm that injects nothing, and so is read differently at every step.
const armNone = "none"

// Arms lists the arms in the registered order.
var Arms = []string{"xid", "ecc", "benign", armNone}

// streams are the watch files every repetition records, by the resource each watches.
var streams = []string{"node", "nodehealth", "workload", "job", "pods"}

// Interval is a duration in seconds, [Lo, Hi]: Lo == Hi only when both ends are nanosecond stamps.
type Interval struct {
	Lo float64 `json:"lo"`
	Hi float64 `json:"hi"`
}

// CellResult is one repetition's reading.
type CellResult struct {
	Dir     string               `json:"dir"`
	Arm     string               `json:"arm"`
	Rep     int                  `json:"rep"`
	Block   int                  `json:"block"`
	Mode    string               `json:"mode"`
	Invalid []string             `json:"invalid,omitempty"`
	Hops    map[string]*Interval `json:"hops,omitempty"`
	// Failed names each registered predicate a fault repetition broke, with what the evidence showed.
	Failed []string `json:"failed,omitempty"`
	// Actions lists the platform's actions in a control repetition.
	Actions []string `json:"actions,omitempty"`
	// AllocatableChanged is P5's reading: whether the target's allocatable GPUs moved across the injection.
	AllocatableChanged bool `json:"allocatableChanged"`
	// Cut is true when the session ran out of time inside this repetition.
	Cut bool `json:"cut,omitempty"`
}

// Valid reports whether the repetition is scored at all.
func (c CellResult) Valid() bool { return len(c.Invalid) == 0 && !c.Cut }

// readEnv reads a key=value file; a missing file is an error, a malformed line is an error.
func readEnv(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for i, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("%s:%d: no '=' in %q", path, i+1, line)
		}
		out[k] = v
	}
	return out, nil
}

// epoch parses the runner's `date +%s.%N` stamps.
func epoch(s string) (time.Time, error) {
	sec, frac, _ := strings.Cut(strings.TrimSpace(s), ".")
	si, err := strconv.ParseInt(sec, 10, 64)
	if err != nil || s == "" {
		return time.Time{}, fmt.Errorf("not an epoch stamp: %q", s)
	}
	var ns int64
	if frac != "" {
		frac = (frac + "000000000")[:9]
		if ns, err = strconv.ParseInt(frac, 10, 64); err != nil {
			return time.Time{}, fmt.Errorf("not an epoch stamp: %q", s)
		}
	}
	return time.Unix(si, ns).UTC(), nil
}

// decodeStream reads a `kubectl get -w -o json` file: concatenated objects, a List expanded into its items.
// An empty or missing file is an error, because a watch that recorded nothing is not a watch that saw nothing.
func decodeStream[T any](path string) ([]T, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(b)) == 0 {
		return nil, fmt.Errorf("%s is empty", filepath.Base(path))
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	var out []T
	for {
		var raw json.RawMessage
		if err := dec.Decode(&raw); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(path), err)
		}
		var head struct {
			Kind  string            `json:"kind"`
			Items []json.RawMessage `json:"items"`
		}
		if err := json.Unmarshal(raw, &head); err != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(path), err)
		}
		docs := []json.RawMessage{raw}
		if strings.HasSuffix(head.Kind, "List") {
			docs = head.Items
		}
		for _, d := range docs {
			var v T
			if err := json.Unmarshal(d, &v); err != nil {
				return nil, fmt.Errorf("%s: %w", filepath.Base(path), err)
			}
			out = append(out, v)
		}
	}
	return out, nil
}

// watchCoverage checks a watch's start and end records: one start before from, and no end before to.
//
// A watch that disconnected inside the window leaves a file that parses and is not empty, and whatever happened
// in the gap is unknown, not absent; so a gap makes the repetition invalid rather than quiet.
func watchCoverage(path string, from, to time.Time) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	starts, firstStart := 0, time.Time{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		t, err := epoch(fields[1])
		if err != nil {
			return fmt.Errorf("%s: %w", filepath.Base(path), err)
		}
		switch fields[0] {
		case "start":
			starts++
			if firstStart.IsZero() {
				firstStart = t
			}
		case "end":
			if t.Before(to) {
				return fmt.Errorf("%s: the watch ended at %s, inside the window", filepath.Base(path), t.Format(time.RFC3339Nano))
			}
		}
	}
	switch {
	case starts == 0:
		return fmt.Errorf("%s: no watch start recorded", filepath.Base(path))
	case starts > 1:
		return fmt.Errorf("%s: the watch restarted %d times", filepath.Base(path), starts-1)
	case firstStart.After(from):
		return fmt.Errorf("%s: the watch started at %s, after the injection began", filepath.Base(path), firstStart.Format(time.RFC3339Nano))
	}
	return sc.Err()
}

func ann(o metav1.Object, key string) (time.Time, bool) {
	s := o.GetAnnotations()[key]
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	return t, err == nil
}

func secs(d time.Duration) float64 { return d.Seconds() }

// span is end − start when end is a nanosecond stamp and start is the injection bracket [s0, s1].
func span(end, s0, s1 time.Time) *Interval {
	return &Interval{secs(end.Sub(s1)), secs(end.Sub(s0))}
}

// spanS is end − start when end is a whole-second Kubernetes time, truncated, and start is a bracket.
func spanS(end, s0, s1 time.Time) *Interval {
	return &Interval{secs(end.Sub(s1)), secs(end.Add(time.Second).Sub(s0))}
}

// wholeSecond is a nanosecond start to a truncated end: [end − start, end + 1 − start].
func wholeSecond(end, start time.Time) *Interval {
	d := secs(end.Sub(start))
	return &Interval{d, d + 1}
}

// bothWhole is the difference of two truncated times, each up to a second late.
func bothWhole(end, start time.Time) *Interval {
	d := secs(end.Sub(start))
	return &Interval{d - 1, d + 1}
}

// cellEvidence is a repetition's decoded streams.
type cellEvidence struct {
	nhs   []platformv1.NodeHealth
	nodes []corev1.Node
	wls   []kueuev1beta1.Workload
	jobs  []batchv1.Job
	pods  []corev1.Pod
}

func loadEvidence(dir string) (cellEvidence, error) {
	var e cellEvidence
	var errs [5]error
	e.nhs, errs[0] = decodeStream[platformv1.NodeHealth](filepath.Join(dir, "watch-nodehealth.json"))
	e.nodes, errs[1] = decodeStream[corev1.Node](filepath.Join(dir, "watch-node.json"))
	e.wls, errs[2] = decodeStream[kueuev1beta1.Workload](filepath.Join(dir, "watch-workload.json"))
	e.jobs, errs[3] = decodeStream[batchv1.Job](filepath.Join(dir, "watch-job.json"))
	e.pods, errs[4] = decodeStream[corev1.Pod](filepath.Join(dir, "watch-pods.json"))
	return e, errors.Join(errs[:]...)
}

// ScoreCell reads one repetition's directory.
func ScoreCell(dir string) (CellResult, error) {
	env, err := readEnv(filepath.Join(dir, "cell.env"))
	if err != nil {
		return CellResult{}, err
	}
	res := CellResult{Dir: dir, Arm: env["arm"], Mode: env["mode"], Hops: map[string]*Interval{}}
	res.Rep, _ = strconv.Atoi(env["rep"])
	res.Block, _ = strconv.Atoi(env["block"])
	inj, ok := armInjection[res.Arm]
	if !ok {
		return CellResult{}, fmt.Errorf("%s: arm %q is not registered", dir, res.Arm)
	}
	invalid := func(f string, a ...any) { res.Invalid = append(res.Invalid, fmt.Sprintf(f, a...)) }
	res.Cut = env["cut"] == "true"

	// V6, the part a cell can see: the run must say which exporter it read.
	if res.Mode != "fake" && res.Mode != "dcgm" {
		invalid("V6: mode %q is neither fake nor dcgm", res.Mode)
	}
	// V2.
	if env["pre_state"] != "ok" {
		invalid("V2: pre-state %q", env["pre_state"])
	}
	tInj0, e1 := epoch(env["t_inject_start"])
	tInj1, e2 := epoch(env["t_inject_end"])
	tEnd, e3 := epoch(env["t_window_end"])
	if err := errors.Join(e1, e2, e3); err != nil || tInj1.Before(tInj0) {
		invalid("V3: injection or window stamps unreadable or out of order (%v)", err)
		return res, nil
	}
	// V1: the value read back is the value written, and the field is the arm's.
	wantRB := inj.value
	if res.Arm == armNone {
		wantRB = env["baseline"]
	}
	if env["readback"] != wantRB || wantRB == "" {
		invalid("V1: readback %q, want %q", env["readback"], wantRB)
	}
	if env["field"] != fieldID(inj.field) {
		invalid("V1: field %q, want %s", env["field"], fieldID(inj.field))
	}
	res.AllocatableChanged = env["alloc_before"] != env["alloc_after"]

	// V5: the exporter served the injected value, for every arm that injected.
	if res.Arm != armNone {
		first, perr := firstProbe(filepath.Join(dir, "probe.tsv"), inj.value, tInj0, tEnd)
		switch {
		case perr != nil:
			invalid("V3: probe: %v", perr)
		case first.IsZero():
			invalid("V5: the exporter never served %s=%s inside the window", inj.field, inj.value)
		default:
			res.Hops["exporter_lag"] = span(first, tInj0, tInj1)
		}
	}

	// V3: every stream present, parseable, and watching from before the injection to the window's end.
	for _, s := range streams {
		if err := watchCoverage(filepath.Join(dir, "watch-"+s+".log"), tInj0, tEnd); err != nil {
			invalid("V3: %v", err)
		}
	}
	ev, err := loadEvidence(dir)
	if err != nil {
		invalid("V3: %v", err)
		return res, nil
	}
	job, target, healthy := env["job"], env["target"], env["healthy"]
	ev.nhs = slices.DeleteFunc(ev.nhs, func(n platformv1.NodeHealth) bool { return n.Spec.NodeName != target })
	ev.nodes = slices.DeleteFunc(ev.nodes, func(n corev1.Node) bool { return n.Name != target })
	ev.wls = slices.DeleteFunc(ev.wls, func(w kueuev1beta1.Workload) bool { return !ownedByJob(&w, job) })
	ev.jobs = slices.DeleteFunc(ev.jobs, func(j batchv1.Job) bool { return j.Name != job })
	if len(ev.nhs) == 0 || len(ev.nodes) == 0 {
		invalid("V3: the streams carry no NodeHealth or Node for target %q", target)
		return res, nil
	}

	if !inj.fault {
		scoreControl(&res, env, ev, inj.field, tInj0, tEnd, invalid)
		return res, nil
	}
	scoreFault(&res, env, ev, inj.field, inj.value, tInj0, tInj1, target, healthy)
	return res, nil
}

// scoreControl counts the platform's actions in a control window, and demands evidence the observer was reading.
//
// A quiet control is evidence only if the operator was reading the card: for the benign arm, the reading it
// recorded must carry the injected value; for no injection, it must have recorded the sentinel the runner
// injects after the window. Without that, the repetition says nothing and is invalid.
func scoreControl(res *CellResult, env map[string]string, ev cellEvidence, field string, tInj0, tEnd time.Time,
	invalid func(string, ...any)) {
	res.Actions = controlActions(ev)
	want, from := env["uuid"]+"/"+field+"=1", tInj0
	if res.Arm == armNone {
		t, err := epoch(env["t_sentinel_start"])
		if err != nil || env["sentinel_value"] == "" {
			invalid("V7: no sentinel recorded, so nothing shows the observer was reading (%v)", err)
			return
		}
		want, from = env["uuid"]+"/"+FieldECCSingleBit+"="+env["sentinel_value"], t
		tEnd = t.Add(SentinelSeconds * time.Second)
	}
	for i := range ev.nhs {
		at, ok := ann(&ev.nhs[i], annReadingAt)
		if ok && !at.Before(from) && !at.After(tEnd) && slices.Contains(strings.Split(ev.nhs[i].Annotations[annReading], ","), want) {
			return
		}
	}
	invalid("V7: the operator never recorded reading %s between %s and %s", want, from.Format(time.RFC3339Nano), tEnd.Format(time.RFC3339Nano))
}

// SentinelSeconds is how long after the no-injection window the runner waits for the operator to read its
// sentinel: ten scrape periods, a convention.
const SentinelSeconds = 10

// faultTimes are a fault repetition's hop times, each zero until its evidence is found.
type faultTimes struct {
	obs, taint, deact, evict, release, react, readmit, suspend, stop, start0, placed, run time.Time
	wrongNode                                                                             string
}

// scoreFault reads a fault repetition's hops, in the order each stream recorded them.
func scoreFault(res *CellResult, env map[string]string, ev cellEvidence, field, value string, tInj0, tInj1 time.Time,
	target, healthy string) {
	fail := func(f string, a ...any) { res.Failed = append(res.Failed, fmt.Sprintf(f, a...)) }
	want := env["uuid"] + "/" + field + "=" + value
	var ft faultTimes
	if latched := ft.readNodeHealth(ev.nhs, want); latched != "" {
		// The stimulus is established independently, by readback and the probe; a different fingerprint is the
		// platform's output, and a wrong output is a result.
		fail("attribution: the platform latched %q, the injection was %q", latched, want)
		return
	}
	nodeTainted := slices.ContainsFunc(ev.nodes, func(n corev1.Node) bool {
		return slices.ContainsFunc(n.Spec.Taints, func(t corev1.Taint) bool { return t.Key == taintKey })
	})
	if !ft.taint.IsZero() && !nodeTainted {
		fail("P2-order: tainted-at is recorded and no Node object in the stream carries the taint")
	}
	ft.readWorkload(ev.wls, want)
	ft.readJob(ev.jobs)
	ft.readPods(ev.pods, target, healthy)
	if ft.wrongNode != "" {
		fail("P3-wrong-node: %s was placed after the taint, not on the healthy node", ft.wrongNode)
	}
	if missing := ft.firstMissing(); missing != "" {
		fail("P2-missing: no %s", missing)
	}
	ft.hops(res, tInj0, tInj1)
	if !ft.obs.IsZero() && ft.obs.Before(tInj0) {
		fail("P2-order: observed-at precedes the injection's start")
	}
	if e := res.Hops["end_to_end"]; e != nil && e.Hi > WindowSeconds {
		fail("P3-late: placed at [%.3f, %.3f] s, not wholly inside W", e.Lo, e.Hi)
	}
	for _, f := range ft.orderFailures() {
		fail("%s", f)
	}
	for name, h := range res.Hops {
		if h.Hi < -truncationSlack {
			fail("P2-order: hop %s reads %.3f s", name, h.Hi)
		}
	}
}

// readNodeHealth finds the platform's own stamps; it returns a latched fingerprint that is not want, if any.
func (ft *faultTimes) readNodeHealth(nhs []platformv1.NodeHealth, want string) string {
	for i := range nhs {
		fp := nhs[i].Annotations[annFingerprint]
		switch {
		case fp == "":
			continue
		case fp != want:
			return fp
		}
		if ft.obs.IsZero() {
			ft.obs, _ = ann(&nhs[i], annObservedAt)
		}
		if t, ok := ann(&nhs[i], annTaintedAt); ok && ft.taint.IsZero() {
			ft.taint = t
		}
	}
	return ""
}

// readWorkload reads the Workload's transitions in stream order: deactivated, evicted, quota released,
// reactivated, readmitted. Stream order, not timestamps, because whole-second stamps can reorder within a second.
func (ft *faultTimes) readWorkload(wls []kueuev1beta1.Workload, want string) {
	released := false
	for i := range wls {
		w := &wls[i]
		if ft.deact.IsZero() {
			t, ok := ann(w, annDeactivatedAt)
			if !ok || w.Annotations[annWLFingerprint] != want {
				continue
			}
			ft.deact = t
		}
		if c := meta.FindStatusCondition(w.Status.Conditions, kueuev1beta1.WorkloadEvicted); ft.evict.IsZero() &&
			c != nil && c.Status == metav1.ConditionTrue && strings.HasPrefix(c.Reason, kueuev1beta1.WorkloadDeactivated) {
			ft.evict = c.LastTransitionTime.Time
		}
		qr := meta.FindStatusCondition(w.Status.Conditions, kueuev1beta1.WorkloadQuotaReserved)
		reserved := qr != nil && qr.Status == metav1.ConditionTrue
		switch {
		case !released && !reserved:
			released = true
			if qr != nil {
				ft.release = qr.LastTransitionTime.Time
			}
		case released && reserved && ft.readmit.IsZero():
			ft.readmit = qr.LastTransitionTime.Time
		}
		if t, ok := ann(w, annReactivatedAt); ok && ft.react.IsZero() {
			ft.react = t
		}
	}
}

// readJob finds the Job's suspension after the deactivation.
func (ft *faultTimes) readJob(jobs []batchv1.Job) {
	if ft.deact.IsZero() {
		return
	}
	for i := range jobs {
		for _, c := range jobs[i].Status.Conditions {
			if c.Type == batchv1.JobSuspended && c.Status == corev1.ConditionTrue && ft.suspend.IsZero() &&
				!c.LastTransitionTime.Time.Before(ft.deact.Truncate(time.Second)) {
				ft.suspend = c.LastTransitionTime.Time
			}
		}
	}
}

// readPods finds the displaced container's stop, the new Pod's placement, and any Pod placed on the wrong node.
func (ft *faultTimes) readPods(pods []corev1.Pod, target, healthy string) {
	for i := range pods {
		p := &pods[i]
		for _, cs := range p.Status.ContainerStatuses {
			if p.Spec.NodeName == target && cs.State.Terminated != nil && ft.stop.IsZero() {
				ft.stop, ft.start0 = cs.State.Terminated.FinishedAt.Time, cs.State.Terminated.StartedAt.Time
			}
			if p.Spec.NodeName == healthy && cs.State.Running != nil && ft.run.IsZero() {
				ft.run = cs.State.Running.StartedAt.Time
			}
		}
		c := podCondition(p, corev1.PodScheduled)
		if c == nil || c.Status != corev1.ConditionTrue {
			continue
		}
		afterTaint := !ft.taint.IsZero() && p.CreationTimestamp.After(ft.taint.Truncate(time.Second))
		switch {
		case p.Spec.NodeName == healthy && ft.placed.IsZero():
			ft.placed = c.LastTransitionTime.Time
		case p.Spec.NodeName != healthy && afterTaint:
			ft.wrongNode = p.Name + " on " + p.Spec.NodeName
		}
	}
}

// firstMissing names the first hop, in the path's order, with no evidence.
func (ft *faultTimes) firstMissing() string {
	for _, h := range []struct {
		name string
		at   time.Time
	}{{"observed", ft.obs}, {"tainted", ft.taint}, {"deactivated", ft.deact}, {"evicted", ft.evict}, {"suspended", ft.suspend},
		{"released", ft.release}, {"stopped", ft.stop}, {"reactivated", ft.react}, {"readmitted", ft.readmit}, {"placed", ft.placed}} {
		if h.at.IsZero() {
			return h.name
		}
	}
	return ""
}

// hops turns the times into the registered intervals; a hop whose ends are not both known is left out.
func (ft *faultTimes) hops(res *CellResult, tInj0, tInj1 time.Time) {
	exact := func(a, b time.Time) *Interval { d := secs(b.Sub(a)); return &Interval{d, d} }
	set := func(name string, ok bool, iv func() *Interval) {
		if ok {
			res.Hops[name] = iv()
		}
	}
	set("detect", !ft.obs.IsZero(), func() *Interval { return span(ft.obs, tInj0, tInj1) })
	set("taint", !ft.obs.IsZero() && !ft.taint.IsZero(), func() *Interval { return exact(ft.obs, ft.taint) })
	set("evict_request", !ft.taint.IsZero() && !ft.deact.IsZero(), func() *Interval { return exact(ft.taint, ft.deact) })
	for name, t := range map[string]time.Time{"kueue_evict": ft.evict, "job_suspend": ft.suspend, "quota_release": ft.release, "stop": ft.stop} {
		set(name, !ft.deact.IsZero() && !t.IsZero(), func() *Interval { return wholeSecond(t, ft.deact) })
	}
	set("readmit", !ft.release.IsZero() && !ft.readmit.IsZero(), func() *Interval { return bothWhole(ft.readmit, ft.release) })
	set("end_to_end", !ft.placed.IsZero(), func() *Interval { return spanS(ft.placed, tInj0, tInj1) })
	set("running", !ft.run.IsZero(), func() *Interval { return spanS(ft.run, tInj0, tInj1) })
	set("lost_work", !ft.stop.IsZero() && !ft.start0.IsZero(), func() *Interval {
		lw := bothWhole(ft.stop, ft.start0)
		lw.Lo = math.Max(0, lw.Lo)
		return lw
	})
}

// orderFailures checks P2's order among the nanosecond stamps, and against the truncated ones within truncation.
func (ft *faultTimes) orderFailures() []string {
	var out []string
	for _, o := range []struct {
		a, b   time.Time
		an, bn string
		slack  time.Duration
	}{
		{ft.obs, ft.taint, "observed", "tainted", 0}, {ft.taint, ft.deact, "tainted", "deactivated", 0},
		{ft.deact, ft.evict, "deactivated", "evicted", time.Second}, {ft.evict, ft.readmit, "evicted", "readmitted", time.Second},
		{ft.readmit, ft.placed, "readmitted", "placed", time.Second},
	} {
		if !o.a.IsZero() && !o.b.IsZero() && o.b.Add(o.slack).Before(o.a) {
			out = append(out, fmt.Sprintf("P2-order: %s at %s precedes %s at %s", o.bn, o.b.Format(time.RFC3339Nano), o.an, o.a.Format(time.RFC3339Nano)))
		}
	}
	return out
}

func fieldID(name string) string {
	switch name {
	case FieldXid:
		return "230"
	case FieldECCDoubleBit:
		return "311"
	case FieldECCSingleBit:
		return "310"
	}
	return ""
}

func ownedByJob(w *kueuev1beta1.Workload, job string) bool {
	for _, o := range w.OwnerReferences {
		if o.Kind == "Job" && o.Name == job {
			return true
		}
	}
	return false
}

func podCondition(p *corev1.Pod, t corev1.PodConditionType) *corev1.PodCondition {
	for i := range p.Status.Conditions {
		if p.Status.Conditions[i].Type == t {
			return &p.Status.Conditions[i]
		}
	}
	return nil
}

// controlActions lists every platform action a control repetition's streams carry.
func controlActions(ev cellEvidence) []string {
	var out []string
	for i := range ev.nhs {
		if c := meta.FindStatusCondition(ev.nhs[i].Status.Conditions, condGPUHealthy); c != nil && c.Status == metav1.ConditionFalse {
			out = append(out, "GPUHealthy=False ("+c.Reason+")")
			break
		}
	}
	for i := range ev.nhs {
		if fp := ev.nhs[i].Annotations[annFingerprint]; fp != "" {
			out = append(out, "latched "+fp)
			break
		}
	}
	for i := range ev.nodes {
		if slices.ContainsFunc(ev.nodes[i].Spec.Taints, func(t corev1.Taint) bool { return t.Key == taintKey }) {
			out = append(out, "gpu-fault taint")
			break
		}
	}
	for i := range ev.wls {
		if ev.wls[i].Annotations[annDeactivatedAt] != "" {
			out = append(out, "deactivated "+ev.wls[i].Name)
			break
		}
	}
	return out
}

// firstProbe returns the first probe sample inside [after, until] that carries the value.
// Each line is "<epoch>\t<value>"; a value of ERR is a probe that failed, and is skipped.
func firstProbe(path, value string, after, until time.Time) (time.Time, error) {
	f, err := os.Open(path)
	if err != nil {
		return time.Time{}, err
	}
	defer func() { _ = f.Close() }()
	want, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("injected value %q is not a number", value)
	}
	sc := bufio.NewScanner(f)
	n := 0
	for sc.Scan() {
		ts, v, ok := strings.Cut(sc.Text(), "\t")
		if !ok {
			return time.Time{}, fmt.Errorf("malformed probe line %q", sc.Text())
		}
		n++
		t, err := epoch(ts)
		if err != nil {
			return time.Time{}, err
		}
		if t.Before(after) || t.After(until) || v == "ERR" {
			continue
		}
		if fv, err := strconv.ParseFloat(v, 64); err == nil && fv == want {
			return t, nil
		}
	}
	if err := sc.Err(); err != nil {
		return time.Time{}, err
	}
	if n == 0 {
		return time.Time{}, fmt.Errorf("the probe recorded no samples")
	}
	return time.Time{}, nil
}

// ArmVerdict is one arm's registered reading.
type ArmVerdict struct {
	Arm     string                `json:"arm"`
	Verdict string                `json:"verdict"`
	Valid   int                   `json:"valid"`
	Total   int                   `json:"total"`
	Reasons []string              `json:"reasons,omitempty"`
	Summary map[string][3]float64 `json:"summary,omitempty"`
}

// CheckResult is one registered check outside the arms: the stale-signal cells.
type CheckResult struct {
	Name    string   `json:"name"`
	Verdict string   `json:"verdict"`
	Reasons []string `json:"reasons,omitempty"`
}

// Report is the session's reading.
type Report struct {
	Label  string        `json:"label"`
	Arms   []ArmVerdict  `json:"arms"`
	Checks []CheckResult `json:"checks"`
	P5     string        `json:"p5"`
	Cells  []CellResult  `json:"cells"`
	Refuse []string      `json:"refuse,omitempty"`
}

// Judge applies the verdict rules to every repetition of a session; notRun names arms the smoke cell stopped.
func Judge(cells []CellResult, notRun map[string]bool) Report {
	rep := Report{Label: "RESULT", Cells: cells}
	modes := map[string]bool{}
	for _, c := range cells {
		modes[c.Mode] = true
	}
	switch {
	case len(cells) == 0:
		rep.Label = "NO-EVIDENCE"
		rep.Refuse = append(rep.Refuse, "no repetition directory was found")
	case len(modes) != 1:
		rep.Label = "REFUSED"
		rep.Refuse = append(rep.Refuse, fmt.Sprintf("repetitions disagree on the exporter: %v", modes))
	case modes["fake"]:
		// The fake exporter is the apparatus, not DCGM: nothing it scores is a result.
		rep.Label = "REHEARSAL"
	}
	// P5's failure is an unexpected change with its cause unresolved, never by itself proof that injection
	// reached NVML: the device plugin also marks devices unhealthy on its own NVML errors.
	rep.P5 = "held"
	for _, c := range cells {
		if c.Valid() && c.AllocatableChanged {
			rep.P5 = "FAILED: allocatable changed across an injection in " + filepath.Base(c.Dir) + "; cause unresolved"
		}
	}
	for _, arm := range Arms {
		v := ArmVerdict{Arm: arm, Summary: map[string][3]float64{}}
		var valid []CellResult
		for _, c := range cells {
			if c.Arm != arm {
				continue
			}
			v.Total++
			switch {
			case c.Valid():
				valid = append(valid, c)
			case c.Cut:
				v.Reasons = append(v.Reasons, filepath.Base(c.Dir)+": cut by the session deadline")
			default:
				v.Reasons = append(v.Reasons, filepath.Base(c.Dir)+": INVALID: "+strings.Join(c.Invalid, "; "))
			}
		}
		v.Valid = len(valid)
		switch {
		case notRun[arm]:
			v.Verdict = "NOT-RUN"
		case len(valid) < MinValidReps:
			v.Verdict = "UNJUDGED"
		case armInjection[arm].fault:
			v.Verdict = judgeFault(valid, &v)
		default:
			v.Verdict = "QUIET"
			for _, c := range valid {
				if len(c.Actions) > 0 {
					v.Verdict = "FALSE-POSITIVE"
					v.Reasons = append(v.Reasons, filepath.Base(c.Dir)+": "+strings.Join(c.Actions, ", "))
				}
			}
			v.Reasons = append(v.Reasons, fmt.Sprintf("%d fully observed window(s); this is a count, not a rate", len(valid)))
		}
		rep.Arms = append(rep.Arms, v)
	}
	return rep
}

func judgeFault(valid []CellResult, v *ArmVerdict) string {
	failed, outside := false, false
	for _, c := range valid {
		name := filepath.Base(c.Dir)
		for _, f := range c.Failed {
			failed = true
			v.Reasons = append(v.Reasons, name+": "+f)
		}
		// P1 is breached only when the whole detect interval lies above the bound.
		if d := c.Hops["detect"]; d != nil && d.Lo > DetectBoundSeconds {
			outside = true
			v.Reasons = append(v.Reasons, fmt.Sprintf("%s: P1: detect [%.3f, %.3f] s lies above %.1f s", name, d.Lo, d.Hi, DetectBoundSeconds))
		}
	}
	// The per-hop summary: median, minimum and maximum of each interval's upper end, over valid repetitions.
	names := map[string]bool{}
	for _, c := range valid {
		for n := range c.Hops {
			names[n] = true
		}
	}
	for n := range names {
		var xs []float64
		for _, c := range valid {
			if h := c.Hops[n]; h != nil {
				xs = append(xs, h.Hi)
			}
		}
		sort.Float64s(xs)
		v.Summary[n] = [3]float64{median(xs), xs[0], xs[len(xs)-1]}
	}
	switch {
	case failed:
		return "FAILED"
	case outside:
		return "REACTED-OUTSIDE-BOUND"
	}
	return "REACTED"
}

func median(xs []float64) float64 {
	n := len(xs)
	if n%2 == 1 {
		return xs[n/2]
	}
	return (xs[n/2-1] + xs[n/2]) / 2
}

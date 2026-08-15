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

package main

import (
	"encoding/json"
	"fmt"
	"reflect"
	"runtime/debug"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// qualifyWorker establishes that the worker has the devices and is not already carrying somebody else's, and
// that is a claim about CAPACITY. It says nothing about the mechanism the experiment is actually built out of.
//
// The two arms differ by one shell command and nothing else: A-honor runs `trap 'exit 143' TERM; sleep D &
// wait` and A-ignore runs `sleep D`, under one termination grace period. Everything the study reports is the
// difference between those two under a delete. So if this cluster does not deliver SIGTERM to that process —
// a runtime quirk, a shim that kills instead of signalling, a shell that is not PID 1 — an A-honor Pod behaves
// exactly like an A-ignore Pod, the contrast the arm is named for is gone, and the run still completes and
// still prints numbers that look entirely reasonable.
//
// This file is the recorded answer to that question, and its central design point is that it qualifies the
// CONTRAST rather than one half of it. "The honouring Pod stopped promptly" is passed with flying colours by a
// runtime that SIGKILLs everything the instant it is asked, which is precisely the failure that collapses the
// two arms into one. So the ignoring Pod has to be shown to SURVIVE to the grace deadline in the same
// experiment, or nothing has been established.

const (
	// canaryAnnotationKey is where the qualification lives: an annotation on the worker Node itself.
	//
	// The alternatives were a file next to the operator who ran the canary, and a cluster-side object of some
	// other kind. A file is the same mistake this lineage already found in the machine-local recordPath: the
	// qualification is a statement about a CLUSTER, and a file on somebody's laptop says nothing at all about
	// the cluster a later run — very possibly from another laptop, or from CI — is about to measure on.
	//
	// Among cluster-side homes the Node is the one that costs nothing and carries its own lifecycle. Two of the
	// three things being qualified (the kubelet and the container runtime that actually deliver the signal) are
	// properties OF THIS NODE and are read off this very object, so the verdict sits beside the facts it was
	// derived from and is compared against them in one read. It needs no namespace anybody has to own, it is
	// covered by the Node access the runner already has for the ownership transaction, and it expires by
	// construction: a node deleted and recreated — a rebuilt kind cluster, the ordinary case here — takes the
	// annotation with it rather than leaving a document that outlived the machine it described.
	//
	// A ConfigMap would have needed a namespace that no run owns (the run's own namespace is deleted at
	// teardown), a second RBAC rule, and a garbage-collection story of its own, in exchange for nothing this
	// needs.
	canaryAnnotationKey = "queuelab.gpu-platform/termination-canary"
	canarySchema        = 1

	// canaryNamespace holds the probe Pods. It is deliberately not a run namespace: this is not a run, it
	// creates no fixtures, and it must be able to execute while gateRefusal refuses every run.
	canaryNamespace = "queuelab-canary"

	// canaryArm is what the ownership journal records for a canary's transaction, so an operator running
	// -inspect-worker on a node a canary is holding is told what is holding it rather than seeing an arm name
	// the experiment does not have.
	canaryArm = "termination-canary"
)

// honorExitCode mirrors internal/queuelab's private termExitCode, duplicated for the reason spine.go
// duplicates terminationGraceSec: that package is measurement code that must not change for this, and it does
// not export the constant. TestCanaryContractMirrorsWhatTheHarnessActuallyRenders pins the two together
// against the renderer's own output, so the copy cannot drift in silence.
//
// What an observed 143 does and does not prove is worth stating exactly, because it is easy to over-read. A
// process killed BY an untrapped SIGTERM also exits 128+15, so 143 is not proof that the trap ran. What it IS
// proof of is the thing the arm depends on: the signal was delivered and the process stopped because of it.
// The two states this rules out are the ones that would collapse the arms — a SIGKILL after the grace deadline
// (137, the ignoring arm's own ending) and a natural completion (0).
const honorExitCode = 143

// killExitCode is 128+SIGKILL, which is how a container that outlasted its grace period ends.
//
// It is required of the ignoring probe rather than merely expected. Requiring it is what makes "it survived"
// a positive observation — the kubelet had to take it out — instead of an inference from a clock reading that
// a slow status update could also produce.
//
// There is a second guard against that stall, noticed after this was written and worth recording because it
// is not obvious: both probes are read by ONE loop on ONE clock, so a stall long enough to make a
// promptly-killed ignoring probe look like a survivor inflates the honouring probe's reading by the same
// interval — and the honouring probe has an UPPER bound. A global stall therefore trips canaryPromptWithin
// before it can manufacture a survivor. The two bounds protect each other; this clause is what closes the
// remaining case, a stall that somehow reached only one of the two reads.
const killExitCode = 137

// The two thresholds that turn the observation into a verdict, both derived from terminationGraceSec so they
// can never drift away from the window they are dividing up.
//
// They are a third and two thirds of the grace period rather than tight bounds around zero and thirty,
// because what has to be demonstrated is a CONTRAST and not a latency: the honouring workload must stop in a
// region no grace-expiry kill can reach, and the ignoring one must survive into a region no prompt exit can
// reach. A gap of a third of the window between the two is far wider than any scheduling or polling jitter,
// and it stays a real gap on a slow cluster instead of turning into a flake that gets re-run until it passes.
const (
	canaryPromptWithin    = (terminationGraceSec / 3) * time.Second
	canarySurvivesAtLeast = (2 * terminationGraceSec / 3) * time.Second
)

// canaryContract is the half of the qualification key that comes out of this build rather than off the
// cluster: what is run, how it is asked to stop, and what stopping is supposed to look like.
//
// Every field is READ FROM THE MEASUREMENT PACKAGE'S OWN RENDERER rather than copied. That is the whole point
// of the type: a canary that probed a hand-written imitation of the workload would qualify a command nothing
// submits, and the image digest in particular is exactly the kind of constant that gets updated in one place
// and not the other. harnessTerminationContract calls RenderMLTrainingJobWithContract, which is the same
// function submit() calls, so the probe runs the bytes the arm runs by construction.
type canaryContract struct {
	Image         string
	HonorCommand  []string
	IgnoreCommand []string
	// ProbeDurationSec is the row duration the two commands above were rendered at. It is not a property of any
	// arm — it is how long the probe sleeper would run if nobody stopped it — and it is carried so the key can
	// record the commands exactly as they were probed rather than as a template nobody executed.
	ProbeDurationSec int
	GraceSec         int64
	HonorExitCode    int32
}

// canaryProbeDurationSec is how long a probe Pod would sleep if nothing ever asked it to stop.
//
// It has to outlast the whole probe — start-up, the grace period, and the slack around both — because a
// sleeper that finished on its own would give a prompt, clean exit that means nothing about signal delivery.
// Ten minutes is several times the worst case canaryStartBudget plus a grace period allows, and it doubles as
// the bound on a leaked probe: a canary killed between creating its Pods and deleting them leaves two
// CPU-only containers that exit by themselves within ten minutes.
const canaryProbeDurationSec = 600

// harnessTerminationContract renders what this build would actually submit, so the canary probes it.
//
// The row is synthetic and its name and tenant are irrelevant: only the image and the command come out of it,
// and both are functions of the contract and the duration alone.
func harnessTerminationContract() canaryContract {
	row := queuelab.TrainingTraceRow{
		Index: 0, Name: "termination-canary", Tenant: "canary",
		GPUCount: 1, DurationSec: canaryProbeDurationSec,
	}
	honor := queuelab.RenderMLTrainingJobWithContract(row, canaryNamespace, queuelab.HonorsSIGTERM)
	ignore := queuelab.RenderMLTrainingJobWithContract(row, canaryNamespace, queuelab.IgnoresSIGTERM)
	return canaryContract{
		Image:            honor.Spec.Image,
		HonorCommand:     honor.Spec.Command,
		IgnoreCommand:    ignore.Spec.Command,
		ProbeDurationSec: canaryProbeDurationSec,
		GraceSec:         terminationGraceSec,
		HonorExitCode:    honorExitCode,
	}
}

// canaryKey is what the qualification is keyed by: the combination whose change invalidates it.
//
// Every field here is one this program can actually READ, which is not true of everything a key like this
// might want. The two node-side fields come off Status.NodeInfo on the Node the runner already fetches. The
// apiserver's own version is deliberately absent: it is not what delivers a signal to a container — the
// kubelet and the runtime under it are — and reading it would need a discovery client this binary does not
// build. Naming the readable, load-bearing half is worth more than a key with a field in it that is only
// there because it sounded thorough.
//
// The harness's git revision is NOT a field, and that is the one deliberate departure from the obvious. A
// revision changes on every commit, so keying on it would invalidate every recorded qualification whenever a
// comment was reworded, and the operator would be re-running the canary before every run — which is exactly
// the per-run ritual this was designed not to be. What a revision would be standing in FOR is spelled out
// instead: the image, both rendered commands, the grace period and the expected exit code, taken from the
// renderer rather than from constants here, so a harness change to any of them changes a key field.
//
// That is deliberately NOT a claim to cover the whole mechanism, and the first version of this comment made
// that claim and was wrong. The canary hand-builds its probe in canaryPod; a run's Pod is materialised from
// the controller's own Job template (internal/controller/mltrainingjob_controller.go's buildJob). A commit
// adding a preStop hook, shareProcessNamespace, or an explicit terminationGracePeriodSeconds to THAT template
// would change what a run measures while changing no field here, and a recorded qualification would go on
// matching. The decision not to key the revision stands — the alternative is worse, and the exposure is
// narrow and named — but the record does not hide it: recordUnchecked() states this same residual as the one
// thing a qualified run's artifact still cannot speak for, and that entry is the honest version of what this
// key covers.
//
// Two more invalidators are invisible to any key of readable strings, and are worth naming rather than
// leaving to be discovered: a kubelet restarted with different flags, and a container-runtime configuration
// change that bumps no version string. Both leave every field below identical while changing what the
// cluster does with a signal. Re-take the canary after either; nothing here can prompt you to.
//
// The revision is still recorded beside the key (canaryQualification.HarnessRevision) so a reader can see
// which build took the reading; it just is not what the match turns on.
type canaryKey struct {
	Image         string   `json:"image"`
	HonorCommand  []string `json:"honorCommand"`
	IgnoreCommand []string `json:"ignoreCommand"`
	// GraceSec is the grace period the apiserver DEFAULTED onto the probe Pods, not one the canary asked for.
	//
	// That is the fact worth keying on, because nothing in this harness sets a grace period at all: the
	// controller's Job template (internal/controller/mltrainingjob_controller.go) leaves
	// terminationGracePeriodSeconds unset, so every Pod a run creates takes the API default.
	//
	// FOUR separate pieces of arithmetic rest on that default being 30, not one: the observation horizon
	// (spine.go's horizonSec), the trace's remaining-service check and the victim's own row duration
	// (trace.go), and the schedule's minimum owner duration (schedule.go). A cluster defaulting anything else
	// is not running this protocol at all — every one of those four numbers would be sized against a window the
	// workload does not have. judgeCanary refuses any value but terminationGraceSec outright, which is what
	// covers all four rather than the one this comment used to name.
	GraceSec      int64 `json:"graceSec"`
	HonorExitCode int32 `json:"honorExitCode"`
	// NodeUID rather than the node name alone. A node deleted and recreated under the same name is a different
	// machine, the same judgement decideClear makes about a quarantine record; the annotation would normally
	// die with the object, so this catches the remaining route — a qualification copied by hand onto a node it
	// was never taken on.
	NodeUID string `json:"nodeUID"`
	// The two things that actually deliver a signal to a container, in the spelling the Node reports them:
	// "v1.31.0" and "containerd://1.7.18".
	KubeletVersion   string `json:"kubeletVersion"`
	ContainerRuntime string `json:"containerRuntime"`
}

// canaryKeyFor builds the key a run requires of a recorded qualification: this build's mechanism, on this
// node's kubelet and runtime.
//
// GraceSec is the contract's rather than anything read off the node, because on this side of the comparison
// it is a REQUIREMENT: 30 is what spine.go's horizon is built on, and a recorded qualification taken under a
// cluster that defaulted something else must not match, which is precisely what happens when the recorded
// key carries what was observed and this one carries what is needed.
func canaryKeyFor(n *corev1.Node, c canaryContract) canaryKey {
	return canaryKey{
		Image:            c.Image,
		HonorCommand:     c.HonorCommand,
		IgnoreCommand:    c.IgnoreCommand,
		GraceSec:         c.GraceSec,
		HonorExitCode:    c.HonorExitCode,
		NodeUID:          string(n.UID),
		KubeletVersion:   n.Status.NodeInfo.KubeletVersion,
		ContainerRuntime: n.Status.NodeInfo.ContainerRuntimeVersion,
	}
}

// canaryProbe is what one probe Pod did after it was asked to stop.
//
// Both probes are recorded whatever happened, including the one that failed, for the reason the qualification
// block is persisted on the refusal path: a canary that refused is precisely the canary whose evidence would
// otherwise be a sentence on somebody's terminal.
type canaryProbe struct {
	Pod      string   `json:"pod"`
	Contract string   `json:"contract"`
	Command  []string `json:"command"`
	// GraceSec is what the apiserver stored on the Pod, read back out of the Create response rather than out
	// of the request: what a run's Pods get is the default, and the default is what has to be observed.
	GraceSec int64 `json:"graceSec"`
	// Terminated says a terminal container status was actually seen. Everything below it is meaningless
	// without it, which is why the verdict tests this before it tests any number.
	Terminated bool   `json:"terminated"`
	ExitCode   int32  `json:"exitCode"`
	Reason     string `json:"reason,omitempty"`
	// StoppedAfterMs is measured on this program's own clock, from the instant the delete was accepted to the
	// instant a terminal status was first observed. It is deliberately not derived from the kubelet's
	// finishedAt: that field has one-second resolution, which is a third of the promptness threshold below.
	//
	// Being this program's own clock, it is inflated by a read stall — which is exactly why the verdict never
	// rests on it alone. See killExitCode for the two things that close that: the exit code the cluster itself
	// reports, and the fact that a global stall trips the honouring probe's upper bound first.
	StoppedAfterMs int64 `json:"stoppedAfterMs"`
	// Unobserved is why nothing terminal was seen, when nothing was. An empty Terminated with an empty reason
	// would be a probe nobody could tell apart from one that was never run.
	Unobserved string `json:"unobserved,omitempty"`
}

// canaryQualification is the document the worker Node carries: what was probed, on what, and what happened.
//
// It records a FAILED canary as readily as a passing one, and that is a deliberate choice over writing only
// successes. A run refused for "no canary has been recorded" and a run refused for "the canary that ran here
// on Tuesday found this cluster kills instead of signalling" are the same refusal to an operator holding only
// the first, and the second is the one that tells them what to fix. Failures being empty is what makes the
// document a qualification; its presence alone never is.
type canaryQualification struct {
	Schema      int    `json:"schema"`
	CanaryID    string `json:"canaryID"`
	Node        string `json:"node"`
	QualifiedAt string `json:"qualifiedAt"`
	// HarnessRevision is which build took the reading, from the binary's own VCS stamp. It is recorded and not
	// keyed; see canaryKey for that argument. It is honest about being absent — a `go test` binary carries no
	// vcs settings at all, which is measured rather than assumed (see harnessRevision).
	HarnessRevision string      `json:"harnessRevision"`
	Key             canaryKey   `json:"key"`
	Honor           canaryProbe `json:"honor"`
	Ignore          canaryProbe `json:"ignore"`
	// Failures is every claim the probe pair did not establish, empty exactly when the contrast was shown.
	Failures []string `json:"failures,omitempty"`
}

// canaryReference is what the run record carries: which qualification this run stood on.
//
// It carries the key rather than only an id, because an id is a pointer into a cluster the reader may not
// have and very often will not have by the time they read the file. The two measured durations come along for
// the same reason: they are the contrast itself, so a reader can see that the qualification this run rested on
// was a real separation between the arms and not a pair of numbers a threshold happened to admit.
type canaryReference struct {
	CanaryID             string    `json:"canaryID"`
	QualifiedAt          string    `json:"qualifiedAt"`
	Key                  canaryKey `json:"key"`
	HonorStoppedAfterMs  int64     `json:"honorStoppedAfterMs"`
	IgnoreStoppedAfterMs int64     `json:"ignoreStoppedAfterMs"`
}

// canaryRefOf reads the reference through a qualification block that may itself be absent.
//
// Two nils mean different things and the callers all want the same answer from both: no qualification block
// is a run that never inspected its worker, and a block without a reference is one that inspected it and did
// not get past this gate. Neither consulted a canary.
func canaryRefOf(q *qualification) *canaryReference {
	if q == nil {
		return nil
	}
	return q.TerminationCanary
}

func encodeCanary(q canaryQualification) (string, error) {
	b, err := json.Marshal(q)
	if err != nil {
		return "", fmt.Errorf("encode termination canary: %w", err)
	}
	return string(b), nil
}

// decodeCanary refuses anything it does not fully understand, exactly as decodeJournal does and for the same
// reason: this document is what stands between a run and measuring a contrast the cluster cannot produce, so
// a version of it with fields that were silently ignored is not one to proceed from.
//
// The required-field sweep at the end is doing more work here than it looks. Without it the zero
// canaryQualification — `{"schema":1}` — decodes cleanly and carries a zero key, and a zero key compares
// equal to another zero key; a bug that built the expected side out of nothing would then match anything, and
// the check would still be present and would no longer be checking. Every field below is one no real
// qualification can be missing.
func decodeCanary(s string) (canaryQualification, error) {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.DisallowUnknownFields()
	var q canaryQualification
	if err := dec.Decode(&q); err != nil {
		return canaryQualification{}, fmt.Errorf("decode termination canary: %w", err)
	}
	if dec.More() {
		return canaryQualification{}, fmt.Errorf("decode termination canary: trailing data after the document")
	}
	if q.Schema != canarySchema {
		return canaryQualification{}, fmt.Errorf("decode termination canary: schema %d is not %d",
			q.Schema, canarySchema)
	}
	for name, v := range map[string]string{
		"canaryID": q.CanaryID, "node": q.Node, "qualifiedAt": q.QualifiedAt,
		"key.image": q.Key.Image, "key.nodeUID": q.Key.NodeUID,
		"key.kubeletVersion": q.Key.KubeletVersion, "key.containerRuntime": q.Key.ContainerRuntime,
	} {
		if v == "" {
			return canaryQualification{}, fmt.Errorf("decode termination canary: %s is empty", name)
		}
	}
	if len(q.Key.HonorCommand) == 0 || len(q.Key.IgnoreCommand) == 0 {
		return canaryQualification{}, fmt.Errorf(
			"decode termination canary: the key names no command for one of the two contracts, so it cannot say " +
				"which workload was qualified")
	}
	if q.Key.GraceSec < 1 {
		return canaryQualification{}, fmt.Errorf(
			"decode termination canary: the key records a %d second grace period; a workload asked to stop with "+
				"no time in which to do it cannot have demonstrated anything about stopping", q.Key.GraceSec)
	}
	return q, nil
}

// judgeCanary decides whether the pair demonstrated the contrast, and names every claim it did not.
//
// The halves are judged TOGETHER and both are required, which is the entire reason this function takes two
// probes rather than being called twice. A runtime that SIGKILLs every container the moment it is asked passes
// the honouring half — promptly stopped, and 143 is what an untrapped SIGTERM leaves too — and it is exactly
// the runtime that makes A-honor and A-ignore the same experiment. Only the ignoring probe surviving to the
// grace deadline rules it out.
//
// Every failed claim is reported rather than the first, for the reason qualify accumulates its own: they are
// independent facts about one cluster, and an operator who fixes one and meets the next on the following
// attempt has paid two round trips for something describable in one.
func judgeCanary(honor, ignore canaryProbe) []string {
	var failed []string

	// The grace period is checked first because it is the premise of both readings below: the thresholds are
	// fractions of it, and the horizon the whole protocol is timed against assumes it. A cluster that defaults
	// something else has not failed the contrast — it has changed the experiment.
	for _, p := range []canaryProbe{honor, ignore} {
		if p.GraceSec != terminationGraceSec {
			failed = append(failed, fmt.Sprintf(
				"probe %s was stored with a %d second termination grace period, not the %d this protocol's "+
					"horizon is derived from; nothing in this harness sets one, so this is the cluster's own default "+
					"and every Pod a run creates would take it too",
				p.Pod, p.GraceSec, terminationGraceSec))
		}
	}

	switch {
	case !honor.Terminated:
		failed = append(failed, fmt.Sprintf(
			"the honouring probe %s was never observed to stop at all (%s); a workload whose ending nobody saw "+
				"cannot show that this cluster can stop one", honor.Pod, honor.Unobserved))
	default:
		if honor.ExitCode != honorExitCode {
			detail := ""
			if honor.ExitCode == killExitCode {
				// Named specially because it is THE failure this whole file exists to catch, and because an
				// operator reading a bare "wanted 143, got 137" would not necessarily connect it to the arm.
				detail = "; that is the post-grace SIGKILL, so the signal never reached the workload and A-honor " +
					"would behave exactly like A-ignore"
			}
			failed = append(failed, fmt.Sprintf(
				"the honouring probe %s exited %d (%s), not %d%s",
				honor.Pod, honor.ExitCode, honor.Reason, honorExitCode, detail))
		}
		if honor.StoppedAfterMs > canaryPromptWithin.Milliseconds() {
			failed = append(failed, fmt.Sprintf(
				"the honouring probe %s took %dms to stop, past the %s a prompt stop has to land inside; a "+
					"workload that only stops near its grace deadline is not distinguishable from one that ignores "+
					"the request", honor.Pod, honor.StoppedAfterMs, canaryPromptWithin))
		}
	}

	switch {
	case !ignore.Terminated:
		failed = append(failed, fmt.Sprintf(
			"the ignoring probe %s was never observed to stop at all (%s); without its ending there is no "+
				"contrast to compare the honouring one against", ignore.Pod, ignore.Unobserved))
	default:
		if ignore.StoppedAfterMs < canarySurvivesAtLeast.Milliseconds() {
			failed = append(failed, fmt.Sprintf(
				"the ignoring probe %s stopped after %dms, inside the %s it was supposed to outlast; this cluster "+
					"stops a workload that ignores SIGTERM as promptly as one that honours it, so the two arms "+
					"differ in name only and the honouring half of this canary passed for the wrong reason",
				ignore.Pod, ignore.StoppedAfterMs, canarySurvivesAtLeast))
		}
		if ignore.ExitCode != killExitCode {
			failed = append(failed, fmt.Sprintf(
				"the ignoring probe %s exited %d (%s), not the %d of a post-grace SIGKILL; its survival has to be "+
					"something the kubelet had to end, not something inferred from a clock",
				ignore.Pod, ignore.ExitCode, ignore.Reason, killExitCode))
		}
	}
	return failed
}

// canaryKeyMatches decides whether a recorded qualification is the one this run needs, and explains a no.
//
// The EQUALITY is the authority and keyDifferences is only the explanation. That split is what makes a field
// added to canaryKey without a matching line below fail toward the REFUSAL rather than being silently ignored
// — the direction absenceName's default case fails in, and for the same reason: an unrecognised difference is
// a difference, and a comparison that cannot say what changed still knows that something did.
func canaryKeyMatches(want, got canaryKey) (bool, []string) {
	if reflect.DeepEqual(want, got) {
		return true, nil
	}
	diffs := keyDifferences(want, got)
	if len(diffs) == 0 {
		diffs = []string{fmt.Sprintf(
			"%s (recorded %+v, needed %+v); a field was added to the key without a line that names it",
			unnamedKeyDifference, got, want)}
	}
	return false, diffs
}

// unnamedKeyDifference prefixes the fallback above.
//
// It is a constant so a test can tell the two outcomes apart, which is the whole difficulty with a safety net
// of this shape: the net makes the refusal correct for a field nobody named, and by doing so it also makes
// "nobody named it" invisible. TestEveryFieldOfTheKeyCanRefuseOnItsOwn asserts no field of today's key
// reaches it, so the net stays a net rather than becoming where the diagnosis quietly goes.
const unnamedKeyDifference = "the recorded key is not this run's and this build cannot say which field differs"

// keyDifferences names every field on which a recorded qualification is not the one this run needs.
//
// Field by field rather than "the key does not match", because the whole value of a refusal here is telling
// an operator whether they are looking at a re-imaged node, a bumped sleeper digest or a cluster upgrade —
// three completely different next steps that a single mismatched-digest sentence would collapse into one.
func keyDifferences(want, got canaryKey) []string {
	var diffs []string
	str := func(field, w, g string) {
		if w != g {
			diffs = append(diffs, fmt.Sprintf("%s: this run needs %q, the recorded qualification was taken on %q",
				field, w, g))
		}
	}
	str("image", want.Image, got.Image)
	str("honoring command", strings.Join(want.HonorCommand, " "), strings.Join(got.HonorCommand, " "))
	str("ignoring command", strings.Join(want.IgnoreCommand, " "), strings.Join(got.IgnoreCommand, " "))
	str("node UID", want.NodeUID, got.NodeUID)
	str("kubelet version", want.KubeletVersion, got.KubeletVersion)
	str("container runtime", want.ContainerRuntime, got.ContainerRuntime)
	if want.GraceSec != got.GraceSec {
		diffs = append(diffs, fmt.Sprintf(
			"termination grace period: this run's timing is derived from %ds, the recorded qualification was "+
				"taken under a cluster that defaulted %ds", want.GraceSec, got.GraceSec))
	}
	if want.HonorExitCode != got.HonorExitCode {
		diffs = append(diffs, fmt.Sprintf(
			"expected exit code: this run's honouring workload exits %d, the recorded qualification looked for %d",
			want.HonorExitCode, got.HonorExitCode))
	}
	return diffs
}

// checkTerminationCanary is the consult: it reads the worker's recorded qualification and decides whether
// this run may stand on it.
//
// It takes the Node the caller already holds rather than fetching one, so the qualification is read off the
// same version of the object every other environment check was decided from — and so this costs no round trip
// at all on the path where it passes.
//
// Every refusal below names what was expected and what was found, and every one of them ends the run before
// it creates anything, which is the shape the capacity gate established.
func checkTerminationCanary(n *corev1.Node, c canaryContract) (*canaryReference, error) {
	raw := n.Annotations[canaryAnnotationKey]
	if raw == "" {
		return nil, fmt.Errorf(
			"no termination canary has been recorded for it, so nothing has established that this cluster can "+
				"actually stop a Pod that is asked to — which is the entire mechanism the arms differ by. Run:\n"+
				"    queuelabrun -termination-canary -worker %s", n.Name)
	}
	q, err := decodeCanary(raw)
	if err != nil {
		// The annotation is quoted for the reason residueNote quotes everything it decodes: it came out of the
		// cluster, and this sentence is printed to a terminal beside a command the operator is invited to run.
		return nil, fmt.Errorf(
			"its recorded termination canary could not be read (%v); found %q. A qualification this tool cannot "+
				"read is not one a run may stand on. Re-take it:\n    queuelabrun -termination-canary -worker %s",
			err, raw, n.Name)
	}
	// The KEY is tested before the recorded failures, and the order is the whole of the difference between two
	// refusals an operator reads completely differently. A canary that failed on a combination this run does
	// not use — a bumped image digest, a kubelet since upgraded — says nothing whatever about this run: the
	// truth is "that reading is about a different machine", not "this cluster cannot stop a Pod". Tested the
	// other way round, that stale document produced the most alarming sentence this file can print, and it was
	// also the one branch that offered no way forward.
	want := canaryKeyFor(n, c)
	if matched, diffs := canaryKeyMatches(want, q.Key); !matched {
		var b strings.Builder
		fmt.Fprintf(&b, "its termination canary was taken on a different combination than this run needs "+
			"(recorded at %q, id %q):", q.QualifiedAt, q.CanaryID)
		for _, d := range diffs {
			fmt.Fprintf(&b, "\n    %s", d)
		}
		fmt.Fprintf(&b, "\n  a qualification is a property of one combination of workload, cluster, runtime and "+
			"harness, and says nothing about another. Re-take it:\n"+
			"    queuelabrun -termination-canary -worker %s", n.Name)
		return nil, fmt.Errorf("%s", b.String())
	}
	// Reached only once the key is this run's, so what follows is a statement about the combination this run
	// is actually about to measure on.
	if len(q.Failures) > 0 {
		var b strings.Builder
		fmt.Fprintf(&b, "the termination canary recorded on it at %q (id %q) FAILED on this run's own "+
			"combination, so this cluster has been shown not to produce the contrast the arms are built on:",
			q.QualifiedAt, q.CanaryID)
		for _, f := range q.Failures {
			fmt.Fprintf(&b, "\n    %s", f)
		}
		// A command is offered here too, unlike the first version of this branch. It is not the fix — a cluster
		// that cannot stop a Pod is not fixed by measuring it again — but it is what an operator runs to confirm
		// they have fixed it, and a branch with no next step at all reads as a dead end.
		fmt.Fprintf(&b, "\n  fix the cluster, then re-take the reading:\n"+
			"    queuelabrun -termination-canary -worker %s", n.Name)
		return nil, fmt.Errorf("%s", b.String())
	}
	return &canaryReference{
		CanaryID:             q.CanaryID,
		QualifiedAt:          q.QualifiedAt,
		Key:                  q.Key,
		HonorStoppedAfterMs:  q.Honor.StoppedAfterMs,
		IgnoreStoppedAfterMs: q.Ignore.StoppedAfterMs,
	}, nil
}

// unstampedRevision is what the harness revision reads as when the binary carries no VCS stamp.
//
// It is a sentence rather than an empty string because this value is written into a document somebody reads
// later, and "" there is indistinguishable from a writer that forgot the field.
const unstampedRevision = "(no vcs stamp in this binary)"

// harnessRevision is the build's own git revision, when it has one.
//
// It genuinely is often absent, which is measured rather than assumed: a binary from `go build ./cmd/...`
// carries vcs.revision and vcs.modified, and a `go test` binary carries neither — debug.ReadBuildInfo still
// returns ok, with no vcs settings at all. That asymmetry is the practical reason this value is recorded and
// not keyed: half the ways this code is exercised could not produce a key that matched.
func harnessRevision() string {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return unstampedRevision
	}
	var rev, modified string
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value
		case "vcs.modified":
			modified = s.Value
		}
	}
	if rev == "" {
		return unstampedRevision
	}
	if modified == "true" {
		// A dirty tree is worth saying out loud: the revision alone would name a commit whose contents are not
		// what took the reading.
		return rev + "+dirty"
	}
	return rev
}

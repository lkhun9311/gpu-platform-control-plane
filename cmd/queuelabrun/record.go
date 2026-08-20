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
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// recordSchemaVersion is refused by any reader that does not know it.
//
// An unknown version must not be read under today's rules: the whole point of the record is that a later
// reader can tell what a run actually established, and silently applying current semantics to a document
// written under different ones is the failure this package exists to prevent.
//
// Version 2 adds the qualification block's `requiredBoundBy`, and the bump is there for one direction of the
// asymmetry only. A version-2 record read by a version-1 build already fails loudly — DisallowUnknownFields
// refuses the field it has never heard of — so nothing needed to be added for that. The dangerous direction
// is the other one: a version-1 record, and at least one exists from a real cluster run, decodes into today's
// struct WITHOUT COMPLAINT, leaving RequiredBoundBy at "" — a value that is neither documented constant and
// that a reader classifying on it would take as a third, unnamed kind of bound. That is precisely the
// silent reinterpretation the paragraph above says this constant exists to stop, so the version is what
// separates the two shapes rather than the absence of a field nobody can distinguish from a bound of "".
//
// Version 3 adds the ownership window, and the asymmetry is the same one again. An absent window means a run
// that never opened one — refused before it acquired, or refused at qualification — which is a real and
// ordinary state; so a version-2 record, written by a build that could not open a window at all, decodes
// into today's struct as a run that got no further than acquisition, and a reader asking "did this run prove
// its worker stayed its own" would be told "it never got that far" about a run that was never able to ask.
// The version is what separates those two, because nothing in the document itself can.
//
// Version 4 adds the observation block and the validity verdict, and the asymmetry is the same one a third
// time. A version-3 record decodes into today's struct without complaint, leaving Observation nil and
// Validity at its zero value — and both of those zeros are readable as claims nobody made. A nil observation
// says "this run never opened its streams", which is a real state (a run refused before the collector was
// built), so a record written by a build that could not record streams at all would be read as a run that
// never observed anything. And a blank verdict is the more dangerous half: the whole reason the verdict is a
// field is that a reader classifies on it without parsing prose, so a document decoding into a verdict that
// is neither documented name gives that reader a value to classify on that means nothing at all.
//
// Version 5 adds the qualification block's `terminationCanary`, and the asymmetry is the same one a fourth
// time — sharper here than in any of the three above, because of what the absent field means. A version-4
// record decodes into today's struct with TerminationCanary nil, and nil is not a spare slot: it is exactly
// what THIS build writes for a run it refused because nothing had established that the worker can stop a Pod
// that is asked to. So every record every earlier build wrote — including the ones whose runs were fine,
// since no earlier build could take that reading at all — would read as a run that faced that gate and did
// not get past it. The version is what separates "was refused for it" from "could not ask", and nothing in
// the document itself can.
//
// Version 6 adds `podTemplateHash` to the key inside that reference, and this one's argument is weaker than
// the four above it, which is worth writing down rather than dressing up. A version-5 record that carries a
// reference is refused with or without the bump, because the reference guard below stops an empty hash on its
// own. What the version adds is the same thing it adds to the canary document: the DIAGNOSIS. Without it the
// refusal an operator meets says the reference identifies nothing, which reads as a corrupted or hand-edited
// file, when what they are holding is a perfectly good record from a build in which the operator's Pod
// template was not yet part of what a reading covered. The version is the only thing in either document that
// can tell those apart.
// Version 12 adds `resolvedToNs` to the resolution block, and its asymmetry is the sharpest in this list
// because of which direction the missing value fails in. A version-11 record decodes into today's struct
// with ResolvedToNs at zero, and zero on this field is not a spare slot or an absent reading: it is the
// STRONGEST claim the field can carry, "this run distinguished differences down to nothing". Every earlier
// record would therefore assert, silently and in the one field a consumer is meant to act on, the exact
// property those runs did not have — and they are the very records whose sub-second residual was published
// as a measurement. The four blocks above bump the version to stop an absent field reading as a claim
// nobody made; this one bumps it to stop an absent field reading as the claim that was already made wrongly
// once.
// Version 13 adds validity.deviceEvidence, and its asymmetry is not about a zero value that reads as a
// claim -- it is about a question the document could not be ASKED. A version-12 record decodes with a blank
// axis, and blank is refused, so the bump buys the diagnosis rather than the refusal: an operator holding an
// older file is told they have a record from a build in which nothing could distinguish a device that did
// work from one that was held, rather than being told their file is corrupt. Every record this lab has
// produced is in exactly that state, which is why the message matters more here than the guard.
const recordSchemaVersion = 13

// runRecord is what a non-preview invocation leaves behind.
//
// It made no experimental claim when it was first written — an invocation happened, this is the disposition
// it reached, here are the raw events — and the environment, the restoration audit and the verdict were named
// as later pieces that would add their own fields rather than be reserved here. All three have since landed
// as Qualification, Window and Validity, which is why this type is now the thing a reader can judge a run
// from. The fixtures are the one item on that old list still absent, and no field is reserved for them here
// either — the same rule as before, that a block appears when something writes it.
type runRecord struct {
	SchemaVersion int `json:"schemaVersion"`
	// The bump to 8 adds the measurement block below. Until it, the record carried the ledger and nothing
	// derived from it, so the numbers a run reported existed only on a terminal — and one of them, the waste,
	// is sometimes a LOWER BOUND rather than a value. A reader quoting it out of an older document had nothing
	// in the file telling them which of the two they were holding.
	//
	// The bump to 7 carried two changes, and both are about a record being unable to say what it observed:
	// Dose below, and the exit code the ledger's AttemptStopped events now carry. A document from before it is
	// refused rather than read, because in both cases the silence would be taken for the ordinary case — the
	// default regime, and a stop whose kind nobody could tell.
	//
	// Dose names which side of the termination grace period this run's victim was preempted on, and it is
	// persisted because the two regimes measure different quantities: self-completing reports what the
	// victim's remaining WORK costs the owner, grace-bounded reports what the platform's configured PATIENCE
	// costs it. Two records without this field are indistinguishable while describing different experiments,
	// so a reader comparing them would be comparing numbers that never answered the same question.
	Dose string `json:"dose"`
	// Measurement is absent when the run produced no reconstruction, which is every refused run: a block of
	// zeroes would read as a run that measured nothing rather than one that never got to measure.
	Measurement *measurement `json:"measurement,omitempty"`
	// Preview has no writer on purpose, and is NOT a reserved slot like the Flags field deleted before it: it
	// exists for decodeRunRecord, so that a preview document fed to a run-record reader is rejected by the
	// specific check below rather than by a generic unknown-field error that says nothing about why. Deleting
	// it would silently weaken that message, so it stays despite buildRecord never setting it.
	//
	// It buys only that message: a hand-written {"schemaVersion":1,"preview":true,"runID":"x",
	// "disposition":"y"} with no events still decodes as a valid RUN record, because the check that fires is
	// about carrying events, not about the flag.
	Preview     bool   `json:"preview,omitempty"`
	RunID       string `json:"runID"`
	Arm         string `json:"arm"`
	StartedAt   string `json:"startedAt,omitempty"`
	EndedAt     string `json:"endedAt,omitempty"`
	Disposition string `json:"disposition"`
	Reason      string `json:"reason,omitempty"`
	// Events is the ledger. It is present whenever a collector ran.
	Events []queuelab.LifecycleEvent `json:"events,omitempty"`
	// Residue is what this run's teardown could not prove gone. Empty is the ordinary case and says nothing;
	// a non-empty one is the fact the next run has to refuse to start on.
	Residue []recordResidue `json:"residue,omitempty"`
	// Qualification is what the run observed about its worker before it created anything on it.
	//
	// It is a pointer, and absent means the run never got that far — a refused acquisition, a failed connect —
	// rather than a worker that qualified. A struct value would write a zero qualification for those runs,
	// claiming a node named "" advertising no devices was inspected and found fine, which is the one thing a
	// record must never do.
	Qualification *qualification `json:"qualification,omitempty"`
	// Window is what the run observed about its exclusive hold between acquisition and release.
	//
	// It is a pointer for the same reason Qualification is, and the nil case says the same kind of thing: the
	// run never opened a window, because it was refused before or at the point where one could be opened. A
	// struct value would write a window that observed nothing over a node named "" and claim the hold held.
	Window *ownershipWindow `json:"window,omitempty"`
	// Observation is what the run's own continuous view of its namespace was: what each stream's baseline
	// established, how long every stream took to attach, and how each of them ended.
	//
	// It is a pointer for the reason the two blocks above are, and nil says the same kind of thing: the run
	// never built a collector, because it was refused before it got that far. A struct value would write an
	// observation of a namespace named "" that established nothing, which reads as a truncated run rather than
	// as a run that never began observing — the exact confusion this block exists to remove.
	Observation *observationEvidence `json:"observation,omitempty"`
	// Validity is this record's verdict on itself, derived from the fields above.
	//
	// It is a value rather than a pointer, and that is deliberate: every record can be judged, including one
	// for an invocation refused before it reached a cluster, because "this document supports none of the
	// claims" is itself the answer. An absent block therefore decodes to a blank verdict, which decodeRunRecord
	// refuses — there is no run for which the honest answer is "no verdict was taken".
	Validity validity `json:"validity"`
}

// The verdicts a record can carry. They are constants for the same reason the dispositions are: the record
// persists one and a reader classifies on it, so a reworded string would silently become a different verdict.
const (
	// verdictAdmissible names what this build can actually establish, and deliberately not "valid" — for
	// dispChecksPassed's reason, and it carries recordUnchecked alongside so the gap is in the document rather
	// than in the reader's memory.
	//
	// It became WRITABLE when gateRefusal came off, and the order of those two events is the point. The verdict
	// existed, derived and tested, through every build that refused to run: deciding what "admissible" means in
	// the same change that starts publishing under it is how a definition gets shaped to fit the first run that
	// wants to pass. So no invocation before that change could write this value, and none since needs a new
	// rule to.
	verdictAdmissible = "admissible-under-implemented-gates"
	// verdictRefused is a record whose own fields do not support one of the claims below. It always names at
	// least one of them; a refusal that names nothing would tell a reader less than the disposition already
	// does.
	verdictRefused = "refused"
	// verdictPreview is separate from refused because a preview is not a run that failed a gate: it is a run
	// whose gate was waived on purpose, and its record must be readable as neither a pass nor a failure of
	// gates it never faced.
	verdictPreview = "preview-not-evidence"
)

// The device-evidence axis. It is SEPARATE from the verdict above, and the separation is the whole point.
//
// validity exists because a reader classifies on a field instead of parsing prose. Device use broke that
// promise: the fact that nothing here can tell a used device from a reserved one lived in
// unimplementedGates as a paragraph of English, so a consumer reading verdict saw
// "admissible-under-implemented-gates" and had no machine-readable way to learn that the GPU-seconds beside
// it are seconds of RESERVATION. Every record this lab has produced says exactly that, and the verdict on
// every one of them reads the same as a record from a run on real hardware would.
//
// That is the defect a GPU stage cannot survive. The entire reason to spend money on a device is to move
// this axis, and a harness where moving it changes no field a consumer classifies on cannot tell anyone
// whether the money bought anything. So the axis is derived, it is refused when blank, and today it reads
// device-not-observed on every record — which is the correct answer, stated in a form that can change.
const (
	// deviceWorkObserved means something in the run established that the device did work, as opposed to
	// having been held. No build has yet written it, and the constant exists so that the axis has a value to
	// move TO rather than as a slot for a future writer: without it the not-observed case is a boolean
	// dressed as a string.
	deviceWorkObserved = "device-work-observed"
	// deviceNotObserved means the run establishes reservation and nothing about computation. It is the
	// honest reading of every record this lab has produced.
	deviceNotObserved = "device-not-observed"
)

// The claims a record can fail to support, each named after the claim rather than after its cause.
//
// The naming is what makes them usable on refusals as well as passes. "environment-not-established" is true
// both of a run that inspected its worker and found a foreign GPU Pod and of a run that never got far enough
// to look, and those two are the same fact from the record's point of view: it does not carry evidence for
// that claim. A vocabulary of causes would need a second name for every "we never looked", and a reader would
// have to know which of the two they were holding before they could tell what was established.
const (
	failureRunIncomplete = "run-did-not-complete"
	failureObservation   = "observation-not-continuous"
	failureEnvironment   = "environment-not-established"
	failureExclusivity   = "worker-not-exclusive-for-the-whole-window"
	failureContainment   = "cluster-not-left-as-this-run-found-it"
)

// recordUnchecked is what a record cannot speak for, and the rule governing it is that every entry must be
// verifiable in the code of the build that wrote the document.
//
// That rule reads as obvious and was learned the hard way, so the incident stays written down. This block
// once carried the executable's own list of work still to do — the roadmap the refusal that used to stand in
// spine.go printed for an operator — on a DRY argument that inverts here. A roadmap shown once on a terminal
// may be over-broad at no cost: an item still named after the work lands only delays the moment somebody
// narrows it. This list is a DURABLE STATEMENT about the document it sits in, read by someone who was not
// there and has only the file, and an over-broad entry there is not conservative, it is false.
//
// The live artifact is what settled it. A record carrying an observation block, a qualification, a window and
// a derived verdict was written while asserting, inside itself, that this build had no "synchronized
// list+watch with resourceVersion continuity" and no "validity-bearing run artifact". The first named the
// very block printed beside it; the second named the block making the assertion. A reader following that list
// would have discounted exactly the evidence the record was built to carry.
//
// The roadmap is gone now — every gate it named exists — and its removal is precisely why the rule has to be
// stated here as a rule rather than as a contrast with something a reader could go and look at. The next
// person tempted to widen this list "to be safe" has no other place to find out that safety runs the other
// way in a durable document.
//
// So one entry, and only what is verifiable from the code.
//
// It used to say that nothing in this build checked that the worker can actually terminate a Pod, and that
// entry is GONE rather than reworded, because it is no longer true: qualify now refuses a worker whose
// recorded termination canary is absent, failed, or was taken on a different combination, and no run reaches
// a measurement without one. Leaving it would have been the mirror image of the defect that produced this
// list — a durable statement about the document it sits in, false about the build that wrote it — and a
// reader following it would discount the very gate that qualified the run.
//
// What replaces it is the residual that gate genuinely does not close, stated as narrowly as the code
// supports. The canary probes a Pod IT creates: the same image and the same rendered command as the arm, on
// the same node, under the grace period that node's apiserver defaults. A run's Pods reach the kubelet by a
// different route — MLTrainingJob, admitted by Kueue, rendered into a Job by this repository's own controller.
//
// That entry has NARROWED twice since, and the second time is the one that changed what is probed rather than
// what is keyed. The key carries a fingerprint of the Pod template the controller renders (canaryKey's
// PodTemplateHash), so the controller cannot change it without invalidating every reading taken before the
// change; and the probe Pod is now BUILT FROM that same rendered template, so the re-take a mismatch forces
// actually exercises what changed. The first alone would have been detection with hollow remediation — the
// mismatch fires, the operator re-takes, and the fresh reading is of a Pod without the change in it.
//
// What is left is the reconcile loop and the Job controller, which is a narrower thing than "the CRD path".
// Nothing here submits an MLTrainingJob, so nothing exercises the reconciler that renders it, Kueue's
// admission, or the Job controller that creates the Pod — this tool creates the Pod itself, so it carries no
// owner reference, none of the labels a Job stamps on its Pods, and no restart of a failed Pod. And the
// template is still keyed and probed as THIS BINARY renders it, which is not a statement about the operator
// image running on the cluster.
//
// Saying "the CRD path is not exercised" would now understate what the reading covers, and saying the path is
// covered would be the overclaim this list was written after. The entry says which of the two it is.
//
// It is a function rather than a package-level slice because a slice would be mutable from anywhere, and a
// caller that appended to what it was handed would edit what every later record claims about itself.
func recordUnchecked() []string {
	return []string{
		"termination canary coverage: the recorded canary probes a Pod built from the very template this " +
			"build's operator would render, carrying the arm's own image and command and no device request, and " +
			"the key it is matched on fingerprints that template, so a change to it both refuses the reading and " +
			"is exercised by the re-take; what is still not travelled is the operator's reconcile loop and the " +
			"Job controller — nothing here submits an MLTrainingJob, so Kueue admits nothing and no Job creates " +
			"the Pod, which therefore carries no owner reference and none of the labels a Job stamps on its " +
			"Pods — and the template is rendered by THIS BINARY, not by the operator image running on the cluster",
		"device use: nothing in this build can establish that a GPU was USED rather than reserved. The " +
			"workload in internal/queuelab/submit.go is pure Python float arithmetic making no driver call, and " +
			"the cluster advertises nvidia.com/gpu through a fake device plugin, so a Pod that dropped the " +
			"resource request entirely would compute exactly the same iterations at exactly the same rate. " +
			"measurement.discardedIterations therefore counts CPU work performed by a Pod HOLDING a reservation, " +
			"and measurement.workload states the same thing beside the number; neither is discarded GPU " +
			"computation. This entry is no longer the only place that fact lives, and that is the point of " +
			"validity.deviceEvidence: a consumer reads the axis instead of this paragraph, and the axis is the " +
			"field a run on real hardware would move",
	}
}

// validity states, once and in the record, what the evidence beside it supports.
//
// It exists because the alternative is every consumer re-deriving it, and the re-derivation people actually
// perform is reading `disposition` and then parsing `reason`. That is not merely inconvenient, it is wrong on
// a case this package has already met: when a collector stream desyncs AND the ownership window is violated,
// both land on collector-desync — deliberately, because builder.Err() is the one thing that decides whether a
// number may exist — and LedgerBuilder.Desync keeps only the FIRST reason it was given. The exclusivity
// failure then survives nowhere in the prose, only as window.violationsObserved > 0. A verdict parsed from
// `reason` misses it; a verdict derived from the fields cannot.
// measurement is what the run's reconstruction produced, persisted beside the ledger it came from.
//
// It sits with observation, window and qualification as EVIDENCE rather than inside validity, and that
// placement is the argument. checkValidity re-derives the verdict from the document's own fields; a censoring
// flag put in there would be a claim the decoder cannot reproduce, because reproducing it means rebuilding
// the trace from the arm and dose, replaying the ledger and re-running the reconstruction. Evidence blocks
// are not re-derived, they are what a verdict is derived FROM, and this is one.
//
// HorizonNs is here for the same reason: without it a reader holding the events cannot replay them to the
// same boundary, so nothing in the file could be recomputed even in principle.
type measurement struct {
	// HorizonNs is the observation boundary the reconstruction charged against, as an offset from t0.
	HorizonNs int64 `json:"horizonNs"`
	// WastedGPUSeconds is the discarded work attributable to reclamation.
	WastedGPUSeconds float64 `json:"wastedGPUSeconds"`
	// WasteLowerBoundGPUSeconds is what the run can prove was discarded. It equals WastedGPUSeconds unless
	// Censored, and the two are carried separately so a reader never has to infer which they hold.
	WasteLowerBoundGPUSeconds float64 `json:"wasteLowerBoundGPUSeconds"`
	// Censored says an attempt's stop was observed BEYOND the horizon, so its interval is truncated and the
	// waste above is a floor rather than a measurement.
	//
	// It is expected to become ordinary on slower clusters — a longer image pull pushes every stop later —
	// which is exactly why the record has to say it. The printed result already did; the durable artifact did
	// not, and the artifact is what outlives the terminal.
	Censored bool `json:"censored,omitempty"`
	// UnfinishedAtHorizon is the count still pending or running when the window closed.
	UnfinishedAtHorizon int `json:"unfinishedAtHorizon"`
	// DiscardedIterations is the work the run threw away, summed over attempts that stopped without their row
	// completing, and it is what gives the waste figure a denominator.
	//
	// GPU-seconds say how long a device was held; iterations say what was lost. A run whose workload computed
	// nothing reports zero here beside a large waste figure, which is the state that used to be
	// indistinguishable from a saturated card.
	//
	// It counts CPU iterations, NOT device work, and Workload below is what says so in the record rather than
	// only in a source comment. Reading it as discarded GPU computation is the one misreading this field
	// invites, and it is not a small one: the number would then describe hardware that was never touched.
	//
	// A pointer, because "no attempt carried a count" is a different fact from "nothing was discarded": the
	// first happens when the terminated status could not be read, the second when the run genuinely lost no
	// work.
	DiscardedIterations *int `json:"discardedIterations,omitempty"`
	// Workload states what the counted work actually was, and travels beside the count so the two cannot be
	// separated by anyone reading the record.
	Workload workloadProvenance `json:"workload"`
	// Resolution is how far this harness's own observations lag the events they describe.
	//
	// It sits in the measurement block rather than beside the ledger because it qualifies every number here:
	// each interval is a difference of ARRIVAL times, so it carries the lag of both its endpoints. A waste
	// figure of 40.99 against a 40s dose says something quite different depending on whether the harness sees
	// events 30ms or 900ms late.
	Resolution *observationResolution `json:"resolution,omitempty"`
}

// observationResolution bounds how finely the intervals in this record can be read.
//
// It is the spread between the kubelet's stamp for a stop and this collector's arrival time for it, and it
// is a BOUND rather than a correction. The two times come from unsynchronised clocks on different machines
// and the kubelet's is truncated to the second, so the gap mixes propagation, clock offset and truncation
// with no way here to separate them. What it supports is one statement: an interval is not resolved below
// this spread. It does not support "the watch is N milliseconds late".
type observationResolution struct {
	// Samples is how many stop events carried a kubelet timestamp to compare against.
	Samples int `json:"samples"`
	// MinNs, MedianNs and MaxNs describe the observed lag.
	MinNs    int64 `json:"minNs"`
	MedianNs int64 `json:"medianNs"`
	MaxNs    int64 `json:"maxNs"`
	// QuantisationNs is the granularity of the kubelet's own field.
	//
	// metav1.Time serialises to RFC3339 with SECOND precision, so finishedAt arrives with its nanoseconds
	// zeroed — checked, not assumed: every observed value ends in nine zeros. Each figure below therefore
	// carries up to a second of truncation on top of everything else, which is why they bound rather than
	// measure.
	QuantisationNs int64 `json:"quantisationNs"`
	// ResolvedToNs is the magnitude below which this run distinguished nothing, and it is the field a
	// consumer is meant to act on. The three figures above describe the skew; this one says what follows
	// from it.
	//
	// It is derived from the spread rather than from MedianNs because every interval in this record is a
	// difference of ARRIVAL times, so a constant lag cancels and only the DIFFERENCE between two endpoints'
	// lags survives into the number. queuelab.ObservationSpread carries the derivation and the argument for
	// the quantisation floor sitting under it.
	ResolvedToNs int64 `json:"resolvedToNs"`
	// Note names what the reader must not do with the intervals in this record.
	Note string `json:"note"`
}

// resolutionOf projects the reconstruction's own spread into the record's shape.
//
// It derives NOTHING itself, and that is deliberate. This block and the floor the report prints have to
// agree, and the way two such numbers stop agreeing is by being computed twice from the same inputs by two
// pieces of code that drift apart. queuelab.SpreadOf is the one derivation; this function is a projection
// of it, so a change to the rule reaches the terminal output and the durable artifact together.
//
// nil is the honest answer rather than a zero: "no stop reported a kubelet timestamp" and "this harness is
// perfectly prompt" are different states, and only one of them is good news.
func resolutionOf(events []queuelab.LifecycleEvent) *observationResolution {
	s := queuelab.SpreadOf(events)
	if s == nil {
		return nil
	}
	return &observationResolution{
		Samples:        s.Samples,
		QuantisationNs: s.QuantisationNs,
		MinNs:          s.MinNs,
		MedianNs:       s.MedianNs,
		MaxNs:          s.MaxNs,
		ResolvedToNs:   s.FloorNs,
		Note: "resolvedToNs is the operative figure: a difference smaller than it is not resolved by this " +
			"run, and no number of repetitions changes that because a resolution limit is not a noise " +
			"level. The skew figures it comes from are a bound, not a delivery time -- they mix propagation, " +
			"the offset between two unsynchronised clocks and one-second truncation, and nothing here " +
			"separates them. Every interval in this record is a difference of ARRIVAL times",
	}
}

// workloadProvenance records what produced the iteration counts, so a reader cannot take them for device
// work without contradicting the record itself.
//
// The workload is pure Python arithmetic on a cluster whose nvidia.com/gpu capacity is advertised by a fake
// device plugin. There is no kernel, no driver call, and nothing that would fail if the resource request were
// dropped — so an iteration is CPU work performed by a Pod that HELD a GPU reservation, which is a different
// claim from work the GPU did.
//
// The distinction survives into the GPU stage rather than becoming moot: there, DeviceUseEstablished only
// becomes true once something outside the workload's own report says the device was used. Until then the
// field reads false and the reason says why, which is what stops "iterations" from quietly graduating into
// "GPU-seconds of computation" when the hardware arrives.
type workloadProvenance struct {
	// Kind is what the inner loop computes.
	Kind string `json:"kind"`
	// CountedUnit names what one iteration is, in the terms the workload itself uses.
	CountedUnit string `json:"countedUnit"`
	// DeviceUseEstablished is whether anything in this run showed the GPU was USED rather than reserved.
	DeviceUseEstablished bool `json:"deviceUseEstablished"`
	// WhyNot is the reason DeviceUseEstablished is false, and is empty when it is true.
	WhyNot string `json:"whyNot,omitempty"`
}

// cpuOnlyWorkload is the provenance every run on this cluster carries.
//
// It is a constructor rather than a literal at the call site so that a build which gains a real kernel has
// one place to change, and so that no run can be assembled without stating this at all.
func cpuOnlyWorkload() workloadProvenance {
	return workloadProvenance{
		Kind:                 "pure-python-float-arithmetic",
		CountedUnit:          "50000 float multiply-modulo operations",
		DeviceUseEstablished: false,
		WhyNot: "the cluster advertises nvidia.com/gpu through a fake device plugin and the workload makes no " +
			"driver call, so nothing here can distinguish a device that was used from one that was only reserved",
	}
}

type validity struct {
	Verdict string `json:"verdict"`
	// Failures is every claim this record does not support, in a fixed order so two records of the same shape
	// compare equal.
	Failures []string `json:"failures,omitempty"`
	// UnimplementedGates is what this build cannot check AT ALL, carried so that verdictAdmissible cannot be
	// read as more than it says.
	//
	// Its only source is recordUnchecked, whose comment gives the rule: every entry must be verifiable in the
	// code of the build that wrote this document, because a reader holding the file has nothing else to check
	// it against. The field NAME predates that rule and is kept because it is on the wire — renaming it is a
	// schema change, and it still fits what it holds, since a check this build cannot perform and a gate it has
	// not implemented are the same thing described from the two ends.
	UnimplementedGates []string `json:"unimplementedGates,omitempty"`
	// DeviceEvidence says whether this run established that a GPU did WORK, and it is deliberately not part
	// of Verdict. A run can be fully admissible -- exclusive worker, qualified environment, continuous
	// observation, contained teardown -- and still say nothing whatever about a device, which is the state
	// every record here is in. Folding the two together would force a choice between refusing every run this
	// lab has ever taken and letting an admissible verdict imply hardware it never touched.
	DeviceEvidence string `json:"deviceEvidence"`
}

// deriveValidity reads the fields the record persists and nothing else.
//
// Every input below is a field of the document being built, which is what makes the verdict reproducible by
// anyone holding the file: a reader who disagrees can re-derive it from the same JSON. Nothing here reads
// o.Reason, and nothing may: that string is the human's account of whichever failure came first.
func deriveValidity(o outcome, left []recordResidue, qual *qualification, win *ownershipWindow,
	obs *observationEvidence, m *measurement, preview bool) validity {
	v := validity{
		Verdict:            verdictAdmissible,
		UnimplementedGates: recordUnchecked(),
		DeviceEvidence:     deviceEvidenceOf(m),
	}
	// The disposition is a claim of its own rather than a summary of the four below it. A run can hold its
	// worker, qualify it, observe continuously and still be cancelled at the horizon, and a record that only
	// listed gate failures would call that one admissible.
	if o.Disposition != dispChecksPassed {
		v.Failures = append(v.Failures, failureRunIncomplete)
	}
	if !observationContinuous(obs) {
		v.Failures = append(v.Failures, failureObservation)
	}
	if !environmentEstablished(qual) {
		v.Failures = append(v.Failures, failureEnvironment)
	}
	if !exclusivityHeld(win) {
		v.Failures = append(v.Failures, failureExclusivity)
	}
	if !clusterRestored(left, win) {
		v.Failures = append(v.Failures, failureContainment)
	}
	if len(v.Failures) > 0 {
		v.Verdict = verdictRefused
	}
	// Last and unconditional, and it is the ONLY thing -preview now decides anywhere in this program: an
	// invocation its author declared a smoke check must not be readable as an admissible run however well every
	// other field came out. Being last is what makes that hold — a preview against a flawless cluster derives
	// verdictAdmissible in the lines above, and this line is what refuses to publish it under that name. The
	// failures are kept beside it rather than dropped, because a preview is also the mode an operator uses to
	// find out what is wrong with a cluster.
	if preview {
		v.Verdict = verdictPreview
	}
	return v
}

// deviceEvidenceOf reads the axis off the workload provenance, and can only ever narrow it.
//
// It takes the measurement rather than the bool so that the absent case is decided here rather than at each
// call site: a run with no measurement observed no device, and that is the same answer as a run whose
// workload made no driver call. Both are device-not-observed, and neither may be silent -- a blank axis is
// refused on decode for the reason a blank verdict is.
//
// The one direction this must never go is the generous one. A workload that reports its own device use is
// not evidence of it, in the same way that a Pod carrying a quota-exempt annotation is not evidence that it
// may bypass quota: both are claims made by the party the check exists to constrain. When a writer for
// deviceWorkObserved arrives it has to be an observer the workload cannot write to, and this comment is
// where that requirement is recorded so the next person does not wire the workload's own stdout into it.
func deviceEvidenceOf(m *measurement) string {
	if m == nil || !m.Workload.DeviceUseEstablished {
		return deviceNotObserved
	}
	return deviceWorkObserved
}

// observationContinuous asks whether the streams covered the run, reading their own endings.
//
// The per-stream test is streamEnd's one-sided reading and not a paraphrase of it: a forwarded terminal
// status is a loss the stream witnessed, and an ending with neither flag set is a stream that stopped on its
// own, which leaves a gap nothing can close. Cancelled-or-Stopped with no status is the only ending that may
// be accepted, and even that is only "not shown to be a loss".
func observationContinuous(obs *observationEvidence) bool {
	// An absent block is a run that never built a collector, and no streams at all is one whose very first
	// baseline was refused. Neither observed the run, and neither may read as though it had.
	if obs == nil || !obs.Established {
		return false
	}
	// The count and the coverage loop below are ONE check, and neither half works alone. Coverage alone reads
	// only the last entry per kind, because the map that follows is keyed by kind: a document listing a Pod
	// stream that forwarded a 410 and then a healthy duplicate Pod stream would have every watched kind
	// present, valid resume points throughout — so decodeRunRecord's own all-streams guard stays silent — and
	// the 410 would never be looked at. The count alone is no better: four streams all named "Pod" satisfy it.
	// Together they force a bijection onto watchedKinds, so every element of obs.Streams is exactly one of the
	// entries the loop below reads.
	//
	// This was a regression introduced by the fix for the missing-kind finding, not an original gap — the loop
	// it replaced ran the one-sided reading over every element. No build writes a duplicate kind, so no real
	// run was affected, but a forged document is the whole reason checkValidity re-derives this verdict at all.
	if len(obs.Streams) != len(watchedKinds()) {
		return false
	}
	seen := map[string]streamEvidence{}
	for _, s := range obs.Streams {
		seen[s.Kind] = s
	}
	// Every kind this build watches has to be there. A record carrying one healthy stream out of four is not a
	// continuous view of the run, and counting the entries would not say so on its own — three Pod streams and
	// no Workload stream pass any length check. This is why watchedKinds was hoisted: the set that decides
	// here is the set that opened them.
	//
	// It does couple a record to the build reading it, and that is accepted rather than overlooked: a build
	// that watches a different set of kinds is a build whose evidence has a different shape, which is a schema
	// change, and recordSchemaVersion is what separates those documents anyway.
	for _, k := range watchedKinds() {
		s, ok := seen[k.kind]
		if !ok {
			return false
		}
		// The one-sided reading, spelled out because each clause catches something the others do not. Ended
		// keeps a stream still shutting down from reading as one that died. LastStatus is the only clause that
		// can see a loss a cancellation has MASKED — a stream that forwarded a terminal 410 and was then
		// cancelled at the horizon has Cancelled true and is still a gap, and an expired resume point is the
		// canonical thing RetryWatcher cannot resume past. And neither flag set is a stream that stopped on its
		// own, which is always a gap.
		if !s.Ended || s.LastStatus != "" || (!s.Cancelled && !s.Stopped) {
			return false
		}
		// startWatchStream refuses both of these outright, so a stream persisted with one describes a watch
		// that began at an unknown point — which is the defect the continuity gate replaced, not evidence of it
		// having been fixed.
		if s.BaselineResourceVersion == "" || s.BaselineResourceVersion == "0" {
			return false
		}
	}
	return true
}

// environmentEstablished re-reads the qualification's own numbers rather than trusting that a block exists.
//
// A qualification is persisted on the refusal path too — that is the more valuable of the two records — so
// its presence says the worker was inspected and never that it passed.
//
// The first two clauses are a FLOOR, and they are the symmetric twin of the guard decodeRunRecord already
// applies to the window. Without them `0 >= 0` satisfies the capacity test, so a qualification of a node
// named "" advertising no device and requiring none reads as a worker this run could measure on — the exact
// zero-valued claim the field being a pointer was chosen to prevent, re-entered through the values instead of
// through the block's absence. Neither is a state any build writes: qualify copies the node's own name, and
// requiredGPU refuses a requirement below 1 outright rather than accepting a bar every machine clears.
//
// PodsOnNode deliberately has NO floor, and the asymmetry with the window's NodeVersionsObserved is the
// point. The window's opening read makes 1 the structural minimum, so a zero there is impossible; a node
// genuinely carrying no Pods is an ordinary cluster state, and refusing it would refuse a real machine for
// being quiet.
//
// The canary reference is required for the same reason the two floors are, and it is the one clause here that
// is about the mechanism rather than the machine: a worker can be Ready, schedulable, uncontended and large
// enough while being one on which the two arms are the same experiment. A nil reference is every run that did
// not get past that gate — no canary recorded, a recorded one that failed, or one taken on another
// combination — and none of those may read as an established environment.
func environmentEstablished(q *qualification) bool {
	if q == nil {
		return false
	}
	if q.Node == "" || q.RequiredGPU < 1 {
		return false
	}
	if q.TerminationCanary == nil {
		return false
	}
	return q.Ready && q.Schedulable && q.AllocatableGPU >= q.RequiredGPU && len(q.GPUConsumers) == 0
}

// exclusivityHeld is the check the whole block exists for: it reads the count, never the reason.
//
// NodeVersionsObserved is the denominator, for the reason ownershipWindow's own comment gives: "nothing
// deviated" from a view that compared nothing is indistinguishable from a view pointed at the wrong object.
func exclusivityHeld(w *ownershipWindow) bool {
	return w != nil && w.ViolationsObserved == 0 && w.NodeVersionsObserved >= 1
}

// clusterRestored asks whether this run gave back what it took.
//
// The restoration audit is only required where one could exist. A run refused before it opened a window never
// acquired a worker to restore, and flagging that would report the absence of damage as damage; a run that
// did open one and cannot show its markers came off has left a node marked, which is the thing worth naming.
func clusterRestored(left []recordResidue, w *ownershipWindow) bool {
	if len(left) > 0 {
		return false
	}
	if w != nil && (w.Restoration == nil || !w.Restoration.OurMarkersRemoved) {
		return false
	}
	return true
}

// recordResidue is the record's own projection of a residue entry, and deliberately not teardown.go's
// `residue` itself.
//
// residue carries an `error` on its observation, and an interface field does not survive the round trip —
// but not because encoding loses it. What an error ENCODES as depends on its concrete type: a plain
// fmt.Errorf/errors.New value has no exported fields, so it degenerates to `{}`, but the case settlePhase
// actually holds a delete refusal aside to report — an apiserver refusal, *apierrors.StatusError — has an
// exported ErrStatus and encodes in full, message and all. What breaks, for every error value alike
// (short of nil), is the DECODE: encoding/json cannot unmarshal a JSON object into an interface field,
// independent of DisallowUnknownFields or of what the object contains. Persisting `[]residue` verbatim
// would therefore write records that decodeRunRecord rejects, on exactly the runs whose delete was
// refused: the most informative residue there is would be the residue that made the record unreadable. So
// the error is flattened to its text here, at the boundary where the record is built.
//
// Absence is a NAME rather than the iota, which is the point at which the plan said to settle that: an int
// here would make the declaration order of the constants in teardown.go a wire format, and inserting a case
// between two of them would silently relabel every record ever written.
//
// The phase is not carried. It is a function of the kind — namespace, then ClusterQueue, then
// ResourceFlavor — so persisting it would only create a second copy to keep in sync with enumerate.
type recordResidue struct {
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Absence     string `json:"absence"`
	Found       bool   `json:"found,omitempty"`
	Terminating bool   `json:"terminating,omitempty"`
	UID         string `json:"uid,omitempty"`
	WantUID     string `json:"wantUID,omitempty"`
	Error       string `json:"error,omitempty"`
}

// absenceName is the persisted spelling of a verdict.
//
// The default case names the integer rather than falling back to "unknown", because a constant added to
// teardown.go without a case here is a bug in this function, and reporting it as the verdict that means
// "nobody could tell" would hide that bug inside a value the schema says is legitimate.
func absenceName(a absence) string {
	switch a {
	case absencePresent:
		return "present"
	case absenceAbsent:
		return "absent"
	case absenceForeign:
		return "foreign"
	case absenceUnknown:
		return "unknown"
	default:
		return fmt.Sprintf("unrecognised(%d)", int(a))
	}
}

// residueForRecord projects what teardown observed into what the record persists.
func residueForRecord(left []residue) []recordResidue {
	if len(left) == 0 {
		return nil
	}
	out := make([]recordResidue, 0, len(left))
	for _, r := range left {
		e := recordResidue{
			Kind:        r.Observation.Target.Kind,
			Name:        r.Observation.Target.Name,
			Absence:     absenceName(r.Absence),
			Found:       r.Observation.Found,
			Terminating: r.Observation.Terminating,
			UID:         r.Observation.UID,
			WantUID:     r.Observation.WantUID,
		}
		// The read's own failure is reported in preference to a delete refusal, because when a read failed
		// there is no observation for a refusal to be about; only one of the two can be true of one target.
		switch {
		case r.Observation.Err != nil:
			e.Error = r.Observation.Err.Error()
		case r.Observation.DeleteRefusal != nil:
			e.Error = r.Observation.DeleteRefusal.Error()
		}
		out = append(out, e)
	}
	return out
}

// previewRecord is a separate type, not runRecord with the events omitted.
//
// A preview's author declared its output uncountable, so that output must not be convertible into evidence
// by anyone downstream who did not read the declaration. Because queuelab.Reconstruct accepts an event slice,
// any field decodable into one is reconstructable regardless of its name — so the preview branch has no such
// field at all, and the summary below is deliberately lossy. The declaration is thus enforced by the TYPE
// rather than by the reader's good faith, which is what makes it survive a shell redirect.
type previewRecord struct {
	SchemaVersion int `json:"schemaVersion"`
	// Dose is carried for the same reason runRecord carries it: two previews of different regimes would
	// otherwise be indistinguishable documents describing different experiments.
	Dose        string `json:"dose"`
	Preview     bool   `json:"preview"`
	RunID       string `json:"runID"`
	Arm         string `json:"arm"`
	StartedAt   string `json:"startedAt,omitempty"`
	EndedAt     string `json:"endedAt,omitempty"`
	Disposition string `json:"disposition"`
	Reason      string `json:"reason,omitempty"`
	// EventCount is a count, not a ledger: it cannot be inverted into events.
	EventCount int    `json:"eventCount"`
	Note       string `json:"note"`
	// Residue is carried here too, unlike the ledger, because a preview runs the whole of run() — namespace
	// and fixtures included — and leaves exactly the same objects behind when teardown cannot finish.
	// Withholding it would hide a held worker from the mode most likely to be the one that stranded it, since
	// a smoke check is what an operator reaches for on a cluster they do not yet trust. It is safe here for the
	// same structural reason the type's own comment gives: recordResidue has no field a lifecycle ledger can be
	// decoded out of.
	Residue []recordResidue `json:"residue,omitempty"`
	// Qualification is carried here for the same reason Residue is, and is safe here for the same structural
	// reason: it describes the machine, not the run's lifecycle, and has no field a ledger can be decoded out
	// of. A preview runs the whole of run(), so it qualifies its worker exactly as a real run does, and a
	// preview whose record did not say what it found would be a smoke check of an unnamed machine.
	Qualification *qualification `json:"qualification,omitempty"`
	// Window is carried for the same reason and is safe for the same one: it describes what happened to a
	// Node, and every field in it is a string, a bool or an int that no lifecycle ledger can be decoded out
	// of. A preview opens its window exactly as a run does, and a preview that lost its worker mid-flight is
	// worth knowing about precisely because a smoke check is where that would first be noticed.
	Window *ownershipWindow `json:"window,omitempty"`
	// Observation is carried for the same reason and is safe for the same one: resource versions, counts and
	// ending flags are not a lifecycle ledger and nothing can be decoded out of them into one. A preview opens
	// the same four streams a run does, and the failure this block describes — a watch that never attached, a
	// stream that died mid-run — is exactly what a smoke check is run to find.
	Observation *observationEvidence `json:"observation,omitempty"`
	// Validity is carried so that a preview's record states its own inadmissibility in the same field a run's
	// record states its admissibility, rather than leaving a reader to notice the preview flag. Its verdict is
	// always verdictPreview; see deriveValidity.
	Validity validity `json:"validity"`
}

// previewNote is a fixed constant, never anything derived from the run.
//
// previewRecord has no field a ledger can be decoded out of, but Note is free text, so a future writer could
// fold run data — a JSON-encoded ledger, most obviously — into it and hand a preview exactly the
// reconstructable evidence the type was shaped to deny it. A constant closes that second-order route with
// something a test can check, which a formatted string could not be.
//
// The TEXT used to say "the validity gates were not enforced", and that was false about every build that
// wrote it. run() has never taken a preview flag, so no gate has ever been waived for a preview; the sentence
// went stale the day the first gate landed. It is replaced rather than annotated because this is the same
// defect the UnimplementedGates field was already fixed for — a durable statement, inside a document, that is
// untrue of the build that wrote the document, read by someone who has only the file. An operator who checks
// the claim and finds it false learns to discount the rest of the note, including the conclusion that is the
// half worth acting on.
//
// What replaces it is the difference that actually exists, which is about the ARTIFACT and not about the
// checking: buildRecord's preview branch returns previewRecord, which carries a count where a run carries its
// events and has no field a ledger can be decoded out of, so no result can be reconstructed from this
// document by anyone — and deriveValidity's last line forces the verdict to verdictPreview however well every
// other field came out. Those two, plus what reportRun withholds from the terminal for the same reason, are
// the whole of the delta.
//
// It is phrased as a property of the MODE rather than of the invocation, because this note is persisted on
// every preview record including one refused before it reached a cluster, where no gate ran at all — for the
// same reason no gate runs on a non-preview invocation refused at the same point. "No gate is waived for a
// preview" is true of all of them; "this invocation passed the gates" would not be.
const previewNote = "preview: declared a smoke check. No validity gate is waived for a preview — it is " +
	"checked exactly as a run is — but this record withholds the events ledger, so no result can be " +
	"reconstructed from it and it is not evidence"

// classified refuses a zero disposition, which is the one thing a record must never carry.
//
// run sets a disposition on every return, but nothing in the language enforces that: deleting a single
// assignment leaves the named return at its zero value, and neither the compiler nor go vet says a word.
// The test that walked the returns could only reach two of seventeen, so the invariant is enforced here,
// where every record is built, rather than audited where only some are reachable.
//
// It substitutes rather than panicking. A panic in the record writer would destroy the record for a run
// that genuinely happened, which is precisely the evidence loss this whole task exists to stop; naming the
// bug in the artifact keeps the record, fails the run (main exits non-zero on anything that is not
// dispChecksPassed), and leaves a string a reader can grep for.
func classified(o outcome) outcome {
	if o.Disposition != "" {
		return o
	}
	reason := "a return path set no disposition; this is a bug in run(), not an outcome of the run"
	if o.Reason != "" {
		reason = reason + " (reason given: " + o.Reason + ")"
	}
	return outcome{Disposition: dispUnclassified, Reason: reason}
}

// buildRecord chooses which record a given invocation may leave behind.
//
// This is the only place a preview and a run diverge in what they PERSIST, so the guarantee that a preview
// cannot emit reconstructable evidence lives in one readable decision rather than being spread across the
// call sites that write. (reportRun diverges too, but only over what reaches a terminal, and it diverges the
// same way for the same reason: a printed ledger reconstructs as well as a written one.)
// recordIdentity is what names the experiment a record describes.
//
// A struct rather than three adjacent strings, for the reason FixtureIdentity is one: runID, arm and dose are
// all strings, a transposition would not be caught by the compiler, and a record naming the wrong arm or the
// wrong dose regime is a document that answers a question it did not ask.
type recordIdentity struct {
	RunID string
	Arm   string
	Dose  string
}

// measurementOf projects a reconstruction into the record, or nil when there was none.
//
// nil rather than a zero block, because "this run measured nothing" and "this run never got far enough to
// measure" are different states and a reader must not have to guess which produced a row of zeroes.
// discardedIterations sums the work of attempts whose ROW never completed.
//
// The completion filter is the whole of it, and the first version did not have one: it added every stopped
// attempt, so a row that ran to a successful finish had its work counted as thrown away. On a live run that
// turned 21540 genuinely discarded iterations into 47513 by adding the owner's 25973 completed ones — a
// number that would have been quoted as waste and was the opposite of it. The doc comment claimed the filter
// before the code had it.
//
// A Completed event is the ledger's own statement that the row's work was credited. Its ABSENCE is what makes
// an attempt's iterations discarded, which is deliberately wider than "the container failed": the
// self-completing regime's victim exits 0 and is still re-executed from zero, because Kueue does not credit a
// suspended Job's finished attempt. Reading the exit code instead would call that work saved when the whole
// experiment is about it being lost.
//
// Counted off the LEDGER rather than off the reconstruction, because the ledger is what the record persists:
// a number derived from anything the document does not carry could not be re-derived by a reader holding it.
func discardedIterations(events []queuelab.LifecycleEvent) *int {
	credited := make(map[string]bool)
	for _, e := range events {
		if e.Type == queuelab.EventCompleted {
			credited[e.Job] = true
		}
	}
	total, seen := 0, false
	for _, e := range events {
		if e.Type != queuelab.EventAttemptStopped || e.Iterations == nil {
			continue
		}
		seen = true
		if !credited[e.Job] {
			total += *e.Iterations
		}
	}
	if !seen {
		return nil
	}
	return &total
}

func measurementOf(res *queuelab.LabResult, horizonNs int64, events []queuelab.LifecycleEvent) *measurement {
	if res == nil {
		return nil
	}
	return &measurement{
		DiscardedIterations:       discardedIterations(events),
		Workload:                  cpuOnlyWorkload(),
		Resolution:                resolutionOf(events),
		HorizonNs:                 horizonNs,
		WastedGPUSeconds:          res.TotalWastedGPUSeconds,
		WasteLowerBoundGPUSeconds: res.TotalWasteLowerBoundGPUSeconds,
		Censored:                  res.AnyWasteCensored,
		UnfinishedAtHorizon:       res.UnfinishedAtHorizon,
	}
}

func buildRecord(o outcome, events []queuelab.LifecycleEvent, left []residue, qual *qualification,
	win *ownershipWindow, obs *observationEvidence, id recordIdentity, m *measurement, preview bool,
	started, ended time.Time) any {
	o = classified(o)
	persistedResidue := residueForRecord(left)
	// Derived from the PROJECTION rather than from `left`, so the verdict is taken over the same array the
	// document carries: a residue entry that failed to project would otherwise be counted by a verdict nobody
	// reading the file could reproduce.
	v := deriveValidity(o, persistedResidue, qual, win, obs, m, preview)
	startedAt := started.UTC().Format(time.RFC3339)
	endedAt := ended.UTC().Format(time.RFC3339)
	if preview {
		return previewRecord{
			SchemaVersion: recordSchemaVersion,
			Preview:       true,
			RunID:         id.RunID,
			Arm:           id.Arm,
			Dose:          id.Dose,
			StartedAt:     startedAt,
			EndedAt:       endedAt,
			Disposition:   string(o.Disposition),
			Reason:        o.Reason,
			EventCount:    len(events),
			Note:          previewNote,
			Residue:       persistedResidue,
			Qualification: qual,
			Window:        win,
			Observation:   obs,
			Validity:      v,
		}
	}
	// The preview above deliberately carries NO measurement. It withholds the ledger so its output cannot be
	// reconstructed into a number, and handing back the numbers directly would return exactly what the
	// withholding protects.
	return runRecord{
		SchemaVersion: recordSchemaVersion,
		Measurement:   m,
		RunID:         id.RunID,
		Arm:           id.Arm,
		Dose:          id.Dose,
		StartedAt:     startedAt,
		EndedAt:       endedAt,
		Disposition:   string(o.Disposition),
		Reason:        o.Reason,
		Events:        events,
		Residue:       persistedResidue,
		Qualification: qual,
		Window:        win,
		Observation:   obs,
		Validity:      v,
	}
}

func encodeRecord(v any) ([]byte, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("encode record: %w", err)
	}
	return append(b, '\n'), nil
}

// decodeRunRecord refuses anything it does not fully understand.
//
// A non-empty RunID is required but does not mean a run id somebody chose: an invocation refused before it
// read -runid is recorded under the unidentifiedRunID sentinel, which runIDPattern can never accept, so a
// reader matching records to runs must expect ids that name no run.
func decodeRunRecord(b []byte) (runRecord, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var r runRecord
	if err := dec.Decode(&r); err != nil {
		return runRecord{}, fmt.Errorf("decode record: %w", err)
	}
	// The three sibling decoders in this package all refuse trailing data and this one did not, which made its
	// own doc comment false: a decoder stops at the end of the first value, so a record file with a second
	// document appended decoded exactly as cleanly as one without, and every byte past the record went to no
	// reader at all. That is not a hypothetical shape — a double write, a partially replaced file, or two
	// records concatenated by a wrapper script all produce it, and the artifact is the deliverable precisely
	// because a reader can re-derive the verdict from the fields beside the numbers. Bytes nobody accounts for
	// sitting after those fields mean the file is not one document, whatever its first document says.
	if dec.More() {
		return runRecord{}, fmt.Errorf("decode record: trailing data after the record")
	}
	if r.SchemaVersion != recordSchemaVersion {
		return runRecord{}, fmt.Errorf("decode record: schema %d is not %d", r.SchemaVersion, recordSchemaVersion)
	}
	if r.Preview && len(r.Events) > 0 {
		return runRecord{}, fmt.Errorf("decode record: a preview record carries %d events; preview output is not evidence",
			len(r.Events))
	}
	if r.RunID == "" || r.Disposition == "" {
		return runRecord{}, fmt.Errorf("decode record: runID and disposition are required")
	}
	// The version check above already refuses every document an older build wrote, so this guards a different
	// thing: a document that CLAIMS this version while carrying a bound no build ever produced — a hand-edited
	// file, or a future writer that forgot to set it. Both would otherwise decode into the same undocumented
	// "" the version bump exists to stop being readable, which would make the bump a fix for one route into a
	// state the type still permits.
	if q := r.Qualification; q != nil &&
		q.RequiredBoundBy != boundByQuotaSum && q.RequiredBoundBy != boundByLargestRow {
		return runRecord{}, fmt.Errorf(
			"decode record: qualification names bound %q, which is neither %q nor %q; a requirement whose "+
				"binding constraint is unknown cannot be read as either of them",
			q.RequiredBoundBy, boundByQuotaSum, boundByLargestRow)
	}
	// The same guard once more for the canary reference, and it closes the same route the two around it do: a
	// document CLAIMING this version while carrying a reference that names nothing. A zero canaryReference
	// satisfies environmentEstablished's non-nil test — which is the strongest thing this block can say about
	// the mechanism the arms differ by — while identifying no qualification, quoting no image and naming no
	// runtime, so a reader could not go and check it against anything. No build writes one: qualify attaches
	// only what checkTerminationCanary returned, and that comes from a document decodeCanary has already
	// refused to read without these fields.
	//
	// The pod template hash is swept with them rather than left to the version check above, and the reason is
	// the shape of failure this lineage has already met once: two guards that each look sufficient, neither of
	// which covers one field, and the overlap hiding that nothing did. The version refuses documents written
	// before the field existed; this clause refuses a document claiming today's version whose reference carries
	// no hash, which is the state a projection that dropped the field, or a hand-edited file, produces.
	if tc := canaryRefOf(r.Qualification); tc != nil &&
		(tc.CanaryID == "" || tc.Key.Image == "" || tc.Key.NodeUID == "" || tc.Key.PodTemplateHash == "") {
		return runRecord{}, fmt.Errorf(
			"decode record: the qualification names termination canary %q on image %q, node UID %q and pod "+
				"template %q; a reference that identifies no qualification cannot be read as evidence that one "+
				"was consulted",
			tc.CanaryID, tc.Key.Image, tc.Key.NodeUID, tc.Key.PodTemplateHash)
	}
	// The same guard for the window, and it is a different check from the version one above for the same
	// reason: a document CLAIMING this version while carrying a window that observed no node version at all
	// would be read as a run whose worker was watched throughout and never deviated, which is the single
	// strongest thing this record can say. No build writes one — startOwnershipSentinel's opening read makes
	// every window it returns at least 1 — so a zero here is a hand-edited or future-written document, and
	// it must not be readable as the claim it structurally cannot support.
	if w := r.Window; w != nil && (w.Node == "" || w.NodeVersionsObserved < 1) {
		return runRecord{}, fmt.Errorf(
			"decode record: the window names node %q and %d observed node version(s); a window that watched "+
				"nothing cannot be read as evidence that the worker stayed this run's",
			w.Node, w.NodeVersionsObserved)
	}
	// The same guard once more for the observation. startWatchStream refuses "" and "0" as resume points — a
	// watch that starts at "now" or at an arbitrary cached position cannot speak for the interval before it
	// attached — so a stream recorded with either is a hand-edited or future-written document, and it must not
	// be readable as the continuous view the block's whole existence claims.
	if ob := r.Observation; ob != nil {
		for _, s := range ob.Streams {
			if s.BaselineResourceVersion == "" || s.BaselineResourceVersion == "0" {
				return runRecord{}, fmt.Errorf(
					"decode record: the %s stream records resume point %q, which is not a point a watch can "+
						"resume from; a stream with no known baseline cannot be read as a continuous view",
					s.Kind, s.BaselineResourceVersion)
			}
		}
	}
	if err := checkValidity(r); err != nil {
		return runRecord{}, err
	}
	return r, nil
}

// checkValidity refuses a verdict a reader could not act on, and one the document does not support.
//
// The two halves are asymmetric on purpose. An unknown verdict is refused outright, for the reason the schema
// version exists at all: the field's entire value is that a reader classifies on it without parsing prose, so
// a value that is neither documented name hands that reader something to classify on that means nothing —
// including the "" a version-3 document would decode into, which is the other route into the state the bump
// closes.
//
// The support check runs for verdictAdmissible ALONE, and that is a deliberate choice rather than a partial
// implementation. Re-deriving a refusal would refuse documents over a failure vocabulary that legitimately
// grows as gates land, and a record that already says it is inadmissible is the weaker claim in any case.
// verdictAdmissible is the strongest thing this file can say and the one somebody would forge, so it is the
// one required to be re-derivable from the evidence printed beside it: a verdict that does not follow from
// the fields is a verdict, not evidence.
func checkValidity(r runRecord) error {
	switch r.Validity.Verdict {
	case verdictRefused:
		// A refusal that names no claim tells a reader strictly less than the disposition already did, and no
		// build writes one: deriveValidity reaches this verdict only by appending at least one failure.
		if len(r.Validity.Failures) == 0 {
			return fmt.Errorf("decode record: the record refuses itself and names no failed claim; a refusal " +
				"that says nothing about what was not established is not a verdict")
		}
	case verdictPreview:
	case verdictAdmissible:
		want := deriveValidity(outcome{Disposition: disposition(r.Disposition)}, r.Residue, r.Qualification,
			r.Window, r.Observation, r.Measurement, r.Preview)
		if want.Verdict != verdictAdmissible {
			return fmt.Errorf("decode record: the record claims %q while its own fields do not support it (%v); "+
				"a verdict that cannot be re-derived from the evidence beside it is an assertion, not evidence",
				verdictAdmissible, want.Failures)
		}
		if len(r.Validity.Failures) > 0 {
			return fmt.Errorf("decode record: the record claims %q and lists failed claim(s) %v at the same time",
				verdictAdmissible, r.Validity.Failures)
		}
	default:
		return fmt.Errorf("decode record: the verdict is %q, which is none of %q, %q or %q; a document whose "+
			"verdict is unreadable has not been judged as far as any reader can tell",
			r.Validity.Verdict, verdictAdmissible, verdictRefused, verdictPreview)
	}
	// Checked for EVERY verdict, including refused and preview, and outside the switch above so it cannot be
	// skipped by adding a case. A refused run still carries a measurement on some paths, and a reader asking
	// "did anything here touch a device" is asking a question the verdict does not answer in any of the three
	// states -- so the axis has to be readable in all of them or it is readable in none.
	switch r.Validity.DeviceEvidence {
	case deviceWorkObserved, deviceNotObserved:
	case "":
		return fmt.Errorf("decode record: the record states no device-evidence axis; a blank axis is not the " +
			"cautious reading, it is a value a consumer classifies on that means nothing at all, and this " +
			"document's GPU-seconds are seconds of reservation unless something says otherwise")
	default:
		return fmt.Errorf("decode record: the device-evidence axis is %q, which is neither %q nor %q",
			r.Validity.DeviceEvidence, deviceWorkObserved, deviceNotObserved)
	}
	// The axis is derived, so a document may not assert one its own evidence does not produce. This is the
	// check that stops a record claiming device work on the strength of a hand-edited field, which is the
	// only way the value could appear at all in a build with no observer.
	if want := deviceEvidenceOf(r.Measurement); want != r.Validity.DeviceEvidence {
		return fmt.Errorf("decode record: the record claims device evidence %q while its own measurement "+
			"supports %q; an axis that cannot be re-derived from the evidence beside it is an assertion",
			r.Validity.DeviceEvidence, want)
	}
	return nil
}

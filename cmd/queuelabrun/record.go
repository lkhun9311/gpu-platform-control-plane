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
const recordSchemaVersion = 3

// runRecord is what a non-preview invocation leaves behind.
//
// It makes no experimental claim: it says an invocation happened, what disposition it reached, and carries
// the raw events. Fixtures, environment, restoration audit and validity are later pieces and add their own
// fields when they exist rather than being reserved here.
type runRecord struct {
	SchemaVersion int `json:"schemaVersion"`
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
		if r.Observation.Err != nil {
			e.Error = r.Observation.Err.Error()
		}
		out = append(out, e)
	}
	return out
}

// previewRecord is a separate type, not runRecord with the events omitted.
//
// A preview runs without the validity gates, so its output must not be convertible into evidence. Because
// queuelab.Reconstruct accepts an event slice, any field decodable into one is reconstructable regardless
// of its name — so the preview branch has no such field at all, and the summary below is deliberately
// lossy.
type previewRecord struct {
	SchemaVersion int    `json:"schemaVersion"`
	Preview       bool   `json:"preview"`
	RunID         string `json:"runID"`
	Arm           string `json:"arm"`
	StartedAt     string `json:"startedAt,omitempty"`
	EndedAt       string `json:"endedAt,omitempty"`
	Disposition   string `json:"disposition"`
	Reason        string `json:"reason,omitempty"`
	// EventCount is a count, not a ledger: it cannot be inverted into events.
	EventCount int    `json:"eventCount"`
	Note       string `json:"note"`
	// Residue is carried here too, unlike the ledger, because a preview runs the whole of run() — namespace
	// and fixtures included — and is therefore the mode generating residue today. Withholding it would lose
	// the residue for the only mode currently producing any. It is safe here for the same structural reason
	// the type's own comment gives: recordResidue has no field a lifecycle ledger can be decoded out of.
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
}

// previewNote is a fixed constant, never anything derived from the run.
//
// previewRecord has no field a ledger can be decoded out of, but Note is free text, so a future writer could
// fold run data — a JSON-encoded ledger, most obviously — into it and hand a gateless run exactly the
// reconstructable evidence the type was shaped to deny it. A constant closes that second-order route with
// something a test can check, which a formatted string could not be.
const previewNote = "preview: the validity gates were not enforced, so this is a smoke check and not evidence"

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
// This is the only place the preview and non-preview branches diverge, so the guarantee that a gateless run
// cannot emit reconstructable evidence lives in one readable decision rather than being spread across the
// call sites that write.
func buildRecord(o outcome, events []queuelab.LifecycleEvent, left []residue, qual *qualification,
	win *ownershipWindow, runID, arm string, preview bool, started, ended time.Time) any {
	o = classified(o)
	persistedResidue := residueForRecord(left)
	startedAt := started.UTC().Format(time.RFC3339)
	endedAt := ended.UTC().Format(time.RFC3339)
	if preview {
		return previewRecord{
			SchemaVersion: recordSchemaVersion,
			Preview:       true,
			RunID:         runID,
			Arm:           arm,
			StartedAt:     startedAt,
			EndedAt:       endedAt,
			Disposition:   string(o.Disposition),
			Reason:        o.Reason,
			EventCount:    len(events),
			Note:          previewNote,
			Residue:       persistedResidue,
			Qualification: qual,
			Window:        win,
		}
	}
	return runRecord{
		SchemaVersion: recordSchemaVersion,
		RunID:         runID,
		Arm:           arm,
		StartedAt:     startedAt,
		EndedAt:       endedAt,
		Disposition:   string(o.Disposition),
		Reason:        o.Reason,
		Events:        events,
		Residue:       persistedResidue,
		Qualification: qual,
		Window:        win,
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
	return r, nil
}

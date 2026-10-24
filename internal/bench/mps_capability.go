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

package bench

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"strings"
)

// The MPS capability session's outcome, from docs/superpowers/specs/2026-09-25-can-mps-engage-on-this-card-at-all.md
// and its amendment of 2026-10-24, which fixes the order the four outcomes are tested in.
//
// The runner appends one JSON object per line to a journal as it works: a bar "started" before its instrument runs
// and "decided" once it has read the answer, and a named fact whenever it establishes one.
// This file reads that journal and names exactly one outcome.
// A journal it cannot read is refused rather than classified, because a session cut short and a recorder that wrote
// nonsense must not be reported as the same thing.

// MPSOutcome is one of the four outcomes the registration allows.
type MPSOutcome string

const (
	MPSPass         MPSOutcome = "PASS"
	MPSRefused      MPSOutcome = "REFUSED"
	MPSInconclusive MPSOutcome = "INCONCLUSIVE"
	MPSInvalid      MPSOutcome = "INVALID"
)

// MPSBars are the registration's bars, in the order the session decides them.
var MPSBars = []string{"B0", "B1", "B2", "B3", "B4", "B5"}

// A bar's state as the journal leaves it.
// "interrupted" is a bar whose instrument started and never reported, which the amendment keeps apart from both a
// failure and a pass; "absent" is a bar the session never reached.
const (
	mpsBarPass        = "pass"
	mpsBarFail        = "fail"
	mpsBarUnmeasured  = "unmeasured"
	mpsBarInterrupted = "interrupted"
	mpsBarAbsent      = "absent"
)

// The facts the classification reads, each a yes or no the runner establishes.
//
// The first six are preconditions: false on any of them is INVALID, and PASS needs each one true.
// A precondition left unwritten is unknown, which blocks PASS without making the run INVALID, except for the two the
// amendment makes INVALID by absence: a LaunchTime the instance never confirmed reading, since every deadline counts
// from it, and a termination nobody confirmed.
// schedulable is false only when an engine Pod could not be scheduled for a reason the diagnostics name and that is
// not the device; a Pod the device refused is evidence about MPS, not a broken apparatus.
var mpsPreconditions = []string{
	"launch_time_read",
	"overlay_pinned",
	"manifests_pinned",
	"images_pulled",
	"schedulable",
	"termination_confirmed",
}

// The remaining facts: the two kinds of refusal evidence and the two completeness checks.
var mpsOtherFacts = []string{
	"no_healthy_devices_event",
	"daemon_rejected_client",
	"diagnostics_uploaded",
	"provenance_complete",
}

// MPSVerdict is the outcome with every reason that produced it, and each bar's state.
type MPSVerdict struct {
	Outcome MPSOutcome
	Reasons []string
	Bars    map[string]string
}

type mpsJournalLine struct {
	Type   string `json:"type"`
	Bar    string `json:"bar,omitempty"`
	State  string `json:"state,omitempty"`
	Result string `json:"result,omitempty"`
	Name   string `json:"name,omitempty"`
	Value  *bool  `json:"value,omitempty"`
	Detail string `json:"detail,omitempty"`
	At     string `json:"at"`
}

// mpsJournalState is what a journal establishes once read: which bars started, how each decided bar came out, and
// every fact.
type mpsJournalState struct {
	started map[string]bool
	decided map[string]string
	facts   map[string]bool
}

// ClassifyMPSCapability reads a journal and applies the amendment's order: INVALID, then REFUSED, then PASS, and
// INCONCLUSIVE for everything else.
func ClassifyMPSCapability(r io.Reader) (MPSVerdict, error) {
	st, err := readMPSJournal(r)
	if err != nil {
		return MPSVerdict{}, err
	}
	return classifyMPS(st), nil
}

func readMPSJournal(r io.Reader) (mpsJournalState, error) {
	st := mpsJournalState{started: map[string]bool{}, decided: map[string]string{}, facts: map[string]bool{}}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	// Lines and records are counted apart, because a journal of blank lines has lines and no evidence.
	n, records := 0, 0
	for sc.Scan() {
		n++
		raw := bytes.TrimSpace(sc.Bytes())
		if len(raw) == 0 {
			continue
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		var l mpsJournalLine
		if err := dec.Decode(&l); err != nil {
			return st, fmt.Errorf("journal line %d is not a journal record: %w", n, err)
		}
		// One record per line: Decode stops after the first object, so anything after it would be dropped unread,
		// and a dropped line can be the fact that contradicts the rest.
		if _, err := dec.Token(); err != io.EOF {
			return st, fmt.Errorf("journal line %d holds more than one record", n)
		}
		if l.At == "" {
			return st, fmt.Errorf("journal line %d has no time", n)
		}
		records++
		var err error
		switch l.Type {
		case "bar":
			err = st.applyBar(l)
		case "fact":
			err = st.applyFact(l)
		default:
			err = fmt.Errorf("has type %q, not bar or fact", l.Type)
		}
		if err != nil {
			return st, fmt.Errorf("journal line %d %w", n, err)
		}
	}
	if err := sc.Err(); err != nil {
		return st, fmt.Errorf("reading the journal: %w", err)
	}
	if records == 0 {
		return st, fmt.Errorf("the journal holds no records, so there is nothing to classify")
	}
	return st, nil
}

func (st mpsJournalState) applyBar(l mpsJournalLine) error {
	if !slices.Contains(MPSBars, l.Bar) {
		return fmt.Errorf("names bar %q, which the registration does not have", l.Bar)
	}
	switch l.State {
	case "started":
		// One attempt per bar: the stopping rule forbids a second, so a second start is a runner fault.
		if st.started[l.Bar] {
			return fmt.Errorf("starts %s a second time", l.Bar)
		}
		st.started[l.Bar] = true
	case "decided":
		if !st.started[l.Bar] {
			return fmt.Errorf("decides %s, which was never started", l.Bar)
		}
		if _, again := st.decided[l.Bar]; again {
			return fmt.Errorf("decides %s a second time", l.Bar)
		}
		switch l.Result {
		case mpsBarPass, mpsBarFail, mpsBarUnmeasured:
		default:
			return fmt.Errorf("decides %s as %q, not pass, fail or unmeasured", l.Bar, l.Result)
		}
		st.decided[l.Bar] = l.Result
	default:
		return fmt.Errorf("gives %s the state %q, not started or decided", l.Bar, l.State)
	}
	return nil
}

func (st mpsJournalState) applyFact(l mpsJournalLine) error {
	if !slices.Contains(mpsPreconditions, l.Name) && !slices.Contains(mpsOtherFacts, l.Name) {
		return fmt.Errorf("records fact %q, which the classification does not read", l.Name)
	}
	if l.Value == nil {
		return fmt.Errorf("records fact %s with no value", l.Name)
	}
	// A fact is established once; a second line for it is a runner that asked twice and could disagree.
	if _, again := st.facts[l.Name]; again {
		return fmt.Errorf("records fact %s a second time", l.Name)
	}
	st.facts[l.Name] = *l.Value
	return nil
}

func (st mpsJournalState) isTrue(name string) bool  { v, ok := st.facts[name]; return ok && v }
func (st mpsJournalState) isFalse(name string) bool { v, ok := st.facts[name]; return ok && !v }

func classifyMPS(st mpsJournalState) MPSVerdict {
	v := MPSVerdict{Bars: map[string]string{}}
	for _, b := range MPSBars {
		switch {
		case st.decided[b] != "":
			v.Bars[b] = st.decided[b]
		case st.started[b]:
			v.Bars[b] = mpsBarInterrupted
		default:
			v.Bars[b] = mpsBarAbsent
		}
	}

	// INVALID first: a broken apparatus says nothing about MPS, whatever the bars read.
	if invalid := mpsInvalidReasons(st); len(invalid) > 0 {
		v.Outcome, v.Reasons = MPSInvalid, invalid
		return v
	}

	// REFUSED needs the evidence of the refusal and the diagnostics that let a reader check it.
	var refusal []string
	if v.Bars["B1"] == mpsBarPass && st.isTrue("no_healthy_devices_event") {
		refusal = append(refusal, "the plugin advertised two and the kubelet's no healthy devices event was captured")
	}
	if st.isTrue("daemon_rejected_client") {
		refusal = append(refusal, "the control daemon recorded a client's rejection")
	}
	if len(refusal) > 0 && st.isTrue("diagnostics_uploaded") {
		v.Outcome, v.Reasons = MPSRefused, refusal
		return v
	}

	short := mpsShortOfPass(st, v.Bars)
	if len(refusal) > 0 {
		short = append(short, "refusal evidence was recorded but the diagnostics were not uploaded, so it cannot be checked")
	}
	if len(short) == 0 {
		v.Outcome, v.Reasons = MPSPass, []string{"B0 to B5 passed, the provenance and diagnostics are complete, and termination is confirmed"}
		return v
	}
	v.Outcome, v.Reasons = MPSInconclusive, short
	return v
}

func mpsInvalidReasons(st mpsJournalState) []string {
	var invalid []string
	for _, p := range []string{"launch_time_read", "termination_confirmed"} {
		if !st.isTrue(p) {
			invalid = append(invalid, p+" is not established")
		}
	}
	for _, p := range mpsPreconditions {
		if p != "launch_time_read" && p != "termination_confirmed" && st.isFalse(p) {
			invalid = append(invalid, p+" is false")
		}
	}
	return invalid
}

// mpsShortOfPass is every reason the run is not a pass: a bar that did not pass, a fact not established, and refusal
// evidence, since refusal evidence beside six passing bars is a contradiction and a contradiction is not a pass.
func mpsShortOfPass(st mpsJournalState, bars map[string]string) []string {
	var short []string
	for _, b := range MPSBars {
		if bars[b] != mpsBarPass {
			short = append(short, fmt.Sprintf("%s is %s", b, bars[b]))
		}
	}
	for _, p := range append(slices.Clone(mpsPreconditions), "diagnostics_uploaded", "provenance_complete") {
		if !st.isTrue(p) {
			short = append(short, p+" is not established")
		}
	}
	for _, f := range []string{"no_healthy_devices_event", "daemon_rejected_client"} {
		if st.isTrue(f) {
			short = append(short, f+" is recorded")
		}
	}
	return short
}

// String prints the verdict as the session records it: the outcome, each bar, and every reason.
func (v MPSVerdict) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "MPS: %s\n", v.Outcome)
	for _, bar := range MPSBars {
		fmt.Fprintf(&b, "%s %s\n", bar, v.Bars[bar])
	}
	for _, r := range v.Reasons {
		fmt.Fprintf(&b, "reason: %s\n", r)
	}
	return b.String()
}

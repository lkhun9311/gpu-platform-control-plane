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
	"fmt"
	"maps"
	"strings"
	"testing"
)

// mpsJournal builds a journal that passes, so each case changes exactly one thing.
//
// bars maps a bar to its result, "" for a bar started and never decided, and "-" for a bar never started; facts maps
// a fact to its value, and a fact named with "-" is left out.
type mpsJournal struct {
	bars  map[string]string
	facts map[string]string
	extra []string
}

func passingMPSJournal() mpsJournal {
	j := mpsJournal{bars: map[string]string{}, facts: map[string]string{}}
	for _, b := range MPSBars {
		j.bars[b] = "pass"
	}
	for _, f := range mpsPreconditions {
		j.facts[f] = "true"
	}
	j.facts["no_healthy_devices_event"] = "false"
	j.facts["daemon_rejected_client"] = "false"
	j.facts["diagnostics_uploaded"] = "true"
	j.facts["provenance_complete"] = "true"
	return j
}

func (j mpsJournal) with(kind, name, value string) mpsJournal {
	c := mpsJournal{bars: map[string]string{}, facts: map[string]string{}, extra: j.extra}
	maps.Copy(c.bars, j.bars)
	maps.Copy(c.facts, j.facts)
	if kind == "bar" {
		c.bars[name] = value
	} else {
		c.facts[name] = value
	}
	return c
}

func (j mpsJournal) render() string {
	var b strings.Builder
	for _, bar := range MPSBars {
		r := j.bars[bar]
		if r == "-" {
			continue
		}
		fmt.Fprintf(&b, `{"type":"bar","bar":%q,"state":"started","at":"2026-10-24T00:00:00Z"}`+"\n", bar)
		if r != "" {
			fmt.Fprintf(&b, `{"type":"bar","bar":%q,"state":"decided","result":%q,"at":"2026-10-24T00:00:01Z"}`+"\n", bar, r)
		}
	}
	for _, f := range append(append([]string{}, mpsPreconditions...), mpsOtherFacts...) {
		v, ok := j.facts[f]
		if !ok || v == "-" {
			continue
		}
		fmt.Fprintf(&b, `{"type":"fact","name":%q,"value":%s,"at":"2026-10-24T00:00:02Z"}`+"\n", f, v)
	}
	for _, e := range j.extra {
		b.WriteString(e + "\n")
	}
	return b.String()
}

func TestMPSCapabilityOutcomes(t *testing.T) {
	pass := passingMPSJournal()
	refusedByDevice := pass.with("bar", "B2", "fail").with("fact", "no_healthy_devices_event", "true")
	cases := []struct {
		name    string
		journal mpsJournal
		want    MPSOutcome
		reason  string
	}{
		{"every bar passed and every fact established", pass, MPSPass, "B0 to B5 passed"},

		// INVALID by absence: every deadline counts from LaunchTime, and a run whose instance was not seen to end is void.
		{"termination unconfirmed after six passing bars", pass.with("fact", "termination_confirmed", "-"), MPSInvalid, "termination_confirmed is not established"},
		{"termination recorded as not confirmed", pass.with("fact", "termination_confirmed", "false"), MPSInvalid, "termination_confirmed is not established"},
		{"LaunchTime never read", pass.with("fact", "launch_time_read", "-"), MPSInvalid, "launch_time_read is not established"},
		{"the overlay not the pinned one", pass.with("fact", "overlay_pinned", "false"), MPSInvalid, "overlay_pinned is false"},
		{"an engine manifest not the pinned one", pass.with("fact", "manifests_pinned", "false"), MPSInvalid, "manifests_pinned is false"},
		// An image that did not pull reaches the same "never Running" as a refused device; it must not be read as one.
		{"an image that did not pull, beside a failed B2", pass.with("bar", "B2", "fail").with("fact", "images_pulled", "false"), MPSInvalid, "images_pulled is false"},
		{"a Pod unschedulable for a reason that is not the device", pass.with("fact", "schedulable", "false"), MPSInvalid, "schedulable is false"},
		{"INVALID outranks a captured refusal", refusedByDevice.with("fact", "termination_confirmed", "false"), MPSInvalid, "termination_confirmed"},

		{"the device refused after advertising two", refusedByDevice, MPSRefused, "no healthy devices"},
		{"the daemon rejected a client", pass.with("bar", "B3", "fail").with("fact", "daemon_rejected_client", "true"), MPSRefused, "rejection"},
		// The event without B1's advertisement is not the registered refusal: a plugin that advertised nothing cannot
		// have been declined.
		{"the event without B1 passing", refusedByDevice.with("bar", "B1", "fail"), MPSInconclusive, "B1 is fail"},
		{"refusal evidence without the diagnostics", refusedByDevice.with("fact", "diagnostics_uploaded", "false"), MPSInconclusive, "cannot be checked"},

		{"a bar started and never decided", pass.with("bar", "B4", ""), MPSInconclusive, "B4 is interrupted"},
		{"a bar never reached", pass.with("bar", "B5", "-"), MPSInconclusive, "B5 is absent"},
		{"an unmeasured bar", pass.with("bar", "B4", "unmeasured"), MPSInconclusive, "B4 is unmeasured"},
		{"a failed bar whose cause is unknown", pass.with("bar", "B0", "fail"), MPSInconclusive, "B0 is fail"},
		{"provenance incomplete", pass.with("fact", "provenance_complete", "false"), MPSInconclusive, "provenance_complete is not established"},
		{"diagnostics not uploaded", pass.with("fact", "diagnostics_uploaded", "-"), MPSInconclusive, "diagnostics_uploaded is not established"},
		{"a precondition left unknown", pass.with("fact", "images_pulled", "-"), MPSInconclusive, "images_pulled is not established"},
		// Six passing bars beside a recorded refusal is a contradiction, and a contradiction is not a pass.
		{"refusal evidence beside six passing bars, without B1's advertisement read as a refusal",
			pass.with("fact", "no_healthy_devices_event", "true").with("fact", "diagnostics_uploaded", "false"), MPSInconclusive, "no_healthy_devices_event is recorded"},
	}
	for _, c := range cases {
		v, err := ClassifyMPSCapability(strings.NewReader(c.journal.render()))
		if err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
			continue
		}
		if v.Outcome != c.want {
			t.Errorf("%s: got %s, want %s:\n%s", c.name, v.Outcome, c.want, v)
			continue
		}
		if !strings.Contains(strings.Join(v.Reasons, "; "), c.reason) {
			t.Errorf("%s: no %q among the reasons:\n%s", c.name, c.reason, v)
		}
	}
}

func TestMPSCapabilityRefusesAJournalItCannotRead(t *testing.T) {
	pass := passingMPSJournal()
	withExtra := func(line string) string {
		j := pass
		j.extra = []string{line}
		return j.render()
	}
	cases := []struct {
		name, journal, want string
	}{
		{"an empty journal", "", "no records"},
		{"a journal of blank lines", "\n  \n\n", "no records"},
		// The trailing record is the one that would make the run INVALID, so dropping it would change the outcome.
		{"two records on one line", strings.Replace(pass.render(), `"value":true,"at":"2026-10-24T00:00:02Z"}`+"\n",
			`"value":true,"at":"2026-10-24T00:00:02Z"} {"type":"fact","name":"x","value":false,"at":"t"}`+"\n", 1), "more than one record"},
		{"garbage after a record", strings.Replace(pass.render(), `"value":true,"at":"2026-10-24T00:00:02Z"}`+"\n",
			`"value":true,"at":"2026-10-24T00:00:02Z"} trailing`+"\n", 1), "more than one record"},
		{"a line that is not JSON", withExtra("B0 pass"), "not a journal record"},
		{"a field the journal does not have", withExtra(`{"type":"fact","name":"provenance_complete","value":true,"at":"x","ok":1}`), "not a journal record"},
		{"a line with no time", withExtra(`{"type":"bar","bar":"B9","state":"started"}`), "no time"},
		{"a bar the registration does not have", withExtra(`{"type":"bar","bar":"B6","state":"started","at":"x"}`), "does not have"},
		{"a second start", withExtra(`{"type":"bar","bar":"B0","state":"started","at":"x"}`), "a second time"},
		{"a second decision", withExtra(`{"type":"bar","bar":"B0","state":"decided","result":"fail","at":"x"}`), "a second time"},
		{"a decision never started", passingMPSJournal().with("bar", "B3", "-").render() + `{"type":"bar","bar":"B3","state":"decided","result":"pass","at":"x"}` + "\n", "never started"},
		{"a result that is not one of the three", passingMPSJournal().with("bar", "B3", "-").render() +
			`{"type":"bar","bar":"B3","state":"started","at":"x"}` + "\n" + `{"type":"bar","bar":"B3","state":"decided","result":"ok","at":"x"}` + "\n", "not pass, fail or unmeasured"},
		{"an unknown state", withExtra(`{"type":"bar","bar":"B0","state":"retried","at":"x"}`), "not started or decided"},
		{"a fact the classification does not read", withExtra(`{"type":"fact","name":"mps_engaged","value":true,"at":"x"}`), "does not read"},
		// The fact is otherwise absent, so the line cannot be refused as a repeat instead.
		{"a fact with no value", passingMPSJournal().with("fact", "provenance_complete", "-").render() + `{"type":"fact","name":"provenance_complete","at":"x"}` + "\n", "no value"},
		{"a fact recorded twice", withExtra(`{"type":"fact","name":"provenance_complete","value":true,"at":"x"}`), "a second time"},
		{"an unknown type", withExtra(`{"type":"note","at":"x"}`), "not bar or fact"},
	}
	for _, c := range cases {
		_, err := ClassifyMPSCapability(strings.NewReader(c.journal))
		if err == nil {
			t.Errorf("%s: classified, it must be refused", c.name)
			continue
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %q does not say %q", c.name, err, c.want)
		}
	}
}

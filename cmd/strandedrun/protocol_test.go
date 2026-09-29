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
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// protocolPath is the checked-in canonical protocol, relative to this package's directory.
const protocolPath = "../../hack/stranded-protocol.yaml"

// The checked-in protocol must load, and must say what the registration page says it says.
//
// This is the page-against-file comparison the pair exists to have. The page states the matrix in prose --
// "two arms, three repetitions, six cells", "at most twelve attempts", "six submissions and six censuses",
// "2, 1, 1" -- and until this test existed nothing compared those sentences with the file the tool reads.
// docs-check resolves backticked names and says nothing about arithmetic.
//
// Mutation that turns this red: change any of those values in hack/stranded-protocol.yaml.
func TestTheCheckedInProtocolLoadsAndMatchesWhatThePageSays(t *testing.T) {
	p, err := LoadProtocol(protocolPath)
	if err != nil {
		t.Fatalf("the campaign's own protocol does not load: %v", err)
	}
	if got := []int(p.Layout()); len(got) != 3 || got[0] != 2 || got[1] != 1 || got[2] != 1 {
		t.Errorf("the registered layout is %v; the page registers 2, 1, 1", got)
	}
	arms := []string{}
	for _, a := range p.Arms {
		arms = append(arms, a.Name)
	}
	if strings.Join(arms, ",") != string(ArmUntouched)+","+string(ArmConfigured) {
		t.Errorf("the registered arms are %v; the page registers %s and %s", arms, ArmUntouched, ArmConfigured)
	}
	if len(p.Submissions) != 6 || p.Expected.SubmissionAttempts != 6 || p.Expected.AcceptedCensuses != 6 {
		t.Errorf("the page registers six submissions and six censuses; the file says %d submissions, %d attempts, "+
			"%d censuses", len(p.Submissions), p.Expected.SubmissionAttempts, p.Expected.AcceptedCensuses)
	}
	if p.Matrix.Cells != 6 || p.Matrix.RepetitionsPerArm != 3 || p.Matrix.MaxAttemptsTotal != 12 {
		t.Errorf("the page registers six cells, three repetitions and twelve attempts; the file says %d, %d, %d",
			p.Matrix.Cells, p.Matrix.RepetitionsPerArm, p.Matrix.MaxAttemptsTotal)
	}
	// The discriminating step is the one the question lives at, and the page names s3 with a request of 2.
	disc := ""
	for _, s := range p.Submissions {
		if s.Discriminating {
			disc = s.ID
			if s.Request != 2 {
				t.Errorf("the discriminating submission requests %d; the page registers 2", s.Request)
			}
		}
	}
	if disc != "s3" {
		t.Errorf("the discriminating submission is %q; the page registers s3", disc)
	}
	if p.Barriers.PerStepTimeoutSeconds != 120 || !p.Barriers.SettlednessMustBeObserved {
		t.Errorf("the page registers a 120 second per-step timeout and observed settledness; the file says %d and %t",
			p.Barriers.PerStepTimeoutSeconds, p.Barriers.SettlednessMustBeObserved)
	}
}

// writeVariant copies the checked-in protocol with one textual substitution and returns its path.
//
// The variants are built from the REAL file rather than from a fixture written here. A fixture would be a third
// copy of the protocol, and the next change to the real file would leave these cases testing something that no
// longer exists -- while still passing.
func writeVariant(t *testing.T, old, new string) string {
	t.Helper()
	b, err := os.ReadFile(protocolPath)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if n := strings.Count(s, old); n != 1 {
		t.Fatalf("the anchor %q appears %d time(s) in the protocol, expected 1; this case is not a verdict "+
			"about the validator", old, n)
	}
	path := filepath.Join(t.TempDir(), "stranded-protocol.yaml")
	if err := os.WriteFile(path, []byte(strings.Replace(s, old, new, 1)), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// A protocol whose derived quantities contradict each other must be refused, one relation at a time.
//
// Each case below is a sentence the page asserts, broken in the file. They are separate subtests because a
// single case with several contradictions passes as long as ANY one check survives a mutation.
//
// Mutation that turns this red: delete the corresponding relation from Protocol.Validate().
func TestTheProtocolRefusesWhatItsOwnArithmeticContradicts(t *testing.T) {
	for _, tc := range []struct {
		name, old, new, wantIn string
	}{
		{
			name:   "cells that are not arms times repetitions",
			old:    "  cells: 6",
			new:    "  cells: 9",
			wantIn: "2 arms x 3 repetitions is 6",
		},
		{
			name:   "an attempt bound that does not follow from the matrix",
			old:    "  max_attempts_total: 12",
			new:    "  max_attempts_total: 20",
			wantIn: "6 cells with 1 replacement(s) each is 12",
		},
		{
			name:   "a census count that disagrees with the submission count",
			old:    "  accepted_censuses: 6",
			new:    "  accepted_censuses: 5",
			wantIn: "accepted_censuses is 5 and the sequence has 6 submissions",
		},
		{
			name:   "an expected attempt count that disagrees with the sequence",
			old:    "  submission_attempts: 6",
			new:    "  submission_attempts: 7",
			wantIn: "submission_attempts is 7 and the sequence has 6",
		},
		{
			name:   "a discriminating request larger than the largest node",
			old:    "    request: 2\n    discriminating: true",
			new:    "    request: 3\n    discriminating: true",
			wantIn: "could never bind in either arm",
		},
		{
			name:   "a discriminating request of one device, which cannot distinguish anything",
			old:    "    request: 2\n    discriminating: true",
			new:    "    request: 1\n    discriminating: true",
			wantIn: "cannot distinguish the arms",
		},
		{
			name:   "no discriminating step at all",
			old:    "    discriminating: true\n",
			new:    "",
			wantIn: "marks 0 discriminating submissions",
		},
		{
			name:   "an arm whose installs flag disagrees with the instrument",
			old:    "    installs_scheduler_config: false",
			new:    "    installs_scheduler_config: true",
			wantIn: "would install the other arm",
		},
		{
			name:   "an arm this campaign never registered",
			old:    "  - name: S-default",
			new:    "  - name: S-tas",
			wantIn: "neither S-default nor S-gpu-most",
		},
		{
			name:   "devices on the control plane",
			old:    "  control_plane_devices: 0",
			new:    "  control_plane_devices: 1",
			wantIn: "runs no device plugin",
		},
		{
			name:   "an unpinned node image",
			old:    "  node: kindest/node:v1.31.0",
			new:    "  node: kindest/node",
			wantIn: "not pinned to a tag",
		},
		{
			name:   "settledness allowed to be asserted",
			old:    "  settledness_must_be_observed: true",
			new:    "  settledness_must_be_observed: false",
			wantIn: "asserted rather than observed",
		},
		{
			name:   "no per-step timeout",
			old:    "  per_step_timeout_seconds: 120",
			new:    "  per_step_timeout_seconds: 0",
			wantIn: "outcome selecting the method",
		},
		{
			name:   "a version this binary does not know",
			old:    "version: 1",
			new:    "version: 2",
			wantIn: "is not 1",
		},
		{
			name:   "attempts that are not all published",
			old:    "  publish_every_attempt: true",
			new:    "  publish_every_attempt: false",
			wantIn: "publishing the retakes is what makes it visible",
		},
		{
			name:   "a reporting threshold chosen in advance",
			old:    "  reporting_threshold: none",
			new:    "  reporting_threshold: two_devices",
			wantIn: "publishes every valid cell",
		},
		{
			name:   "membership judged as a total rather than per step",
			old:    "  membership_at_step_k_must_be: s1..sk",
			new:    "  membership_at_step_k_must_be: six_at_the_end",
			wantIn: "membership is judged per step",
		},
		{
			name:   "scheduling refusals not retained, so the validity judgement is an opinion",
			old:    "    - failed_scheduling_events\n",
			new:    "",
			wantIn: "is an opinion rather than a judgement about evidence",
		},
		{
			name:   "a cell no longer invalidated by an unobserved disposition",
			old:    "  - unobserved_disposition\n",
			new:    "",
			wantIn: "one of the three failures",
		},
		{
			name:   "a tie promoted to an invalidation, which would discard null results",
			old:    "  - a_tie_between_nodes\n",
			new:    "",
			wantIn: "selecting on the outcome",
		},
		{
			// Added rather than substituted: replacing a_tie_between_nodes would trip the check that requires it
			// to be present, which runs first, and the case would then pass on the wrong refusal.
			name:   "the same reason in both invalidation lists",
			old:    "  - a_shortage_classification",
			new:    "  - a_shortage_classification\n  - unobserved_disposition",
			wantIn: "appears in both invalidation lists",
		},
		{
			name:   "the reference no longer requiring the profile file to be absent",
			old:    "      profile_file_must_be_absent: true",
			new:    "      profile_file_must_be_absent: false",
			wantIn: "quietest way for this arm to become the other one",
		},
		{
			name:   "the treatment scoring a resource this study does not vary",
			old:    "        - name: nvidia.com/gpu",
			new:    "        - name: cpu",
			wantIn: "does not name " + GPUResourceName,
		},
		{
			name:   "a treatment arm whose strategy disagrees with its own name",
			old:    "      scoring_strategy: MostAllocated",
			new:    "      scoring_strategy: LeastAllocated",
			wantIn: "the arm is named for " + string(MostAllocated),
		},
		{
			name:   "the reference carrying scoring evidence it could not have",
			old:    "      demand_must_schedule: true",
			new:    "      demand_must_schedule: true\n      scoring_strategy: MostAllocated",
			wantIn: "there is no scoring of its to qualify",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := writeVariant(t, tc.old, tc.new)
			_, err := LoadProtocol(path)
			if err == nil {
				t.Fatalf("the validator accepted a protocol with %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not name the disagreement.\n  want substring: %s\n  got: %v",
					tc.wantIn, err)
			}
		})
	}
}

// A file that breaks two rules must be refused by the earlier group, and that order must be pinned.
//
// Validate() runs its groups in a declared order and its comment calls that order load-bearing. Nothing was
// checking it: reversing the five calls left all twenty-five refusal cases green, because each of those cases
// breaks exactly one rule and one rule produces the same message wherever its group sits. So the comment was
// asserting an invariant no test could see -- and the invariant is real, since it is why the overlap case adds
// an entry instead of substituting one.
//
// This case breaks a sequence rule and a rules-group rule at once. The sequence group runs first, so the
// sequence refusal is what a reader must be told about.
//
// Mutation that turns this red: reorder the groups in Validate().
func TestABrokenProtocolIsRefusedByTheEarlierGroup(t *testing.T) {
	b, err := os.ReadFile(protocolPath)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	// Two independent faults: the discriminating step is unmarked (a sequence fault), and a reason appears in
	// both invalidation lists (a rules fault).
	for _, a := range []string{"    discriminating: true\n", "  - a_shortage_classification"} {
		if n := strings.Count(s, a); n != 1 {
			t.Fatalf("anchor %q appears %d time(s), expected 1", a, n)
		}
	}
	s = strings.Replace(s, "    discriminating: true\n", "", 1)
	s = strings.Replace(s, "  - a_shortage_classification",
		"  - a_shortage_classification\n  - unobserved_disposition", 1)

	path := filepath.Join(t.TempDir(), "stranded-protocol.yaml")
	if err := os.WriteFile(path, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = LoadProtocol(path)
	if err == nil {
		t.Fatal("a protocol with two independent faults was accepted")
	}
	// The sequence group runs before the rules group, so this is the refusal a reader must get.
	if !strings.Contains(err.Error(), "marks 0 discriminating submissions") {
		t.Errorf("the earlier group's refusal did not win, so the declared order of Validate's groups has "+
			"changed and the comment calling that order load-bearing is now wrong.\n  got: %v", err)
	}
	if strings.Contains(err.Error(), "appears in both invalidation lists") {
		t.Error("the later group's refusal won; a reader would be told about the second fault and would fix it " +
			"without learning about the first")
	}
}

// A misspelled key must be refused, not ignored.
//
// This is why LoadProtocol uses UnmarshalStrict. Under the lenient form `submisions:` is dropped and the field
// keeps its zero value, so the protocol would arrive with no submissions and the refusal would blame the
// sequence being empty rather than the typo -- a diagnosis pointing at the wrong file.
//
// Mutation that turns this red: change UnmarshalStrict back to Unmarshal.
func TestAMisspelledKeyIsRefusedRatherThanSilentlyDropped(t *testing.T) {
	path := writeVariant(t, "submissions:", "submisions:")
	_, err := LoadProtocol(path)
	if err == nil {
		t.Fatal("a protocol with a misspelled key was accepted")
	}
	if !strings.Contains(err.Error(), "does not parse") {
		t.Errorf("the refusal blames something other than the parse, so the typo was silently dropped: %v", err)
	}
}

// The ledger at step k must be exactly the protocol's first k submissions, by identity, order and request.
//
// This is the check that closes the hole Census.Settled leaves open. Settled is a boolean the run operator
// sets; the reservation balance cannot see a submission omitted from the ledger entirely, because a ledger
// missing a row balances perfectly well. Membership is therefore judged against the frozen file.
//
// Mutation that turns this red: compare only the count, or only the names.
func TestTheLedgerMustBeExactlyTheProtocolsFirstKSubmissions(t *testing.T) {
	p, err := LoadProtocol(protocolPath)
	if err != nil {
		t.Fatal(err)
	}
	nodes := []NodeCapacity{
		{Name: "stranded-worker", Allocatable: 2, Reserved: 1},
		{Name: "stranded-worker2", Allocatable: 1, Reserved: 1},
		{Name: "stranded-worker3", Allocatable: 1, Reserved: 0},
	}
	// The honest ledger at step 2: s1 and s2, both bound, both requesting one device.
	honest := []Submission{
		{Name: "s1", Request: 1, Disposition: DispositionBound, Node: "stranded-worker"},
		{Name: "s2", Request: 1, Disposition: DispositionBound, Node: "stranded-worker2"},
	}
	if err := p.CheckMembership(2, Census{Step: "c2", Nodes: nodes, Submissions: honest, Settled: true}); err != nil {
		t.Fatalf("the honest ledger was refused: %v", err)
	}

	for _, tc := range []struct {
		name   string
		subs   []Submission
		step   int
		wantIn string
	}{
		{
			name:   "a row omitted entirely, which the reservation balance cannot see",
			step:   2,
			subs:   honest[:1],
			wantIn: "a missing row balances the reservation check perfectly",
		},
		{
			name:   "the sequence reordered",
			step:   2,
			subs:   []Submission{honest[1], honest[0]},
			wantIn: "a reordered ledger is a different sequence",
		},
		{
			name: "the right names with a wrong request",
			step: 2,
			subs: []Submission{honest[0], {Name: "s2", Request: 2, Disposition: DispositionBound,
				Node: "stranded-worker2"}},
			wantIn: "reports a different study",
		},
		{
			name:   "a submission nobody looked at",
			step:   2,
			subs:   []Submission{honest[0], {Name: "s2", Request: 1, Disposition: DispositionUnobserved}},
			wantIn: "carries no observed disposition",
		},
		{
			name:   "a census at a step the campaign never registered",
			step:   7,
			subs:   honest,
			wantIn: "outside the registered sequence",
		},
		{
			name:   "a ledger that ran ahead of its step",
			step:   1,
			subs:   honest,
			wantIn: "holds 2 submission(s) and the protocol registers 1",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := p.CheckMembership(tc.step, Census{Step: "c", Nodes: nodes, Submissions: tc.subs, Settled: true})
			if err == nil {
				t.Fatalf("the census was accepted with %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not say what is wrong.\n  want substring: %s\n  got: %v", tc.wantIn, err)
			}
		})
	}
}

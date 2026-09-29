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
	"fmt"
	"os"
	"slices"
	"strings"

	"sigs.k8s.io/yaml"
)

// Protocol is the campaign's frozen protocol as the registration file states it.
//
// It is READ rather than restated. The registration page
// docs/superpowers/specs/2026-09-29-stranded-gpu-frozen-protocol.md states the same matrix in prose, and the
// only thing that stops those two from becoming two statements of one fact is that the page's derived
// quantities are recomputed from this file by Validate() rather than typed into Go.
//
// Not embedded with go:embed, and there is no precedent for that in this repository. Embedding would make the
// binary carry a copy of the protocol, so a run could disagree with the file on disk and say nothing -- which
// is the drift this arrangement exists to prevent. The path is supplied, and a run that cannot read it fails.
// Every key of the file is declared here, and that is a requirement rather than tidiness: UnmarshalStrict
// refuses a key this type does not know. The first version of this struct declared eight of the file's keys and
// the protocol would not load at all -- which is the failure worth having. Under the lenient form it would have
// loaded cleanly and enforced a subset, while the page claimed the file was canonical and nothing disagreed.
type Protocol struct {
	Version     int                  `json:"version"`
	Arms        []ProtocolArm        `json:"arms"`
	Submissions []ProtocolSubmission `json:"submissions"`
	NodeLayout  struct {
		Workers             []int `json:"workers"`
		ControlPlaneDevices int   `json:"control_plane_devices"`
	} `json:"node_layout"`
	Images struct {
		Node      string `json:"node"`
		Scheduler string `json:"scheduler"`
	} `json:"images"`
	Expected struct {
		SubmissionAttempts int `json:"submission_attempts"`
		AcceptedCensuses   int `json:"accepted_censuses"`
		// MembershipAtStepK is prose in the file and a pinned constant here: the campaign's whole defence
		// against an omitted ledger row is that membership is judged per step rather than as a total.
		MembershipAtStepK string `json:"membership_at_step_k_must_be"`
	} `json:"expected_counts"`
	Matrix struct {
		RepetitionsPerArm          int    `json:"repetitions_per_arm"`
		Cells                      int    `json:"cells"`
		ReplacementsPerInvalidCell int    `json:"replacements_per_invalid_cell"`
		MaxAttemptsTotal           int    `json:"max_attempts_total"`
		PublishEveryAttempt        bool   `json:"publish_every_attempt"`
		ReportingThreshold         string `json:"reporting_threshold"`
	} `json:"matrix"`
	Barriers struct {
		SettlednessMustBeObserved bool     `json:"settledness_must_be_observed"`
		PerStepTimeoutSeconds     int      `json:"per_step_timeout_seconds"`
		RetainPerStep             []string `json:"retain_per_step"`
	} `json:"barriers"`
	InvalidatesACell       []string `json:"invalidates_a_cell"`
	DoesNotInvalidateACell []string `json:"does_not_invalidate_a_cell"`
	// QualificationEvidenceExcluded are the hand-run checks disclosed as evidence that the instrument
	// discriminates. They are declared so the file may carry them; no figure of theirs enters a comparison.
	QualificationEvidenceExcluded []string `json:"qualification_evidence_excluded_from_comparison"`
}

// ProtocolArm is one registered arm and the evidence that qualifies it.
type ProtocolArm struct {
	Name                    string `json:"name"`
	InstallsSchedulerConfig bool   `json:"installs_scheduler_config"`
	Qualification           struct {
		// The reference's qualification, which is behavioural because its effective configuration cannot be
		// read here: no --config in the scheduler's arguments, no profile file, and demand that schedules.
		SchedulerArgsMustNotContain []string `json:"scheduler_args_must_not_contain"`
		ProfileFileMustBeAbsent     bool     `json:"profile_file_must_be_absent"`
		DemandMustSchedule          bool     `json:"demand_must_schedule"`
		// The treatment's qualification, which is a predicted placement plus the profile it must install.
		CheckTreatmentMustReportApplied bool             `json:"check_treatment_must_report_applied"`
		ScoringStrategy                 ScoringStrategy  `json:"scoring_strategy"`
		ScoringResources                []ResourceWeight `json:"scoring_resources"`
	} `json:"qualification"`
}

// ProtocolSubmission is one registered step of the submission sequence.
type ProtocolSubmission struct {
	ID             string `json:"id"`
	Request        int    `json:"request"`
	Discriminating bool   `json:"discriminating"`
}

// LoadProtocol reads and validates the protocol file at path.
//
// UnmarshalStrict rather than Unmarshal, deliberately. A misspelled key under the lenient form is silently
// dropped and the field keeps its zero value, so `submisions:` would produce a protocol with no submissions and
// a refusal that blamed the wrong thing. A protocol whose typos are ignored is not a protocol.
func LoadProtocol(path string) (Protocol, error) {
	var p Protocol
	data, err := os.ReadFile(path)
	if err != nil {
		return Protocol{}, fmt.Errorf("could not read the protocol at %s: %w; a cell may not run against a "+
			"protocol nobody read", path, err)
	}
	if err := yaml.UnmarshalStrict(data, &p); err != nil {
		return Protocol{}, fmt.Errorf("the protocol at %s does not parse: %w", path, err)
	}
	if err := p.Validate(); err != nil {
		return Protocol{}, fmt.Errorf("the protocol at %s is not self-consistent: %w", path, err)
	}
	return p, nil
}

// Validate recomputes the registration page's derived quantities from this file.
//
// Each check below is a sentence the page asserts in prose. The page says six cells; this says
// cells == arms x repetitions. The page says at most twelve attempts; this says
// max_attempts_total == cells x (1 + replacements). Written out this way because a page and a file are two
// statements of one fact, and the only thing that makes the pair safe is that one of them is computed.
func (p Protocol) Validate() error {
	if p.Version != 1 {
		return fmt.Errorf("protocol version %d is not 1; a version this binary does not know may mean "+
			"anything and must not be guessed at", p.Version)
	}
	// In this order, and the order is load-bearing. Several refusals are reachable from one broken file -- a
	// protocol that both drops a required invalidation reason and duplicates another, say -- and which one a
	// reader is told about is decided here. The refusal tests are written against these positions, so moving a
	// group changes which message a broken protocol produces.
	for _, check := range []func() error{
		p.validateArms,
		p.validateLayoutAndImages,
		p.validateSequence,
		p.validateCounts,
		p.validateBarriersAndRules,
	} {
		if err := check(); err != nil {
			return err
		}
	}
	for _, a := range p.Arms {
		if err := a.validateQualification(); err != nil {
			return err
		}
	}
	return nil
}

// validateArms refuses an arm set that is not the two this campaign registered, or one that disagrees with the
// instrument about what it installs.
func (p Protocol) validateArms() error {
	// The arms, by name, must be exactly the two this campaign registered -- and each must agree with the Arm
	// type about whether it installs a configuration, because that boolean decides what the renderer emits.
	if len(p.Arms) != 2 {
		return fmt.Errorf("the protocol registers %d arm(s); the first campaign registers exactly 2", len(p.Arms))
	}
	seen := map[Arm]bool{}
	for _, a := range p.Arms {
		arm := Arm(a.Name)
		if err := arm.Validate(); err != nil {
			return fmt.Errorf("protocol arm %q: %w", a.Name, err)
		}
		if seen[arm] {
			return fmt.Errorf("arm %s appears twice; three repetitions of one arm is not a two-arm campaign", arm)
		}
		seen[arm] = true
		if a.InstallsSchedulerConfig != arm.InstallsSchedulerConfig() {
			return fmt.Errorf("the protocol says arm %s installs_scheduler_config=%t while the instrument says "+
				"%t; the renderer follows the instrument, so a run would install the other arm",
				arm, a.InstallsSchedulerConfig, arm.InstallsSchedulerConfig())
		}
	}
	return nil
}

// validateLayoutAndImages refuses a layout a census could not account for, and a version that could move.
func (p Protocol) validateLayoutAndImages() error {
	if len(p.NodeLayout.Workers) == 0 {
		return fmt.Errorf("the protocol registers no worker capacities, so nothing pins the layout a cell runs on")
	}
	for i, w := range p.NodeLayout.Workers {
		if w <= 0 {
			return fmt.Errorf("worker %d advertises %d devices; a worker that advertises nothing is not part of "+
				"a GPU layout and would silently change what the sequence means", i+1, w)
		}
	}
	if p.NodeLayout.ControlPlaneDevices != 0 {
		return fmt.Errorf("the protocol gives the control plane %d devices; it runs no device plugin in this "+
			"study and capacity there would enter the census unaccounted for", p.NodeLayout.ControlPlaneDevices)
	}

	// Both images pinned, for the reason measured on this host: it has more than one Kubernetes version
	// installed, so an unpinned version can move between cells and read as the treatment.
	if p.Images.Node == "" || !strings.Contains(p.Images.Node, ":") {
		return fmt.Errorf("the node image %q is not pinned to a tag", p.Images.Node)
	}
	if p.Images.Scheduler == "" || !strings.Contains(p.Images.Scheduler, ":") {
		return fmt.Errorf("the scheduler image %q is not pinned to a tag", p.Images.Scheduler)
	}
	return nil
}

// validateSequence refuses a submission sequence that could not be checked for membership, or whose
// discriminating step could not discriminate.
func (p Protocol) validateSequence() error {
	// The submission sequence: named, positive, and identified by position so a census can be checked for
	// membership rather than for a total.
	if len(p.Submissions) == 0 {
		return fmt.Errorf("the protocol registers no submissions; a cell with no registered demand measures nothing")
	}
	ids := map[string]bool{}
	discriminating := []string{}
	largestNode := 0
	for _, w := range p.NodeLayout.Workers {
		if w > largestNode {
			largestNode = w
		}
	}
	for i, s := range p.Submissions {
		if s.ID == "" {
			return fmt.Errorf("submission %d has no id; a submission with no identity cannot be checked for "+
				"ledger membership, which is the check that catches an omitted row", i+1)
		}
		if ids[s.ID] {
			return fmt.Errorf("submission id %q appears twice; membership at step k could then be satisfied by "+
				"the wrong row", s.ID)
		}
		ids[s.ID] = true
		if s.Request <= 0 {
			return fmt.Errorf("submission %s requests %d devices; a non-positive request is not demand",
				s.ID, s.Request)
		}
		if s.Discriminating {
			discriminating = append(discriminating, s.ID)
			if s.Request > largestNode {
				return fmt.Errorf("the discriminating submission %s requests %d devices and the largest node "+
					"advertises %d; it could never bind in either arm, so it would measure shortage rather than "+
					"the arms' difference", s.ID, s.Request, largestNode)
			}
			if s.Request <= 1 {
				return fmt.Errorf("the discriminating submission %s requests %d device; a single-device request "+
					"fits wherever anything is free and cannot distinguish the arms", s.ID, s.Request)
			}
		}
	}
	if len(discriminating) != 1 {
		return fmt.Errorf("the protocol marks %d discriminating submissions (%s); exactly one step carries the "+
			"question, and marking none or several makes the sequence's purpose unstated",
			len(discriminating), strings.Join(discriminating, ", "))
	}
	return nil
}

// validateCounts recomputes every quantity the registration page states in prose.
func (p Protocol) validateCounts() error {
	// The page's counts, recomputed rather than trusted.
	if p.Expected.SubmissionAttempts != len(p.Submissions) {
		return fmt.Errorf("expected_counts.submission_attempts is %d and the sequence has %d submissions",
			p.Expected.SubmissionAttempts, len(p.Submissions))
	}
	if p.Expected.AcceptedCensuses != len(p.Submissions) {
		return fmt.Errorf("expected_counts.accepted_censuses is %d and the sequence has %d submissions; a census "+
			"is taken after each one settles", p.Expected.AcceptedCensuses, len(p.Submissions))
	}
	if p.Matrix.RepetitionsPerArm <= 0 {
		return fmt.Errorf("repetitions_per_arm is %d", p.Matrix.RepetitionsPerArm)
	}
	if want := len(p.Arms) * p.Matrix.RepetitionsPerArm; p.Matrix.Cells != want {
		return fmt.Errorf("the protocol registers %d cells; %d arms x %d repetitions is %d",
			p.Matrix.Cells, len(p.Arms), p.Matrix.RepetitionsPerArm, want)
	}
	if p.Matrix.ReplacementsPerInvalidCell < 0 {
		return fmt.Errorf("replacements_per_invalid_cell is %d", p.Matrix.ReplacementsPerInvalidCell)
	}
	if want := p.Matrix.Cells * (1 + p.Matrix.ReplacementsPerInvalidCell); p.Matrix.MaxAttemptsTotal != want {
		return fmt.Errorf("max_attempts_total is %d; %d cells with %d replacement(s) each is %d, and a bound "+
			"that does not follow from the matrix is a bound that can be argued with mid-campaign",
			p.Matrix.MaxAttemptsTotal, p.Matrix.Cells, p.Matrix.ReplacementsPerInvalidCell, want)
	}
	return nil
}

// validateBarriersAndRules refuses a protocol whose barriers could be asserted rather than observed, and whose
// invalidation rules would discard the cells that report a null result.
func (p Protocol) validateBarriersAndRules() error {
	if !p.Barriers.SettlednessMustBeObserved {
		return fmt.Errorf("the protocol allows settledness to be asserted rather than observed; a census taken " +
			"mid-binding describes a cluster that existed at no instant, and -settled is the run operator's " +
			"claim rather than a reading")
	}
	if p.Barriers.PerStepTimeoutSeconds <= 0 {
		return fmt.Errorf("per_step_timeout_seconds is %d; a step with no bound waits until the outcome looks "+
			"right, which is the outcome selecting the method", p.Barriers.PerStepTimeoutSeconds)
	}
	if p.Expected.MembershipAtStepK != "s1..sk" {
		return fmt.Errorf("membership_at_step_k_must_be is %q; the campaign's defence against an omitted ledger "+
			"row is that membership is judged per step, and a protocol that asked for totals would accept a "+
			"ledger missing a row", p.Expected.MembershipAtStepK)
	}
	if !slices.Contains(p.Barriers.RetainPerStep, "failed_scheduling_events") {
		return fmt.Errorf("the protocol does not retain failed_scheduling_events (it retains %v); without them "+
			"\"pending for a reason other than GPU capacity\" is an opinion rather than a judgement about "+
			"evidence, and that judgement is what invalidates a cell", p.Barriers.RetainPerStep)
	}
	if !p.Matrix.PublishEveryAttempt {
		return fmt.Errorf("the protocol does not publish every attempt; retaking until the numbers agree selects " +
			"on the outcome, and publishing the retakes is what makes it visible that this did not happen")
	}
	if p.Matrix.ReportingThreshold != "none" {
		return fmt.Errorf("reporting_threshold is %q; this campaign publishes every valid cell, and a threshold "+
			"chosen here would be chosen knowing which policy the literature favours",
			p.Matrix.ReportingThreshold)
	}

	// The invalidation rules, both lists. The second list is the load-bearing one: a protocol that invalidated a
	// tie or an identical outcome would discard exactly the cells that report a null result.
	for _, want := range []string{"unobserved_disposition", "ledger_membership_mismatch",
		"scheduler_restart_during_the_cell",
		// The two isolation rules. The sibling fragmentation study counts headroom across every namespace and
		// reads its context from an environment variable, so a cell sharing a cluster with it would have its
		// demand counted into that study's vector and vice versa -- and neither run would say so.
		"a_submission_of_this_campaign_outside_its_own_cluster",
		"the_sibling_studys_fixture_installed_on_the_cells_cluster"} {
		if !slices.Contains(p.InvalidatesACell, want) {
			return fmt.Errorf("the protocol does not invalidate a cell for %s; that is one of the three failures "+
				"the page's validity argument rests on", want)
		}
	}
	for _, want := range []string{"a_tie_between_nodes", "an_identical_outcome_across_arms_or_repetitions"} {
		if !slices.Contains(p.DoesNotInvalidateACell, want) {
			return fmt.Errorf("the protocol does not state that %s leaves a cell valid; a campaign that "+
				"invalidated it would discard the cells that report a null result, which is selecting on the "+
				"outcome", want)
		}
	}
	for _, r := range p.InvalidatesACell {
		if slices.Contains(p.DoesNotInvalidateACell, r) {
			return fmt.Errorf("%q appears in both invalidation lists; a cell's validity would then depend on "+
				"which list was consulted first", r)
		}
	}
	return nil
}

// validateQualification refuses an arm whose registered evidence would not establish that it is the arm it says.
//
// The two arms are qualified by different kinds of evidence, and that asymmetry is registered rather than
// accidental: the treatment's preference is predicted, the reference's is not, because the default plugin set
// cannot be enumerated in this repository and the scheduler will not state its effective configuration without
// a credential this study has not registered.
func (a ProtocolArm) validateQualification() error {
	q := a.Qualification
	if !Arm(a.Name).InstallsSchedulerConfig() {
		if !slices.Contains(q.SchedulerArgsMustNotContain, "--config") {
			return fmt.Errorf("arm %s does not require --config to be absent from the scheduler's arguments; "+
				"that absence is the observable that distinguishes it from the treatment, and it is observable "+
				"without a credential", a.Name)
		}
		if !q.ProfileFileMustBeAbsent {
			return fmt.Errorf("arm %s does not require the profile file to be absent; a stale file in a reused "+
				"directory is the quietest way for this arm to become the other one", a.Name)
		}
		if !q.DemandMustSchedule {
			return fmt.Errorf("arm %s does not require demand to schedule; without that, a reference whose "+
				"scheduler was broken would strand everything and read as a result", a.Name)
		}
		if q.ScoringStrategy != "" || len(q.ScoringResources) > 0 {
			return fmt.Errorf("arm %s registers scoring evidence (strategy %q, %d resource(s)); the reference "+
				"installs no configuration, so there is no scoring of its to qualify",
				a.Name, q.ScoringStrategy, len(q.ScoringResources))
		}
		return nil
	}
	if !q.CheckTreatmentMustReportApplied {
		return fmt.Errorf("arm %s does not require check-treatment to report applied; the treatment silently "+
			"not applying is the failure that reports identical arms as a null result", a.Name)
	}
	if q.ScoringStrategy != MostAllocated {
		return fmt.Errorf("arm %s registers scoring strategy %q; the arm is named for %s and a name that "+
			"disagrees with the configuration it installs misdescribes every cell it runs",
			a.Name, q.ScoringStrategy, MostAllocated)
	}
	// Through the instrument's own guard, so a resource list that omits the GPU is refused here for the same
	// reason it is refused there -- rather than by a second, weaker copy of that check written for this file.
	profile := SchedulerProfile{
		Strategy:      q.ScoringStrategy,
		Resources:     q.ScoringResources,
		SchedulerName: GPUAware(q.ScoringStrategy).SchedulerName,
	}
	if err := profile.Validate(); err != nil {
		return fmt.Errorf("arm %s registers a profile the instrument would refuse: %w", a.Name, err)
	}
	return nil
}

// Layout is the protocol's worker capacities in the form the renderer and the layout check use.
func (p Protocol) Layout() NodeLayout { return NodeLayout(p.NodeLayout.Workers) }

// CheckMembership refuses a census whose demand ledger is not exactly the protocol's first k submissions.
//
// This is the check that closes the hole `Census.Settled` leaves open. Settled is a boolean the run operator
// sets, not a barrier that was observed, and the reservation balance cannot catch a submission omitted from the
// ledger entirely -- a ledger missing a row balances perfectly well. So membership is judged against this file,
// which is frozen independently of the run, identity by identity and in order.
//
// Requests are compared too. A ledger that carries the right names with the wrong requests would satisfy a
// membership check that only looked at names, and the requests are what the stranding figure is computed from.
func (p Protocol) CheckMembership(step int, c Census) error {
	if step < 1 || step > len(p.Submissions) {
		return fmt.Errorf("step %d is outside the registered sequence of %d submissions; a census at an "+
			"unregistered step is not a census this campaign asked for", step, len(p.Submissions))
	}
	want := p.Submissions[:step]
	if len(c.Submissions) != len(want) {
		return fmt.Errorf("the ledger at step %d holds %d submission(s) and the protocol registers %d by then "+
			"(%s); a missing row balances the reservation check perfectly and would pass it",
			step, len(c.Submissions), len(want), protocolIDs(want))
	}
	for i, w := range want {
		got := c.Submissions[i]
		if got.Name != w.ID {
			return fmt.Errorf("position %d of the ledger at step %d is %q and the protocol registers %q; the "+
				"sequence is fixed before any arm runs and a reordered ledger is a different sequence",
				i+1, step, got.Name, w.ID)
		}
		if got.Request != w.Request {
			return fmt.Errorf("submission %s requests %d in the ledger and %d in the protocol; the stranding "+
				"figure is computed from the request, so a ledger that differs here reports a different study",
				w.ID, got.Request, w.Request)
		}
		if got.Disposition == DispositionUnobserved {
			return fmt.Errorf("submission %s carries no observed disposition at step %d; a census with any "+
				"unobserved submission is invalid", w.ID, step)
		}
	}
	return nil
}

func protocolIDs(subs []ProtocolSubmission) string {
	ids := make([]string, 0, len(subs))
	for _, s := range subs {
		ids = append(ids, s.ID)
	}
	return strings.Join(ids, ", ")
}

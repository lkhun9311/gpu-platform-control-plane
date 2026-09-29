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
	"sort"
	"strings"
)

// ScoringStrategy is the NodeResourcesFit scoring type an arm asks the scheduler for.
//
// The two values are upstream kube-scheduler names rather than this study's own vocabulary, and they are
// spelled exactly as the scheduler spells them: a typo here produces a configuration the scheduler rejects at
// startup, which is a loud failure, but a typo in the RESOURCE list below produces one it accepts and ignores.
type ScoringStrategy string

const (
	// LeastAllocated spreads: it scores a node higher the more of the named resources remain free.
	LeastAllocated ScoringStrategy = "LeastAllocated"
	// MostAllocated packs: it scores a node higher the more of the named resources are already taken.
	MostAllocated ScoringStrategy = "MostAllocated"
)

// GPUResourceName is the extended resource the fake device plugin advertises.
const GPUResourceName = "nvidia.com/gpu"

// SchedulerKubeconfigPath is where kubeadm puts the scheduler's credentials on a control-plane node.
//
// It is a constant of the kubeadm layout rather than a choice of this study's, and it is named here because a
// KubeSchedulerConfiguration that omits it leaves the scheduler unable to reach the API server at all.
const SchedulerKubeconfigPath = "/etc/kubernetes/scheduler.conf"

// Arm is which of the study's two configurations a run installs, stated explicitly.
//
// The registration's amendment offered two ways to define the reference and chose one: "the reference is the
// untouched default and the treatment is *the whole configuration change* including the resource list". The
// instrument implemented the other branch for four PRs -- GPUAware was the only constructor, so both arms were
// GPU-aware and an unconfigured scheduler could not be expressed at all. This type is the choice made sayable.
//
// A mode rather than a nil profile or an empty resource list. An absent value has to mean "nobody said", never
// "untouched": Validate() refuses a profile whose scoring list omits nvidia.com/gpu precisely because that is
// the treatment-is-inert failure, and letting emptiness mean the reference would turn that guard into a
// constructor for it.
type Arm string

const (
	// ArmUnset is the zero value and is refused. Neither arm may be reached by defaulting.
	ArmUnset Arm = ""
	// ArmUntouched installs no scheduler configuration at all: the scheduler the pinned node image ships,
	// governed by its own defaults. It is the reference the amendment chose.
	//
	// "Untouched" is scoped to the SCHEDULER CONFIGURATION. The cluster still has this study's deliberate
	// worker capacities and its fake device plugins -- those are the environment both arms share, not part of
	// the treatment.
	ArmUntouched Arm = "S-default"
	// ArmConfigured installs the registered GPU-aware profile. The contrast against ArmUntouched measures the
	// whole configuration change -- the mount, the resource list and the strategy together -- and therefore
	// cannot attribute a difference to MostAllocated alone. That narrower attribution needs its own comparison.
	ArmConfigured Arm = "S-gpu-most"
)

// Validate refuses an arm that was defaulted into rather than chosen.
func (a Arm) Validate() error {
	switch a {
	case ArmUntouched, ArmConfigured:
		return nil
	case ArmUnset:
		return fmt.Errorf("no arm was named; %s and %s differ in what the run installs and there is no "+
			"default arm to fall back to", ArmUntouched, ArmConfigured)
	default:
		return fmt.Errorf("arm %q is neither %s nor %s; the first campaign registers exactly those two",
			a, ArmUntouched, ArmConfigured)
	}
}

// InstallsSchedulerConfig says whether this arm supplies a KubeSchedulerConfiguration.
func (a Arm) InstallsSchedulerConfig() bool { return a == ArmConfigured }

// ArmProfile pairs an arm with the profile it installs, and refuses the combinations that would misdescribe it.
//
// The untouched arm must carry NO profile content. Accepting a strategy or a resource list there would let a
// run record itself as the reference while installing something, which is the same class of defect as a
// treatment that silently does not apply -- read from the other end.
type ArmProfile struct {
	Arm Arm
	// Profile is meaningful only for ArmConfigured and must be the zero value for ArmUntouched.
	Profile SchedulerProfile
}

// ConfiguredArm is the treatment: the registered GPU-aware profile at the given strategy.
func ConfiguredArm(s ScoringStrategy) ArmProfile {
	return ArmProfile{Arm: ArmConfigured, Profile: GPUAware(s)}
}

// UntouchedArm is the reference: no scheduler configuration of this study's.
func UntouchedArm() ArmProfile { return ArmProfile{Arm: ArmUntouched} }

// Validate refuses a pairing that would render a cluster the run could not honestly describe.
func (ap ArmProfile) Validate() error {
	if err := ap.Arm.Validate(); err != nil {
		return err
	}
	if ap.Arm == ArmUntouched {
		// Field by field, because SchedulerProfile holds a slice and Go will not compare it. Naming the three
		// fields also means a field added later is a compile-time reminder to decide whether the reference may
		// carry it -- a `!= empty` comparison would have silently accepted the new one.
		if ap.Profile.Strategy != "" || len(ap.Profile.Resources) > 0 || ap.Profile.SchedulerName != "" {
			return fmt.Errorf("arm %s carries scheduler profile content (strategy %q, %d resource(s), "+
				"schedulerName %q); the reference installs no configuration, and a run that recorded itself as "+
				"the reference while installing one would misdescribe its own treatment", ArmUntouched,
				ap.Profile.Strategy, len(ap.Profile.Resources), ap.Profile.SchedulerName)
		}
		return nil
	}
	return ap.Profile.Validate()
}

// SchedulerProfile is everything about the scheduler that an arm freezes before it runs.
//
// The amendment to the registration requires the complete resource list, the weights, the scheduler version and
// the pods' schedulerName to be registered rather than assumed, for one reason: NodeResourcesFit scores **cpu
// and memory** by default. Selecting MostAllocated without naming nvidia.com/gpu activates the named strategy
// and packs nothing, so three arms report the same number and it reads as a null result rather than as an
// unapplied treatment.
type SchedulerProfile struct {
	// Strategy is the NodeResourcesFit scoring type.
	Strategy ScoringStrategy
	// Resources are the resource names the strategy scores over, with their weights. The study's whole claim
	// rests on GPUResourceName being present here.
	Resources []ResourceWeight
	// SchedulerName is the value pods must carry in spec.schedulerName for this profile to govern them.
	SchedulerName string
}

// ResourceWeight is one entry of the scoring strategy's resource list.
type ResourceWeight struct {
	Name   string
	Weight int
}

// GPUAware builds the profile an arm of this study uses: the given strategy, scoring over the GPU resource.
//
// cpu and memory are deliberately absent rather than carried along at weight zero. A zero-weight entry is
// accepted by the scheduler and contributes nothing, so it would be indistinguishable in behaviour from the
// list below while suggesting to a reader that the study scores over three resources. What the arms differ by
// has to be readable from this function.
func GPUAware(s ScoringStrategy) SchedulerProfile {
	return SchedulerProfile{
		Strategy:      s,
		Resources:     []ResourceWeight{{Name: GPUResourceName, Weight: 1}},
		SchedulerName: "default-scheduler",
	}
}

// Validate refuses a profile that would run without the study's treatment actually applying.
//
// Every refusal here is a case that the scheduler itself ACCEPTS. That is the point: a configuration the
// scheduler rejects fails loudly at cluster creation, and this function exists for the ones that do not.
func (p SchedulerProfile) Validate() error {
	if p.Strategy != LeastAllocated && p.Strategy != MostAllocated {
		return fmt.Errorf("scoring strategy %q is neither %s nor %s; this study compares those two and a third "+
			"value would be an arm nothing registered", p.Strategy, LeastAllocated, MostAllocated)
	}
	if len(p.Resources) == 0 {
		return fmt.Errorf("the scoring strategy names no resources, so NodeResourcesFit falls back to its "+
			"default of cpu and memory and %s is never scored", GPUResourceName)
	}
	found := false
	for _, r := range p.Resources {
		if r.Name == GPUResourceName {
			if r.Weight <= 0 {
				return fmt.Errorf("%s carries weight %d; a non-positive weight contributes nothing to the "+
					"score, so the treatment would be configured and inert", GPUResourceName, r.Weight)
			}
			found = true
		}
		if r.Weight < 0 {
			return fmt.Errorf("resource %q carries a negative weight %d", r.Name, r.Weight)
		}
	}
	if !found {
		return fmt.Errorf("the scoring resource list does not name %s (it names %s); the strategy would be "+
			"applied to resources this study does not vary, which is the failure mode that reports three "+
			"identical arms as a null result", GPUResourceName, p.resourceNames())
	}
	if p.SchedulerName == "" {
		return fmt.Errorf("no schedulerName is registered; pods that name a different scheduler are not " +
			"governed by this profile at all and their placement would be evidence about something else")
	}
	return nil
}

func (p SchedulerProfile) resourceNames() string {
	names := make([]string, 0, len(p.Resources))
	for _, r := range p.Resources {
		names = append(names, r.Name)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// KubeSchedulerConfigurationYAML renders the profile as the upstream config kind the scheduler reads.
//
// Rendered rather than kept as a checked-in file, because the file and the Go value would then be two
// statements of one fact and nothing would compare them -- the shape this repository has been bitten by more
// than once. Validate() is called here rather than being left to the caller, so an invalid profile cannot reach
// a cluster through this path at all.
func (p SchedulerProfile) KubeSchedulerConfigurationYAML() (string, error) {
	if err := p.Validate(); err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("apiVersion: kubescheduler.config.k8s.io/v1\n")
	b.WriteString("kind: KubeSchedulerConfiguration\n")
	// clientConnection is not optional, and leaving it out does not degrade the scheduler -- it stops it.
	//
	// Measured, not read: the first cluster this renderer built came up with the profile mounted correctly and
	// the scheduler crash-looping eight times with `Neither --kubeconfig nor --master was specified`. kubeadm
	// passes BOTH --config and --kubeconfig, and kube-scheduler ignores the flag once --config is given: the
	// kubeconfig has to come from inside the file. Nothing scheduled after that, so kindnet stayed Pending,
	// every node stayed NotReady, and the device plugins that depend on them looked like the failure.
	//
	// That is worse than the silent-treatment failure this study is arranged around. A treatment that does not
	// apply produces arms that agree; a treatment that removes the scheduler produces a cluster where nothing
	// runs and the first thing a reader blames is whatever they were installing at the time.
	fmt.Fprintf(&b, "clientConnection:\n  kubeconfig: %s\n", SchedulerKubeconfigPath)
	b.WriteString("profiles:\n")
	fmt.Fprintf(&b, "  - schedulerName: %s\n", p.SchedulerName)
	b.WriteString("    pluginConfig:\n")
	b.WriteString("      - name: NodeResourcesFit\n")
	b.WriteString("        args:\n")
	b.WriteString("          scoringStrategy:\n")
	fmt.Fprintf(&b, "            type: %s\n", p.Strategy)
	b.WriteString("            resources:\n")
	for _, r := range p.Resources {
		fmt.Fprintf(&b, "              - name: %s\n", r.Name)
		fmt.Fprintf(&b, "                weight: %d\n", r.Weight)
	}
	return b.String(), nil
}

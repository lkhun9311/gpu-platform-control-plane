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

package queuelab

import "fmt"

// JobUIDLabelKey is Kueue's label on a Workload carrying the owning Job's UID (kueue.x-k8s.io/job-uid). The
// collector reads it into ObservedObject.JobUIDLabel, and the join cross-checks it against the
// ownerReference so a Workload cannot be attributed to a Job it merely happens to sit beside.
const JobUIDLabelKey = "kueue.x-k8s.io/job-uid"

// ObservedObject is the minimal identity and ownership a collector extracts from a watched object, so the
// join can be unit-tested without a live API server.
type ObservedObject struct {
	// Kind is "MLTrainingJob" | "Job" | "Workload" | "Pod".
	Kind string
	// Name is the object's own name; for an MLTrainingJob it IS the trace job name.
	Name string
	// UID is the object's UID, the immutable attempt/generation identity the ledger keys on.
	UID string
	// OwnerUIDs are the object's ownerReferences' UIDs, walked up toward the root MLTrainingJob.
	OwnerUIDs []string
	// JobUIDLabel is a Workload's kueue.x-k8s.io/job-uid value (empty for other kinds); it must equal the
	// owning Job's UID or the chain is inconsistent.
	JobUIDLabel string
}

// Object kinds the join understands.
const (
	kindMLTrainingJob = "MLTrainingJob"
	kindJob           = "Job"
	kindWorkload      = "Workload"
	kindPod           = "Pod"
)

// ResolveTraceJobs attributes every observed Job, Workload, and Pod to the trace job (MLTrainingJob) it
// descends from, by walking ownership up to the root MLTrainingJob whose name is the trace row name.
//
// It returns objectUID -> trace job name for EVERY input object. It errors on any object that does not
// resolve to exactly one MLTrainingJob, or whose Kueue job-uid label disagrees with its owning Job, because
// a name-only join would silently merge two generations of a recreated object into one timeline; the
// ledger must key on this UID-validated attribution, not on display names.
func ResolveTraceJobs(objs []ObservedObject) (map[string]string, error) {
	byUID := make(map[string]ObservedObject, len(objs))
	for _, o := range objs {
		if o.UID == "" {
			return nil, fmt.Errorf("%s %q has no UID", o.Kind, o.Name)
		}
		if _, dup := byUID[o.UID]; dup {
			return nil, fmt.Errorf("duplicate object UID %q", o.UID)
		}
		byUID[o.UID] = o
	}

	name := map[string]string{}  // objectUID -> trace job name
	jobUIDs := map[string]bool{} // UIDs known to be Jobs, for the Workload/Pod cross-check

	// Roots: an MLTrainingJob's own name is the trace job name.
	for _, o := range objs {
		if o.Kind == kindMLTrainingJob {
			name[o.UID] = o.Name
		}
	}
	// Jobs descend directly from an MLTrainingJob.
	for _, o := range objs {
		if o.Kind != kindJob {
			continue
		}
		parent, err := soleOwnerName(o, name)
		if err != nil {
			return nil, err
		}
		name[o.UID] = parent
		jobUIDs[o.UID] = true
	}
	// Workloads and Pods descend from a Job.
	for _, o := range objs {
		switch o.Kind {
		case kindMLTrainingJob, kindJob:
			continue
		case kindWorkload, kindPod:
		default:
			return nil, fmt.Errorf("unknown object kind %q for %q", o.Kind, o.Name)
		}
		parent, err := soleOwnerNameAmong(o, name, jobUIDs)
		if err != nil {
			return nil, err
		}
		if o.Kind == kindWorkload {
			owningJobUID := soleOwnerUIDAmong(o, jobUIDs)
			if o.JobUIDLabel != owningJobUID {
				return nil, fmt.Errorf("workload %q job-uid label %q disagrees with owning Job UID %q", o.Name, o.JobUIDLabel, owningJobUID)
			}
		}
		name[o.UID] = parent
	}
	return name, nil
}

// soleOwnerName returns the single trace job name reachable through the object's owners, erroring on none
// or more than one.
func soleOwnerName(o ObservedObject, name map[string]string) (string, error) {
	var found string
	matches := 0
	for _, uid := range o.OwnerUIDs {
		if n, ok := name[uid]; ok {
			found = n
			matches++
		}
	}
	if matches != 1 {
		return "", fmt.Errorf("%s %q resolves to %d owning trace jobs, want exactly 1", o.Kind, o.Name, matches)
	}
	return found, nil
}

// soleOwnerNameAmong is soleOwnerName restricted to owners that are known Jobs, so a Workload or Pod is
// attributed only through its owning Job, not through any other resolvable owner.
func soleOwnerNameAmong(o ObservedObject, name map[string]string, jobUIDs map[string]bool) (string, error) {
	var found string
	matches := 0
	for _, uid := range o.OwnerUIDs {
		if jobUIDs[uid] {
			found = name[uid]
			matches++
		}
	}
	if matches != 1 {
		return "", fmt.Errorf("%s %q resolves to %d owning Jobs, want exactly 1", o.Kind, o.Name, matches)
	}
	return found, nil
}

// soleOwnerUIDAmong returns the single owning Job UID (the caller has already verified exactly one exists).
func soleOwnerUIDAmong(o ObservedObject, jobUIDs map[string]bool) string {
	for _, uid := range o.OwnerUIDs {
		if jobUIDs[uid] {
			return uid
		}
	}
	return ""
}

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

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// sleeperImage is the CPU-only image the trace jobs run, pinned by digest.
//
// The review caught that a mutable tag (busybox:1.36) lets the image drift between runs, so the same study
// re-run months later could execute different bytes; pinning the multi-arch manifest-list digest freezes
// exactly what runs while still resolving on whatever architecture the kind node uses.
const sleeperImage = "busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"

// localQueueName is the deterministic LocalQueue name a tenant's jobs are admitted through.
//
// It must match the name BuildFixtures uses for that tenant's LocalQueue, so a submitted job lands in the
// queue whose policy variant is under test.
func localQueueName(tenant string) string {
	return "ql-" + tenant
}

// RenderMLTrainingJob turns one immutable trace row into the MLTrainingJob to submit into namespace.
//
// The sleeper is CPU-only busybox that just holds its quota for the row's duration, so the whole study runs
// on kind with fake nvidia.com/gpu capacity and no real GPU; the point under test is Kueue admission and
// reclaim, not GPU computation.
//
// Parallelism and completions are pinned to 1 so a row's gpuCount is exactly its demand (one Pod), which the
// occupancy and demand-satisfaction accounting assumes.
func RenderMLTrainingJob(row TrainingTraceRow, namespace string) *platformv1.MLTrainingJob {
	return &platformv1.MLTrainingJob{
		ObjectMeta: metav1.ObjectMeta{
			Name:      row.Name,
			Namespace: namespace,
			// The trace index and tenant are stamped as labels so the list/watch collector can join an
			// observed object back to its trace row without parsing the name.
			Labels: map[string]string{
				"queuelab.gpu-platform/trace-index": fmt.Sprintf("%d", row.Index),
				"queuelab.gpu-platform/tenant":      row.Tenant,
			},
		},
		Spec: platformv1.MLTrainingJobSpec{
			Queue:       localQueueName(row.Tenant),
			Image:       sleeperImage,
			Command:     []string{"sh", "-c", fmt.Sprintf("sleep %d", row.DurationSec)},
			GPUCount:    int32(row.GPUCount),
			Parallelism: 1,
			Completions: 1,
		},
	}
}

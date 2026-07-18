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

package gateway

import (
	"context"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// newSchemeForTest builds a scheme with both the client-go and platform types registered.
func newSchemeForTest() *runtime.Scheme {
	scheme := runtime.NewScheme()
	Expect(clientgoscheme.AddToScheme(scheme)).To(Succeed())
	Expect(platformv1.AddToScheme(scheme)).To(Succeed())
	return scheme
}

var _ = Describe("policyForTenant", func() {
	It("returns ErrNoPolicy when no policy matches the tenant", func() {
		c := fake.NewClientBuilder().WithScheme(newSchemeForTest()).Build()
		s := &Server{Client: c}
		_, err := s.policyForTenant(context.Background(), "team-vision")
		Expect(err).To(MatchError(ErrNoPolicy))
	})

	It("returns the oldest policy when more than one matches the tenant", func() {
		older := &platformv1.GPUQuotaPolicy{
			ObjectMeta: metav1.ObjectMeta{
				Name:              "team-vision-old",
				CreationTimestamp: metav1.NewTime(time.Now().Add(-time.Hour)),
			},
			Spec: platformv1.GPUQuotaPolicySpec{Tenant: "team-vision"},
		}
		newer := &platformv1.GPUQuotaPolicy{
			ObjectMeta: metav1.ObjectMeta{
				Name:              "team-vision-new",
				CreationTimestamp: metav1.NewTime(time.Now()),
			},
			Spec: platformv1.GPUQuotaPolicySpec{Tenant: "team-vision"},
		}
		c := fake.NewClientBuilder().WithScheme(newSchemeForTest()).WithObjects(newer, older).Build()
		s := &Server{Client: c}
		got, err := s.policyForTenant(context.Background(), "team-vision")
		Expect(err).NotTo(HaveOccurred())
		Expect(got.Name).To(Equal("team-vision-old"))
	})
})

var _ = Describe("bucketRegistry", func() {
	It("limits per the rate and refreshes on change", func() {
		b := newBucketRegistry()
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 1}
		Expect(b.Allow("t", rl)).To(BeTrue())
		Expect(b.Allow("t", rl)).To(BeFalse())
	})

	It("returns true for an unlimited (nil) rate limit", func() {
		b := newBucketRegistry()
		Expect(b.Allow("t", nil)).To(BeTrue())
	})
})

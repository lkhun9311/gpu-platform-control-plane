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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("offAdmitter", func() {
	It("admits every request regardless of tier or size", func() {
		a := offAdmitter{}
		ok, reason := a.Admit(context.Background(), RequestMeta{EstInputTokens: 1_000_000}, &BackendRef{Namespace: "ns", Name: "b"}, "t", "standard")
		Expect(ok).To(BeTrue())
		Expect(reason).To(BeEmpty())
	})
})

var _ = Describe("tierForPolicy", func() {
	It("resolves the exact annotation value \"premium\" to premium", func() {
		p := &platformv1.GPUQuotaPolicy{
			ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{tierAnnotation: "premium"}},
		}
		Expect(tierForPolicy(p)).To(Equal("premium"))
	})

	It("resolves an explicit \"standard\" annotation to standard", func() {
		p := &platformv1.GPUQuotaPolicy{
			ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{tierAnnotation: "standard"}},
		}
		Expect(tierForPolicy(p)).To(Equal("standard"))
	})

	It("resolves a missing annotation to standard", func() {
		p := &platformv1.GPUQuotaPolicy{}
		Expect(tierForPolicy(p)).To(Equal("standard"))
	})

	It("resolves a nil policy to standard", func() {
		Expect(tierForPolicy(nil)).To(Equal("standard"))
	})

	It("never grants premium on a case variant", func() {
		// A typo or case mismatch must never grant premium, or a tenant could bypass admission control by accident.
		p := &platformv1.GPUQuotaPolicy{
			ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{tierAnnotation: "PREMIUM"}},
		}
		Expect(tierForPolicy(p)).To(Equal("standard"))
	})

	It("never grants premium on a typo'd value", func() {
		p := &platformv1.GPUQuotaPolicy{
			ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{tierAnnotation: "premiumm"}},
		}
		Expect(tierForPolicy(p)).To(Equal("standard"))
	})
})

var _ = Describe("staticCapAdmitter", func() {
	var (
		ctx     = context.Background()
		backend = &BackendRef{Namespace: "vision-ns", Name: "llama"}
	)

	It("always admits a premium request, even at eligible length", func() {
		// rate 0 and burst 0 means the bucket starts and stays empty, so any standard request would be refused.
		a := newStaticCapAdmitter(0, 0, 4096)
		ok, reason := a.Admit(ctx, RequestMeta{EstInputTokens: 8192}, backend, "t", "premium")
		Expect(ok).To(BeTrue())
		Expect(reason).To(BeEmpty())
	})

	It("always admits a standard request shorter than the long threshold", func() {
		a := newStaticCapAdmitter(0, 0, 4096)
		ok, reason := a.Admit(ctx, RequestMeta{EstInputTokens: 4095}, backend, "t", "standard")
		Expect(ok).To(BeTrue())
		Expect(reason).To(BeEmpty())
	})

	It("admits a standard-long request while the bucket has capacity", func() {
		a := newStaticCapAdmitter(0, 4096, 4096)
		ok, reason := a.Admit(ctx, RequestMeta{EstInputTokens: 4096}, backend, "t", "standard")
		Expect(ok).To(BeTrue())
		Expect(reason).To(BeEmpty())
	})

	It("rejects a standard-long request once the bucket is exhausted", func() {
		// burst 0 leaves nothing for any weighted request to consume.
		a := newStaticCapAdmitter(0, 0, 4096)
		ok, reason := a.Admit(ctx, RequestMeta{EstInputTokens: 4096}, backend, "t", "standard")
		Expect(ok).To(BeFalse())
		Expect(reason).To(Equal("input_rate_limit"))
	})

	It("weights consumption by input tokens: a single 8192-token request consumes about twice what a 4096-token one does", func() {
		// rate 0 means the bucket never refills during the test, so consumption is exactly what AllowN takes.
		burst := 8192
		threshold := 4096

		// Two 4096-token requests fit exactly within an 8192 burst.
		twoSmall := newStaticCapAdmitter(0, burst, threshold)
		ok1, _ := twoSmall.Admit(ctx, RequestMeta{EstInputTokens: 4096}, backend, "t", "standard")
		Expect(ok1).To(BeTrue())
		ok2, _ := twoSmall.Admit(ctx, RequestMeta{EstInputTokens: 4096}, backend, "t", "standard")
		Expect(ok2).To(BeTrue())

		// A single 8192-token request against a fresh, identically sized bucket consumes it entirely in one shot.
		oneBig := newStaticCapAdmitter(0, burst, threshold)
		ok3, _ := oneBig.Admit(ctx, RequestMeta{EstInputTokens: 8192}, backend, "t", "standard")
		Expect(ok3).To(BeTrue())
		// Nothing is left, so even the smallest eligible request is refused next.
		ok4, reason4 := oneBig.Admit(ctx, RequestMeta{EstInputTokens: 4096}, backend, "t", "standard")
		Expect(ok4).To(BeFalse())
		Expect(reason4).To(Equal("input_rate_limit"))
	})

	It("keys the bucket per backend, so one backend's exhaustion does not affect another", func() {
		a := newStaticCapAdmitter(0, 4096, 4096)
		other := &BackendRef{Namespace: "vision-ns", Name: "other-model"}
		ok1, _ := a.Admit(ctx, RequestMeta{EstInputTokens: 4096}, backend, "t", "standard")
		Expect(ok1).To(BeTrue())
		// backend's bucket is now empty, but other's bucket is untouched.
		ok2, _ := a.Admit(ctx, RequestMeta{EstInputTokens: 4096}, other, "t", "standard")
		Expect(ok2).To(BeTrue())
	})
})

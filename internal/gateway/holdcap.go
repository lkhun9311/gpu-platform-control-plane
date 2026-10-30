package gateway

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// AdmissionHoldCap is serial-prefill on a backend whose InferenceDeployment asks for HoldCap and whose controller reports the engine's prefill cap in force.
// It is never a value of --admission-mode: a backend selects it, and the process-wide mode cannot change or disable it.
const AdmissionHoldCap AdmissionMode = "hold-cap"

const (
	// reasonHoldCapRequiresStream refuses a standard request that does not stream, because the hold is released by the first content event and a non-streaming response has none until it is complete.
	reasonHoldCapRequiresStream = "holdcap_requires_stream"
	// reasonHoldCapSingleChoice refuses a standard request asking for other than one choice, because each choice is its own prefill and the first content event of one says nothing about the others.
	reasonHoldCapSingleChoice = "holdcap_single_choice"
)

// holdCapAdmitter admits HoldCap backends by serial-prefill, each with the hold from its own spec.
type holdCapAdmitter struct{ s *serialPrefillAdmitter }

// newHoldCapAdmitter builds the admitter with no hold of its own, because every waiter takes its backend's.
func newHoldCapAdmitter() holdCapAdmitter { return holdCapAdmitter{s: newSerialPrefillAdmitter(0)} }

// Admit refuses, as serial-prefill's does: the server reaches it only through Reserve.
func (holdCapAdmitter) Admit(context.Context, RequestMeta, *BackendRef, string, string) (bool, string) {
	return false, reasonReservationRequired
}

// Reserve holds a standard request for its backend's turn, for at most that backend's hold.
func (h holdCapAdmitter) Reserve(ctx context.Context, _ RequestMeta, backend *BackendRef, tenant, tier string) (*reservation, bool, string) {
	return h.s.reserve(ctx, backend, tenant, tier, backend.MaxHold)
}

// holdCapTargets is the candidates a request may be sent to once HoldCap is in play.
// A HoldCap head is served only as itself, premium included, because its admission was decided for its engine and no other.
// A HoldCap backend in the tail is dropped, because entering it by fallback would reach the capped engine without its hold.
// It is dropped rather than cut at, so a plain backend after it still serves; the cost is that a dead plain head never falls back into a HoldCap deployment.
func holdCapTargets(targets []*BackendRef) []*BackendRef {
	if len(targets) > 0 && targets[0].Admission == AdmissionHoldCap {
		return targets[:1]
	}
	kept := make([]*BackendRef, 0, len(targets))
	for _, t := range targets {
		if t.Admission != AdmissionHoldCap {
			kept = append(kept, t)
		}
	}
	return kept
}

// bindsPriority decides whether a request carries its tier's engine priority.
//
// -bind-priority asks for it everywhere. A HoldCap backend's engine is rendered with priority scheduling, so its
// requests carry the tier whatever the flag says.
// So does a request whose every reachable backend is a rendered engine, in any mode: those engines schedule by
// priority, and without a bound tier every request arrives at the same one and the policy does nothing. The hold-cap
// product study measured what that costs: the product's Off left the premium tail at 6 to 10 s where the lab's off,
// which bound the tier, gave about 1.5 s (hack/eks-serve/holdcap-study/runs/).
// Every backend, not the first, because a request may fall back, and a backend the controller does not render may
// schedule first-come and refuse a priority it was not built for.
func (s *Server) bindsPriority(holdCap bool, targets []*BackendRef) bool {
	return s.bindPriority || holdCap || allPriorityScheduled(targets)
}

// allPriorityScheduled reports whether every backend a request may reach schedules by priority; false for none.
func allPriorityScheduled(targets []*BackendRef) bool {
	for _, t := range targets {
		if !t.PriorityScheduled {
			return false
		}
	}
	return len(targets) > 0
}

// anyPriorityScheduled reports whether some backend a request may reach schedules by priority.
func anyPriorityScheduled(targets []*BackendRef) bool {
	for _, t := range targets {
		if t.PriorityScheduled {
			return true
		}
	}
	return false
}

// admissionFor is the admitter and mode a request's head backend selects, and whether that is HoldCap.
// A HoldCap backend replaces the process-wide mode for its requests, and the two never stack, because the cap was measured with serial-prefill alone.
func (s *Server) admissionFor(targets []*BackendRef) (Admitter, AdmissionMode, bool) {
	if len(targets) > 0 && targets[0].Admission == AdmissionHoldCap {
		s.holdCapOnce.Do(func() { s.holdCap = newHoldCapAdmitter() })
		return s.holdCap, AdmissionHoldCap, true
	}
	admitter := s.admitter
	if admitter == nil {
		// SetAdmitter was never called, so behave exactly as if the guard did not exist.
		admitter = offAdmitter{}
	}
	mode := s.mode
	if mode == "" {
		mode = AdmissionOff
	}
	return admitter, mode, false
}

// holdCapShapeRefusal is the reason a request cannot be held on a HoldCap backend, or empty when it can.
// Premium is never held, so its shape does not matter.
func holdCapShapeRefusal(meta RequestMeta, tier string) string {
	if tier == tierPremium {
		return ""
	}
	if !meta.Stream {
		return reasonHoldCapRequiresStream
	}
	if meta.Choices != 1 {
		return reasonHoldCapSingleChoice
	}
	return ""
}

// refuseHoldCapShape answers 400 to a standard request whose shape the hold cannot time, and reports whether it did.
// It is 400 without Retry-After, unlike an admission refusal, because the same request is refused again however long the client waits.
// It runs before admission, so a refused request never takes a turn on the backend.
func (s *Server) refuseHoldCapShape(w http.ResponseWriter, tenant string, meta RequestMeta, tier string) bool {
	reason := holdCapShapeRefusal(meta, tier)
	if reason == "" {
		return false
	}
	w.Header().Set(HeaderAdmissionReason, reason)
	requests.WithLabelValues(tenant, meta.Model, strconv.Itoa(http.StatusBadRequest)).Inc()
	writeJSONErrorCode(w, http.StatusBadRequest, reason,
		"a standard-tier request to a hold-cap backend must stream and ask for one choice")
	return true
}

// backendAdmissionGateway is the mode label of a backend served by the process-wide mode.
const backendAdmissionGateway = "gateway"

// backendAdmissionListTimeout bounds one scrape's list, so a cache that has not synced cannot hang /metrics.
const backendAdmissionListTimeout = 5 * time.Second

// backendAdmissionCollector publishes, per backend, which admission the gateway applies to it, read from the cache at scrape time.
// The process-wide gauge cannot say this once a backend can choose its own.
// It is computed at scrape time rather than written per request, so a deleted or changed deployment leaves no stale series and two requests cannot race a delete against a set.
type backendAdmissionCollector struct {
	reader client.Reader
	desc   *prometheus.Desc
}

func newBackendAdmissionCollector(reader client.Reader) *backendAdmissionCollector {
	return &backendAdmissionCollector{
		reader: reader,
		desc: prometheus.NewDesc(metricPrefix+"backend_admission_mode",
			"The admission the gateway applies to a backend, as a 1 on its mode label: hold-cap, or gateway for the process-wide mode.",
			[]string{"namespace", "name", "mode"}, nil),
	}
}

// Describe sends the one descriptor this collector emits.
func (c *backendAdmissionCollector) Describe(ch chan<- *prometheus.Desc) { ch <- c.desc }

// Collect lists every InferenceDeployment and labels each by backendAdmission, the same function routing uses, so the gauge cannot disagree with what requests get.
// A failed list emits no series and is logged, rather than failing the whole scrape and hiding every other gateway series with it.
func (c *backendAdmissionCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), backendAdmissionListTimeout)
	defer cancel()
	var list platformv1.InferenceDeploymentList
	if err := c.reader.List(ctx, &list); err != nil {
		log.Log.WithName("gateway").Error(err, "cannot list inferencedeployments for the backend admission gauge")
		return
	}
	for i := range list.Items {
		d := &list.Items[i]
		mode := backendAdmissionGateway
		if m, _ := backendAdmission(d); m == AdmissionHoldCap {
			mode = string(AdmissionHoldCap)
		}
		ch <- prometheus.MustNewConstMetric(c.desc, prometheus.GaugeValue, 1, d.Namespace, d.Name, mode)
	}
}

// RegisterBackendAdmissionMetric adds the per-backend admission gauge to the registry /metrics serves, reading through the server's client.
// It is a method rather than a package-level registration because the collector needs the client, which exists only once main has built the cache.
func (s *Server) RegisterBackendAdmissionMetric() error {
	return metrics.Registry.Register(newBackendAdmissionCollector(s.Client))
}

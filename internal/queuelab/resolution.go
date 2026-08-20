package queuelab

import (
	"sort"
	"time"
)

// stampQuantisationNs is the granularity of the kubelet's own timestamp.
//
// metav1.Time serialises to RFC3339 with SECOND precision, so finishedAt arrives with its nanoseconds
// zeroed. This was checked rather than assumed: every observed value in the recorded runs ends in nine
// zeros. It is a constant here rather than a literal at the point of use because it is a property of the
// apiserver's wire format, not a tuning knob, and a reader who changes it is changing what the harness
// believes about Kubernetes.
const stampQuantisationNs = int64(time.Second)

// minimumSpreadSamples is how many observations it takes before a spread bounds anything.
//
// One sample has a spread of zero, and zero is the most dangerous possible answer: it would let a run
// declare that its intervals are resolved to the quantisation floor on the strength of a single reading
// that had nothing to be spread against.
const minimumSpreadSamples = 2

// ObservationSpread is how finely the intervals reconstructed from a run's events can be read.
//
// Every interval this package reports is a difference of ARRIVAL times — when a watch event reached the
// collector, not when the thing it describes happened. So an interval's error is the DIFFERENCE between its
// two endpoints' lags, and NOT their size. A harness uniformly two seconds behind the cluster measures every
// interval exactly. That is the whole reason FloorNs is built from the spread rather than from MedianNs,
// and it is worth stating because the median is the number a reader reaches for first.
type ObservationSpread struct {
	// Samples is how many stop events carried a kubelet timestamp to compare against.
	Samples int
	// MinNs, MedianNs and MaxNs describe the observed skew. They are a BOUND, not a delivery time: the two
	// stamps come from unsynchronised clocks on different machines and one of them is truncated, so the gap
	// mixes propagation, clock offset and truncation with nothing here able to separate them.
	MinNs    int64
	MedianNs int64
	MaxNs    int64
	// QuantisationNs is the granularity of the stamp the skews were computed against.
	QuantisationNs int64
	// FloorNs is the magnitude below which this run's intervals are not resolved.
	//
	// It is max(MaxNs-MinNs, QuantisationNs), and both terms are load-bearing. The spread bounds how much
	// the two endpoints' lags can differ, which is the error an interval actually carries. The quantisation
	// is a floor UNDER that spread because the skews it was computed from each absorbed up to a second of
	// truncation: a spread that comes out smaller than a second is therefore not evidence of a tighter
	// bound, it is a spread that fits inside the truncation of the values it was measured from.
	//
	// A difference smaller than this is not a small effect. It is an effect this harness cannot see, and no
	// number of repetitions changes that — a resolution limit is not a noise level.
	FloorNs int64
}

// SpreadOf summarises the skew the events carried, or nil when they cannot bound anything.
//
// nil is the honest answer rather than a zero-valued struct, because "no stop reported a kubelet timestamp"
// and "this harness is perfectly prompt" are opposite states and only one of them is good news. A caller
// holding nil knows it has no bound; a caller holding zeros would believe it had the best possible one.
func SpreadOf(events []LifecycleEvent) *ObservationSpread {
	skews := make([]int64, 0, len(events))
	for _, e := range events {
		if e.ObservedSkewNs != nil {
			skews = append(skews, *e.ObservedSkewNs)
		}
	}
	if len(skews) < minimumSpreadSamples {
		return nil
	}
	sort.Slice(skews, func(i, j int) bool { return skews[i] < skews[j] })
	spread := skews[len(skews)-1] - skews[0]
	floor := spread
	if floor < stampQuantisationNs {
		floor = stampQuantisationNs
	}
	return &ObservationSpread{
		Samples:        len(skews),
		MinNs:          skews[0],
		MedianNs:       skews[len(skews)/2],
		MaxNs:          skews[len(skews)-1],
		QuantisationNs: stampQuantisationNs,
		FloorNs:        floor,
	}
}

// Resolves says whether a magnitude is large enough for this run to have seen it.
//
// It is a method rather than a comparison at each call site because the comparison has a direction that is
// easy to invert, and inverting it turns "the harness cannot see this" into "the harness measured this".
// That inversion is not hypothetical: a residual of 0.94 seconds was published from this lab as the control
// plane's own cost while the run's spread ran from 0.4 to 2.4 seconds.
func (s *ObservationSpread) Resolves(magnitudeNs int64) bool {
	if s == nil {
		return false
	}
	if magnitudeNs < 0 {
		magnitudeNs = -magnitudeNs
	}
	return magnitudeNs > s.FloorNs
}

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// serving starts an endpoint that answers with the given metrics body, the way the operator's /metrics does.
func serving(t *testing.T, body string) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// allThree is a body carrying every series this tool derives its numbers from.
const allThree = `# HELP workqueue_depth Current depth of workqueue
workqueue_depth{name="mltrainingjob"} 7
workqueue_adds_total{name="mltrainingjob"} 120
controller_runtime_reconcile_total{controller="mltrainingjob",result="success"} 98
`

func TestThePresentSeriesAreRead(t *testing.T) {
	m, err := readMetrics(serving(t, allThree))
	if err != nil {
		t.Fatalf("readMetrics: %v", err)
	}
	if m.Depth != 7 || m.Adds != 120 || m.Done != 98 {
		t.Errorf("depth/adds/done = %d/%d/%d, want 7/120/98", m.Depth, m.Adds, m.Done)
	}
	if missing := m.missingSeries(); len(missing) != 0 {
		t.Errorf("missingSeries() = %v, want none when all three are served", missing)
	}
}

// TestAnEmptyQueueIsNotAnUnreadEndpoint is the distinction the Saw* fields exist for.
//
// A queue that is genuinely empty reports depth 0, and so does an endpoint that never mentioned the queue.
// Only the first is a measurement, and the verdict this tool prints for the second -- "the queue never held
// anything: this run measured the client, not the operator" -- reads as a finding about the operator.
func TestAnEmptyQueueIsNotAnUnreadEndpoint(t *testing.T) {
	empty := `workqueue_depth{name="mltrainingjob"} 0
workqueue_adds_total{name="mltrainingjob"} 0
controller_runtime_reconcile_total{controller="mltrainingjob"} 0
`
	m, err := readMetrics(serving(t, empty))
	if err != nil {
		t.Fatalf("readMetrics: %v", err)
	}
	if m.Depth != 0 {
		t.Errorf("depth = %d, want 0", m.Depth)
	}
	if missing := m.missingSeries(); len(missing) != 0 {
		t.Errorf("a genuine zero was reported as missing series %v; zero is a value, not an absence", missing)
	}
}

// TestAnEndpointThatNeverMentionsTheQueueIsNamed covers the renamed-metric case.
//
// Mutation that turns this red: drop the Saw* assignment for a family, or have missingSeries return nil.
func TestAnEndpointThatNeverMentionsTheQueueIsNamed(t *testing.T) {
	// A perfectly healthy endpoint serving somebody else's registry.
	other := `go_goroutines 42
workqueue_depth{name="nodehealth"} 3
controller_runtime_reconcile_total{controller="nodehealth"} 11
`
	m, err := readMetrics(serving(t, other))
	if err != nil {
		t.Fatalf("readMetrics should not fail on a 200 that simply lacks our series: %v", err)
	}
	missing := m.missingSeries()
	if len(missing) != 3 {
		t.Fatalf("missingSeries() = %v, want all three named", missing)
	}
	for _, want := range []string{"workqueue_depth", "workqueue_adds_total", "controller_runtime_reconcile_total"} {
		if !strings.Contains(strings.Join(missing, " "), want) {
			t.Errorf("missingSeries() = %v, does not name %s", missing, want)
		}
	}
}

// TestOneAbsentFamilyIsStillNamed keeps the check from being all-or-nothing.
func TestOneAbsentFamilyIsStillNamed(t *testing.T) {
	partial := `workqueue_depth{name="mltrainingjob"} 4
controller_runtime_reconcile_total{controller="mltrainingjob"} 9
`
	m, err := readMetrics(serving(t, partial))
	if err != nil {
		t.Fatalf("readMetrics: %v", err)
	}
	missing := m.missingSeries()
	if len(missing) != 1 || !strings.Contains(missing[0], "workqueue_adds_total") {
		t.Errorf("missingSeries() = %v, want exactly the adds family", missing)
	}
}

// TestAMalformedSampleIsRefusedRatherThanRoundedToZero is the other half of the same defect.
//
// intValue returned 0 for an unparseable value, so a corrupt sample entered the record as a measurement --
// and zero is the most believable number this tool prints.
func TestAMalformedSampleIsRefusedRatherThanRoundedToZero(t *testing.T) {
	corrupt := `workqueue_depth{name="mltrainingjob"} not-a-number
workqueue_adds_total{name="mltrainingjob"} 1
controller_runtime_reconcile_total{controller="mltrainingjob"} 1
`
	if _, err := readMetrics(serving(t, corrupt)); err == nil {
		t.Fatal("a malformed sample was accepted; it would have been recorded as depth 0")
	}
}

func TestIntValueSaysWhenItCouldNotParse(t *testing.T) {
	for _, tc := range []struct {
		line string
		want int
		ok   bool
	}{
		{`workqueue_depth{name="x"} 12`, 12, true},
		{`workqueue_depth{name="x"} 12.0`, 12, true},
		{`workqueue_depth{name="x"} NaN-ish`, 0, false},
		{`no-space-anywhere`, 0, false},
	} {
		got, ok := intValue(tc.line)
		if got != tc.want || ok != tc.ok {
			t.Errorf("intValue(%q) = (%d, %v), want (%d, %v)", tc.line, got, ok, tc.want, tc.ok)
		}
	}
}

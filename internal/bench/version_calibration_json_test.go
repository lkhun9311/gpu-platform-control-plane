package bench

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// TestRungRecordUsesCamelCaseAndReadsBack: rung files share the camelCase of every other artifact, and the strict reader accepts what the writer wrote.
func TestRungRecordUsesCamelCaseAndReadsBack(t *testing.T) {
	want := CalibrationRungRecord{Ordinal: 1, Class: RungStable, Observation: RungObservation{
		OfferedRate: 2, WindowSeconds: 180, StartedDrained: true, Arrivals: 360, Departures: 359,
		OutstandingStart: 1, OutstandingEnd: 2, OutstandingSlopePerSec: 0.01, Failures: 3, UnresolvedAtDrain: 4,
	}}
	data, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"offeredRate", "windowSeconds", "startedDrained", "arrivals", "departures",
		"outstandingStart", "outstandingEnd", "outstandingSlopePerSec", "failures", "unresolvedAtDrain"} {
		if !strings.Contains(string(data), `"`+key+`":`) {
			t.Fatalf("rung record %s lacks %q", data, key)
		}
	}
	// VerifyCalibrationEvidence decodes with DisallowUnknownFields, so a writer/reader mismatch would refuse every rung file.
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var got CalibrationRungRecord
	if err := dec.Decode(&got); err != nil || got != want {
		t.Fatalf("read back %+v err %v, want %+v", got, err, want)
	}
}

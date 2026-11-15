package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestReplayMatchToleranceAcceptsAnEmptyV3Field: a v3 manifest must leave matchTolerance empty, and the replay used to refuse exactly that.
func TestReplayMatchToleranceAcceptsAnEmptyV3Field(t *testing.T) {
	tol, err := replayMatchTolerance(&bench.RunManifest{SchemaVersion: bench.ManifestSchemaV3})
	if err != nil || tol != 0 {
		t.Fatalf("v3 with no tolerance: %v %v, want 0 and no error", tol, err)
	}
}

// TestReplayMatchToleranceKeepsTheEarlierChecks: only an empty v3 field is exempt, so every earlier manifest is held as before.
func TestReplayMatchToleranceKeepsTheEarlierChecks(t *testing.T) {
	for _, c := range []struct {
		schema, tol, want string
	}{
		{bench.ManifestSchemaV2, "", "not a number"},
		{bench.ManifestSchemaV2, "NaN", ""},
		{bench.ManifestSchemaV2, "1.5", ""},
		{bench.ManifestSchemaV3, "abc", "not a number"},
	} {
		_, err := replayMatchTolerance(&bench.RunManifest{SchemaVersion: c.schema, MatchTolerance: c.tol})
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s %q: err %v, want a refusal containing %q", c.schema, c.tol, err, c.want)
		}
	}
	if tol, err := replayMatchTolerance(&bench.RunManifest{SchemaVersion: bench.ManifestSchemaV2, MatchTolerance: "0.05"}); err != nil || tol != 0.05 {
		t.Fatalf("v2 0.05: %v %v", tol, err)
	}
}

// TestApplyStudySamplingPutsTheRegisteredPolicyOnTheWire: the replay is the one place a study's policy reaches the sender.
func TestApplyStudySamplingPutsTheRegisteredPolicyOnTheWire(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer srv.Close()
	for _, c := range []struct {
		study    string
		known    bool
		wantTemp bool
	}{
		{bench.StudyVersionAsync, true, true},
		{bench.StudyVersionAsync, false, false},
		{bench.StudyProspectivePilot, true, false},
	} {
		st, _ := bench.LookupStudy(c.study)
		s := bench.NewHTTPSender(srv.URL, "m", nil, 5*time.Second, bench.SenderConn{MaxIdleConnsPerHost: 1})
		if err := applyStudySampling(s, st, c.known); err != nil {
			t.Fatal(err)
		}
		got = nil
		s.Send(context.Background(), bench.TraceRow{Index: 3, Tenant: "t", PromptLenChars: 40, MaxOutputTokens: 64}, time.Now().UnixNano())
		if _, has := got["temperature"]; has != c.wantTemp {
			t.Errorf("study %s known=%v: body has temperature %v, want %v (body %v)", c.study, c.known, has, c.wantTemp, got)
		}
	}
}

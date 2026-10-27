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
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gpufault"
)

func call(t *testing.T, d *fakeDCGM, method, target string) (int, string) {
	t.Helper()
	w := httptest.NewRecorder()
	d.ServeHTTP(w, httptest.NewRequest(method, target, nil))
	return w.Code, w.Body.String()
}

// The exporter serves the snapshot, not the cache: an injection is introspectable at once and exported only
// after the next collection, which is the lag the study's first hop measures.
func TestFakeDCGMExportsAfterTheNextCollection(t *testing.T) {
	now := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	d := newFakeDCGM("n1", 2, func() time.Time { return now })
	if code, body := call(t, d, http.MethodPost, "/inject?gpu=1&field=230&value=79&offset=900"); code != http.StatusOK {
		t.Fatalf("inject: %d %s", code, body)
	}
	if _, body := call(t, d, http.MethodGet, "/introspect?gpu=1&field=230"); strings.TrimSpace(body) != "79" {
		t.Fatalf("introspect %q", body)
	}
	_, before := call(t, d, http.MethodGet, "/metrics")
	if strings.Contains(before, "} 79") {
		t.Fatalf("exported before a collection:\n%s", before)
	}
	d.collect()
	_, after := call(t, d, http.MethodGet, "/metrics")
	// What the fake serves must be what the operator's parser reads, field for field.
	r, err := gpufault.ParseExposition([]byte(after))
	if err != nil {
		t.Fatalf("the operator's parser refused the fake's output: %v\n%s", err, after)
	}
	a, err := gpufault.Assess(r)
	if err != nil {
		t.Fatal(err)
	}
	if a.Cards != 2 || len(a.Missing) != 0 || a.Fingerprint() != "fake-gpu-1/DCGM_FI_DEV_XID_ERRORS=79" {
		t.Fatalf("assessment %+v", a)
	}
}

// A later injection at the same offset supersedes; an earlier-stamped one is refused, as DCGM would not show it.
func TestFakeDCGMKeepsTheNewestSampleByTimestamp(t *testing.T) {
	now := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	d := newFakeDCGM("n1", 1, func() time.Time { return now })
	call(t, d, http.MethodPost, "/inject?gpu=0&field=311&value=1&offset=900")
	if code, _ := call(t, d, http.MethodPost, "/inject?gpu=0&field=311&value=0&offset=1"); code != http.StatusConflict {
		t.Fatalf("an older-stamped injection was accepted (%d)", code)
	}
	now = now.Add(time.Second)
	if code, body := call(t, d, http.MethodPost, "/inject?gpu=0&field=311&value=0&offset=900"); code != http.StatusOK {
		t.Fatalf("the reset was refused: %d %s", code, body)
	}
	if _, body := call(t, d, http.MethodGet, "/introspect?gpu=0&field=311"); strings.TrimSpace(body) != "0" {
		t.Fatalf("introspect after reset %q", body)
	}
}

func TestFakeDCGMExporterCanBeTakenAway(t *testing.T) {
	d := newFakeDCGM("n1", 1, time.Now)
	if code, _ := call(t, d, http.MethodPost, "/exporter?state=down"); code != http.StatusOK {
		t.Fatalf("down: %d", code)
	}
	if code, _ := call(t, d, http.MethodGet, "/metrics"); code != http.StatusServiceUnavailable {
		t.Fatalf("metrics while down: %d", code)
	}
	// The cache is still there to inject into and read, as a host engine outlives an exporter restart.
	if code, _ := call(t, d, http.MethodGet, "/introspect?gpu=0&field=230"); code != http.StatusOK {
		t.Fatalf("introspect while down: %d", code)
	}
	call(t, d, http.MethodPost, "/exporter?state=up")
	if code, _ := call(t, d, http.MethodGet, "/metrics"); code != http.StatusOK {
		t.Fatalf("metrics back up: %d", code)
	}
	if code, _ := call(t, d, http.MethodPost, "/exporter?state=sideways"); code != http.StatusBadRequest {
		t.Fatalf("a bad state: %d", code)
	}
}

func TestFakeDCGMRefusals(t *testing.T) {
	d := newFakeDCGM("n1", 1, time.Now)
	for target, want := range map[string]int{
		"/inject?gpu=0&field=230&value=79":  http.StatusMethodNotAllowed, // GET
		"/introspect?gpu=0":                 http.StatusBadRequest,
		"/introspect?gpu=3&field=230":       http.StatusNotFound,
		"/introspect?gpu=0&field=999":       http.StatusNotFound,
		"/nothing":                          http.StatusNotFound,
		"/introspect?gpu=zero&field=230":    http.StatusBadRequest,
		"/introspect?gpu=0&field=230&x=1":   http.StatusOK,
		"/metrics":                          http.StatusOK,
		"/health":                           http.StatusOK,
		"/introspect?field=230":             http.StatusBadRequest,
		"/introspect?gpu=0&field=310":       http.StatusOK,
		"/introspect?gpu=0&field=311":       http.StatusOK,
		"/introspect?gpu=-1&field=230":      http.StatusNotFound,
		"/introspect?gpu=0&field=230&gpu=1": http.StatusOK,
	} {
		if code, _ := call(t, d, http.MethodGet, target); code != want {
			t.Errorf("GET %s: %d, want %d", target, code, want)
		}
	}
	for target, want := range map[string]int{
		"/inject?gpu=0&field=999&value=1":  http.StatusConflict,
		"/inject?gpu=1&field=230&value=1":  http.StatusConflict,
		"/inject?gpu=0&field=230&value=-1": http.StatusConflict,
		"/inject?gpu=0&field=230":          http.StatusBadRequest,
	} {
		if code, _ := call(t, d, http.MethodPost, target); code != want {
			t.Errorf("POST %s: %d, want %d", target, code, want)
		}
	}
	for env, ok := range map[string]bool{"": true, ":9400": true, "9400": false} {
		_, _, err := fakeDCGMConfig(func(k string) string {
			if k == "FAKE_DCGM_ADDR" {
				return env
			}
			return ""
		})
		if (err == nil) != ok {
			t.Errorf("FAKE_DCGM_ADDR %q: err %v", env, err)
		}
	}
	if _, _, err := fakeDCGMConfig(func(k string) string {
		return map[string]string{"FAKE_DCGM_ADDR": ":9400", "FAKE_DCGM_COLLECT_MS": "0"}[k]
	}); err == nil {
		t.Errorf("a zero collection period was accepted")
	}
}

package bench

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The fixtures under testdata/vllm-runtime are the raw bodies the paid readiness preflight of 2026-11-16 (run 6, #594) saved from the first start of each treatment.
// <T>.server-info.json is `GET /server_info?config_format=json` and <T>.version.json is `GET /version`, copied byte for byte.
// A ran vllm/vllm-openai@sha256:0a51ea5b… (v0.27.1), B and C ran vllm/vllm-openai@sha256:befccf0e… (v0.32.0) with async scheduling off and on.
// Every engine ran with VLLM_SERVER_DEV_MODE=1 and the registered profile, so each capture is what its own treatment's engine says about itself.
func vllmCapture(t *testing.T, treatment string) (serverInfo, version []byte) {
	t.Helper()
	dir := filepath.Join("testdata", "vllm-runtime")
	serverInfo, err := os.ReadFile(filepath.Join(dir, treatment+".server-info.json"))
	if err != nil {
		t.Fatal(err)
	}
	version, err = os.ReadFile(filepath.Join(dir, treatment+".version.json"))
	if err != nil {
		t.Fatal(err)
	}
	return serverInfo, version
}

// TestParseVLLMRuntimeMatchesEachCapturedTreatment: each real engine passes its own registration and is refused by the others'.
//
// The expected values are the registration's, never the capture's, so the reader is checked against what the study fixed and not against itself.
func TestParseVLLMRuntimeMatchesEachCapturedTreatment(t *testing.T) {
	d := versionAsyncDesign()
	wantUnproven := []string{UnprovenImage, UnprovenChatTemplate, UnprovenProfileArgs}
	for _, own := range versionStudyTreatments {
		si, v := vllmCapture(t, own)
		rt, err := ParseVLLMRuntime(si, v)
		if err != nil {
			t.Fatalf("%s: %v", own, err)
		}
		unproven, err := d.CheckObservedRuntime(own, rt)
		if err != nil {
			t.Fatalf("%s's own engine was refused: %v", own, err)
		}
		if !slices.Equal(unproven, wantUnproven) {
			t.Fatalf("%s: unproven %v, want %v", own, unproven, wantUnproven)
		}
		if rt.Image != "" || rt.ChatTemplateSHA256 != "" || rt.ProfileArgs != nil {
			t.Fatalf("%s: the reader filled a field the responses do not carry: %+v", own, rt)
		}
		for _, other := range versionStudyTreatments {
			if other == own {
				continue
			}
			if _, err := d.CheckObservedRuntime(other, rt); err == nil {
				t.Errorf("%s's engine passed as %s", own, other)
			}
		}
	}
}

// TestParseVLLMRuntimeRefusesWhatItCannotRead: a key that is missing, null or of another type is an error, never a zero that might match.
//
// A's prefix caching and async scheduling are registered false, so a missing boolean read as false would pass.
func TestParseVLLMRuntimeRefusesWhatItCannotRead(t *testing.T) {
	si, v := vllmCapture(t, TreatmentA)
	edit := func(section, key string, value any, remove bool) []byte {
		var doc map[string]any
		if err := json.Unmarshal(si, &doc); err != nil {
			t.Fatal(err)
		}
		m := doc["vllm_config"].(map[string]any)[section].(map[string]any)
		if _, ok := m[key]; !ok {
			t.Fatalf("the capture has no %s.%s", section, key)
		}
		if remove {
			delete(m, key)
		} else {
			m[key] = value
		}
		out, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	keys := map[string][]string{
		"model_config":     {"model", "tokenizer", "revision", "tokenizer_revision", "dtype", "max_model_len"},
		"scheduler_config": {"max_num_seqs", "max_num_batched_tokens", "policy", "async_scheduling"},
		"cache_config":     {"gpu_memory_utilization", "enable_prefix_caching"},
	}
	for section, names := range keys {
		for _, key := range names {
			if _, err := ParseVLLMRuntime(edit(section, key, nil, true), v); err == nil {
				t.Errorf("%s.%s missing: parsed", section, key)
			}
			if _, err := ParseVLLMRuntime(edit(section, key, nil, false), v); err == nil {
				t.Errorf("%s.%s null: parsed", section, key)
			}
			if _, err := ParseVLLMRuntime(edit(section, key, []int{1}, false), v); err == nil {
				t.Errorf("%s.%s of another type: parsed", section, key)
			}
		}
	}
	var doc map[string]any
	if err := json.Unmarshal(si, &doc); err != nil {
		t.Fatal(err)
	}
	delete(doc["vllm_config"].(map[string]any), "instance_id")
	noInstance, _ := json.Marshal(doc)
	if _, err := ParseVLLMRuntime(noInstance, v); err == nil || !strings.Contains(err.Error(), "instance_id") {
		t.Errorf("no instance_id: %v", err)
	}
	if _, err := ParseVLLMRuntime(edit("cache_config", "gpu_memory_utilization", "0.9", false), v); err == nil {
		t.Error("a memory fraction sent as a string parsed")
	}
	if _, err := ParseVLLMRuntime(si, []byte(`{"version":"0.32.0"}`)); err == nil || !strings.Contains(err.Error(), "0.27.1") {
		t.Errorf("/version disagreeing with the configuration's own version: %v", err)
	}
	if _, err := ParseVLLMRuntime(si, []byte(`{}`)); err == nil {
		t.Error("an empty /version parsed")
	}
}

// TestCheckRuntimeRefusesWhatWasNotProven: the complete check, which preflight and the in-session calibration use, does not accept a gap.
func TestCheckRuntimeRefusesWhatWasNotProven(t *testing.T) {
	d := versionAsyncDesign()
	si, v := vllmCapture(t, TreatmentA)
	rt, err := ParseVLLMRuntime(si, v)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.CheckRuntime(TreatmentA, rt); err == nil || !strings.Contains(err.Error(), "not proven") {
		t.Fatalf("A's responses alone: %v, want a refusal naming what they do not prove", err)
	}
}

// TestCheckObservedRuntimeRefusesADeclarationItCannotHonour: a gap is a field left empty and named, and nothing else may be skipped.
func TestCheckObservedRuntimeRefusesADeclarationItCannotHonour(t *testing.T) {
	d := versionAsyncDesign()
	si, v := vllmCapture(t, TreatmentA)
	base, err := ParseVLLMRuntime(si, v)
	if err != nil {
		t.Fatal(err)
	}
	// Each case names the refusal it must meet, so a case refused for another reason does not hide a missing check.
	for name, c := range map[string]struct {
		mutate func(r *RuntimeIdentity)
		want   string
	}{
		"a named image that carries a value": {func(r *RuntimeIdentity) { r.Image = d.Engines[TreatmentA].Image }, "carries a value"},
		"named arguments that are present":   {func(r *RuntimeIdentity) { r.ProfileArgs = d.ReviewedProfileArgs[TreatmentA] }, "carries a value"},
		"a setting named as unproven": {func(r *RuntimeIdentity) {
			r.Unproven = append(slices.Clone(r.Unproven), "asyncScheduling")
		}, "cannot be unproven"},
		"a gap named twice": {func(r *RuntimeIdentity) { r.Unproven = append(slices.Clone(r.Unproven), UnprovenImage) }, "twice"},
		"an empty image not named": {func(r *RuntimeIdentity) {
			r.Unproven = slices.DeleteFunc(slices.Clone(r.Unproven), func(s string) bool { return s == UnprovenImage })
		}, "image digest"},
	} {
		r := base
		c.mutate(&r)
		if _, err := d.CheckObservedRuntime(TreatmentA, r); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want a refusal naming %q", name, err, c.want)
		}
	}
}

// TestEngineSettingsDiffComparesTheMemoryFractionByValue: the engine reports 0.9 for the registered 0.90, which is the same fraction.
func TestEngineSettingsDiffComparesTheMemoryFractionByValue(t *testing.T) {
	want := versionAsyncDesign().Engines[TreatmentA]
	for got, same := range map[string]bool{"0.9": true, "0.90": true, "0.900": true, "0.91": false, "0.905": false, "9/10": false, "9e-1": false, "": false, ".9": false} {
		g := want
		g.GPUMemoryUtilization = got
		if diff := want.Diff(g); (diff == "") != same {
			t.Errorf("%q against %q: diff %q", got, want.GPUMemoryUtilization, diff)
		}
	}
}

// TestFetchVLLMIdentityNeedsDevMode: an engine without VLLM_SERVER_DEV_MODE answers 404 and is refused, since nothing else carries its configuration.
func TestFetchVLLMIdentityNeedsDevMode(t *testing.T) {
	si, v := vllmCapture(t, TreatmentA)
	devMode := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/server_info" && devMode && r.URL.Query().Get("config_format") == "json":
			_, _ = w.Write(si)
		case r.URL.Path == "/version":
			_, _ = w.Write(v)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	got, err := FetchVLLMIdentity(context.Background(), srv.Client(), srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if string(got.ServerInfo) != string(si) || string(got.Version) != string(v) {
		t.Fatal("the fetched bodies are not the engine's")
	}
	devMode = false
	if _, err := FetchVLLMIdentity(context.Background(), srv.Client(), srv.URL); err == nil || !strings.Contains(err.Error(), "VLLM_SERVER_DEV_MODE") {
		t.Fatalf("dev mode off: %v, want a refusal naming it", err)
	}
}

// TestCheckObservedRuntimeRefusesAnotherModel: a revision string alone does not name the weights, since vLLM ignores it for a local path.
func TestCheckObservedRuntimeRefusesAnotherModel(t *testing.T) {
	d := versionAsyncDesign()
	si, v := vllmCapture(t, TreatmentA)
	for key, want := range map[string]string{"model": "model", "tokenizer": "tokenizer"} {
		var doc map[string]any
		if err := json.Unmarshal(si, &doc); err != nil {
			t.Fatal(err)
		}
		doc["vllm_config"].(map[string]any)["model_config"].(map[string]any)[key] = "/models/different-checkpoint"
		edited, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		rt, err := ParseVLLMRuntime(edited, v)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.CheckObservedRuntime(TreatmentA, rt); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("A with another %s: %v", key, err)
		}
	}
}

// TestParseVLLMRuntimeReadsTheProcess: every start reports its own instance id, which is how a replaced engine is told from the one checked.
func TestParseVLLMRuntimeReadsTheProcess(t *testing.T) {
	seen := map[string]string{}
	for _, tr := range versionStudyTreatments {
		si, v := vllmCapture(t, tr)
		rt, err := ParseVLLMRuntime(si, v)
		if err != nil {
			t.Fatal(err)
		}
		if rt.InstanceID == "" || seen[rt.InstanceID] != "" {
			t.Fatalf("%s: instance id %q, already seen on %s", tr, rt.InstanceID, seen[rt.InstanceID])
		}
		seen[rt.InstanceID] = tr
	}
}

// TestFetchVLLMIdentityReadsOnlyTheEngineItWasGiven: a redirect would let one engine's identity stand for another that serves the requests.
func TestFetchVLLMIdentityReadsOnlyTheEngineItWasGiven(t *testing.T) {
	si, v := vllmCapture(t, TreatmentA)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/server_info":
			http.Redirect(w, r, "/elsewhere/server_info?config_format=json", http.StatusFound)
		case "/elsewhere/server_info":
			_, _ = w.Write(si)
		case "/version":
			_, _ = w.Write(v)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	if _, err := FetchVLLMIdentity(context.Background(), srv.Client(), srv.URL); err == nil || !strings.Contains(err.Error(), "302") {
		t.Fatalf("a redirected /server_info: %v, want a refusal", err)
	}
	direct := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/server_info":
			_, _ = w.Write(si)
		case "/version":
			_, _ = w.Write(v)
		default:
			http.NotFound(w, r)
		}
	}))
	defer direct.Close()
	// The sender trims every trailing slash, so the identity must be read from the same engine for the same flag.
	if _, err := FetchVLLMIdentity(context.Background(), direct.Client(), direct.URL+"//"); err != nil {
		t.Fatalf("a base URL with trailing slashes: %v", err)
	}
}

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

// Package bench implements the GPU-free benchmark harness: a frozen run manifest, an immutable
// open-loop trace, a replay client that records raw per-request evidence, and a report that
// computes the design's pre-registered checks from that evidence.
//
// Design rationale (design spec "Benchmarking harness" section): the gateway's own request
// histogram starts just before the proxy handoff and stops when the stream closes, so it is not
// TTFT. Every latency number this package reports comes from client-side raw timestamps recorded
// during replay, never from a server-side metric.
package bench

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"sigs.k8s.io/yaml"
)

// TimeoutScopeWholeRequest is what TimeoutMs actually bounds, written once so two writers cannot drift.
//
// HTTPSender.Send wraps the request in a single context deadline before dialling and keeps it through the
// SSE scan, so the budget covers connection, TLS, headers and the whole stream. It is NOT a first-token
// budget: a response that starts in time and then stalls expires too, and that expiry is recorded with the
// first token it had already stamped.
//
// A constant rather than a literal at each manifest writer, because gen-trace and prepare-traces both
// write the field and a string typed twice is a string that drifts once.
const TimeoutScopeWholeRequest = "whole-request-including-stream"

// RunManifest freezes everything that must stay fixed for a benchmark comparison across arms to
// be valid.
//
// Design rationale (design spec "Benchmarking harness" section): "Frozen run manifest (versioned,
// validated): arms, trace checksum, image digests, model/tokenizer revision, gateway SHA,
// thresholds, B rate/burst, endpoint, tolerances." Every arm's manifest for one repetition shares
// the same TracePath/TraceChecksum, Model, and Seed; only Arm and Thresholds are expected to
// differ between them.
type RunManifest struct {
	// SchemaVersion pins the manifest shape, so a future incompatible change to this struct can
	// be detected instead of silently misparsed.
	SchemaVersion string `json:"schemaVersion"`
	// Study names the pre-registered experiment this run belongs to.
	//
	// It exists because arm names are not unique across experiments and never were: M5-b's "off" is
	// the gateway with its guard disabled, and the price-of-protection run's control is the engine at
	// its default batch budget with no gateway at all. Without this field the two produce rows a
	// report cannot tell apart, and pooling them silently answers a question nobody asked.
	//
	// Empty means the evidence predates studies, and is read as StudyM5BGateway.
	Study string `json:"study,omitempty"`
	// Arm names which pre-registered condition of Study this run measures.
	//
	// The admissible values come from the study registry in study.go, not from a list here.
	Arm string `json:"arm"`
	// GatewayURL is the target the replay client sends requests to.
	GatewayURL string `json:"gatewayURL"`
	// TracePath locates the immutable trace file this run replays.
	//
	// A relative path is resolved against the manifest file's own directory by LoadManifest, so
	// a manifest and its trace can be moved together without editing this field.
	TracePath string `json:"tracePath"`
	// TraceChecksum is the sha256 (hex) of the trace file at TracePath, verified by LoadManifest.
	//
	// This is what makes "immutable trace across frozen arms" enforceable rather than aspirational:
	// a trace edited after the checksum was frozen fails to load instead of silently comparing arms
	// against different traffic.
	TraceChecksum string `json:"traceChecksum"`
	// Model is the model name every replayed request targets.
	Model string `json:"model"`
	// PromptCorpusSHA identifies the prompt text the run's binary sends, which traceChecksum cannot cover:
	// the trace records prompt LENGTHS and the text is synthesised at send time. LoadManifest refuses a
	// manifest whose corpus is not the one compiled into this binary, so a run frozen against different
	// prompt bytes cannot be replayed or reported as if it were the same traffic.
	PromptCorpusSHA string `json:"promptCorpusSHA"`

	// TokenizerRev records the tokenizer/chat-template revision the estimator was calibrated
	// against.
	//
	// Recorded for provenance only; the GPU-free build never loads a real tokenizer with it
	// (design spec "Frozen run manifest" bullet).
	TokenizerRev string `json:"tokenizerRev,omitempty"`
	// GatewaySHA is the gateway build's commit SHA, recorded for provenance.
	GatewaySHA string `json:"gatewaySHA,omitempty"`
	// ImageDigests pins every image (gateway, vLLM, load generator) this run used, by name.
	ImageDigests map[string]string `json:"imageDigests,omitempty"`
	// GatewayBinarySHA256 and GatewayBase name the gateway by content, which its image ID cannot.
	//
	// The image ID changes with every build of the same binary on the same base (the copied file's
	// timestamp is in the layer), so a reproduction compares these two instead when both runs recorded them.
	// Registered in docs/superpowers/specs/2026-10-07-gateway-identity-for-reproduction.md.
	GatewayBinarySHA256 string `json:"gatewayBinarySHA256,omitempty"`
	GatewayBase         string `json:"gatewayBase,omitempty"`
	// Thresholds records the guard/static-cap parameters in effect for this arm (e.g. engage
	// usage, W, static-cap rate/burst), as strings so heterogeneous parameter sets across arms
	// don't need one struct field per possible knob.
	Thresholds map[string]string `json:"thresholds,omitempty"`
	// TimeoutMs bounds how long the replay client waits for a single request before recording it
	// as a timeout row.
	TimeoutMs int `json:"timeoutMs"`
	// TimeoutScope names WHICH INTERVAL TimeoutMs covers, because the number alone does not say.
	//
	// The sender wraps the whole request in one context deadline -- connection, TLS, headers and the entire
	// SSE stream -- so "60000" is not a first-token budget and not a connect budget. Two different
	// expiries both record errorKind "timeout": one before any response (httpStatus 0, no first token) and
	// one mid-stream (the first token already stamped and kept). A reader asking "were any requests
	// censored by the timeout" needs the interval named, and the fifth of the nine log questions asks for
	// exactly that.
	//
	// EMPTY MEANS THE RUN PREDATES THIS FIELD, and Validate deliberately does not require it: the three
	// archives on disk carry no scope, and refusing them would make every past manifest unloadable to
	// prove a point about future ones. "Not recorded" and "no scope" must not read the same, which is why
	// the absence is documented here rather than defaulted to the current value.
	TimeoutScope string `json:"timeoutScope,omitempty"`
	// Seed is the trace generator's seed, recorded here so a manifest alone documents which seed
	// produced its trace even though gen-trace, not LoadManifest, is what actually consumes it.
	Seed int64 `json:"seed"`
	// PrimaryEndpoint names the pre-registered primary metric.
	//
	// Design spec "Pre-registered success criteria" section: "Primary endpoint is TTFT p99 ...
	// Choosing the endpoint now prevents post-hoc metric selection." Always "ttft_p99" in this
	// design, but recorded rather than hardcoded so the report can assert it was not changed
	// after the fact.
	PrimaryEndpoint string `json:"primaryEndpoint"`
	// MatchTolerance is the pre-registered admission-work match tolerance, as a decimal string
	// (e.g. "0.05" for +/-5%).
	//
	// A string, not a float64: the manifest is meant to be hand-edited YAML, and "0.05" round-trips
	// through YAML/JSON exactly, while a float field risks a value like 0.050000000000000003
	// appearing in a re-serialized manifest and looking like the tolerance was silently changed.
	MatchTolerance string `json:"matchTolerance"`
	// LongThreshold is the eligible-population token threshold the guard and static cap gate on.
	//
	// It is frozen here so the report scores admitted-work over the same population the guard used, even if the paid pilot tuned the gateway's --admission-long-threshold.
	LongThreshold int `json:"longThreshold,omitempty"`
	// PromptLenChars records the prompt length each tenant was sent, in characters.
	//
	// The registration freezes the rate, the three weights, the duration and the seed. It does NOT freeze
	// the prompt length, and the length moves the headline number: the ninth pilot sent premium prompts of
	// 200 characters and the first CR-driven run sent 1,174, and the two reported 27.2x and 23.0x for the
	// same study. Neither manifest said which load it was.
	//
	// Not covered by the two fields that come closest. traceChecksum changes with the length -- it is the
	// sha256 of the trace -- so the difference was DETECTABLE, but two disagreeing hashes do not tell a
	// reader the prompts grew 5.9x. promptCorpusSHA pins the prompt TEXT and was identical in both runs,
	// which is correct: the corpus is the source the text is cut from, and the length is cut at send time.
	//
	// Written by PromptLenCharsByTenant from the trace itself, so the two places that build a manifest
	// cannot disagree about it. -1 for a tenant whose rows carry more than one length, which means the
	// trace is not the one the study froze.
	//
	// omitempty, and not in validateFields' required list: the ninth pilot's six manifests predate the
	// field and must keep loading. Making it required needs a schemaVersion branch, and there is no such
	// branch anywhere yet -- both writers stamp the literal "v2" and nothing reads it.
	PromptLenChars map[string]int `json:"promptLenChars,omitempty"`

	// MaxOutputTokens is the per-tenant max_tokens cap this cell sent, keyed by tenant.
	//
	// Two of the five frozen quantities are the output caps, and until 2026-10-02 the manifest recorded
	// neither: the caps reached the engine and then existed only as a per-row field in the trace, so the
	// declared tuple a run was bought under could not be read back from its manifest. The lengths and the
	// timeout were already here; these complete the five.
	//
	// omitempty and not required, for the reason PromptLenChars gives: six manifests from the ninth pilot
	// predate the field and must keep loading.
	MaxOutputTokens map[string]int `json:"maxOutputTokens,omitempty"`
}

// LoadManifest reads, validates, and returns the manifest at path.
//
// Validation covers two independent things, both hard errors: every required field is present
// and well-formed, and TraceChecksum matches the sha256 of the trace file TracePath resolves to.
// The second check is what makes an edited-after-freeze trace file unusable rather than silently
// accepted, which is the property the design spec calls "immutable trace across frozen arms".
//
// On success, m.TracePath is rewritten to the resolved absolute path, so callers (gen-trace,
// replay) never need to re-resolve it against the manifest's own directory.
func LoadManifest(path string) (*RunManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest %s: %w", path, err)
	}

	var m RunManifest
	// sigs.k8s.io/yaml round-trips through JSON, so a manifest may be written as either YAML or
	// plain JSON (JSON is valid YAML) without this package needing to tell them apart.
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse manifest %s: %w", path, err)
	}

	if err := m.validateFields(); err != nil {
		return nil, fmt.Errorf("manifest %s: %w", path, err)
	}

	tracePath := m.TracePath
	if !filepath.IsAbs(tracePath) {
		tracePath = filepath.Join(filepath.Dir(path), tracePath)
	}
	sum, err := ChecksumFile(tracePath)
	if err != nil {
		return nil, fmt.Errorf("read trace file %s: %w", tracePath, err)
	}
	if sum != m.TraceChecksum {
		return nil, fmt.Errorf("trace checksum mismatch: manifest declares %s but %s hashes to %s",
			m.TraceChecksum, tracePath, sum)
	}
	m.TracePath = tracePath

	return &m, nil
}

// validateFields checks that every field LoadManifest's checksum step depends on, and every
// field the report later depends on, is present and well-formed.
//
// It does not touch the filesystem; that half of validation (the checksum check) lives in
// LoadManifest, since it needs the resolved trace path.
func (m *RunManifest) validateFields() error {
	required := []struct {
		name  string
		value string
	}{
		{"schemaVersion", m.SchemaVersion},
		{"arm", m.Arm},
		{"gatewayURL", m.GatewayURL},
		{"tracePath", m.TracePath},
		{"traceChecksum", m.TraceChecksum},
		{"model", m.Model},
		{"promptCorpusSHA", m.PromptCorpusSHA},
		{"primaryEndpoint", m.PrimaryEndpoint},
		{"matchTolerance", m.MatchTolerance},
	}
	for _, f := range required {
		if f.value == "" {
			return fmt.Errorf("missing required field %q", f.name)
		}
	}

	if m.PromptCorpusSHA != PromptCorpusSHA256 {
		return fmt.Errorf("promptCorpusSHA mismatch: manifest declares %s but this binary sends corpus %s",
			m.PromptCorpusSHA, PromptCorpusSHA256)
	}

	study, ok := LookupStudy(m.Study)
	if !ok {
		return fmt.Errorf("study %q is not registered; known studies are %s", m.Study, strings.Join(KnownStudyIDs(), ", "))
	}
	if !study.Admits(m.Arm) {
		return fmt.Errorf("arm %q is not one of study %s's arms (%s)", m.Arm, study.ID, strings.Join(study.Arms, ", "))
	}

	if m.TimeoutMs <= 0 {
		return fmt.Errorf("timeoutMs must be positive, got %d", m.TimeoutMs)
	}

	if _, err := strconv.ParseFloat(m.MatchTolerance, 64); err != nil {
		return fmt.Errorf("matchTolerance %q is not a number: %w", m.MatchTolerance, err)
	}

	return nil
}

// ProvenanceRoles are the images a paid run's number depends on, and therefore the ones its evidence has to
// name.
//
// The gateway is the component under test on arms C and B; the engine is what produces every latency the
// report quotes. A record that cannot say which build of either produced it is a number without a subject.
var ProvenanceRoles = []string{"gateway", "engine"}

// digestPinned reports whether a reference names an immutable image.
//
// A tag is not provenance. `gateway:m5b` identifies whatever was pushed under that name most recently, so a
// record carrying it says only that somebody ran something called m5b -- and the paid session scripts used
// exactly that form. Only `name@sha256:...` survives a rebuild.
func digestPinned(ref string) bool {
	i := strings.Index(ref, "@sha256:")
	if i <= 0 {
		return false
	}
	// 64 hex characters after the prefix, and nothing else.
	hex := ref[i+len("@sha256:"):]
	if len(hex) != 64 {
		return false
	}
	for _, c := range hex {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// GatewayIdentityRefusal says what is wrong with a manifest's gateway content facts, or nil.
//
// Neither is a run from before the facts existed. One without the other is refused rather than read as neither,
// because a half-recorded identity would silently fall back to comparing the image ID it was meant to replace.
func GatewayIdentityRefusal(binarySHA256, base string) error {
	switch {
	case binarySHA256 == "" && base == "":
		return nil
	case binarySHA256 == "" || base == "":
		return fmt.Errorf("manifest records gatewayBinarySHA256 %q and gatewayBase %q; the gateway's identity is both or neither", binarySHA256, base)
	case !lowerHex(binarySHA256, 64):
		return fmt.Errorf("manifest records gatewayBinarySHA256 %q, which is not 64 lowercase hex characters", binarySHA256)
	case !digestPinned(base):
		return fmt.Errorf("manifest records gatewayBase %q, which is not pinned by digest; a tag names whatever was pushed under it most recently", base)
	}
	return nil
}

// lowerHex reports whether s is exactly n lowercase hex characters.
func lowerHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// commitShaped reports whether s could be a git commit: 7 to 40 lowercase hex characters, optionally
// followed by "-dirty".
//
// Short and full-length both occur in this repository's records, so the range is deliberate rather than a
// single length. It does not prove the commit exists -- nothing available here can -- but it does reject the
// placeholders a shell fallback produces.
//
// The suffix is allowed because hack/m5b-arms.sh:440 appends it on purpose when the tree is not clean, and
// nothing on that path refuses a dirty tree before the card is rented. Refusing it here would fail a paid
// run at its first replay, after both engines are up -- the most expensive place to learn it. A commit plus
// "the tree was modified" still names a build; "unknown" names nothing, and that is the difference this
// check is drawing.
func commitShaped(s string) bool {
	s = strings.TrimSuffix(s, "-dirty")
	if len(s) < 7 || len(s) > 40 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// RequireProvenance refuses a manifest that cannot name the builds its numbers came from.
//
// GatewaySHA and ImageDigests were declared on RunManifest for exactly this and nothing ever set them: no
// gen-trace flag accepted them, no script passed them, and every manifest this repository has produced left
// them empty. The fields documented an intention.
//
// This is opt-in rather than always-on, in the manner of -require-device: a kind run against a stub has no
// build worth pinning, and making every free run carry one would push operators toward inventing a value.
// The paid path asks for it, because that is where the record has to outlive the cluster.
func (m RunManifest) RequireProvenance() error {
	sha := strings.TrimSpace(m.GatewaySHA)
	if sha == "" {
		return fmt.Errorf("manifest carries no gatewaySHA; a paid run's evidence must name the build that produced it")
	}
	// A value that is not a commit is refused, not just an empty one.
	//
	// hack/m5c-matrix.sh derives the commit with `git rev-parse ... || echo unknown`, and on a rented instance
	// the source arrives as a tarball with no .git. The 2026-09-16 ladder therefore recorded "unknown" in all
	// seven paid manifests and this guard passed them, because "unknown" is not empty. A check that cannot
	// fail on the one value the scripts actually produce is worse than no check: it certifies the gap.
	if !commitShaped(sha) {
		return fmt.Errorf("manifest records gatewaySHA %q, which is not a commit; a paid run's evidence must name the build that produced it", sha)
	}
	for _, role := range ProvenanceRoles {
		ref, ok := m.ImageDigests[role]
		if !ok || strings.TrimSpace(ref) == "" {
			return fmt.Errorf("manifest names no image for %q; imageDigests must pin every image the number depends on", role)
		}
		if !digestPinned(ref) {
			return fmt.Errorf("manifest pins %q to %q, which is a tag rather than a digest;"+
				" a tag names whatever was pushed under it most recently, so it identifies nothing after the next build", role, ref)
		}
	}
	// The tokenizer revision, demanded for the same reason as the build and the images.
	//
	// The design scores admitted work over the SERVED tokenizer count, and the character-to-token
	// calibration this repository commits was measured against one specific tokenizer. A number that cannot
	// name that tokenizer cannot be compared with the calibration, and the calibration file itself claimed to
	// have been measured at a revision nobody recorded.
	//
	// commitShaped is NOT reused here. It accepts 7 to 40 hex characters and a -dirty suffix, both of which
	// are meaningful for a build from a working tree and meaningless for a model revision: there is no such
	// thing as a partially modified upstream tokenizer, and a truncated revision does not identify one.
	rev := strings.TrimSpace(m.TokenizerRev)
	if rev == "" {
		return fmt.Errorf("manifest carries no tokenizerRev; a paid run's evidence must name the tokenizer its input-token counts were scored against")
	}
	if !revisionShaped(rev) {
		return fmt.Errorf("manifest records tokenizerRev %q, which is not a full 40-character lowercase hex revision; a truncated or invented revision identifies no tokenizer", rev)
	}
	// The gateway's content facts are not demanded, because the M5-b path (prepare-traces) does not record them.
	// A paid manifest that records them must record them whole.
	return GatewayIdentityRefusal(m.GatewayBinarySHA256, m.GatewayBase)
}

// revisionShaped reports whether s is exactly 40 lowercase hex characters.
//
// Deliberately stricter than commitShaped. That function exists for a build of THIS repository, where a
// short SHA and a -dirty suffix both still name something a reader can find. A model revision comes from an
// upstream registry: it is always the full hash, it is never dirty, and accepting a prefix would let two
// different tokenizers share a recorded identity.
func revisionShaped(s string) bool {
	if len(s) != 40 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

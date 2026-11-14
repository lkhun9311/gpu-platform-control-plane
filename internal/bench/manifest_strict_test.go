package bench

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// writeManifestFile writes m as YAML, with extra appended verbatim, beside a one-row trace it checksums.
//
// extra is how a test adds a field the struct does not have, which is the case strict decoding exists for.
func writeManifestFile(t *testing.T, m RunManifest, extra string) string {
	t.Helper()
	dir := t.TempDir()
	trace := []byte(`{"index":0,"offsetMs":0,"tenant":"premium-1","promptLenChars":1174,"maxOutputTokens":64,"isNoisy":false}` + "\n")
	if err := os.WriteFile(filepath.Join(dir, "trace.jsonl"), trace, 0o600); err != nil {
		t.Fatal(err)
	}
	m.TracePath, m.TraceChecksum = "trace.jsonl", Checksum(trace)
	data, err := yaml.Marshal(&m)
	if err != nil {
		t.Fatal(err)
	}
	data = append(data, []byte(extra)...)
	path := filepath.Join(dir, "manifest.yaml")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// historicalManifest is a v2 manifest of the kind every archive on disk carries.
func historicalManifest() RunManifest {
	return RunManifest{
		SchemaVersion:   ManifestSchemaV2,
		Study:           StudyHoldCapProductTransfer,
		Arm:             "Off",
		GatewayURL:      "http://gateway.example:8080",
		Model:           "qwen2.5-3b-instruct",
		PromptCorpusSHA: PromptCorpusSHA256,
		TimeoutMs:       30000,
		TimeoutScope:    TimeoutScopeWholeRequest,
		Seed:            11,
		PrimaryEndpoint: "ttft_p99",
		MatchTolerance:  "0.05",
	}
}

// TestCommittedManifestsLoadStrictly decodes every run manifest committed under hack/ with the strict decoder.
//
// Strict decoding would orphan an archive that carried a field the struct lacks, so the archives are the test.
// The floor on the count catches a walk that silently found nothing, which would pass for the wrong reason.
func TestCommittedManifestsLoadStrictly(t *testing.T) {
	root := filepath.Join("..", "..", "hack")
	n := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := d.Name()
		if d.IsDir() || !strings.HasPrefix(name, "manifest") ||
			!(strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".yaml")) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !strings.Contains(string(data), "traceChecksum") {
			return nil
		}
		n++
		m, err := decodeManifest(data)
		if err != nil {
			t.Errorf("%s: %v", path, err)
			return nil
		}
		if err := m.validateFields(); err != nil {
			t.Errorf("%s: %v", path, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if n < 50 {
		t.Fatalf("found %d committed run manifests, want at least 50; the walk is not reading the archives", n)
	}
}

// TestManifestRefusals lists v2 manifests that used to load and must not (audit finding 13).
func TestManifestRefusals(t *testing.T) {
	for name, c := range map[string]struct {
		mutate func(m *RunManifest)
		extra  string
		want   string
	}{
		"an unknown field, which used to have no effect": {extra: "asyncScheduling: true\n", want: "unknown field"},
		"a known field in another letter case":           {extra: "timeoutMS: 60000\n", want: "timeoutMS"},
		"an unsupported schema version":                  {mutate: func(m *RunManifest) { m.SchemaVersion = "v4" }, want: "schemaVersion"},
		"a primary endpoint nobody registered":           {mutate: func(m *RunManifest) { m.PrimaryEndpoint = "ttft_p50" }, want: "primaryEndpoint"},
		"a timeout scope the sender does not implement":  {mutate: func(m *RunManifest) { m.TimeoutScope = "first-token" }, want: "timeoutScope"},
		"a non-finite match tolerance":                   {mutate: func(m *RunManifest) { m.MatchTolerance = "NaN" }, want: "matchTolerance"},
		"a match tolerance outside [0, 1]":               {mutate: func(m *RunManifest) { m.MatchTolerance = "5" }, want: "matchTolerance"},
		"a v3 manifest for a historical study": {
			mutate: func(m *RunManifest) { m.SchemaVersion = ManifestSchemaV3 }, want: "schema",
		},
		"v3 engine settings in a v2 manifest": {
			mutate: func(m *RunManifest) { m.Engine = &EngineSettings{VLLMVersion: "v0.27.1"} }, want: "v3",
		},
	} {
		t.Run(name, func(t *testing.T) {
			m := historicalManifest()
			if c.mutate != nil {
				c.mutate(&m)
			}
			_, err := LoadManifest(writeManifestFile(t, m, c.extra))
			if err == nil {
				t.Fatalf("accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("refusal %q does not mention %q", err, c.want)
			}
		})
	}
	if _, err := LoadManifest(writeManifestFile(t, historicalManifest(), "")); err != nil {
		t.Fatalf("the unmutated historical manifest was refused: %v", err)
	}
	legacy := historicalManifest()
	legacy.TimeoutScope = ""
	if _, err := LoadManifest(writeManifestFile(t, legacy, "")); err != nil {
		t.Errorf("a manifest from before timeoutScope existed was refused: %v", err)
	}
}

// studyVersionFixture is the version study registered with every owner decision filled, for these tests only.
const studyVersionFixture = "vllm-version-async-fixture"

func registerFrozenVersionStudy(t *testing.T) {
	t.Helper()
	st, _ := LookupStudy(StudyVersionAsync)
	st.ID = studyVersionFixture
	st.Version = new(frozenVersionDesignFixture())
	studies[studyVersionFixture] = st
	t.Cleanup(func() { delete(studies, studyVersionFixture) })
}

// versionManifest is a valid v3 manifest for block 2 of the fixture campaign, treatment C at 0.9 λ0.
func versionManifest(t *testing.T) RunManifest {
	t.Helper()
	d := frozenVersionDesignFixture()
	seed, err := WorkloadSeed(d.CampaignSeed, 2, LoadL090)
	if err != nil {
		t.Fatal(err)
	}
	pos := 0
	for i, tr := range ArmOrder(d.CampaignSeed, 2) {
		if tr == TreatmentC {
			pos = i + 1
		}
	}
	return RunManifest{
		SchemaVersion:   ManifestSchemaV3,
		Study:           studyVersionFixture,
		Arm:             VersionStudyArm(TreatmentC, LoadL090),
		GatewayURL:      "http://engine.example:8000",
		Model:           "qwen2.5-3b-instruct",
		PromptCorpusSHA: PromptCorpusSHA256,
		TimeoutMs:       d.TimeoutMs,
		TimeoutScope:    TimeoutScopeWholeRequest,
		Seed:            seed,
		PrimaryEndpoint: EndpointVersionDecisionSet,
		Engine:          new(d.Engines[TreatmentC]),
		Sampling:        versionStudySampling(),
		Cell: &CellIdentity{
			CampaignID:             "s1-20261120",
			Block:                  2,
			Position:               pos,
			OrderSeed:              d.CampaignSeed,
			CapacityRequestsPerSec: 4,
			CapacityArtifactSHA256: strings.Repeat("c", 64),
			OfferedRequestsPerSec:  3.6,
		},
	}
}

// TestVersionManifestAccepted checks the valid shape loads, so every refusal below is the mutation's.
func TestVersionManifestAccepted(t *testing.T) {
	registerFrozenVersionStudy(t)
	if _, err := LoadManifest(writeManifestFile(t, versionManifest(t), "")); err != nil {
		t.Fatalf("a valid v3 manifest was refused: %v", err)
	}
}

// TestVersionManifestRefusals lists the v3 manifests the version study must refuse.
func TestVersionManifestRefusals(t *testing.T) {
	registerFrozenVersionStudy(t)
	for name, c := range map[string]struct {
		mutate func(m *RunManifest)
		want   string
	}{
		"v2 schema":                   {func(m *RunManifest) { m.SchemaVersion = ManifestSchemaV2 }, "schema"},
		"async scheduling off for C":  {func(m *RunManifest) { m.Engine.AsyncScheduling = new(false) }, "asyncScheduling"},
		"another batch budget":        {func(m *RunManifest) { m.Engine.MaxNumBatchedTokens = 2048 }, "maxNumBatchedTokens"},
		"image pinned by tag":         {func(m *RunManifest) { m.Engine.Image = "vllm/vllm-openai:latest" }, "image"},
		"no engine settings":          {func(m *RunManifest) { m.Engine = nil }, "engine"},
		"sampling temperature 0.7":    {func(m *RunManifest) { m.Sampling.Temperature = 0.7 }, "sampling"},
		"no sampling":                 {func(m *RunManifest) { m.Sampling = nil }, "sampling"},
		"valid unregistered penalty":  {func(m *RunManifest) { m.Sampling.RepetitionPenalty = 1.05 }, "not the registered"},
		"no cell identity":            {func(m *RunManifest) { m.Cell = nil }, "cell"},
		"empty campaign":              {func(m *RunManifest) { m.Cell.CampaignID = "" }, "campaignId"},
		"block beyond replacements":   {func(m *RunManifest) { m.Cell.Block = 8 }, "block"},
		"position not the seeded one": {func(m *RunManifest) { m.Cell.Position = m.Cell.Position%3 + 1 }, "position"},
		"another order seed":          {func(m *RunManifest) { m.Cell.OrderSeed = 7 }, "orderSeed"},
		"workload seed of block 1":    {func(m *RunManifest) { m.Seed++ }, "seed"},
		"offered rate not 0.9 λ0":     {func(m *RunManifest) { m.Cell.OfferedRequestsPerSec = 4 }, "offered"},
		"no capacity":                 {func(m *RunManifest) { m.Cell.CapacityRequestsPerSec = 0 }, "capacity"},
		"capacity artifact not hex":   {func(m *RunManifest) { m.Cell.CapacityArtifactSHA256 = "pending" }, "capacityArtifactSHA256"},
		"another timeout":             {func(m *RunManifest) { m.TimeoutMs = 30000 }, "timeoutMs"},
		"no timeout scope":            {func(m *RunManifest) { m.TimeoutScope = "" }, "timeoutScope"},
		"the admission endpoint":      {func(m *RunManifest) { m.PrimaryEndpoint = "ttft_p99" }, "primaryEndpoint"},
		"gateway thresholds":          {func(m *RunManifest) { m.Thresholds = map[string]string{"W": "4"} }, "thresholds"},
		"an admission tolerance":      {func(m *RunManifest) { m.MatchTolerance = "0.05" }, "matchTolerance"},
	} {
		t.Run(name, func(t *testing.T) {
			m := versionManifest(t)
			c.mutate(&m)
			_, err := LoadManifest(writeManifestFile(t, m, ""))
			if err == nil {
				t.Fatalf("accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("refusal %q does not mention %q", err, c.want)
			}
		})
	}
}

// TestVersionManifestRefusesAnOmittedSetting checks a setting left out is refused rather than read as its zero value.
//
// temperature 0 is the registered value, so only a presence check can tell "sent greedy" from "never said".
func TestVersionManifestRefusesAnOmittedSetting(t *testing.T) {
	registerFrozenVersionStudy(t)
	path := writeManifestFile(t, versionManifest(t), "")
	data, _ := os.ReadFile(path)
	cut := strings.Replace(string(data), "  temperature: 0\n", "", 1)
	if cut == string(data) {
		t.Fatalf("fixture has no temperature line to remove:\n%s", data)
	}
	if err := os.WriteFile(path, []byte(cut), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := LoadManifest(path)
	if err == nil || !strings.Contains(err.Error(), "temperature") {
		t.Fatalf("err = %v, want a refusal naming the missing temperature", err)
	}
}

// TestRegisteredVersionStudyRefusesUntilFrozen checks no cell can load while the owner's decisions are open.
func TestRegisteredVersionStudyRefusesUntilFrozen(t *testing.T) {
	m := versionManifest(t)
	m.Study = StudyVersionAsync
	_, err := LoadManifest(writeManifestFile(t, m, ""))
	if err == nil || !strings.Contains(err.Error(), "not frozen") {
		t.Fatalf("err = %v, want the unfrozen refusal", err)
	}
}

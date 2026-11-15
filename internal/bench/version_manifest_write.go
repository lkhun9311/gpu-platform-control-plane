package bench

import (
	"errors"
	"fmt"
	"path/filepath"
	"slices"

	"sigs.k8s.io/yaml"
)

// VersionCellManifest is the v3 manifest of one cell, built from the frozen bundle so no field is typed by hand.
//
// Every value that pairs the cell with its campaign comes from the bundle or the registration: the trace and its seed, λ0, both orders, the engine and the sampling.
// engineURL is the one value a session supplies, because the engine's address is not part of what is compared.
func VersionCellManifest(b *CampaignBundle, bundleSHA, bundleDir string, block int, treatment, load, engineURL string) (RunManifest, error) {
	st, ok := LookupStudy(b.Study)
	if !ok || st.Version == nil || st.Sampling == nil {
		return RunManifest{}, fmt.Errorf("study %q is not a version study", b.Study)
	}
	d := st.Version
	switch {
	case !isSHA256Hex(bundleSHA):
		return RunManifest{}, fmt.Errorf("bundle sha %q is not a sha256", bundleSHA)
	case engineURL == "":
		return RunManifest{}, errors.New("engine URL is empty")
	case block < 1 || block > d.PlannedBlocks+d.MaxReplacementBlocks:
		return RunManifest{}, fmt.Errorf("block %d is outside 1..%d", block, d.PlannedBlocks+d.MaxReplacementBlocks)
	case !slices.Contains(versionStudyTreatments, treatment):
		return RunManifest{}, fmt.Errorf("treatment %q is not one of %v", treatment, versionStudyTreatments)
	}
	i := slices.IndexFunc(b.Traces, func(t BundleTrace) bool { return t.Block == block && t.Load == load })
	if i < 0 {
		return RunManifest{}, fmt.Errorf("the bundle has no trace for block %d at load %q", block, load)
	}
	tr := b.Traces[i]
	rate, err := OfferedRate(load, b.StableRateRequestsPerSec)
	if err != nil {
		return RunManifest{}, err
	}
	// Absolute, because LoadManifest resolves a relative trace path against the manifest's directory, which is not the bundle's.
	tracePath, err := filepath.Abs(filepath.Join(bundleDir, tr.Path))
	if err != nil {
		return RunManifest{}, err
	}
	engine := d.Engines[treatment]
	return RunManifest{
		SchemaVersion:   ManifestSchemaV3,
		Study:           b.Study,
		Arm:             VersionStudyArm(treatment, load),
		GatewayURL:      engineURL,
		TracePath:       tracePath,
		TraceChecksum:   tr.SHA256,
		Model:           d.Model,
		TokenizerRev:    d.TokenizerRevision,
		PromptCorpusSHA: PromptCorpusSHA256,
		TimeoutMs:       d.TimeoutMs,
		TimeoutScope:    TimeoutScopeWholeRequest,
		Seed:            tr.Seed,
		PrimaryEndpoint: EndpointVersionDecisionSet,
		Engine:          &engine,
		Sampling:        new(*st.Sampling),
		Cell: &CellIdentity{
			CampaignID:               b.CampaignID,
			Block:                    block,
			Position:                 slices.Index(ArmOrder(d.CampaignSeed, block), treatment) + 1,
			LoadPosition:             slices.Index(LoadOrder(block), load) + 1,
			OrderSeed:                d.CampaignSeed,
			StableRateRequestsPerSec: b.StableRateRequestsPerSec,
			BundleSHA256:             bundleSHA,
			OfferedRequestsPerSec:    rate,
		},
	}, nil
}

// WriteManifestFile writes m as YAML to a new file, refusing to replace one: a frozen cell's record is never rewritten.
func WriteManifestFile(path string, m RunManifest) error {
	data, err := yaml.Marshal(m)
	if err != nil {
		return err
	}
	return writeExclusive(path, data)
}

package bench

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"sigs.k8s.io/yaml"
)

// CampaignBundleFile is the bundle's file name inside its campaign directory.
const CampaignBundleFile = "bundle.json"

// CampaignInputs are what a session has read or measured by the time it writes the bundle, after calibration and before block 1.
type CampaignInputs struct {
	CampaignID string
	// CalibrationArtifact is the calibration result's path relative to the campaign directory; λ0 is read from it, never passed separately.
	CalibrationArtifact    string
	PriceUSDPerHour        float64
	PriceSource            string
	PriceReadAt            string
	OtherChargesUSDPerHour float64
}

// WriteCampaignBundle generates every trace, chooses the window from them, writes the bundle, and reads it back through LoadCampaignBundle.
//
// λ0 comes from the calibration artifact's own bytes, so the bundle cannot name a rate the calibration did not resolve.
// Nothing is overwritten: an existing trace or bundle means a campaign was already frozen in this directory.
// The returned bundle and sha are LoadCampaignBundle's, so what a session pairs its cells with is what the checker accepted.
func WriteCampaignBundle(dir, study string, in CampaignInputs) (*CampaignBundle, string, error) {
	st, ok := LookupStudy(study)
	if !ok || st.Version == nil {
		return nil, "", fmt.Errorf("study %q is not a version study", study)
	}
	d := st.Version
	if err := d.PreflightRefusal(); err != nil {
		return nil, "", err
	}
	if in.CampaignID == "" {
		return nil, "", errors.New("campaignId is empty")
	}
	if !(in.PriceUSDPerHour > 0) || in.PriceSource == "" {
		return nil, "", fmt.Errorf("price %v from %q is not a read price", in.PriceUSDPerHour, in.PriceSource)
	}
	art, artSum, err := readCalibration(filepath.Join(dir, in.CalibrationArtifact))
	if err != nil {
		return nil, "", err
	}
	type key struct {
		block int
		load  string
	}
	// Generated once at the longest window; every shorter window's trace is a prefix of it.
	longest := map[key][]TraceRow{}
	seeds := map[key]int64{}
	for block := 1; block <= d.PlannedBlocks+d.MaxReplacementBlocks; block++ {
		for _, l := range versionStudyLoads {
			seed, err := WorkloadSeed(d.CampaignSeed, block, l.Name)
			if err != nil {
				return nil, "", err
			}
			rate, err := OfferedRate(l.Name, art.StableRateRequestsPerSec)
			if err != nil {
				return nil, "", err
			}
			rows, err := d.VersionTrace(seed, rate, d.MaxMeasureSeconds)
			if err != nil {
				return nil, "", fmt.Errorf("block %d at %s: %w", block, l.Name, err)
			}
			longest[key{block, l.Name}], seeds[key{block, l.Name}] = rows, seed
		}
	}
	window, err := d.ChooseWindow(func(block int, load string, w int) (int, error) {
		return d.MeasuredRows(longest[key{block, load}], w), nil
	})
	if err != nil {
		return nil, "", err
	}
	b := CampaignBundle{
		Study: study, CampaignID: in.CampaignID,
		Model: d.Model, ModelRevision: d.ModelRevision, TokenizerRevision: d.TokenizerRevision, ChatTemplateSHA256: d.ChatTemplateSHA256,
		StableRateRequestsPerSec: art.StableRateRequestsPerSec,
		CalibrationArtifact:      in.CalibrationArtifact, CalibrationArtifactSHA256: artSum,
		WindowSeconds:   window,
		PriceUSDPerHour: in.PriceUSDPerHour, PriceSource: in.PriceSource, PriceReadAt: in.PriceReadAt,
		OtherChargesUSDPerHour: in.OtherChargesUSDPerHour,
		Images:                 map[string]string{},
	}
	for _, t := range versionStudyTreatments {
		b.Images[t] = d.Engines[t].Image
	}
	for block := 1; block <= d.PlannedBlocks+d.MaxReplacementBlocks; block++ {
		for _, l := range versionStudyLoads {
			k := key{block, l.Name}
			rate, _ := OfferedRate(l.Name, art.StableRateRequestsPerSec)
			// Regenerated at the chosen window rather than cut from the longest, so the file is exactly what VersionTrace says for it.
			rows, err := d.VersionTrace(seeds[k], rate, window)
			if err != nil {
				return nil, "", fmt.Errorf("block %d at %s: %w", block, l.Name, err)
			}
			var buf bytes.Buffer
			if err := WriteTrace(&buf, rows); err != nil {
				return nil, "", err
			}
			name := fmt.Sprintf("trace-b%d-%s.jsonl", block, l.Name)
			if err := writeExclusive(filepath.Join(dir, name), buf.Bytes()); err != nil {
				return nil, "", err
			}
			b.Traces = append(b.Traces, BundleTrace{
				Block: block, Load: l.Name, Path: name, SHA256: Checksum(buf.Bytes()), Seed: seeds[k],
				MeasuredRows: d.MeasuredRows(rows, window),
			})
		}
	}
	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		return nil, "", err
	}
	path := filepath.Join(dir, CampaignBundleFile)
	if err := writeExclusive(path, append(data, '\n')); err != nil {
		return nil, "", err
	}
	return LoadCampaignBundle(path)
}

// readCalibration reads a resolved calibration artifact and its sha256 from one read of its bytes.
func readCalibration(path string) (CalibrationArtifact, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return CalibrationArtifact{}, "", fmt.Errorf("calibration artifact: %w", err)
	}
	var art CalibrationArtifact
	if err := yaml.UnmarshalStrict(data, &art); err != nil {
		return CalibrationArtifact{}, "", fmt.Errorf("calibration artifact: %w", err)
	}
	if !art.Resolved {
		return CalibrationArtifact{}, "", fmt.Errorf("calibration was unresolved (%s); the session stops without a λ0", art.Reason)
	}
	return art, Checksum(data), nil
}

// writeExclusive creates path and writes data, refusing a file that already exists.
func writeExclusive(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("%s exists; a frozen campaign is never rewritten", path)
		}
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

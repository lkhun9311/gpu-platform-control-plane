package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// versionBundle freezes a version study campaign: every trace, the window and the bundle, after calibration and before block 1.
//
// λ0 is read from the calibration artifact inside the campaign directory, never from a flag, so the bundle cannot name a rate the calibration did not resolve.
func versionBundle(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("version-bundle", flag.ContinueOnError)
	dir := fs.String("dir", "", "campaign directory holding the calibration artifact; traces and bundle.json are written here")
	study := fs.String("study", bench.StudyVersionAsync, "registered version study id")
	in := bench.CampaignInputs{}
	fs.StringVar(&in.CampaignID, "campaign-id", "", "campaign id every cell will carry")
	fs.StringVar(&in.CalibrationArtifact, "calibration", "calibration.json", "calibration artifact, relative to -dir")
	fs.Float64Var(&in.PriceUSDPerHour, "price-usd-per-hour", 0, "on-demand instance price as read from the price source")
	fs.StringVar(&in.PriceSource, "price-source", "", "where the price was read")
	fs.StringVar(&in.PriceReadAt, "price-read-at", "", "RFC 3339 time the price was read")
	fs.Float64Var(&in.OtherChargesUSDPerHour, "other-charges-usd-per-hour", 0, "the session's other charges per hour")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" {
		return errors.New("-dir is required")
	}
	b, sum, err := bench.WriteCampaignBundle(*dir, *study, in)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "bundle %s sha256 %s: λ0 %v req/s, window %d s, %d traces\n",
		filepath.Join(*dir, bench.CampaignBundleFile), sum, b.StableRateRequestsPerSec, b.WindowSeconds, len(b.Traces))
	return err
}

// versionManifests writes the v3 manifest of every cell of the named blocks, from the bundle alone.
//
// The bundle is loaded, and so verified, before anything is written, and each manifest is loaded back as a cell would be replayed.
func versionManifests(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("version-manifests", flag.ContinueOnError)
	bundlePath := fs.String("bundle", "", "path of the campaign's bundle.json")
	engineURL := fs.String("engine-url", "", "base URL of the engine the cells are sent to")
	blocks := fs.String("blocks", "", "comma-separated block numbers, e.g. 1,2,3")
	outDir := fs.String("out", "", "directory the manifests are written to; existing files are never replaced")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// The engine URL is checked here because the miss would otherwise surface per cell, after the bundle was loaded.
	if *bundlePath == "" || *outDir == "" || *blocks == "" || *engineURL == "" {
		return errors.New("-bundle, -blocks, -out and -engine-url are required")
	}
	b, sum, err := bench.LoadCampaignBundle(*bundlePath)
	if err != nil {
		return err
	}
	st, ok := bench.LookupStudy(b.Study)
	if !ok {
		return fmt.Errorf("study %q is not registered", b.Study)
	}
	// Every manifest is built and every destination checked before the first is written.
	// The writer never replaces a file, so a refusal halfway would leave a frozen partial set that blocks the corrected retry.
	type pending struct {
		path string
		m    bench.RunManifest
	}
	var todo []pending
	seen := map[int]bool{}
	for f := range strings.SplitSeq(*blocks, ",") {
		block, err := strconv.Atoi(strings.TrimSpace(f))
		if err != nil {
			return fmt.Errorf("block %q is not a number", f)
		}
		if seen[block] {
			return fmt.Errorf("block %d is listed twice", block)
		}
		seen[block] = true
		for _, arm := range st.Arms {
			treatment, load, _ := bench.ParseVersionStudyArm(arm)
			m, err := bench.VersionCellManifest(b, sum, filepath.Dir(*bundlePath), block, treatment, load, *engineURL)
			if err != nil {
				return err
			}
			path := filepath.Join(*outDir, fmt.Sprintf("manifest-b%d-%s.yaml", block, arm))
			if _, err := os.Stat(path); err == nil {
				return fmt.Errorf("%s exists; a frozen cell's record is never rewritten", path)
			}
			todo = append(todo, pending{path, m})
		}
	}
	for _, p := range todo {
		if err := bench.WriteManifestFile(p.path, p.m); err != nil {
			return err
		}
		if _, err := bench.LoadManifest(p.path); err != nil {
			return fmt.Errorf("written manifest %s does not load: %w", p.path, err)
		}
		if _, err := fmt.Fprintln(out, p.path); err != nil {
			return err
		}
	}
	return nil
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// calibrationArtifactFile is the artifact version-bundle reads λ0 from, inside the campaign directory.
const calibrationArtifactFile = "calibration.json"

// versionCalibrate runs the registered ladder against treatment A's engine and writes the calibration artifact.
//
// Every rung's rows and observation are written as the rung ends, so a stopped session keeps the evidence of the rungs it ran.
func versionCalibrate(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("version-calibrate", flag.ContinueOnError)
	dir := fs.String("dir", "", "campaign directory; calibration.json and one file per rung are written here, never replaced")
	study := fs.String("study", bench.StudyVersionAsync, "registered version study id")
	engineURL := fs.String("engine-url", "", "base URL of treatment A's engine")
	metricsURL := fs.String("metrics-url", "", "the engine's Prometheus metrics URL, read to start every rung drained")
	model := fs.String("model", "", "served model name the requests carry")
	poll := fs.Duration("poll", 2*time.Second, "how often the drained check reads the engine")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" || *engineURL == "" || *metricsURL == "" || *model == "" {
		return errors.New("-dir, -engine-url, -metrics-url and -model are required")
	}
	st, ok := bench.LookupStudy(*study)
	if !ok || st.Version == nil || st.Sampling == nil {
		return fmt.Errorf("study %q is not a version study", *study)
	}
	if err := st.Version.PreflightRefusal(); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(*dir, calibrationArtifactFile)); err == nil {
		return fmt.Errorf("%s exists; a campaign is calibrated once", filepath.Join(*dir, calibrationArtifactFile))
	}
	sender := bench.NewHTTPSender(*engineURL, *model, nil, time.Duration(st.Version.TimeoutMs)*time.Millisecond,
		bench.SenderConn{MaxIdleConnsPerHost: 256, DrainForReuse: true})
	if err := sender.SetSampling(st.Sampling); err != nil {
		return err
	}
	runner := &bench.RungRunner{
		Design:    *st.Version,
		Sender:    sender,
		Queue:     bench.HTTPEngineQueue(&http.Client{Timeout: 10 * time.Second}, *metricsURL),
		PollEvery: *poll,
	}
	ctx := context.Background()
	res, err := runVersionCalibration(*dir, st.Version.Calibration, runner, func(rate float64, ordinal int) bench.RungClass {
		return runner.Probe(ctx, rate, ordinal)
	})
	if err != nil {
		return err
	}
	if res.Resolved {
		_, err = fmt.Fprintf(out, "calibration resolved: λ0 %v req/s after %d rungs\n", res.Rate, len(res.Rungs))
	} else {
		_, err = fmt.Fprintf(out, "%s after %d rungs; the session stops\n", res.Reason, len(res.Rungs))
	}
	return err
}

// rungRecord is one rung's evidence file: its observation, class and any reason it could not measure the engine.
type rungRecord struct {
	Ordinal     int                   `json:"ordinal"`
	Class       bench.RungClass       `json:"class"`
	Observation bench.RungObservation `json:"observation"`
	Error       string                `json:"error,omitempty"`
}

// runVersionCalibration runs the ladder with probe, writes every rung's evidence as it ends, and writes the artifact last.
//
// The artifact is written for an unresolved ladder too, because "calibration unresolved, stop" is a registered outcome and must be on record.
func runVersionCalibration(dir string, rule bench.CalibrationRule, runner *bench.RungRunner, probe func(rate float64, ordinal int) bench.RungClass) (bench.CalibrationResult, error) {
	// The destination is checked before the first request, because a rung whose evidence cannot be kept is paid for and lost.
	if err := calibrationDestinationReady(dir); err != nil {
		return bench.CalibrationResult{}, err
	}
	var writeErr error
	runner.OnRung = func(ordinal int, rows []bench.RawRow, o bench.RungObservation, cls bench.RungClass, err error) {
		rec := rungRecord{Ordinal: ordinal, Class: cls, Observation: o}
		if err != nil {
			rec.Error = err.Error()
		}
		data, mErr := json.MarshalIndent(rec, "", "  ")
		if mErr == nil {
			mErr = writeNew(filepath.Join(dir, fmt.Sprintf("calibration-rung-%d.json", ordinal)), append(data, '\n'))
		}
		var buf bytes.Buffer
		for _, r := range rows {
			line, lErr := json.Marshal(r)
			if lErr != nil {
				mErr = errors.Join(mErr, lErr)
				break
			}
			buf.Write(append(line, '\n'))
		}
		if mErr == nil {
			mErr = writeNew(filepath.Join(dir, fmt.Sprintf("calibration-rung-%d.jsonl", ordinal)), buf.Bytes())
		}
		writeErr = errors.Join(writeErr, mErr)
	}
	// After a failed write every later rung is refused without being sent; the ladder's invalid bound then ends it at no cost.
	res := rule.Run(func(rate float64, ordinal int) bench.RungClass {
		if writeErr != nil {
			return bench.RungInvalid
		}
		return probe(rate, ordinal)
	})
	if writeErr != nil {
		return res, fmt.Errorf("rung evidence: %w", writeErr)
	}
	art := bench.CalibrationArtifact{Resolved: res.Resolved, StableRateRequestsPerSec: res.Rate, Reason: res.Reason, Rungs: res.Rungs}
	data, err := json.MarshalIndent(art, "", "  ")
	if err != nil {
		return res, err
	}
	return res, writeNew(filepath.Join(dir, calibrationArtifactFile), append(data, '\n'))
}

// writeNew creates path and writes data, refusing a file that already exists.
func writeNew(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// calibrationDestinationReady refuses a directory that is missing, not writable, or already holds calibration evidence.
func calibrationDestinationReady(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("calibration directory: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("calibration directory %s is not a directory", dir)
	}
	existing, err := filepath.Glob(filepath.Join(dir, "calibration*"))
	if err != nil {
		return err
	}
	if len(existing) > 0 {
		return fmt.Errorf("%s already holds calibration evidence (%s); a campaign is calibrated once, into an empty place", dir, filepath.Base(existing[0]))
	}
	probe, err := os.CreateTemp(dir, ".write-check-*")
	if err != nil {
		return fmt.Errorf("calibration directory %s is not writable: %w", dir, err)
	}
	name := probe.Name()
	_ = probe.Close()
	return os.Remove(name)
}

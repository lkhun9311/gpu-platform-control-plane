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

const calibrationArtifactFile = bench.CalibrationArtifactFile

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
		Sampling:  *st.Sampling,
		Queue:     bench.HTTPEngineQueue(&http.Client{Timeout: 10 * time.Second}, *metricsURL),
		PollEvery: *poll,
	}
	// The ladder's registered ceiling is enforced, not only computed: past it the session's context ends and the ladder stops unresolved.
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(st.Version.Calibration.MaxSeconds())*time.Second)
	defer cancel()
	res, err := runVersionCalibration(ctx, *dir, st.Version.Calibration, runner, func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
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

// runVersionCalibration runs the ladder with probe, writes every rung's evidence as it ends, and writes the artifact last.
//
// The artifact is written for an unresolved ladder too, because "calibration unresolved, stop" is a registered outcome and must be on record.
func runVersionCalibration(ctx context.Context, dir string, rule bench.CalibrationRule, runner *bench.RungRunner, probe func(ctx context.Context, rate float64, ordinal int) bench.RungClass) (bench.CalibrationResult, error) {
	// The destination is checked before the first request, because a rung whose evidence cannot be kept is paid for and lost.
	if err := reserveCalibration(dir); err != nil {
		return bench.CalibrationResult{}, err
	}
	var writeErr error
	runner.OnRung = func(ordinal int, rows []bench.RawRow, o bench.RungObservation, cls bench.RungClass, err error) {
		rec := bench.CalibrationRungRecord{Ordinal: ordinal, Class: cls, Observation: o}
		if err != nil {
			rec.Error = err.Error()
		}
		data, mErr := json.MarshalIndent(rec, "", "  ")
		if mErr == nil {
			mErr = writeNew(filepath.Join(dir, bench.CalibrationRungFile(ordinal)), append(data, '\n'))
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
			mErr = writeNew(filepath.Join(dir, bench.CalibrationRungRowsFile(ordinal)), buf.Bytes())
		}
		writeErr = errors.Join(writeErr, mErr)
	}
	// After a failed write every later rung is refused without being sent; the ladder's invalid bound then ends it at no cost.
	res := rule.RunContext(ctx, func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
		if writeErr != nil {
			return bench.RungInvalid
		}
		return probe(ctx, rate, ordinal)
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

// writeNew creates path durably with data, refusing a file that already exists.
//
// Calibration evidence decides λ0, so a crash must leave each record whole or absent, never a torn file under its final name.
func writeNew(path string, data []byte) error {
	return bench.WriteNewFileDurably(path, data)
}

const calibrationLockFile = bench.CalibrationLockFile

// reserveCalibration refuses a directory that is missing or already holds calibration evidence, then reserves it atomically.
//
// The reservation is an exclusive create, so of two calibrations started together exactly one sends traffic.
func reserveCalibration(dir string) error {
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
	if err := writeNew(filepath.Join(dir, calibrationLockFile), []byte(time.Now().UTC().Format(time.RFC3339)+"\n")); err != nil {
		return fmt.Errorf("reserve calibration directory %s: %w", dir, err)
	}
	return nil
}

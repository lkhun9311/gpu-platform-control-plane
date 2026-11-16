package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// versionReadinessPort is the port every start publishes on loopback; one engine runs at a time, so one port serves all.
const versionReadinessPort = 8000

// versionReadiness runs the engine-readiness preflight (#594) on the instance: two image pulls, the model download,
// and three starts of each treatment, every record written as it ends.
//
// It is the paid session's only workload, so the study, the bound and the starts are the registration's and no flag moves them.
func versionReadiness(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("version-readiness", flag.ContinueOnError)
	dir := fs.String("dir", "", "an existing, empty directory every record is written to")
	hfCache := fs.String("hf-cache", "", "host directory for the model cache; must be absent or empty")
	compileCache := fs.String("compile-cache", "", "host directory for the per-image compile caches; must be absent or empty")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" || *hfCache == "" || *compileCache == "" {
		return errors.New("-dir, -hf-cache and -compile-cache are required")
	}
	st, ok := bench.LookupStudy(bench.StudyVersionAsync)
	if !ok || st.Version == nil || st.Sampling == nil {
		return fmt.Errorf("study %q is not registered as a version study", bench.StudyVersionAsync)
	}
	d := *st.Version
	engineURL := fmt.Sprintf("http://127.0.0.1:%d", versionReadinessPort)
	timeout := time.Duration(d.TimeoutMs) * time.Millisecond
	run := &bench.ReadinessRun{
		Study:  st.ID,
		Design: d,
		Engine: &bench.DockerEngine{
			Run: execRunner, HFCache: *hfCache, CompileCacheRoot: *compileCache,
			ServedName: d.Model, Port: versionReadinessPort, NamePrefix: "readiness",
		},
		EngineURL: engineURL,
		Sampling:  *st.Sampling,
		NewSender: func() (bench.Sender, error) {
			s := bench.NewHTTPSender(engineURL, d.Model, nil, timeout, bench.SenderConn{MaxIdleConnsPerHost: 8, DrainForReuse: true})
			return s, s.SetSampling(st.Sampling)
		},
		// No keep-alive: a pooled connection to a removed container would fail a poll for a reason that is not the engine.
		Health:     &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}},
		Logs:       dockerLogs,
		Out:        *dir,
		PollEvery:  500 * time.Millisecond,
		StateEvery: 10 * time.Second,
	}
	sum, err := run.Run(context.Background())
	if err != nil {
		return err
	}
	for _, p := range sum.Pulls {
		if _, err := fmt.Fprintf(out, "pull %s: %.1f s\n", p.Image, p.Seconds); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintf(out, "model download: %.1f s\n", sum.ModelDownload.Seconds); err != nil {
		return err
	}
	for _, t := range sum.Treatments {
		if _, err := fmt.Fprintf(out, "%s: first %s (%s, compile cache warmed by %v), warm %d of %d ready, max %s, median %s, missed %d, failed %d\n",
			t.Treatment, seconds(t.FirstSeconds), t.FirstOutcome, t.FirstCompileWarmedBy, t.WarmReady, t.WarmStarts,
			seconds(t.WarmMaxSeconds), seconds(t.WarmMedianSeconds), t.Missed, t.Failed); err != nil {
			return err
		}
	}
	if !sum.AllReady {
		_, err = fmt.Fprintf(out, "NOT EVERY START WAS READY within %d s; see the start records\n", sum.BoundSeconds)
	}
	return err
}

// seconds prints a figure the summary may leave out, so an absent one never reads as zero.
func seconds(v *float64) string {
	if v == nil {
		return "absent"
	}
	return fmt.Sprintf("%.1f s", *v)
}

// execRunner runs a command and puts its standard error into the error, where DockerEngine reads Docker's not-found answer.
func execRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// dockerLogs returns a container's log with both streams, since vLLM writes its own log to standard error.
func dockerLogs(ctx context.Context, containerID string) ([]byte, error) {
	out, err := exec.CommandContext(ctx, "docker", "logs", "--timestamps", containerID).CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("docker logs %s: %w", containerID, err)
	}
	return out, nil
}

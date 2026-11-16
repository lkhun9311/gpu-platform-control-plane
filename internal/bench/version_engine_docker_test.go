package bench

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/engineargs"
)

// recordingDocker answers docker commands from a script and records every call.
type recordingDocker struct {
	calls  [][]string
	answer func(args []string) ([]byte, error)
}

func (r *recordingDocker) run(_ context.Context, name string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, append([]string{name}, args...))
	if r.answer != nil {
		return r.answer(args)
	}
	return nil, nil
}

func testDockerEngine(r *recordingDocker) *DockerEngine {
	return &DockerEngine{
		Run: r.run, HFCache: "/srv/hf", CompileCacheRoot: "/srv/compile",
		ServedName: "qwen", Port: 8000, NamePrefix: "s1-test",
	}
}

// TestDockerRunArgsRenderTheReviewedCommand: the container receives exactly the argument list the controller renders, after the pinned image.
func TestDockerRunArgsRenderTheReviewedCommand(t *testing.T) {
	d := versionAsyncDesign()
	e := testDockerEngine(&recordingDocker{})
	args, err := e.RunArgs(d, TreatmentC, "visit-1")
	if err != nil {
		t.Fatal(err)
	}
	image := d.Engines[TreatmentC].Image
	i := slices.Index(args, image)
	if i < 0 {
		t.Fatalf("docker run args %v do not name the pinned image %s", args, image)
	}
	profile, _ := engineargs.ProfileArgs("v0.32.0", true)
	want := engineargs.Command(profile, engineargs.Deployment{Model: d.Model, Port: 8000, ServedName: "qwen", Revision: d.ModelRevision})
	if !slices.Equal(args[i+1:], want) {
		t.Fatalf("container args %v, want the rendered command %v", args[i+1:], want)
	}
	for _, need := range []string{"--gpus=all", "--shm-size=1g", "--publish=127.0.0.1:8000:8000"} {
		if !slices.Contains(args[:i], need) {
			t.Errorf("docker run args lack %s: %v", need, args[:i])
		}
	}
	// One compile cache per image: B and C share theirs, A has its own, and none is the container's writable layer.
	cache := func(tr string) string {
		a, _ := e.RunArgs(d, tr, "v")
		for _, x := range a {
			if strings.HasSuffix(x, ":/root/.cache/vllm") {
				return x
			}
		}
		return ""
	}
	if cache(TreatmentA) == "" || cache(TreatmentB) != cache(TreatmentC) || cache(TreatmentA) == cache(TreatmentB) {
		t.Fatalf("compile caches A %q B %q C %q, want one per image", cache(TreatmentA), cache(TreatmentB), cache(TreatmentC))
	}
	// Dev mode serves /server_info, which identity reads from the engine; every treatment gets it, before the image, and only on loopback.
	for _, tr := range []string{TreatmentA, TreatmentB, TreatmentC} {
		a, _ := e.RunArgs(d, tr, "v")
		img := slices.Index(a, d.Engines[tr].Image)
		if img < 0 || !slices.Contains(a[:img], "--env=VLLM_SERVER_DEV_MODE=1") || slices.Contains(a[img:], "--env=VLLM_SERVER_DEV_MODE=1") {
			t.Errorf("treatment %s docker args %v do not set dev mode on the container", tr, a)
		}
		if !slices.Contains(a[:img], "--publish=127.0.0.1:8000:8000") {
			t.Errorf("treatment %s publishes its dev-mode port beyond loopback: %v", tr, a)
		}
	}
}

// TestDockerRunArgsRefuseAnUnpinnedImage: a tag can move, so an engine runs only by digest.
func TestDockerRunArgsRefuseAnUnpinnedImage(t *testing.T) {
	d := versionAsyncDesign()
	e := testDockerEngine(&recordingDocker{})
	settings := d.Engines[TreatmentA]
	settings.Image = "vllm/vllm-openai:v0.27.1"
	d.Engines[TreatmentA] = settings
	if _, err := e.RunArgs(d, TreatmentA, "v"); err == nil {
		t.Fatal("an image without a digest was rendered")
	}
}

// TestDockerStartRecordsWhatRanAndStopConfirmsItEnded: every start leaves the container id, image and argv, and a stop is confirmed.
func TestDockerStartRecordsWhatRanAndStopConfirmsItEnded(t *testing.T) {
	d := versionAsyncDesign()
	gone := false
	r := &recordingDocker{answer: func(args []string) ([]byte, error) {
		switch args[0] {
		case "run":
			return []byte("abc123\n"), nil
		case "inspect":
			if gone {
				return nil, errors.New("No such object: abc123")
			}
			return []byte("running\n"), nil
		case "rm":
			gone = true
		}
		return nil, nil
	}}
	e := testDockerEngine(r)
	start, err := e.Start(context.Background(), d, TreatmentB, "b1-B")
	if err != nil {
		t.Fatal(err)
	}
	if start.ContainerID != "abc123" || start.Image != d.Engines[TreatmentB].Image || len(start.RunArgs) == 0 || start.Name != "s1-test-b1-B" {
		t.Fatalf("start record %+v", start)
	}
	if err := e.Stop(context.Background(), start); err != nil {
		t.Fatalf("stop: %v", err)
	}
	r.answer = func(args []string) ([]byte, error) { return []byte("running\n"), nil }
	if err := e.Stop(context.Background(), start); err == nil {
		t.Fatal("a container still present after rm was reported stopped")
	}
}

// TestDockerRunArgsRefuseAnotherReleasesImage: the arguments are rendered for the declared release, so the image must be that release's.
func TestDockerRunArgsRefuseAnotherReleasesImage(t *testing.T) {
	d := versionAsyncDesign()
	e := testDockerEngine(&recordingDocker{})
	c := d.Engines[TreatmentC]
	c.Image = d.Engines[TreatmentA].Image
	d.Engines[TreatmentC] = c
	if _, err := e.RunArgs(d, TreatmentC, "v"); err == nil || !strings.Contains(err.Error(), "reviewed") {
		t.Fatalf("v0.27.1's image under v0.32.0's arguments: %v", err)
	}
	// A mirror of the same digest is the same image.
	c.Image = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mirror/vllm-openai@" + imageDigest(versionAsyncDesign().Engines[TreatmentC].Image)
	d.Engines[TreatmentC] = c
	if _, err := e.RunArgs(d, TreatmentC, "v"); err != nil {
		t.Fatalf("a mirror of the reviewed digest was refused: %v", err)
	}
}

// TestDockerStartCleansUpOnlyItsOwnFailedStart: a container the daemon created for this attempt holds the GPU and is removed;
// a container that already had the name is another engine and is left alone; an unreachable daemon is reported.
func TestDockerStartCleansUpOnlyItsOwnFailedStart(t *testing.T) {
	d := versionAsyncDesign()
	notFound := errors.New("Error: No such object: s1-test-b1-A")
	for name, c := range map[string]struct {
		label      string
		labelErr   error
		wantRemove bool
		wantErr    string
		// cleanup is whether a container may be left holding the GPU, which the session must stop on.
		cleanup bool
	}{
		"created by this attempt": {label: "tok1", wantRemove: true, wantErr: "docker run"},
		"never created":           {labelErr: notFound, wantErr: "docker run"},
		"another engine's name":   {label: "tok0", wantErr: "not created by this attempt", cleanup: true},
		"daemon unreachable":      {labelErr: errors.New("Cannot connect to the Docker daemon"), wantErr: "cannot tell", cleanup: true},
	} {
		t.Run(name, func(t *testing.T) {
			removed := false
			r := &recordingDocker{answer: func(args []string) ([]byte, error) {
				switch {
				case args[0] == "run":
					return nil, context.DeadlineExceeded
				case args[0] == "inspect" && strings.Contains(args[1], "Labels"):
					return []byte(c.label + "\n"), c.labelErr
				case args[0] == "rm":
					removed = true
				case args[0] == "inspect":
					if removed {
						return nil, notFound
					}
					return []byte("running\n"), nil
				}
				return nil, nil
			}}
			e := testDockerEngine(r)
			e.NewToken = func() string { return "tok1" }
			_, err := e.Start(context.Background(), d, TreatmentA, "b1-A")
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Fatalf("err %v, want it to mention %q", err, c.wantErr)
			}
			if removed != c.wantRemove {
				t.Fatalf("removed %v, want %v (calls %v)", removed, c.wantRemove, r.calls)
			}
			if errors.Is(err, ErrEngineCleanup) != c.cleanup {
				t.Fatalf("err %v marked as a cleanup failure: %v, want %v", err, errors.Is(err, ErrEngineCleanup), c.cleanup)
			}
		})
	}
}

// TestDockerNotFoundReadsEveryReleasesWording: each Docker release words its not-found answer differently, and a missed
// one turns a removed container into an unconfirmed one that stops the session.
func TestDockerNotFoundReadsEveryReleasesWording(t *testing.T) {
	for _, msg := range []string{
		"Error: No such object: abc",
		// Docker 29.9.1, as captured in hack/version-readiness/2026-11-16-run2.
		"docker inspect --format={{.State.Status}} abc: exit status 1: error: no such object: abc",
		"Error response from daemon: No such container: abc",
		"Error response from daemon: No such image: vllm/vllm-openai@sha256:0a51",
		"error: no such image: vllm/vllm-openai@sha256:0a51",
	} {
		if !dockerNotFound(errors.New(msg)) {
			t.Errorf("%q not read as not found", msg)
		}
	}
	for _, msg := range []string{"Cannot connect to the Docker daemon", "permission denied", "context deadline exceeded"} {
		if dockerNotFound(errors.New(msg)) {
			t.Errorf("%q read as not found", msg)
		}
	}
}

// TestDockerStopNeedsDockerToSayTheContainerIsGone: an inspect that fails for another reason is not proof of absence.
func TestDockerStopNeedsDockerToSayTheContainerIsGone(t *testing.T) {
	r := &recordingDocker{answer: func(args []string) ([]byte, error) {
		if args[0] == "inspect" {
			return nil, errors.New("Cannot connect to the Docker daemon")
		}
		return nil, nil
	}}
	if err := testDockerEngine(r).Stop(context.Background(), EngineStart{ContainerID: "abc"}); !errors.Is(err, ErrEngineCleanup) || !strings.Contains(err.Error(), "cannot confirm") {
		t.Fatalf("stop with an unreachable daemon: %v", err)
	}
}

// TestDockerStartCountsReadinessFromBeforeDockerRun: the registered readiness bound includes the time `docker run`
// takes to return, so the start's origin is stamped before the call, not after it.
// Mutation that turns this red: stamp StartedAt after e.Run returns.
func TestDockerStartCountsReadinessFromBeforeDockerRun(t *testing.T) {
	var called time.Time
	r := &recordingDocker{answer: func(args []string) ([]byte, error) {
		if args[0] == "run" {
			called = time.Now()
			time.Sleep(50 * time.Millisecond)
			return []byte("cid\n"), nil
		}
		return nil, nil
	}}
	s, err := testDockerEngine(r).Start(context.Background(), versionAsyncDesign(), TreatmentA, "b1-A")
	if err != nil {
		t.Fatal(err)
	}
	if s.StartedAt.After(called) {
		t.Fatalf("start stamped at %v, after docker run was called at %v", s.StartedAt, called)
	}
}

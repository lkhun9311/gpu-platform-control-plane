package bench

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/engineargs"
)

// CommandRunner runs one command and returns its standard output; tests replace it, the session uses os/exec.
type CommandRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

// DockerEngine starts a treatment's vLLM engine as one container, with the arguments the controller renders for a Pod.
//
// The command after the image comes from internal/engineargs, the same renderer the controller uses, so a container
// and a Pod of the same release and async choice run the same argument list.
type DockerEngine struct {
	Run CommandRunner
	// HFCache is the host directory holding the model and tokenizer, filled once during setup.
	HFCache string
	// CompileCacheRoot holds one compile cache per image, so an image's cache survives every start and is never another's.
	CompileCacheRoot string
	ServedName       string
	Port             int32
	// NamePrefix names the session's containers, so a container is traced to its campaign and visit.
	NamePrefix string
	// NewToken makes an attempt token; nil uses a random one.
	NewToken func() string
}

// EngineStart is the record of one engine start, written before the engine is used.
type EngineStart struct {
	Treatment   string
	Name        string
	ContainerID string
	Image       string
	// RunArgs is the full `docker run` argument list, the image and the engine command included.
	RunArgs   []string
	StartedAt time.Time
}

// RunArgs is the `docker run` argument list for one visit of a treatment.
//
// The container gets the GPU, a 1 GiB /dev/shm as the controller gives a Pod (the engine's ring buffer outgrows the
// default 64 MiB), the shared model cache, its image's own compile cache, and a port published on loopback only.
func (e *DockerEngine) RunArgs(d VersionStudyDesign, treatment, visit string) ([]string, error) {
	s, ok := d.Engines[treatment]
	if !ok {
		return nil, fmt.Errorf("treatment %q is not registered", treatment)
	}
	if !digestPinned(s.Image) {
		return nil, fmt.Errorf("treatment %s image %q is not pinned by digest", treatment, s.Image)
	}
	if s.AsyncScheduling == nil {
		return nil, fmt.Errorf("treatment %s states no async-scheduling choice", treatment)
	}
	// The arguments are rendered for the declared release, so the image launched must be the one that release was reviewed on.
	// A mirror carrying the same digest is the same image, as the controller's CEL rule also accepts.
	rel, ok := engineargs.Releases()[s.VLLMVersion]
	if !ok {
		return nil, fmt.Errorf("treatment %s names release %q, which has no reviewed arguments", treatment, s.VLLMVersion)
	}
	if imageDigest(s.Image) != rel.Digest {
		return nil, fmt.Errorf("treatment %s runs image %q, but release %s was reviewed on %s", treatment, s.Image, s.VLLMVersion, rel.Digest)
	}
	profile, err := engineargs.ProfileArgs(s.VLLMVersion, *s.AsyncScheduling)
	if err != nil {
		return nil, err
	}
	digest := strings.TrimPrefix(imageDigest(s.Image), "sha256:")
	command := engineargs.Command(profile, engineargs.Deployment{
		Model: d.Model, Port: e.Port, ServedName: e.ServedName, Revision: d.ModelRevision,
	})
	args := make([]string, 0, 10+len(command))
	args = append(args,
		"run", "--detach",
		"--name="+e.NamePrefix+"-"+visit,
		"--gpus=all",
		"--shm-size=1g",
		fmt.Sprintf("--publish=127.0.0.1:%d:%d", e.Port, e.Port),
		"--volume="+e.HFCache+":/root/.cache/huggingface",
		"--volume="+filepath.Join(e.CompileCacheRoot, digest)+":/root/.cache/vllm",
		"--label=study="+e.NamePrefix,
		s.Image,
	)
	return append(args, command...), nil
}

// attemptLabel marks the container one start attempt created, so cleanup removes that container and never another of the same name.
const attemptLabel = "platform.lkhun9311.github.io/attempt"

// Start runs a treatment's container and returns its start record; readiness is the caller's next step.
//
// Each attempt labels its container with a fresh token.
// If docker run fails, the daemon may still have created the container, which would keep the GPU and the port;
// cleanup removes it only if it carries this attempt's token, so a name conflict with a container already running is
// reported and left alone.
func (e *DockerEngine) Start(ctx context.Context, d VersionStudyDesign, treatment, visit string) (EngineStart, error) {
	args, err := e.RunArgs(d, treatment, visit)
	if err != nil {
		return EngineStart{}, err
	}
	token := e.token()
	image := slices.Index(args, d.Engines[treatment].Image)
	args = slices.Insert(args, image, "--label="+attemptLabel+"="+token)
	name := e.NamePrefix + "-" + visit
	out, err := e.Run(ctx, "docker", args...)
	id := strings.TrimSpace(string(out))
	if err != nil || id == "" {
		if err == nil {
			err = errors.New("docker run returned no container id")
		}
		runErr := fmt.Errorf("docker run for %s: %w", treatment, err)
		if cerr := e.removeOwned(name, token); cerr != nil {
			return EngineStart{}, errors.Join(runErr, fmt.Errorf("%w: %w", ErrEngineCleanup, cerr))
		}
		return EngineStart{}, runErr
	}
	return EngineStart{
		Treatment: treatment, Name: name, ContainerID: id,
		Image: d.Engines[treatment].Image, RunArgs: args, StartedAt: time.Now().UTC(),
	}, nil
}

// ErrEngineCleanup marks an engine whose container could not be confirmed removed.
//
// Such a container may still hold the GPU and the port, so the next engine would share them: the session stops on it,
// where a failed start that left nothing behind is only the engine's outcome.
var ErrEngineCleanup = errors.New("engine cleanup")

// token is a fresh attempt token; NewToken replaces it in tests.
func (e *DockerEngine) token() string {
	if e.NewToken != nil {
		return e.NewToken()
	}
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Stop removes the container and confirms it is gone, because an engine left running would share the GPU with the next.
func (e *DockerEngine) Stop(ctx context.Context, s EngineStart) error {
	if _, err := e.Run(ctx, "docker", "rm", "--force", s.ContainerID); err != nil {
		return fmt.Errorf("%w: docker rm %s: %w", ErrEngineCleanup, s.ContainerID, err)
	}
	if err := e.confirmGone(ctx, s.ContainerID); err != nil {
		return fmt.Errorf("%w: %w", ErrEngineCleanup, err)
	}
	return nil
}

// dockerCleanupTimeout bounds removing an attempted container, on its own context so a start that failed by its context expiring still cleans up.
const dockerCleanupTimeout = 60 * time.Second

// removeOwned deletes the container named name if this attempt created it, and confirms it is gone.
func (e *DockerEngine) removeOwned(name, token string) error {
	ctx, cancel := context.WithTimeout(context.Background(), dockerCleanupTimeout)
	defer cancel()
	out, err := e.Run(ctx, "docker", "inspect", "--format={{index .Config.Labels \""+attemptLabel+"\"}}", name)
	switch {
	case err != nil && dockerNotFound(err):
		// Nothing was created, so nothing holds the GPU.
		return nil
	case err != nil:
		return fmt.Errorf("cannot tell whether container %s was created: %w", name, err)
	case strings.TrimSpace(string(out)) != token:
		return fmt.Errorf("container %s exists but was not created by this attempt; it is left running", name)
	}
	if _, err := e.Run(ctx, "docker", "rm", "--force", name); err != nil {
		return fmt.Errorf("docker rm %s after a failed start: %w", name, err)
	}
	return e.confirmGone(ctx, name)
}

// confirmGone succeeds only on Docker's own not-found answer; any other inspect failure leaves the container's state unknown.
func (e *DockerEngine) confirmGone(ctx context.Context, ref string) error {
	_, err := e.Run(ctx, "docker", "inspect", "--format={{.State.Status}}", ref)
	switch {
	case err == nil:
		return fmt.Errorf("container %s is still present after docker rm; it may hold the GPU", ref)
	case dockerNotFound(err):
		return nil
	default:
		return fmt.Errorf("cannot confirm container %s is gone: %w", ref, err)
	}
}

// dockerNotFound reads Docker's answer for an object that does not exist.
//
// A CommandRunner must put the command's standard error into its error, which is where Docker writes this.
func dockerNotFound(err error) bool {
	msg := err.Error()
	return strings.Contains(msg, "No such object") || strings.Contains(msg, "No such container")
}

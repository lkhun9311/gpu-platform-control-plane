// Package engineargs renders a vLLM engine's command line from reviewed release rows, with no Kubernetes types.
//
// The controller renders a Pod's arguments from it, and the version study's docker engines render a container's from it,
// so the two cannot drift: there is one list per release, and one order for the deployment flags after it.
package engineargs

import (
	"fmt"
	"maps"
	"slices"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// HoldCapPrefillThreshold is the engine's per-step prefill cap HoldCap pairs with the gateway's serial-prefill admission.
// It is the only cap measured, so it is a constant: a field would ship an unmeasured setting.
const HoldCapPrefillThreshold = 384

// Release is a vLLM release the experimental profile may run, with its flags spelled as that release accepts them.
//
// A newer release may rename or drop a flag, so a row is added only after its args were checked against that release.
type Release struct {
	// Digest is the image the flags were reviewed against; the CRD's CEL rule repeats it.
	Digest string
	// Args are the measured A10G settings without the async-scheduling flag, which the caller chooses.
	Args []string
	// AsyncOn and AsyncOff are this release's spelling of the two async-scheduling choices.
	AsyncOn, AsyncOff string
}

// reviewedArgs is the measured A10G profile, written out per release so a newer row is read, not inherited.
func reviewedArgs() []string {
	return []string{
		"--dtype=half",
		"--max-model-len=16384",
		"--max-num-seqs=64",
		"--gpu-memory-utilization=0.90",
		"--no-enable-prefix-caching",
		"--max-num-batched-tokens=512",
		"--scheduling-policy=priority",
	}
}

// releases are the reviewed rows; the CRD enum on experimental.release and the controller's tests keep them equal.
var releases = map[string]Release{
	platformv1.VLLMReleaseV0271: {
		Digest: platformv1.VLLMV0271Digest, Args: reviewedArgs(),
		AsyncOn: "--async-scheduling", AsyncOff: "--no-async-scheduling",
	},
	// Reviewed against the source at the image's build commit, flag by flag, in hack/engine-flag-reviews/vllm-v0.32.0-async-*.json.
	// The async flag is always rendered, because v0.32.0 enables async scheduling when the flag is absent.
	platformv1.VLLMReleaseV0320: {
		Digest: platformv1.VLLMV0320Digest, Args: reviewedArgs(),
		AsyncOn: "--async-scheduling", AsyncOff: "--no-async-scheduling",
	},
}

// Releases returns a copy of the reviewed rows, so no caller can change them.
func Releases() map[string]Release {
	out := make(map[string]Release, len(releases))
	for name, r := range maps.All(releases) {
		r.Args = slices.Clone(r.Args)
		out[name] = r
	}
	return out
}

// ProfileArgs is a reviewed release's profile with the async choice last, where the validated profiles put it.
func ProfileArgs(release string, async bool) ([]string, error) {
	r, ok := releases[release]
	if !ok {
		return nil, fmt.Errorf("release %q has no reviewed arguments", release)
	}
	flag := r.AsyncOff
	if async {
		flag = r.AsyncOn
	}
	return append(slices.Clone(r.Args), flag), nil
}

// Deployment is what one engine adds to its profile: the model it serves, where it listens, and the revision it pins.
type Deployment struct {
	// Model is the Hub repository, without any hf:// prefix.
	Model      string
	Port       int32
	ServedName string
	// Revision pins both the weights and the tokenizer to one Hub commit.
	Revision string
	// HoldCap appends the engine's per-step prefill cap that HoldCap was measured with.
	HoldCap bool
}

// Command is the argument list `vllm serve` receives: the model, the profile, then the deployment flags.
func Command(profile []string, d Deployment) []string {
	args := make([]string, 0, len(profile)+6)
	args = append(args, d.Model)
	args = append(args, profile...)
	args = append(args,
		fmt.Sprintf("--port=%d", d.Port),
		"--served-model-name="+d.ServedName,
		"--revision="+d.Revision,
		"--tokenizer-revision="+d.Revision,
	)
	if d.HoldCap {
		args = append(args, fmt.Sprintf("--long-prefill-token-threshold=%d", HoldCapPrefillThreshold))
	}
	return args
}

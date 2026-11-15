package bench

import (
	"errors"
	"fmt"
	"slices"
	"strings"
)

// deploymentFlags are the flags every deployment adds to the profile: where it listens, what it calls the model, and
// the revision it pins, which identity checks separately. They are not part of the reviewed profile.
var deploymentFlags = []string{"--port", "--served-model-name", "--revision", "--tokenizer-revision"}

// ParseProfileArgs reduces a running engine's command line to its profile arguments, in order and in --flag=value form.
//
// The command must be `vllm serve <model> ...`. The positional model and the deployment flags are removed; a flag
// that takes a value in the next word is joined to it. A flag missing its value, or given twice, is refused, because
// either would make the comparison read an argv the engine did not run.
func ParseProfileArgs(argv []string) ([]string, error) {
	if len(argv) < 3 || argv[0] != "vllm" || argv[1] != "serve" || strings.HasPrefix(argv[2], "-") {
		return nil, fmt.Errorf("command line %q is not `vllm serve <model> ...`", argv)
	}
	var out []string
	seen := map[string]bool{}
	for i := 3; i < len(argv); i++ {
		a := argv[i]
		if !strings.HasPrefix(a, "--") {
			return nil, fmt.Errorf("argument %q is not a flag", a)
		}
		name, value, hasValue := strings.Cut(a, "=")
		// A bare flag followed by a non-flag word takes that word as its value.
		if !hasValue && i+1 < len(argv) && !strings.HasPrefix(argv[i+1], "--") {
			value, hasValue = argv[i+1], true
			i++
		}
		if seen[name] {
			return nil, fmt.Errorf("flag %s is given twice", name)
		}
		seen[name] = true
		if slices.Contains(deploymentFlags, name) {
			if !hasValue {
				return nil, fmt.Errorf("flag %s has no value", name)
			}
			continue
		}
		if hasValue {
			out = append(out, name+"="+value)
		} else {
			out = append(out, name)
		}
	}
	return out, nil
}

// CheckRuntime compares a running engine with the registration alone, so a wrong engine is refused at preflight,
// before calibration or the bundle exist. CompareRuntime adds the bundle's frozen images on top of it.
func (d VersionStudyDesign) CheckRuntime(treatment string, rt RuntimeIdentity) error {
	want, ok := d.Engines[treatment]
	if !ok {
		return fmt.Errorf("treatment %q is not registered", treatment)
	}
	switch {
	case rt.ModelRevision != d.ModelRevision:
		return fmt.Errorf("engine serves model revision %q, the registration %q", rt.ModelRevision, d.ModelRevision)
	case rt.TokenizerRevision != d.TokenizerRevision:
		return fmt.Errorf("engine uses tokenizer %q, the registration %q", rt.TokenizerRevision, d.TokenizerRevision)
	case rt.ChatTemplateSHA256 != d.ChatTemplateSHA256:
		return fmt.Errorf("engine applies chat template %q, the registration %q", rt.ChatTemplateSHA256, d.ChatTemplateSHA256)
	}
	reviewed, ok := d.ReviewedProfileArgs[treatment]
	if !ok || len(reviewed) == 0 {
		return errors.New("treatment " + treatment + " has no reviewed profile arguments to compare with")
	}
	if !slices.Equal(rt.ProfileArgs, reviewed) {
		return fmt.Errorf("engine of treatment %s runs arguments %v, the reviewed profile is %v", treatment, rt.ProfileArgs, reviewed)
	}
	got := rt.Settings
	got.VLLMVersion, got.Image = rt.VLLMVersion, rt.Image
	if diff := want.Diff(got); diff != "" {
		return fmt.Errorf("engine of treatment %s: %s", treatment, diff)
	}
	return nil
}

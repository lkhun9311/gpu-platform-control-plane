package bench

import (
	"errors"
	"fmt"
	"slices"
	"strings"
)

// deploymentFlags are the flags every deployment adds to the profile: where it listens, what it calls the model, and
// the revision it pins, which identity checks separately.
// They are not part of the reviewed profile.
var deploymentFlags = []string{"--port", "--served-model-name", "--revision", "--tokenizer-revision"}

// ParseProfileArgs reduces a running engine's command line to its profile arguments, in order and in --flag=value form.
//
// The command must be `vllm serve <model> ...`.
// The positional model and the deployment flags are removed; a flag that takes a value in the next word is joined to
// it.
// A flag missing its value, or given twice, is refused, because either would make the comparison read an argv the
// engine did not run.
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
// before calibration or the bundle exist.
// CompareRuntime adds the bundle's frozen images on top of it.
//
// It is the complete check: an identity that leaves any field unproven is refused, because the registration fixes every one.
func (d VersionStudyDesign) CheckRuntime(treatment string, rt RuntimeIdentity) error {
	unproven, err := d.CheckObservedRuntime(treatment, rt)
	if err != nil {
		return err
	}
	if len(unproven) > 0 {
		return fmt.Errorf("engine of treatment %s: %s not proven by what was read from it", treatment, strings.Join(unproven, ", "))
	}
	return nil
}

// CheckObservedRuntime compares every field the reader observed with the registration and returns the fields it could not observe.
//
// A field is skipped only when it is empty and named in rt.Unproven, so a reader cannot drop a check by leaving a value out silently.
// Only the image, the chat template and the command line may be unproven; the release, the revisions and every registered setting must be observed.
// The caller decides whether the returned gap is acceptable and must record it beside whatever it measures.
func (d VersionStudyDesign) CheckObservedRuntime(treatment string, rt RuntimeIdentity) ([]string, error) {
	want, ok := d.Engines[treatment]
	if !ok {
		return nil, fmt.Errorf("treatment %q is not registered", treatment)
	}
	empty := map[string]bool{
		UnprovenImage:        rt.Image == "",
		UnprovenChatTemplate: rt.ChatTemplateSHA256 == "",
		UnprovenProfileArgs:  rt.ProfileArgs == nil,
	}
	skip := map[string]bool{}
	for _, name := range rt.Unproven {
		isEmpty, known := empty[name]
		switch {
		case !known:
			return nil, fmt.Errorf("%q cannot be unproven; only %s may be", name, strings.Join(unprovenFields, ", "))
		case skip[name]:
			return nil, fmt.Errorf("%q is named unproven twice", name)
		case !isEmpty:
			return nil, fmt.Errorf("%q is named unproven but carries a value", name)
		}
		skip[name] = true
	}
	switch {
	// A revision alone does not name the weights: vLLM ignores --revision for a local path, so the model itself is compared.
	case rt.Model != d.Model:
		return nil, fmt.Errorf("engine serves model %q, the registration %q", rt.Model, d.Model)
	case rt.Tokenizer != d.Model:
		return nil, fmt.Errorf("engine uses tokenizer %q, the registration's model is %q", rt.Tokenizer, d.Model)
	case rt.ModelRevision != d.ModelRevision:
		return nil, fmt.Errorf("engine serves model revision %q, the registration %q", rt.ModelRevision, d.ModelRevision)
	case rt.TokenizerRevision != d.TokenizerRevision:
		return nil, fmt.Errorf("engine uses tokenizer %q, the registration %q", rt.TokenizerRevision, d.TokenizerRevision)
	case !skip[UnprovenChatTemplate] && rt.ChatTemplateSHA256 != d.ChatTemplateSHA256:
		return nil, fmt.Errorf("engine applies chat template %q, the registration %q", rt.ChatTemplateSHA256, d.ChatTemplateSHA256)
	}
	reviewed, ok := d.ReviewedProfileArgs[treatment]
	if !ok || len(reviewed) == 0 {
		return nil, errors.New("treatment " + treatment + " has no reviewed profile arguments to compare with")
	}
	if !skip[UnprovenProfileArgs] && !slices.Equal(rt.ProfileArgs, reviewed) {
		return nil, fmt.Errorf("engine of treatment %s runs arguments %v, the reviewed profile is %v", treatment, rt.ProfileArgs, reviewed)
	}
	got := rt.Settings
	got.VLLMVersion, got.Image = rt.VLLMVersion, rt.Image
	// An unproven image is compared as absent on both sides; the registered digest is never put in its place.
	if skip[UnprovenImage] {
		want.Image = ""
	}
	if diff := want.Diff(got); diff != "" {
		return nil, fmt.Errorf("engine of treatment %s: %s", treatment, diff)
	}
	var unproven []string
	for _, name := range unprovenFields {
		if skip[name] {
			unproven = append(unproven, name)
		}
	}
	return unproven, nil
}

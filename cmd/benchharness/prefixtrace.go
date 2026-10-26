package main

import (
	"flag"
	"fmt"
	"slices"
	"strings"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// prefixLoadFlags are gen-trace's flags that shape a load, which a shared-prefix study's registration fixes instead.
var prefixLoadFlags = []string{
	"duration-ms", "rate", "premium-prompt-chars", "noisy-prompt-chars", "premium-output-tokens", "noisy-output-tokens",
	"premium-weight", "noisy-weight", "probe-weight", "probe-under-chars", "probe-over-chars", "premium-rate",
	"noisy-rate", "probe-rate", "timeout-ms",
}

// prefixTrace writes a shared-prefix study's trace for one seed, from its registered load alone.
//
// A load flag is refused rather than ignored: a caller who passed one meant a different load, and a trace that
// silently ignored it would carry the study's name over a load nobody asked for.
func prefixTrace(st bench.Study, fs *flag.FlagSet, out traceOutputs, control, warmup bool) error {
	if warmup {
		return fmt.Errorf("study %s registers no warm-up trace; its cells warm each engine by Pod IP", st.ID)
	}
	if st.PrefixLoad == nil {
		return fmt.Errorf("study %s declares shared-prefix arrivals and registers no load", st.ID)
	}
	var passed []string
	fs.Visit(func(f *flag.Flag) {
		if slices.Contains(prefixLoadFlags, f.Name) {
			passed = append(passed, "--"+f.Name)
		}
	})
	if len(passed) > 0 {
		return fmt.Errorf("study %s fixes its load in its registration, so %s cannot be passed", st.ID, strings.Join(passed, ", "))
	}
	if !slices.Contains(st.Arms, out.arm) {
		return fmt.Errorf("arm %q is not one of study %s's arms %v", out.arm, st.ID, st.Arms)
	}
	rows, err := bench.GeneratePrefixTrace(*st.PrefixLoad, out.seed, control)
	if err != nil {
		return err
	}
	if st.FixesOutputAtCap {
		if err := bench.FixOutputAtCap(rows); err != nil {
			return err
		}
	}
	out.timeoutMs = st.PrefixLoad.TimeoutMs
	return writeTraceAndManifest(rows, out, map[string]int{bench.PremiumTenant: st.PrefixLoad.OutputTokens})
}

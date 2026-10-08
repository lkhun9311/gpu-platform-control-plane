package main

import (
	"context"
	"flag"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// verifyExactTokens checks a study's frozen exact token counts against a live engine.
//
// The pilot stamps its traces from counts frozen in the registry, so no arm sends a calibration probe; this is
// where the frozen counts meet the engine they claim to describe (design page, build item 18). It sends one probe
// per frozen length straight to the engine, each with the request ID calib-<length>, which every measurement
// excludes, and refuses if the engine reports a different count for any of them.
func verifyExactTokens(args []string) error {
	fs := flag.NewFlagSet("verify-exact-tokens", flag.ExitOnError)
	study := fs.String("study", "", "study whose frozen counts are checked (required)")
	engineURL := fs.String("engine-url", "", "the engine's own base URL, not the gateway's (required)")
	model := fs.String("model", "", "model name the engine serves (required)")
	timeout := fs.Duration("timeout", 120*time.Second, "per-probe timeout")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *study == "" || *engineURL == "" || *model == "" {
		return fmt.Errorf("-study, -engine-url and -model are all required")
	}
	st, ok := bench.LookupStudy(*study)
	if !ok || st.FrozenExactTokens == nil {
		return fmt.Errorf("study %q froze no exact token counts", *study)
	}
	lengths := make([]int, 0, len(st.FrozenExactTokens))
	for n := range st.FrozenExactTokens {
		lengths = append(lengths, n)
	}
	sort.Ints(lengths)

	sender := bench.NewHTTPSender(*engineURL, *model, nil, *timeout, bench.SenderConn{MaxIdleConnsPerHost: 2, DrainForReuse: true})
	// The ID is calib-<index>, and the index is the prompt length, so each probe names what it measured.
	sender.SetRequestIDPrefix("calib")
	var wrong []string
	for _, n := range lengths {
		// One output token: the prompt count is what is measured, and generation is only a cost.
		res := sender.Send(context.Background(), bench.TraceRow{Index: n, PromptLenChars: n, MaxOutputTokens: 1}, time.Now().UnixNano())
		want := st.FrozenExactTokens[n]
		fmt.Printf("%7d chars -> engine %d tokens, frozen %d\n", n, res.PromptTokens, want)
		if res.PromptTokens <= 0 {
			wrong = append(wrong, fmt.Sprintf("%d chars: the engine reported no count (status %d, error %q)", n, res.HTTPStatus, res.ErrorKind))
		} else if res.PromptTokens != want {
			wrong = append(wrong, fmt.Sprintf("%d chars: the engine counts %d and the study froze %d", n, res.PromptTokens, want))
		}
	}
	if len(wrong) > 0 {
		return fmt.Errorf("study %s's frozen exact token counts do not describe this engine: %s", st.ID, strings.Join(wrong, "; "))
	}
	return nil
}

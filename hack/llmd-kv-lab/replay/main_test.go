package main

import (
	"strings"
	"testing"
)

// The replay's claim is that only the prompt lengths differ from shared-942, so the arrivals and draws must survive
// scaling exactly.
// Mutation that turns this red: scale DurationMs or RatePerSec with the lengths, or drop the frozen-checksum check.
func TestScaledTraceKeepsTheFrozenArrivalsAndGroups(t *testing.T) {
	rows, load, err := scaledTrace(942, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 482 {
		t.Fatalf("shared-942 has 482 requests, the scaled trace %d", len(rows))
	}
	if load.PromptChars != 4100 || load.PrefixChars != 4000 || load.Groups != 77 {
		t.Fatalf("scaled load %+v", load)
	}
	if rows[0].OffsetMs != 1583 || rows[6].OffsetMs != 3881 {
		t.Fatalf("arrivals moved: row 0 at %d, row 6 at %d (run 2 recorded 1583 and 3881)", rows[0].OffsetMs, rows[6].OffsetMs)
	}
}

func TestUnfrozenSeedIsRefused(t *testing.T) {
	if _, _, err := scaledTrace(944, 10); err == nil {
		t.Fatal("the control seed has no shared-trace checksum here and was accepted")
	}
}

// A labelled series must be read by name alone, and an unrelated series that shares a prefix must not be summed in.
func TestParseGaugesSumsLabelledSeries(t *testing.T) {
	got := parseGauges(`# HELP x
vllm:num_requests_waiting{model_name="m"} 3
vllm:num_requests_waiting_by_reason{reason="x"} 9
vllm:num_requests_running{model_name="m"} 1
vllm:prefix_cache_hits_total{model_name="m"} 1.5e+03
`)
	if got["vllm:num_requests_waiting"] != 3 || got["vllm:num_requests_running"] != 1 || got["vllm:prefix_cache_hits_total"] != 1500 {
		t.Fatalf("parsed %v", got)
	}
}

// A stream that never says [DONE] is a failure, and an absent cached count stays -1 rather than becoming 0.
func TestReadStreamRecordsUsageAndRefusesATruncatedStream(t *testing.T) {
	var rec record
	readStream(strings.NewReader("data: {\"choices\":[{\"text\":\"\"}]}\n\ndata: {\"choices\":[{\"text\":\"hi\"}]}\n\n"+
		"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":8}}}\n\ndata: [DONE]\n\n"), &rec)
	if !rec.Done || rec.Error != "" || rec.CachedTokens != 8 || rec.PromptTokens != 10 || rec.FirstTokenNanos == 0 {
		t.Fatalf("complete stream read as %+v", rec)
	}
	var cut record
	readStream(strings.NewReader("data: {\"choices\":[{\"text\":\"hi\"}]}\n\n"), &cut)
	if cut.Done || cut.Error == "" || cut.CachedTokens != -1 {
		t.Fatalf("truncated stream read as %+v", cut)
	}
}

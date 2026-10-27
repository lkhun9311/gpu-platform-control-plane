package main

import (
	"strings"
	"testing"
)

// The stub's cache is what the routing rehearsal's endpoints are read from, so it must hit a repeated prefix, miss a
// different one, and forget the oldest at capacity.
// Mutation that turns this red: count hits past the first missing block, or never evict.
func TestStubPrefixCacheHitsAndEvicts(t *testing.T) {
	c := newStubPrefixCache(16 * 4) // four blocks
	a := strings.Repeat("a", 4*stubBlockChars)
	if u := c.lookup(a); u != 64 {
		t.Fatalf("a cold prompt left %d tokens uncached, want 64", u)
	}
	if u := c.lookup(a); u != 0 || c.hits != 64 || c.queries != 128 {
		t.Fatalf("a repeated prompt: uncached %d, hits %d, queries %d", u, c.hits, c.queries)
	}
	// A prompt sharing only its first block hits that block alone.
	b := a[:stubBlockChars] + strings.Repeat("b", 3*stubBlockChars)
	if u := c.lookup(b); u != 48 {
		t.Fatalf("a one-block shared prefix left %d uncached, want 48", u)
	}
	// Capacity is four blocks: b's three new blocks evicted three of a's, so a's chain now breaks at its second block.
	if u := c.lookup(a); u != 48 {
		t.Fatalf("after eviction a left %d uncached, want 48", u)
	}
	var out strings.Builder
	c.writeMetrics(&out)
	for _, s := range []string{"vllm:prefix_cache_queries_total{", "vllm:prefix_cache_hits_total{", `enable_prefix_caching="True"`} {
		if !strings.Contains(out.String(), s) {
			t.Fatalf("metrics lack %s:\n%s", s, out.String())
		}
	}
}

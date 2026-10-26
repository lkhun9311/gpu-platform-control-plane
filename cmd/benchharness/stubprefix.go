package main

import (
	"container/list"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"strings"
	"sync"
	"time"
)

// stubBlockChars is the stub's stand-in for one engine block: vLLM's 16 tokens at the gateway's four characters a
// token. The stub has no tokenizer, so this is a model of the engine's cache, not a copy of it.
const stubBlockChars = 64

// stubPrefixCache models vLLM's automatic prefix caching closely enough to rehearse a routing study: a chain of
// block hashes over the prompt, a hit for each leading block already held, LRU eviction at a capacity, and the two
// counters vLLM exports under the names the pinned image uses (vllm:prefix_cache_queries_total and
// vllm:prefix_cache_hits_total, read off hack/eks-serve/holdcap-study/runs/*/cells/*/metrics-engine-*.prom).
//
// It counts in the stub's blocks of 16 "tokens", so its ratios are of the same kind as the engine's; its absolute
// counts are not the engine's, because the engine counts real tokens and the chat template.
type stubPrefixCache struct {
	mu       sync.Mutex
	capacity int
	order    *list.List
	at       map[uint64]*list.Element
	queries  int64
	hits     int64
}

func newStubPrefixCache(capacityTokens int) *stubPrefixCache {
	return &stubPrefixCache{capacity: max(capacityTokens/16, 1), order: list.New(), at: map[uint64]*list.Element{}}
}

// lookup counts the prompt's blocks as queried, its leading held blocks as hits, and then holds every block of it,
// as the engine does once it has computed them. It returns the tokens that were not cached, which the stub's
// prefill delay is charged for.
func (c *stubPrefixCache) lookup(prompt string) (uncachedTokens int) {
	n := len(prompt) / stubBlockChars
	chain := make([]uint64, n)
	h := fnv.New64a()
	var prev uint64
	var buf [8]byte
	for i := range n {
		h.Reset()
		binary.LittleEndian.PutUint64(buf[:], prev)
		_, _ = h.Write(buf[:])
		_, _ = h.Write([]byte(prompt[i*stubBlockChars : (i+1)*stubBlockChars]))
		prev = h.Sum64()
		chain[i] = prev
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	held := 0
	for _, b := range chain {
		if _, ok := c.at[b]; !ok {
			break
		}
		held++
	}
	c.queries += int64(n) * 16
	c.hits += int64(held) * 16
	for _, b := range chain {
		if e, ok := c.at[b]; ok {
			c.order.MoveToBack(e)
			continue
		}
		c.at[b] = c.order.PushBack(b)
		if c.order.Len() > c.capacity {
			old := c.order.Front()
			c.order.Remove(old)
			delete(c.at, old.Value.(uint64))
		}
	}
	return (n - held) * 16
}

// writeMetrics prints the counters and the cache's configuration in vLLM's names and label shape; a stub without a
// modelled cache prints nothing, as an engine started without caching exports no hits.
func (c *stubPrefixCache) writeMetrics(w io.Writer) {
	if c == nil {
		return
	}
	c.mu.Lock()
	q, h := c.queries, c.hits
	c.mu.Unlock()
	_, _ = fmt.Fprintf(w, "vllm:prefix_cache_queries_total{engine=\"0\",model_name=\"stub\"} %d\n", q)
	_, _ = fmt.Fprintf(w, "vllm:prefix_cache_hits_total{engine=\"0\",model_name=\"stub\"} %d\n", h)
	_, _ = fmt.Fprintf(w, "vllm:cache_config_info{block_size=\"16\",enable_prefix_caching=\"True\",engine=\"0\","+
		"kv_cache_size_tokens=\"%d\",num_gpu_blocks=\"%d\"} 1.0\n", c.capacity*16, c.capacity)
}

// stubPromptOf joins the request's message contents, the text the engine would cache.
func stubPromptOf(raw []byte) string {
	var body struct {
		Messages []struct {
			Content string `json:"content"`
		} `json:"messages"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return ""
	}
	var s strings.Builder
	for _, m := range body.Messages {
		s.WriteString(m.Content)
	}
	return s.String()
}

// stubPrefill is the stub's prefill: a delay per uncached token, taken one request at a time when the engine is
// modelled as serial, which is what makes a backend that receives more misses queue the requests behind them.
type stubPrefill struct {
	perToken time.Duration
	serial   sync.Mutex
	isSerial bool
}

// run looks the prompt up and waits out its prefill, one request at a time when the prefill is serial; false means the
// client went away during the wait.
//
// The lookup happens when the prefill starts rather than on arrival, as the engine's does: a request waiting behind a
// serial prefill finds whatever that prefill left in the cache. A stub without a modelled cache has no prefill to wait.
func (p *stubPrefill) run(cache *stubPrefixCache, raw []byte, wait func(time.Duration) bool) bool {
	if p == nil || cache == nil {
		return true
	}
	if p.isSerial {
		p.serial.Lock()
		defer p.serial.Unlock()
	}
	return wait(time.Duration(cache.lookup(stubPromptOf(raw))) * p.perToken)
}

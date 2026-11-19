package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/go-zeromq/zmq4"
	"github.com/vmihailenco/msgpack/v5"
)

// fakeEngine is a vLLM stand-in with vLLM v0.34's prefix-cache behaviour that the hypotheses depend on.
// It caches whole blocks of blockSize tokens, chains each block's hash to its parent's, puts the cache salt in block 0's extra keys only, never serves the last prompt token from cache, evicts the least recently used block when full, and publishes vLLM's event shapes.
// With reportFull honoured, a hit on a request carrying kv_cache_report_mode=full re-announces the reused blocks as BlockStored with no parent, as vLLM's emit_cached_block_events does.
type fakeEngine struct {
	mu          sync.Mutex
	blockSize   int
	capacity    int
	reportFull  bool
	topic       string
	pub         zmq4.Socket
	seq         uint64
	lru         []uint64 // least recently used first
	cached      map[uint64]bool
	removedSent int
}

func (e *fakeEngine) hashes(tokens []uint32, salt string) []uint64 {
	var out []uint64
	var parent uint64
	for i := 0; i+e.blockSize <= len(tokens); i += e.blockSize {
		h := fnv.New64a()
		var b [8]byte
		binary.LittleEndian.PutUint64(b[:], parent)
		h.Write(b[:])
		for _, t := range tokens[i : i+e.blockSize] {
			binary.LittleEndian.PutUint32(b[:4], t)
			h.Write(b[:4])
		}
		if i == 0 && salt != "" {
			h.Write([]byte(salt))
		}
		parent = h.Sum64()
		out = append(out, parent)
	}
	return out
}

func (e *fakeEngine) touch(h uint64) {
	for i, x := range e.lru {
		if x == h {
			e.lru = append(e.lru[:i], e.lru[i+1:]...)
			break
		}
	}
	e.lru = append(e.lru, h)
}

func (e *fakeEngine) publish(events ...any) error {
	payload, err := msgpack.Marshal([]any{float64(time.Now().UnixNano()) / 1e9, events})
	if err != nil {
		return err
	}
	var seq [8]byte
	binary.BigEndian.PutUint64(seq[:], e.seq)
	e.seq++
	return e.pub.Send(zmq4.NewMsgFrom([]byte(e.topic), seq[:], payload))
}

// stored is vLLM's array-encoded BlockStored with the fields v0.34 sends for a full-attention group.
func (e *fakeEngine) stored(hashes []uint64, parent *uint64, tokens []uint32, salt string, firstBlock bool) []any {
	var extra any
	if salt != "" && firstBlock {
		keys := make([]any, len(hashes))
		keys[0] = []any{salt}
		extra = keys
	}
	var p any
	if parent != nil {
		p = *parent
	}
	return []any{"BlockStored", hashes, p, tokens, e.blockSize, nil, "GPU", nil, extra, 0, "full_attention"}
}

// serve handles one token-array completion and returns the cached token count vLLM would report.
func (e *fakeEngine) serve(tokens []uint32, salt string, full bool) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	hs := e.hashes(tokens, salt)
	// vLLM recomputes at least the last prompt token, so a hit stops one token short of the prompt, floored to a block.
	maxHit := (len(tokens) - 1) / e.blockSize
	hit := 0
	for hit < len(hs) && hit < maxHit && e.cached[hs[hit]] {
		hit++
	}
	for _, h := range hs[:hit] {
		e.touch(h)
	}
	if full && hit > 0 && e.reportFull {
		if err := e.publish(e.stored(hs[:hit], nil, tokens[:hit*e.blockSize], salt, true)); err != nil {
			return 0, err
		}
	}
	// A block the engine already holds beyond the hit is the recomputed last block of a whole-prompt hit.
	// vLLM caches that recompute as a second physical block under the same hash and announces it again; this fake keeps one copy per hash and stays silent.
	// No measured row depends on that announcement: the repeat cases read the prediction before the recompute, and the dedup prefixes never end on a block boundary.
	start := hit
	var removed []uint64
	for _, h := range hs[start:] {
		if e.cached[h] {
			e.touch(h)
			continue
		}
		if len(e.lru) >= e.capacity {
			victim := e.lru[0]
			e.lru = e.lru[1:]
			delete(e.cached, victim)
			removed = append(removed, victim)
		}
		e.cached[h] = true
		e.touch(h)
	}
	var events []any
	for _, h := range removed {
		events = append(events, []any{"BlockRemoved", []uint64{h}, "GPU", 0})
		e.removedSent++
	}
	if start < len(hs) {
		var parent *uint64
		if start > 0 {
			parent = &hs[start-1]
		}
		events = append(events, e.stored(hs[start:], parent, tokens[start*e.blockSize:len(hs)*e.blockSize], salt, start == 0))
	}
	if len(events) > 0 {
		if err := e.publish(events...); err != nil {
			return 0, err
		}
	}
	return hit * e.blockSize, nil
}

func (e *fakeEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/completions" {
		http.NotFound(w, r)
		return
	}
	var req struct {
		Prompt    []uint32       `json:"prompt"`
		CacheSalt string         `json:"cache_salt"`
		XArgs     map[string]any `json:"vllm_xargs"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cached, err := e.serve(req.Prompt, req.CacheSalt, req.XArgs["kv_cache_report_mode"] == "full")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	fmt.Fprintf(w, "data: {\"choices\":[{\"text\":\"x\"}]}\n\n")
	fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d,\"prompt_tokens_details\":{\"cached_tokens\":%d}}}\n\n", len(req.Prompt), cached)
	fmt.Fprintf(w, "data: [DONE]\n\n")
}

// startFake serves one fake replica at addr on the given ports.
func startFake(ctx context.Context, addr string, httpPort, zmqPort, blockSize, capacity int, reportFull bool) (*fakeEngine, func(), error) {
	e := &fakeEngine{blockSize: blockSize, capacity: capacity, reportFull: reportFull, topic: "kv@qwen2vl", cached: map[uint64]bool{}}
	e.pub = zmq4.NewPub(ctx)
	if err := e.pub.Listen("tcp://" + net.JoinHostPort(addr, strconv.Itoa(zmqPort))); err != nil {
		return nil, nil, err
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(addr, strconv.Itoa(httpPort)))
	if err != nil {
		e.pub.Close()
		return nil, nil, err
	}
	srv := &http.Server{Handler: e}
	go srv.Serve(ln)
	return e, func() { srv.Close(); e.pub.Close() }, nil
}

// freePort returns a port free on both loopback addresses the test's two replicas use.
func freePort() (int, error) {
	for range 20 {
		l1, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return 0, err
		}
		port := l1.Addr().(*net.TCPAddr).Port
		l2, err := net.Listen("tcp", net.JoinHostPort("127.0.0.2", strconv.Itoa(port)))
		l1.Close()
		if err == nil {
			l2.Close()
			return port, nil
		}
	}
	return 0, fmt.Errorf("no port free on both 127.0.0.1 and 127.0.0.2")
}

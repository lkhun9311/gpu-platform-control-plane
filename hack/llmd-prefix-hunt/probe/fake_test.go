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
// It caches whole blocks of blockSize tokens, chains each block's hash to its parent's, puts the cache salt in block 0's extra keys only, never serves the last prompt token from cache, and evicts the least recently used physical block when full.
// Like vLLM, it computes every block past the hit into a new physical block, so a recomputed last block is a second copy of a hash, announced again and removed once per copy.
// With reportFull honoured, a hit on a request carrying kv_cache_report_mode=full re-announces the reused blocks as BlockStored with no parent, as vLLM's emit_cached_block_events does, without adding a copy.
// Events go out as vLLM's msgspec encodes them: the batch as an array and each event as a map tagged by "type".
type fakeEngine struct {
	mu         sync.Mutex
	blockSize  int
	capacity   int
	reportFull bool
	topic      string
	pub        zmq4.Socket
	seq        uint64
	// lru holds one hash per physical block, least recently used first.
	lru    []uint64
	copies map[uint64]int
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

// touch moves one physical copy of h to the most recently used end.
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

// stored is vLLM's BlockStored with the fields v0.34 sends for a full-attention group.
func (e *fakeEngine) stored(hashes []uint64, parent *uint64, tokens []uint32, salt string, firstBlock bool) map[string]any {
	ev := map[string]any{"type": "BlockStored", "block_hashes": hashes, "parent_block_hash": nil, "token_ids": tokens,
		"block_size": e.blockSize, "lora_id": nil, "medium": "GPU", "lora_name": nil, "group_idx": 0, "kv_cache_spec_kind": "full_attention"}
	if parent != nil {
		ev["parent_block_hash"] = *parent
	}
	if salt != "" && firstBlock {
		keys := make([]any, len(hashes))
		keys[0] = []any{salt}
		ev["extra_keys"] = keys
	}
	return ev
}

// serve handles one token-array completion and returns the cached token count vLLM would report.
func (e *fakeEngine) serve(tokens []uint32, salt string, full bool) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	hs := e.hashes(tokens, salt)
	// vLLM recomputes at least the last prompt token, so a hit stops one token short of the prompt, floored to a block.
	maxHit := (len(tokens) - 1) / e.blockSize
	hit := 0
	for hit < len(hs) && hit < maxHit && e.copies[hs[hit]] > 0 {
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
	var events []any
	for _, h := range hs[hit:] {
		if len(e.lru) >= e.capacity {
			victim := e.lru[0]
			e.lru = e.lru[1:]
			if e.copies[victim]--; e.copies[victim] == 0 {
				delete(e.copies, victim)
			}
			events = append(events, map[string]any{"type": "BlockRemoved", "block_hashes": []uint64{victim}, "medium": "GPU", "group_idx": 0})
		}
		e.copies[h]++
		e.lru = append(e.lru, h)
	}
	if hit < len(hs) {
		var parent *uint64
		if hit > 0 {
			parent = &hs[hit-1]
		}
		events = append(events, e.stored(hs[hit:], parent, tokens[hit*e.blockSize:len(hs)*e.blockSize], salt, hit == 0))
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
	e := &fakeEngine{blockSize: blockSize, capacity: capacity, reportFull: reportFull, topic: "kv@qwen2vl", copies: map[uint64]int{}}
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

/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package gateway

import (
	"container/list"
	"encoding/binary"
	"hash/fnv"
)

// prefixChain hashes a prompt into a chain of fixed-size chunks, as Gateway API Inference Extension proposal 0602
// describes: hash(chunk i) = hash(chunk i content + hash(chunk i-1)).
//
// The chain is seeded with the tenant and the model, so a chunk one tenant sent can never match another tenant's
// request: the index then cannot route one tenant by what another tenant's prompts were, and a routing decision
// cannot reveal that another tenant sent the same text.
// The engines' own caches are not tenant-scoped by this; only the gateway's index is.
//
// Only whole chunks are hashed, because a trailing partial chunk would be a different chunk the next time the same
// prefix arrives with a longer suffix, and could never match. At most maxChunks are hashed, which bounds the work
// a single request can cost the gateway.
func prefixChain(tenant, model, prompt string, chunkChars, maxChunks int) []uint64 {
	if chunkChars <= 0 {
		return nil
	}
	n := min(len(prompt)/chunkChars, maxChunks)
	chain := make([]uint64, 0, n)
	h := fnv.New64a()
	// A separator byte between the two seeds, so tenant "ab" with model "c" is not tenant "a" with model "bc".
	_, _ = h.Write([]byte(tenant))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(model))
	prev := h.Sum64()
	var buf [8]byte
	for i := range n {
		h.Reset()
		binary.LittleEndian.PutUint64(buf[:], prev)
		_, _ = h.Write(buf[:])
		_, _ = h.Write([]byte(prompt[i*chunkChars : (i+1)*chunkChars]))
		prev = h.Sum64()
		chain = append(chain, prev)
	}
	return chain
}

// backendLRU is one backend's approximate prefix cache: the chunk hashes recently sent to it, oldest evicted first.
type backendLRU struct {
	order *list.List
	// at maps a chunk hash to its element in order, whose Value is the hash.
	at map[uint64]*list.Element
	// lastUsed orders whole backends for eviction when more are seen than the index keeps.
	lastUsed uint64
}

// prefixIndex is the gateway's approximation of which prefixes each backend's engine still holds.
//
// It is an approximation by construction: it records what the gateway sent, at the moment it decided, not what the
// engine computed or kept. It mimics the engine's eviction with a per-backend LRU sized to the engine's capacity, as
// llm-d's approximate producer does, and it never learns of an engine restart. A wrong belief costs a cache miss on
// the engine, never a wrong answer.
//
// Memory is bounded twice: capacity chunks per backend, and at most maxBackends backends, the least recently used
// backend's whole entry being dropped when another appears. So at most capacity × maxBackends hashes are held,
// whatever the traffic or the number of InferenceDeployments.
//
// Not safe for concurrent use; the router holds its lock around every call.
type prefixIndex struct {
	capacity    int
	maxBackends int
	backends    map[string]*backendLRU
	clock       uint64
	// entries and evictions are kept for the metrics, which read them under the router's lock.
	entries   int
	evictions uint64
}

func newPrefixIndex(capacity, maxBackends int) *prefixIndex {
	return &prefixIndex{capacity: capacity, maxBackends: maxBackends, backends: map[string]*backendLRU{}}
}

// matched reports how many leading chunks of chain the index believes backend holds.
//
// Leading and consecutive, because an engine's prefix cache can only reuse a prefix: a chunk held after a missing one
// is no use to it. The chain makes chunk i's hash depend on every chunk before it, so a hit at i already means the
// whole prefix through i was sent there.
func (x *prefixIndex) matched(backend string, chain []uint64) int {
	b, ok := x.backends[backend]
	if !ok {
		return 0
	}
	n := 0
	for _, h := range chain {
		if _, ok := b.at[h]; !ok {
			break
		}
		n++
	}
	return n
}

// record marks every chunk of chain as most recently sent to backend, evicting the oldest beyond capacity.
func (x *prefixIndex) record(backend string, chain []uint64) {
	if x.capacity <= 0 || len(chain) == 0 {
		return
	}
	x.clock++
	b, ok := x.backends[backend]
	if !ok {
		if len(x.backends) >= x.maxBackends {
			x.dropOldestBackend()
		}
		b = &backendLRU{order: list.New(), at: map[uint64]*list.Element{}}
		x.backends[backend] = b
	}
	b.lastUsed = x.clock
	// A prompt longer than the capacity keeps its last capacity chunks, which is what an LRU holding it would keep;
	// its leading chunks are then gone and it can never match, as on the engine.
	for _, h := range chain {
		if e, ok := b.at[h]; ok {
			b.order.MoveToBack(e)
			continue
		}
		b.at[h] = b.order.PushBack(h)
		x.entries++
		if b.order.Len() > x.capacity {
			oldest := b.order.Front()
			b.order.Remove(oldest)
			delete(b.at, oldest.Value.(uint64))
			x.entries--
			x.evictions++
		}
	}
}

// dropOldestBackend forgets the backend least recently routed to, which bounds the index by the backend count.
func (x *prefixIndex) dropOldestBackend() {
	var oldest string
	var at uint64
	first := true
	for name, b := range x.backends {
		if first || b.lastUsed < at {
			oldest, at, first = name, b.lastUsed, false
		}
	}
	if first {
		return
	}
	x.entries -= x.backends[oldest].order.Len()
	x.evictions += uint64(x.backends[oldest].order.Len())
	delete(x.backends, oldest)
}

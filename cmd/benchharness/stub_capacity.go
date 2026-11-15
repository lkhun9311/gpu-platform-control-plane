package main

import (
	"context"
	"sync"
)

// stubCapacity is the stub's capacity model: at most a fixed number of requests run, and the rest wait their turn.
//
// A stub that served every request in parallel had no rate it could not sustain, so the version study's calibration
// ladder against it could never find an upper bracket, and its drain check met gauges that never showed a queue.
// With a fixed service time S and n running places, the stub sustains n/S requests a second and queues beyond it.
type stubCapacity struct {
	slots chan struct{}
	// mu guards both counts together: a request moves from waiting to running in one step, and a scrape reads both in
	// one step, so no scrape can catch a request between the two and report an engine that looks drained.
	mu      sync.Mutex
	running int64
	waiting int64
}

func newStubCapacity(running int) *stubCapacity {
	return &stubCapacity{slots: make(chan struct{}, running)}
}

// acquire waits for a running place, or gives up when the client goes away; a request that gave up never counts as running.
func (c *stubCapacity) acquire(ctx context.Context) bool {
	c.mu.Lock()
	c.waiting++
	c.mu.Unlock()
	select {
	case c.slots <- struct{}{}:
		c.mu.Lock()
		c.waiting--
		c.running++
		c.mu.Unlock()
		return true
	case <-ctx.Done():
		c.mu.Lock()
		c.waiting--
		c.mu.Unlock()
		return false
	}
}

// release ends a running request; its count drops before its place is freed, so the running gauge never exceeds the capacity.
func (c *stubCapacity) release() {
	c.mu.Lock()
	c.running--
	c.mu.Unlock()
	<-c.slots
}

// admit takes a running place for one request, and returns how to give it back; a stub without a capacity admits at once.
func (c *stubCapacity) admit(ctx context.Context) (func(), bool) {
	if c == nil {
		return func() {}, true
	}
	if !c.acquire(ctx) {
		return nil, false
	}
	return c.release, true
}

// gauges are vLLM's running and waiting counts: without a capacity every request in flight runs and none waits.
func (c *stubCapacity) gauges(inFlight int64) (running, waiting int64) {
	if c == nil {
		return inFlight, 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running, c.waiting
}

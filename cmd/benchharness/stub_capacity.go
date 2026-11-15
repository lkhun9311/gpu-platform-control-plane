package main

import (
	"context"
	"sync/atomic"
)

// stubCapacity is the stub's capacity model: at most a fixed number of requests run, and the rest wait their turn.
//
// A stub that served every request in parallel had no rate it could not sustain, so the version study's calibration
// ladder against it could never find an upper bracket, and its drain check met gauges that never showed a queue.
// With a fixed service time S and n running places, the stub sustains n/S requests a second and queues beyond it.
type stubCapacity struct {
	slots   chan struct{}
	running atomic.Int64
	waiting atomic.Int64
}

func newStubCapacity(running int) *stubCapacity {
	return &stubCapacity{slots: make(chan struct{}, running)}
}

// acquire waits for a running place, or gives up when the client goes away; a request that gave up never counts as running.
func (c *stubCapacity) acquire(ctx context.Context) bool {
	c.waiting.Add(1)
	defer c.waiting.Add(-1)
	select {
	case c.slots <- struct{}{}:
		c.running.Add(1)
		return true
	case <-ctx.Done():
		return false
	}
}

func (c *stubCapacity) release() {
	c.running.Add(-1)
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
	return c.running.Load(), c.waiting.Load()
}

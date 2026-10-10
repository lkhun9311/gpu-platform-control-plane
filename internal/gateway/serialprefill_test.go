package gateway

import (
	"context"
	"net/url"
	"testing"
	"time"
)

func serialBackend() *BackendRef {
	return &BackendRef{URL: &url.URL{Scheme: "http", Host: "engine-a:8000"}}
}

// reserveAsync runs Reserve on its own goroutine and reports its outcome on the returned channel.
func reserveAsync(s *serialPrefillAdmitter, ctx context.Context, tier string) chan struct {
	res    *reservation
	ok     bool
	reason string
} {
	out := make(chan struct {
		res    *reservation
		ok     bool
		reason string
	}, 1)
	go func() {
		res, ok, reason := s.Reserve(ctx, RequestMeta{}, serialBackend(), "", tier)
		out <- struct {
			res    *reservation
			ok     bool
			reason string
		}{res, ok, reason}
	}()
	return out
}

// waitWaiters waits until n requests are queued, so an assertion about who is held is not a race with Reserve.
func waitWaiters(t *testing.T, s *serialPrefillAdmitter, n int) {
	t.Helper()
	for range 200 {
		if _, w := s.state(serialBackend()); w == n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("never saw %d waiters", n)
}

// A premium request is never held, even with a standard request in prefill and others waiting.
func TestSerialPrefillAdmitsPremiumAtOnce(t *testing.T) {
	s := newSerialPrefillAdmitter(time.Second)
	if _, ok, reason := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok || reason != reasonSerialPrefillFree {
		t.Fatalf("the first standard request: %v %s", ok, reason)
	}
	if res, ok, reason := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierPremium); !ok || res != nil || reason != reasonPremiumUnreserved {
		t.Fatalf("premium was not admitted unreserved: %v %v %s", res, ok, reason)
	}
}

// A second standard request is held until the first one's prefill ends, then admitted, in arrival order.
// Mutation that turns it red: admit a standard request without checking busy, or hand the turn to the newest waiter.
func TestSerialPrefillHoldsUntilThePrefillEndsInOrder(t *testing.T) {
	s := newSerialPrefillAdmitter(5 * time.Second)
	first, ok, _ := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard)
	if !ok {
		t.Fatal("the first standard request was refused")
	}
	second := reserveAsync(s, context.Background(), tierStandard)
	waitWaiters(t, s, 1)
	third := reserveAsync(s, context.Background(), tierStandard)
	waitWaiters(t, s, 2)
	select {
	case <-second:
		t.Fatal("the second standard request was admitted while the first was in prefill")
	case <-time.After(50 * time.Millisecond):
	}
	first.PrefillDone()
	got := <-second
	if !got.ok || got.reason != reasonSerialPrefillWaited {
		t.Fatalf("the second request after the first's prefill: %v %s", got.ok, got.reason)
	}
	select {
	case <-third:
		t.Fatal("the third request was admitted while the second was in prefill")
	case <-time.After(50 * time.Millisecond):
	}
	got.res.Done()
	if r := <-third; !r.ok {
		t.Fatalf("the third request was not admitted after the second's: %s", r.reason)
	}
}

// A request held past maxHold is refused, and its giving up does not keep the backend busy.
func TestSerialPrefillRefusesAfterTheLongestHoldWithoutLeaking(t *testing.T) {
	s := newSerialPrefillAdmitter(30 * time.Millisecond)
	first, _, _ := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard)
	if r := <-reserveAsync(s, context.Background(), tierStandard); r.ok || r.reason != reasonSerialPrefillHoldTimeout {
		t.Fatalf("a request held past maxHold: %v %s", r.ok, r.reason)
	}
	first.PrefillDone()
	if busy, w := s.state(serialBackend()); busy || w != 0 {
		t.Fatalf("after the release the backend is busy=%v with %d waiting", busy, w)
	}
}

// A request whose client goes away while held is refused and taken out of line.
func TestSerialPrefillLetsAGoneClientLeave(t *testing.T) {
	s := newSerialPrefillAdmitter(5 * time.Second)
	first, _, _ := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard)
	ctx, cancel := context.WithCancel(context.Background())
	held := reserveAsync(s, ctx, tierStandard)
	waitWaiters(t, s, 1)
	cancel()
	if r := <-held; r.ok || r.reason != reasonSerialPrefillClientGone {
		t.Fatalf("a held request whose client left: %v %s", r.ok, r.reason)
	}
	if _, w := s.state(serialBackend()); w != 0 {
		t.Fatalf("%d still waiting after the client left", w)
	}
	first.Done()
	if busy, _ := s.state(serialBackend()); busy {
		t.Fatal("the backend stayed busy after the only request ended")
	}
}

// A request that ends before its first body byte, an error or a cancellation, still releases its prefill.
func TestSerialPrefillReleasesOnDoneWithoutAFirstByte(t *testing.T) {
	s := newSerialPrefillAdmitter(time.Second)
	first, _, _ := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard)
	first.Done()
	first.PrefillDone()
	if busy, _ := s.state(serialBackend()); busy {
		t.Fatal("Done did not release the prefill")
	}
	if _, ok, reason := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok || reason != reasonSerialPrefillFree {
		t.Fatalf("the backend was not free after Done: %s", reason)
	}
}

// A waiter already past its hold is skipped when the turn passes, so a turn and the hold's timer ready together cannot
// admit it at random; the turn goes to the next waiter (v26 review, A14).
// Mutation that turns it red: hand the turn to the head of the line without checking its hold.
func TestSerialPrefillSkipsAWaiterPastItsHold(t *testing.T) {
	s := newSerialPrefillAdmitter(time.Second)
	key := serialBackend().URL.String()
	late, fresh := make(chan struct{}), make(chan struct{})
	s.busy[key] = true
	s.waiters[key] = []waiter{{late, time.Now().Add(-2 * time.Second)}, {fresh, time.Now()}}
	s.next(key)
	select {
	case <-late:
		t.Fatal("the turn went to a waiter past its hold")
	default:
	}
	select {
	case <-fresh:
	default:
		t.Fatal("the turn did not pass to the next waiter")
	}
}

// A waiter skipped for being past its hold was never handed the turn, so its own timeout must not pass the turn on:
// that admitted a third request while the fresh holder was still in prefill (review of 0057699).
// Mutation that turns it red: pass the turn on from leave whenever the waiter is no longer in the queue.
func TestSerialPrefillASkippedWaiterDoesNotPassTheTurnOn(t *testing.T) {
	s := newSerialPrefillAdmitter(time.Second)
	key := serialBackend().URL.String()
	late, fresh, third := make(chan struct{}), make(chan struct{}), make(chan struct{})
	s.busy[key] = true
	s.waiters[key] = []waiter{{late, time.Now().Add(-2 * time.Second)}, {fresh, time.Now()}, {third, time.Now()}}
	s.next(key) // skips late, hands the turn to fresh
	s.leave(key, late)
	select {
	case <-third:
		t.Fatal("the skipped waiter's timeout passed the turn to a third request while fresh held it")
	default:
	}
	if busy, waiting := s.state(serialBackend()); !busy || waiting != 1 {
		t.Fatalf("after the skipped waiter left: busy %v, %d waiting; want busy with the third still waiting", busy, waiting)
	}
}

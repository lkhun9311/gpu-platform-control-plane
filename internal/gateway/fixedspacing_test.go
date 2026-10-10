package gateway

import (
	"context"
	"testing"
	"time"
)

type fixedOutcome struct {
	at     time.Time
	ok     bool
	reason string
}

// fixedAsync runs Reserve for a standard request on its own goroutine and reports when it returned and how.
func fixedAsync(f *fixedSpacingAdmitter, ctx context.Context) chan fixedOutcome {
	out := make(chan fixedOutcome, 1)
	go func() {
		_, ok, reason := f.Reserve(ctx, RequestMeta{}, serialBackend(), "", tierStandard)
		out <- fixedOutcome{time.Now(), ok, reason}
	}()
	return out
}

// waitFixedWaiters waits until n standard requests are queued, so the order they queued in is the order sent.
func waitFixedWaiters(t *testing.T, f *fixedSpacingAdmitter, n int) {
	t.Helper()
	for range 200 {
		if f.waiting(serialBackend()) == n {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("never saw %d waiters", n)
}

// A premium request is never held, and takes no slot from the standard requests behind it.
func TestFixedSpacingAdmitsPremiumAtOnce(t *testing.T) {
	f := newFixedSpacingAdmitter(time.Hour, time.Second)
	if _, ok, reason := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok || reason != reasonFixedSpacingFree {
		t.Fatalf("the first standard request: %v %s", ok, reason)
	}
	if res, ok, reason := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierPremium); !ok || res != nil || reason != reasonPremiumUnreserved {
		t.Fatalf("premium was not admitted at once: %v %v %s", res, ok, reason)
	}
}

// Three standard requests arriving together go one spacing apart, in arrival order, with nothing from the engine.
// Mutation that turns it red: count the spacing from the request's arrival instead of the previous admission, or
// admit the newest waiter first.
func TestFixedSpacingAdmitsOneSpacingApartInOrder(t *testing.T) {
	const spacing = 80 * time.Millisecond
	f := newFixedSpacingAdmitter(spacing, 5*time.Second)
	start := time.Now()
	if _, ok, reason := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok || reason != reasonFixedSpacingFree {
		t.Fatalf("the first standard request: %v %s", ok, reason)
	}
	second := fixedAsync(f, context.Background())
	waitFixedWaiters(t, f, 1)
	third := fixedAsync(f, context.Background())
	waitFixedWaiters(t, f, 2)
	s, th := <-second, <-third
	if !s.ok || s.reason != reasonFixedSpacingWaited || !th.ok || th.reason != reasonFixedSpacingWaited {
		t.Fatalf("held requests: %+v %+v", s, th)
	}
	if d := s.at.Sub(start); d < spacing || d > spacing+40*time.Millisecond {
		t.Fatalf("the second went %s after the first, not one spacing", d)
	}
	if d := th.at.Sub(s.at); d < spacing-5*time.Millisecond || d > spacing+40*time.Millisecond {
		t.Fatalf("the third went %s after the second, not one spacing", d)
	}
}

// A standard request arriving after a quiet spell longer than the spacing is admitted at once.
func TestFixedSpacingAdmitsAtOnceAfterTheSpacing(t *testing.T) {
	f := newFixedSpacingAdmitter(20*time.Millisecond, time.Second)
	if _, ok, _ := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok {
		t.Fatal("the first standard request was refused")
	}
	time.Sleep(30 * time.Millisecond)
	if _, ok, reason := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok || reason != reasonFixedSpacingFree {
		t.Fatalf("after the spacing had passed: %v %s", ok, reason)
	}
}

// A request whose turn would come after the longest hold is refused at the hold, and the slot it never used does not
// push back the request behind it: only an admission moves the clock (v26: the replay counts forwards only).
// Mutation that turns it red: book each waiter's slot when it queues, or let a refusal count as an admission.
func TestFixedSpacingRefusesAtTheHoldAndKeepsTheSlot(t *testing.T) {
	const spacing = 200 * time.Millisecond
	f := newFixedSpacingAdmitter(spacing, 60*time.Millisecond)
	start := time.Now()
	if _, ok, _ := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok {
		t.Fatal("the first standard request was refused")
	}
	second := fixedAsync(f, context.Background())
	got := <-second
	if got.ok || got.reason != reasonFixedSpacingHoldTimeout {
		t.Fatalf("a request held past the longest hold: %+v", got)
	}
	// Queued once the second is gone, at about 60 ms: its turn is the first admission's plus one spacing, 200 ms.
	f.maxHold = time.Second
	third := fixedAsync(f, context.Background())
	th := <-third
	if !th.ok {
		t.Fatalf("the third request: %+v", th)
	}
	if d := th.at.Sub(start); d < spacing || d > spacing+40*time.Millisecond {
		t.Fatalf("the third went %s after the first; the refused second must not have taken a slot", d)
	}
}

// A request whose client goes away while held is refused as gone, and leaves the line.
func TestFixedSpacingClientGone(t *testing.T) {
	f := newFixedSpacingAdmitter(time.Hour, time.Hour)
	if _, ok, _ := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard); !ok {
		t.Fatal("the first standard request was refused")
	}
	ctx, cancel := context.WithCancel(context.Background())
	held := fixedAsync(f, ctx)
	waitFixedWaiters(t, f, 1)
	cancel()
	got := <-held
	if got.ok || got.reason != reasonFixedSpacingClientGone {
		t.Fatalf("a held request whose client left: %+v", got)
	}
	if n := f.waiting(serialBackend()); n != 0 {
		t.Fatalf("%d still waiting after the client left", n)
	}
}

// A head of the line already past its hold is dropped at release, takes no slot, and the next waiter goes in its place
// (v26 review, A14). Mutation that turns it red: admit the head without checking its hold.
func TestFixedSpacingDropsAHeadPastItsHold(t *testing.T) {
	f := newFixedSpacingAdmitter(10*time.Millisecond, time.Second)
	key := serialBackend().URL.String()
	late, fresh := make(chan struct{}), make(chan struct{})
	before := time.Now().Add(-time.Minute)
	f.lines[key] = &fixedSpacingLine{last: before, waiters: []waiter{{late, time.Now().Add(-2 * time.Second)}, {fresh, time.Now()}}, armed: true}
	f.release(key)
	select {
	case <-late:
		t.Fatal("a waiter past its hold was admitted")
	default:
	}
	select {
	case <-fresh:
	default:
		t.Fatal("the next waiter was not admitted in its place")
	}
}

// An admitted standard request is pinned to the backend its spacing was charged to: its reservation is not nil, so
// the server does not keep the fallback backends (review of b80093c).
// Mutation that turns it red: return a nil reservation on admission.
func TestFixedSpacingPinsTheChargedBackend(t *testing.T) {
	f := newFixedSpacingAdmitter(time.Millisecond, time.Second)
	res, ok, _ := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "", tierStandard)
	if !ok || res == nil {
		t.Fatalf("an admitted standard request: ok %v, reservation %v", ok, res)
	}
	b2 := &BackendRef{URL: serialBackend().URL}
	if got := forwardTargets(res, []*BackendRef{serialBackend(), b2}); len(got) != 1 {
		t.Fatalf("the request may still go to %d backends", len(got))
	}
}

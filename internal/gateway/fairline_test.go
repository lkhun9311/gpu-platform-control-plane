package gateway

import (
	"context"
	"testing"
	"time"
)

// waiterOf is a fresh waiter for tenant with a second's hold.
func waiterOf(tenant string) waiter {
	return waiter{turn: make(chan struct{}), since: time.Now(), maxHold: time.Second, tenant: tenant}
}

// popOrder pops l empty and returns the tenant of each waiter in the order it was served.
func popOrder(l *fairLine) []string {
	var got []string
	for {
		w, ok := l.pop(time.Now())
		if !ok {
			return got
		}
		got = append(got, w.tenant)
	}
}

// A tenant that queued first and queued many is served one at a time between the others, not all ahead of them.
// Mutation that turns it red: serve the tenant at the front of the order until its queue is empty.
func TestFairLineAlternatesBetweenTenants(t *testing.T) {
	l := newFairLine(waiterOf("a"), waiterOf("a"), waiterOf("a"), waiterOf("b"), waiterOf("c"), waiterOf("b"))
	got := popOrder(l)
	want := []string{"a", "b", "c", "a", "b", "a"}
	if len(got) != len(want) {
		t.Fatalf("served %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("served %v, want %v", got, want)
		}
	}
}

// With one tenant the line is the arrival order it always was, which is what the registered serial-prefill and
// fixed-spacing runs measured, since each had a single standard tenant.
func TestFairLineIsFIFOForOneTenant(t *testing.T) {
	ws := []waiter{waiterOf("a"), waiterOf("a"), waiterOf("a")}
	l := newFairLine(ws...)
	for i, w := range ws {
		got, ok := l.pop(time.Now())
		if !ok || got.turn != w.turn {
			t.Fatalf("pop %d was not the waiter that arrived %d", i, i)
		}
	}
}

// A waiter past its hold is dropped without costing its tenant the turn, so the tenant's next waiter is served next.
// Mutation that turns it red: rotate the tenant to the back when its expired waiter is dropped.
func TestFairLineDropsAnExpiredWaiterWithoutPassingTheTurn(t *testing.T) {
	late := waiterOf("a")
	late.since = time.Now().Add(-2 * time.Second)
	l := newFairLine(late, waiterOf("a"), waiterOf("b"))
	if got := popOrder(l); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("served %v, want [a b]", got)
	}
}

// remove takes out exactly the waiter named, and only reports true for one that was in line.
func TestFairLineRemove(t *testing.T) {
	a1, a2, b1 := waiterOf("a"), waiterOf("a"), waiterOf("b")
	l := newFairLine(a1, a2, b1)
	if !l.remove("a", a1.turn) {
		t.Fatal("a waiter in line was not removed")
	}
	if l.remove("a", a1.turn) {
		t.Fatal("a waiter already removed was reported removed again")
	}
	if l.len() != 2 || l.countOf("a") != 1 {
		t.Fatalf("after removing one of a's: %d in line, %d of a's; want 2 and 1", l.len(), l.countOf("a"))
	}
	if got := popOrder(l); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("served %v, want [a b]", got)
	}
}

// A tenant that floods a backend's line holds one turn in each round, so a second tenant waits behind one of its
// requests rather than all of them (codex review, 2026-10-30, finding 5).
// Mutation that turns it red: ignore the tenant in reserve.
func TestSerialPrefillServesASecondTenantBeforeAFloodingOnesBacklog(t *testing.T) {
	s := newSerialPrefillAdmitter(5 * time.Second)
	first, ok, _ := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), "flood", tierStandard)
	if !ok {
		t.Fatal("the first request was not admitted on a free backend")
	}
	admitted := make(chan string, 4)
	held := func(tenant string) {
		go func() {
			res, ok, _ := s.Reserve(context.Background(), RequestMeta{}, serialBackend(), tenant, tierStandard)
			if ok {
				admitted <- tenant
				res.Done()
			}
		}()
	}
	for i := range 3 {
		held("flood")
		waitWaiters(t, s, i+1)
	}
	held("quiet")
	waitWaiters(t, s, 4)

	first.Done()
	// Each admitted request's Done passes the turn on at once, so the order is the order of turns.
	var order []string
	for range 4 {
		select {
		case who := <-admitted:
			order = append(order, who)
		case <-time.After(2 * time.Second):
			t.Fatalf("only %v were admitted", order)
		}
	}
	if order[0] != "flood" || order[1] != "quiet" {
		t.Fatalf("admitted %v; want the quiet tenant second, after one of the flood's", order)
	}
}

// Fixed spacing shares the line, so the same flood must not take every slot ahead of a quiet tenant.
// Mutation that turns it red: ignore the tenant in fixed spacing's Reserve.
func TestFixedSpacingServesASecondTenantBeforeAFloodingOnesBacklog(t *testing.T) {
	f := newFixedSpacingAdmitter(20*time.Millisecond, 5*time.Second)
	if _, ok, _ := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), "flood", tierStandard); !ok {
		t.Fatal("the first request was not admitted on a quiet backend")
	}
	admitted := make(chan string, 4)
	held := func(tenant string) {
		go func() {
			if _, ok, _ := f.Reserve(context.Background(), RequestMeta{}, serialBackend(), tenant, tierStandard); ok {
				admitted <- tenant
			}
		}()
	}
	for i := range 3 {
		held("flood")
		waitFixedWaiters(t, f, i+1)
	}
	held("quiet")
	waitFixedWaiters(t, f, 4)
	var order []string
	for range 4 {
		select {
		case who := <-admitted:
			order = append(order, who)
		case <-time.After(2 * time.Second):
			t.Fatalf("only %v were admitted", order)
		}
	}
	if order[0] != "flood" || order[1] != "quiet" {
		t.Fatalf("admitted %v; want the quiet tenant second, after one of the flood's", order)
	}
}

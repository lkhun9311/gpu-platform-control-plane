package gateway

import "time"

// fairLine is the requests held for one backend: in arrival order within a tenant, and one turn per tenant in rotation.
//
// One line in arrival order let a tenant that queued many requests hold every turn ahead of a tenant that queued one,
// so the second tenant's hold ran out behind work that was not its own (codex review, 2026-10-30, finding 5).
// With a single standard tenant, as every registered serial-prefill and fixed-spacing run had, the rotation has one
// member and the line is the arrival order it was.
//
// It is not safe for concurrent use; its admitter's lock guards it.
type fairLine struct {
	queues map[string][]waiter
	// order is the tenants with someone waiting, the one whose turn is next first.
	order []string
	n     int
}

// newFairLine returns a line holding ws in the order given.
func newFairLine(ws ...waiter) *fairLine {
	l := &fairLine{queues: map[string][]waiter{}}
	for _, w := range ws {
		l.push(w)
	}
	return l
}

// len is how many wait, past their hold or not.
func (l *fairLine) len() int { return l.n }

// countOf is how many of tenant's requests wait.
func (l *fairLine) countOf(tenant string) int { return len(l.queues[tenant]) }

// push puts w at the back of its tenant's queue, and a tenant that had no one waiting at the back of the rotation.
func (l *fairLine) push(w waiter) {
	if len(l.queues[w.tenant]) == 0 {
		l.order = append(l.order, w.tenant)
	}
	l.queues[w.tenant] = append(l.queues[w.tenant], w)
	l.n++
}

// dropExpired removes waiters past their hold from the front of the line, stopping at the first that is not.
// A dropped waiter does not pass its tenant's turn on: its own timer refuses it, and the tenant's next request takes
// the turn it never used.
func (l *fairLine) dropExpired(now time.Time) {
	for len(l.order) > 0 {
		t := l.order[0]
		q := l.queues[t]
		if now.Sub(q[0].since) <= q[0].maxHold {
			return
		}
		l.shift(t)
		if len(l.queues[t]) == 0 {
			l.order = l.order[1:]
		}
	}
}

// pop removes and returns the next waiter still within its hold at now, and moves its tenant to the back of the
// rotation; false when there is none.
func (l *fairLine) pop(now time.Time) (waiter, bool) {
	l.dropExpired(now)
	if len(l.order) == 0 {
		return waiter{}, false
	}
	t := l.order[0]
	w := l.shift(t)
	l.order = l.order[1:]
	if len(l.queues[t]) > 0 {
		l.order = append(l.order, t)
	}
	return w, true
}

// shift removes and returns the front of tenant's queue, deleting the queue once empty; the caller fixes order.
func (l *fairLine) shift(tenant string) waiter {
	q := l.queues[tenant]
	w := q[0]
	if len(q) == 1 {
		delete(l.queues, tenant)
	} else {
		l.queues[tenant] = q[1:]
	}
	l.n--
	return w
}

// remove takes the waiter holding turn out of tenant's queue, and reports whether it was there.
func (l *fairLine) remove(tenant string, turn chan struct{}) bool {
	q := l.queues[tenant]
	for i, w := range q {
		if w.turn != turn {
			continue
		}
		if len(q) == 1 {
			delete(l.queues, tenant)
			for j, t := range l.order {
				if t == tenant {
					l.order = append(l.order[:j:j], l.order[j+1:]...)
					break
				}
			}
		} else {
			l.queues[tenant] = append(q[:i:i], q[i+1:]...)
		}
		l.n--
		return true
	}
	return false
}

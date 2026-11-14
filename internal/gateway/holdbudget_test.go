package gateway

import "testing"

// small is limits tight enough to reach in a test: three held requests or 300 bytes in all, two or 200 for one tenant.
var small = HoldLimits{Requests: 3, Bytes: 300, TenantRequests: 2, TenantBytes: 200}

// A tenant reaching its own share is refused for its share, and another tenant is still admitted beside it.
// Mutation that turns it red: check only the totals.
func TestHoldBudgetRefusesATenantPastItsShareAndNotTheOthers(t *testing.T) {
	b := newHoldBudget(small)
	for range 2 {
		if ok, _ := b.take("a", 10); !ok {
			t.Fatal("a tenant within its share was refused")
		}
	}
	if ok, reason := b.take("a", 10); ok || reason != ReasonHoldTenantFull {
		t.Fatalf("a tenant's third held request: got ok=%v reason=%q, want refused for %q", ok, reason, ReasonHoldTenantFull)
	}
	if ok, reason := b.take("b", 10); !ok {
		t.Fatalf("another tenant was refused with %q while the gateway still had room", reason)
	}
}

// The gateway's total is a limit of its own: tenants each within their share are refused once together they reach it.
// Mutation that turns it red: check only the tenant's share.
func TestHoldBudgetRefusesAtTheTotalWhenEveryTenantIsWithinItsShare(t *testing.T) {
	b := newHoldBudget(small)
	for _, tenant := range []string{"a", "b", "c"} {
		if ok, _ := b.take(tenant, 10); !ok {
			t.Fatalf("tenant %s was refused below the total", tenant)
		}
	}
	if ok, reason := b.take("d", 10); ok || reason != ReasonHoldFull {
		t.Fatalf("the fourth held request: got ok=%v reason=%q, want refused for %q", ok, reason, ReasonHoldFull)
	}
}

// Bytes are limited as well as requests: one large body can take a tenant's share, and large bodies from several tenants the total.
// Mutation that turns it red: compare requests only.
func TestHoldBudgetLimitsBytesAsWellAsRequests(t *testing.T) {
	b := newHoldBudget(small)
	if ok, reason := b.take("a", 201); ok || reason != ReasonHoldTenantFull {
		t.Fatalf("a body over the tenant's bytes: got ok=%v reason=%q, want %q", ok, reason, ReasonHoldTenantFull)
	}
	b.take("a", 200)
	if ok, reason := b.take("b", 101); ok || reason != ReasonHoldFull {
		t.Fatalf("bytes past the total: got ok=%v reason=%q, want %q", ok, reason, ReasonHoldFull)
	}
}

// A refused take charges nothing, and give returns exactly what take charged, so the budget is empty again after every request has left.
// Mutation that turns it red: charge before checking, or give back nothing.
func TestHoldBudgetReturnsToZero(t *testing.T) {
	b := newHoldBudget(small)
	b.take("a", 100)
	b.take("a", 100)
	b.take("a", 1) // refused for the share
	b.take("b", 50)
	total, a := b.usage("a")
	if total != (holdUsage{requests: 3, bytes: 250}) || a != (holdUsage{requests: 2, bytes: 200}) {
		t.Fatalf("after two of a's and one of b's: total %+v, a %+v", total, a)
	}
	b.give("a", 100)
	b.give("a", 100)
	b.give("b", 50)
	total, a = b.usage("a")
	if total != (holdUsage{}) || a != (holdUsage{}) || len(b.tenants) != 0 {
		t.Fatalf("after every request left: total %+v, a %+v, tenants still tracked %d", total, a, len(b.tenants))
	}
}

// A nil budget charges nothing and refuses nothing, so an admitter constructed without one behaves as before.
func TestNilHoldBudgetAdmitsEverything(t *testing.T) {
	var b *holdBudget
	if ok, reason := b.take("a", 1<<40); !ok || reason != "" {
		t.Fatalf("nil budget: got ok=%v reason=%q", ok, reason)
	}
	b.give("a", 1<<40)
}

// Every limit must be above zero and a tenant's at most its total; the defaults pass.
// Mutation that turns it red: drop either check.
func TestHoldLimitsValidate(t *testing.T) {
	if err := DefaultHoldLimits.Validate(); err != nil {
		t.Fatalf("the defaults: %v", err)
	}
	for name, l := range map[string]HoldLimits{
		"zero requests":          {Requests: 0, Bytes: 1, TenantRequests: 1, TenantBytes: 1},
		"zero tenant bytes":      {Requests: 1, Bytes: 1, TenantRequests: 1, TenantBytes: 0},
		"tenant requests > all":  {Requests: 1, Bytes: 9, TenantRequests: 2, TenantBytes: 1},
		"tenant bytes > all":     {Requests: 9, Bytes: 1, TenantRequests: 1, TenantBytes: 2},
		"negative total bytes":   {Requests: 1, Bytes: -1, TenantRequests: 1, TenantBytes: 1},
		"negative tenant counts": {Requests: 1, Bytes: 1, TenantRequests: -1, TenantBytes: 1},
	} {
		if err := l.Validate(); err == nil {
			t.Errorf("%s: accepted %+v", name, l)
		}
	}
}

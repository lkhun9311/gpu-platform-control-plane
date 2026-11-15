package bench

import (
	"math"
	"slices"
	"strings"
	"testing"
)

// TestVersionTraceIsDeterministicAndPrefixStable: ChooseWindow and the bundle check both rely on a shorter window's trace being a prefix of a longer one's.
func TestVersionTraceIsDeterministicAndPrefixStable(t *testing.T) {
	d := versionAsyncDesign()
	seed, _ := WorkloadSeed(d.CampaignSeed, 2, LoadL090)
	short, err := d.VersionTrace(seed, 3.6, 300)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := d.VersionTrace(seed, 3.6, 300)
	if !slices.Equal(short, again) {
		t.Fatal("the same seed gave two different traces")
	}
	long, err := d.VersionTrace(seed, 3.6, 600)
	if err != nil {
		t.Fatal(err)
	}
	if len(long) <= len(short) || !slices.Equal(long[:len(short)], short) {
		t.Fatalf("the 300 s trace (%d rows) is not a prefix of the 600 s one (%d rows)", len(short), len(long))
	}
	other, _ := WorkloadSeed(d.CampaignSeed, 3, LoadL090)
	diff, _ := d.VersionTrace(other, 3.6, 300)
	if slices.Equal(diff[:20], short[:20]) {
		t.Fatal("two blocks' seeds gave the same opening rows")
	}
}

// TestVersionTraceFollowsTheRegisteredWorkload: Poisson arrivals at the offered rate and the registered length mixture, read off a long seeded stream.
func TestVersionTraceFollowsTheRegisteredWorkload(t *testing.T) {
	d := versionAsyncDesign()
	const rate = 4.0
	rows, err := d.VersionTrace(12345, rate, d.MaxMeasureSeconds)
	if err != nil {
		t.Fatal(err)
	}
	span := float64(d.WarmupSeconds + d.MaxMeasureSeconds)
	if got := float64(len(rows)) / span; math.Abs(got-rate)/rate > 0.05 {
		t.Fatalf("arrival rate %.3f/s, want %.1f/s within 5%%", got, rate)
	}
	// Exponential gaps have a coefficient of variation of 1; an evenly spaced trace with the same mean rate has nearly 0.
	var sum, sumSq float64
	for i := 1; i < len(rows); i++ {
		g := float64(rows[i].OffsetMs - rows[i-1].OffsetMs)
		sum += g
		sumSq += g * g
	}
	k := float64(len(rows) - 1)
	mean := sum / k
	if cv := math.Sqrt(sumSq/k-mean*mean) / mean; math.Abs(cv-1) > 0.1 {
		t.Fatalf("inter-arrival coefficient of variation %.3f, want about 1 for Poisson arrivals", cv)
	}
	inChars := map[int]int{}
	outs := map[int]int{}
	for i, r := range rows {
		if r.Index != i || (i > 0 && r.OffsetMs < rows[i-1].OffsetMs) {
			t.Fatalf("row %d is out of order", i)
		}
		if r.Tenant != PremiumTenant || r.IsNoisy || r.MinOutputTokens != r.MaxOutputTokens {
			t.Fatalf("row %d: tenant %q noisy %v min %d max %d", i, r.Tenant, r.IsNoisy, r.MinOutputTokens, r.MaxOutputTokens)
		}
		inChars[r.PromptLenChars]++
		outs[r.MaxOutputTokens]++
	}
	n := float64(len(rows))
	for chars, want := range map[int]float64{1174: 0.5, 5183: 0.3, 10532: 0.2} {
		if got := float64(inChars[chars]) / n; math.Abs(got-want) > 0.03 {
			t.Errorf("input %d chars at %.3f, want %.1f", chars, got, want)
		}
	}
	for tokens, want := range map[int]float64{64: 0.5, 256: 0.5} {
		if got := float64(outs[tokens]) / n; math.Abs(got-want) > 0.03 {
			t.Errorf("output %d at %.3f, want %.1f", tokens, got, want)
		}
	}
}

// TestVersionTracePassesTheBundleCheck: what the generator writes is what checkTraceRows accepts, warm-up qualification included.
func TestVersionTracePassesTheBundleCheck(t *testing.T) {
	d := versionAsyncDesign()
	seed, _ := WorkloadSeed(d.CampaignSeed, 1, LoadL060)
	rows, err := d.VersionTrace(seed, 2.4, 300)
	if err != nil {
		t.Fatal(err)
	}
	bt := BundleTrace{Block: 1, Load: LoadL060, Seed: seed, MeasuredRows: d.MeasuredRows(rows, 300)}
	if err := d.checkTraceRows(bt, rows, 300); err != nil {
		t.Fatal(err)
	}
}

// TestVersionTraceRefusesAWarmupThatMissesAClass: the registration says warm-up qualifies by content, and redrawing until it does would be choosing a workload.
func TestVersionTraceRefusesAWarmupThatMissesAClass(t *testing.T) {
	d := versionAsyncDesign()
	_, err := d.VersionTrace(7, 0.05, 300)
	if err == nil || !strings.Contains(err.Error(), "warm-up") {
		t.Fatalf("err %v, want a refusal naming the warm-up", err)
	}
}

// TestVersionTraceRefusesBadInputs keeps a rate or a window the design cannot use from producing a trace.
func TestVersionTraceRefusesBadInputs(t *testing.T) {
	d := versionAsyncDesign()
	for name, c := range map[string]struct {
		rate   float64
		window int
	}{
		"zero rate":       {0, 300},
		"negative rate":   {-1, 300},
		"NaN rate":        {math.NaN(), 300},
		"short window":    {2, d.MinMeasureSeconds - 60},
		"long window":     {2, d.MaxMeasureSeconds + 60},
		"off-step window": {2, d.MinMeasureSeconds + 30},
	} {
		if _, err := d.VersionTrace(1, c.rate, c.window); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

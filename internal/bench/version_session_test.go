package bench

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// visit is one call the block runner made.
type visit struct {
	block     int
	treatment string
	loads     []string
}

// blocksRun runs RunBlocks on a fake instance with a real attempt journal, and returns the archived ledger with every visit.
//
// outcome decides each visit; cancel, when set, is called before the visit it names runs.
func blocksRun(t *testing.T, spent float64, outcome func(block int, treatment string) (VisitOutcome, error), cancelAt *visit) (BlocksResult, AttemptLedger, []visit) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "attempts.jsonl")
	j, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	now := func() time.Time { clock = clock.Add(time.Minute); return clock }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var visits []visit
	res, err := RunBlocks(ctx, SessionBlocks{
		Design: versionAsyncDesign(), WindowSeconds: 300, RatePerHour: 1.0,
		Spent: func() float64 { return spent }, Now: now, Ledger: j,
		Visit: func(_ context.Context, block int, treatment string, loads []string) (VisitOutcome, error) {
			if cancelAt != nil && cancelAt.block == block && cancelAt.treatment == treatment {
				cancel()
			}
			visits = append(visits, visit{block, treatment, loads})
			return outcome(block, treatment)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := j.Archive(now()); err != nil {
		t.Fatal(err)
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	l, pending, err := ReadAttemptJournal(path, "camp-1")
	if err != nil || pending != nil {
		t.Fatalf("journal: pending %v err %v", pending, err)
	}
	return res, l, visits
}

func allValid(int, string) (VisitOutcome, error) { return VisitOutcome{}, nil }

// TestRunBlocksRunsTheSeededOrders: six valid blocks, each visiting the treatments and loads in its registered order.
func TestRunBlocksRunsTheSeededOrders(t *testing.T) {
	res, l, visits := blocksRun(t, 0, allValid, nil)
	if res.Valid != 6 || res.Stop != "" || len(visits) != 18 {
		t.Fatalf("result %+v after %d visits, want six valid blocks in 18 visits", res, len(visits))
	}
	for i, v := range visits {
		block := i/3 + 1
		if v.block != block || v.treatment != ArmOrder(20261115, block)[i%3] || !reflect.DeepEqual(v.loads, LoadOrder(block)) {
			t.Fatalf("visit %d is %+v, want block %d's seeded order", i, v, block)
		}
	}
	if set, err := versionAsyncDesign().AnalysisSet(l); err != nil || len(set) != 6 {
		t.Fatalf("analysis set %v err %v", set, err)
	}
}

// TestRunBlocksReplacesInvalidBlocksAfterThePlannedOnes: a replacement takes the next number and names the block it replaces.
func TestRunBlocksReplacesInvalidBlocksAfterThePlannedOnes(t *testing.T) {
	res, l, visits := blocksRun(t, 0, func(block int, treatment string) (VisitOutcome, error) {
		switch {
		case block == 2 && treatment == TreatmentA:
			return VisitOutcome{Invalid: "protocol fault"}, nil
		case block == 4 && treatment == TreatmentC:
			return VisitOutcome{Invalid: "incomplete accounting"}, nil
		}
		return VisitOutcome{}, nil
	}, nil)
	if res.Valid != 6 || res.Stop != "" {
		t.Fatalf("result %+v, want six valid blocks after two replacements", res)
	}
	got := map[int]int{}
	for _, a := range l.Attempts {
		got[a.Block] = a.Replaces
	}
	if !reflect.DeepEqual(got, map[int]int{1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 2, 8: 4}) {
		t.Fatalf("attempts %+v, want 7 replacing 2 and 8 replacing 4", l.Attempts)
	}
	if !strings.Contains(l.Attempts[3].Reason, "incomplete accounting") || len(visits) != 24 {
		t.Fatalf("block 4 reason %q after %d visits; an invalid visit still runs the block's other visits", l.Attempts[3].Reason, len(visits))
	}
	if set, err := versionAsyncDesign().AnalysisSet(l); err != nil || !reflect.DeepEqual(set, []int{1, 3, 5, 6, 7, 8}) {
		t.Fatalf("analysis set %v err %v", set, err)
	}
}

// TestRunBlocksStopRules: each rule that ends the campaign early leaves a ledger the analysis still reads.
func TestRunBlocksStopRules(t *testing.T) {
	t.Run("a third invalid block has no replacement", func(t *testing.T) {
		res, l, _ := blocksRun(t, 0, func(block int, _ string) (VisitOutcome, error) {
			if block <= 3 {
				return VisitOutcome{Invalid: "incomplete accounting"}, nil
			}
			return VisitOutcome{}, nil
		}, nil)
		if res.Valid != 5 || !strings.Contains(res.Stop, "no replacement remains") || len(l.Attempts) != 8 {
			t.Fatalf("result %+v with %d attempts", res, len(l.Attempts))
		}
		// The ledger is one the analysis reads; it reads it as the incomplete pilot the stop made.
		if _, err := versionAsyncDesign().AnalysisSet(l); err == nil || !strings.Contains(err.Error(), "incomplete pilot") {
			t.Fatalf("analysis: %v, want an incomplete pilot", err)
		}
	})
	t.Run("lag in two blocks of one treatment", func(t *testing.T) {
		res, l, _ := blocksRun(t, 0, func(block int, treatment string) (VisitOutcome, error) {
			if (block == 1 || block == 3) && treatment == TreatmentB {
				return VisitOutcome{Invalid: "dispatch lag p99 12 ms", LagInvalid: true}, nil
			}
			return VisitOutcome{}, nil
		}, nil)
		if !strings.Contains(res.Stop, "treatment "+TreatmentB+" in two blocks") || len(l.Attempts) != 3 {
			t.Fatalf("result %+v with %d attempts, want a stop after block 3", res, len(l.Attempts))
		}
	})
	t.Run("lag in two treatments once each does not stop", func(t *testing.T) {
		res, _, _ := blocksRun(t, 0, func(block int, treatment string) (VisitOutcome, error) {
			if (block == 1 && treatment == TreatmentB) || (block == 3 && treatment == TreatmentC) {
				return VisitOutcome{Invalid: "dispatch lag", LagInvalid: true}, nil
			}
			return VisitOutcome{}, nil
		}, nil)
		if res.Valid != 6 || res.Stop != "" {
			t.Fatalf("result %+v, want both lagged blocks replaced", res)
		}
	})
	t.Run("a recorder failure stops the campaign", func(t *testing.T) {
		stopAt := ArmOrder(20261115, 2)[0]
		res, l, visits := blocksRun(t, 0, func(block int, treatment string) (VisitOutcome, error) {
			if block == 2 && treatment == stopAt {
				return VisitOutcome{}, errors.New("rows file: no space left on device")
			}
			return VisitOutcome{}, nil
		}, nil)
		last := l.Attempts[len(l.Attempts)-1]
		if len(l.Attempts) != 2 || last.Status != AttemptStopped || !strings.Contains(last.Reason, "recorder failure") || len(visits) != 4 {
			t.Fatalf("result %+v, attempts %+v after %d visits, want block 2 stopped at its first visit", res, l.Attempts, len(visits))
		}
	})
	t.Run("the budget refuses before block 1", func(t *testing.T) {
		res, l, visits := blocksRun(t, 19, allValid, nil)
		if !strings.Contains(res.Stop, "budget") || len(l.Attempts) != 0 || len(visits) != 0 {
			t.Fatalf("result %+v with %d attempts, %d visits", res, len(l.Attempts), len(visits))
		}
	})
	t.Run("the deadline cuts a block short", func(t *testing.T) {
		res, l, visits := blocksRun(t, 0, allValid, &visit{block: 2, treatment: ArmOrder(20261115, 2)[1]})
		last := l.Attempts[len(l.Attempts)-1]
		if len(l.Attempts) != 2 || last.Status != AttemptStopped || !strings.Contains(res.Stop, "block 2 stopped") || len(visits) != 5 {
			t.Fatalf("result %+v, attempts %+v after %d visits", res, l.Attempts, len(visits))
		}
		// The ledger is one the analysis reads; it reads it as the incomplete pilot the stop made.
		if _, err := versionAsyncDesign().AnalysisSet(l); err == nil || !strings.Contains(err.Error(), "incomplete pilot") {
			t.Fatalf("analysis: %v, want an incomplete pilot", err)
		}
	})
}

// TestRunBlocksChargesEveryValidBlockStillNeeded: the check before a block counts all the blocks still missing.
func TestRunBlocksChargesEveryValidBlockStillNeeded(t *testing.T) {
	d := versionAsyncDesign()
	// Affordable for five more blocks at a $1/h rate but not for six.
	block := float64(d.BlockBoundSeconds(300)) / 3600
	spent := d.BudgetUSD - d.ReserveUSD - float64(d.Bounds.TeardownSeconds)/3600 - 5.5*block
	res, l, _ := blocksRun(t, spent, allValid, nil)
	if len(l.Attempts) != 0 || !strings.Contains(res.Stop, "6 valid blocks") {
		t.Fatalf("result %+v with %d attempts, want a refusal before block 1", res, len(l.Attempts))
	}
}

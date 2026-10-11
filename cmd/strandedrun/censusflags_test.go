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

package main

import (
	"strings"
	"testing"
)

// An omitted disposition field must survive the parser as Unobserved, because that is the distinction the
// ledger exists to carry: "nobody looked" must not arrive as any outcome.
//
// Mutation that turns this red: default a missing disposition to queued-unadmitted, or reject the entry at the
// parser so the census never gets to invalidate on it.
func TestAnOmittedDispositionReachesTheCensusAsUnobserved(t *testing.T) {
	got, err := parseSubmissions("seen:1:released,never:2:")
	if err != nil {
		t.Fatalf("a ledger naming an unobserved submission was refused by the parser: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("parsed %d submissions, want 2", len(got))
	}
	if got[1].Disposition != DispositionUnobserved {
		t.Errorf("submission %q disposition = %q, want the zero value; the parser must not invent an outcome",
			got[1].Name, got[1].Disposition)
	}
	if got[1].Request != 2 {
		t.Errorf("request = %d, want 2", got[1].Request)
	}
	// And the census must then refuse, so the parser's restraint is load-bearing rather than cosmetic.
	c := Census{Step: "s", Settled: true, Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0}), Submissions: got}
	if _, err := c.Report(); err == nil {
		t.Error("a census built from a ledger with an unobserved submission produced a report")
	}
}

// Ledger input the parser cannot read is refused rather than defaulted.
//
// Mutation that turns this red: skip malformed entries instead of failing.
func TestTheLedgerParserRefusesWhatItCannotRead(t *testing.T) {
	for _, in := range []string{
		"name-only",
		"a:1",
		"a:one:bound:w1",
		"a:1:bound:w1:extra",
		"a:1:released,a:2:released",
	} {
		if _, err := parseSubmissions(in); err == nil {
			t.Errorf("parseSubmissions(%q) was accepted", in)
		}
	}
	// An empty ledger is legitimate: an idle cluster with nothing submitted. Report distinguishes that from a
	// ledger whose entries are unobserved.
	got, err := parseSubmissions("")
	if err != nil || got != nil {
		t.Errorf("an empty ledger should parse to nothing without error, got %v / %v", got, err)
	}
}

// Foreign reservations parse as a per-node map, because the amendment lets them be declared or invalidate.
//
// Mutation that turns this red: ignore the flag, or fold every node's foreign count into one total.
func TestForeignReservationsParsePerNode(t *testing.T) {
	got, err := parseForeign("w1:2, w2:1")
	if err != nil {
		t.Fatalf("a well-formed foreign declaration was refused: %v", err)
	}
	if got["w1"] != 2 || got["w2"] != 1 {
		t.Errorf("parseForeign = %v, want w1=2 w2=1", got)
	}
	for _, in := range []string{"w1", "w1:many", "w1:1:2"} {
		if _, err := parseForeign(in); err == nil {
			t.Errorf("parseForeign(%q) was accepted", in)
		}
	}
	if got, err := parseForeign(""); err != nil || got != nil {
		t.Errorf("an empty declaration should parse to nothing without error, got %v / %v", got, err)
	}
}

// take-census requires a step name, because a figure with no step cannot be placed in the series the amendment
// requires in place of a peak.
//
// Mutation that turns this red: give -step a default.
func TestTakeCensusRequiresAStepName(t *testing.T) {
	err := takeCensus([]string{"-settled", "-nodes=w1:1:0,w2:1:0"})
	if err == nil {
		t.Fatal("take-census ran without a step name")
	}
	if !strings.Contains(err.Error(), "-step is required") {
		t.Errorf("the refusal does not name the missing flag: %v", err)
	}
	// With one, the same census is read.
	if err := takeCensus([]string{"-step=named", "-settled", "-nodes=w1:1:0,w2:1:0"}); err != nil {
		t.Errorf("a named, settled census was refused: %v", err)
	}
	// And -settled is not implied: a reading taken mid-binding has to be refused through the command too.
	if err := takeCensus([]string{"-step=named", "-nodes=w1:1:0,w2:1:0"}); err == nil {
		t.Error("take-census accepted a census that did not assert it was settled")
	}
}

package main

import (
	"reflect"
	"strings"
	"testing"
)

// Two scorers are compared on the same prompt sequence, so the prefix must be identical across runs.
func TestPrefixTextIsDeterministicPerFamily(t *testing.T) {
	first, again := prefixText("F0", 50), prefixText("F0", 50)
	if first != again {
		t.Fatal("same family produced different prefixes")
	}
	if prefixText("F0", 50) == prefixText("F1", 50) {
		t.Fatal("different families produced the same prefix")
	}
}

// Families must part at the first word: two names sharing a long beginning would otherwise share whole cache blocks,
// and a pod never warmed for a family could score above zero and count as a predicted hit.
func TestFamiliesDifferFromTheFirstWord(t *testing.T) {
	a := prefixText("R-delete-vllm-d-8579766dcd-8c7vj", 10)
	b := prefixText("R-delete-vllm-d-8579766dcd-cj2pl", 10)
	if strings.Fields(a)[0] == strings.Fields(b)[0] {
		t.Fatalf("families with a common name start share their first word:\n%q\n%q", a, b)
	}
}

// A hit must come only from the shared prefix, so two requests of a family differ only after it.
func TestPromptsShareExactlyTheFamilyPrefix(t *testing.T) {
	a, b := promptFor("F0", 40, "r-1"), promptFor("F0", 40, "r-2")
	p := prefixText("F0", 40)
	if !strings.HasPrefix(a, p) || !strings.HasPrefix(b, p) || a == b {
		t.Fatalf("prompts do not share exactly the prefix:\n%q\n%q", a, b)
	}
}

func TestExpandPlan(t *testing.T) {
	got, err := expandPlan("F0,F1*2, W ,")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"F0", "F1", "F1", "W"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for _, bad := range []string{"", "F0*0", "F0*x"} {
		if _, err := expandPlan(bad); err == nil {
			t.Fatalf("plan %q was accepted", bad)
		}
	}
}

// Zero cached tokens is a real observation, so an absent field must be an error rather than a silent zero.
func TestParseUsageRefusesMissingDetails(t *testing.T) {
	for _, body := range []string{
		`{"usage":{"prompt_tokens":10}}`,
		`{"usage":{"prompt_tokens":10,"prompt_tokens_details":{}}}`,
		`{"usage":{"prompt_tokens":10,"prompt_tokens_details":{"cached_tokens":null}}}`,
	} {
		if _, _, err := parseUsage([]byte(body)); err == nil {
			t.Fatalf("%s was read as zero cached tokens", body)
		}
	}
	p, c, err := parseUsage([]byte(`{"usage":{"prompt_tokens":10,"prompt_tokens_details":{"cached_tokens":0}}}`))
	if err != nil || p != 10 || c != 0 {
		t.Fatalf("got %d %d %v", p, c, err)
	}
}

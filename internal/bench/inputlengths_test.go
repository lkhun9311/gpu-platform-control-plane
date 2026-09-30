package bench

import (
	"encoding/json"
	"os"
	"testing"
)

// TestInputLengthTableMatchesTheMeasurement ties the Go table to the JSON the resolver wrote.
//
// The values live in two places: internal/bench/inputlengths.go, which CompilePlan reads, and
// hack/input-length-resolution.json, which hack/resolve-input-lengths.sh produced by sweeping candidate
// prompt lengths against the served tokenizer. A value living in two places with no ruler between them is
// the shape of every overclaim this project has had to withdraw, so this is the ruler.
//
// It cannot prove the JSON came from a real sweep -- only re-running the resolver does that. What it proves
// is that nobody can edit one side without the other disagreeing, which is the failure that actually
// happens: a number gets adjusted where it is read and not where it was measured.
func TestInputLengthTableMatchesTheMeasurement(t *testing.T) {
	const path = "../../hack/input-length-resolution.json"

	blob, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the resolution table: %v", err)
	}
	var file struct {
		Tokenizer                        string `json:"tokenizer"`
		TokenizerRevision                string `json:"tokenizerRevision"`
		TokenizerCoreFilesCombinedSHA256 string `json:"tokenizerCoreFilesCombinedSHA256"`
		ChatTemplateSHA256               string `json:"chatTemplateSHA256"`
		ServingImage                     string `json:"servingImage"`
		Resolved                         map[string]struct {
			Chars      int   `json:"chars"`
			Matches    int   `json:"matches"`
			AllMatches []int `json:"allMatches"`
		} `json:"resolved"`
	}
	if err := json.Unmarshal(blob, &file); err != nil {
		t.Fatalf("decode the resolution table: %v", err)
	}

	// The identity first. A table measured against a different tokenizer is a different table, and the Go
	// constants are what a manifest's tokenizerRev will be compared against.
	for _, c := range []struct{ name, got, want string }{
		{"tokenizerRevision", InputLengthTokenizerRevision, file.TokenizerRevision},
		{"tokenizerCoreFilesCombinedSHA256", InputLengthTokenizerFilesSHA256, file.TokenizerCoreFilesCombinedSHA256},
		{"chatTemplateSHA256", InputLengthChatTemplateSHA256, file.ChatTemplateSHA256},
		{"servingImage", InputLengthServingImage, file.ServingImage},
	} {
		if c.got != c.want {
			t.Errorf("%s: Go has %q, the measurement recorded %q", c.name, c.got, c.want)
		}
	}
	if file.Tokenizer != ServedModel {
		t.Errorf("the table was measured against %q and the plan compiler serves %q", file.Tokenizer, ServedModel)
	}

	// Then the entries, in both directions. One direction alone would let an entry be added to the Go table
	// with no measurement behind it, or a measured entry be silently dropped from the code.
	if got, want := len(resolvedInputLengths), len(file.Resolved); got != want {
		t.Errorf("the Go table holds %d entries and the measurement holds %d", got, want)
	}
	for _, tokens := range ResolvedInputTokenCounts() {
		key := itoa(tokens)
		m, ok := file.Resolved[key]
		if !ok {
			t.Errorf("the Go table carries %d tokens and the measurement does not; a value nobody swept is a guess", tokens)
			continue
		}
		r, _ := ResolveInputTokens(tokens)
		if r.Chars != m.Chars {
			t.Errorf("%d tokens: Go says %d characters, the measurement says %d", tokens, r.Chars, m.Chars)
		}
		if r.Matches != m.Matches {
			t.Errorf("%d tokens: Go says %d matches, the measurement says %d", tokens, r.Matches, m.Matches)
		}
		// The recorded length must be the SMALLEST match, which is the rule the table declares. Checking it
		// here is what makes that rule enforced rather than described: transcribing any other member of
		// allMatches would pass the two comparisons above.
		if len(m.AllMatches) == 0 {
			t.Errorf("%d tokens: the measurement lists no matches at all, so its chars value came from nowhere", tokens)
			continue
		}
		smallest := m.AllMatches[0]
		for _, n := range m.AllMatches {
			if n < smallest {
				smallest = n
			}
		}
		if m.Chars != smallest {
			t.Errorf("%d tokens: the table records %d but the smallest match is %d; the rule is the smallest",
				tokens, m.Chars, smallest)
		}
		if len(m.AllMatches) != m.Matches {
			t.Errorf("%d tokens: matches says %d and allMatches lists %d", tokens, m.Matches, len(m.AllMatches))
		}
	}
}

// itoa avoids importing strconv for one call in a test that is otherwise about comparison.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

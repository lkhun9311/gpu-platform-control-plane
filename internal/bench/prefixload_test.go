package bench

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func prefixStudyLoad(t *testing.T) PrefixLoad {
	t.Helper()
	st, ok := LookupStudy(StudyPrefixRoute)
	if !ok || st.PrefixLoad == nil || st.Arrivals != ArrivalsSharedPrefix {
		t.Fatalf("study %s is not registered with a shared-prefix load", StudyPrefixRoute)
	}
	return *st.PrefixLoad
}

// Every message is exactly the registered length, a request shares exactly its system prompt with the others of its
// group, and nothing with another group.
// Mutation that turns this red: drop the group header, or let the suffix fill to a length of its own.
func TestPrefixTraceSharesExactlyTheSystemPrompt(t *testing.T) {
	load := prefixStudyLoad(t)
	rows, err := GeneratePrefixTrace(load, 941, false)
	if err != nil {
		t.Fatal(err)
	}
	byGroup := map[int][]string{}
	for _, r := range rows {
		p := PromptForRow(r)
		if len(p) != load.PromptChars {
			t.Fatalf("row %d is %d characters, want %d", r.Index, len(p), load.PromptChars)
		}
		byGroup[r.PrefixGroup] = append(byGroup[r.PrefixGroup], p)
	}
	if len(byGroup) < 2 {
		t.Fatalf("only %d groups drawn", len(byGroup))
	}
	var firsts []string
	for g, ps := range byGroup {
		if g < 1 || g > load.Groups {
			t.Fatalf("group %d outside 1..%d", g, load.Groups)
		}
		for _, p := range ps[1:] {
			if p[:load.PrefixChars] != ps[0][:load.PrefixChars] {
				t.Fatalf("group %d's requests differ inside the system prompt", g)
			}
			if p == ps[0] {
				t.Fatalf("two requests of group %d are identical, so their suffixes are shared", g)
			}
		}
		firsts = append(firsts, ps[0][:64])
	}
	for i := range firsts {
		for j := range i {
			if firsts[i] == firsts[j] {
				t.Fatal("two groups share their first 64 characters")
			}
		}
	}
}

// The control keeps every arrival, length and group of the shared trace for the same seed, and gives every request a
// first chunk of its own.
// Mutation that turns this red: leave the header where the shared trace puts it.
func TestPrefixControlIsTheSameLoadWithUniqueStarts(t *testing.T) {
	load := prefixStudyLoad(t)
	shared, err := GeneratePrefixTrace(load, 944, false)
	if err != nil {
		t.Fatal(err)
	}
	control, err := GeneratePrefixTrace(load, 944, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(shared) != len(control) {
		t.Fatalf("%d and %d rows", len(shared), len(control))
	}
	seen := map[string]bool{}
	for i := range shared {
		s, c := shared[i], control[i]
		if s.OffsetMs != c.OffsetMs || s.PrefixGroup != c.PrefixGroup || s.PromptLenChars != c.PromptLenChars {
			t.Fatalf("row %d differs in its load", i)
		}
		p := PromptForRow(c)
		if len(p) != load.PromptChars {
			t.Fatalf("control row %d is %d characters", i, len(p))
		}
		if seen[p[:256]] {
			t.Fatalf("control row %d shares its first chunk", i)
		}
		seen[p[:256]] = true
	}
}

// A trace that predates shared prefixes sends what it always sent.
func TestPromptForRowLeavesOldTracesAlone(t *testing.T) {
	r := TraceRow{Index: 3, PromptLenChars: 1174}
	if PromptForRow(r) != PromptText(1174) {
		t.Fatal("an ordinary row's prompt changed")
	}
}

// The paid session regenerates its traces and refuses any whose checksum is not the frozen one, so a change to the
// generator, the study's load or the output fixing must fail here first, before a session finds it.
// Mutation that turns this red: change any value of the registered PrefixLoad, or the group draw.
func TestPrefixTracesMatchTheFrozenChecksums(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "hack", "eks-serve", "prefix-route-study", "frozen-traces.sha256"))
	if err != nil {
		t.Fatal(err)
	}
	load := prefixStudyLoad(t)
	n := 0
	for line := range strings.SplitSeq(strings.TrimSpace(string(raw)), "\n") {
		want, name, ok := strings.Cut(line, "  ")
		if !ok {
			t.Fatalf("line %q is not a sha256sum line", line)
		}
		kind, seedText, _ := strings.Cut(strings.TrimSuffix(name, ".jsonl"), "-")
		seed, err := strconv.ParseInt(seedText, 10, 64)
		if err != nil {
			t.Fatal(err)
		}
		rows, err := GeneratePrefixTrace(load, seed, kind == "control")
		if err != nil {
			t.Fatal(err)
		}
		if err := FixOutputAtCap(rows); err != nil {
			t.Fatal(err)
		}
		var b strings.Builder
		if err := WriteTrace(&b, rows); err != nil {
			t.Fatal(err)
		}
		if got := Checksum([]byte(b.String())); got != want {
			t.Errorf("%s regenerates as %s, frozen as %s", name, got, want)
		}
		n++
	}
	if n != 4 {
		t.Fatalf("%d frozen traces, want 4", n)
	}
}

// The trace checksum covers lengths, groups and seeds, not the text: PromptForRow synthesises that at send time, as
// PromptText always has. So the bytes every request of the frozen traces sends are pinned here as well.
// Mutation that turns this red: change a header's wording, the order of the parts, or the corpus.
func TestPrefixPromptsMatchTheFrozenBytes(t *testing.T) {
	want := map[string]string{
		"shared-941":  "2a86079bd08eba6168fa42472ae134c47c71a80b9f8782024c0c3582d9a209a6",
		"shared-942":  "2ce1894a36e616dfc9626f70206546c04dca75ffddf6554bd084f0fc7503e61e",
		"shared-943":  "33d368b73e2f2d34164b713431cc3b6a61bef3d10f52d3dcbe6b658f37a3ba34",
		"control-944": "12b8b4ccabf6fe97ee7867091269c2a3a55e6eaf59ee75f995c350c77eeb9ecc",
	}
	load := prefixStudyLoad(t)
	for name, digest := range want {
		kind, seedText, _ := strings.Cut(name, "-")
		seed, _ := strconv.ParseInt(seedText, 10, 64)
		rows, err := GeneratePrefixTrace(load, seed, kind == "control")
		if err != nil {
			t.Fatal(err)
		}
		var all strings.Builder
		for _, r := range rows {
			all.WriteString(PromptForRow(r))
			all.WriteByte('\n')
		}
		if got := Checksum([]byte(all.String())); got != digest {
			t.Errorf("%s's prompts digest to %s, frozen as %s", name, got, digest)
		}
	}
}

func TestPrefixTraceRefusesALoadWithNoRoom(t *testing.T) {
	load := prefixStudyLoad(t)
	load.PromptChars = load.PrefixChars + 5
	if _, err := GeneratePrefixTrace(load, 941, false); err == nil || !strings.Contains(err.Error(), "no room") {
		t.Fatalf("a load whose own part cannot hold its header was accepted: %v", err)
	}
}

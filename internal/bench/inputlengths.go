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

package bench

// Declared input-token counts resolved to the character length that produces exactly that many tokens.
//
// WHY A TABLE AND NOT A FUNCTION. There is no function. The generator takes characters, the CRD declares
// tokens, and ceil(chars/4) relates them badly enough to be useless as an inverse: the committed calibration
// measures 50 estimated against 68 actual at 200 characters, and 10,000 against 7,695 at 40,000. The
// relationship is a property of a specific tokenizer and chat template, so it is measured once and recorded.
//
// WHY IN GO AND NOT LOADED FROM THE JSON. cmd/strandedrun/protocol.go records this repository's decision
// against go:embed and there is no precedent for it here, and a path-loading table would make CompilePlan
// depend on a file the caller has to find -- a compiler that can be made to accept anything by pointing it
// somewhere else is not a gate. The values live here, and TestInputLengthTableMatchesTheMeasurement compares
// them against hack/input-length-resolution.json digit for digit, so the two cannot drift.
//
// HOW TO ADD A VALUE. Run hack/resolve-input-lengths.sh with the token count, which fetches the tokenizer
// files at the pinned revision, generates candidates from the real corpus through benchharness, tokenizes
// them inside the serving image, and writes the JSON. Then transcribe the entry here. Do not compute one.

// ResolvedInputLength is one measured (tokens -> characters) pair and what the measurement saw.
type ResolvedInputLength struct {
	// Chars is the SMALLEST character length that tokenizes to the declared count.
	//
	// Smallest because several lengths give the same count -- eight of them for 256 tokens -- and the fewest
	// bytes on the wire is the one choice that needs no further justification. Matches records how many there
	// were so the choice is visible rather than implied.
	Chars int
	// Matches is how many character lengths in the swept window produced exactly the declared count.
	//
	// It is carried because 1 and 8 mean different things about how sharp the resolution is, and a reader
	// comparing two runs should be able to see that without re-running the sweep.
	Matches int
}

// InputLengthTokenizerRevision is the model revision the table was measured against.
//
// A table measured against one tokenizer says nothing about another. This is recorded so a manifest's
// tokenizerRev can be compared with it: a run whose engine serves a different revision is a run the table
// does not describe, and the comparison is the only thing that can notice.
const InputLengthTokenizerRevision = "aa8e72537993ba99e69dfaafa59ed015b17504d1"

// InputLengthTokenizerFilesSHA256 and InputLengthChatTemplateSHA256 identify what actually did the counting.
//
// The revision is where the files came from; these are what they were. Both are in the table because the
// revision can move without the tokenizer changing, and the tokenizer can be identical across revisions --
// measured: Qwen2.5 0.5B, 3B and 7B carry byte-identical tokenizer files under three different revisions.
const (
	InputLengthTokenizerFilesSHA256 = "81feaac8d04514a200e05e9a15d594181fff403abc1202b11a5f3883198155e1"
	InputLengthChatTemplateSHA256   = "cd8e9439f0570856fd70470bf8889ebd8b5d1107207f67a5efb46e342330527f"
)

// InputLengthServingImage is the digest-pinned image the counting ran inside.
//
// It is the image the sharing topologies deploy, which is what makes this a measurement of the served
// tokenizer rather than of a vendored copy of one -- the objection cmd/benchharness/exacttokens.go raises
// against importing a tokenizer, and the reason this does not fall to it.
const InputLengthServingImage = "vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"

// resolvedInputLengths is the measured table. Every entry came from a sweep; none was computed.
var resolvedInputLengths = map[int]ResolvedInputLength{
	256:  {Chars: 1174, Matches: 8},
	2048: {Chars: 10532, Matches: 5},
	8192: {Chars: 42579, Matches: 3},
}

// ResolveInputTokens returns the measured character length for a declared token count.
//
// The second return is false for a count the table does not carry, and that is a REFUSAL rather than a
// missing-data condition: nothing here may guess a character length. A caller that wants another count runs
// the resolver and adds the entry.
func ResolveInputTokens(tokens int) (ResolvedInputLength, bool) {
	r, ok := resolvedInputLengths[tokens]
	return r, ok
}

// ResolvedInputTokenCounts lists the counts the table carries, in ascending order.
//
// Used by the refusal message, so an operator is told what IS available rather than only what is not.
func ResolvedInputTokenCounts() []int {
	out := make([]int, 0, len(resolvedInputLengths))
	for t := range resolvedInputLengths {
		out = append(out, t)
	}
	// Sorted, because a map iteration order in a refusal message makes the same failure read differently
	// on consecutive runs and sends a reader looking for a change that did not happen.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j-1] > out[j]; j-- {
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	return out
}

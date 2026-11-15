package bench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// TestTheSenderDigestsTheOutputText: the registered diagnostic, so two arms' greedy outputs can be compared without storing them.
func TestTheSenderDigestsTheOutputText(t *testing.T) {
	sum := sha256.Sum256([]byte("hihi"))
	want := hex.EncodeToString(sum[:])
	res := readOneStream(t, streamChunk+streamChunk+"data: [DONE]\n\n")
	if res.OutputSHA256 != want {
		t.Fatalf("digest %q, want sha256 of the concatenated content %q", res.OutputSHA256, want)
	}
	// A stream cut off after its content still reports what it delivered.
	if cut := readOneStream(t, streamChunk+streamChunk); cut.OutputSHA256 != want {
		t.Fatalf("a truncated stream's digest %q, want %q", cut.OutputSHA256, want)
	}
	// No content is no digest, never the digest of the empty string.
	if none := readOneStream(t, "data: [DONE]\n\n"); none.OutputSHA256 != "" {
		t.Fatalf("a stream with no content has digest %q", none.OutputSHA256)
	}
}

// TestReplayCarriesTheDigestToTheRow: the row is what the archive keeps.
func TestReplayCarriesTheDigestToTheRow(t *testing.T) {
	rows := Replay(t.Context(), digestSender{}, []TraceRow{{Index: 0}}, ReplayOptions{})
	if rows[0].OutputSHA256 != "abc" {
		t.Fatalf("row digest %q", rows[0].OutputSHA256)
	}
}

// digestSender answers every request with a fixed digest.
type digestSender struct{}

func (digestSender) Send(_ context.Context, _ TraceRow, _ int64) SendResult {
	return SendResult{HTTPStatus: 200, OutputSHA256: "abc"}
}

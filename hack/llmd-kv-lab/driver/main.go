// Command driver sends completions with controlled shared prefixes through the llm-d-router lab and records,
// per request, which simulator pod served it and how many prompt tokens that pod already had cached.
//
// The pod comes from the simulator's x-inference-pod response header rather than from the EPP, because the
// header is set by the process that did the work, so it cannot disagree with where the request really went.
// The cached-token count comes from usage.prompt_tokens_details.cached_tokens for the same reason: it is the
// simulator's own prefix-cache lookup, the ground truth a routing decision is trying to predict.
//
// The EPP's view (its per-endpoint scores) is joined later from its logs by the x-request-id the simulator echoes,
// because the gateway replaces the one this sets and the EPP logs the gateway's.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"hash/fnv"
	"io"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"time"
)

// vocabulary is plain English so the prompt tokenizes the same way under the simulator's real tokenizer and
// the EPP's character estimate; exotic text would make the two disagree on block boundaries for reasons
// unrelated to routing.
var vocabulary = strings.Fields(`the a of and to in is it that was for on are as with his they at be this from
have or by one had not but what all were when we there can an your which their said if do will each about how up
out them then she many some so these would other into has more her two like him see time could no make than first
been its who now people my made over did down only way find use may water long little very after words called just
where most know get through back much go good new write our me man too any day same right look think also around
another came come work three word must because does part even place well such here take why help put different
away again off went old number great tell men say small every found still between name should home big give air
line set own under read last never us left end along while might next sound below saw something thought both few
those always looked show large often together asked house world going want school important until form food keep
children feet land side without boy once animal life enough took sometimes four head above kind began almost live
page got earth need far hand high year mother light parts country father let night following picture being study
second eyes soon times story boys since white days ever paper hard near sentence better best across during today
others sure means knew turned girl usually along river city`)

// prefixText returns the shared prefix for a family: the same words every time for the same name, so a run
// can be replayed and two runs on different scorers see byte-identical prompts.
func prefixText(family string, words int) string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(family))
	// A seeded generator, not crypto, because the point is reproducibility.
	r := rand.New(rand.NewSource(int64(h.Sum64()))) //nolint:gosec
	out := make([]string, 0, words+5)
	// The family's hash comes first, so two families part at the first token even when their names share a long start;
	// otherwise they would share whole cache blocks and an unwarmed pod could score above zero for the other family.
	out = append(out, fmt.Sprintf("f%016x", h.Sum64()), "Context", "for", family+":")
	for range words {
		out = append(out, vocabulary[r.Intn(len(vocabulary))])
	}
	return strings.Join(out, " ")
}

// promptFor appends a suffix unique to the request, so every request shares exactly its family's prefix and
// nothing more, and a cache hit can only come from that prefix.
func promptFor(family string, words int, requestID string) string {
	return prefixText(family, words) + "\nQuestion " + requestID + ": summarise the context in one line."
}

// record is one line of the JSONL output.
type record struct {
	Seq       int     `json:"seq"`
	RequestID string  `json:"request_id"`
	Family    string  `json:"family"`
	Target    string  `json:"target"`
	SentAt    string  `json:"sent_at"`
	LatencyMS float64 `json:"latency_ms"`
	Status    int     `json:"status"`
	Pod       string  `json:"pod"`
	ViaEPP    bool    `json:"via_epp"`
	// ServedID is the x-request-id the simulator received; through the gateway it is the gateway's id, not ours.
	ServedID     string `json:"served_request_id"`
	PromptTokens int    `json:"prompt_tokens"`
	CachedTokens int    `json:"cached_tokens"`
	Error        string `json:"error,omitempty"`
}

type completionResponse struct {
	Usage struct {
		PromptTokens        int `json:"prompt_tokens"`
		PromptTokensDetails *struct {
			// A pointer, so an absent or null count is told apart from a real zero.
			CachedTokens *int `json:"cached_tokens"`
		} `json:"prompt_tokens_details"`
	} `json:"usage"`
}

// parseUsage reads the token counts; a missing details block is reported as an error rather than as zero
// cached tokens, because zero is a real answer and must not be manufactured by an absent field.
func parseUsage(body []byte) (prompt, cached int, err error) {
	var cr completionResponse
	if err := json.Unmarshal(body, &cr); err != nil {
		return 0, 0, fmt.Errorf("decode response: %w", err)
	}
	if cr.Usage.PromptTokensDetails == nil {
		return cr.Usage.PromptTokens, 0, errors.New("response has no prompt_tokens_details")
	}
	if cr.Usage.PromptTokensDetails.CachedTokens == nil {
		return cr.Usage.PromptTokens, 0, errors.New("response has no cached_tokens count")
	}
	return cr.Usage.PromptTokens, *cr.Usage.PromptTokensDetails.CachedTokens, nil
}

// expandPlan turns "F0,F1,F2*3" into a family per request; "*n" repeats so a plan stays one readable flag.
func expandPlan(plan string) ([]string, error) {
	var out []string
	for item := range strings.SplitSeq(plan, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		name, count := item, 1
		if i := strings.LastIndex(item, "*"); i > 0 {
			if _, err := fmt.Sscanf(item[i+1:], "%d", &count); err != nil || count < 1 {
				return nil, fmt.Errorf("bad repeat in %q", item)
			}
			name = item[:i]
		}
		for j := 0; j < count; j++ {
			out = append(out, name)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("empty plan")
	}
	return out, nil
}

func main() {
	url := flag.String("url", "http://127.0.0.1:30598", "base URL: the gateway, or a port-forwarded pod to bypass the EPP")
	model := flag.String("model", "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "model name")
	plan := flag.String("plan", "", "comma-separated families, e.g. F0,F1,F0*3")
	words := flag.Int("prefix-words", 300, "words in each family's shared prefix")
	tag := flag.String("tag", "run", "prefix of every x-request-id, so the EPP log can be joined")
	target := flag.String("target", "gateway", "label written into each record: gateway or direct:<pod>")
	gap := flag.Duration("gap", 300*time.Millisecond,
		"pause between requests, so KV events can land before the next decision")
	out := flag.String("out", "", "JSONL file to append to; stdout when empty")
	flag.Parse()

	families, err := expandPlan(*plan)
	if err != nil {
		fmt.Fprintln(os.Stderr, "driver:", err)
		os.Exit(2)
	}
	w := io.Writer(os.Stdout)
	if *out != "" {
		f, err := os.OpenFile(*out, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintln(os.Stderr, "driver:", err)
			os.Exit(2)
		}
		defer func() { _ = f.Close() }()
		w = f
	}
	client := &http.Client{Timeout: 60 * time.Second}
	enc := json.NewEncoder(w)
	failed := 0
	for i, fam := range families {
		rec := send(client, *url, *model, fam, *words, fmt.Sprintf("%s-%03d", *tag, i), *target)
		rec.Seq = i
		if rec.Error != "" {
			failed++
		}
		if err := enc.Encode(rec); err != nil {
			fmt.Fprintln(os.Stderr, "driver:", err)
			os.Exit(2)
		}
		time.Sleep(*gap)
	}
	// A run with failed requests still writes every row, but exits non-zero so a caller cannot read a partial
	// run as a clean one.
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "driver: %d of %d requests failed\n", failed, len(families))
		os.Exit(1)
	}
}

func send(client *http.Client, base, model, family string, words int, requestID, target string) record {
	rec := record{RequestID: requestID, Family: family, Target: target, SentAt: time.Now().UTC().Format(time.RFC3339Nano)}
	body, _ := json.Marshal(map[string]any{
		"model":       model,
		"prompt":      promptFor(family, words, requestID),
		"max_tokens":  8,
		"temperature": 0,
	})
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(base, "/")+"/v1/completions", bytes.NewReader(body))
	if err != nil {
		rec.Error = err.Error()
		return rec
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-request-id", requestID)
	start := time.Now()
	resp, err := client.Do(req)
	rec.LatencyMS = float64(time.Since(start).Microseconds()) / 1000
	if err != nil {
		rec.Error = err.Error()
		return rec
	}
	defer func() { _ = resp.Body.Close() }()
	data, _ := io.ReadAll(resp.Body)
	rec.Status = resp.StatusCode
	rec.Pod = resp.Header.Get("x-inference-pod")
	rec.ServedID = resp.Header.Get("x-request-id")
	// The EPP stamps this on every response it processed, so its presence proves the request took the routed path.
	rec.ViaEPP = resp.Header.Get("x-went-into-resp-headers") == "true"
	if resp.StatusCode != http.StatusOK {
		rec.Error = fmt.Sprintf("status %d: %.200s", resp.StatusCode, data)
		return rec
	}
	rec.PromptTokens, rec.CachedTokens, err = parseUsage(data)
	if err != nil {
		rec.Error = err.Error()
	}
	return rec
}

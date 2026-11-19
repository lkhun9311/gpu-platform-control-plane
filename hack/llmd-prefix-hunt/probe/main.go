// Command probe measures, per request, what llm-d-router's precise prefix-cache producer predicts each vLLM replica
// holds against what the replica then serves from its cache.
//
// It runs the router's own plugins, built from one pinned llm-d-router commit, outside Kubernetes.
// The token producer turns the request into token IDs as the EPP would, and one precise-prefix-cache-producer per
// router block size subscribes to every replica's KV-event socket, as the EPP does with per-pod subscriptions.
// Before each request it asks every producer for its per-replica match, then sends the request to the replica the plan
// names and records what vLLM reports as cached and when the first token arrived.
// The replica is the plan's, not a scheduler's, because the question is whether the index is right, not where a
// scorer would send the request.
//
// Beside the producers, a plain subscriber records every event batch each replica published, raw and decoded, so a
// disagreement can be traced to the events that caused it.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-zeromq/zmq4"
	dto "github.com/prometheus/client_model/go"
	"k8s.io/apimachinery/pkg/types"
	ctrlmetrics "sigs.k8s.io/controller-runtime/pkg/metrics"

	fwkdl "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/datalayer"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
	attrprefix "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/datalayer/attribute/prefix"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/requesthandling/dataproducer/preciseprefixcache"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/requesthandling/dataproducer/tokenizer"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/requesthandling/parsers/openai"
	"github.com/llm-d/llm-d-router/pkg/kvcache"
	"github.com/llm-d/llm-d-router/pkg/kvcache/kvblock"
	kvmetrics "github.com/llm-d/llm-d-router/pkg/kvcache/metrics"
	"github.com/llm-d/llm-d-router/pkg/kvevents"
	"github.com/llm-d/llm-d-router/pkg/kvevents/engineadapter"
)

// pod is one vLLM replica: its HTTP port serves requests and /render, and its ZMQ port publishes KV events.
type pod struct {
	Name     string
	Addr     string
	HTTPPort int
	ZMQPort  int
}

func (p pod) base() string { return "http://" + net.JoinHostPort(p.Addr, strconv.Itoa(p.HTTPPort)) }

// parsePods reads "a=10.0.0.2,b=10.0.0.3" with the default ports, or "a=127.0.0.1:8000:5557" with a pod's own.
func parsePods(s string, httpPort, zmqPort int) ([]pod, error) {
	var out []pod
	for _, kv := range strings.Split(s, ",") {
		name, rest, ok := strings.Cut(strings.TrimSpace(kv), "=")
		if !ok || name == "" || rest == "" {
			return nil, fmt.Errorf("pod %q is not name=addr", kv)
		}
		p := pod{Name: name, Addr: rest, HTTPPort: httpPort, ZMQPort: zmqPort}
		if parts := strings.Split(rest, ":"); len(parts) == 3 {
			h, err1 := strconv.Atoi(parts[1])
			z, err2 := strconv.Atoi(parts[2])
			if err1 != nil || err2 != nil {
				return nil, fmt.Errorf("pod %q has non-numeric ports", kv)
			}
			p.Addr, p.HTTPPort, p.ZMQPort = parts[0], h, z
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return nil, errors.New("no pods")
	}
	return out, nil
}

// metadata is the endpoint the producers see for a pod.
// Address and Port make the producer's index identity, "addr:port", which is also what its subscriber attributes events to.
func (p pod) metadata() *fwkdl.EndpointMetadata {
	return &fwkdl.EndpointMetadata{
		ID:      types.NamespacedName{Namespace: "hunt", Name: p.Name},
		Name:    p.Name,
		Address: p.Addr,
		Port:    strconv.Itoa(p.HTTPPort),
	}
}

// router is one precise-prefix-cache-producer and the block size it hashes with.
type router struct {
	name      string
	blockSize int
	producer  *preciseprefixcache.Producer
}

// prediction is what one router believes one pod holds of the request's prompt.
type prediction struct {
	CachedTokens int  `json:"cached_tokens"`
	GPUTokens    int  `json:"gpu_tokens"`
	MatchBlocks  int  `json:"match_blocks"`
	TotalBlocks  int  `json:"total_blocks"`
	BlockSize    int  `json:"block_size"`
	Found        bool `json:"found"`
}

// record is one request's line in requests.jsonl.
type record struct {
	Step
	Tokens       []uint32 `json:"tokens,omitempty"`
	RouterTokens int      `json:"router_prompt_tokens"`
	// Predictions holds router -> pod -> prediction, taken before the request was sent.
	Predictions map[string]map[string]prediction `json:"predictions"`
	// EngineTokens and RealizedCached are vLLM's usage for the request; -1 means the response carried no count.
	EngineTokens   int     `json:"engine_prompt_tokens"`
	RealizedCached int     `json:"realized_cached_tokens"`
	TTFTMillis     float64 `json:"ttft_ms"`
	Status         int     `json:"status"`
	Error          string  `json:"error,omitempty"`
	SentUnixNanos  int64   `json:"sent_unix_nanos"`
	DoneUnixNanos  int64   `json:"done_unix_nanos"`
	// RenderedTokens and MMFeatures are what the token producer handed the routers for a chat row, so parity can be checked on content and not only on counts.
	RenderedTokens     []uint32 `json:"rendered_tokens,omitempty"`
	MMFeatures         any      `json:"mm_features,omitempty"`
	PredictedUnixNanos int64    `json:"predicted_unix_nanos"`
	// TapSeq is the last event sequence each pod had published when the prediction was taken.
	TapSeq map[string]uint64 `json:"tap_seq_at_prediction"`
	// RouterMetrics are the router's KV-event and index counters when the prediction was taken.
	RouterMetrics map[string]float64 `json:"router_metrics"`
}

// tap records every event batch a pod publishes, independently of the producers.
type tap struct {
	mu      sync.Mutex
	enc     *json.Encoder
	lastSeq map[string]uint64
	lastAt  map[string]time.Time
	count   map[string]int
}

type tapEvent struct {
	Type        string   `json:"type"`
	BlockSize   int      `json:"block_size,omitempty"`
	BlockHashes []uint64 `json:"block_hashes,omitempty"`
	ParentHash  uint64   `json:"parent_hash,omitempty"`
	Tokens      []uint32 `json:"tokens,omitempty"`
	ExtraKeys   [][]any  `json:"extra_keys,omitempty"`
	GroupIdx    *int     `json:"group_idx,omitempty"`
	Kind        string   `json:"kind,omitempty"`
	Medium      string   `json:"medium,omitempty"`
}

type tapLine struct {
	UnixNanos int64      `json:"unix_nanos"`
	Pod       string     `json:"pod"`
	Topic     string     `json:"topic"`
	Seq       uint64     `json:"seq"`
	Payload   string     `json:"payload_b64"`
	Events    []tapEvent `json:"events"`
	Error     string     `json:"decode_error,omitempty"`
}

func summarize(ev kvevents.GenericEvent) tapEvent {
	switch e := ev.(type) {
	case *kvevents.BlockStoredEvent:
		return tapEvent{Type: "BlockStored", BlockSize: e.BlockSize, BlockHashes: e.BlockHashes, ParentHash: e.ParentHash,
			Tokens: e.Tokens, ExtraKeys: e.ExtraKeys, GroupIdx: e.GroupIdx, Kind: string(e.KVCacheSpecKind), Medium: e.DeviceTier}
	case *kvevents.BlockRemovedEvent:
		return tapEvent{Type: "BlockRemoved", BlockHashes: e.BlockHashes, GroupIdx: e.GroupIdx, Medium: e.DeviceTier}
	case *kvevents.AllBlocksClearedEvent:
		return tapEvent{Type: "AllBlocksCleared"}
	default:
		return tapEvent{Type: fmt.Sprintf("%T", ev)}
	}
}

func (t *tap) run(ctx context.Context, p pod, topicFilter string) error {
	adapter, err := engineadapter.NewAdapter("vllm")
	if err != nil {
		return err
	}
	sub := zmq4.NewSub(ctx)
	if err := sub.Dial("tcp://" + net.JoinHostPort(p.Addr, strconv.Itoa(p.ZMQPort))); err != nil {
		return fmt.Errorf("tap %s: %w", p.Name, err)
	}
	if err := sub.SetOption(zmq4.OptionSubscribe, topicFilter); err != nil {
		return err
	}
	go func() {
		defer sub.Close()
		for {
			msg, err := sub.Recv()
			if err != nil {
				return
			}
			line := tapLine{UnixNanos: time.Now().UnixNano(), Pod: p.Name}
			if len(msg.Frames) != 3 || len(msg.Frames[1]) < 8 {
				line.Error = fmt.Sprintf("malformed frame: %d frames", len(msg.Frames))
			} else {
				line.Topic, line.Seq = string(msg.Frames[0]), binary.BigEndian.Uint64(msg.Frames[1])
				line.Payload = base64.StdEncoding.EncodeToString(msg.Frames[2])
				_, _, batch, err := adapter.ParseMessage(&kvevents.RawMessage{Topic: line.Topic, Sequence: line.Seq,
					Payload: msg.Frames[2], SourceEndpoint: net.JoinHostPort(p.Addr, strconv.Itoa(p.HTTPPort))})
				if err != nil {
					line.Error = err.Error()
				}
				for _, ev := range batch.Events {
					line.Events = append(line.Events, summarize(ev))
				}
			}
			t.mu.Lock()
			_ = t.enc.Encode(line)
			t.lastSeq[p.Name] = line.Seq
			t.lastAt[p.Name] = time.Now()
			t.count[p.Name]++
			t.mu.Unlock()
		}
	}()
	return nil
}

// settle waits until no pod has published for quiet, or max has passed, and reports which.
// The producers read the same sockets as the tap, so a quiet tap means the batches they are still processing are the ones already received; grace covers that processing.
func (t *tap) settle(quiet, grace, max time.Duration) bool {
	deadline := time.Now().Add(max)
	for time.Now().Before(deadline) {
		t.mu.Lock()
		latest := time.Time{}
		for _, at := range t.lastAt {
			if at.After(latest) {
				latest = at
			}
		}
		t.mu.Unlock()
		if time.Since(latest) >= quiet {
			time.Sleep(grace)
			return true
		}
		time.Sleep(quiet / 4)
	}
	return false
}

func (t *tap) seqs() map[string]uint64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make(map[string]uint64, len(t.lastSeq))
	for k, v := range t.lastSeq {
		out[k] = v
	}
	return out
}

// routerMetrics flattens the router's KV-event and index counters, which its pool registers with controller-runtime's registry.
// Both producers share these collectors, so a counter here is the sum over both routers' pools.
func routerMetrics() map[string]float64 {
	out := map[string]float64{}
	families, err := ctrlmetrics.Registry.Gather()
	if err != nil {
		out["gather_error"] = 1
		return out
	}
	for _, mf := range families {
		name := mf.GetName()
		if !strings.Contains(name, "kv_cache_events") && !strings.Contains(name, "kv_cache_index") {
			continue
		}
		for _, m := range mf.GetMetric() {
			var labels []string
			for _, l := range m.GetLabel() {
				labels = append(labels, l.GetName()+"="+l.GetValue())
			}
			key := name + "{" + strings.Join(labels, ",") + "}"
			switch mf.GetType() {
			case dto.MetricType_COUNTER:
				out[key] = m.GetCounter().GetValue()
			case dto.MetricType_GAUGE:
				out[key] = m.GetGauge().GetValue()
			}
		}
	}
	return out
}

// pngDataURL draws a seeded noise image, so each chat case has its own image and its own multimodal hash.
func pngDataURL(seed uint64, side int) (string, error) {
	rng := rand.New(rand.NewPCG(seed, ^seed))
	img := image.NewRGBA(image.Rect(0, 0, side, side))
	for y := range side {
		for x := range side {
			img.Set(x, y, color.RGBA{uint8(rng.IntN(256)), uint8(rng.IntN(256)), uint8(rng.IntN(256)), 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(buf.Bytes()), nil
}

// imageSide gives Qwen2-VL 24x24 patches of 14 pixels, which its 2x2 merge turns into 144 image tokens, if the processor does not resize it.
const imageSide = 336

// body builds the request a step sends, the same bytes the router parses and the replica serves.
func body(s Step, model string) (path string, raw []byte, err error) {
	m := map[string]any{
		"model":          model,
		"max_tokens":     s.MaxTokens,
		"temperature":    0,
		"stream":         true,
		"stream_options": map[string]any{"include_usage": true},
	}
	if s.Salt != "" {
		m["cache_salt"] = s.Salt
	}
	if s.ReportFull {
		// vLLM reads this from SamplingParams.extra_args and then reports reused prefix blocks as BlockStored events.
		m["vllm_xargs"] = map[string]any{"kv_cache_report_mode": "full"}
	}
	switch s.Kind {
	case "completion":
		path = "/v1/completions"
		m["prompt"] = s.Tokens
	case "chat":
		path = "/v1/chat/completions"
		url, err := pngDataURL(s.ImageSeed, imageSide)
		if err != nil {
			return "", nil, err
		}
		m["messages"] = []any{
			map[string]any{"role": "system", "content": "You are a careful assistant."},
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "image_url", "image_url": map[string]any{"url": url}},
				map[string]any{"type": "text", "text": s.ChatText + "\n" + s.Question},
			}},
		}
	default:
		return "", nil, fmt.Errorf("step %s has unknown kind %q", s.ID, s.Kind)
	}
	raw, err = json.Marshal(m)
	return path, raw, err
}

// usage is the part of vLLM's final stream chunk the record keeps.
type usage struct {
	PromptTokens        int `json:"prompt_tokens"`
	PromptTokensDetails *struct {
		CachedTokens *int `json:"cached_tokens"`
	} `json:"prompt_tokens_details"`
}

// send streams one request and returns vLLM's usage and the time to the first generated text.
func send(ctx context.Context, client *http.Client, url string, raw []byte, rec *record) {
	rec.EngineTokens, rec.RealizedCached = -1, -1
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		rec.addError("send", err.Error())
		return
	}
	req.Header.Set("Content-Type", "application/json")
	start := time.Now()
	rec.SentUnixNanos = start.UnixNano()
	resp, err := client.Do(req)
	if err != nil {
		rec.addError("send", err.Error())
		return
	}
	defer resp.Body.Close()
	rec.Status = resp.StatusCode
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		rec.addError("send", strings.TrimSpace(string(b)))
		return
	}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		line := sc.Text()
		data, ok := strings.CutPrefix(line, "data: ")
		if !ok || data == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Text  string `json:"text"`
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
			Usage *usage `json:"usage"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		// The first chunk that carries generated text marks the first token; a role-only chat chunk does not.
		if rec.TTFTMillis == 0 && len(chunk.Choices) > 0 && (chunk.Choices[0].Text != "" || chunk.Choices[0].Delta.Content != "") {
			rec.TTFTMillis = float64(time.Since(start).Microseconds()) / 1000
		}
		if chunk.Usage != nil {
			rec.EngineTokens = chunk.Usage.PromptTokens
			if d := chunk.Usage.PromptTokensDetails; d != nil && d.CachedTokens != nil {
				rec.RealizedCached = *d.CachedTokens
			}
		}
	}
	if err := sc.Err(); err != nil {
		rec.addError("send", err.Error())
	}
	rec.DoneUnixNanos = time.Now().UnixNano()
}

type options struct {
	pods        []pod
	model       string
	renderURL   string
	out         string
	seed        uint64
	reps        int
	flood       int
	blockSizes  []int
	topicFilter string
	quiet       time.Duration
	grace       time.Duration
	maxSettle   time.Duration
	subscribeS  time.Duration
	only        string
}

func parseSizes(s string) ([]int, error) {
	var out []int
	for _, f := range strings.Split(s, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(f))
		if err != nil || n <= 0 {
			return nil, fmt.Errorf("block size %q is not a positive integer", f)
		}
		out = append(out, n)
	}
	return out, nil
}

// newRouter builds one producer as the EPP's plugin factory would, with only the block size set.
func newRouter(ctx context.Context, bs int, topicFilter string, zmqPort int) (*router, error) {
	idx, err := kvcache.NewDefaultConfig()
	if err != nil {
		return nil, err
	}
	ev := kvevents.DefaultConfig()
	ev.TopicFilter = topicFilter
	ev.PodDiscoveryConfig.SocketPort = zmqPort
	name := fmt.Sprintf("precise-r%d", bs)
	p, err := preciseprefixcache.New(ctx, name, preciseprefixcache.PluginConfig{
		TokenProcessorConfig: &kvblock.TokenProcessorConfig{BlockSizeTokens: bs},
		IndexerConfig:        idx,
		KVEventsConfig:       ev,
	})
	if err != nil {
		return nil, err
	}
	return &router{name: fmt.Sprintf("r%d", bs), blockSize: bs, producer: p}, nil
}

func run(ctx context.Context, o options, logw io.Writer) error {
	if err := os.MkdirAll(o.out, 0o755); err != nil {
		return err
	}
	kvmetrics.Register()
	// Each pod gets its own port only in the offline test, where both pods share one host.
	// The producers dial SocketPort for every pod, so the pods there must differ by address and share the port.
	for _, p := range o.pods[1:] {
		if p.ZMQPort != o.pods[0].ZMQPort {
			return errors.New("every pod must publish on the same ZMQ port, as the producers dial one SocketPort")
		}
	}

	evf, err := os.Create(filepath.Join(o.out, "events.jsonl"))
	if err != nil {
		return err
	}
	defer evf.Close()
	t := &tap{enc: json.NewEncoder(evf), lastSeq: map[string]uint64{}, lastAt: map[string]time.Time{}, count: map[string]int{}}
	for _, p := range o.pods {
		if err := t.run(ctx, p, o.topicFilter); err != nil {
			return err
		}
	}

	var routers []*router
	for _, bs := range o.blockSizes {
		r, err := newRouter(ctx, bs, o.topicFilter, o.pods[0].ZMQPort)
		if err != nil {
			return fmt.Errorf("router r%d: %w", bs, err)
		}
		for _, p := range o.pods {
			ep := fwkdl.NewEndpoint(p.metadata(), &fwkdl.Metrics{})
			if err := r.producer.Extract(ctx, fwkdl.EndpointEvent{Type: fwkdl.EventAddOrUpdate, Endpoint: ep}); err != nil {
				return fmt.Errorf("router r%d subscribe %s: %w", bs, p.Name, err)
			}
		}
		routers = append(routers, r)
	}
	handle := plugin.NewEppHandle(ctx, nil)
	tokCfg, _ := json.Marshal(map[string]any{"backend": "vllm", "modelName": o.model, "vllm": map[string]any{"url": o.renderURL, "timeout": "30s"}})
	tp, err := tokenizer.PluginFactory("token-producer", json.NewDecoder(bytes.NewReader(tokCfg)), handle)
	if err != nil {
		return fmt.Errorf("token producer: %w", err)
	}
	tokens := tp.(*tokenizer.Plugin)
	parser := openai.NewOpenAIParser()

	// ZMQ subscriptions take effect asynchronously, so events published before they do are lost to the router.
	// The plan's first request comes only after this wait.
	time.Sleep(o.subscribeS)
	meta := map[string]any{"type": "meta", "model": o.model, "seed": o.seed, "reps": o.reps, "flood": o.flood,
		"block_sizes": o.blockSizes, "pods": o.pods, "render_url": o.renderURL, "started_unix_nanos": time.Now().UnixNano(),
		// The counters are process-wide, so the verdict reads end minus start and not the end alone.
		"router_metrics_start": routerMetrics()}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, d := range bi.Deps {
			if d.Path == "github.com/llm-d/llm-d-router" {
				meta["router_module"] = d.Version
			}
		}
	}
	for _, r := range routers {
		state, _ := r.producer.DumpState()
		meta["state_"+r.name] = state
	}
	mf, err := os.Create(filepath.Join(o.out, "meta.json"))
	if err != nil {
		return err
	}
	_ = json.NewEncoder(mf).Encode(meta)
	mf.Close()

	rf, err := os.Create(filepath.Join(o.out, "requests.jsonl"))
	if err != nil {
		return err
	}
	defer rf.Close()
	renc := json.NewEncoder(rf)
	client := &http.Client{Timeout: 120 * time.Second}
	byName := map[string]pod{}
	for _, p := range o.pods {
		byName[p.Name] = p
	}

	plan := BuildPlan(o.seed, o.reps, o.flood)
	for _, s := range plan {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if o.only != "" && s.Hyp != o.only {
			continue
		}
		target, ok := byName[s.Pod]
		if !ok {
			return fmt.Errorf("step %s names pod %q, which is not configured", s.ID, s.Pod)
		}
		rec := record{Step: s, Tokens: s.Tokens, Predictions: map[string]map[string]prediction{}}
		rec.Step.Tokens = nil
		// A flood row is never measured, and the row after the flood settles before its own prediction.
		// Skipping the wait between flood rows keeps a flood of hundreds of prompts inside the probe's bound.
		if s.Phase != "flood" && !t.settle(o.quiet, o.grace, o.maxSettle) {
			rec.addError("settle", "events did not settle before the prediction")
		}
		rec.TapSeq = t.seqs()
		rec.RouterMetrics = routerMetrics()
		path, raw, err := body(s, o.model)
		if err != nil {
			return err
		}
		if err := predict(ctx, parser, tokens, routers, o.pods, s, path, raw, o.model, &rec); err != nil {
			rec.addError("predict", err.Error())
		}
		if s.NoSend {
			rec.EngineTokens, rec.RealizedCached = -1, -1
		} else {
			send(ctx, client, target.base()+path, raw, &rec)
		}
		if err := renc.Encode(rec); err != nil {
			return err
		}
		fmt.Fprintf(logw, "%s pod=%s router_tokens=%d engine_tokens=%d realized=%d predicted=%s ttft_ms=%.1f status=%d %s\n",
			s.ID, s.Pod, rec.RouterTokens, rec.EngineTokens, rec.RealizedCached, brief(rec.Predictions, s.Pod), rec.TTFTMillis, rec.Status, rec.Error)
	}
	t.settle(o.quiet, o.grace, o.maxSettle)
	end := map[string]any{"type": "end", "router_metrics": routerMetrics(), "tap_counts": t.count, "ended_unix_nanos": time.Now().UnixNano()}
	for _, r := range routers {
		state, _ := r.producer.DumpState()
		end["state_"+r.name] = state
	}
	ef, err := os.Create(filepath.Join(o.out, "end.json"))
	if err != nil {
		return err
	}
	defer ef.Close()
	return json.NewEncoder(ef).Encode(end)
}

// addError keeps every failure of a row, each named by the stage it came from, so a later stage cannot hide an earlier one.
func (r *record) addError(stage, msg string) {
	if r.Error != "" {
		r.Error += "; "
	}
	r.Error += stage + ": " + msg
}

func brief(p map[string]map[string]prediction, pod string) string {
	var names []string
	for r := range p {
		names = append(names, r)
	}
	sort.Strings(names)
	var parts []string
	for _, r := range names {
		parts = append(parts, fmt.Sprintf("%s:%d", r, p[r][pod].CachedTokens))
	}
	return strings.Join(parts, ",")
}

// predict runs the token producer once, then every router's producer, on fresh endpoints, and reads each endpoint's match.
func predict(ctx context.Context, parser *openai.OpenAIParser, tokens *tokenizer.Plugin, routers []*router, pods []pod,
	s Step, path string, raw []byte, model string, rec *record,
) error {
	headers := map[string]string{":path": path, "content-type": "application/json"}
	parsed, err := parser.ParseRequest(ctx, raw, headers)
	if err != nil {
		return fmt.Errorf("parse: %w", err)
	}
	req := &scheduling.InferenceRequest{RequestID: s.ID, TargetModel: model, Body: parsed.Body, Headers: headers, RequestSizeBytes: len(raw)}
	if err := tokens.Produce(ctx, req, nil); err != nil {
		return fmt.Errorf("tokenize: %w", err)
	}
	if req.Body.TokenizedRequest == nil {
		return errors.New("the token producer left no tokens")
	}
	rec.RouterTokens = req.Body.TokenizedRequest.TokenCount()
	rec.PredictedUnixNanos = time.Now().UnixNano()
	if s.Kind == "chat" && len(req.Body.TokenizedRequest.Prompts) > 0 {
		rec.RenderedTokens = req.Body.TokenizedRequest.Prompts[0].TokenIDs
		rec.MMFeatures = req.Body.TokenizedRequest.Prompts[0].MultiModalFeatures
	}
	for _, r := range routers {
		eps := make([]scheduling.Endpoint, len(pods))
		for i, p := range pods {
			eps[i] = scheduling.NewEndpoint(p.metadata(), &fwkdl.Metrics{}, nil)
		}
		if err := r.producer.Produce(ctx, req, eps); err != nil {
			return fmt.Errorf("%s produce: %w", r.name, err)
		}
		dk := attrprefix.PrefixCacheMatchInfoDataKey.WithNonEmptyProducerName(r.producer.TypedName().Name)
		per := map[string]prediction{}
		for i, p := range pods {
			pr := prediction{}
			if v, ok := eps[i].Get(dk); ok {
				if info, ok := v.(*attrprefix.PrefixCacheMatchInfo); ok {
					// These are the producer's own conversions: predictedCachedTokens and gpuCachedTokens in its prerequest.go.
					pr = prediction{Found: true, MatchBlocks: info.MatchBlocks(), TotalBlocks: info.TotalBlocks(), BlockSize: info.BlockSizeTokens(),
						CachedTokens: info.CachedBlockCount() * info.BlockSizeTokens(),
						GPUTokens:    info.CachedBlocksByTier()[kvcache.GPUTier] * info.BlockSizeTokens()}
				}
			}
			per[p.Name] = pr
		}
		rec.Predictions[r.name] = per
	}
	return nil
}

func main() {
	var o options
	var pods, sizes string
	var httpPort, zmqPort int
	flag.StringVar(&pods, "pods", "", "name=addr,... or name=addr:http:zmq,...")
	flag.IntVar(&httpPort, "http-port", 8000, "replica HTTP port")
	flag.IntVar(&zmqPort, "zmq-port", 5557, "replica KV-event port")
	flag.StringVar(&o.model, "model", "", "served model name")
	flag.StringVar(&o.renderURL, "render-url", "", "vLLM base URL the token producer renders chat requests with")
	flag.StringVar(&o.out, "out", "", "output directory")
	flag.Uint64Var(&o.seed, "seed", 20261119, "plan seed")
	flag.IntVar(&o.reps, "reps", 2, "repetitions of each case")
	flag.IntVar(&o.flood, "flood", 24, "flood prompts per dedup repetition")
	flag.StringVar(&sizes, "router-block-sizes", "16,64", "one producer per router block size")
	flag.StringVar(&o.topicFilter, "topic-filter", "kv@", "ZMQ topic filter")
	flag.DurationVar(&o.quiet, "quiet", 400*time.Millisecond, "event silence that counts as settled")
	flag.DurationVar(&o.grace, "grace", 200*time.Millisecond, "processing grace after the silence")
	flag.DurationVar(&o.maxSettle, "max-settle", 5*time.Second, "longest wait for events to settle")
	flag.DurationVar(&o.subscribeS, "subscribe-wait", 3*time.Second, "wait for subscriptions before the first request")
	flag.StringVar(&o.only, "only", "", "run only this hypothesis's steps")
	printPlan := flag.Bool("print-plan", false, "print the plan as JSON lines and exit")
	flag.Parse()
	if *printPlan {
		enc := json.NewEncoder(os.Stdout)
		for _, s := range BuildPlan(o.seed, o.reps, o.flood) {
			_ = enc.Encode(s)
		}
		return
	}
	var err error
	if o.pods, err = parsePods(pods, httpPort, zmqPort); err == nil {
		o.blockSizes, err = parseSizes(sizes)
	}
	if err == nil && (o.model == "" || o.out == "" || o.renderURL == "") {
		err = errors.New("-model, -out and -render-url are required")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "probe:", err)
		os.Exit(2)
	}
	if err := run(context.Background(), o, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "probe:", err)
		os.Exit(1)
	}
}

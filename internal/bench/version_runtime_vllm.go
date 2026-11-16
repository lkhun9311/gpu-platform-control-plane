package bench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
)

// The identity fields a vLLM engine's own responses do not carry.
// A reader that cannot observe one leaves it empty and names it in RuntimeIdentity.Unproven; it never copies the registered value in.
const (
	// UnprovenImage: neither /server_info nor /version names the image digest the process was started from.
	UnprovenImage = "image"
	// UnprovenChatTemplate: --chat-template is a server argument, not part of the engine configuration /server_info dumps, and no response hashes the template.
	UnprovenChatTemplate = "chatTemplate"
	// UnprovenProfileArgs: the responses carry the resolved configuration, not the command line, so an unreviewed flag whose effect is not among the mapped settings is invisible.
	UnprovenProfileArgs = "profileArgs"
)

// unprovenFields is every name Unproven may hold, in the order CheckObservedRuntime reports them.
var unprovenFields = []string{UnprovenImage, UnprovenChatTemplate, UnprovenProfileArgs}

// VLLMIdentityResponses are the two raw bodies a vLLM runtime identity is read from, kept verbatim as the evidence of what the engine said.
type VLLMIdentityResponses struct {
	// ServerInfo is `GET /server_info?config_format=json`, served only when the engine runs with VLLM_SERVER_DEV_MODE=1.
	ServerInfo json.RawMessage
	// Version is `GET /version`.
	Version json.RawMessage
}

// maxIdentityBody bounds each response; the captured /server_info bodies are about 30 KB, so this is generous and still stops a runaway stream.
const maxIdentityBody = 4 << 20

// FetchVLLMIdentity reads the two identity responses from a running vLLM engine at baseURL.
//
// Anything but 200 is an error, because a missing configuration cannot be replaced by the registration's values.
func FetchVLLMIdentity(ctx context.Context, client *http.Client, baseURL string) (VLLMIdentityResponses, error) {
	base := strings.TrimSuffix(baseURL, "/")
	si, err := getIdentityBody(ctx, client, base+"/server_info?config_format=json")
	if err != nil {
		var status statusError
		if errors.As(err, &status) && status.code == http.StatusNotFound {
			return VLLMIdentityResponses{}, fmt.Errorf("%w; the engine must run with VLLM_SERVER_DEV_MODE=1 (amendment 2026-11-16), since no other response carries its configuration", err)
		}
		return VLLMIdentityResponses{}, err
	}
	v, err := getIdentityBody(ctx, client, base+"/version")
	if err != nil {
		return VLLMIdentityResponses{}, err
	}
	return VLLMIdentityResponses{ServerInfo: si, Version: v}, nil
}

// statusError is a response that arrived with a status other than 200.
type statusError struct {
	url  string
	code int
}

func (e statusError) Error() string { return fmt.Sprintf("GET %s: HTTP %d", e.url, e.code) }

// getIdentityBody returns one 200 body, refusing one larger than maxIdentityBody rather than reading a truncated document.
func getIdentityBody(ctx context.Context, client *http.Client, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, statusError{url: url, code: resp.StatusCode}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxIdentityBody+1))
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	if len(body) > maxIdentityBody {
		return nil, fmt.Errorf("GET %s: body exceeds %d bytes", url, maxIdentityBody)
	}
	return body, nil
}

// vllmServerInfo is the part of /server_info the identity reads, with the key names the 2026-11-16 captures of v0.27.1 and v0.32.0 carry.
//
// Every field is a pointer so a missing or null key is told apart from a zero or false the registration might hold.
type vllmServerInfo struct {
	VLLMConfig *struct {
		ModelConfig *struct {
			Revision          *string `json:"revision"`
			TokenizerRevision *string `json:"tokenizer_revision"`
			Dtype             *string `json:"dtype"`
			MaxModelLen       *int    `json:"max_model_len"`
		} `json:"model_config"`
		SchedulerConfig *struct {
			MaxNumSeqs          *int    `json:"max_num_seqs"`
			MaxNumBatchedTokens *int    `json:"max_num_batched_tokens"`
			Policy              *string `json:"policy"`
			AsyncScheduling     *bool   `json:"async_scheduling"`
		} `json:"scheduler_config"`
		CacheConfig *struct {
			// The fraction is kept as the raw literal, because json.Number would also accept a quoted string and float64 would round it.
			GPUMemoryUtilization *json.RawMessage `json:"gpu_memory_utilization"`
			EnablePrefixCaching  *bool            `json:"enable_prefix_caching"`
		} `json:"cache_config"`
	} `json:"vllm_config"`
	SystemEnv *struct {
		VLLMVersion *string `json:"vllm_version"`
	} `json:"system_env"`
}

// releaseVersion is what /version reports for a release build; a dev or local build carries a suffix and is not the registered release.
var releaseVersion = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

// torchDtypeFlag maps the resolved torch dtype back to the --dtype spelling the registration uses.
//
// vLLM resolves both `half` and `float16` to torch.float16, so the resolved value cannot tell them apart and the registration's spelling is reported.
// Any other dtype is reported as the engine wrote it, so it differs from every registered value and is refused by the comparison.
var torchDtypeFlag = map[string]string{"torch.float16": "half"}

// ParseVLLMRuntime builds a RuntimeIdentity from a vLLM engine's /server_info?config_format=json and /version bodies.
//
// Each mapped key must be present, non-null and of its type, or the read fails.
// The image, the chat template and the command line are not in either response, so they stay empty and are named in Unproven.
func ParseVLLMRuntime(serverInfo, version []byte) (RuntimeIdentity, error) {
	var si vllmServerInfo
	if err := json.Unmarshal(serverInfo, &si); err != nil {
		return RuntimeIdentity{}, fmt.Errorf("/server_info: %w", err)
	}
	var v struct {
		Version *string `json:"version"`
	}
	if err := json.Unmarshal(version, &v); err != nil {
		return RuntimeIdentity{}, fmt.Errorf("/version: %w", err)
	}
	var missing []string
	need := func(present bool, key string) {
		if !present {
			missing = append(missing, key)
		}
	}
	need(v.Version != nil, "/version version")
	need(si.SystemEnv != nil && si.SystemEnv.VLLMVersion != nil, "system_env.vllm_version")
	c := si.VLLMConfig
	need(c != nil, "vllm_config")
	if c != nil {
		m, s, k := c.ModelConfig, c.SchedulerConfig, c.CacheConfig
		need(m != nil && m.Revision != nil, "model_config.revision")
		need(m != nil && m.TokenizerRevision != nil, "model_config.tokenizer_revision")
		need(m != nil && m.Dtype != nil, "model_config.dtype")
		need(m != nil && m.MaxModelLen != nil, "model_config.max_model_len")
		need(s != nil && s.MaxNumSeqs != nil, "scheduler_config.max_num_seqs")
		need(s != nil && s.MaxNumBatchedTokens != nil, "scheduler_config.max_num_batched_tokens")
		need(s != nil && s.Policy != nil, "scheduler_config.policy")
		need(s != nil && s.AsyncScheduling != nil, "scheduler_config.async_scheduling")
		need(k != nil && k.GPUMemoryUtilization != nil, "cache_config.gpu_memory_utilization")
		need(k != nil && k.EnablePrefixCaching != nil, "cache_config.enable_prefix_caching")
	}
	if len(missing) > 0 {
		return RuntimeIdentity{}, fmt.Errorf("the engine's responses lack %s", strings.Join(missing, ", "))
	}
	// Two independent reports of the release must agree, so neither is trusted alone.
	if *v.Version != *si.SystemEnv.VLLMVersion {
		return RuntimeIdentity{}, fmt.Errorf("/version reports %q, but /server_info's system_env reports %q", *v.Version, *si.SystemEnv.VLLMVersion)
	}
	if !releaseVersion.MatchString(*v.Version) {
		return RuntimeIdentity{}, fmt.Errorf("/version reports %q, which is not a release version", *v.Version)
	}
	// A quoted "0.9" is not a plain decimal literal, so a value of another type is refused here.
	if !isDecimal(string(*c.CacheConfig.GPUMemoryUtilization)) {
		return RuntimeIdentity{}, fmt.Errorf("cache_config.gpu_memory_utilization %q is not a plain decimal", *c.CacheConfig.GPUMemoryUtilization)
	}
	dtype := *c.ModelConfig.Dtype
	if flag, ok := torchDtypeFlag[dtype]; ok {
		dtype = flag
	}
	return RuntimeIdentity{
		// The registration names releases by their tag, which is the version with a leading v.
		VLLMVersion:       "v" + *v.Version,
		ModelRevision:     *c.ModelConfig.Revision,
		TokenizerRevision: *c.ModelConfig.TokenizerRevision,
		Unproven:          append([]string(nil), unprovenFields...),
		Settings: EngineSettings{
			Dtype:                dtype,
			MaxModelLen:          *c.ModelConfig.MaxModelLen,
			MaxNumSeqs:           *c.SchedulerConfig.MaxNumSeqs,
			MaxNumBatchedTokens:  *c.SchedulerConfig.MaxNumBatchedTokens,
			GPUMemoryUtilization: string(*c.CacheConfig.GPUMemoryUtilization),
			PrefixCaching:        new(*c.CacheConfig.EnablePrefixCaching),
			SchedulingPolicy:     *c.SchedulerConfig.Policy,
			AsyncScheduling:      new(*c.SchedulerConfig.AsyncScheduling),
		},
	}, nil
}

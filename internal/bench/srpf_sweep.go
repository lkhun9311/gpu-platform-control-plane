package bench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/engineargs"
)

// The SRPF threshold sweep: vLLM PR #58420 at its 2026-11-18 head, measured under fcfs, priority and its own SRPF at
// five aging thresholds, on one A10G with the admission diagnostic's frozen two-tenant load.
//
// Run 8 on 2026-11-17 measured the earlier head aae949c, whose aging rule was the literal "starvation > 5" scheduler
// steps; the PR's author then made the step count VLLM_SRPF_STARVATION_THRESHOLD (default 5) and asked for 2 or 3 and
// 8 or 10 beside it.
// The new head b8b0d36 has the same merge base, so the image is run 8's, and it changes only scheduler.py against it.
// The PR changes only vllm/v1/core/sched/scheduler.py inside the package (and adds a stray top-level script), so the
// build is vLLM CI's post-merge image of the PR's merge base with that one file mounted over the installed copy.
// SRPF is not a --scheduling-policy value at the merge base, whose SchedulerPolicy is Literal["fcfs", "priority"].
// The PR switches it on with VLLM_ENABLE_SRPF=1 under the fcfs policy and reads the threshold in Scheduler.__init__, so
// the SRPF arms set those two variables and nothing else, and the baselines set neither.
// The 384-token prefill threshold arms of run 8 are not repeated: none of the author's questions is about it.

const (
	// SRPFSweepImage is vLLM CI's post-merge image of the merge base, pinned by its manifest-list digest.
	// The digest is the linux/amd64 manifest under the tag of that commit, whose list is sha256:b8a326c6...86ab.
	// Its config labels name revision 5039f736e612ae637099eba3fa645031d416ef53, and it is CUDA 13.2.1, which driver 595 serves.
	SRPFSweepImage = "public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:bfb59377bd23ee1ac0a31ae8aa4836baaf7d840e6c1004906afbec1ffbf35467"
	// SRPFSweepBaseCommit is the PR's merge base on main, the commit the image was built from.
	SRPFSweepBaseCommit = "5039f736e612ae637099eba3fa645031d416ef53"
	// SRPFSweepPRCommit is the PR's head as force-pushed on 2026-11-18, still one commit on top of the merge base.
	// Against run 8's head aae949c it changes scheduler.py alone; the stray top-level script is the same blob 690e1de2.
	SRPFSweepPRCommit = "b8b0d3610dee138db57ba465897f4b7af74abbd5"
	// SRPFSweepBaseSchedulerSHA256 is scheduler.py at the merge base (git blob c6801611cb90), which the image must carry.
	SRPFSweepBaseSchedulerSHA256 = "b67848721847aa8f45cddee43cabdbb2f35205eb3b441e16d79823d30f3be097"
	// SRPFSweepPRSchedulerSHA256 is scheduler.py at the PR head (git blob be34356a5faa), the file mounted over it.
	// Run 8's, at aae949c, was 19502766a57a (git blob 87e31dcc425d).
	SRPFSweepPRSchedulerSHA256 = "2b39435388f0d716cb5a3f02b532f4225d1688153b483a67643af8c26389972a"
	// SRPFSweepEnableEnv is the variable the PR reads, in three places of scheduler.py, to switch SRPF on.
	SRPFSweepEnableEnv = "VLLM_ENABLE_SRPF"
	// SRPFSweepStarvationEnv is the variable Scheduler.__init__ reads, with int() and a default of "5", as the number of
	// scheduler steps after which a waiting request counts as starved.
	SRPFSweepStarvationEnv = "VLLM_SRPF_STARVATION_THRESHOLD"
	// SRPFSweepTraceSeed and SRPFSweepTraceChecksum name the diagnostic's frozen trace of block 3.
	// It is the block the 452 against 1,486 ms of the vLLM #57413 comment came from.
	SRPFSweepTraceSeed     = 853
	SRPFSweepTraceChecksum = "4360cb83f7c2259040c8ccda45b881a8b817a5087f968334630f26aa12d68167"
	// SRPFSweepOrderSeed fixes the arm order SRPFSweepOrder draws.
	SRPFSweepOrderSeed = 58420
	// SRPFSweepModel and SRPFSweepRevision are the earlier runs' model and snapshot.
	SRPFSweepModel    = "Qwen/Qwen2.5-3B-Instruct"
	SRPFSweepRevision = "aa8e72537993ba99e69dfaafa59ed015b17504d1"
	// SRPFSweepPriorities is what the earlier runs' gateway bound by tier, now sent by the client in every arm.
	// Under fcfs the queue ignores a request's priority, so every arm receives byte-identical request bodies.
	SRPFSweepPriorities = PremiumTenant + "=0," + NoisyTenant + "=1"
	// srpfSweepPycachePrefix moves every bytecode cache out of the image's tree.
	// A .pyc the image shipped for scheduler.py could otherwise be loaded in place of the mounted source.
	srpfSweepPycachePrefix = "/tmp/srpf-pycache"
	// srpfSyncCheckEnv is set to "error" by the CI image, which then checks every GPU sync on the serving path.
	// The release images the earlier runs used do not set it, so the engine is started with it removed.
	srpfSyncCheckEnv = "VLLM_GPU_SYNC_CHECK"
	// srpfChunkedPrefillLine is what vLLM's SchedulerConfig logs when chunked prefill is on at the registered budget.
	srpfChunkedPrefillLine = "Chunked prefill is enabled with max_num_batched_tokens=512."
)

// The sweep's step bounds.
//
// hack/vllm-58420-session.sh sizes the instance's hard stop from these, and its offline test holds the two equal.
const (
	// SRPFSweepPullBound bounds the image pull: the image is 10.9 GB compressed.
	// From ECR Public it took 913, 1,111 and 1,239 s on g5.xlarge, and twice ran past 1,500 s (2026-11-16 and 11-17).
	// In the second of those, 51 of 53 layers had downloaded and 34 were extracted when the bound cut it.
	// The sweep passes it to the readiness pull step as ReadinessRun.PullBound, and a test holds the two equal.
	SRPFSweepPullBound = 2400 * time.Second
	// SRPFSweepImageIdentityBound bounds the three identity containers run before the model download.
	// The first of them to import vllm runs right after the pull, on a cold page cache.
	// Run 4 on 2026-11-17 was still importing torch two minutes into the overlay probe when an earlier 180 s bound cut it.
	SRPFSweepImageIdentityBound = 600 * time.Second
	// SRPFSweepModelBound bounds the model download, which took 105 s on 2026-11-16 and ran past 300 s once.
	// The download is the readiness preflight's, which applies ReadinessModelBound; a test holds the two equal.
	SRPFSweepModelBound = 900 * time.Second
	// SRPFSweepReadyBound bounds one engine's start to /health 200, from before docker run.
	// Each arm starts on an empty compile cache, so every start is cold.
	// Run 8 on 2026-11-17 started this image six times cold on g5.xlarge, ready at 102-108 s and at 158 s for the first.
	// That run's 500 s bound, times seven arms, would put the session's worst case over $3, so it is 300 s, near twice the slowest.
	// An arm that overruns it is one failed arm, not a failed sweep.
	SRPFSweepReadyBound = 300 * time.Second
	// SRPFSweepArmIdentityBound bounds checking the running engine's arguments and the code it imports.
	SRPFSweepArmIdentityBound = 90 * time.Second
	// SRPFSweepCaptureBound bounds saving the ready engine's identity endpoints.
	// The capture is the readiness preflight's, which applies ReadinessCaptureBound; a test holds the two equal.
	SRPFSweepCaptureBound = 20 * time.Second
	// SRPFSweepWarmupBound bounds the two warm-up requests, each under the trace's 30 s timeout.
	SRPFSweepWarmupBound = 60 * time.Second
	// SRPFSweepIdleBound bounds waiting for the engine to report no running and no waiting request.
	SRPFSweepIdleBound = 30 * time.Second
	// SRPFSweepMetricsBound bounds one read of /metrics, taken before and after the replay.
	SRPFSweepMetricsBound = 10 * time.Second
	// SRPFSweepReplayBound bounds the replay: 420 s of schedule, the last request's 30 s timeout, and 30 s to finish the record.
	SRPFSweepReplayBound = 480 * time.Second
	// SRPFSweepStopBound bounds reading the engine's log and removing its container.
	// The stop is the readiness preflight's, which applies ReadinessStopBound; a test holds the two equal.
	SRPFSweepStopBound = 30 * time.Second
)

// SRPFSweepArmBound is the most one arm can take, the sum of its step bounds.
//
// The idle wait runs twice, before the replay and after it, and so does the metrics read.
const SRPFSweepArmBound = SRPFSweepReadyBound + SRPFSweepArmIdentityBound + SRPFSweepCaptureBound + SRPFSweepWarmupBound +
	2*SRPFSweepIdleBound + 2*SRPFSweepMetricsBound + SRPFSweepReplayBound + SRPFSweepStopBound

// SRPFSweepBound is the most the whole sweep can take on the instance, after the bring-up.
const SRPFSweepBound = SRPFSweepPullBound + SRPFSweepImageIdentityBound + SRPFSweepModelBound + srpfSweepArmCount*SRPFSweepArmBound

// srpfSweepArmCount is len(srpfSweepArms), as a constant so the bound above is one; a test holds the two equal.
const srpfSweepArmCount = 7

// SRPFArm is one arm: a scheduling policy, whether the prefill threshold is set, whether SRPF is switched on, and the
// SRPF aging threshold it runs with.
type SRPFArm struct {
	Name   string `json:"name"`
	Policy string `json:"policy"`
	// Threshold is the --long-prefill-token-threshold passed, 0 when the flag is left out.
	Threshold int  `json:"threshold"`
	SRPF      bool `json:"srpf"`
	// Starvation is the VLLM_SRPF_STARVATION_THRESHOLD an SRPF arm sets, and 0, the variable unset, for any other arm.
	// Every SRPF arm sets it, the default 5 included, so each one runs the PR's new read of it.
	Starvation int `json:"starvationThreshold"`
}

// srpfSweepArms are fcfs, the baseline the author compares the tail to, priority, the client-label reference the short
// p99 is compared to, and SRPF at the author's tighter (2, 3) and looser (8, 10) thresholds.
// srpf-s5 is the default, the same rule run 8's srpf arm ran, so it is the drift check against that run.
var srpfSweepArms = []SRPFArm{
	{Name: "fcfs", Policy: "fcfs"},
	{Name: "priority", Policy: "priority"},
	{Name: "srpf-s2", Policy: "fcfs", SRPF: true, Starvation: 2},
	{Name: "srpf-s3", Policy: "fcfs", SRPF: true, Starvation: 3},
	{Name: "srpf-s5", Policy: "fcfs", SRPF: true, Starvation: 5},
	{Name: "srpf-s8", Policy: "fcfs", SRPF: true, Starvation: 8},
	{Name: "srpf-s10", Policy: "fcfs", SRPF: true, Starvation: 10},
}

// SRPFSweepArms returns the seven arms in their canonical order, as a copy.
func SRPFSweepArms() []SRPFArm { return slices.Clone(srpfSweepArms) }

// SRPFSweepArmNames returns the arms' names in their canonical order.
func SRPFSweepArmNames() []string {
	names := make([]string, len(srpfSweepArms))
	for i, a := range srpfSweepArms {
		names[i] = a.Name
	}
	return names
}

// SRPFSweepOrder is the order the arms run in, counterbalanced and then drawn by the seed.
//
// The comparison is across thresholds, so a threshold that rose or fell with position on the instance would be
// confounded with whatever drifts over the session.
// The order is therefore drawn from the balanced ones (srpfBalanced), as the one whose sha256("<seed>/<arm>,<arm>,...")
// is least.
func SRPFSweepOrder(seed int64) []SRPFArm {
	var best []SRPFArm
	bestKey := ""
	for _, p := range permutations(SRPFSweepArms()) {
		if !srpfBalanced(p) {
			continue
		}
		names := make([]string, len(p))
		for i, a := range p {
			names[i] = a.Name
		}
		sum := sha256.Sum256(fmt.Appendf(nil, "%d/%s", seed, strings.Join(names, ",")))
		if key := hex.EncodeToString(sum[:]); best == nil || key < bestKey {
			best, bestKey = p, key
		}
	}
	return best
}

// srpfBalanced says the order keeps position from standing in for an arm's scheduler:
//   - fcfs and priority run in opposite halves, with an SRPF arm in the middle, so neither baseline holds both ends;
//   - the SRPF thresholds' Spearman correlation with their positions is within ±0.2, so no trend in time reads as one in threshold;
//   - no two thresholds next to each other on the ladder run back to back, so a neighbouring pair shares no stretch of the session.
func srpfBalanced(order []SRPFArm) bool {
	n := len(order)
	half := func(name string) int {
		i := slices.IndexFunc(order, func(a SRPFArm) bool { return a.Name == name })
		switch {
		case i < 0 || i == n/2:
			return 0
		case i < n/2:
			return -1
		}
		return 1
	}
	if f, p := half("fcfs"), half("priority"); f == 0 || p == 0 || f == p {
		return false
	}
	ladder := []int{}
	for _, a := range order {
		if a.SRPF {
			ladder = append(ladder, a.Starvation)
		}
	}
	rank := slices.Sorted(slices.Values(ladder))
	rankOf := func(v int) int { return slices.Index(rank, v) }
	// With m distinct ranks, rho = 1 - 6*S/(m^3-m) for S the sum of squared rank differences, so |rho| <= 0.2 is
	// 0.8*(m^3-m) <= 6*S <= 1.2*(m^3-m), kept in integers as 8*(m^3-m) <= 60*S <= 12*(m^3-m).
	m := len(ladder)
	s := 0
	for pos, v := range ladder {
		d := rankOf(v) - pos
		s += d * d
	}
	if span := m*m*m - m; m < 2 || 60*s < 8*span || 60*s > 12*span {
		return false
	}
	for i := 1; i < n; i++ {
		if order[i].SRPF && order[i-1].SRPF {
			if d := rankOf(order[i].Starvation) - rankOf(order[i-1].Starvation); d == 1 || d == -1 {
				return false
			}
		}
	}
	return true
}

// permutations returns every ordering of arms, each a fresh slice.
func permutations(arms []SRPFArm) [][]SRPFArm {
	if len(arms) <= 1 {
		return [][]SRPFArm{slices.Clone(arms)}
	}
	var out [][]SRPFArm
	for i := range arms {
		rest := slices.Concat(arms[:i:i], arms[i+1:])
		for _, p := range permutations(rest) {
			out = append(out, append([]SRPFArm{arms[i]}, p...))
		}
	}
	return out
}

// srpfSweepProfile is the earlier runs' engine profile with the arm's policy in place of theirs, and async scheduling off.
//
// The v0.27.1 row is the profile the hold-cap runs were rendered from, so the only flags that differ are the arm's.
func srpfSweepProfile(a SRPFArm) ([]string, error) {
	rel, ok := engineargs.Releases()[platformv1.VLLMReleaseV0271]
	if !ok {
		return nil, errors.New("the v0.27.1 engine profile is not registered")
	}
	i := slices.Index(rel.Args, "--scheduling-policy=priority")
	if i < 0 {
		return nil, errors.New("the v0.27.1 engine profile no longer sets --scheduling-policy=priority")
	}
	args := slices.Clone(rel.Args)
	args[i] = "--scheduling-policy=" + a.Policy
	return append(args, rel.AsyncOff), nil
}

// SRPFSweepPriorityMap is SRPFSweepPriorities as the sender takes it, for the warm-up.
func SRPFSweepPriorityMap() map[string]int { return map[string]int{PremiumTenant: 0, NoisyTenant: 1} }

// SRPFSweep runs the six arms on one instance.
type SRPFSweep struct {
	// Docker runs the docker CLI.
	Docker CommandRunner
	// Exec runs the harness itself with args, so each replay is the replay subcommand every earlier run used.
	Exec CommandRunner
	// Self is the path of the harness binary Exec runs.
	Self string
	// HFCache holds the model, downloaded once; CompileRoot holds one fresh compile cache per arm.
	HFCache, CompileRoot string
	// Overlay is the PR's scheduler.py on the host, mounted read-only over the image's.
	Overlay string
	// Trace and ArchivedManifest are the diagnostic's committed trace-off-3.jsonl and manifest-off-3.yaml.
	Trace, ArchivedManifest string
	// Out is the directory every record is written to; it must be empty.
	Out string
	// Port is what the engine publishes on loopback, and EngineURL is where it answers.
	Port      int32
	EngineURL string
	Health    *http.Client
	Logs      func(ctx context.Context, containerID string) ([]byte, error)
	PollEvery time.Duration
	// StateEvery is how often the container's state is read while /health fails.
	StateEvery time.Duration
	// NewSender gives the warm-up a sender of its own.
	NewSender func(url string) (*HTTPSender, error)
	// NewToken makes the containers' attempt tokens; nil uses random ones.
	NewToken func() string
}

// SRPFImageIdentity is what the image was checked to be before any arm ran.
type SRPFImageIdentity struct {
	Image string `json:"image"`
	// SchedulerPath is where the image installs the scheduler, and so where the overlay is mounted.
	SchedulerPath string `json:"schedulerPath"`
	// InstalledSHA256 is that file as the image ships it, which must be the merge base's.
	InstalledSHA256 string `json:"installedSHA256"`
	// OverlaidSHA256 is the file Python imported with the overlay mounted, which must be the PR head's.
	OverlaidSHA256 string `json:"overlaidSHA256"`
	OverlaidFile   string `json:"overlaidFile"`
	// VLLMVersion is `vllm --version` as printed, recorded and not judged.
	VLLMVersion string `json:"vllmVersion"`
	// Probes are the identity containers' outputs, verbatim.
	Probes []string `json:"probes"`
}

// SRPFSweepSummary is the sweep's result, written last.
type SRPFSweepSummary struct {
	Study     string            `json:"study"`
	OrderSeed int64             `json:"orderSeed"`
	Order     []string          `json:"order"`
	Image     SRPFImageIdentity `json:"image"`
	Pull      StepRecord        `json:"pull"`
	Model     StepRecord        `json:"modelDownload"`
	Arms      []SRPFArmResult   `json:"arms"`
}

// SRPFArmResult is one arm's record, written when its container is gone.
type SRPFArmResult struct {
	SRPFArm
	Position int `json:"position"`
	// Outcome is "measured" when the replay ran to a complete record and "failed" otherwise; Reason says why.
	Outcome     string    `json:"outcome"`
	Reason      string    `json:"reason,omitempty"`
	ContainerID string    `json:"containerID,omitempty"`
	RunArgs     []string  `json:"runArgs,omitempty"`
	DockerRunAt time.Time `json:"dockerRunAt"`
	// HealthSeconds is the first /health 200 from before docker run, absent when none came.
	HealthSeconds *float64 `json:"healthSeconds,omitempty"`
	// NonDefaultArgs is the engine's own "non-default args" log line, which must show the arm's policy and threshold.
	NonDefaultArgs string `json:"nonDefaultArgs,omitempty"`
	// CodeProbe is the running container's own report of the scheduler it imports and the SRPF variable it sees.
	CodeProbe string `json:"codeProbe,omitempty"`
	// EngineCoreEnv names each engine core, the process it inherited from, and the SRPF variables that process carried.
	EngineCoreEnv string          `json:"engineCoreEnv,omitempty"`
	Capture       []CaptureRecord `json:"capture"`
	Warmup        []RawRow        `json:"warmup"`
	// ReplayError is the replay subcommand's failure, empty when it exited 0.
	ReplayError string `json:"replayError,omitempty"`
	// MetricsError is why the engine's counters could not be read after the replay, kept beside a replay failure.
	MetricsError string `json:"metricsError,omitempty"`
	RawFile      string `json:"rawFile,omitempty"`
	// Preemptions is the engine's preemption counter after the replay minus before it, absent when it was not read.
	Preemptions      *float64     `json:"preemptions,omitempty"`
	PreemptionMetric string       `json:"preemptionMetric,omitempty"`
	Figures          *SRPFFigures `json:"figures,omitempty"`
	FiguresError     string       `json:"figuresError,omitempty"`
	LogFile          string       `json:"logFile,omitempty"`
	LogError         string       `json:"logError,omitempty"`
}

// Quantile is a nearest-rank quantile in milliseconds, or infinite when it falls on a failed request.
type Quantile struct {
	Ms       *float64 `json:"ms,omitempty"`
	Infinite bool     `json:"infinite,omitempty"`
}

// String prints the quantile, "+Inf" for an infinite one.
func (q Quantile) String() string {
	switch {
	case q.Infinite:
		return "+Inf"
	case q.Ms == nil:
		return "absent"
	}
	return strconv.FormatFloat(*q.Ms, 'f', 1, 64)
}

// TenantFigures is one tenant's counts in a replay.
type TenantFigures struct {
	Rows      int `json:"rows"`
	Completed int `json:"completed"`
	Failed    int `json:"failed"`
	// FailedBy counts the failed rows by the first rule each broke.
	FailedBy map[string]int `json:"failedBy"`
}

// SRPFFigures are an arm's reported figures, every latency measured from the request's scheduled send time.
type SRPFFigures struct {
	Premium   TenantFigures `json:"premium"`
	Contender TenantFigures `json:"contender"`
	// PremiumTTFT is first content, client-observed, with a failed request at +Inf.
	PremiumTTFTP50 Quantile `json:"premiumTTFTP50"`
	PremiumTTFTP99 Quantile `json:"premiumTTFTP99"`
	// ContenderE2E is the last content frame, client-observed, with a failed request at +Inf.
	ContenderE2EP50 Quantile `json:"contenderE2EP50"`
	ContenderE2EP95 Quantile `json:"contenderE2EP95"`
	// MaxDispatchLagMs is the latest any request left the client after its scheduled time.
	MaxDispatchLagMs float64 `json:"maxDispatchLagMs"`
	// InputTokenMismatches counts rows whose engine-reported prompt length is not the trace's frozen count.
	// The earlier runs' engine rendered 68 and 7,695 tokens, and a newer chat template could send a different prompt.
	InputTokenMismatches int `json:"inputTokenMismatches"`
}

// srpfFailure names the first success rule a row broke, or "" for a completed row.
//
// The rule is the hold-cap scorer's, with the engine's token count in place of frames, as the study's contract says.
func srpfFailure(r RawRow, want int) string {
	switch {
	case r.HTTPStatus == 0 && r.ErrorKind != "":
		return r.ErrorKind
	case r.HTTPStatus == 0:
		return "no-response"
	case r.HTTPStatus != http.StatusOK:
		return "http-" + strconv.Itoa(r.HTTPStatus)
	case r.ErrorKind != "":
		return r.ErrorKind
	case r.StreamError != "":
		return "stream-error"
	case !r.StreamTerminated:
		return "unterminated"
	case r.EngineUsageReported == nil || !*r.EngineUsageReported:
		return "no-usage"
	case r.EngineOutputTokens != want:
		return "output-tokens"
	case r.Clock == nil || r.Clock.FirstContentNanos == nil || r.Clock.LastContentNanos == nil:
		return "no-content"
	}
	return ""
}

// SRPFSweepFigures scores one replay's raw rows against the trace they replayed.
//
// It refuses rows that are not the trace's, one per index with the same tenant and offset, or that carry no clock.
// A figure from a partial or mismatched record would be a plausible wrong number.
func SRPFSweepFigures(arm string, trace []TraceRow, rows []RawRow) (*SRPFFigures, error) {
	if len(rows) != len(trace) {
		return nil, fmt.Errorf("%d rows for a trace of %d", len(rows), len(trace))
	}
	byIndex := make(map[int]RawRow, len(rows))
	for _, r := range rows {
		if _, dup := byIndex[r.Index]; dup {
			return nil, fmt.Errorf("index %d appears twice", r.Index)
		}
		byIndex[r.Index] = r
	}
	f := &SRPFFigures{
		Premium:   TenantFigures{FailedBy: map[string]int{}},
		Contender: TenantFigures{FailedBy: map[string]int{}},
	}
	var ttft, e2e []float64
	lag := math.Inf(-1)
	for _, tr := range trace {
		r, ok := byIndex[tr.Index]
		if !ok {
			return nil, fmt.Errorf("no row for trace index %d", tr.Index)
		}
		// A file of another arm or study scored under this arm's name would be contamination no figure shows.
		if r.Study != StudySRPF58420Threshold || r.Arm != arm {
			return nil, fmt.Errorf("row %d is study %q arm %q, not %s arm %s", tr.Index, r.Study, r.Arm, StudySRPF58420Threshold, arm)
		}
		if r.TraceChecksum != SRPFSweepTraceChecksum {
			return nil, fmt.Errorf("row %d replayed trace %q, not %s", tr.Index, r.TraceChecksum, SRPFSweepTraceChecksum)
		}
		if r.Tenant != tr.Tenant || r.ScheduledOffsetMs != tr.OffsetMs {
			return nil, fmt.Errorf("row %d is %s at %d ms, and the trace has %s at %d ms", tr.Index, r.Tenant, r.ScheduledOffsetMs, tr.Tenant, tr.OffsetMs)
		}
		if r.Clock == nil || r.Clock.IntendedNanos == nil {
			return nil, fmt.Errorf("row %d carries no scheduled time on its clock", tr.Index)
		}
		// Replay schedules each request at its trace offset from the origin, so any other intended time is not this trace's schedule.
		if *r.Clock.IntendedNanos != tr.OffsetMs*int64(time.Millisecond) {
			return nil, fmt.Errorf("row %d was scheduled at %d ns, and the trace offset is %d ms", tr.Index, *r.Clock.IntendedNanos, tr.OffsetMs)
		}
		if sent, ok := r.Clock.FromIntended(r.Clock.SendNanos); ok {
			lag = max(lag, nanosToMs(sent))
		}
		// A row that reports usage reports its prompt length too, so a zero there is a mismatch and not a missing value.
		if r.EngineUsageReported != nil && *r.EngineUsageReported && r.EngineInputTokens != tr.ExactInputTokens {
			f.InputTokenMismatches++
		}
		var t *TenantFigures
		switch tr.Tenant {
		case PremiumTenant:
			t = &f.Premium
		case NoisyTenant:
			t = &f.Contender
		default:
			return nil, fmt.Errorf("row %d belongs to tenant %q, which this load does not have", tr.Index, tr.Tenant)
		}
		t.Rows++
		why := srpfFailure(r, tr.MaxOutputTokens)
		if why != "" {
			t.Failed++
			t.FailedBy[why]++
		} else {
			t.Completed++
		}
		switch tr.Tenant {
		case PremiumTenant:
			ttft = append(ttft, srpfLatency(r, why, r.Clock.FirstContentNanos))
		case NoisyTenant:
			e2e = append(e2e, srpfLatency(r, why, r.Clock.LastContentNanos))
		}
	}
	if len(ttft) == 0 || len(e2e) == 0 {
		return nil, errors.New("the record holds no premium or no contender request")
	}
	if math.IsInf(lag, -1) {
		return nil, errors.New("no request carries a send time")
	}
	f.MaxDispatchLagMs = lag
	slices.Sort(ttft)
	slices.Sort(e2e)
	f.PremiumTTFTP50, f.PremiumTTFTP99 = quantileOf(ttft, 0.50), quantileOf(ttft, 0.99)
	f.ContenderE2EP50, f.ContenderE2EP95 = quantileOf(e2e, 0.50), quantileOf(e2e, 0.95)
	return f, nil
}

// srpfLatency is an event's time from the request's schedule in milliseconds, +Inf for a failed request.
func srpfLatency(r RawRow, why string, event *int64) float64 {
	if why != "" {
		return math.Inf(1)
	}
	n, ok := r.Clock.FromIntended(event)
	if !ok {
		return math.Inf(1)
	}
	return nanosToMs(n)
}

// quantileOf is the nearest-rank q-quantile of sorted, which may end in +Inf.
func quantileOf(sorted []float64, q float64) Quantile {
	v := percentile(sorted, q)
	if math.IsInf(v, 1) {
		return Quantile{Infinite: true}
	}
	return Quantile{Ms: &v}
}

// PromSum sums every sample of the metric name in a Prometheus text exposition, labels or not.
//
// It reports false when no sample of that name is present, so an absent counter is never read as zero.
func PromSum(text, name string) (float64, bool) {
	var sum float64
	found := false
	for line := range strings.Lines(text) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !strings.HasPrefix(line, name) {
			continue
		}
		rest := line[len(name):]
		if rest == "" || (rest[0] != '{' && rest[0] != ' ') {
			continue
		}
		fields := strings.Fields(rest[strings.LastIndex(rest, "}")+1:])
		if len(fields) == 0 {
			continue
		}
		v, err := strconv.ParseFloat(fields[0], 64)
		if err != nil {
			continue
		}
		sum += v
		found = true
	}
	return sum, found
}

// srpfPreemptionMetrics are the names vLLM's preemption counter is exposed under, the counter's own first.
var srpfPreemptionMetrics = []string{"vllm:num_preemptions_total", "vllm:num_preemptions"}

// PreemptionDelta is the preemption counter's growth between two expositions, under the first name both carry.
func PreemptionDelta(before, after string) (float64, string, error) {
	for _, name := range srpfPreemptionMetrics {
		b, okB := PromSum(before, name)
		a, okA := PromSum(after, name)
		if okB && okA {
			if a < b {
				return 0, name, fmt.Errorf("%s fell from %g to %g, so the engine was not the same process", name, b, a)
			}
			return a - b, name, nil
		}
	}
	return 0, "", fmt.Errorf("neither exposition carries %s", strings.Join(srpfPreemptionMetrics, " or "))
}

// srpfNonDefaultArgsRefusal checks the engine's own "non-default args" line against the arm.
//
// fcfs is vLLM's default, so an fcfs arm is one whose line names no other policy.
func srpfNonDefaultArgsRefusal(a SRPFArm, line string) error {
	if line == "" {
		return errors.New("the engine logged no non-default args line")
	}
	for _, p := range []string{"fcfs", "priority"} {
		named := strings.Contains(line, "'scheduling_policy': '"+p+"'")
		switch {
		case p == a.Policy && p != "fcfs" && !named:
			return fmt.Errorf("the engine's args do not name policy %s: %s", p, line)
		case p != a.Policy && named:
			return fmt.Errorf("the engine runs policy %s, not %s: %s", p, a.Policy, line)
		}
	}
	threshold := strings.Contains(line, "'long_prefill_token_threshold':")
	want := fmt.Sprintf("'long_prefill_token_threshold': %d", a.Threshold)
	switch {
	case a.Threshold == 0 && threshold:
		return fmt.Errorf("the engine has a prefill threshold the arm does not set: %s", line)
	case a.Threshold != 0 && !strings.Contains(line, want+",") && !strings.Contains(line, want+"}"):
		return fmt.Errorf("the engine's args do not carry %s: %s", want, line)
	}
	return nil
}

// srpfCodeProbe is run inside a container: it reports what the processes already running there loaded and inherited,
// then imports the scheduler itself and reports the file and its sha256.
//
// The bytecode the server wrote under the prefix records the size of the source it compiled, which tells the PR's
// scheduler from the merge base's, so it shows what the server imported rather than what a later import would.
// It is read before this probe's own import, which would otherwise write it.
// Every other process's environment is read from /proc, so the SRPF variable is shown to have reached the engine core.
const srpfCodeProbe = `import hashlib, importlib.util, json, os
src = os.path.join(os.path.dirname(importlib.util.find_spec("vllm").origin), "v1", "core", "sched", "scheduler.py")
pyc = importlib.util.cache_from_source(src)
head = open(pyc, "rb").read(16) if os.path.exists(pyc) else b""
procs = []
for pid in os.listdir("/proc"):
    if not pid.isdigit() or int(pid) == os.getpid():
        continue
    try:
        cmd = open("/proc/%s/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
        env = dict(kv.split("=", 1) for kv in open("/proc/%s/environ" % pid, "rb").read().decode(errors="replace").split("\0") if "=" in kv)
        ppid = int(open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        continue
    procs.append({"pid": int(pid), "ppid": ppid, "cmd": cmd[:160], "envCount": len(env), "env": env.get("` + SRPFSweepEnableEnv + `"), "starvation": env.get("` + SRPFSweepStarvationEnv + `"), "pycachePrefix": env.get("PYTHONPYCACHEPREFIX"), "syncCheck": env.get("` + srpfSyncCheckEnv + `")})
import vllm.v1.core.sched.scheduler as s
data = open(s.__file__, "rb").read()
print(json.dumps({"file": s.__file__, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
  "srpfKey": hasattr(s.Scheduler, "_get_srpf_key_for_req"), "env": os.environ.get("` + SRPFSweepEnableEnv + `"),
  "starvation": os.environ.get("` + SRPFSweepStarvationEnv + `"),
  "pycachePrefix": os.environ.get("PYTHONPYCACHEPREFIX"), "pyc": pyc,
  "pycFlags": int.from_bytes(head[4:8], "little") if len(head) == 16 else None,
  "pycSourceSize": int.from_bytes(head[12:16], "little") if len(head) == 16 else None, "procs": procs}))`

// srpfProbe is the code probe's answer.
type srpfProbe struct {
	File          string  `json:"file"`
	SHA256        string  `json:"sha256"`
	Size          int64   `json:"size"`
	SRPFKey       bool    `json:"srpfKey"`
	Env           *string `json:"env"`
	Starvation    *string `json:"starvation"`
	PycachePrefix *string `json:"pycachePrefix"`
	Pyc           string  `json:"pyc"`
	// PycFlags and PycSourceSize are the header of the bytecode found under the prefix before the probe imported anything.
	PycFlags      *int64          `json:"pycFlags"`
	PycSourceSize *int64          `json:"pycSourceSize"`
	Procs         []srpfProbeProc `json:"procs"`
}

// srpfProbeProc is one other process in the container and what it inherited.
type srpfProbeProc struct {
	PID  int `json:"pid"`
	PPID int `json:"ppid"`
	// EnvCount is how many variables /proc showed; zero means the environment could not be read, not that it is empty.
	EnvCount      int     `json:"envCount"`
	Cmd           string  `json:"cmd"`
	Env           *string `json:"env"`
	Starvation    *string `json:"starvation"`
	PycachePrefix *string `json:"pycachePrefix"`
	SyncCheck     *string `json:"syncCheck"`
}

// srpfProbeRefusal checks a code probe against what the arm must run: the PR's scheduler, and SRPF on, at the arm's
// aging threshold, exactly when the arm says.
//
// serving says a server is running in the container, whose bytecode and processes must then show the same.
func srpfProbeRefusal(a SRPFArm, path string, serving bool, out []byte) error {
	_, err := srpfProbeCheck(a, path, serving, out)
	return err
}

// srpfProbeCheck is srpfProbeRefusal that also says, for a serving probe, which process vouched for each engine core's
// environment and what that process carried.
func srpfProbeCheck(a SRPFArm, path string, serving bool, out []byte) (string, error) {
	var p srpfProbe
	if err := json.Unmarshal(lastLine(out), &p); err != nil {
		return "", fmt.Errorf("the code probe's answer is not JSON: %w: %q", err, out)
	}
	wantStarvation := strconv.Itoa(a.Starvation)
	envRefusal := func(who string, env, starvation, prefix *string) error {
		switch {
		case prefix == nil || *prefix != srpfSweepPycachePrefix:
			return fmt.Errorf("%s has PYTHONPYCACHEPREFIX %s, not %s", who, show(prefix), srpfSweepPycachePrefix)
		case a.SRPF && (env == nil || *env != "1"):
			return fmt.Errorf("arm %s needs %s=1 and %s has %s", a.Name, SRPFSweepEnableEnv, who, show(env))
		case !a.SRPF && env != nil:
			return fmt.Errorf("arm %s must not set %s and %s has %s", a.Name, SRPFSweepEnableEnv, who, show(env))
		// The value is compared as the string the arm set, so "05" or " 5", which int() would also read as 5, is still refused.
		case a.SRPF && (starvation == nil || *starvation != wantStarvation):
			return fmt.Errorf("arm %s needs %s=%s and %s has %s", a.Name, SRPFSweepStarvationEnv, wantStarvation, who, show(starvation))
		case !a.SRPF && starvation != nil:
			return fmt.Errorf("arm %s must not set %s and %s has %s", a.Name, SRPFSweepStarvationEnv, who, show(starvation))
		}
		return nil
	}
	switch {
	case p.File != path:
		return "", fmt.Errorf("the scheduler imported is %s, not the overlaid %s", p.File, path)
	case p.SHA256 != SRPFSweepPRSchedulerSHA256:
		return "", fmt.Errorf("the scheduler imported hashes to %s, not the PR head's %s", p.SHA256, SRPFSweepPRSchedulerSHA256)
	case !p.SRPFKey:
		return "", errors.New("the scheduler imported has no _get_srpf_key_for_req")
	}
	if err := envRefusal("the probe", p.Env, p.Starvation, p.PycachePrefix); err != nil {
		return "", err
	}
	if !serving {
		return "", nil
	}
	switch {
	case p.PycFlags == nil || p.PycSourceSize == nil:
		return "", fmt.Errorf("no server process wrote bytecode for the scheduler at %s, so what it imported is not shown", p.Pyc)
	case *p.PycFlags != 0 || *p.PycSourceSize != p.Size:
		return "", fmt.Errorf("the server compiled a scheduler of %d bytes (pyc flags %d), and the PR head's is %d", *p.PycSourceSize, *p.PycFlags, p.Size)
	case len(p.Procs) == 0:
		return "", errors.New("the probe found no server process in the container")
	}
	byPID := make(map[int]srpfProbeProc, len(p.Procs))
	for _, pr := range p.Procs {
		byPID[pr.PID] = pr
	}
	for _, pr := range p.Procs {
		who := fmt.Sprintf("process %d (%s)", pr.PID, pr.Cmd)
		// vLLM renames its engine core with setproctitle, which overwrites the memory /proc reads the environment from.
		// The overwrite can be partial: on 2026-11-17 the engine core showed 30 entries with none of the variables its
		// parent passed, while a spawn child given the same title locally kept them in os.environ and showed none in /proc.
		// So a renamed process's /proc environment is not read at all, whatever it holds.
		// It inherited its environment from its parent at spawn, so its nearest readable ancestor is checked instead.
		if pr.EnvCount == 0 || srpfRenamed(pr) {
			if _, ok := readableAncestor(byPID, pr); !ok {
				return "", fmt.Errorf("%s shows no environment and no ancestor whose environment can be read", who)
			}
			continue
		}
		if err := envRefusal(who, pr.Env, pr.Starvation, pr.PycachePrefix); err != nil {
			return "", err
		}
		if pr.SyncCheck != nil {
			return "", fmt.Errorf("%s runs with %s=%s, the CI image's debug check, which a release image does not set", who, srpfSyncCheckEnv, *pr.SyncCheck)
		}
	}
	// The scheduler, and its read of both variables, runs in the engine core, so an arm is measured only once the
	// process that spawned each engine core is shown to have carried the arm's values.
	var proof []string
	for _, pr := range p.Procs {
		if !strings.HasPrefix(pr.Cmd, srpfEngineCoreTitle) {
			continue
		}
		parent, ok := readableAncestor(byPID, pr)
		if !ok {
			return "", fmt.Errorf("engine core %d has no ancestor whose environment can be read", pr.PID)
		}
		who := fmt.Sprintf("engine core %d's ancestor %d (%s)", pr.PID, parent.PID, parent.Cmd)
		if err := envRefusal(who, parent.Env, parent.Starvation, parent.PycachePrefix); err != nil {
			return "", err
		}
		proof = append(proof, fmt.Sprintf("%s %d inherits from %d: %s=%s %s=%s", pr.Cmd, pr.PID, parent.PID,
			SRPFSweepEnableEnv, show(parent.Env), SRPFSweepStarvationEnv, show(parent.Starvation)))
	}
	if len(proof) == 0 {
		return "", fmt.Errorf("the probe found no %s process, so the arm's variables are not shown to reach the scheduler", srpfEngineCoreTitle)
	}
	return strings.Join(proof, "; "), nil
}

// srpfEngineCoreTitle is the title vLLM gives the process that runs the scheduler.
const srpfEngineCoreTitle = "VLLM::EngineCore"

// srpfRenamed reports a process vLLM retitled, whose /proc environment setproctitle has overwritten.
// vLLM titles its processes "VLLM::<role>", and an untitled process's command line starts with its executable.
func srpfRenamed(pr srpfProbeProc) bool {
	return strings.HasPrefix(pr.Cmd, "VLLM::")
}

// readableAncestor walks a process's parents to the nearest one whose environment /proc can be trusted: one that
// showed variables and was not retitled.
// Every such process is checked in its own right, so finding one is enough.
// A retitled ancestor is passed over even when /proc showed it variables, since what it showed may be the title's overwrite.
func readableAncestor(byPID map[int]srpfProbeProc, pr srpfProbeProc) (srpfProbeProc, bool) {
	for range len(byPID) {
		parent, ok := byPID[pr.PPID]
		if !ok {
			return srpfProbeProc{}, false
		}
		if parent.EnvCount > 0 && !srpfRenamed(parent) {
			return parent, true
		}
		pr = parent
	}
	return srpfProbeProc{}, false
}

// show prints an optional string, "unset" when absent.
func show(v *string) string {
	if v == nil {
		return "unset"
	}
	return strconv.Quote(*v)
}

// lastLine is the last non-empty line of out, where a probe prints its answer after any warning.
func lastLine(out []byte) []byte {
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	return []byte(strings.TrimSpace(lines[len(lines)-1]))
}

// RunArgs is the `docker run` argument list for one arm's engine.
//
// Every arm gets the same image, overlay, dev mode and bytecode prefix; the arm's policy, threshold and SRPF variable are
// its only differences, and its compile cache is its own and empty so no arm starts warmer than another.
func (s *SRPFSweep) RunArgs(a SRPFArm, schedulerPath string) ([]string, error) {
	profile, err := srpfSweepProfile(a)
	if err != nil {
		return nil, err
	}
	command := engineargs.Command(profile, engineargs.Deployment{
		Model: SRPFSweepModel, Port: s.Port, ServedName: SRPFSweepModel, Revision: SRPFSweepRevision,
		HoldCap: a.Threshold == engineargs.HoldCapPrefillThreshold,
	})
	if a.Threshold != 0 && a.Threshold != engineargs.HoldCapPrefillThreshold {
		return nil, fmt.Errorf("arm %s sets threshold %d, and only %d was measured", a.Name, a.Threshold, engineargs.HoldCapPrefillThreshold)
	}
	// An SRPF arm left on the default would not show the variable reached the engine, and a baseline that set it would
	// differ from the other baseline by more than its policy.
	if a.SRPF != (a.Starvation > 0) {
		return nil, fmt.Errorf("arm %s has SRPF %t and starvation threshold %d; an SRPF arm sets a positive one and no other arm sets one", a.Name, a.SRPF, a.Starvation)
	}
	args := []string{
		"run", "--detach",
		"--name=srpf-" + a.Name,
		"--gpus=all",
		"--shm-size=1g",
		"--workdir=/",
		"--env=" + DevModeEnv,
		"--env=PYTHONPYCACHEPREFIX=" + srpfSweepPycachePrefix,
	}
	if a.SRPF {
		args = append(args, "--env="+SRPFSweepEnableEnv+"=1", "--env="+SRPFSweepStarvationEnv+"="+strconv.Itoa(a.Starvation))
	}
	args = append(args,
		fmt.Sprintf("--publish=127.0.0.1:%d:%d", s.Port, s.Port),
		"--volume="+s.HFCache+":/root/.cache/huggingface",
		"--volume="+filepath.Join(s.CompileRoot, a.Name)+":/root/.cache/vllm",
		"--volume="+s.Overlay+":"+schedulerPath+":ro",
		"--label=study=srpf-sweep",
		// An empty value is refused by vLLM's own check of the variable, so env removes it before vllm starts.
		"--entrypoint=env",
		SRPFSweepImage,
		"-u", srpfSyncCheckEnv, "vllm", "serve",
	)
	return append(args, command...), nil
}

// readiness is a ReadinessRun carrying only what its pull, download, health, capture and stop steps read, so the sweep
// runs those steps exactly as the readiness preflight does.
func (s *SRPFSweep) readiness() *ReadinessRun {
	return &ReadinessRun{
		Study:  StudySRPF58420Threshold,
		Design: VersionStudyDesign{Model: SRPFSweepModel, ModelRevision: SRPFSweepRevision},
		Engine: &DockerEngine{
			Run: s.Docker, HFCache: s.HFCache, CompileCacheRoot: s.CompileRoot,
			ServedName: SRPFSweepModel, Port: s.Port, NamePrefix: "srpf", NewToken: s.NewToken,
		},
		EngineURL: s.EngineURL, Health: s.Health, Logs: s.Logs, Out: s.Out,
		PollEvery: s.PollEvery, StateEvery: s.StateEvery, PullBound: SRPFSweepPullBound,
	}
}

// refuse checks, before anything is pulled, every input the sweep's numbers depend on.
func (s *SRPFSweep) refuse() error {
	if s.Docker == nil || s.Exec == nil || s.Self == "" || s.Health == nil || s.Logs == nil || s.NewSender == nil ||
		s.PollEvery <= 0 || s.StateEvery <= 0 || s.Port <= 0 || s.EngineURL == "" {
		return errors.New("the sweep is missing its runner, harness, health client, log reader, sender, port or poll intervals")
	}
	for _, p := range []string{s.HFCache, s.CompileRoot, s.Overlay, s.Out, s.Trace, s.ArchivedManifest} {
		// Docker reads a bare name as a named volume, so a relative path would be checked in one place and mounted from another.
		if !filepath.IsAbs(p) {
			return fmt.Errorf("path %q is not absolute", p)
		}
	}
	if err := emptyOrAbsent(s.Out, false); err != nil {
		return fmt.Errorf("out directory: %w", err)
	}
	if err := emptyOrAbsent(s.CompileRoot, true); err != nil {
		return fmt.Errorf("compile cache: %w", err)
	}
	if err := emptyOrAbsent(s.HFCache, true); err != nil {
		return fmt.Errorf("model cache: %w", err)
	}
	// Every arm's manifest is derived here, before the pull, so an archived manifest of another block costs nothing.
	archived, err := os.ReadFile(s.ArchivedManifest)
	if err != nil {
		return err
	}
	for _, name := range SRPFSweepArmNames() {
		if _, err := ArmManifest(archived, name, s.Trace, s.EngineURL); err != nil {
			return fmt.Errorf("archived manifest %s: %w", s.ArchivedManifest, err)
		}
	}
	if sum, err := ChecksumFile(s.Overlay); err != nil || sum != SRPFSweepPRSchedulerSHA256 {
		return fmt.Errorf("the overlay %s hashes to %q (%v), not the PR head's scheduler %s", s.Overlay, sum, err, SRPFSweepPRSchedulerSHA256)
	}
	if sum, err := ChecksumFile(s.Trace); err != nil || sum != SRPFSweepTraceChecksum {
		return fmt.Errorf("the trace %s hashes to %q (%v), not seed %d's %s", s.Trace, sum, err, SRPFSweepTraceSeed, SRPFSweepTraceChecksum)
	}
	return nil
}

// ArmManifest derives one arm's replay manifest from the diagnostic's archived one, as derive_manifest.py did for the
// hold-cap product runs.
//
// The load is kept as archived; the study, arm, trace path and target are this sweep's, and the gateway's provenance,
// which named a gateway this sweep does not have, is dropped.
func ArmManifest(archived []byte, arm, tracePath, engineURL string) (RunManifest, error) {
	m, err := decodeManifest(archived)
	if err != nil {
		return RunManifest{}, err
	}
	switch {
	case m.Study != StudyAdmissionDiagnostic || m.Arm != "off":
		return RunManifest{}, fmt.Errorf("the archived manifest is study %s arm %s, not the diagnostic's off", m.Study, m.Arm)
	case m.Seed != SRPFSweepTraceSeed || m.TraceChecksum != SRPFSweepTraceChecksum:
		return RunManifest{}, fmt.Errorf("the archived manifest is seed %d with trace %s, not seed %d's %s", m.Seed, m.TraceChecksum, SRPFSweepTraceSeed, SRPFSweepTraceChecksum)
	case !slices.Contains(SRPFSweepArmNames(), arm):
		return RunManifest{}, fmt.Errorf("arm %q is not one of %v", arm, SRPFSweepArmNames())
	}
	m.Study, m.Arm, m.TracePath, m.GatewayURL = StudySRPF58420Threshold, arm, tracePath, engineURL
	m.GatewaySHA, m.GatewayBase, m.GatewayBinarySHA256 = "", "", ""
	m.ImageDigests = map[string]string{"engine": SRPFSweepImage}
	return *m, nil
}

// Run pulls the image, checks what it runs, downloads the model, and runs every arm in the seed's order.
//
// A failed arm is an outcome and the sweep goes on; a pull, identity or download failure, a write error, or a container
// that cannot be removed ends it, because every arm after would be unmeasured or contaminated.
func (s *SRPFSweep) Run(ctx context.Context) (SRPFSweepSummary, error) {
	sum := SRPFSweepSummary{Study: StudySRPF58420Threshold, OrderSeed: SRPFSweepOrderSeed, Arms: []SRPFArmResult{}}
	order := SRPFSweepOrder(SRPFSweepOrderSeed)
	for _, a := range order {
		sum.Order = append(sum.Order, a.Name)
	}
	if err := s.refuse(); err != nil {
		return sum, err
	}
	return s.run(ctx, sum, order)
}

// run is Run after its refusals, kept apart so the tests can drive the whole sweep without the PR's scheduler on disk.
func (s *SRPFSweep) run(ctx context.Context, sum SRPFSweepSummary, order []SRPFArm) (SRPFSweepSummary, error) {
	r := s.readiness()
	archived, err := os.ReadFile(s.ArchivedManifest)
	if err != nil {
		return sum, err
	}
	trace, err := ReadTraceFileVerified(s.Trace, SRPFSweepTraceChecksum)
	if err != nil {
		return sum, err
	}
	if err := s.writeJSON("order.json", map[string]any{"seed": SRPFSweepOrderSeed, "order": sum.Order}); err != nil {
		return sum, err
	}

	sum.Pull, err = r.pull(ctx, SRPFSweepImage)
	if wErr := s.writeJSON("pull.json", sum.Pull); wErr != nil || err != nil {
		return sum, errors.Join(err, wErr)
	}
	sum.Image, err = s.imageIdentity(ctx)
	if wErr := s.writeJSON("image-identity.json", sum.Image); wErr != nil || err != nil {
		return sum, errors.Join(err, wErr)
	}
	sum.Model, err = r.downloadModel(ctx, SRPFSweepImage)
	if wErr := s.writeJSON("model-download.json", sum.Model); wErr != nil || err != nil {
		return sum, errors.Join(err, wErr)
	}
	for i, a := range order {
		res, err := s.arm(ctx, r, a, i+1, sum.Image.SchedulerPath, archived, trace)
		sum.Arms = append(sum.Arms, res)
		if wErr := s.writeJSON("arm-"+a.Name+".json", res); wErr != nil || err != nil {
			return sum, errors.Join(err, wErr)
		}
	}
	return sum, s.writeJSON("summary.json", sum)
}

// srpfLocateProbe reports, without importing vLLM, where the image installs the scheduler and what it hashes to.
const srpfLocateProbe = `import hashlib, importlib.util, json, os
p = os.path.join(os.path.dirname(importlib.util.find_spec("vllm").origin), "v1", "core", "sched", "scheduler.py")
print(json.dumps({"file": p, "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()}))`

// imageIdentity checks the pulled image before the model is downloaded: it ships the merge base's scheduler, and Python
// imports the PR's once the overlay is mounted.
// It also records `vllm --version`.
func (s *SRPFSweep) imageIdentity(ctx context.Context) (SRPFImageIdentity, error) {
	id := SRPFImageIdentity{Image: SRPFSweepImage, Probes: []string{}}
	ictx, cancel := context.WithTimeout(ctx, SRPFSweepImageIdentityBound)
	defer cancel()
	out, err := s.probe(ictx, "locate", []string{"--entrypoint=python3", SRPFSweepImage, "-c", srpfLocateProbe})
	id.Probes = append(id.Probes, string(out))
	if err != nil {
		return id, fmt.Errorf("locate the scheduler: %w", err)
	}
	var loc srpfProbe
	if err := json.Unmarshal(lastLine(out), &loc); err != nil {
		return id, fmt.Errorf("the locate probe's answer is not JSON: %w: %q", err, out)
	}
	id.SchedulerPath, id.InstalledSHA256 = loc.File, loc.SHA256
	switch {
	case !filepath.IsAbs(loc.File) || !strings.HasSuffix(loc.File, "/vllm/v1/core/sched/scheduler.py"):
		return id, fmt.Errorf("the image's scheduler is at %q, which is not an installed vllm package's", loc.File)
	case loc.SHA256 != SRPFSweepBaseSchedulerSHA256:
		return id, fmt.Errorf("the image's scheduler hashes to %s, not the merge base's %s, so the overlay would not make the PR head", loc.SHA256, SRPFSweepBaseSchedulerSHA256)
	}
	out, err = s.probe(ictx, "overlay", []string{
		"--env=PYTHONPYCACHEPREFIX=" + srpfSweepPycachePrefix, "--volume=" + s.Overlay + ":" + loc.File + ":ro",
		"--entrypoint=python3", SRPFSweepImage, "-c", srpfCodeProbe,
	})
	id.Probes = append(id.Probes, string(out))
	if err != nil {
		return id, fmt.Errorf("import the overlaid scheduler: %w", err)
	}
	if err := srpfProbeRefusal(SRPFArm{Name: "image"}, loc.File, false, out); err != nil {
		return id, err
	}
	var ov srpfProbe
	_ = json.Unmarshal(lastLine(out), &ov)
	id.OverlaidFile, id.OverlaidSHA256 = ov.File, ov.SHA256
	// The version comes from the package metadata, which imports no torch.
	// On 2026-11-16 `vllm --version` printed its version and then did not exit within the identity bound, ending a paid run.
	vctx, vcancel := context.WithTimeout(ictx, srpfVersionProbeBound)
	defer vcancel()
	out, runErr, cleanupErr := s.probeParts(vctx, "version", []string{"--entrypoint=python3", SRPFSweepImage, "-c", srpfVersionProbe})
	id.Probes = append(id.Probes, string(out))
	if cleanupErr != nil {
		return id, fmt.Errorf("version probe: %w", errors.Join(runErr, cleanupErr))
	}
	// The version is recorded and not judged: the digest already fixes the image, and the scheduler hash its code.
	// A local version part spelt another way than "+g5039f736e" would otherwise end a paid run over a string, and so
	// would a probe that could not read it.
	if runErr != nil {
		id.VLLMVersion = "unread: " + runErr.Error()
		return id, nil
	}
	id.VLLMVersion = strings.TrimSpace(string(lastLine(out)))
	return id, nil
}

// srpfVersionProbe prints the installed vllm distribution's version from its metadata, without importing vllm.
const srpfVersionProbe = `import importlib.metadata as m; print(m.version("vllm"))`

// srpfVersionProbeBound bounds the version probe on its own, so a slow one cannot spend the scheduler checks' time.
const srpfVersionProbeBound = 30 * time.Second

// probe runs one short-lived identity container, named per attempt so a timed-out probe is removed and no other.
func (s *SRPFSweep) probe(ctx context.Context, what string, args []string) ([]byte, error) {
	out, runErr, cleanupErr := s.probeParts(ctx, what, args)
	if runErr != nil || cleanupErr != nil {
		return out, errors.Join(runErr, cleanupErr)
	}
	return out, nil
}

// probeParts is probe with the container's own failure kept apart from a failure to remove it.
// Only the second makes later arms unsafe, since a container left behind would share the GPU.
func (s *SRPFSweep) probeParts(ctx context.Context, what string, args []string) (out []byte, runErr, cleanupErr error) {
	name := "srpf-probe-" + what + "-" + s.readiness().Engine.token()
	full := append([]string{"run", "--rm", "--name=" + name, "--gpus=all", "--workdir=/"}, args...)
	out, runErr = s.Docker(ctx, "docker", full...)
	if runErr != nil {
		cleanupErr = s.readiness().removeContainer(name)
	}
	return out, runErr, cleanupErr
}

// arm runs one arm from docker run to its container's removal.
//
// The returned error is only for what makes later arms unsafe: a container that could not be removed, or a record that
// could not be written.
// Everything else is the arm's outcome.
func (s *SRPFSweep) arm(ctx context.Context, r *ReadinessRun, a SRPFArm, position int, schedulerPath string, archived []byte, trace []TraceRow) (SRPFArmResult, error) {
	res := SRPFArmResult{SRPFArm: a, Position: position, Outcome: "failed", Capture: []CaptureRecord{}, Warmup: []RawRow{}}
	args, err := s.RunArgs(a, schedulerPath)
	if err != nil {
		res.Reason = err.Error()
		return res, err
	}
	t0 := time.Now()
	res.DockerRunAt = t0.UTC()
	// The readiness bound runs from before docker run, so the container's creation is inside it.
	rctx, cancel := context.WithDeadline(ctx, t0.Add(SRPFSweepReadyBound))
	defer cancel()
	token := r.Engine.token()
	image := slices.Index(args, SRPFSweepImage)
	args = slices.Insert(args, image, "--label="+attemptLabel+"="+token)
	res.RunArgs = args
	out, err := s.Docker(rctx, "docker", args...)
	id := strings.TrimSpace(string(out))
	if err != nil || id == "" {
		res.Reason = fmt.Sprintf("docker run: %v", err)
		return res, r.Engine.removeOwned("srpf-"+a.Name, token)
	}
	res.ContainerID = id
	es := EngineStart{Treatment: a.Name, Name: "srpf-" + a.Name, ContainerID: id, Image: SRPFSweepImage, RunArgs: args, StartedAt: t0.UTC()}
	mErr := s.measureArm(ctx, rctx, r, &res, es, schedulerPath, archived, trace, t0)

	rec := ReadinessStart{Treatment: a.Name, Ordinal: 1}
	err = r.finish(ctx, &rec, es)
	res.LogFile, res.LogError = rec.LogFile, rec.LogError
	return res, errors.Join(mErr, err)
}

// measureArm takes a started engine through readiness, its identity checks, the warm-up and the replay, filling res.
//
// It stops at the first step that fails, with the reason on res; the caller removes the container either way.
//
// The error it returns is only a record that could not be written, which ends the sweep.
func (s *SRPFSweep) measureArm(ctx, rctx context.Context, r *ReadinessRun, res *SRPFArmResult, es EngineStart, schedulerPath string,
	archived []byte, trace []TraceRow, t0 time.Time) error {
	a := res.SRPFArm
	healthAt, exited, err := r.waitHealthy(rctx, es)
	switch {
	case exited != "":
		res.Reason = "the engine container " + exited + " before /health returned 200"
		return nil
	case err != nil:
		res.Reason = fmt.Sprintf("no /health 200 within %s", SRPFSweepReadyBound)
		return nil
	}
	h := healthAt.Sub(t0).Seconds()
	res.HealthSeconds = &h

	// The engine's arguments and the code it imports are checked before any request, so a wrong arm is never measured.
	ictx, cancel := context.WithTimeout(ctx, SRPFSweepArmIdentityBound)
	defer cancel()
	logs, err := r.Logs(ictx, es.ContainerID)
	if err != nil {
		res.Reason = "read the engine log: " + err.Error()
		return nil
	}
	for line := range strings.Lines(string(logs)) {
		if i := strings.Index(line, "non-default args: "); i >= 0 {
			res.NonDefaultArgs = strings.TrimSpace(line[i:])
			break
		}
	}
	if err := srpfNonDefaultArgsRefusal(a, res.NonDefaultArgs); err != nil {
		res.Reason = err.Error()
		return nil
	}
	// The threshold is ignored without chunked prefill, whose default the engine decides per model, so its own line is required.
	if !strings.Contains(string(logs), srpfChunkedPrefillLine) {
		res.Reason = "the engine did not log " + strconv.Quote(srpfChunkedPrefillLine)
		return nil
	}
	probe, err := s.Docker(ictx, "docker", "exec", es.ContainerID, "python3", "-c", srpfCodeProbe)
	res.CodeProbe = string(probe)
	if err != nil {
		res.Reason = "the code probe failed: " + err.Error()
		return nil
	}
	res.EngineCoreEnv, err = srpfProbeCheck(a, schedulerPath, true, probe)
	if err != nil {
		res.Reason = err.Error()
		return nil
	}

	rs := ReadinessStart{Treatment: a.Name, Ordinal: 1, Capture: []CaptureRecord{}}
	r.capture(ctx, &rs)
	res.Capture = rs.Capture

	if why := s.warmup(ctx, res, trace); why != "" {
		res.Reason = why
		return nil
	}
	if err := s.waitIdle(ctx); err != nil {
		res.Reason = err.Error()
		return nil
	}
	before, err := s.metrics(ctx, "metrics-"+a.Name+"-before.prom")
	if err != nil {
		res.Reason = err.Error()
		return fatalWrite(err)
	}
	// What the arm is and what it checked are on disk before the replay, so a reclaim during it keeps them with the rows.
	if err := s.writeJSON("arm-"+a.Name+".pre-replay.json", res); err != nil {
		return err
	}
	if err := WriteNewFileDurably(filepath.Join(s.Out, "start-"+a.Name+"-1.pre-replay.engine.log"), logs); err != nil {
		return err
	}
	var fatal error
	res.ReplayError, res.RawFile, fatal = s.replay(ctx, a, archived)
	if fatal != nil {
		res.Reason = fatal.Error()
		return fatal
	}
	// The counter is read once the engine has finished every request, so no preemption of the replay is still unreported.
	mErr := s.waitIdle(ctx)
	after := ""
	if mErr == nil {
		after, mErr = s.metrics(ctx, "metrics-"+a.Name+"-after.prom")
		if fatal := fatalWrite(mErr); fatal != nil {
			res.Reason = fatal.Error()
			return fatal
		}
	}
	if mErr != nil {
		res.MetricsError = mErr.Error()
	} else if d, name, err := PreemptionDelta(before, after); err == nil {
		res.Preemptions, res.PreemptionMetric = &d, name
	} else {
		res.MetricsError = err.Error()
	}
	res.Figures, err = s.figures(a.Name, res.RawFile, trace)
	if err != nil {
		res.FiguresError = err.Error()
	}
	switch {
	case res.ReplayError != "":
		res.Reason = "the replay: " + res.ReplayError
	case res.MetricsError != "":
		res.Reason = "the preemption counter: " + res.MetricsError
	case err != nil:
		res.Reason = "the figures: " + err.Error()
	case res.Figures.InputTokenMismatches > 0:
		// The rows stay on disk, but figures from requests of another length are not this trace's.
		res.Reason = fmt.Sprintf("%d rows' prompts were another length to the engine than the trace's", res.Figures.InputTokenMismatches)
	default:
		res.Outcome = "measured"
	}
	return nil
}

// srpfWriteError marks a record that could not be written, which ends the sweep rather than one arm.
type srpfWriteError struct{ error }

// fatalWrite returns err when it is a write failure, and nil otherwise.
func fatalWrite(err error) error {
	if _, ok := errors.AsType[srpfWriteError](err); ok {
		return err
	}
	return nil
}

// warmup sends the trace's first premium and first contender request one at a time, and names the first that failed.
//
// They carry the arm's priorities and their own request IDs, and their rows are kept apart from the replay's.
func (s *SRPFSweep) warmup(ctx context.Context, res *SRPFArmResult, trace []TraceRow) string {
	wctx, cancel := context.WithTimeout(ctx, SRPFSweepWarmupBound)
	defer cancel()
	prio := SRPFSweepPriorityMap()
	for _, tenant := range []string{PremiumTenant, NoisyTenant} {
		i := slices.IndexFunc(trace, func(t TraceRow) bool { return t.Tenant == tenant })
		if i < 0 {
			return "the trace has no " + tenant + " request to warm up with"
		}
		row := trace[i]
		row.Index, row.OffsetMs = len(res.Warmup), 0
		sender, err := s.NewSender(s.EngineURL)
		if err != nil {
			return err.Error()
		}
		sender.SetPriorities(prio)
		// The sender sends the X-Request-Id and Replay only records it, so both are given the prefix.
		sender.SetRequestIDPrefix("warmup-" + res.Name)
		got := Replay(wctx, sender, []TraceRow{row}, ReplayOptions{
			Study: StudySRPF58420Threshold, Arm: res.Name, Priorities: prio, RequestIDPrefix: "warmup-" + res.Name, RecordTiming: true,
		})
		res.Warmup = append(res.Warmup, got...)
		if len(got) != 1 {
			return "the " + tenant + " warm-up returned no row"
		}
		if why := srpfFailure(got[0], row.MaxOutputTokens); why != "" {
			return "the " + tenant + " warm-up failed: " + why
		}
		// The trace's token counts are frozen for this model and template, so a prompt the engine counts otherwise is another workload.
		// No request of the workload had reached an engine of this image before run 7, so the warm-up is where that shows first.
		if got[0].EngineInputTokens != row.ExactInputTokens {
			return fmt.Sprintf("the %s warm-up's prompt was %d tokens to the engine, and the trace's is %d", tenant, got[0].EngineInputTokens, row.ExactInputTokens)
		}
	}
	return ""
}

// waitIdle polls /metrics until the engine reports no running and no waiting request, so the replay starts on an idle engine.
func (s *SRPFSweep) waitIdle(ctx context.Context) error {
	ictx, cancel := context.WithTimeout(ctx, SRPFSweepIdleBound)
	defer cancel()
	last := "no /metrics answer"
	for {
		status, body, err := s.readiness().fetch(ictx, http.MethodGet, "/metrics", nil)
		switch {
		case err != nil:
			last = err.Error()
		case status != http.StatusOK:
			last = fmt.Sprintf("status %d: %.200s", status, body)
		}
		if err == nil && status == http.StatusOK {
			running, okR := PromSum(string(body), "vllm:num_requests_running")
			waiting, okW := PromSum(string(body), "vllm:num_requests_waiting")
			if okR && okW && running == 0 && waiting == 0 {
				return nil
			}
			last = fmt.Sprintf("running %g (read %t), waiting %g (read %t)", running, okR, waiting, okW)
		}
		select {
		case <-ictx.Done():
			return fmt.Errorf("the engine was not idle within %s: %s", SRPFSweepIdleBound, last)
		case <-time.After(s.PollEvery):
		}
	}
}

// metrics reads /metrics once and saves it raw under name.
func (s *SRPFSweep) metrics(ctx context.Context, name string) (string, error) {
	mctx, cancel := context.WithTimeout(ctx, SRPFSweepMetricsBound)
	defer cancel()
	status, body, err := s.readiness().fetch(mctx, http.MethodGet, "/metrics", nil)
	if body != nil {
		if wErr := WriteNewFileDurably(filepath.Join(s.Out, name), body); wErr != nil {
			return "", srpfWriteError{wErr}
		}
	}
	if err == nil && status != http.StatusOK {
		err = fmt.Errorf("status %d", status)
	}
	if err != nil {
		return "", fmt.Errorf("read %s: %w", name, err)
	}
	return string(body), nil
}

// replay writes the arm's manifest and runs the replay subcommand on it.
//
// It returns the subcommand's failure and the raw file it wrote, and, apart, a record of the sweep's own that could not
// be written, which ends the sweep.
// The subcommand is the one every earlier run used, so its sender, schedule, record and completion check are theirs.
func (s *SRPFSweep) replay(ctx context.Context, a SRPFArm, archived []byte) (string, string, error) {
	m, err := ArmManifest(archived, a.Name, s.Trace, s.EngineURL)
	if err != nil {
		return err.Error(), "", nil
	}
	manifest := filepath.Join(s.Out, "manifest-"+a.Name+".yaml")
	if err := WriteManifestFile(manifest, m); err != nil {
		return "", "", srpfWriteError{err}
	}
	raw := filepath.Join(s.Out, "raw-"+a.Name+".jsonl")
	rctx, cancel := context.WithTimeout(ctx, SRPFSweepReplayBound)
	defer cancel()
	out, err := s.Exec(rctx, s.Self, "replay", "--manifest", manifest, "--raw-out", raw,
		"--priorities", SRPFSweepPriorities, "--request-id-prefix", "srpf-"+a.Name)
	if wErr := WriteNewFileDurably(filepath.Join(s.Out, "replay-"+a.Name+".log"), out); wErr != nil {
		return "", filepath.Base(raw), srpfWriteError{wErr}
	}
	if err != nil {
		return err.Error(), filepath.Base(raw), nil
	}
	return "", filepath.Base(raw), nil
}

// figures reads the arm's raw rows back from the file the replay wrote and scores them.
func (s *SRPFSweep) figures(arm, rawFile string, trace []TraceRow) (*SRPFFigures, error) {
	if rawFile == "" {
		return nil, errors.New("no raw file was written")
	}
	f, err := os.Open(filepath.Join(s.Out, rawFile))
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	rows, err := ReadRawRows(f)
	if err != nil {
		return nil, err
	}
	return SRPFSweepFigures(arm, trace, rows)
}

// writeJSON writes one record durably and never over another.
func (s *SRPFSweep) writeJSON(name string, v any) error {
	return s.readiness().writeJSON(name, v)
}

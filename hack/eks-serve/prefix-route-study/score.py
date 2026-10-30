"""Scores experiment A, prefix-aware routing, against its registration.

The registration is docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md; every constant and rule here
is copied from it, and a rule it does not state is not applied, with one exception the page records: the engine pin
(REGISTERED_ENGINE_ARGS), added after the result as a check on the evidence ("Recorded after the result, 2026-10-29").
Where the evidence cannot support a figure the scorer refuses it, naming why, rather than reporting one.

    python3 hack/eks-serve/prefix-route-study/score.py <study dir> [--capacity-tokens N] [--engine-unpinned]

<study dir> is what run.sh writes: study-id.txt, traces/<block>.jsonl and cells/<block>-<arm>/.
--capacity-tokens exists for the kind rehearsal, whose stub engines model a smaller cache; the verdict prints the
capacity it judged against, and the paid session never passes it. --engine-unpinned is the rehearsal's too, for the
same stubs; the output then says the engine pin was not checked, and a run that would have passed is
reported as a rehearsal, not a result, and exits 1.

Exits 0 only on "observed on these traces"; 1 on any other verdict; 2 on a usage error.
"""

from __future__ import annotations

import ast
import hashlib
import json
import math
import os
import re
import sys

STUDY = "prefix-route-2026-10-27"
ARMS = ("RoundRobin", "LeastQueue", "PrefixAffinity")
TREATMENT, CONTROLS = "PrefixAffinity", ("RoundRobin", "LeastQueue")
SHARED_BLOCKS = ("shared-941", "shared-942", "shared-943")
CONTROL_BLOCK = "control-944"
BLOCKS = SHARED_BLOCKS + (CONTROL_BLOCK,)
NAMESPACE = "prefix-route"
BACKENDS = (f"{NAMESPACE}/qwen-a", f"{NAMESPACE}/qwen-b")
ENGINE_FILE = {BACKENDS[0]: "a", BACKENDS[1]: "b"}
TENANT = "premium-1"
OUTPUT_TOKENS = 64
SENDER_POOL = 600
SAMPLE_GAP_NS = 15_000_000_000
DISPATCH_MAX_NS = 50_000_000
RR_COMPLETION_MIN = 0.99
CONTROL_GAIN_MAX = 0.01
CAPACITY_TOKENS = 393_232
CAPACITY_TOLERANCE = 0.05
QUERIES = "vllm:prefix_cache_queries_total"
HITS = "vllm:prefix_cache_hits_total"
SUCCESS = "vllm:request_success_total"
CACHE_INFO = "vllm:cache_config_info"
ENGINE_SERIES = (QUERIES, HITS, SUCCESS, CACHE_INFO)
ROUTING = "gpuaas_gateway_routing_decisions_total"
FALLBACKS = "gpuaas_gateway_backend_fallbacks_total"
CACHING_ARG = "'enable_prefix_caching': True"
HERE = os.path.dirname(os.path.abspath(__file__))


class Unscorable(Exception):
    """Evidence that is missing, malformed or does not match the trace; it makes the study inconclusive."""


class Invalid(Exception):
    """Evidence that is complete and breaks a validity line; it makes the study inconclusive too."""


# The arm order per block, a Latin square over the shared blocks so each arm runs once first, once second and once
# third; the hash order this replaced put PrefixAffinity before RoundRobin in all three (astra's finding 5).
ORDER = {
    "shared-941": ("RoundRobin", "LeastQueue", "PrefixAffinity"),
    "shared-942": ("LeastQueue", "PrefixAffinity", "RoundRobin"),
    "shared-943": ("PrefixAffinity", "RoundRobin", "LeastQueue"),
    "control-944": ("RoundRobin", "LeastQueue", "PrefixAffinity"),
}
TIMEOUT_MS = 30_000
# What must be the same in every cell; the gateway Pod is replaced per cell by design, so its UID is not here.
IDENTITY_KEYS = ("argo", "images", "gatewayArgs", "gpuNodes")
REGISTERED_GATEWAY_ARGS = [["/gateway"]]
# The engine the registration names: profile v0.27.1-a10g-prefix-cache at the pinned revision, "nothing else changed".
# Checking prefix caching alone let a cell whose engines served another model, or ran max_num_seqs 1, be scored as
# routing's effect (audit finding 10), so the whole of what vLLM logs as its non-default args is pinned, as the
# gateway's arguments are. These are the args every engine of the paid run 2 logged, all 24 of them identical.
REGISTERED_ENGINE_ARGS = {
    "model_tag": "Qwen/Qwen2.5-3B-Instruct",
    "model": "Qwen/Qwen2.5-3B-Instruct",
    "dtype": "half",
    "revision": "aa8e72537993ba99e69dfaafa59ed015b17504d1",
    "tokenizer_revision": "aa8e72537993ba99e69dfaafa59ed015b17504d1",
    "max_model_len": 16384,
    "served_model_name": ["Qwen/Qwen2.5-3B-Instruct"],
    "gpu_memory_utilization": 0.9,
    "enable_prefix_caching": True,
    "max_num_batched_tokens": 512,
    "max_num_seqs": 64,
    "scheduling_policy": "priority",
    "async_scheduling": False,
}
REGISTERED_ENGINE_VERSION = "0.27.1"
ARGS_MARK = "non-default args: "
VERSION_RE = re.compile(r"\bversion (\d+\.\d+\.\d+\S*)")


def registered_order(block: str) -> tuple[str, ...]:
    return ORDER[block]


def nearest_rank(values: list[float], q: float) -> float:
    if not values:
        raise Unscorable("a quantile of nothing")
    ordered = sorted(values)
    return ordered[max(0, math.ceil(q * len(ordered)) - 1)]


def read_json(path: str):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError) as exc:
        raise Unscorable(f"{path}: {exc}") from exc


def read_jsonl(path: str) -> list[dict]:
    try:
        with open(path) as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        raise Unscorable(f"{path}: {exc}") from exc
    out = []
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except ValueError as exc:
            raise Unscorable(f"{path} line {n} does not parse") from exc
    return out


PROM_LINE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)")


def read_prom(path: str, required: tuple[str, ...]) -> dict[str, list[tuple[str, float]]]:
    """Series name to its (labels, value) pairs; every required series must be present, and every line must parse."""
    out: dict[str, list[tuple[str, float]]] = {}
    try:
        with open(path) as handle:
            text = handle.read()
    except OSError as exc:
        raise Unscorable(f"{path}: {exc}") from exc
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        m = PROM_LINE.match(line)
        if not m:
            raise Unscorable(f"{path}: a line does not parse: {line[:80]}")
        try:
            value = float(m.group(3))
        except ValueError as exc:
            raise Unscorable(f"{path}: a value does not parse: {line[:80]}") from exc
        out.setdefault(m.group(1), []).append((m.group(2) or "", value))
    missing = [s for s in required if s not in out]
    if missing:
        raise Unscorable(f"{path} lacks {', '.join(missing)}")
    return out


def total(series: dict, name: str) -> float:
    return sum(v for _, v in series.get(name, []))


def label(labels: str, key: str) -> str | None:
    m = re.search(r'(?:^|[{,])' + re.escape(key) + r'="([^"]*)"', labels)
    return m.group(1) if m else None


def frozen_checksums() -> dict[str, str]:
    """The registered trace checksums, committed beside this scorer before any paid replay."""
    path = os.path.join(HERE, "frozen-traces.sha256")
    out = {}
    try:
        with open(path) as handle:
            for line in handle:
                if line.strip():
                    digest, name = line.split()
                    out[name.removesuffix(".jsonl")] = digest
    except (OSError, ValueError) as exc:
        raise Unscorable(f"the frozen trace checksums cannot be read: {exc}") from exc
    if set(out) != set(BLOCKS):
        raise Unscorable(f"the frozen checksums name {sorted(out)}, not the registered blocks")
    return out


def load_trace(study_dir: str, block: str, frozen: dict[str, str]) -> tuple[list[dict], str]:
    path = os.path.join(study_dir, "traces", f"{block}.jsonl")
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        raise Unscorable(f"trace {block}: {exc}") from exc
    digest = hashlib.sha256(raw).hexdigest()
    if digest != frozen[block]:
        raise Unscorable(f"trace {block} is {digest[:12]}, not the frozen {frozen[block][:12]}")
    rows = [json.loads(line) for line in raw.decode().splitlines() if line.strip()]
    return rows, digest


def share_bound(trace: list[dict]) -> float:
    """0.5 plus two standard deviations of one backend's share if each prompt's requests went to a fair coin's pick."""
    counts: dict[int, int] = {}
    for r in trace:
        g = r.get("prefixGroup", 0)
        if g < 1:
            raise Unscorable("a shared-trace row carries no prompt group")
        counts[g] = counts.get(g, 0) + 1
    n = len(trace)
    return 0.5 + 2 * math.sqrt(sum(c * c for c in counts.values())) / (2 * n)


def succeeded(row: dict) -> bool:
    """HTTP 200, no error, the stream's own end marker, and the engine's own count of 64 generated tokens.

    The engine's count and not the content events: the hold-cap product run recorded 14 requests that generated 64
    tokens in 63 events (holdcap-study/runs/20261021T021149Z/README.md), so counting events would turn a complete
    request into +inf (astra's finding 2).
    """
    return (row.get("httpStatus") == 200 and not row.get("errorKind") and not row.get("streamError")
            and row.get("streamTerminated") is True and row.get("engineOutputTokens") == OUTPUT_TOKENS)


def ttft_ms(row: dict) -> float:
    if not succeeded(row):
        return math.inf
    scheduled = row["replayOriginUnixNanos"] + row["scheduledOffsetMs"] * 1_000_000
    return (row["firstTokenUnixNanos"] - scheduled) / 1e6


def engine_args(text: str) -> dict | None:
    """The dict vLLM logged after "non-default args: ", or None when the text is not exactly one such line."""
    lines = [line for line in text.splitlines() if ARGS_MARK in line]
    if len(lines) != 1:
        return None
    try:
        parsed = ast.literal_eval(lines[0].split(ARGS_MARK, 1)[1].strip())
    except (ValueError, SyntaxError):
        return None
    return parsed if isinstance(parsed, dict) else None


def score_cell(study_dir: str, study: str, block: str, arm: str, trace: list[dict], checksum: str,
               capacity: int, identity: dict, pin_engine: bool = True) -> dict:
    """Every endpoint of one cell, after its completeness and validity lines; raises on the first that fails."""
    d = os.path.join(study_dir, "cells", f"{block}-{arm}")
    if not os.path.isdir(d):
        raise Unscorable(f"cell {block}-{arm} was never run")
    cell = read_json(os.path.join(d, "cell.json"))
    if cell.get("outcome") != "complete":
        raise Unscorable(f"cell {block}-{arm} is {cell.get('outcome')!r}")
    after_identity = read_json(os.path.join(d, "identity-after.json"))
    for key in IDENTITY_KEYS:
        if key not in identity or key not in after_identity:
            raise Unscorable(f"cell {block}-{arm}: the identity lacks {key}")
        if after_identity[key] != identity[key]:
            raise Invalid(f"cell {block}-{arm}: {key} changed from the study's start")
    rows = read_jsonl(os.path.join(d, "raw.jsonl"))
    by_index = {}
    for r in rows:
        if r.get("index") in by_index:
            raise Unscorable(f"cell {block}-{arm}: row {r.get('index')} appears twice")
        by_index[r.get("index")] = r
    if len(by_index) != len(trace):
        raise Unscorable(f"cell {block}-{arm}: {len(by_index)} rows for a trace of {len(trace)}")
    for t in trace:
        r = by_index.get(t["index"])
        if r is None or r.get("scheduledOffsetMs") != t["offsetMs"] or r.get("tenant") != t["tenant"]:
            raise Unscorable(f"cell {block}-{arm}: row {t['index']} does not match the trace")
        if r.get("study") != study or r.get("arm") != arm or r.get("traceChecksum") != checksum:
            raise Unscorable(f"cell {block}-{arm}: row {t['index']} is stamped {r.get('study')}/{r.get('arm')}")
    sender = read_json(os.path.join(d, "raw.jsonl.sender.json"))
    if (sender.get("study"), sender.get("arm"), sender.get("connMode"), sender.get("maxIdleConnsPerHost"),
            sender.get("timeoutMs")) != (study, arm, "pooled", SENDER_POOL, TIMEOUT_MS):
        raise Unscorable(f"cell {block}-{arm}: the sender is not the registered one ({sender})")
    # A sample counts only when every read in it succeeded; one that failed a read is dropped rather than read as a value,
    # and the gap line is then judged on the samples that remain, so a flaky read costs coverage, never a number.
    samples = [s for s in read_jsonl(os.path.join(d, "samples.jsonl"))
               if all(isinstance(s.get(k), (int, float)) for k in ("engineALoad", "engineBLoad"))
               and all(s.get(k) not in (None, "-") for k in ("engineAUID", "engineBUID", "gatewayUID"))]
    if len(samples) < 2:
        raise Unscorable(f"cell {block}-{arm}: {len(samples)} complete samples")
    times = [s["t"] for s in samples]
    # Coverage of the whole replay, not only between the samples that survived: the first and last counted samples must
    # fall within the gap line of the replay's start and its last return (codex review).
    origin = min(r.get("replayOriginUnixNanos") or 0 for r in rows)
    last_return = max(r.get("returnedUnixNanos") or 0 for r in rows)
    if not origin or not last_return:
        raise Unscorable(f"cell {block}-{arm}: the rows carry no replay timing")
    if times[0] > origin + SAMPLE_GAP_NS or times[-1] < last_return - SAMPLE_GAP_NS:
        raise Unscorable(f"cell {block}-{arm}: the samples do not cover the replay from start to end")
    if max(b - a for a, b in zip(times, times[1:])) > SAMPLE_GAP_NS:
        raise Unscorable(f"cell {block}-{arm}: a gap over 15 s between samples")
    engines = {}
    for b in BACKENDS:
        f = ENGINE_FILE[b]
        before = read_prom(os.path.join(d, f"metrics-engine-{f}-before.prom"), ENGINE_SERIES)
        after = read_prom(os.path.join(d, f"metrics-engine-{f}-after.prom"), ENGINE_SERIES)
        try:
            with open(os.path.join(d, f"engine-{f}-args.txt")) as handle:
                args = handle.read()
            with open(os.path.join(d, f"engine-{f}.log")) as handle:
                version = VERSION_RE.search(handle.read())
        except OSError as exc:
            raise Unscorable(f"cell {block}-{arm}: engine {f}'s args: {exc}") from exc
        if pin_engine:
            parsed = engine_args(args)
            if parsed is None:
                raise Unscorable(f"cell {block}-{arm}: engine {f}'s args are not one {ARGS_MARK!r} line vLLM wrote")
            if parsed != REGISTERED_ENGINE_ARGS:
                moved = sorted(k for k in parsed.keys() | REGISTERED_ENGINE_ARGS.keys()
                               if parsed.get(k) != REGISTERED_ENGINE_ARGS.get(k))
                raise Invalid(f"cell {block}-{arm}: engine {f} is not the registered engine; it differs in {moved}")
            if version is None or version.group(1) != REGISTERED_ENGINE_VERSION:
                raise Invalid(f"cell {block}-{arm}: engine {f} reports vLLM "
                              f"{version.group(1) if version else 'no version'}, not {REGISTERED_ENGINE_VERSION}")
        engines[b] = (before, after, args)
    gw_before = read_prom(os.path.join(d, "metrics-gateway-before.prom"), ())
    gw_after = read_prom(os.path.join(d, "metrics-gateway-after.prom"), (ROUTING,))

    # Validity.
    answered = [r for r in rows if r.get("httpStatus")]
    for r in answered:
        if r.get("routingPolicy") != arm:
            raise Invalid(f"cell {block}-{arm}: row {r['index']} was routed under {r.get('routingPolicy')!r}")
        if r.get("routedBackend") not in BACKENDS:
            raise Invalid(f"cell {block}-{arm}: row {r['index']} names backend {r.get('routedBackend')!r}")
    for b, (before, after, args) in engines.items():
        if CACHING_ARG not in args:
            raise Invalid(f"cell {block}-{arm}: engine {b} did not report prefix caching on in its args")
        infos = after[CACHE_INFO]
        if len(infos) != 1 or label(infos[0][0], "enable_prefix_caching") != "True":
            raise Invalid(f"cell {block}-{arm}: engine {b}'s cache_config_info does not say prefix caching is on")
        size = label(infos[0][0], "kv_cache_size_tokens")
        if size is None or not size.isdigit() or abs(int(size) - capacity) > CAPACITY_TOLERANCE * capacity:
            raise Invalid(f"cell {block}-{arm}: engine {b}'s capacity is {size} tokens, not within 5% of {capacity}")
        arrived = total(after, SUCCESS) - total(before, SUCCESS)
        routed = sum(1 for r in rows if r.get("httpStatus") == 200 and r.get("routedBackend") == b)
        if arrived != routed:
            raise Invalid(f"cell {block}-{arm}: engine {b} finished {arrived:g} requests and the rows route {routed} 200s to it")
    fallbacks = total(gw_after, FALLBACKS) - total(gw_before, FALLBACKS)
    if fallbacks != 0:
        raise Invalid(f"cell {block}-{arm}: {fallbacks:g} fallback(s), so a row's backend may not be the one that served it")
    for key in ("engineAUID", "engineBUID", "gatewayUID", "engineARestarts", "engineBRestarts", "gatewayRestarts"):
        seen = {s.get(key) for s in samples}
        if len(seen) != 1 or None in seen or "-" in seen or seen != {cell.get(key)}:
            raise Invalid(f"cell {block}-{arm}: {key} was {sorted(map(str, seen))} against the cell's {cell.get(key)}")
    for r in rows:
        lag = r["sendUnixNanos"] - (r["replayOriginUnixNanos"] + r["scheduledOffsetMs"] * 1_000_000)
        if lag > DISPATCH_MAX_NS:
            raise Invalid(f"cell {block}-{arm}: row {r['index']} was dispatched {lag / 1e6:.1f} ms late")
    completion = sum(1 for r in rows if succeeded(r)) / len(trace)
    if arm == "RoundRobin" and completion < RR_COMPLETION_MIN:
        raise Invalid(f"cell {block}-{arm}: RoundRobin completed {completion:.4f}, below 0.99, so its p99 is undefined")

    # Endpoints.
    queries = sum(total(a, QUERIES) - total(b, QUERIES) for b, a, _ in engines.values())
    hits = sum(total(a, HITS) - total(b, HITS) for b, a, _ in engines.values())
    if queries <= 0:
        raise Unscorable(f"cell {block}-{arm}: the engines counted no prefix-cache queries, so no hit ratio exists")
    ttfts = [ttft_ms(by_index[t["index"]]) for t in trace]
    share = {b: sum(1 for r in answered if r.get("routedBackend") == b) / len(answered) for b in BACKENDS} \
        if answered else {b: 0.0 for b in BACKENDS}
    per_backend_p99 = {}
    for b in BACKENDS:
        mine = [ttft_ms(r) for r in rows if r.get("routedBackend") == b]
        per_backend_p99[b] = nearest_rank(mine, 0.99) if mine else math.nan
    # Rule 5 compares the treatment's worse backend with RoundRobin's, so RoundRobin's must exist and be finite on both;
    # otherwise an infinite treatment tail would pass against an infinite reference (astra's finding 4).
    if arm == "RoundRobin":
        for b, v in per_backend_p99.items():
            if math.isnan(v) or math.isinf(v):
                raise Invalid(f"cell {block}-{arm}: RoundRobin's p99 on {b} is {fmt(v)}, so rule 5 has no reference")
    loads = [abs(s["engineALoad"] - s["engineBLoad"]) for s in samples]
    return {"hit_ratio": hits / queries, "p50": nearest_rank(ttfts, 0.50), "p99": nearest_rank(ttfts, 0.99),
            "share": share, "per_backend_p99": per_backend_p99, "imbalance": sum(loads) / len(loads),
            "completion": completion}


def fmt(x: float) -> str:
    return "inf" if math.isinf(x) else ("nan" if math.isnan(x) else f"{x:.1f}")


def shared_block_failures(cells: dict, block: str, bound: float) -> list[str]:
    """Rules 3 to 5 on one shared block whose three cells all scored; each failure names the rule and the block."""
    t = cells[(block, TREATMENT)]
    out = []
    if not all(t["hit_ratio"] > cells[(block, a)]["hit_ratio"] for a in CONTROLS):
        out.append(f"rule 3 (hit ratio not raised in {block})")
    for q in ("p50", "p99"):
        if not all(t[q] < cells[(block, a)][q] for a in CONTROLS):
            out.append(f"rule 4 {q} (not lowered in {block})")
    top = max(t["share"].values())
    if top > bound:
        out.append(f"rule 5 ({block} share {top:.3f} > {bound:.4f})")
    # A backend that served nothing has no tail, and the share line judges it; an infinite tail is a worse tail.
    tails = [v for v in t["per_backend_p99"].values() if not math.isnan(v)]
    worst_rr = max(cells[(block, "RoundRobin")]["per_backend_p99"].values())
    if tails and not max(tails) <= worst_rr:
        out.append(f"rule 5 ({block} worse-backend p99 {fmt(max(tails))} > RoundRobin's {fmt(worst_rr)} ms)")
    return out


def main(argv: list[str]) -> int:
    args = list(argv[1:])
    capacity = CAPACITY_TOKENS
    usage = "usage: score.py <study dir> [--capacity-tokens N] [--engine-unpinned]"
    # The kind rehearsal's stub engines are not vLLM, so it skips the engine pin; a run scored without the pin cannot pass.
    pin_engine = "--engine-unpinned" not in args
    if not pin_engine:
        args.remove("--engine-unpinned")
    if "--capacity-tokens" in args:
        i = args.index("--capacity-tokens")
        try:
            capacity = int(args[i + 1])
        except (IndexError, ValueError):
            print(usage, file=sys.stderr)
            return 2
        del args[i:i + 2]
    if len(args) != 1:
        print(usage, file=sys.stderr)
        return 2
    study_dir = args[0]
    # Problems that make nothing scorable at all.
    try:
        with open(os.path.join(study_dir, "study-id.txt")) as handle:
            study = handle.read().strip()
        if study != STUDY:
            raise Unscorable(f"study-id.txt names {study!r}, not {STUDY}")
        frozen = frozen_checksums()
        identity = read_json(os.path.join(study_dir, "identity-start.json"))
        # The routing sizes are the gateway's defaults, so a gateway started with any argument is not the registered
        # treatment, however steady it stayed across cells (codex review).
        if identity.get("gatewayArgs") != REGISTERED_GATEWAY_ARGS:
            raise Unscorable(f"the gateway ran {identity.get('gatewayArgs')}, not the registered {REGISTERED_GATEWAY_ARGS}")
        present = set(os.listdir(os.path.join(study_dir, "cells")))
        unexpected = present - {f"{b}-{a}" for b in BLOCKS for a in ARMS}
        if unexpected:
            raise Unscorable(f"cells {sorted(unexpected)} are not registered")
    except (Unscorable, OSError) as exc:
        print(f"verdict: inconclusive: {exc}")
        return 1
    stopped = ""
    if os.path.exists(os.path.join(study_dir, "STOPPED")):
        with open(os.path.join(study_dir, "STOPPED")) as handle:
            stopped = handle.read().strip()

    # Each block is scored on its own, so a block that completed keeps its result when another did not (finding 10).
    cells: dict[tuple[str, str], dict] = {}
    broken: dict[str, str] = {}
    bounds: dict[str, float] = {}
    for block in BLOCKS:
        try:
            trace, checksum = load_trace(study_dir, block, frozen)
            if block in SHARED_BLOCKS:
                bounds[block] = share_bound(trace)
            for arm in registered_order(block):
                cells[(block, arm)] = score_cell(study_dir, study, block, arm, trace, checksum, capacity, identity,
                                                 pin_engine)
        except (Unscorable, Invalid) as exc:
            broken[block] = str(exc)
    lines = []
    for (block, arm), c in sorted(cells.items()):
        lines.append(f"{block} {arm}: H={c['hit_ratio']:.4f} p50={fmt(c['p50'])} ms p99={fmt(c['p99'])} ms "
                     f"share a/b={c['share'][BACKENDS[0]]:.3f}/{c['share'][BACKENDS[1]]:.3f} "
                     f"p99 a/b={fmt(c['per_backend_p99'][BACKENDS[0]])}/{fmt(c['per_backend_p99'][BACKENDS[1]])} ms "
                     f"imbalance={c['imbalance']:.2f} completion={c['completion']:.4f}")
    for block, why in broken.items():
        lines.append(f"{block}: not scorable: {why}")
    if stopped:
        lines.append(f"the study stopped: {stopped}")
    failures = []
    for block in SHARED_BLOCKS:
        if block not in broken:
            failures += shared_block_failures(cells, block, bounds[block])

    # Rule 2, attribution, needs the control and every shared block.
    attribution = ""
    if CONTROL_BLOCK not in broken and not any(b in broken for b in SHARED_BLOCKS):
        for a in CONTROLS:
            ctrl_gain = cells[(CONTROL_BLOCK, TREATMENT)]["hit_ratio"] - cells[(CONTROL_BLOCK, a)]["hit_ratio"]
            lines.append(f"rule 2, control: PrefixAffinity's H gain over {a} on {CONTROL_BLOCK} is {ctrl_gain:+.4f} "
                         f"(limit {CONTROL_GAIN_MAX}, and below every shared block's)")
            if ctrl_gain >= CONTROL_GAIN_MAX and not attribution:
                attribution = f"the control's gain over {a} is {ctrl_gain:+.4f}"
            # The shared effect must exceed the control's in every block, or the control reproduces it (finding 3).
            for b in SHARED_BLOCKS:
                gain = cells[(b, TREATMENT)]["hit_ratio"] - cells[(b, a)]["hit_ratio"]
                if gain <= ctrl_gain and not attribution:
                    attribution = f"{b}'s gain over {a}, {gain:+.4f}, is not above the control's {ctrl_gain:+.4f}"
    lines.append("share bounds: " + ", ".join(f"{b} {bounds[b]:.4f}" for b in SHARED_BLOCKS if b in bounds))
    lines.append(f"capacity bar: {capacity} tokens")
    if not pin_engine:
        lines.append("engine pin: NOT CHECKED (--engine-unpinned, the kind rehearsal's stub engines)")

    # Precedence: a failure a complete, valid shared block shows stands whatever else is missing; then missing or invalid
    # evidence; then attribution; then the pass.
    if failures:
        verdict = "not met: " + "; ".join(failures)
        if broken or stopped:
            verdict += " (and the study is incomplete)"
    elif broken or stopped:
        first = next(iter(broken.values()), stopped)
        verdict = f"inconclusive: {first}"
    elif attribution:
        verdict = f"not attributable to prefix affinity: {attribution}"
    elif not pin_engine:
        # Nothing stops a paid run's scoring from passing the flag, so an unpinned pass is never the registered verdict.
        verdict = "rehearsal only, not a result: the traces met every line, but the engine pin was not checked"
    else:
        verdict = "observed on these traces"
    print(f"verdict: {verdict}")
    for line in lines:
        print(line)
    return 0 if verdict == "observed on these traces" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))



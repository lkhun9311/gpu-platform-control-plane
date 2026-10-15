"""Scores the hold-cap product transfer study against its registration.

The registration is docs/superpowers/specs/2026-10-15-holdcap-on-the-product-path-design.md; every constant and rule
here is copied from it, and a rule it does not state is not applied.

    python3 hack/eks-serve/holdcap-study/score.py <run dir> [--traces <dir>]

Exits 0 only on "observed on these traces"; 1 on "not met" or "inconclusive"; 2 on a usage error.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys

STUDY = "holdcap-product-transfer-2026-10-15"
SEEDS = (851, 852, 853)
ARMS = ("Off", "HoldCap")
PREMIUM, CONTENDER = "premium-1", "standard-noisy"
OUTPUT_TOKENS = {PREMIUM: 64, CONTENDER: 16}
TIMEOUT_NS = 30_000_000_000
SENDER_POOL = 600
SAMPLE_GAP_NS = 15_000_000_000
DISPATCH_MAX_NS = 50_000_000
DISPATCH_L_NS = 13_000_000
PREMIUM_OVER_L_MAX = 0.001
PREMIUM_LOSS_MAX = 0.005
OFF_COMPLETION_MIN = 0.95
TTFT_RATIO_MAX = 0.85
COMPLETION_MIN = 0.95
P50_RATIO_MAX = 1.5
P95_MAX_MS = 25_000
GAP_RATIO_MAX = 1.25
CAP_ARG = "'long_prefill_token_threshold': 384"
BACKEND_MODE = {"Off": "gateway", "HoldCap": "hold-cap"}
PRIORITY = {"Off": {PREMIUM: "", CONTENDER: ""}, "HoldCap": {PREMIUM: "0", CONTENDER: "1"}}
PREEMPTIONS = "vllm:num_preemptions_total"
ENGINE_SERIES = (PREEMPTIONS, "vllm:num_requests_running", "vllm:num_requests_waiting")
GATEWAY_SERIES = ("gpuaas_gateway_admission_mode_active", "gpuaas_gateway_backend_admission_mode")
DEFAULT_TRACES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "diagnostic")


class Unscorable(Exception):
    """Evidence that is missing, malformed or does not correspond to the trace; it makes the block inconclusive."""


def registered_order(seed: int) -> list[str]:
    """The block's arm order, sha256("<seed>/<arm>") ascending, as the registration fixes it."""
    return sorted(ARMS, key=lambda a: hashlib.sha256(f"{seed}/{a}".encode()).hexdigest())


def cell_name(seed: int, arm: str) -> str:
    return f"{seed}-{arm}"


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
        raise Unscorable(f"{os.path.basename(path)}: {exc}") from exc


def read_jsonl(path: str) -> list[dict]:
    try:
        with open(path) as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        raise Unscorable(f"{os.path.basename(path)}: {exc}") from exc
    rows = []
    for n, line in enumerate(lines, 1):
        try:
            rows.append(json.loads(line))
        except ValueError as exc:
            raise Unscorable(f"{os.path.basename(path)} line {n} does not parse") from exc
    return rows


PROM_LINE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)")


def read_prom(path: str, required: tuple[str, ...]) -> dict[str, list[tuple[str, float]]]:
    """Series name to its (labels, value) pairs; every required series must be present."""
    out: dict[str, list[tuple[str, float]]] = {}
    try:
        with open(path) as handle:
            for line in handle:
                if line.startswith("#") or not line.strip():
                    continue
                m = PROM_LINE.match(line)
                try:
                    value = float(m.group(3)) if m else None
                except ValueError:
                    value = None
                if value is None:
                    raise Unscorable(f"{os.path.basename(path)}: unparsable line {line.strip()[:80]!r}")
                out.setdefault(m.group(1), []).append((m.group(2) or "", value))
    except OSError as exc:
        raise Unscorable(f"{os.path.basename(path)}: {exc}") from exc
    missing = [s for s in required if s not in out]
    if missing:
        raise Unscorable(f"{os.path.basename(path)} lacks {missing}")
    return out


def scheduled(row: dict) -> int:
    return row.get("replayOriginUnixNanos", 0) + row["scheduledOffsetMs"] * 1_000_000


def succeeded(row: dict) -> bool:
    """HTTP 200, no error, [DONE], output exactly at its limit, and one gap fewer than its tokens."""
    want = OUTPUT_TOKENS.get(row.get("tenant"))
    gaps = row.get("contentGapsMicros")
    return (
        row.get("httpStatus") == 200
        and not row.get("errorKind")
        and not row.get("streamError")
        and row.get("streamTerminated") is True
        and row.get("outputTokens") == want
        and bool(row.get("firstTokenUnixNanos"))
        and gaps is not None
        and len(gaps) == want - 1
    )


def refused(row: dict) -> bool:
    """A response the gateway or engine sent as a refusal: any HTTP status of 400 or above."""
    return (row.get("httpStatus") or 0) >= 400


class Cell:
    """One cell's evidence, checked for completeness on construction."""

    def __init__(self, run: str, seed: int, arm: str, trace_dir: str):
        self.seed, self.arm, self.name = seed, arm, cell_name(seed, arm)
        self.dir = os.path.join(run, "cells", self.name)
        if not os.path.isdir(self.dir):
            raise Unscorable(f"cell {self.name} is missing")
        trace_path = os.path.join(trace_dir, f"trace-off-{seed - 850}.jsonl")
        with open(trace_path, "rb") as handle:
            self.trace_sum = hashlib.sha256(handle.read()).hexdigest()
        self.trace = read_jsonl(trace_path)
        self.meta = read_json(os.path.join(self.dir, "cell.json"))
        self.rows = read_jsonl(os.path.join(self.dir, "raw.jsonl"))
        self.sender = read_json(os.path.join(self.dir, "raw.jsonl.sender.json"))
        self.samples = read_jsonl(os.path.join(self.dir, "samples.jsonl"))
        self.engine_before = read_prom(os.path.join(self.dir, "metrics-engine-before.prom"), ENGINE_SERIES)
        self.engine_after = read_prom(os.path.join(self.dir, "metrics-engine-after.prom"), ENGINE_SERIES)
        read_prom(os.path.join(self.dir, "metrics-gateway-before.prom"), GATEWAY_SERIES)
        read_prom(os.path.join(self.dir, "metrics-gateway-after.prom"), GATEWAY_SERIES)
        self.identity = read_json(os.path.join(self.dir, "identity-after.json"))
        self._complete()

    def _complete(self) -> None:
        if self.meta.get("cell") != self.name or self.meta.get("outcome") != "complete":
            raise Unscorable(f"cell {self.name}: outcome {self.meta.get('outcome')!r}")
        # One row per trace request, matched by index, tenant and scheduled offset: nothing missing, doubled or extra.
        if len(self.rows) != len(self.trace):
            raise Unscorable(f"cell {self.name}: {len(self.rows)} rows for {len(self.trace)} trace requests")
        by_index = {}
        for row in self.rows:
            if row.get("index") in by_index:
                raise Unscorable(f"cell {self.name}: row index {row.get('index')} appears twice")
            by_index[row.get("index")] = row
        for t in self.trace:
            row = by_index.get(t["index"])
            if row is None or row.get("tenant") != t["tenant"] or row.get("scheduledOffsetMs") != t["offsetMs"]:
                raise Unscorable(f"cell {self.name}: trace request {t['index']} has no matching row")
        for row in self.rows:
            stamp = (row.get("study"), row.get("arm"), row.get("traceChecksum"))
            if stamp != (STUDY, self.arm, self.trace_sum):
                raise Unscorable(f"cell {self.name}: row {row.get('index')} is stamped {stamp}")
            if row.get("priority") is not None:
                raise Unscorable(f"cell {self.name}: row {row.get('index')} sent a client priority")
            if not row.get("replayOriginUnixNanos") or not row.get("sendUnixNanos"):
                raise Unscorable(f"cell {self.name}: row {row.get('index')} lacks its replay timing")
        s = self.sender
        if (s.get("study"), s.get("arm"), s.get("connMode"), s.get("maxIdleConnsPerHost"), s.get("timeoutMs")) != (
                STUDY, self.arm, "pooled", SENDER_POOL, TIMEOUT_NS // 1_000_000) or s.get("priorities"):
            raise Unscorable(f"cell {self.name}: sender configuration {s}")
        # Samples must cover the replay with no gap over 15 s, counting the replay's own start and end as edges.
        start = min(r["replayOriginUnixNanos"] for r in self.rows)
        end = max(r.get("returnedUnixNanos") or 0 for r in self.rows)
        times = sorted(x["t"] for x in self.samples if start <= x["t"] <= end)
        edges = [start] + times + [end]
        worst = max(b - a for a, b in zip(edges, edges[1:]))
        if worst > SAMPLE_GAP_NS:
            raise Unscorable(f"cell {self.name}: a {worst / 1e9:.1f} s gap between samples during the replay")
        self.window = (start, end)

    def preemptions(self) -> float:
        def total(prom):
            return sum(v for _, v in prom[PREEMPTIONS])
        return total(self.engine_after) - total(self.engine_before)

    def validity(self, identity_start: dict) -> list[str]:
        problems = []
        start, end = self.window
        during = [x for x in self.samples if start <= x["t"] <= end]
        first = during[0] if during else None
        for x in during:
            if x.get("statusMode") != self.arm or x.get("backendMode") != BACKEND_MODE[self.arm] or x.get("processMode") != "off":
                problems.append(f"a sample shows status {x.get('statusMode')!r}, backend {x.get('backendMode')!r}, process {x.get('processMode')!r}")
                break
            keys = ("engineUID", "engineRestarts", "gatewayUID", "gatewayRestarts")
            if first and any(x.get(k) != first.get(k) for k in keys):
                problems.append("the engine or gateway Pod changed during the replay")
                break
        if first and first.get("engineUID") != self.meta.get("enginePodUID"):
            problems.append("the sampled engine is not the cell's")
        has_cap = CAP_ARG in (self.meta.get("engineNonDefaultArgs") or "")
        if has_cap != (self.arm == "HoldCap"):
            problems.append(f"the cap is {'present' if has_cap else 'absent'} in the engine's non-default args")
        for row in self.rows:
            if row.get("httpStatus") == 200 and row.get("enginePriority", "") != PRIORITY[self.arm][row["tenant"]]:
                problems.append(f"row {row['index']} carries engine priority {row.get('enginePriority', '')!r}")
                break
        lags = [(row["tenant"], row["sendUnixNanos"] - scheduled(row)) for row in self.rows]
        if any(lag > DISPATCH_MAX_NS for _, lag in lags):
            problems.append("a request was dispatched more than 50 ms late")
        premium = [lag for tenant, lag in lags if tenant == PREMIUM]
        if sum(lag > DISPATCH_L_NS for lag in premium) > PREMIUM_OVER_L_MAX * len(premium):
            problems.append("more than 0.1% of premium requests were dispatched over 13 ms late")
        if self.identity != identity_start:
            problems.append("the frozen identity changed")
        return problems

    def premium_ttft_p99_ms(self) -> float:
        values = [(r["firstTokenUnixNanos"] - scheduled(r)) / 1e6 if succeeded(r) else math.inf
                  for r in self.rows if r["tenant"] == PREMIUM]
        return nearest_rank(values, 0.99)

    def premium_loss(self) -> float:
        premium = [r for r in self.rows if r["tenant"] == PREMIUM]
        return sum(not succeeded(r) for r in premium) / len(premium)

    def contender(self) -> tuple[float, float, float]:
        """(completion, p50 ms, p95 ms), failures at +inf."""
        lat = []
        for r in self.rows:
            if r["tenant"] != CONTENDER:
                continue
            if succeeded(r):
                gaps = r["contentGapsMicros"]
                end = r["firstTokenUnixNanos"] + (sum(gaps) + len(gaps)) * 1000
                latency = end - scheduled(r)
                lat.append(latency / 1e6 if latency <= TIMEOUT_NS else math.inf)
            else:
                lat.append(math.inf)
        done = sum(not math.isinf(x) for x in lat) / len(lat)
        return done, nearest_rank(lat, 0.5), nearest_rank(lat, 0.95)

    def premium_gap_p99_us(self) -> float:
        gaps = [g for r in self.rows if r["tenant"] == PREMIUM and succeeded(r) for g in r["contentGapsMicros"]]
        return nearest_rank(gaps, 0.99)

    def refusals(self) -> int:
        return sum(refused(r) for r in self.rows)


def off_validity(off: Cell) -> list[str]:
    problems = []
    if off.premium_loss() >= PREMIUM_LOSS_MAX:
        problems.append(f"Off premium loss {off.premium_loss():.4f}")
    done, p50, p95 = off.contender()
    if done < OFF_COMPLETION_MIN:
        problems.append(f"Off contender completion {done:.3f}")
    if any(math.isinf(v) for v in (off.premium_ttft_p99_ms(), p50, p95)) or off.premium_gap_p99_us() <= 0:
        problems.append("an Off denominator is not finite and positive")
    return problems


def acceptance(off: Cell, hc: Cell) -> list[tuple[str, bool, str]]:
    ttft_ratio = hc.premium_ttft_p99_ms() / off.premium_ttft_p99_ms()
    done, p50, p95 = hc.contender()
    _, off_p50, _ = off.contender()
    gap_ratio = hc.premium_gap_p99_us() / off.premium_gap_p99_us()
    return [
        ("1 premium TTFT p99 ratio", ttft_ratio <= TTFT_RATIO_MAX,
         f"{hc.premium_ttft_p99_ms():.1f} / {off.premium_ttft_p99_ms():.1f} ms = {ttft_ratio:.3f}"),
        ("2 contender completion", done >= COMPLETION_MIN, f"{done:.4f}"),
        ("3 contender p50 ratio and p95", p50 <= P50_RATIO_MAX * off_p50 and p95 <= P95_MAX_MS,
         f"p50 {p50:.0f} against {off_p50:.0f} ms, p95 {p95:.0f} ms"),
        ("4 refusals", hc.refusals() == 0, f"{hc.refusals()}"),
        ("5 premium content-event gap p99 ratio", gap_ratio <= GAP_RATIO_MAX,
         f"{hc.premium_gap_p99_us():.0f} / {off.premium_gap_p99_us():.0f} us = {gap_ratio:.3f}"),
        ("6 preemptions", hc.preemptions() == 0, f"{hc.preemptions():.0f}"),
    ]


def score(run: str, trace_dir: str = DEFAULT_TRACES) -> tuple[str, list[str]]:
    lines: list[str] = []
    try:
        identity_start = read_json(os.path.join(run, "identity-start.json"))
    except Unscorable as exc:
        return "inconclusive", [f"no starting identity: {exc}"]
    # Exactly the registered cells, each once, in the registered order; anything else is an attempt the run kept.
    present = sorted(os.listdir(os.path.join(run, "cells"))) if os.path.isdir(os.path.join(run, "cells")) else []
    expected = [cell_name(s, a) for s in SEEDS for a in registered_order(s)]
    extra = sorted(set(present) - set(expected))
    if extra:
        return "inconclusive", [f"cells outside the registration: {extra}"]

    cells: dict[str, Cell] = {}
    unscorable: dict[str, str] = {}
    for seed in SEEDS:
        for arm in ARMS:
            try:
                cells[cell_name(seed, arm)] = Cell(run, seed, arm, trace_dir)
            except Unscorable as exc:
                unscorable[cell_name(seed, arm)] = str(exc)
    started = sorted((c.meta.get("startedUnixNanos", 0), name) for name, c in cells.items())
    if [n for _, n in started] != [n for n in expected if n in cells]:
        return "inconclusive", [f"cells ran in the order {[n for _, n in started]}, not the registered {expected}"]

    # 1. Direct harms in a HoldCap cell with complete evidence count whatever any comparison's validity.
    for seed in SEEDS:
        hc = cells.get(cell_name(seed, "HoldCap"))
        if hc and (hc.refusals() or hc.preemptions()):
            lines.append(f"block {seed}: {hc.refusals()} refusal(s), {hc.preemptions():.0f} preemption(s) under HoldCap")
            return "not met", lines

    # 2. Any unscorable or invalid block makes the study inconclusive.
    problems = []
    for seed in SEEDS:
        off, hc = cells.get(cell_name(seed, "Off")), cells.get(cell_name(seed, "HoldCap"))
        for arm in ARMS:
            if cell_name(seed, arm) in unscorable:
                problems.append(f"block {seed} {arm} unscorable: {unscorable[cell_name(seed, arm)]}")
        if off and hc:
            try:
                for c in (off, hc):
                    for p in c.validity(identity_start):
                        problems.append(f"block {seed} {c.arm} invalid: {p}")
                for p in off_validity(off):
                    problems.append(f"block {seed} invalid: {p}")
            except Unscorable as exc:
                problems.append(f"block {seed} unscorable: {exc}")
    if problems:
        return "inconclusive", problems

    # 3. Comparative lines, block by block.
    failed = None
    for seed in SEEDS:
        for label, ok, detail in acceptance(cells[cell_name(seed, "Off")], cells[cell_name(seed, "HoldCap")]):
            lines.append(f"block {seed} {'ok ' if ok else 'BAD'} {label}: {detail}")
            if not ok and failed is None:
                failed = f"block {seed}, line {label}"
    if failed:
        return "not met", [f"first failing: {failed}"] + lines
    return "observed on these traces", lines


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != "--traces"):
        print(__doc__)
        return 2
    verdict, lines = score(argv[1], argv[3] if len(argv) == 4 else DEFAULT_TRACES)
    print(f"verdict: {verdict}")
    for line in lines:
        print(f"  {line}")
    return 0 if verdict == "observed on these traces" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Judges the precise prefix-cache hunt from the probe's records.

    verdict.py <probe dir>

The probe dir holds meta.json (the plan's seed and repetitions), requests.jsonl (one row per request, the router's
predictions taken before it was sent and vLLM's usage after), events.jsonl (every KV-event batch each replica
published, as an independent subscriber received it) and end.json (the routers' counters at the end).
It prints key=value lines and then one table row per measured request.

A hypothesis is called confirmed or refuted only when every row the plan measures for it is present and sound, the
engine is shown to have behaved as the hypothesis assumes, and the trigger is shown to have happened.
Anything short of that makes it void.
Three gates come first, and a failed gate voids every hypothesis:
the event stream must be whole (every pod's sequence numbers consecutive, and both routers' subscribers received
exactly the batches the independent subscriber did), the engine must have used one block size, and calibration (an
aligned shared prefix) must agree on every side.
"""
import json
import os
import statistics
import sys
from collections import defaultdict

DEDUP_PREFIX = 1024
ROUTERS = ("r16", "r64")
# The measured rows the plan has per repetition, as hypothesis/case/phase.
EXPECTED = (
    ["calib/shared512/probe"]
    + [f"bias/shared{n}/probe" for n in (528, 544, 560)]
    + [f"bias/repeat{n}/probe" for n in (512, 576, 600)]
    + ["salt/salted512/probe", "mm/image/probe"]
    + [f"dedup/{c}/{p}" for c in ("full", "incremental") for p in ("pre", "check", "post")]
)


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def pred(row, router, pod="a"):
    return row.get("predictions", {}).get(router, {}).get(pod, {}).get("cached_tokens", -1)


def key(r):
    return f"{r['hyp']}/{r['case']}/{r['phase']}"


def row_ok(row):
    """A row counts only if both routers predicted it, and, if it was sent, it was served, vLLM reported its cached tokens, and both sides counted the same prompt."""
    if row.get("error"):
        return False, f"failed: {row['error'][:120]}"
    if any(pred(row, r) < 0 or pred(row, r, "b") < 0 for r in ROUTERS):
        return False, "a router made no prediction"
    if any(pred(row, r, "b") != 0 for r in ROUTERS):
        return False, f"pod b, which serves nothing, was predicted to hold {pred(row, 'r16', 'b')}/{pred(row, 'r64', 'b')} tokens"
    if row.get("no_send"):
        return True, ""
    if row.get("status") != 200 or row.get("realized_cached_tokens", -1) < 0:
        return False, f"not served: status={row.get('status')} realized={row.get('realized_cached_tokens')}"
    if row.get("router_prompt_tokens") != row.get("engine_prompt_tokens"):
        return False, f"token parity: router {row.get('router_prompt_tokens')} engine {row.get('engine_prompt_tokens')}"
    return True, ""


def stream_whole(events, end, start):
    """Every pod's batches arrived in order with no gap, decoded, and each router's subscriber received as many as the tap."""
    seqs = defaultdict(list)
    for line in events:
        if line.get("decode_error"):
            return False, f"pod {line.get('pod')} seq {line.get('seq')}: {line['decode_error'][:100]}"
        if any(ev.get("type") == "AllBlocksCleared" for ev in line.get("events") or []):
            return False, f"pod {line.get('pod')} cleared its whole cache at seq {line.get('seq')}"
        seqs[line["pod"]].append(line["seq"])
    for pod, s in seqs.items():
        if s != list(range(s[0], s[0] + len(s))):
            return False, f"pod {pod}: event sequence numbers are not consecutive"
    metrics = (end or {}).get("router_metrics", {})
    for pod, s in seqs.items():
        got = [v - start.get(k, 0) for k, v in metrics.items() if "messages_received" in k and f"pod_identifier=hunt/{pod}" in k]
        # Both routers' subscribers add to one counter, so a whole stream is twice what the tap saw.
        if got != [2 * len(s)]:
            return False, f"pod {pod}: the routers received {got} batches, not twice the tap's {len(s)}"
    return True, f"{sum(len(s) for s in seqs.values())} batches, consecutive, and both routers received each"


def engine_block_size(events):
    sizes = defaultdict(int)
    for line in events:
        for ev in line.get("events") or []:
            if ev.get("type") == "BlockStored" and ev.get("block_size"):
                sizes[ev["block_size"]] += 1
    return dict(sizes)


def floor_to(n, b):
    return (n // b) * b


def inventory(rows, reps):
    """The measured rows by (rep, key), or the first planned row that is missing or repeated."""
    got = defaultdict(list)
    for r in rows:
        if r["measured"]:
            got[(r["rep"], key(r))].append(r)
    for rep in range(reps):
        for k in EXPECTED:
            if len(got.get((rep, k), [])) != 1:
                return None, f"rep {rep} {k}: {len(got.get((rep, k), []))} rows, want 1"
    return {k: v[0] for k, v in got.items()}, ""


def warm_len(rows, r):
    w = [x for x in rows if x["rep"] == r["rep"] and x["hyp"] == r["hyp"] and x["case"] == r["case"] and x["phase"] == "warm"]
    if len(w) != 1 or w[0].get("status") != 200 or w[0].get("engine_prompt_tokens", -1) <= 0:
        return None
    return w[0]["engine_prompt_tokens"]


def judge_calib(rows, inv, reps):
    for rep in range(reps):
        r = inv[(rep, "calib/shared512/probe")]
        ok, why = row_ok(r)
        if not ok:
            return "void", f"{r['id']}: {why}"
        want = r["shared_len"]
        got = (r["realized_cached_tokens"], pred(r, "r16"), pred(r, "r64"))
        if got != (want, want, want):
            return "fail", f"{r['id']}: realized, r16 and r64 were {got}, want all {want}"
    return "pass", f"{reps} rows agree"


def judge_bias(rows, inv, reps, e):
    """H1: the router credits tokens the engine cannot serve.

    Component (a): a shared prefix ending inside an engine block is credited at router block 16.
    Component (b): a whole-prompt hit at an aligned length is credited in full even at router block e.
    Every row must match the block-rule model exactly on both sides, so a lag or a different mechanism cannot pass as either component.
    """
    shared = ["bias/shared528/probe", "bias/shared544/probe", "bias/shared560/probe"]
    repeats = ["bias/repeat512/probe", "bias/repeat576/probe", "bias/repeat600/probe"]
    a = b = 0
    n = 0
    for rep in range(reps):
        for k in shared + repeats:
            r = inv[(rep, k)]
            ok, why = row_ok(r)
            if not ok:
                return "void", f"{r['id']}: {why}"
            length, warm = r["engine_prompt_tokens"], warm_len(rows, r)
            if warm is None:
                return "void", f"{r['id']}: its warm request was not served"
            # vLLM serves at most the prompt minus its last token, floored to its block size, of what the warm request cached.
            cached_by_warm = floor_to(warm, e)
            realized = floor_to(min(r["shared_len"], length - 1, cached_by_warm), e)
            if r["realized_cached_tokens"] != realized:
                return "void", f"{r['id']}: the engine served {r['realized_cached_tokens']}, not the {realized} its block rule gives"
            # A router either agrees with the engine, which refutes the row, or predicts what its index model gives, which is the hypothesis; anything else is neither.
            for name, bs in (("r16", 16), ("r64", 64)):
                model = floor_to(min(r["shared_len"], length, cached_by_warm), bs)
                if pred(r, name) not in (realized, model):
                    return "void", f"{r['id']}: {name} predicted {pred(r, name)}, neither the {realized} served nor the {model} the index model gives"
            n += 1
            if k in shared and pred(r, "r16") > realized:
                a += 1
            if k in repeats and pred(r, "r64") > realized:
                b += 1
    if a == 0 and b == 0:
        return "refuted", f"all {n} rows predicted what the engine served"
    if a == 0 or b == 0:
        return "partial", f"component (a) over-predicted in {a} rows, component (b) in {b}"
    return "confirmed", (f"{n} rows match the engine's block rule and the index model; (a) router 16 over-credited a prefix ending inside an engine block in {a} rows; "
                         f"(b) a whole-prompt hit was over-credited even at router block {e} in {b} rows")


def family_wire(events, prefix, pod_name, upto_seq, e):
    """The prefix's engine blocks on pod's wire up to a sequence number: stores and removals per hash, and each removal's sequence."""
    stores, removes, removed_at = defaultdict(int), defaultdict(int), defaultdict(list)
    order = []
    parented = 0
    for line in events:
        if line.get("pod") != pod_name or line["seq"] > upto_seq:
            continue
        for ev in line.get("events") or []:
            if ev.get("type") == "BlockStored":
                toks, hs, bs = ev.get("tokens") or [], ev.get("block_hashes") or [], ev.get("block_size") or 0
                if not toks or bs != e:
                    continue
                head = toks[: min(len(toks), len(prefix))]
                if ev.get("parent_hash", 0) == 0 and head == prefix[: len(head)]:
                    for i, h in enumerate(hs):
                        if (i + 1) * bs <= len(prefix):
                            if h not in stores:
                                order.append(h)
                            stores[h] += 1
                elif ev.get("parent_hash", 0) in stores:
                    # No planned request extends the prefix by a whole block before the check, so a store chained to one of its blocks is something this join does not account for.
                    parented += 1
            elif ev.get("type") == "BlockRemoved":
                for h in ev.get("block_hashes") or []:
                    removes[h] += 1
                    removed_at[h].append(line["seq"])
    return order, stores, {h: removes[h] for h in order}, removed_at, parented


def judge_dedup(rows, inv, reps, events, e):
    """H2: reused-block reports raise the dedup count, so the engine's one removal is suppressed and the index keeps the evicted prefix."""
    detail = []
    stale = clean = 0
    want_blocks = DEDUP_PREFIX // e
    for rep in range(reps):
        got = {k.split("/", 1)[1]: inv[(rep, k)] for k in EXPECTED if k.startswith("dedup/")}
        for r in got.values():
            ok, why = row_ok(r)
            if not ok:
                return "void", f"{r['id']}: {why}", detail
        warm = {c: [x for x in rows if x["rep"] == rep and x["hyp"] == "dedup" and x["case"] == c and x["phase"] == "warm"] for c in ("full", "incremental")}
        repeats = {c: [x for x in rows if x["rep"] == rep and x["hyp"] == "dedup" and x["case"] == c and x["phase"] == "repeat"] for c in ("full", "incremental")}
        fams = {}
        for c in ("full", "incremental"):
            pre, check, post = got[f"{c}/pre"], got[f"{c}/check"], got[f"{c}/post"]
            if len(warm[c]) != 1 or warm[c][0].get("status") != 200 or not warm[c][0].get("tokens"):
                return "void", f"rep {rep} {c}: the warm request was not served", detail
            # The trigger: every repeat must have been served from the cached prefix, or the reports it should have caused did not happen.
            if len(repeats[c]) != 3 or any(x.get("status") != 200 or x.get("realized_cached_tokens") != DEDUP_PREFIX for x in repeats[c]):
                return "void", f"rep {rep} {c}: not every repeat was a {DEDUP_PREFIX}-token hit", detail
            if pre["realized_cached_tokens"] != DEDUP_PREFIX or pred(pre, "r16") != DEDUP_PREFIX or pred(pre, "r64") != DEDUP_PREFIX:
                return "void", f"{pre['id']}: before the flood the prefix was not served and predicted in full", detail
            if post["realized_cached_tokens"] != 0:
                return "void", f"{post['id']}: the engine still served {post['realized_cached_tokens']} tokens, so the flood did not evict the prefix", detail
            prefix = warm[c][0]["tokens"][:DEDUP_PREFIX]
            order, stores, removes, removed_at, parented = family_wire(events, prefix, "a", check["tap_seq_at_prediction"].get("a", -1), e)
            if len(order) != want_blocks:
                return "void", f"{check['id']}: the wire names {len(order)} of the prefix's {want_blocks} engine blocks", detail
            if parented:
                return "void", f"{check['id']}: {parented} parented stores continue the prefix, which this join does not count", detail
            want_stores = 1 + (3 if c == "full" else 0)
            if any(stores[h] != want_stores for h in order):
                return "void", (f"{check['id']}: stores per block were {sorted(set(stores[h] for h in order))}, want {want_stores}; "
                                f"{'the engine did not send its reused-block reports' if c == 'full' else 'the control was announced more than once'}"), detail
            if any(removes[h] != 1 for h in order):
                return "void", f"{check['id']}: removals per block before the prediction were {sorted(set(removes.values()))}, want 1", detail
            fams[c] = (order, removed_at, check, post)
            detail.append(f"rep{rep} {c}: {len(order)} engine blocks, {want_stores} store(s) and 1 removal per block before the check; "
                          f"check predicted r16={pred(check, 'r16')} r64={pred(check, 'r64')}; post-flood realized={post['realized_cached_tokens']}")
        full_order, full_removed, full_check, full_post = fams["full"]
        inc_order, inc_removed, inc_check, _ = fams["incremental"]
        if pred(inc_check, "r16") != 0 or pred(inc_check, "r64") != 0:
            return "void", f"{inc_check['id']}: the control kept {pred(inc_check, 'r16')}/{pred(inc_check, 'r64')} tokens after its removals", detail
        # The barrier holds only for a reported-prefix check taken after the control's.
        if not inc_check["predicted_unix_nanos"] < full_check["predicted_unix_nanos"]:
            return "void", f"{full_check['id']}: predicted before the control's check, so the control proves nothing about what its index had processed", detail
        # The control's check was predicted at 0, so each router had processed the removal of its first block.
        # One pod's events are processed in order, so every removal published before that one had been processed too.
        barrier = inc_removed[inc_order[0]][0]
        late = [h for h in full_order if full_removed[h][0] > barrier]
        if late:
            return "void", f"{full_check['id']}: {len(late)} of the reported prefix's removals came after the control's first, so its check may have read an index that had not seen them", detail
        if pred(full_check, "r16") == DEDUP_PREFIX and pred(full_check, "r64") == DEDUP_PREFIX:
            stale += 1
        elif pred(full_check, "r16") == 0 and pred(full_check, "r64") == 0:
            clean += 1
        else:
            return "void", f"{full_check['id']}: partly stale ({pred(full_check, 'r16')}/{pred(full_check, 'r64')})", detail
    if stale == reps:
        return "confirmed", f"in all {reps} repetitions the reported prefix stayed predicted in full after every block's one removal, and the control did not", detail
    if clean == reps:
        return "refuted", f"in all {reps} repetitions the reported prefix left the index with its removals, although every report was sent", detail
    return "mixed", f"stale in {stale} of {reps} repetitions", detail


def judge_control(inv, reps, hyp, k):
    """The known llm-d-router #3788: with router block 16 under engine block 64, salted and multimodal prompts match only up to their first tagged sub-block."""
    n = 0
    for rep in range(reps):
        r = inv[(rep, k)]
        ok, why = row_ok(r)
        if not ok:
            return "void", f"{r['id']}: {why}"
        if r["realized_cached_tokens"] <= 0:
            return "void", f"{r['id']}: the engine served nothing, so there was nothing to mispredict"
        if pred(r, "r16") < r["realized_cached_tokens"] and pred(r, "r64") == r["realized_cached_tokens"]:
            n += 1
    if n == reps:
        return "reproduced", f"{n} rows: router 16 under-predicted and router 64 matched"
    return "not-reproduced", f"{n} of {reps} rows"


def ttft(rows, sel):
    v = [r["ttft_ms"] for r in rows if sel(r) and r.get("ttft_ms", 0) > 0 and not r.get("error")]
    return (round(statistics.median(v), 1), len(v)) if v else (None, 0)


def main():
    d = sys.argv[1]
    meta = json.load(open(f"{d}/meta.json"))
    end = json.load(open(f"{d}/end.json")) if os.path.exists(f"{d}/end.json") else None
    rows = load(f"{d}/requests.jsonl")
    events = load(f"{d}/events.jsonl")
    reps = meta["reps"]
    sizes = engine_block_size(events)
    print(f"engine_block_sizes={json.dumps(sizes, sort_keys=True)}")
    print(f"rows={len(rows)} measured={sum(1 for r in rows if r['measured'])} event_batches={len(events)} reps={reps}")
    gate = []
    whole, why = stream_whole(events, end, meta.get("router_metrics_start") or {})
    print(f"stream_whole={'yes' if whole else 'no'}")
    print(f"stream_why={why}")
    if not whole:
        gate.append(why)
    if len(sizes) != 1:
        gate.append(f"the engine announced block sizes {sizes}, not one")
    inv, why = inventory(rows, reps)
    if inv is None:
        gate.append(why)
    calib = "void"
    if not gate:
        calib, why = judge_calib(rows, inv, reps)
        print(f"calib_why={why}")
        if calib != "pass":
            gate.append(f"calibration {calib}")
    print(f"calib_verdict={calib}")
    if gate:
        print(f"why_void={'; '.join(gate)}")
        for h in ("bias", "dedup", "salt", "mm"):
            print(f"{h}_verdict=void")
    else:
        e = next(iter(sizes))
        v, w = judge_bias(rows, inv, reps, e)
        print(f"bias_verdict={v}")
        print(f"bias_why={w}")
        v, w, detail = judge_dedup(rows, inv, reps, events, e)
        print(f"dedup_verdict={v}")
        print(f"dedup_why={w}")
        for line in detail:
            print(f"dedup_detail={line}")
        for h, k in (("salt", "salt/salted512/probe"), ("mm", "mm/image/probe")):
            v, w = judge_control(inv, reps, h, k)
            print(f"{h}_verdict={v}")
            print(f"{h}_why={w}")
    hit = ttft(rows, lambda r: r["hyp"] == "dedup" and r["phase"] == "pre")
    miss = ttft(rows, lambda r: r["hyp"] == "dedup" and r["phase"] == "post")
    print(f"ttft_ms_hit_median={hit[0]} n={hit[1]}")
    print(f"ttft_ms_miss_median={miss[0]} n={miss[1]}")
    print("# id | pod | prompt router/engine | realized | r16 a/b | r64 a/b | ttft_ms | error")
    for r in rows:
        if r["measured"]:
            print(f"# {r['id']} | {r['pod']} | {r.get('router_prompt_tokens')}/{r.get('engine_prompt_tokens')} | {r.get('realized_cached_tokens')} | "
                  f"{pred(r, 'r16')}/{pred(r, 'r16', 'b')} | {pred(r, 'r64')}/{pred(r, 'r64', 'b')} | {r.get('ttft_ms')} | {r.get('error', '')[:80]}")


if __name__ == "__main__":
    main()

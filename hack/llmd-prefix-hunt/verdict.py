#!/usr/bin/env python3
"""Judges the precise prefix-cache hunt from the probe's records.

    verdict.py <probe dir>

The probe dir holds requests.jsonl (one row per request, the router's predictions taken before it was sent and vLLM's
usage after) and events.jsonl (every KV-event batch each replica published).
It prints key=value lines and then one table row per measured request.

A hypothesis is called confirmed only when the rows show it and the engine is shown to have behaved as the hypothesis
assumes; a row that failed, or an engine that did not behave so, makes it void, never confirmed or refuted.
Calibration gates everything: if the router and the engine disagree on an aligned shared prefix, nothing else is judged.
"""
import json
import statistics
import sys
from collections import defaultdict

DEDUP_PREFIX = 1024


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def pred(row, router, pod="a"):
    return row.get("predictions", {}).get(router, {}).get(pod, {}).get("cached_tokens", -1)


def row_ok(row):
    """A row counts only if it was served, vLLM reported its cached tokens, and both sides counted the same prompt."""
    if row.get("error") or row.get("status") != 200 or row.get("realized_cached_tokens", -1) < 0:
        return False, f"failed: status={row.get('status')} error={row.get('error', '')[:120]}"
    if row.get("router_prompt_tokens") != row.get("engine_prompt_tokens"):
        return False, f"token parity: router {row.get('router_prompt_tokens')} engine {row.get('engine_prompt_tokens')}"
    if not row.get("predictions"):
        return False, "no prediction"
    return True, ""


def engine_block_size(events):
    sizes = defaultdict(int)
    for line in events:
        for ev in line.get("events") or []:
            if ev.get("type") == "BlockStored" and ev.get("block_size"):
                sizes[ev["block_size"]] += 1
    return dict(sizes)


def floor_to(n, b):
    return (n // b) * b


def judge_calib(rows, out):
    probes = [r for r in rows if r["hyp"] == "calib" and r["measured"]]
    if not probes:
        return "void", "no calibration rows"
    for r in probes:
        ok, why = row_ok(r)
        if not ok:
            return "void", f"{r['id']}: {why}"
        want = r["shared_len"]
        got = (r["realized_cached_tokens"], pred(r, "r16"), pred(r, "r64"), pred(r, "r16", "b"), pred(r, "r64", "b"))
        if got != (want, want, want, 0, 0):
            return "fail", f"{r['id']}: realized, r16, r64 on a and r16, r64 on b were {got}, want ({want}, {want}, {want}, 0, 0)"
    return "pass", f"{len(probes)} rows agree"


def judge_bias(rows, e):
    """H1: the router credits tokens the engine cannot serve: a prefix ending inside an engine block, and a whole-prompt hit's last block."""
    probes = [r for r in rows if r["hyp"] == "bias" and r["measured"]]
    if not probes:
        return "void", "no rows"
    over = 0
    over_r64_repeat = 0
    for r in probes:
        ok, why = row_ok(r)
        if not ok:
            return "void", f"{r['id']}: {why}"
        n = r["engine_prompt_tokens"]
        # vLLM serves at most the prompt minus its last token, floored to its block size.
        expect = floor_to(min(r["shared_len"], n - 1), e)
        if r["realized_cached_tokens"] != expect:
            return "void", f"{r['id']}: the engine served {r['realized_cached_tokens']}, not the {expect} its block rule gives"
        if pred(r, "r16") < r["realized_cached_tokens"] or pred(r, "r64") < r["realized_cached_tokens"]:
            return "void", f"{r['id']}: a router under-predicted ({pred(r, 'r16')}, {pred(r, 'r64')} < {r['realized_cached_tokens']}), which is not this hypothesis"
        if pred(r, "r16") > r["realized_cached_tokens"]:
            over += 1
        if r["case"].startswith("repeat") and pred(r, "r64") > r["realized_cached_tokens"]:
            over_r64_repeat += 1
    if over == 0:
        return "refuted", f"all {len(probes)} rows predicted what the engine served"
    if over_r64_repeat == 0:
        return "partial", f"{over} of {len(probes)} rows over-predicted at router block 16, none at router block {e} on a whole-prompt hit"
    return "confirmed", f"{over} of {len(probes)} rows over-predicted at router block 16; {over_r64_repeat} whole-prompt hits over-predicted even at router block {e}"


def family_hashes(events, prefix, pod_name, before):
    """Engine hashes pod announced for a prefix, with store and removal counts on the wire before a time."""
    stores, removes = defaultdict(int), defaultdict(int)
    mine = set()
    n = len(prefix)
    for line in events:
        if line.get("pod") != pod_name or line["unix_nanos"] >= before:
            continue
        for ev in line.get("events") or []:
            if ev.get("type") == "BlockStored":
                toks, hs, bs = ev.get("tokens") or [], ev.get("block_hashes") or [], ev.get("block_size") or 0
                # A store whose tokens start at the prompt's first token names that prefix's blocks; a reused-block report has no parent and so does too.
                if ev.get("parent_hash", 0) == 0 and toks and bs and toks[: min(len(toks), n)] == prefix[: min(len(toks), n)]:
                    for i, h in enumerate(hs):
                        if (i + 1) * bs <= n:
                            mine.add(h)
                            stores[h] += 1
            elif ev.get("type") == "BlockRemoved":
                for h in ev.get("block_hashes") or []:
                    removes[h] += 1
    return mine, {h: stores[h] for h in mine}, {h: removes[h] for h in mine}


def judge_dedup(rows, events):
    """H2: reused-block reports raise the dedup count, so the engine's one removal is suppressed and the index keeps the evicted prefix."""
    by = defaultdict(dict)
    warm = {}
    for r in rows:
        if r["hyp"] != "dedup":
            continue
        if r["phase"] == "warm":
            warm[(r["rep"], r["case"])] = r
        if r["measured"]:
            by[r["rep"]][(r["case"], r["phase"])] = r
    if not by:
        return "void", "no rows", []
    detail = []
    stale = 0
    for rep, got in sorted(by.items()):
        need = [("full", "pre"), ("incremental", "pre"), ("full", "post"), ("incremental", "post")]
        if any(k not in got for k in need):
            return "void", f"rep {rep}: missing rows", detail
        for k in need:
            ok, why = row_ok(got[k])
            if not ok:
                return "void", f"{got[k]['id']}: {why}", detail
        for c in ("full", "incremental"):
            pre, post = got[(c, "pre")], got[(c, "post")]
            if pre["realized_cached_tokens"] != DEDUP_PREFIX or pred(pre, "r16") != DEDUP_PREFIX:
                return "void", f"{pre['id']}: before the flood the prefix was not served and predicted in full ({pre['realized_cached_tokens']}, {pred(pre, 'r16')})", detail
            if post["realized_cached_tokens"] != 0:
                return "void", f"{post['id']}: the engine still served {post['realized_cached_tokens']} tokens, so the flood did not evict the prefix", detail
            w = warm.get((rep, c))
            if not w or not w.get("tokens"):
                return "void", f"rep {rep} {c}: no warm row with tokens", detail
            hashes, stores, removes = family_hashes(events, w["tokens"][:DEDUP_PREFIX], "a", post["sent_unix_nanos"])
            if not hashes:
                return "void", f"{post['id']}: no BlockStored on the wire names the prefix", detail
            unremoved = [h for h in hashes if removes[h] == 0]
            if unremoved:
                return "void", f"{post['id']}: {len(unremoved)} of the prefix's {len(hashes)} engine blocks were never removed on the wire", detail
            detail.append(f"rep{rep} {c}: {len(hashes)} engine blocks, stores per block {sorted(set(stores.values()))}, removals per block {sorted(set(removes.values()))}, "
                          f"post-eviction predicted r16={pred(post, 'r16')} r64={pred(post, 'r64')} realized={post['realized_cached_tokens']}")
        full_post, inc_post = got[("full", "post")], got[("incremental", "post")]
        if pred(inc_post, "r16") != 0 or pred(inc_post, "r64") != 0:
            return "void", f"{inc_post['id']}: the control kept {pred(inc_post, 'r16')}/{pred(inc_post, 'r64')} tokens after its removals, so something other than the reports is stale", detail
        if pred(full_post, "r16") == DEDUP_PREFIX and pred(full_post, "r64") == DEDUP_PREFIX:
            stale += 1
        elif pred(full_post, "r16") != 0 or pred(full_post, "r64") != 0:
            return "void", f"{full_post['id']}: partly stale ({pred(full_post, 'r16')}/{pred(full_post, 'r64')})", detail
    if stale == len(by):
        return "confirmed", f"in all {stale} repetitions the reported prefix stayed predicted in full after every block's removal, and the control did not", detail
    if stale == 0:
        return "refuted", f"in all {len(by)} repetitions the reported prefix left the index with its removals", detail
    return "mixed", f"stale in {stale} of {len(by)} repetitions", detail


def judge_control(rows, hyp):
    """The known llm-d-router #3788: with router block 16 under engine block 64, salted and multimodal prompts match only up to their first tagged sub-block."""
    probes = [r for r in rows if r["hyp"] == hyp and r["measured"]]
    if not probes:
        return "void", "no rows"
    n = 0
    for r in probes:
        ok, why = row_ok(r)
        if not ok:
            return "void", f"{r['id']}: {why}"
        if r["realized_cached_tokens"] <= 0:
            return "void", f"{r['id']}: the engine served nothing, so there was nothing to mispredict"
        if pred(r, "r16") < r["realized_cached_tokens"] and pred(r, "r64") == r["realized_cached_tokens"]:
            n += 1
    if n == len(probes):
        return "reproduced", f"{n} rows: router 16 under-predicted and router 64 matched"
    return "not-reproduced", f"{n} of {len(probes)} rows"


def ttft(rows, sel):
    v = [r["ttft_ms"] for r in rows if sel(r) and r.get("ttft_ms", 0) > 0 and not r.get("error")]
    return (round(statistics.median(v), 1), len(v)) if v else (None, 0)


def main():
    d = sys.argv[1]
    rows = load(f"{d}/requests.jsonl")
    events = load(f"{d}/events.jsonl")
    sizes = engine_block_size(events)
    print(f"engine_block_sizes={json.dumps(sizes, sort_keys=True)}")
    print(f"rows={len(rows)} measured={sum(1 for r in rows if r['measured'])} event_batches={len(events)}")
    calib, why = judge_calib(rows, sys.stdout)
    print(f"calib_verdict={calib}")
    print(f"calib_why={why}")
    if calib != "pass" or len(sizes) != 1:
        if len(sizes) != 1:
            print(f"why_void=the engine announced block sizes {sizes}, not one")
        for h in ("bias", "dedup", "salt", "mm"):
            print(f"{h}_verdict=void")
    else:
        e = next(iter(sizes))
        for h, (v, w) in (("bias", judge_bias(rows, e)),):
            print(f"{h}_verdict={v}")
            print(f"{h}_why={w}")
        v, w, detail = judge_dedup(rows, events)
        print(f"dedup_verdict={v}")
        print(f"dedup_why={w}")
        for line in detail:
            print(f"dedup_detail={line}")
        for h in ("salt", "mm"):
            v, w = judge_control(rows, h)
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

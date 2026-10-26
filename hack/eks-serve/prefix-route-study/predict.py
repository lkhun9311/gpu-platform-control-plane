"""Predicts each arm's prefix-cache hit ratio on the frozen traces with a token-level LRU model of two engines.

    python3 hack/eks-serve/prefix-route-study/predict.py <trace.jsonl>... [--fold-groups K]

This is a prediction, not a measurement and not a bar. It models what routing can change, which prefixes each engine
keeps, and nothing else:

- each request is its prompt's tokens at 5.198 characters a token (40,000 / 7,695, tokenizer_calibration.json) plus
  25 tokens of chat template shared by every request, in 16-token blocks, as the engine's block_size;
- each engine holds 393,232 tokens of blocks (the measured kv_cache_size_tokens), evicting the least recently used,
  and keeps every block of a request once it is computed, its 64 output tokens included;
- it has no clock: running requests' blocks are not held apart from the cache, nothing queues, and so LeastQueue,
  which decides on outstanding requests, cannot be modelled and is printed as RoundRobin's alternation;
- PrefixAffinity sends a prompt where it last sent it, and a new prompt to the engine that has seen fewer requests,
  the gateway's rule without its load escape.

--fold-groups K maps prompt g to 1 + (g - 1) mod K, to ask what the same arrivals would do with only K prompts.
"""

from __future__ import annotations

import collections
import json
import sys

CHARS_PER_TOKEN = 40000 / 7695
TEMPLATE_TOKENS = 25
BLOCK = 16
CAPACITY_TOKENS = 393_232
OUTPUT_TOKENS = 64


def blocks_of(row: dict, fold: int | None) -> list[tuple]:
    group = row["prefixGroup"]
    if fold:
        group = 1 + (group - 1) % fold
    prefix_tokens = int(row["prefixChars"] / CHARS_PER_TOKEN)
    own_tokens = int((row["promptLenChars"] - row["prefixChars"]) / CHARS_PER_TOKEN)
    template = [("template", i) for i in range(TEMPLATE_TOKENS // BLOCK)]
    if row.get("prefixControl"):
        # The request's own header comes first, so nothing after the template is shared.
        own = [("req", row["index"], i) for i in range((prefix_tokens + own_tokens) // BLOCK)]
        return template + own
    prefix = [("prefix", group, i) for i in range(prefix_tokens // BLOCK)]
    own = [("req", row["index"], i) for i in range(own_tokens // BLOCK)]
    return template + prefix + own


def simulate(rows: list[dict], policy: str, fold: int | None) -> float:
    caches = [collections.OrderedDict(), collections.OrderedDict()]
    cap = CAPACITY_TOKENS // BLOCK
    where: dict = {}
    sent = [0, 0]
    turn = 0
    queried = hit = 0
    for row in rows:
        chain = blocks_of(row, fold)
        if policy == "PrefixAffinity":
            key = (1 + (row["prefixGroup"] - 1) % fold if fold else row["prefixGroup"], bool(row.get("prefixControl")),
                   row["index"] if row.get("prefixControl") else None)
            engine = where.get(key)
            if engine is None:
                engine = 0 if sent[0] <= sent[1] else 1
            where[key] = engine
        else:
            engine = turn % 2
            turn += 1
        sent[engine] += 1
        cache = caches[engine]
        held = 0
        for b in chain:
            if b not in cache:
                break
            held += 1
        queried += len(chain) * BLOCK
        hit += held * BLOCK
        for b in chain + [("out", row["index"], i) for i in range(OUTPUT_TOKENS // BLOCK)]:
            cache[b] = True
            cache.move_to_end(b)
            while len(cache) > cap:
                cache.popitem(last=False)
    return hit / queried


def main(argv: list[str]) -> int:
    args = list(argv[1:])
    fold = None
    if "--fold-groups" in args:
        i = args.index("--fold-groups")
        fold = int(args[i + 1])
        del args[i:i + 2]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    for path in args:
        with open(path) as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
        rr = simulate(rows, "RoundRobin", fold)
        pa = simulate(rows, "PrefixAffinity", fold)
        print(f"{path}: {len(rows)} requests, predicted H RoundRobin {rr:.3f}, LeastQueue (as RoundRobin) {rr:.3f}, "
              f"PrefixAffinity {pa:.3f}, difference {pa - rr:+.3f}" + (f" (prompts folded to {fold})" if fold else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

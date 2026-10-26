"""The share bound of rule 5 for each frozen trace, and the exact probability chance placement stays inside it.

    python3 hack/eks-serve/prefix-route-study/share_coverage.py <trace.jsonl>...

Chance placement sends each prompt's requests, all of them, to one backend picked by a fair coin, independently per
prompt. The bound is 0.5 plus two standard deviations of one backend's share under that placement; the coverage is
the exact probability, by dynamic programming over the prompts' request counts, that neither backend's share exceeds
it. The registration calls the bound a two-standard-deviation convention, and this prints what it covers.
"""

from __future__ import annotations

import json
import math
import sys


def main(argv: list[str]) -> int:
    for path in argv[1:]:
        counts: dict[int, int] = {}
        with open(path) as handle:
            for line in handle:
                if line.strip():
                    g = json.loads(line)["prefixGroup"]
                    counts[g] = counts.get(g, 0) + 1
        n = sum(counts.values())
        bound = 0.5 + 2 * math.sqrt(sum(c * c for c in counts.values())) / (2 * n)
        # dist[k] is the probability that backend a receives exactly k requests.
        dist = [1.0] + [0.0] * n
        for c in counts.values():
            nxt = [0.0] * (n + 1)
            for k, p in enumerate(dist):
                if p:
                    nxt[k] += p / 2
                    nxt[k + c] += p / 2
            dist = nxt
        inside = sum(p for k, p in enumerate(dist) if k / n <= bound and (n - k) / n <= bound)
        print(f"{path}: {n} requests over {len(counts)} prompts, bound {bound:.4f}, chance placement inside it {inside:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

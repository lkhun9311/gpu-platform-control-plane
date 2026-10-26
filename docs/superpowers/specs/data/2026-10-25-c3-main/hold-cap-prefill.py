"""Hold-cap's engine prefill d per length and block, with its p95 and unfinished count, and the gateway's
admission-to-first-content beside it, which the registration publishes and headroom-main does not print.
Run from the repository root with the three blocks' archives in block order:
  python3 docs/superpowers/specs/data/2026-10-25-c3-main/hold-cap-prefill.py <block 1's m5c-run> <block 2's> <block 3's>
Both come from the scorer's own engine_prefill and admission_to_content, so each median is the d its rule 4 reads."""
import sys, math
sys.path.insert(0, "hack/prospective-pilot")
import pilot_report as p

for l in p.MAIN_LENGTHS:
    for b, d in enumerate(sys.argv[1:], start=1):
        tag = "hold-cap-%s-1" % l
        eng, mal = p.engine_prefill(d, tag)
        a2c, unt = p.admission_to_content(d, tag)
        print("%s block %d: d p50 %.1f p95 %.1f unfinished %d n %d malformed %d | adm->content p50 %.1f p95 %.1f timed %d untimed %d"
              % (l, b, p.nearest_rank(eng, .5), p.nearest_rank(eng, .95), sum(math.isinf(x) for x in eng), len(eng), mal,
                 p.nearest_rank(a2c, .5), p.nearest_rank(a2c, .95), len(a2c), unt))

#!/usr/bin/env bash
# FR-002b — the HEAD backend goes away and a second one absorbs the request.
#
# WHY THIS IS A SEPARATE EXPERIMENT FROM FR-002
#
# FR-002 kills the pod behind the only backend, so every failure reaches the client and
# backend_fallbacks_total stays 0. That is the correct reading of that run and it leaves the retry path
# completely unexercised — the counter existing and reading zero proves nothing about whether it can move.
#
# A "backend" here is an InferenceDeployment, not a pod. backendsFor lists every InferenceDeployment serving
# the model, oldest first, and the tail is what tryBackends walks. Adding pod replicas does NOT exercise
# this: that is Service load balancing, one list entry down. The first attempt at this experiment scaled
# replicas to 2 and would have measured nothing.
#
# The head is taken away by scaling it to zero rather than by deleting a pod. A deleted pod races with its
# replacement, so a fallback might or might not be needed on any given request; a head with no endpoints
# fails deterministically, every time, until it is scaled back.
#
# WHAT MUST BE TRUE FOR THE RESULT TO MEAN ANYTHING
#
#   before   two backends serve the model, requests succeed, fallbacks counter is at a known value
#   after    requests STILL succeed, and the fallback counter moved
#
# The second half alone is not enough. A gateway that failed every request would leave the counter at zero
# too, and a run that only checked "the counter moved" would pass a gateway that fell back on every single
# request including the healthy ones.
set -uo pipefail

NS=${NS:-gpu-platform-control-plane-system}
SERV=${SERV:-serving}
HEAD=${HEAD:-stub-llm}
SPARE=${SPARE:-stub-llm-spare}
GW=${GW:-localhost:8080}
PROM=${PROM:-localhost:9090}
KEY=${KEY:-premium-1}
MODEL=${MODEL:-demo-llm}
OUT=${OUT:-./ex/chaos-fr002b.json}
# The cluster this runs against, named rather than inherited.
#
# Every kubectl below used to run against whatever context happened to be current. On 2026-09-21 that was a
# destroyed EKS cluster, so every call failed at DNS and the first one reported "InferenceDeployment
# stub-llm does not exist" -- about a CR that was sitting Ready in the kind cluster one context away. A
# wrong-cluster run cannot be told from a missing object unless the script says which cluster it means.
KCTX=${KCTX:-kind-platform}

say () { echo "  $*"; }
die () { echo "ABORT: $*" >&2; exit 1; }
k () { kubectl --context "$KCTX" "$@"; }
# reachable answers whether the API server responds at all, so "not found" is never reported for a cluster
# this process cannot talk to.
reachable () { k version --request-timeout=5s >/dev/null 2>&1; }
now_ns () { date +%s%N; }
ms () { echo "scale=1; $1 / 1000000" | bc; }

req () {
  curl -s -o /dev/null -m 3 -w '%{http_code}' -X POST "http://$GW/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null
}

# An absent series returns the EMPTY STRING, not 0, and the difference is the whole point.
#
# This used to print '0' for a query that matched nothing, which made three different situations produce the
# same number: the scrape is broken, the counter has never been incremented so Prometheus holds no series
# for it, and the counter really is at zero. The run would then report delta 0 and conclude the gateway did
# not fall back -- a verdict about the gateway drawn from a fact about the query.
#
# It is not hypothetical here. gpuaas_gateway_backend_fallbacks_total had no series at all on this cluster
# until a request exercised it, because Prometheus does not materialise a counter nobody has touched.
#
# fr002 already used the empty string for this and guards on it; the two scripts disagreed, and only the
# guarded one could tell the cases apart.
promq () {
  curl -sG "http://$PROM/api/v1/query" --data-urlencode "query=$1" 2>/dev/null | python3 -c "
import json,sys
try: r=json.load(sys.stdin)['data']['result']
except Exception: print(''); raise SystemExit
print(r[0]['value'][1] if r else '')"
}

# reads a counter that MUST already exist, and refuses the run when it does not.
#
# Called before the injection rather than after, because an absent series discovered afterwards cannot be
# told from an injection that changed nothing.
must_promq () {
  local v
  v=$(promq "$1")
  [ -n "$v" ] || die "Prometheus has no series for $1; the counter is unreadable, and a run that treated that as zero would publish a verdict about the gateway drawn from a fact about the query. Send one request through the gateway first, then re-run."
  echo "$v"
}

endpoints () { k -n "$SERV" get endpoints "$1" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null; }

restore () {
  echo
  say "restoring $HEAD"
  k -n "$SERV" patch inferencedeployment "$HEAD" --type=merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1
  for _ in $(seq 60); do [ -n "$(endpoints "$HEAD")" ] && { say "$HEAD serving again"; return; }; sleep 2; done
  say "WARNING: $HEAD never came back; the next run's steady state will refuse to start"
}
# Armed only once the head has actually been scaled down.
#
# Armed at definition time it fired on every early abort, printing "restoring stub-llm" and then a warning
# that it never came back -- for a run that had changed nothing. A recovery message for an injection that
# did not happen is worse than silence: it describes the cluster wrongly in the one log a later reader has.
INJECTED=false
on_exit () { [ "$INJECTED" = true ] && restore; }
trap on_exit EXIT

# ---------------------------------------------------------------- steady state
say "=== steady state ==="

# Reachability first, because every check below reports absence when it cannot reach the API at all.
reachable || die "context $KCTX does not answer; every check below would report a missing object for a cluster this process cannot talk to. Set KCTX to the cluster that holds $SERV/$HEAD."
say "context $KCTX answers"

for d in "$HEAD" "$SPARE"; do
  k -n "$SERV" get inferencedeployment "$d" >/dev/null 2>&1 || die "InferenceDeployment $d does not exist in $KCTX"
  [ -n "$(endpoints "$d")" ] || die "$d has no endpoints; there is no working pair to fall back between"
done
say "both backends have endpoints"

# The two must serve the SAME model, or the gateway never considers them alternatives and this measures
# nothing at all.
for d in "$HEAD" "$SPARE"; do
  m=$(k -n "$SERV" get inferencedeployment "$d" -o jsonpath='{.spec.model.name}' 2>/dev/null)
  [ "$m" = "$MODEL" ] || die "$d serves model '$m', not '$MODEL'; they are not alternatives"
done
say "both serve model $MODEL"

# Oldest-first is the routing order, so the head must actually be the older of the two.
H_TS=$(k -n "$SERV" get inferencedeployment "$HEAD" -o jsonpath='{.metadata.creationTimestamp}')
S_TS=$(k -n "$SERV" get inferencedeployment "$SPARE" -o jsonpath='{.metadata.creationTimestamp}')
[[ "$H_TS" < "$S_TS" ]] || die "$HEAD ($H_TS) is not older than $SPARE ($S_TS); the head is not the one being removed"
say "$HEAD is the head (older): $H_TS < $S_TS"

ok=0
for _ in $(seq 5); do [ "$(req)" = "200" ] && ok=$((ok+1)); done
[ "$ok" -eq 5 ] || die "only $ok of 5 pre-fault requests succeeded"
say "5/5 pre-fault requests returned 200"

# must_promq rather than promq: an absent series here is a setup failure, not a reading of zero.
FALLBACKS_BEFORE=$(must_promq 'sum(gpuaas_gateway_backend_fallbacks_total)') || exit 1
say "backend_fallbacks_total before: $FALLBACKS_BEFORE"

# The three counters below are read for the same window but NOT gated on.
#
# They answer "what else did this injection do", which the fallback delta alone cannot: a gateway that
# absorbed the traffic by rate-limiting it, or by refusing it at admission, would also leave requests
# succeeding and the fallback counter moving. Recording them is what lets a later reader rule those out.
#
# They are allowed to be absent, and an absent one is recorded as such instead of as zero -- the whole
# correction this script needed.
LIMITED_BEFORE=$(promq 'sum(gpuaas_gateway_rate_limited_total)')
UPSTREAM_BEFORE=$(promq 'sum(gpuaas_gateway_upstream_errors_total)')
ADMIT_BEFORE=$(promq 'sum(gpuaas_gateway_admission_decisions_total)')
say "context before: rate_limited=${LIMITED_BEFORE:-<no series>} upstream_errors=${UPSTREAM_BEFORE:-<no series>} admission_decisions=${ADMIT_BEFORE:-<no series>}"

# ---------------------------------------------------------------- inject
echo
say "=== inject: scaling the head to zero ==="
T0=$(now_ns)
k -n "$SERV" patch inferencedeployment "$HEAD" --type=merge -p '{"spec":{"replicas":0}}' >/dev/null 2>&1 \
  || die "scale down failed"
# Armed here and nowhere earlier: from this line on the cluster is altered and a run that ends for any
# reason must put the head back.
INJECTED=true

GONE=""
for _ in $(seq 120); do
  [ -z "$(endpoints "$HEAD")" ] && { GONE=$(now_ns); break; }
  sleep 0.5
done
[ -n "$GONE" ] || die "$HEAD still has endpoints; the head was never actually removed"
say "head lost its endpoints $(ms $(( GONE - T0 )))ms after the scale-down"

# ---------------------------------------------------------------- effect
echo
say "=== effect: do requests still succeed, and did the gateway fall back ==="
OK=0; FAIL=0; CODES=""
for _ in $(seq 20); do
  C=$(req); CODES="$CODES$C "
  [ "$C" = "200" ] && OK=$((OK+1)) || FAIL=$((FAIL+1))
  sleep 0.2
done
say "$OK of 20 requests succeeded with the head gone"
say "codes: $(echo "$CODES" | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')"

sleep 20   # one scrape at least
FALLBACKS_AFTER=$(must_promq 'sum(gpuaas_gateway_backend_fallbacks_total)') || exit 1
DELTA=$(echo "$FALLBACKS_AFTER - $FALLBACKS_BEFORE" | bc 2>/dev/null || echo 0)
say "backend_fallbacks_total after:  $FALLBACKS_AFTER  (delta $DELTA)"

LIMITED_AFTER=$(promq 'sum(gpuaas_gateway_rate_limited_total)')
UPSTREAM_AFTER=$(promq 'sum(gpuaas_gateway_upstream_errors_total)')
ADMIT_AFTER=$(promq 'sum(gpuaas_gateway_admission_decisions_total)')
delta_of () { [ -n "$1" ] && [ -n "$2" ] && echo "$2 - $1" | bc 2>/dev/null || echo null; }
LIMITED_DELTA=$(delta_of "$LIMITED_BEFORE" "$LIMITED_AFTER")
UPSTREAM_DELTA=$(delta_of "$UPSTREAM_BEFORE" "$UPSTREAM_AFTER")
ADMIT_DELTA=$(delta_of "$ADMIT_BEFORE" "$ADMIT_AFTER")
say "context after:  rate_limited delta=$LIMITED_DELTA  upstream_errors delta=$UPSTREAM_DELTA  admission_decisions delta=$ADMIT_DELTA"

# A rate-limited request never reaches a backend, so it cannot be one the spare absorbed. If the limiter
# moved during the window the twenty successes are not all attributable to fallback, and the run says so
# rather than leaving the reader to assume otherwise.
if [ "$LIMITED_DELTA" != "null" ] && [ "$LIMITED_DELTA" != "0" ]; then
  say "WARNING: the rate limiter refused $LIMITED_DELTA request(s) during this window; the fallback delta is not the only thing that shaped the outcome"
fi

SERVED=false;  [ "$OK" -ge 18 ] && SERVED=true
FELL_BACK=false; [ "$(echo "$DELTA > 0" | bc 2>/dev/null)" = "1" ] && FELL_BACK=true

if [ "$SERVED" = true ] && [ "$FELL_BACK" = true ]; then
  say "the spare absorbed the traffic AND the counter recorded it"
elif [ "$SERVED" = true ]; then
  say "requests succeeded but the fallback counter did not move — the gateway is serving them some other way, and the metric an operator would rely on is silent"
else
  say "requests FAILED with a healthy spare one list entry away — the fallback path did not engage"
fi

# ---------------------------------------------------------------- record
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
{
  "experiment": "FR-002b head backend removed, spare must absorb",
  "model": "$MODEL",
  "head": "$SERV/$HEAD",
  "spare": "$SERV/$SPARE",
  "injection": "scale the head InferenceDeployment to zero replicas",
  "why": "a backend is an InferenceDeployment, not a pod; adding pod replicas exercises Service load balancing rather than the gateway's retry path",
  "steadyStateEstablished": true,
  "headEndpointsGoneMs": $(ms $(( GONE - T0 ))),
  "requests": { "sent": 20, "succeeded": $OK, "failed": $FAIL },
  "backendFallbacks": { "before": $FALLBACKS_BEFORE, "after": $FALLBACKS_AFTER, "delta": $DELTA },
  "context": {
    "note": "read for the same window and not gated on; an absent series is null rather than 0, so a counter Prometheus never materialised is never mistaken for one that stayed still",
    "rateLimited": { "before": ${LIMITED_BEFORE:-null}, "after": ${LIMITED_AFTER:-null}, "delta": $LIMITED_DELTA },
    "upstreamErrors": { "before": ${UPSTREAM_BEFORE:-null}, "after": ${UPSTREAM_AFTER:-null}, "delta": $UPSTREAM_DELTA },
    "admissionDecisions": { "before": ${ADMIT_BEFORE:-null}, "after": ${ADMIT_AFTER:-null}, "delta": $ADMIT_DELTA }
  },
  "verdict": {
    "stillServed": $SERVED,
    "counterMoved": $FELL_BACK,
    "note": "both are required. Requests succeeding alone could mean the head never really left; the counter moving alone could mean every request is falling back, including ones that should not."
  }
}
EOF
echo
say "record written to $OUT"
[ "$SERVED" = true ] && [ "$FELL_BACK" = true ]

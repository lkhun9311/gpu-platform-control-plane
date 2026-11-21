#!/usr/bin/env python3
"""Runs each shared-rate-limit test against a mutation that breaks the property it guards.

Usage: mutate.py <tree> <out.tsv>

<tree> is a clean checkout of the commit under test (a detached worktree), because every mutation is written into
it and reverted with git checkout; running in a working tree with edits would revert them too.

A mutation is KILLED only when its build succeeded, the focused spec ran, and the run failed.
A build failure is INVALID, not a kill: a mutation that does not compile proves nothing about the test.
The baseline, every focused spec with no mutation, must pass first, or nothing after it means anything.
"""
import subprocess
import sys

TREE, OUT = sys.argv[1], sys.argv[2]
REDIS = "internal/gateway/ratelimit_redis.go"
SERVER = "internal/gateway/server.go"
MANIFEST = "config/gateway/deployment.yaml"

NON_ATOMIC = '''
// nonAtomicBucket is the mutation: the same bucket read and written from Go in separate round trips.
func nonAtomicBucket(ctx context.Context, c *redis.Client, key string, rpm, burst float64) ([]int64, error) {
	now, err := c.Time(ctx).Result()
	if err != nil {
		return nil, err
	}
	vals, err := c.HMGet(ctx, key, "tokens", "ts").Result()
	if err != nil {
		return nil, err
	}
	nowUs := float64(now.UnixMicro())
	tokens, ts := burst, nowUs
	if s, ok := vals[0].(string); ok {
		tokens, _ = strconv.ParseFloat(s, 64)
	}
	if s, ok := vals[1].(string); ok {
		ts, _ = strconv.ParseFloat(s, 64)
	}
	if nowUs > ts {
		tokens = min(burst, tokens+(nowUs-ts)*rpm/60e6)
		ts = nowUs
	}
	if tokens < 1 {
		return []int64{0, 0}, nil
	}
	if err := c.HSet(ctx, key, "tokens", tokens-1, "ts", ts).Err(); err != nil {
		return nil, err
	}
	return []int64{1, 0}, nil
}
'''

SCRIPT_CALL = '''res, err := tokenBucketScript.Run(callCtx, l.client, []string{l.prefix + tenant},
		strconv.FormatInt(int64(rl.RequestsPerMinute), 10), strconv.FormatInt(int64(rl.Burst), 10)).Int64Slice()'''

# (name, property guarded, [(file, old, new)], go test target, selector)
MUTATIONS = [
    ("per-replica-key", "replicas share one budget",
     [(REDIS, "[]string{l.prefix + tenant}", '[]string{l.prefix + fmt.Sprintf("%p:", l) + tenant}')],
     "gw", "admits exactly the burst"),
    ("non-atomic-read-modify-write", "replicas share one budget",
     [(REDIS, SCRIPT_CALL,
       "res, err := nonAtomicBucket(callCtx, l.client, l.prefix+tenant, float64(rl.RequestsPerMinute), float64(rl.Burst))"),
      (REDIS, "// answered logs the end of an outage once.", NON_ATOMIC + "\n// answered logs the end of an outage once.")],
     "gw", "admits exactly the burst"),
    ("refill-60x-fast", "refill follows the policy rate",
     [(REDIS, "/ 60000000", "/ 1000000")], "gw", "refills at the policy"),
    ("no-refill", "refill follows the policy rate",
     [(REDIS, "    tokens = tokens + (now - ts) * per_us\n", "    tokens = tokens\n")], "gw", "refills at the policy"),
    ("rebuild-on-policy-edit", "a policy edit keeps spent tokens",
     [(REDIS, "[]string{l.prefix + tenant}",
       '[]string{l.prefix + tenant + ":" + strconv.Itoa(int(rl.RequestsPerMinute)) + "/" + strconv.Itoa(int(rl.Burst))}')],
     "gw", "keeps spent tokens across a policy edit"),
    ("key-without-tenant", "tenants never share a bucket",
     [(REDIS, "[]string{l.prefix + tenant}", "[]string{l.prefix}")], "gw", "keeps tenants' buckets apart"),
    ("no-expiry", "keys expire once the bucket is full",
     [(REDIS, "  redis.call('PEXPIRE', KEYS[1], math.ceil(burst / per_us / 1000) + 1000)",
       "  redis.call('PERSIST', KEYS[1])")], "gw", "expires a tenant's key"),
    ("closed-admits", "closed refuses while Redis is down",
     [(REDIS, "\treturn false, 0, ErrRateLimitUnavailable\n}", "\treturn true, 0, nil\n}")],
     "gw", "refuses under the closed policy"),
    ("local-admits-all", "local is bounded by a local bucket",
     [(REDIS, "\t\tok, wait := l.local.Reserve(tenant, rl)\n\t\treturn ok, wait, nil", "\t\treturn true, 0, nil")],
     "gw", "falls back to a local bucket"),
    ("local-refuses", "local keeps serving while Redis is down",
     [(REDIS, "\t\tok, wait := l.local.Reserve(tenant, rl)\n\t\treturn ok, wait, nil",
       "\t\treturn false, 0, ErrRateLimitUnavailable")],
     "gw", "falls back to a local bucket"),
    ("no-timeout", "a hung Redis costs one timeout",
     [(REDIS, "callCtx, cancel := context.WithTimeout(ctx, l.timeout)", "callCtx, cancel := context.WithCancel(ctx)"),
      (REDIS, "\t\tReadTimeout:  cfg.Timeout,\n\t\tWriteTimeout: cfg.Timeout,", "\t\tReadTimeout:  -1,\n\t\tWriteTimeout: -1,")],
     "gw", "gives up on a hung Redis"),
    ("no-breaker", "a failure keeps the replica off Redis for the cooldown",
     [(REDIS, "\tl.openUntil.Store(time.Now().Add(l.cooldown).UnixNano())", "\t_ = l.cooldown")],
     "gw", "stops calling a failed Redis"),
    ("breaker-never-closes", "the replica returns to Redis once it is back",
     [(REDIS, "\tif time.Now().UnixNano() < l.openUntil.Load() {",
       "\tif l.down.Load() || time.Now().UnixNano() < l.openUntil.Load() {")],
     "gw", "returns to the shared bucket"),
    ("holdcap-allowed", "HoldCap is refused under the shared store",
     [(SERVER, "\tif targets[0].Admission == AdmissionHoldCap {\n\t\treturn singleGatewayHoldCap",
       "\tif targets[0].Admission == \"never\" {\n\t\treturn singleGatewayHoldCap")],
     "gw", "refuses a HoldCap backend"),
    ("prefix-affinity-allowed", "PrefixAffinity is refused under the shared store",
     [(SERVER, "routingPolicyFor(targets) == platformv1.RoutingPolicyPrefixAffinity {",
       "routingPolicyFor(targets) == \"never\" {")],
     "gw", "refuses PrefixAffinity"),
    ("unavailable-as-429", "an undecided request is 503, not 429",
     [(SERVER, "\tok, wait, err := limiter.Decide(ctx, tenant, policy.Spec.RateLimit)\n\tif err != nil {",
       "\tok, wait, err := limiter.Decide(ctx, tenant, policy.Spec.RateLimit)\n"
       "\tif err != nil {\n\t\ts.fail(w, tenant, \"\", http.StatusTooManyRequests)\n\t\treturn\n\t}\n\tif err != nil {")],
     "gw", "rate_limit_unavailable"),
    ("startup-accepts-holding-modes", "the shared store refuses every admission mode but off at start",
     [(SERVER, "\tif mode == AdmissionOff {\n\t\treturn nil\n\t}", "\tif mode != \"never\" {\n\t\treturn nil\n\t}")],
     "cmd", "TestInstallRateLimiterRedisRefusesPerProcessAdmission"),
    ("startup-accepts-kv-aware", "kv-aware is outside the supported multi-replica profile",
     [(SERVER, "\tif mode == AdmissionOff {\n", "\tif mode == AdmissionOff || mode == AdmissionKVAware {\n")],
     "cmd", "TestInstallRateLimiterRedisRefusesPerProcessAdmission"),
    ("evalsha-without-fallback", "a flushed script cache is reloaded, not an outage",
     [(REDIS, "tokenBucketScript.Run(", "tokenBucketScript.EvalSha(")], "gw", "script cache is flushed"),
    ("manifest-rolling-update", "the shipped manifest never runs two Pods during a rollout",
     [(MANIFEST, "  strategy:\n    type: Recreate\n", "")], "cmd", "TestGatewayManifestIsTheSingleInstanceProfile"),
    ("manifest-two-replicas", "the shipped memory-store manifest runs one replica",
     [(MANIFEST, "  replicas: 1\n", "  replicas: 2\n")], "cmd", "TestGatewayManifestIsTheSingleInstanceProfile"),
]


def go_test(target, selector):
    if target == "gw":
        cmd = ["go", "test", "./internal/gateway/", "-count=1", "-timeout", "90s", "-run", "TestGateway", "-v",
               "-args", "-ginkgo.focus=" + selector, "-ginkgo.no-color"]
    else:
        cmd = ["go", "test", "./cmd/gateway/", "-count=1", "-timeout", "90s", "-run", selector, "-v"]
    p = subprocess.run(cmd, cwd=TREE, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def ran(target, out):
    if target == "gw":
        return any(line.startswith("Ran ") and not line.startswith("Ran 0 ") for line in out.splitlines())
    return "=== RUN" in out


def evidence(out):
    """The failed assertion with the values it saw, so a kill can be read without rerunning it."""
    lines = out.splitlines()
    keep = []
    for i, l in enumerate(lines):
        s = l.strip()
        if s.startswith("[FAILED]") or "panic: test timed out" in s or s.startswith("ratelimit_store_test"):
            keep.append(s)
        elif s == "Expected" and i + 3 < len(lines):
            # Gomega prints the actual value, the matcher and the wanted value on the three lines after.
            keep.append(" ".join(x.strip() for x in lines[i:i + 4]))
    return " | ".join(dict.fromkeys(keep))[:400].replace("\t", " ")


def apply(edits):
    for path, old, new in edits:
        full = f"{TREE}/{path}"
        src = open(full).read()
        if src.count(old) != 1:
            raise SystemExit(f"mutation text occurs {src.count(old)} times in {path}, want 1: {old[:60]!r}")
        open(full, "w").write(src.replace(old, new))


def revert():
    subprocess.run(["git", "checkout", "--", "internal", "cmd", "config"], cwd=TREE, check=True)


rows = ["mutation\tproperty\tselector\tverdict\tevidence"]
# Baseline: every selector passes unmutated, and actually runs a spec.
for sel_target, sel in sorted({(m[3], m[4]) for m in MUTATIONS}):
    code, out = go_test(sel_target, sel)
    if code != 0 or not ran(sel_target, out):
        print(out[-3000:], file=sys.stderr)
        raise SystemExit(f"baseline failed or ran nothing for {sel!r}")
    rows.append(f"baseline\t-\t{sel}\tPASS\t")
    print(f"baseline {sel}: PASS", flush=True)

failed = 0
for name, prop, edits, target, sel in MUTATIONS:
    apply(edits)
    try:
        code, out = go_test(target, sel)
    finally:
        revert()
    if "[build failed]" in out or "[setup failed]" in out:
        verdict = "INVALID"
    elif code != 0 and (ran(target, out) or "panic: test timed out" in out):
        verdict = "KILLED"
    else:
        verdict = "SURVIVED"
    if verdict != "KILLED":
        failed += 1
    rows.append(f"{name}\t{prop}\t{sel}\t{verdict}\t{evidence(out)}")
    print(f"{name}: {verdict}", flush=True)

with open(OUT, "w") as f:
    f.write("\n".join(rows) + "\n")
sys.exit(1 if failed else 0)

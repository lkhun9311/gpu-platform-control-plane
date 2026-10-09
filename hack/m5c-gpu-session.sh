#!/usr/bin/env bash
#
# Rents one GPU instance, builds a kind cluster on it, and runs the M5-c sharing matrix inside.
#
# WHY THIS EXISTS RATHER THAN hack/m5c-matrix.sh ON ITS OWN
#
# The matrix drives a Kubernetes cluster. It does not make one. Until now the only cluster it could drive was
# an EKS cluster with a GPU node group -- and the cluster half of the AWS path has never been applied, so the
# matrix had nowhere to run and its pre-registration was costed against a shape it does not have.
#
# hack/queuelab-gpu-session.sh already solved the hard part on a rented card: the NVIDIA container toolkit as
# docker's default runtime, `accept-nvidia-visible-devices-as-volume-mounts`, the /var/run/nvidia-container-devices
# mount that makes a kind node see the cards, the toolkit configured a SECOND time inside the node container
# because Pods run on its containerd and not on the host's docker, and a kubeconfig path passed rather than
# guessed. Every one of those was bought with a paid session. This runs the same recipe for one card.
#
# WHY g5.2xlarge AND NOT g5.xlarge
#
# The same single A10G, twice the host memory: 32 GiB against 16. This session runs a kind node, two vLLM
# engines and the replay harness at once, and 16 GiB is the sort of margin that is discovered at a rollout
# timeout on a card that is already billing. Measured 2026-09-10 in ap-northeast-2: $0.680-0.689/h against
# $0.574-0.596/h. Ten cents an hour is the wrong place to economise.
#
# WHAT THIS SHIPS RATHER THAN BUILDS
#
# The GPU AMI carries a driver, not a toolchain, so `go build` on the instance fails with
# `go: command not found` after the driver, the cluster and the plugin have all been paid for. The gateway
# and the harness are built here and shipped with their digests, exactly as the device session ships its
# runner, and the matrix takes them through GATEWAY_BIN and BENCHHARNESS_BIN.
#
# It does NOT ship an operator image, and that is a finding rather than an omission:
# hack/test/rehearse-m5c-deploy.sh proved on a real cluster that the gateway resolves a backend by reading
# the InferenceDeployment CR and constructing http://<name>.<namespace>.svc:<port> itself. The CRDs and the
# gateway's ClusterRole are what M5-c needs. The controller-manager is not.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

REGION="${AWS_REGION:-ap-northeast-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
# Above the $0.68-0.69 measured across all three zones with room for a rise, and below the on-demand price
# the pre-registration does not authorise.
#
# THE SPENDING BOUND IS THIS PRICE TIMES THE PAID LIFETIME, and it is not a completion estimate.
#
#   HARD_STOP_SECONDS / 3600 * MAX_SPOT_PRICE  =  16800 / 3600 * 1.10  =  $5.13
#   at the measured rate instead:              =  4.67 h   * 0.685     =  $3.20
#
# Those two are what a run can cost. Neither says it will finish: cell time for `timeSlicing` has never been
# measured on this card, so a 15-cell projection built from the other arms' time would be the generalisation
# this session has made and retracted repeatedly. The bound caps SPENDING; whether the matrix completes
# inside it is a separate question, and a matrix that completes six of fifteen cells has bought six
# comparable cells rather than failed.
#
# Add to it anything that bills outside the instance: the standing cluster (~$0.27/h while it exists), and
# the first pull of the vLLM image and the model weights through the NAT (~$0.7-0.9 per fresh node). Both of
# those figures were measured for M5-b on g5.xlarge (docs/M5B_PAID_SESSION_RUNBOOK.md) and are carried over
# here unverified; the same cluster and the same NAT make them plausible, not measured, for this run.
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-1.10}"
# The backstop inside the instance, and the one this script waits for. The instance's fires first on purpose:
# a shell that dies here must not leave a card running, and the only timer that survives a dead shell is the
# one on the machine that is billing.
# Raised twice on 2026-10-01, and the second time from a MEASUREMENT rather than from this script's model.
#
# First 8400 -> 9600, on the arithmetic below: a GpuSharingBenchmark compiles to two arms, the CRD floors
# repetitions at five, so ten cells at the registered 505-second trace, and `require_credential_margin`
# estimated 143 minutes. That estimate came from `replay_min`, which counts the trace and nothing else.
#
# The run at 9600 stopped itself after cell 1 of 10. The cell had taken 15.7 minutes against the model's
# 10 (S3 object timestamps: preflight 09:31:51, cell-1 evidence 09:47:30), because every cell rolls its
# engines out again, re-checks readiness, re-establishes the port-forward and uploads its own evidence, and
# the model charges for none of it.
#
# What the matrix requires is its own projection, hack/m5c-matrix.sh:1445:
#
#   projected = (cells_total - cells_done) * per * 12/10
#
# The 12/10 is applied to the REMAINING cells, never to all ten.
#
# Second 9600 -> 13200 (220 min). Third 13200 -> 16800 (280 min), and the third time against that stopping
# rule rather than against a sum of parts. Simulating it reproduces the real run: 160 minutes with
# 15.65-minute cells stops at cell 1 projecting 170 against 142 left, and the run projected 167 against 142.
# With the control reproduced, the model says:
#
#   shared cell   at a 220 min deadline       completes at
#   15.65 (= R1)  completes, 61 min spare     190 min
#   21.00         completes, 34 min spare     220 min   <- break-even
#   22.90         STOPS AT CELL 2             230 min
#   28.00         STOPS AT CELL 2             260 min
#   31.30         STOPS AT CELL 2             280 min
#
# WRONG MECHANISM, kept here with its correction: `shared` is ONE engine serving both tenants, and the
# two-engine arms are `timeSlicing` and `mps`. What this paragraph argued from was the engine count, and
# the measured difference is 7.2 SECONDS whose cause was never measured.
# The non-replay part of an R1 cell is 7.22 of its 15.65 minutes
# -- 46%, derived from the committed raw rows, whose 4655 requests span 505.6 s against a registered 505 s
# trace, so the rest of the cell is not replay. Doubling only that part puts a shared cell at 22.9 and past
# the break-even, and 220 would then have bought TWO cells rather than nine: the arms alternate
# (hack/m5c-matrix.sh:360-361 iterates repetition-major), so the average jumps right after the first
# sharing cell and the projection jumps with it. 280 covers that part TRIPLING.
#
# A deadline costs nothing it does not use -- the bill is the run's actual length, and the instance is
# terminated when the matrix finishes. Setting this to the expected case rather than the worst case is what
# bought one cell for $0.25.
#
# MEASURED, 2026-10-01, ten cells at this deadline (the run completed with 2h38m of it unused):
#
#   cell        time    replay   outside     cell        time    replay   outside
#   R1-1       15.58      8.43      7.16     shared-1   11.85      8.49      3.36
#   R1-2       11.37      8.43      2.94     shared-2   11.27      8.49      2.78
#   R1-3       11.18      8.43      2.76     shared-3   11.43      8.49      2.94
#   R1-4       11.20      8.43      2.77     shared-4   11.27      8.49      2.78
#   R1-5       11.18      8.43      2.76     shared-5   11.27      8.49      2.78
#
# Two of the premises above are now wrong, and the deadline they justified is right anyway.
#
# The 46% outside replay is a property of the FIRST cell, not of a cell: it downloads the model weights and
# every later cell finds them cached. Warm cells spend 2.87 minutes outside replay, 25%, and the figure is
# steady to the second. Generalising one cold cell to ten is what produced 22.9.
#
# The sharing arm IS slower and more variable, but by 7.2
# seconds rather than seven minutes: at the plateau R1 is 11.189 (n=3, spread 1.0 s) and shared is 11.308
# (n=4, spread 10.0 s), and the two do not overlap -- every shared cell exceeds every R1 cell. A real
# effect, 0.7% of a cell, and the thing that actually costs four minutes is the cold start.
#
# The matrix took 117.6 minutes of the 280. The deadline is now generous rather than fitted, and that is
# the state to leave it in: what it costs when unused is nothing, and what it cost when tight was a cell.
#
# An earlier version of this comment also charged 20 minutes of bootstrap, which nothing measured. The
# run's own figures put the bring-up INSIDE the deadline at 2.35 minutes: the matrix had 142 of 160 left
# when its first cell ended, and that cell was 15.65.
#
# An earlier version of this comment said ten cells need 177 minutes and that the matrix lifts that to 212
# with its 12/10. Neither step is what the code does: 177 is the replay sum with no safety factor at all,
# and 212 applied the factor to all ten cells. The value it was used to justify is large enough anyway,
# which is why it survived -- a wrong derivation that lands near the right answer is the kind that does.
#
# What the first raise cost: $0.25 and one cell. It did not warn, because a deadline that is too short is
# not an error until the matrix reaches the boundary where it would be cut -- and then it stops cleanly,
# which looks like success until you count the cells.
#
# The gap between the two is unchanged at ten minutes, and the ordering it exists for is unchanged: this
# shell gives up first so a dead laptop still leaves the instance's own timer to stop the billing.
#
# The ordering was VERIFIED rather than assumed on 2026-10-01: both timers start inside the instance's own
# user-data, the backstop where it is armed and DEADLINE_EPOCH some forty lines below it, and between the
# two there is nothing but variable assignment. So the ten-minute lead survives intact.
# Whether the caller set the limits, for the pilot, whose limits are registered and not the caller's to move.
LIMITS_FROM_CALLER="${BACKSTOP_SECONDS+set}${HARD_STOP_SECONDS+set}"
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-17400}"
HARD_STOP_SECONDS="${HARD_STOP_SECONDS:-16800}"
# The same arms, in the same order, as hack/m5c-matrix.sh's own default.
#
# This value is EXPORTED into the matrix, so when the two disagree this one wins and the matrix's default is
# dead text. It said "shared timeSlicing mps" while the matrix said "R1 shared timeSlicing mps", which would
# have bought a run with no isolated baseline for the second time running. A unit test now fails when they
# drift, because this repository has already paid for exactly this shape once with REPS: two scripts that do
# not read each other, one of them quietly halving what the study was designed around.
# LADDER rents a card for the capacity ladder of
# docs/superpowers/specs/2026-09-13-what-the-split-costs-in-throughput.md instead of the sharing matrix.
#
# The refusals below mirror hack/m5c-matrix.sh's exactly, and they exist here as well as there for the
# reason this file's header already gives about ARMS and REPS: two scripts that do not read each other will
# eventually disagree, and the one that wins is whichever exports last. A run that reached the instance with
# both a ladder and a single load would be refused ON THE CARD, after the bring-up was paid for.
# Whether the CALLER set these, recorded before the defaults below answer the question for them.
#
# The refusals further down cannot ask it afterwards: ARMS is defaulted on the next line, so every run would
# look as though an arm list had been passed beside the ladder. The first version of this took the snapshot
# after the default and refused every ladder run with "ARMS and LADDER are both set" -- a refusal that was
# right about nothing, found by hack/test/check-ladder-refusals.sh before it reached a card.
#
# The refusals themselves live below say() and fail(), because a refusal that calls an undefined function
# prints "fail: command not found" and no reason at all. That was the version before this one.
LADDER="${LADDER:-}"
ARMS_FROM_CALLER="${ARMS+set}"
REPS_FROM_CALLER="${REPS+set}"
ARMS="${ARMS:-R1 shared timeSlicing mps}"
OUT="${OUT:-hack/m5c-$(date -u +%Y%m%d-%H%M%S)}"
STACK="m5c-gpu"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The engine-pin waiver cannot reach a rented card. It exists for the kind rehearsal, whose substituted stub
# engine has no registry digest, and a paid run that carried it would produce numbers naming no build.
[ -z "${ENGINE_PIN_WAIVED:-}" ] \
  || fail "ENGINE_PIN_WAIVED is set. That waiver exists for the GPU-free rehearsal, whose stub engine cannot be digest-pinned; a run that rents a card must be able to say which engine build produced its numbers"

if [ -n "$LADDER" ]; then
  [ -z "${RATE:-}" ]         || fail "RATE and LADDER are both set. The ladder carries a rate per rung, so a single RATE is either ignored or overrides them -- refusing rather than picking."
  [ -z "${NOISY_WEIGHT:-}" ] || fail "NOISY_WEIGHT and LADDER are both set. The ladder carries the contender's load per rung -- a weight, or a rate under a study registered with independent arrivals -- and that is how it holds the contender fixed in absolute terms while the premium rate climbs."
  [ -z "$ARMS_FROM_CALLER" ] || fail "ARMS and LADDER are both set. The ladder's arms are its two topologies plus one isolated baseline cell at the rung it stops on, which is not known until it stops."
  [ -z "$REPS_FROM_CALLER" ] || fail "REPS and LADDER are both set. Ladder rungs are different loads rather than repetitions of one, and pooling two of them would report a p99 for a load that was never offered."
fi

# A best-effort SWEEP, for the studies registered with independent arrivals: PREMIUM_RATE held, one arm per
# BE rate. Like the ladder it carries its own load, so the weighted RATE, NOISY_WEIGHT and ARMS are refused
# beside it here, before the matrix would refuse them on the rented card; the matrix repeats every one of
# these checks, and this copy exists only so the refusal arrives before the spend.
SWEEP="${SWEEP:-}"
PREMIUM_RATE="${PREMIUM_RATE:-}"
if [ -n "$SWEEP" ]; then
  [ -z "$LADDER" ]           || fail "SWEEP and LADDER are both set. The ladder climbs the premium rate and the sweep holds it."
  [ -z "${RATE:-}" ]         || fail "RATE and SWEEP are both set. A sweep holds PREMIUM_RATE and steps the BE rate; a total RATE describes a weighted mix this sweep does not draw."
  [ -z "${NOISY_WEIGHT:-}" ] || fail "NOISY_WEIGHT and SWEEP are both set. The sweep's BE rates are absolute, one per level."
  [ -z "$ARMS_FROM_CALLER" ] || fail "ARMS and SWEEP are both set. A sweep's arms are R1 and one be<NN>-shared per SWEEP entry."
  [ -n "$PREMIUM_RATE" ]     || fail "SWEEP is set and PREMIUM_RATE is not. The sweep holds the latency-critical rate fixed, so it has to be named."
  # Both reach the instance through a sed substitution, so nothing but decimals and spaces gets that far.
  case "$SWEEP $PREMIUM_RATE" in *[!0-9.\ ]*) fail "SWEEP and PREMIUM_RATE carry only decimals and spaces; got ${SWEEP@Q} and ${PREMIUM_RATE@Q}" ;; esac
  # The labels the matrix will build, so the cost estimate and the archive check below count the cells it
  # will actually buy rather than the four default topologies.
  ARMS="R1"; _l=0
  for _ in $SWEEP; do _l=$(( _l + 1 )); ARMS="$ARMS $(printf 'be%02d-shared' "$_l")"; done
elif [ -n "${PILOT_STAGE:-}" ]; then
  # The prospective-admission pilot (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md,
  # "The measurement pilot"): two tenants at fixed independent rates, one stage per session, its arms the stage's.
  # Stages A and B are the pilot's, stage D the admission diagnostic's (design page, "v25").
  case "$PILOT_STAGE:${STUDY:-}" in
    A:prospective-pilot-2026-10-08 | B:prospective-pilot-2026-10-08 | D:admission-diagnostic-2026-10-10) ;;
    *) fail "PILOT_STAGE ${PILOT_STAGE@Q} and STUDY ${STUDY@Q} do not go together: stages A and B are prospective-pilot-2026-10-08's, stage D admission-diagnostic-2026-10-10's" ;;
  esac
  [ -z "$LADDER" ]           || fail "PILOT_STAGE and LADDER are both set"
  [ -z "${RATE:-}" ]         || fail "RATE and PILOT_STAGE are both set; the pilot's rates are PREMIUM_RATE and PILOT_NOISY_RATE"
  [ -z "${NOISY_WEIGHT:-}" ] || fail "NOISY_WEIGHT and PILOT_STAGE are both set; the pilot's rates are absolute"
  [ -z "$ARMS_FROM_CALLER" ] || fail "ARMS and PILOT_STAGE are both set; the pilot's arms are its stage's"
  [ -n "$PREMIUM_RATE" ] && [ -n "${PILOT_NOISY_RATE:-}" ] || fail "the pilot needs PREMIUM_RATE and PILOT_NOISY_RATE"
  case "$PREMIUM_RATE ${PILOT_NOISY_RATE} ${PILOT_STATIC_RATE:-0}" in *[!0-9.\ ]*) fail "the pilot's rates carry only decimals" ;; esac
  case "$PILOT_STAGE" in A | D) ;; B) [ -n "${PILOT_STATIC_RATE:-}" ] || fail "stage B needs PILOT_STATIC_RATE, the R fitted in stage A" ;;
    *) fail "PILOT_STAGE is ${PILOT_STAGE@Q}; the pilot has stages A and B, the diagnostic stage D" ;; esac
  [ "$PILOT_STAGE" != D ] || [ -z "${PILOT_STATIC_RATE:-}" ] || fail "PILOT_STATIC_RATE is set and stage D has no static arm"
  # The stage's arms, as the sweep's are built above: the cost projection counts them and the end-of-session
  # check expects each, and the default topologies here would fail a complete pilot after it was paid for.
  # shellcheck source=hack/lib/prospective-pilot.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/prospective-pilot.sh" || fail "could not source hack/lib/prospective-pilot.sh"
  ARMS=$(pp_stage_arms "$PILOT_STAGE" | tr '\n' ' ') || fail "no arms for stage $PILOT_STAGE"
  ARMS="${ARMS% }"
  # The registered limits (design page, "Deadlines"): stage A's hard stop is 2 h 30 and its backstop 2 h 40;
  # stage B is the size of a main session, 3 h 30 and 3 h 40. They size the allowance, so a caller cannot move them.
  [ -z "$LIMITS_FROM_CALLER" ] || fail "HARD_STOP_SECONDS or BACKSTOP_SECONDS is set, and the pilot's limits are registered per stage; unset them"
  # Stage D, the diagnostic's 13 cells, by the pilot's allowance method: 1.25 x (200 + 13 x 920 + 12) = 15,215 s,
  # rounded up to 4 h 14 m, and its backstop 10 minutes later (design page, "v25").
  case "$PILOT_STAGE" in A) HARD_STOP_SECONDS=9000; BACKSTOP_SECONDS=9600 ;; B) HARD_STOP_SECONDS=12600; BACKSTOP_SECONDS=13200 ;;
    D) HARD_STOP_SECONDS=15240; BACKSTOP_SECONDS=15840 ;; esac
elif [ -n "$PREMIUM_RATE" ]; then
  fail "PREMIUM_RATE is set without SWEEP. It is the held latency-critical rate of a sweep, and on its own it would be ignored."
fi

# REPS has no default here, and that is deliberate.
#
# A pilot is one repetition and a confirmatory run is three; which one this is decides what it costs and what
# may be concluded from it, and neither is a thing to arrive at by forgetting a variable. The matrix defaults
# to four for its own reasons -- a statistical argument about bootstrap blocks -- and a session script that
# quietly defaulted to something else would be the same defect this repository already recorded, where two
# scripts disagreed about REPS and a re-run silently bought half the repetitions the design was built on.
if [ -n "$LADDER" ]; then
  # The ladder has no repetitions to choose: each rung is one cell of a different load, and the one place it
  # repeats -- a rung that lands within a tenth of the target -- is a re-run of that rung, registered in the
  # pre-registration and not a count set here.
  REPS=1
else
  [ -n "${REPS:-}" ] || fail "REPS is unset. A pilot is REPS=1 and a confirmatory run is REPS=3. Which this is decides both the cost and what may be concluded, so it is not a default."
  case "$REPS" in ''|*[!0-9]*) fail "REPS is ${REPS@Q}, which is not a number" ;; esac
fi
# SEEDS reaches the instance through a sed substitution, so anything but digits and spaces is refused here:
# a `|` would end the expression and the user-data would carry whatever followed it. Whether the list suits
# the study is the matrix's judgement, and the local plan check below runs it before the card is rented.
SEEDS="${SEEDS:-}"
case "$SEEDS" in *[!0-9\ ]*) fail "SEEDS is ${SEEDS@Q}; it is a space-separated list of non-negative integers" ;; esac

# PURPOSE has no default either, and the registration is the reason.
#
# The 2026-10-02 amendment to docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md
# says a purchase declares exactly one of two questions -- a reproduction attempt naming a target archive, or
# a new measurement naming its load, hypothesis and stopping rule -- and that "a purchase that names neither
# is not authorised by this registration".
#
# NOTHING ENFORCED IT. REPRODUCES was forwarded to the plan check when set and simply absent otherwise, and
# no hypothesis or stopping rule was ever asked for anywhere. So the registration promised a mechanical check
# this script did not make, which is the shape this repository keeps recording: a guard that exists in prose.
# An external review found it on 2026-10-02, after the reproduction comparison itself had been reviewed twice.
#
# It is not hypothetical. On 2026-10-02 $2.16 bought a run registered as a "five-repetition reproduction" of
# the 2026-09-13 pilot which reproduced nothing -- different prompt length, different timeout -- and the
# mismatch was found while drafting the publication rather than before the card was rented.
#
# The ladder cannot carry a reproduction claim, and that is refused rather than ignored: hack/m5c-matrix.sh
# forwards REPRODUCES only on the matrix path, so a ladder declaring one would be a declaration nothing
# checks.
if [ -n "$LADDER" ] && [ "${PURPOSE:-}" = "reproduction" ]; then
  fail "LADDER and PURPOSE=reproduction are both set. The plan check forwards a reproduction claim only on the matrix path, so a ladder's claim would be enforced by nothing -- buy it as a new measurement, or buy the matrix."
fi
case "${PURPOSE:-}" in
  reproduction)
    [ -n "${REPRODUCES:-}" ] \
      || fail "PURPOSE=reproduction and REPRODUCES is unset. A reproduction attempt names the archive it repeats, and the plan check compares this run's offered load against that archive before anything is rented."
    { [ -z "${HYPOTHESIS:-}" ] && [ -z "${STOPPING_RULE:-}" ]; } \
      || fail "PURPOSE=reproduction carries HYPOTHESIS or STOPPING_RULE. Those belong to a new measurement; a reproduction's question is fixed -- whether a named run's result holds when its conditions are restored."
    ;;
  new-measurement)
    [ -z "${REPRODUCES:-}" ] \
      || fail "PURPOSE=new-measurement and REPRODUCES is set. A new measurement does not name a prior run as its target; putting a new label on a repeat purchase is the circumvention the registration's last section forbids."
    [ -n "${HYPOTHESIS:-}" ] \
      || fail "PURPOSE=new-measurement and HYPOTHESIS is unset. The registration requires the hypothesis before the card, because a question written after the answer is not a question."
    [ -n "${STOPPING_RULE:-}" ] \
      || fail "PURPOSE=new-measurement and STOPPING_RULE is unset. The rule that ends the spending has to exist before the spending starts."
    ;;
  "")
    fail "PURPOSE is unset. The registration authorises exactly two purchases -- PURPOSE=reproduction with REPRODUCES, or PURPOSE=new-measurement with HYPOTHESIS and STOPPING_RULE -- and says a purchase that names neither is not authorised by it."
    ;;
  *)
    fail "PURPOSE is ${PURPOSE@Q}, which is neither reproduction nor new-measurement."
    ;;
esac
# Said out loud, because a declaration nobody can read afterwards is not a declaration.
#
# This lands in the wrapper's transcript. The archive copy is written where $OUT is created, a few hundred
# lines below -- not here, because this guard runs before anything is created and that ordering is the point
# of it. A run refused here leaves no directory, which is correct: nothing was bought.
if [ "$PURPOSE" = "reproduction" ]; then
  say "purpose: reproduction of ${REPRODUCES}"
else
  say "purpose: new measurement -- hypothesis ${HYPOTHESIS@Q}, stopping rule ${STOPPING_RULE@Q}"
fi

spot_say()  { say "$@"; }
spot_fail() { fail "$@"; }
# shellcheck source=hack/lib/spot-run.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/spot-run.sh"
# The instrument-validation study's per-arm trace lengths, the same table the matrix reads.
# shellcheck source=hack/lib/instrument-validation.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/instrument-validation.sh" || fail "could not source hack/lib/instrument-validation.sh"

ACCOUNT=$(spot_account) || fail "not authenticated. aws sso login --profile <yours>, and export AWS_PROFILE"
BUCKET="${BUCKET:-$STACK-$ACCOUNT}"
# The S3 prefix carries a NONCE, so one launch cannot read another launch's records.
#
# It used to be the output directory's basename alone. Reuse that basename at the same commit -- a re-run
# after a failure, a name typed twice -- and the old DONE marker, the old archive and the old commit file
# all qualify: the wrapper downloads the PREVIOUS experiment, prints SESSION DONE, and its exit trap
# terminates the instance it has just paid to launch. The commit guard establishes that the SOURCE is the
# same; it says nothing about which session's numbers came back.
#
# openssl when it is there, the kernel's random pool when it is not, and the clock as a last resort -- this
# must never be the thing that stops a launch.
RUN_NONCE="${RUN_NONCE:-$(openssl rand -hex 4 2>/dev/null \
  || head -c4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' \
  || date +%s | tail -c 9)}"
[ -n "$RUN_NONCE" ] || RUN_NONCE=$(date +%s | tail -c 9)
RUN_ID="$(basename "$OUT")-$RUN_NONCE"

# LAUNCH_IDENTITY is a SECOND random value, and the split is the point: RUN_NONCE labels records, this one
# decides what may be terminated.
#
# The comment above the run tag says RUN_NONCE must never be given deletion authority, because it is 32 bits
# with a clock fallback and is overridable from the environment. The client token was then built as
# "m5c-$RUN_NONCE-$z" -- a prefix and a zone add no entropy, so the forbidden value held that authority
# anyway. Two sessions sharing a nonce and a zone shared the selector that spot_reconcile_token terminates
# by, and `RUN_NONCE=x` on the command line was enough to arrange it.
#
# So: 128 bits, no clock fallback, and no `${LAUNCH_IDENTITY:-}` -- an identity a caller can choose is not an
# identity. Unlike the nonce this one MAY stop a launch, which is the correct trade: a run that cannot name
# what it created must not create anything. Nothing reads it but the token.
LAUNCH_IDENTITY=$(openssl rand -hex 16 2>/dev/null \
  || head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "${#LAUNCH_IDENTITY}" -eq 32 ] \
  || fail "no source of 128 random bits (openssl and /dev/urandom both refused), so a launch could not be named well enough to be recovered. Nothing was launched."
mkdir -p "$OUT"

# The declared purpose, written into the run's OWN directory.
#
# The guard near the top refuses a purchase that declares neither question, and announces the declaration
# with `say`. That announcement lives in this shell's transcript and nowhere else -- and a declaration that
# exists only in a terminal is not evidence. The archive is what a later reader has, and "it was announced at
# the time" has exactly the standing of the registration that said "reproduction" while nothing checked it.
#
# No timestamp. This file is transcribed into the characterization goldens, so a clock in it would make every
# golden differ on every run, and a golden that differs for no behavioural reason is one that gets
# regenerated without being read.
{
  printf 'purpose: %s\n' "$PURPOSE"
  case "$PURPOSE" in
    reproduction)    printf 'reproduces: %s\n' "${REPRODUCES:-}" ;;
    new-measurement) printf 'hypothesis: %s\nstoppingRule: %s\n' "${HYPOTHESIS:-}" "${STOPPING_RULE:-}" ;;
  esac
} > "$OUT/purpose.txt"

say "study  M5-c sharing matrix -- does giving each tenant its own engine on a shared card protect the tail"
# The arm list as it is, not "R1 plus" it. R1 is now IN the list, and the old wording printed it twice.
if [ -n "$LADDER" ]; then
  say "arms   the two contended topologies at every rung, counterbalanced, plus one isolated baseline cell"
else
  say "arms   [$ARMS], $REPS repetition(s) each"
fi
say "output $OUT"

# ---------------------------------------------------------------- the load
#
# Every part of it is passed to the matrix, which refuses to start without all five, and the reasons are
# written out at that refusal. The short version: gen-trace's defaults put the 40,000-character contender at
# 45% of arrivals, which is four to five times an A10G's prefill capacity at any rate this study could use,
# and lowering the rate to compensate starves the premium tail below the sample floor. The mix has to move.
#
# These are the price-of-protection run's measured values, which were derived against ONE engine holding the
# WHOLE card. This run gives each engine half of one. They are therefore a starting point that the pilot's
# job is to replace, and the pilot is not finished until its derivation is written down.
# In ladder mode RATE and NOISY_WEIGHT are per rung and must stay EMPTY here, so that what reaches the
# instance is a ladder and not a ladder with a single load beside it. The refusals above make sure nobody
# passed one; these lines make sure this script does not invent one.
# The instrument-validation study takes no load, and the matrix refuses any load variable beside it.
# So a caller's value is refused here, before anything is built, and the defaults below are not applied:
# they would hand the matrix a RATE of 9.85 that it then refuses on the instance, after the card is paid for.
IV_NO_LOAD=""
if [ -z "$LADDER" ] && iv_is_study "${STUDY:-}"; then
  for _v in RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT PREMIUM_RATE \
    PREMIUM_PROMPT_CHARS NOISY_PROMPT_CHARS PREMIUM_OUTPUT_TOKENS NOISY_OUTPUT_TOKENS; do
    [ -z "${!_v:-}" ] || fail "$_v is ${!_v@Q} and study ${STUDY} takes no load; its episodes are the registration's. Unset it"
  done
  IV_NO_LOAD=1
fi
if [ -n "$IV_NO_LOAD" ]; then RATE=""; PREMIUM_WEIGHT=""; NOISY_WEIGHT=""; PROBE_WEIGHT=""
elif [ -n "$LADDER" ] || [ -n "$SWEEP" ] || [ -n "${PILOT_STAGE:-}" ]; then RATE=""; NOISY_WEIGHT=""; else
RATE="${RATE:-9.85}"
PREMIUM_WEIGHT="${PREMIUM_WEIGHT:-1}"
NOISY_WEIGHT="${NOISY_WEIGHT:-0.054}"
fi
[ -n "$IV_NO_LOAD" ] || PREMIUM_WEIGHT="${PREMIUM_WEIGHT:-1}"
# ZERO, and this is a correction rather than a carried value.
#
# The probe tenants straddle the ADMISSION guard's eligibility threshold. This study runs the gateway with
# -admission-mode=off, so they measure nothing here -- and they cost something: the first paid run sent 41
# probe requests that the gateway turned away on credentials, because the replay carries API keys for the
# premium and contending tenants and the trace generated four. The report said so in as many words, marking
# both probe rows VOID.
#
# hack/lib/spot-run.sh's header records this exact failure happening twice before: "one paid run answered a
# quarter of every replay with 401, the next answered its probe tenants with 403." That was the third. The
# value here was carried from hack/m5b-price-of-protection.sh, which has NO gateway in its path and so needs
# no key for anything.
#
# Zero removes the tenants rather than giving them keys, because a tenant that measures nothing this study
# varies is load wearing a measurement's name. gen-trace omits them entirely at 0.
PROBE_WEIGHT="${PROBE_WEIGHT:-0}"
# Emptied again for the instrument-validation study, on its own line because sharing_test.go reads the default above
# in exactly that form to check that probe tenants are never generated without keys.
[ -z "$IV_NO_LOAD" ] || PROBE_WEIGHT=""
# The instrument-validation study's trace length is its arm's, so it gets no run-wide default.
#
# The matrix refuses a non-empty DURATION_MS beside that study, and this default would hand it one.
# Refused here too, so the caller hears it before anything is built rather than from the plan check.
if [ -z "$LADDER" ] && iv_is_study "${STUDY:-}"; then
  [ -z "${DURATION_MS:-}" ] \
    || fail "DURATION_MS is ${DURATION_MS@Q} and study ${STUDY} sets the trace length per arm ($(iv_duration_summary "$STUDY")); unset it"
  [ -n "$ARMS_FROM_CALLER" ] \
    || fail "ARMS is unset and study ${STUDY} has none of the default topologies; name its arms"
  for _a in $ARMS; do _why=$(iv_duration_ms "$STUDY" "$_a") || fail "$_why"; done
  DURATION_MS=""
else
  DURATION_MS="${DURATION_MS:-420000}"
fi
if [ -n "$LADDER" ]; then
  say "load   a ladder, ${DURATION_MS}ms per cell, weights premium=$PREMIUM_WEIGHT probe=$PROBE_WEIGHT"
  say "       rungs: $LADDER (RATE:NOISY_WEIGHT, or PREMIUM_RATE:NOISY_RATE for a study registered with independent arrivals)"
  say "       solved offline against the real gen-trace; every rung holds the contender at 139 offers +/- 2"
elif [ -n "$SWEEP" ]; then
  say "load   a sweep, ${DURATION_MS}ms per cell: latency-critical held at ${PREMIUM_RATE}/s, best-effort at $SWEEP /s"
  say "       independent arrivals, so each repetition offers the latency-critical tenant one schedule at every level"
elif [ -n "${PILOT_STAGE:-}" ]; then
  say "load   the pilot's stage ${PILOT_STAGE}, ${DURATION_MS}ms per cell: premium ${PREMIUM_RATE}/s, contender ${PILOT_NOISY_RATE}/s, independent"
  [ -z "${PILOT_STATIC_RATE:-}" ] || say "       the static arm at R=${PILOT_STATIC_RATE}"
elif iv_is_study "${STUDY:-}"; then
  say "load   none -- registered episodes, one tenant; the trace length per arm ($(for _a in $ARMS; do printf '%s=%sms ' "$_a" "$(iv_duration_ms "$STUDY" "$_a")"; done))"
else
  say "load   rate ${RATE}/s, ${DURATION_MS}ms, weights premium=$PREMIUM_WEIGHT noisy=$NOISY_WEIGHT probe=$PROBE_WEIGHT"
  say "       (carried from the whole-card run; the pilot's job is to re-derive them for a half-card engine)"
fi

# ---------------------------------------------------------------- credentials
#
# Checked BEFORE anything is rented, because the alternative was measured: on 2026-09-08 a confirmatory run
# launched with 54 minutes of credential against 100 minutes of work, the credentials expired mid-run, the
# EXIT trap's terminate call was refused, and the line on screen said the instance was being terminated while
# it went on billing until somebody noticed.
#
# The margin is the whole session plus the bring-up plus a tail for the download of the evidence.
require_credential_margin() {
  local need_min="$1" cache newest expiry left

  # THE ACTIVE CREDENTIAL'S OWN EXPIRY, ASKED OF THE PROVIDER, BEFORE ANY CACHE IS READ.
  #
  # Everything below this block scans ~/.aws/cli/cache and takes the newest entry whose account matches.
  # That establishes "some credential for this account expires then", which is not the same fact: an active
  # credential with twenty minutes left, beside another role's twelve-hour entry in the same account, reads
  # as twelve hours. An adversarial review built exactly that pair of fixtures and watched this function
  # print "credentials expire in 719 min" and approve a 150-minute session.
  #
  # `aws configure export-credentials` resolves the credentials the CLI would ACTUALLY use for this profile
  # -- the same chain every aws call in this session goes through -- and reports their expiry. Only the
  # Expiration field is read; the keys it also returns are never printed, logged or stored.
  #
  # The cache scan stays as the fallback for a CLI too old to have the subcommand (it arrived in v2.9) and
  # for static credentials, which have no expiry at all.
  local active_expiry=""
  if active_expiry=$(aws configure export-credentials --format process 2>/dev/null \
      | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('Expiration',''))
except Exception:
    print('')" 2>/dev/null) && [ -n "$active_expiry" ]; then
    left=$(python3 -c "
import datetime,sys
e=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))
" "$active_expiry" 2>/dev/null || echo 0)
    local margin_active="${CREDENTIAL_MARGIN_MIN:-30}"
    say "credentials expire in ${left} min (asked of the active provider); this session needs about ${need_min} plus ${margin_active} of headroom"
    [ "$left" -ge $(( need_min + margin_active )) ] || fail "the credentials this session would actually use expire in ${left} minutes. It estimates ${need_min} and requires ${margin_active} of headroom on top, because the evidence download and the terminate call both come after the last cell. Re-authenticate first:  aws sso logout; aws sso login --profile <yours>"
    return 0
  fi
  say "the CLI could not export the active credential's expiry; falling back to scanning the credential cache"

  # The pilot refuses where other sessions skip or trust (design page, build item 13): an expiry it cannot establish,
  # an active role sts cannot name, and a cache entry that names only an account rather than the exact role.
  # Each of those is a session that could outlive its credentials, and the pilot's terminate-first rule needs them.
  local strict="${PILOT_STAGE:+1}"
  cache="${AWS_CLI_CACHE_DIR:-$HOME/.aws/cli/cache}"
  if [ ! -d "$cache" ]; then
    [ -z "$strict" ] || fail "the active credential's expiry could not be exported and there is no CLI cache at $cache, so the pilot cannot establish when its credentials end"
    say "no CLI credential cache at $cache; skipping the expiry check"; return 0
  fi
  # The LATEST live expiry, not the earliest. Taking min() across every file in the cache reads a stale
  # entry from another profile as this session's, which is how a fresh twelve-hour login was once reported
  # as expired.
  # Matched to the credentials THIS run is using, not merely to the newest entry in a shared cache.
  #
  # Taking the latest expiry fixed an earlier bug where a stale entry from another profile made a fresh
  # twelve-hour login read as expired. It did not establish identity: an active profile with twenty minutes
  # left beside another profile's twelve-hour entry still reads as twelve hours, and the run then loses
  # polling, download and termination partway through a paid session.
  #
  # The account and role of the credentials in use come from sts, and only cache entries whose assumed-role
  # ARN matches are considered. An entry that carries no ARN is skipped rather than trusted: this check
  # exists for the moments when something about the account is wrong, and those are the moments an
  # unidentified entry is most likely to be the wrong one.
  # Identity is matched on whatever the ENTRY actually carries, which is not always an ARN.
  #
  # The cache holds two shapes. An assume-role entry carries AssumedRoleUser.Arn; an SSO entry -- which is
  # what this account produces -- carries ProviderType "sso" and Credentials.AccountId and no ARN at all.
  # Requiring an ARN would therefore have skipped every entry this machine has and turned the whole check
  # into "no expiry found; skipping", which is worse than the hole it was closing: a guard that refuses to
  # answer always passes.
  #
  # So: an ARN is compared EXACTLY on the role path (a prefix comparison let 'AdminAccess' match
  # 'AdminAccessReadOnly'), an account id is compared exactly, and an entry carrying neither is skipped.
  # Account identity is weaker than role identity and it is what the entry has; it still rules out the
  # realistic confusion, which is another account's twelve hours standing in for this one's twenty minutes.
  local arn account
  arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | cut -d/ -f1-2) || arn=""
  account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || account=""
  newest=""
  for f in "$cache"/*.json; do
    [ -f "$f" ] || continue
    expiry=$(python3 -c "
import json,sys
want, want_account, strict = sys.argv[2], sys.argv[3], sys.argv[4] == '1'
try:
    d=json.load(open(sys.argv[1]))
    c=d.get('Credentials',{})
    who=(d.get('AssumedRoleUser') or {}).get('Arn','')
    # An entry with NO Arn is skipped, and the comment above has always said so while the code did the
    # opposite: the old condition was 'want and who and not startswith', so an empty who fell through to
    # the expiry. This guard exists for the moments when something about the account is wrong, and those
    # are exactly the moments an unidentifiable entry is most likely to be the wrong one.
    #
    # And the comparison is EXACT on the role path rather than a prefix. 'assumed-role/AdminAccess' is a
    # prefix of 'assumed-role/AdminAccessReadOnly', so startswith let a different role's twelve hours
    # stand in for this one's twenty minutes.
    acct = c.get('AccountId','')
    if not want and not want_account:
        print(c.get('Expiration',''))          # nothing to match against; the caller warns
    elif who:
        print(c.get('Expiration','') if '/'.join(who.split('/')[:2]) == want else '')
    elif acct:
        # An account alone may be another role's entry in the same account; the pilot does not take it.
        print(c.get('Expiration','') if acct == want_account and not strict else '')
    else:
        print('')                              # carries no identity at all
except Exception:
    print('')
" "$f" "$arn" "$account" "$strict" 2>/dev/null)
    [ -n "$expiry" ] || continue
    if [ -z "$newest" ] || [[ "$expiry" > "$newest" ]]; then newest="$expiry"; fi
  done
  if [ -z "$arn" ] && [ -n "$strict" ]; then
    fail "sts could not name the active role, so no cache entry can be matched to it and the pilot cannot establish when its credentials end"
  fi
  if [ -z "$arn" ] && [ -z "$account" ]; then
    say "WARNING: sts could not say which role is active, so every cache entry is being trusted and the"
    say "  expiry below may belong to a different profile. This session will be launched on that basis."
  fi
  if [ -z "$newest" ]; then
    [ -z "$strict" ] || fail "no entry in $cache names the active role ${arn:-?} with an expiry, so the pilot cannot establish when its credentials end; re-authenticate with aws sso login --profile <yours>"
    say "no expiry found in $cache; skipping the check"; return 0
  fi
  left=$(python3 -c "
import datetime,sys
e=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))
" "$newest" 2>/dev/null || echo 0)
  # HEADROOM on top of the estimate, because the estimate is a model and the check is about money.
  #
  # This used to be a bare `left >= need`, and on 2026-09-11 it passed a launch with 86 minutes against an
  # estimate of 74 -- twelve minutes of margin on a number nobody had measured. The run had to be killed by
  # hand. A guard that permits a launch it would have refused one minute later is a rounding rule, not a
  # guard.
  #
  # Thirty minutes, flat rather than proportional, because what it covers does not scale with the run: a
  # slow image pull, a Spot interruption and a retry, an arm that hits its rollout timeout instead of its
  # expected time. The evidence download and the terminate call both need credentials AFTER the last cell,
  # and those are the two that cost something when they fail.
  local margin_min="${CREDENTIAL_MARGIN_MIN:-30}"
  say "credentials expire in ${left} min; this session needs about ${need_min} plus ${margin_min} of headroom"
  [ "$left" -ge $(( need_min + margin_min )) ] || fail "credentials expire in ${left} minutes. This session estimates ${need_min} and requires ${margin_min} minutes of headroom on top, because the estimate is a model and the evidence download and the terminate call both come after the last cell. Re-authenticate first -- a run whose credentials die mid-flight cannot terminate its own instance, and the trap that tries will be refused. Type:  aws sso logout; aws sso login --profile <yours>"
}
# The runtime model, refitted on 2026-09-11 against a run that was actually measured.
#
# The first numbers were carried from hack/m5b-price-of-protection.sh, which rents a bare instance and runs
# `docker run`. This one builds a cluster, so the shape is different. What the measured run did, from the
# S3 object timestamps of a session that reached its second arm:
#
#   launch -> user-data executing            63 s
#   -> driver, toolkit, kind, node toolkit    2 min 43 s   (the AMI already ships nvidia-ctk)
#   -> CRDs, RBAC, plugin, first engine ready 8 min        (the 15.6 GB image pull dominates)
#   -> one 420 s replay complete              7 min
#
# So about 11 minutes of bring-up, an 8-minute first engine, and roughly 9 minutes per cell after it. The
# estimate below keeps 25 minutes of fixed cost rather than 11: the measured bring-up had a warm AMI and no
# Spot retry, and a credential check is the wrong place to be optimistic.
# 25 min bring-up + 1.5 min per arm + 7 min per arm-repetition + 15 min for evidence and teardown.
#
# R1 is counted by the loop rather than added afterwards. It used to be a +1 beside it, from when the matrix
# had no R1 arm and the baseline was imagined to come from somewhere else. Now that ARMS carries it, the
# increment would charge the estimate for a fifth arm that does not exist.
# In ladder mode the cell count is two per rung plus the one isolated-baseline cell, and it is an UPPER
# bound: the stopping rule can end the climb early, and a credential check is the wrong place to assume it
# will. arm_count is reused as "engine rollouts to pay for", which is the same number either way.
if [ -n "$LADDER" ]; then
  # Skipped rungs hold a position and cost nothing, so they must not be charged for -- a credential margin
  # built from the list length would demand time for cells this run will not buy.
  rung_count=0; for _r in $LADDER; do case "$_r" in skip) ;; *) rung_count=$(( rung_count + 1 )) ;; esac; done
  [ "$rung_count" -gt 0 ] || fail "LADDER is set but describes no rungs to buy -- every entry was skip, or the list is empty"
  arm_count=$(( rung_count * 2 + 1 ))
else
  arm_count=0; for _a in $ARMS; do arm_count=$(( arm_count + 1 )); done
fi
# The replay minutes come from DURATION_MS, because that is what decides them.
#
# This was a hardcoded 7 per arm-repetition, from a run whose trace was 420 s. The load derivation for a
# half-card engine puts the trace at 505 s and nothing here would have noticed: the check would have
# approved a session on credentials that expire during it, and the first thing to fail would be the evidence
# download -- after the card had been paid for. A ceiling division, plus one minute per cell for the replay
# client's own drain, and never less than the old 7 so a short trace cannot make this optimistic.
replay_min=$(( (DURATION_MS + 59999) / 60000 + 1 ))
if [ "$replay_min" -lt 7 ]; then replay_min=7; fi
# THE DEADLINE IS THE FLOOR HERE, NOT THE MODEL.
#
# The model above counts the trace and the bring-up and nothing else. It does not charge for the per-cell
# engine rollout, so it UNDERSTATES the session -- and the deadline this script arms is deliberately set
# above it. Deriving the credential requirement from the model therefore demanded less time than the run is
# permitted to bill for, and on 2026-10-01 the two drifted 57 minutes apart: HARD_STOP_SECONDS was raised to
# 13200 and BACKSTOP_SECONDS to 13800 while this line still asked for 143 + 30 = 173 minutes. A credential
# with 173 minutes left would have been approved for a run whose own timer lets it bill for 230, and the two
# things that need credentials AFTER the last cell -- the evidence download and the terminate call -- are
# exactly the two that cost money when they fail. That is the 2026-09-08 failure this guard exists to stop,
# arriving by a different route: raising one number and leaving the other alone.
#
# No run can bill past the instance's own backstop, because that timer is what shuts the machine down. So
# the backstop is the honest floor, and taking the larger of the two means raising EITHER number raises the
# requirement. They cannot drift apart again.
need_min=$(( 25 + arm_count * 3 / 2 + arm_count * REPS * replay_min + 15 ))
# The instrument-validation study's cells differ in length, so each is charged its own replay.
#
# Its synchronous arms run once per block and its async arms once in all, as hack/m5c-matrix.sh builds them,
# and each cell's replay floor follows the rule above, including the 7-minute minimum.
if [ -z "$LADDER" ] && iv_is_study "${STUDY:-}"; then
  iv_replay_min=0
  for _a in $ARMS; do
    _ms=$(iv_duration_ms "$STUDY" "$_a") || fail "$_ms"
    _m=$(( (_ms + 59999) / 60000 + 1 )); [ "$_m" -ge 7 ] || _m=7
    case "$_a" in *-async) _n=1 ;; *) _n=$REPS ;; esac
    iv_replay_min=$(( iv_replay_min + _n * _m ))
  done
  need_min=$(( 25 + arm_count * 3 / 2 + iv_replay_min + 15 ))
fi
# The model's own figure, kept so a later charge adds to the model and not to the backstop that floors it.
model_min="$need_min"
backstop_min=$(( BACKSTOP_SECONDS / 60 ))
if [ "$backstop_min" -gt "$need_min" ]; then need_min="$backstop_min"; fi
require_credential_margin "$need_min"

# ---------------------------------------------------------------- what the instance builds from
#
# git archive rather than the working tree: the evidence names a commit somebody can check out, and a build
# from uncommitted changes is provenance that names nothing.
REQUIRE_CLEAN_TREE="${REQUIRE_CLEAN_TREE:-1}"
COMMIT=$(git rev-parse HEAD)
if [ -z "$(git status --porcelain)" ]; then
  say "source $COMMIT, working tree clean"
elif [ "$REQUIRE_CLEAN_TREE" = "1" ]; then
  fail "the working tree is dirty. This session records a commit as the provenance of its numbers. Commit, or set REQUIRE_CLEAN_TREE=0 and accept that the archive will not match the tree you are looking at"
else
  say "source $COMMIT, TREE IS DIRTY and REQUIRE_CLEAN_TREE=0 -- this archive does NOT match the working tree"
fi
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)

say "building the gateway and the harness for the instance, which has no Go"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/gateway" ./cmd/gateway || fail "build gateway"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness || fail "build benchharness"
GATEWAY_SHA=$(sha256sum "$OUT/gateway" | cut -d' ' -f1)
HARNESS_SHA=$(sha256sum "$OUT/benchharness" | cut -d' ' -f1)
say "  gateway ${GATEWAY_SHA:0:12}, benchharness ${HARNESS_SHA:0:12}"
# A study that warms each engine first owes each cell its warm-up as well, and only the generator knows it.
#
# Charged here rather than above because the warm-up's span is read off a generated trace, and this is the
# first line at which the binary that generates it exists.
# One trace per arm at the first seed: a warm-up's span moves with the seed only by the stagger's jitter of
# up to 100 ms per episode, which the fixed 30 s in iv_trace_span_ms covers.
# The credential margin is asked again with the warm-ups added to the model, under the same backstop floor.
if [ -z "$LADDER" ] && iv_has_warmup "${STUDY:-}"; then
  iv_warm_min=0
  _seed=$(printf '%s\n' ${SEEDS:-11} | sed -n 1p)
  for _a in $ARMS; do
    _ms=$(iv_warmup_duration_ms "$STUDY" "$_a") || fail "$_ms"
    _err="$OUT/warmup-plan-$_a.err"
    "$OUT/benchharness" gen-trace --warmup --seed "$_seed" --duration-ms "$_ms" --study "$STUDY" --arm "$_a" \
      --trace-out "$OUT/warmup-plan-$_a.jsonl" --manifest-out "$OUT/warmup-plan-$_a.yaml" >/dev/null 2>"$_err" \
      || fail "gen-trace --warmup could not build $_a's warm-up trace, so its card time is unknown: $(tail -2 "$_err" | tr '\n' ' ')"
    _span=$(iv_trace_span_ms "$OUT/warmup-plan-$_a.jsonl") || fail "$_span"
    case "$_a" in *-async) _n=1 ;; *) _n=$REPS ;; esac
    iv_warm_min=$(( iv_warm_min + _n * ((_span + 59999) / 60000) ))
  done
  say "  warm-ups add ${iv_warm_min} min across the cells"
  need_min=$(( model_min + iv_warm_min ))
  if [ "$backstop_min" -gt "$need_min" ]; then need_min="$backstop_min"; fi
  require_credential_margin "$need_min"
fi

# ---------------------------------------------------------------- AWS scaffolding
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"

say "uploading the source and the binaries"
aws s3 cp "$OUT/source.tgz" "s3://$BUCKET/$RUN_ID/src/source.tgz" >/dev/null || fail "upload the source archive"
aws s3 cp "$OUT/gateway" "s3://$BUCKET/$RUN_ID/bin/gateway" >/dev/null || fail "upload the gateway"
aws s3 cp "$OUT/benchharness" "s3://$BUCKET/$RUN_ID/bin/benchharness" >/dev/null || fail "upload benchharness"

AMI=$(spot_resolve_ami "$REGION" \
  /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id) \
  || fail "could not resolve a GPU AMI"
ZONES=$(spot_zones_offering "$REGION" "$INSTANCE_TYPE")
[ -n "$ZONES" ] || fail "$INSTANCE_TYPE is offered in no availability zone of $REGION"
say "$INSTANCE_TYPE is offered in: $ZONES"

# ---------------------------------------------------------------- what the instance runs
RUNSCRIPT=$(mktemp)
# Armed at the first mktemp so a refusal before `trap cleanup EXIT` cannot leave these files in tmpfs.
# `trap cleanup EXIT` replaces it later, and cleanup removes the same files.
# Bash runs an EXIT trap on INT, TERM and HUP as well, measured 2026-10-04, so this also covers a signal in the window.
trap 'rm -f "${RUNSCRIPT:-}" "${UD:-}"' EXIT
cat > "$RUNSCRIPT" <<'USERDATA'
#!/bin/bash
exec > >(tee /var/log/m5c.log) 2>&1
set -x
( sleep BACKSTOP_SECONDS_PLACEHOLDER; shutdown -h now ) &

BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
SOURCE_SHA="SOURCE_SHA_PLACEHOLDER"
GATEWAY_SHA="GATEWAY_SHA_PLACEHOLDER"
HARNESS_SHA="HARNESS_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
REPS="REPS_PLACEHOLDER"
ARMS="ARMS_PLACEHOLDER"
RATE="RATE_PLACEHOLDER"
PREMIUM_WEIGHT="PREMIUM_WEIGHT_PLACEHOLDER"
NOISY_WEIGHT="NOISY_WEIGHT_PLACEHOLDER"
PROBE_WEIGHT="PROBE_WEIGHT_PLACEHOLDER"
DURATION_MS="DURATION_MS_PLACEHOLDER"
LADDER="LADDER_PLACEHOLDER"
LADDER_STUDY="LADDER_STUDY_PLACEHOLDER"
SWEEP="SWEEP_PLACEHOLDER"
# Not PREMIUM_RATE_PLACEHOLDER: the RATE substitution runs first and matches inside that name.
PREMIUM_RATE="HELD_LC_PER_SEC_PLACEHOLDER"
# The pilot's stage, contender rate and static rate R. Named so no earlier substitution matches inside them.
PILOT_STAGE="PILOT_STAGE_PLACEHOLDER"
PILOT_NOISY_RATE="PILOT_CONTENDER_PER_SEC_PLACEHOLDER"
PILOT_STATIC_RATE="PILOT_STATIC_R_PLACEHOLDER"
# The rest of the load, which used to stay on the laptop.
#
# The ninth pilot's user-data carries no PREMIUM_PROMPT_CHARS, no MODEL_REVISION and no REQUEST_TIMEOUT_MS
# -- and the OUTPUT CAPS were added to this block on 2026-10-01 for exactly the same reason, one layer
# further out. The caps became CR-declared that day, hack/m5c-matrix.sh learned to pass them to
# gen-trace, and this wrapper did not send them: the matrix would have defaulted them and the compiled
# value would have died on the laptop. The spot-lifecycle goldens did not notice, because what they
# transcribe is THIS script's user-data -- so their silence was evidence of the gap rather than of
# safety.
# -- checked, zero occurrences -- so every paid run so far used the matrix's own defaults for them: 200 and
# 40,000 characters, and a revision this wrapper never chose. The resolved lengths measured against the
# served tokenizer (1,174 and 42,579) had therefore never reached a rented card.
#
# They are empty when no compiled CR supplied them, and the matrix defaults exactly as before. A compiled
# run fills them, and the matrix's compiled-CR block then refuses any disagreement.
PREMIUM_PROMPT_CHARS="PREMIUM_PROMPT_CHARS_PLACEHOLDER"
NOISY_PROMPT_CHARS="NOISY_PROMPT_CHARS_PLACEHOLDER"
REQUEST_TIMEOUT_MS="REQUEST_TIMEOUT_MS_PLACEHOLDER"
PREMIUM_OUTPUT_TOKENS="PREMIUM_OUTPUT_TOKENS_PLACEHOLDER"
NOISY_OUTPUT_TOKENS="NOISY_OUTPUT_TOKENS_PLACEHOLDER"
MODEL_REVISION="MODEL_REVISION_PLACEHOLDER"
# The study travels under BOTH names, from one placeholder, and the reason is that they are read by
# different checks.
#
# STUDY is what the matrix files its evidence under. STUDY_FROM_CR is what a compiled plan was compiled FOR,
# and the matrix compares the two. Until today only the second reached the instance, so a run asked for
# tail-crossing-lc8192-2026-10-04 arrived with STUDY unset, the matrix defaulted it to the sharing matrix,
# and the long level's 42,579-character load then collided with that study's frozen 1,174 -- a refusal that
# arrives AFTER the card is rented. The runner's own allow-list is what defends the identity now; this line
# is what gives it something to defend.
#
# Sharing one placeholder is deliberate: both come from the caller's STUDY, so they cannot disagree here.
# The comparison in the matrix is still worth keeping, because the compiled-CR path can set STUDY_FROM_CR
# from a block whose study differs from the one this session was told.
STUDY="STUDY_PLACEHOLDER"
STUDY_FROM_CR="STUDY_PLACEHOLDER"
# One seed per repetition for a study registering a trace per repetition; empty keeps the matrix's seed 11.
SEEDS="SEEDS_PLACEHOLDER"
BENCHMARK_CR_SHA256="BENCHMARK_CR_SHA256_PLACEHOLDER"
BENCHMARK_CR_TOKENIZER_REV="BENCHMARK_CR_TOKENIZER_REV_PLACEHOLDER"
# The deadline the matrix budgets its cells against is the EARLIER of the two, not the instance's.
#
# The instance's own backstop is BACKSTOP_SECONDS and this shell gives up at HARD_STOP_SECONDS, which is
# sooner. Handing the matrix the later one let it approve a remaining workload that fits the instance and
# not the wrapper: the wrapper then terminates mid-cell, and because the evidence is archived only after the
# matrix RETURNS, every cell completed before that point leaves with the instance.
DEADLINE_EPOCH=$(( $(date +%s) + HARD_STOP_SECONDS_PLACEHOLDER ))
# The pilot's matrix stops at an absolute instant the wrapper chose before launch: its acquisition deadline less
# the session tail's reserve. Counted from this boot instead, it ran about the bring-up's 25 minutes past the
# moment the wrapper terminates the instance.
PILOT_MATRIX_DEADLINE="PILOT_MATRIX_DEADLINE_PLACEHOLDER"
[ -z "$PILOT_MATRIX_DEADLINE" ] || DEADLINE_EPOCH="$PILOT_MATRIX_DEADLINE"

upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/m5c.log log.txt; shutdown -h now' EXIT

# Verified before it is trusted: a truncated download that still extracts produces a build, and a build
# produces numbers.
aws s3 cp "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
got=$(sha256sum /tmp/source.tgz | cut -d' ' -f1)
if [ "$got" != "$SOURCE_SHA" ]; then echo "source checksum mismatch: $SOURCE_SHA vs $got"; exit 1; fi
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src
cd /src
echo "$COMMIT" > /tmp/commit.txt && upload /tmp/commit.txt commit.txt

mkdir -p /src/bin
for b in gateway benchharness; do
  aws s3 cp "s3://$BUCKET/$PREFIX/bin/$b" "/src/bin/$b"
  chmod +x "/src/bin/$b"
done
got=$(sha256sum /src/bin/gateway | cut -d' ' -f1)
if [ "$got" != "$GATEWAY_SHA" ]; then echo "gateway checksum mismatch"; exit 1; fi
got=$(sha256sum /src/bin/benchharness | cut -d' ' -f1)
if [ "$got" != "$HARNESS_SHA" ]; then echo "benchharness checksum mismatch"; exit 1; fi

# Preflight 1: the card. A machine that does not report one A10G is not what this session was costed for,
# and finding that out after twenty minutes of cluster bring-up is finding it out too late.
#
# driver_version is asked for because two runs on the same card model disagreed and nothing could compare it.
#
# On 2026-10-02 a five-repetition run put `timeSlicing` at 14,868 ms where the 2026-09-13 pilot had 1,008.
# The leading explanation is the prompt length, which IS recorded, but the two candidates behind it are the
# engine build and the driver -- and neither archive carried a driver version, because this query asked for
# index, name and memory and nothing else. So the question "how much of a 14.75x change was the driver"
# cannot be asked of any archive this project has. One field closes that for every run after this one; it
# cannot be closed backwards. The row count is what the card check below reads, so an extra column is free.
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
cards=$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)
if [ "$cards" -ne 1 ]; then
  echo "PREFLIGHT FAILED: $cards cards; this matrix splits ONE card and two engines on two cards are not sharing"
  exit 1
fi

# The host's docker, configured to hand the card to a container.
#
# This is NOT in the rehearsable span below: it installs packages as root and rewrites
# /etc/nvidia-container-runtime/config.toml, which is the instance's business and nobody's laptop's. The
# span starts where the recipe stops needing a machine with a card in it.
export DEBIAN_FRONTEND=noninteractive
if ! command -v nvidia-ctk >/dev/null; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit || exit 1
fi
nvidia-ctk runtime configure --runtime=docker --set-as-default
sed -i 's/^#accept-nvidia-visible-devices-as-volume-mounts.*/accept-nvidia-visible-devices-as-volume-mounts = true/' \
  /etc/nvidia-container-runtime/config.toml || true
grep -q 'accept-nvidia-visible-devices-as-volume-mounts = true' /etc/nvidia-container-runtime/config.toml \
  || echo 'accept-nvidia-visible-devices-as-volume-mounts = true' >> /etc/nvidia-container-runtime/config.toml
systemctl restart docker
sleep 5

# >>> REHEARSABLE -- everything to the matching marker needs no GPU and no root.
#
# hack/test/rehearse-bringup.sh extracts exactly this span and runs it on a development machine, driven with
# RUNNER=hack/m5c-gpu-session.sh. It exists because the first thing ever to execute these lines would
# otherwise be a rented instance, which is how a kubeconfig path this repository had asserted without
# checking cost a whole session.
#
# The span begins here rather than at the toolkit install above, which needs root and a card. It ends where
# the recipe starts reaching into the node container for the same toolkit -- the first thing that genuinely
# needs hardware, and the only part the instance should be discovering.
curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# One worker, and the cards reach it through the mount rather than through any GPU environment.
#
# accept-nvidia-visible-devices-as-volume-mounts tells the container runtime to read a mount under
# /var/run/nvidia-container-devices/ as if it were NVIDIA_VISIBLE_DEVICES. A kind node is an ordinary
# container that nobody passes that variable to, so the mount is how it ends up with the card. The first
# session to get this far had the setting and not the mount, which is half a recipe: the node saw no devices
# and the plugin advertised zero.
# The kubelet's container-log rotation is raised from its 10 MiB default, because an engine log longer than that
# was rotated and `kubectl logs` returns only the newest file: the S1 confirmation's staggered cells wrote about
# 11.4 MiB and lost their first 38,000 iterations (docs/superpowers/specs/2026-10-07-confirming-s1-on-unseen-settings.md).
cat > /tmp/kind.yaml <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: m5cgpu
kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    containerLogMaxSize: 200Mi
    containerLogMaxFiles: 2
nodes:
  - role: control-plane
  - role: worker
    extraMounts:
      - hostPath: /dev/null
        containerPath: /var/run/nvidia-container-devices/all
KINDEOF
# Told to kind rather than guessed from it: cloud-init runs user-data with HOME unset, and kind with no HOME
# writes .kube/config RELATIVE TO THE WORKING DIRECTORY. A session died three minutes in that way, with kind
# reporting success while the next kubectl talked to localhost:8080.
export KUBECONFIG=/tmp/kubeconfig
kind create cluster --config /tmp/kind.yaml --kubeconfig "$KUBECONFIG" --wait 300s || exit 1
kubectl cluster-info || { echo "PREFLIGHT FAILED: the cluster is up but unreachable through $KUBECONFIG"; exit 1; }

# The CRDs, with kustomize rather than `make install`: that target depends on `manifests`, which runs
# controller-gen and rewrites generated files. The CRDs are committed; building them is all that is needed.
kubectl kustomize config/crd | kubectl apply -f - || exit 1

# The gateway's ClusterRole, through the OVERLAY and not the bare file.
#
# config/gateway/rbac.yaml says `namespace: system`, which is kubebuilder's placeholder; the overlay is what
# rewrites it. Applying the file directly is refused with `namespaces "system" not found`, and
# hack/m5c-matrix.sh refuses to start without the ClusterRole because a binding to a missing one is accepted
# by Kubernetes and then fails authorization on every request, with nothing looking wrong until the first
# replay. Only the RBAC kinds: the overlay also carries a gateway Deployment pinned to an ECR digest, and the
# matrix deploys its own gateway from the binary shipped above.
kubectl create ns gpu-platform-control-plane-system --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize config/gateway > /tmp/gateway-all.yaml || exit 1
awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding|ServiceAccount)(\n|$)/ {print "---"; print $0}' \
  /tmp/gateway-all.yaml > /tmp/gateway-rbac.yaml
grep -q "name: gateway-role" /tmp/gateway-rbac.yaml || { echo "PREFLIGHT FAILED: no gateway-role in the rendered overlay"; exit 1; }
kubectl apply -f /tmp/gateway-rbac.yaml || exit 1

# The toolkit is needed INSIDE the node as well, and that is a second configuration rather than the same one.
#
# Everything above configures the HOST's docker, which is what puts the card into the node container. Pods do
# not run on the host's docker; they run on the containerd inside that node, which knows nothing about any of
# it -- so the device plugin starts with no NVML and dies, and DCGM agrees that NVML does not exist. The node
# image ships neither nvidia-ctk nor /sbin/ldconfig.real, so both are put there.
docker exec m5cgpu-worker ln -sf /sbin/ldconfig /sbin/ldconfig.real || exit 1
docker exec m5cgpu-worker bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl gnupg ca-certificates
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=containerd --set-as-default
' || { echo "PREFLIGHT FAILED: could not configure the container runtime inside m5cgpu-worker"; exit 1; }

# Restarting containerd takes the kubelet's runtime out from under it, so the node is waited for rather than
# assumed back. Anything applied before it is Ready would land on a NotReady node.
docker exec m5cgpu-worker systemctl restart containerd || exit 1
kubectl wait --for=condition=Ready node/m5cgpu-worker --timeout=300s \
  || { echo "PREFLIGHT FAILED: m5cgpu-worker did not come back Ready after its containerd was restarted"; exit 1; }
# <<< REHEARSABLE
#
# The span ends HERE and not at the RBAC above, because everything between the two needs no card: installing
# the toolkit inside the node container and pointing its containerd at it are apt-get and a config rewrite,
# and both fail the same way on a laptop as on a rented machine. The first line past this marker asks the
# node for its cards, which is the first thing that genuinely needs one.
docker exec m5cgpu-worker nvidia-smi -L > /tmp/node-cards.txt 2>&1 || echo "(nvidia-smi failed inside the node)" >> /tmp/node-cards.txt
upload /tmp/node-cards.txt preflight-node-cards.txt

# ---------------------------------------------------------------- the matrix
#
# Everything the matrix needs that it refuses to default: the platform, the deadline it measures cell budgets
# against, the shipped binaries, and the whole load.
export KUBECONFIG=/tmp/kubeconfig
export PLATFORM=kind
export KCTX=kind-m5cgpu
export GPU_NODE=m5cgpu-worker
export DEADLINE_EPOCH
export GATEWAY_BIN=/src/bin/gateway
export BENCHHARNESS_BIN=/src/bin/benchharness
# In ladder mode these are UNSET rather than emptied, and the difference is the whole thing.
#
# The matrix asks whether the caller SET ARMS with ${ARMS+set}, which is non-empty for a variable set to the
# empty string. Exporting ARMS="" would therefore look exactly like an operator passing an arm list beside a
# ladder, and the matrix would refuse -- on the rented card, after the bring-up. `unset` is what makes the
# question mean what it asks.
if [ -n "$LADDER" ]; then
  unset RATE NOISY_WEIGHT ARMS REPS
  export PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS LADDER LADDER_STUDY
elif [ -n "$SWEEP" ]; then
  # The matrix builds a sweep's arms from SWEEP and refuses an ARMS beside it, for the reason given above.
  unset RATE NOISY_WEIGHT ARMS
  export PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS REPS SWEEP PREMIUM_RATE
elif [ -n "$PILOT_STAGE" ]; then
  # The pilot's arms are its stage's, and the matrix refuses an ARMS or a weighted RATE beside it.
  unset RATE NOISY_WEIGHT ARMS
  export PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS REPS PREMIUM_RATE PILOT_STAGE PILOT_NOISY_RATE
  if [ -n "$PILOT_STATIC_RATE" ]; then export PILOT_STATIC_RATE; fi
else
  export RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT DURATION_MS REPS ARMS
fi
# Exported only when they carry something, because the matrix treats an EMPTY value differently from an
# unset one: PREMIUM_PROMPT_CHARS="" would reach gen-trace as an empty flag argument rather than falling
# back to the default, and BENCHMARK_CR_SHA256="" would switch on a compiled-CR guard for a run that has no
# compiled CR. So an uncompiled run exports none of them and behaves exactly as it did before.
#
# `if` rather than `[ ... ] && export`, because the last iteration of that form leaves status 1 behind and
# this script runs under `set -e`. Measured: the loop with every value empty exits 1, and what happens next
# then depends on whichever line follows -- a run that dies here would die after the card is up.
# STUDY is on this list rather than the unconditional one above, and the distinction matters.
#
# The matrix defaults an unset STUDY to the sharing matrix, which is what every existing caller relies on.
# Exporting STUDY="" would hand it an EMPTY value instead of an absent one, and its allow-list would then
# judge the empty string rather than falling back -- so a run that names no study must export none. This is
# the same rule the five load values follow for the same reason.
for v in PREMIUM_PROMPT_CHARS NOISY_PROMPT_CHARS REQUEST_TIMEOUT_MS MODEL_REVISION \
         PREMIUM_OUTPUT_TOKENS NOISY_OUTPUT_TOKENS \
         BENCHMARK_CR_SHA256 BENCHMARK_CR_TOKENIZER_REV STUDY STUDY_FROM_CR SEEDS; do
  if [ -n "${!v}" ]; then export "${v?}"; fi
done
export OUT=/src/m5c-run

# Each cell goes up the moment it is bought, so an instance that STOPS does not take the cells before it.
#
# The archive below still runs and is still the complete record; this is a second copy of each raw file,
# written while the card is still being paid for. A Spot interruption is the case: the matrix's own failure
# paths all reach the archive, and an interruption reaches nothing.
cat > /usr/local/bin/m5c-cell-done <<'CELLHOOK'
#!/bin/bash
# $1 raw file, $2 arm, $3 repetition; $OUT is read from the environment. Failure here must not fail the
# cell: the evidence is on local disk either way, and a transient S3 error is not a reason to discard a
# measurement that was paid for.
#
# WHAT THIS USED TO SEND, AND WHY THAT WAS NOT A CELL. It copied the raw file alone. Measured against the
# 2026-10-02 run's own bucket: `cells/` holds 15 objects, all `raw-*.jsonl`, while the manifest, the trace,
# the port-forward log and every accumulating TSV existed only inside the end-of-run `evidence.tgz`. So an
# instance that went away mid-run left rows nobody could place -- no manifest to say what load produced
# them, no trace to check them against, no cell-environment.tsv to name the card they ran on. The whole
# point of a per-cell upload is that the cell survives the instance, and a row without its manifest does not.
#
# The accumulating files are re-sent on EVERY cell rather than once at the end. They are small, they are
# rewritten as the run proceeds, and the copy that matters is the last one that made it off the machine.
set -u
raw="$1"; arm="$2"; rep="$3"
out="${OUT:-$(dirname "$raw")}"
base="s3://__BUCKET__/__PREFIX__/cells"
missing=""
send() { # <path> <s3 name>; records the name when it does not go up
  [ -f "$1" ] || return 0
  aws s3 cp "$1" "$base/$2" >/dev/null 2>&1 || missing="$missing $2"
}
# This cell's four files, named so one cell's set cannot be confused with another's.
for kind in raw trace manifest; do
  case "$kind" in
    raw|trace) ext=jsonl ;;
    manifest)  ext=yaml ;;
  esac
  send "$out/$kind-$arm-$rep.$ext" "$kind-$arm-$rep.$ext"
done
send "$out/port-forward-$arm-$rep.log" "port-forward-$arm-$rep.log"
# The engine's counters from both sides of the replay, one file per engine per phase, .prom or .err.
# They are the only server-side evidence a cell has, so a cell that survives the instance without them is
# the cell the 2026-10-04 registration could not decompose.
for f in "$out"/engine-metrics-"$arm"-"$rep"-*.prom "$out"/engine-metrics-"$arm"-"$rep"-*.err; do
  [ -f "$f" ] || continue
  send "$f" "$(basename "$f")"
done
# The engine's own log for this cell, written only under the instrument-validation study.
# Its iteration lines are that study's measurement, so a cell that survives without them is not a cell.
send "$out/engine-log-$arm-$rep.txt" "engine-log-$arm-$rep.txt"
# A step-boundary -step cell's instrument log and the sha256 of the instrument it ran, absent for every other cell.
send "$out/step-log-$arm-$rep.jsonl" "step-log-$arm-$rep.jsonl"
send "$out/step-plugin-$arm-$rep.sha256" "step-plugin-$arm-$rep.sha256"
# The warm-up's rows, its boundary, and the trace and manifest it replayed, written only under session 2.
# The boundary is what separates the log's warm-up iterations from the measured ones, so the log without it
# cannot be split.
send "$out/raw-warmup-$arm-$rep.jsonl" "raw-warmup-$arm-$rep.jsonl"
send "$out/warmup-boundary-$arm-$rep.txt" "warmup-boundary-$arm-$rep.txt"
send "$out/warmup-trace-$arm-$rep.jsonl" "warmup-trace-$arm-$rep.jsonl"
send "$out/warmup-manifest-$arm-$rep.yaml" "warmup-manifest-$arm-$rep.yaml"
# The prospective-admission pilot's per-cell evidence: the gateway's own record, the sender's configuration, the
# fence's answer and an ineligibility reason, each absent for every other study. Without them a cell that survives
# the instance has rows nothing can time or join (review of 20cbf33).
send "$out/gateway-record-$arm-$rep.jsonl" "gateway-record-$arm-$rep.jsonl"
send "$out/raw-$arm-$rep.jsonl.sender.json" "raw-$arm-$rep.jsonl.sender.json"
send "$out/fence-$arm-$rep.json" "fence-$arm-$rep.json"
send "$out/ineligible-$arm-$rep.txt" "ineligible-$arm-$rep.txt"
# Its engine samples during the replay: running and waiting requests, KV usage and preemptions, one line a second.
send "$out/engine-samples-$arm-$rep.tsv" "engine-samples-$arm-$rep.tsv"
# The run-wide records, refreshed so the newest surviving copy is the newest one written. phases.tsv and
# cell-uploads.tsv are the pilot's; cell-uploads.tsv gains each cell's line after its own hook, so this cell's
# hook carries the previous cell's line, and the last line goes with the final archive.
for f in cell-environment.tsv cell-timings.tsv cell-judgements.tsv applied-values.tsv load-source.txt \
         phases.tsv cell-uploads.tsv calibration.txt sidecar-uploads.tsv; do
  send "$out/$f" "$f"
done
# A refusal or an invalidation is per ARM, so it appears partway through a run and must travel too.
# cell-refused-* is a cell the matrix stopped on, with its reason; without it a session that dies before the final
# archive leaves the stop unexplained in the bucket (found by review).
for f in "$out"/refused-*.txt "$out"/invalid-*.txt "$out"/cell-refused-*.txt; do
  [ -f "$f" ] || continue
  send "$f" "$(basename "$f")"
done
if [ -n "$missing" ]; then
  # Named, not counted. "3 files failed" sends an operator to look at all of them.
  echo "  cell $arm rep $rep: these did NOT reach the bucket:$missing"
  exit 1
fi
echo "  cell $arm rep $rep uploaded as it completed, with its manifest, trace, port-forward log and the run records"
CELLHOOK
sed -i "s|__BUCKET__|$BUCKET|; s|__PREFIX__|$PREFIX|" /usr/local/bin/m5c-cell-done
chmod +x /usr/local/bin/m5c-cell-done
export CELL_DONE_HOOK=/usr/local/bin/m5c-cell-done

# The pilot's evidence sidecar (hack/lib/prospective-pilot.sh, pp_sidecar_start): during each replay the matrix
# hands it the live rows and the gateway's record every 30 s, and at once when the Spot notice below appears.
# They go under live/, apart from the per-cell uploads, so a later complete file is never overwritten by a live one.
if [ -n "$PILOT_STAGE" ]; then
  cat > /usr/local/bin/m5c-sidecar <<'SIDECAR'
#!/bin/bash
for f in "$1" "$2"; do
  [ -f "$f" ] && aws s3 cp --only-show-errors "$f" "s3://__BUCKET__/__PREFIX__/live/$(basename "$f")" || exit 1
done
SIDECAR
  sed -i "s|__BUCKET__|$BUCKET|; s|__PREFIX__|$PREFIX|" /usr/local/bin/m5c-sidecar
  chmod +x /usr/local/bin/m5c-sidecar
  export CELL_SIDECAR_HOOK=/usr/local/bin/m5c-sidecar
  # The Spot notice, polled from the metadata service every 5 s with an IMDSv2 token. The two-minute warning is far
  # longer than one upload, so the sidecar's flush on it can finish.
  export PP_SPOT_NOTICE_FILE=/tmp/spot-notice
  (
    # Each request bounded at 2 s, so a stalled metadata call cannot use up the two-minute warning (review of c4eef3d).
    while :; do
      imds_token=$(curl -s --connect-timeout 1 --max-time 2 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" \
        http://169.254.169.254/latest/api/token || true)
      code=$(curl -s --connect-timeout 1 --max-time 2 -o /tmp/spot-instance-action -w '%{http_code}' \
        -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/spot/instance-action || true)
      if [ "$code" = 200 ]; then
        cp /tmp/spot-instance-action "$PP_SPOT_NOTICE_FILE"
        # The notice itself leaves the instance, beside the live snapshots, as the evidence of the interruption.
        aws s3 cp --only-show-errors /tmp/spot-instance-action "s3://$BUCKET/$PREFIX/live/spot-notice.json" || true
        break
      fi
      sleep 5
    done
  ) &
fi

# The commit this session shipped, which the matrix cannot work out for itself here.
#
# hack/m5c-matrix.sh derives SOURCE_COMMIT with `git rev-parse` when it is unset, and the instance unpacks a
# source TARBALL with no .git -- so it fell back to the literal string "unknown" and wrote that into every
# manifest as gatewaySHA. The 2026-09-16 ladder was bought that way: seven paid manifests naming no build,
# past a --require-provenance that only refused an EMPTY value. The commit was known here all along.
export SOURCE_COMMIT="$COMMIT"

# The pilot's matrix is ended at its absolute deadline, because nothing inside it stops for time: the pilot has no
# projection stop, so DEADLINE_EPOCH alone bounded nothing, and the matrix could run into the tail reserve until
# the wrapper terminated the instance, archive and all (review of 9496808). A cell cut here is lost; the archive,
# the per-cell uploads already made and the marker's absence say so. At least 1 s, since timeout reads 0 as no limit.
if [ -n "$PILOT_MATRIX_DEADLINE" ]; then
  matrix_left=$(( PILOT_MATRIX_DEADLINE - $(date +%s) ))
  [ "$matrix_left" -ge 1 ] || matrix_left=1
  timeout --kill-after=30 "$matrix_left" bash hack/m5c-matrix.sh; matrix_rc=$?
  [ "$matrix_rc" != 124 ] || echo "matrix stopped at the pilot's deadline, $(date -u -d "@$PILOT_MATRIX_DEADLINE" +%H:%M:%SZ)"
else
  bash hack/m5c-matrix.sh; matrix_rc=$?
fi
echo "matrix exited $matrix_rc"
# When the matrix returned, so the session tail -- from here to the marker's upload -- can be measured.
date +%s > /tmp/matrix-returned.txt
upload /tmp/matrix-returned.txt matrix-returned.txt

# The evidence goes up whatever happened. A matrix that stopped on a cell boundary still bought every cell
# before it, and those are the cells a partial answer is made of.
if [ -d /src/m5c-run ]; then
  tar -czf /tmp/m5c-evidence.tgz -C /src m5c-run
  upload /tmp/m5c-evidence.tgz evidence.tgz
fi
kubectl get nodes -o wide > /tmp/nodes.txt 2>&1 || true
upload /tmp/nodes.txt nodes.txt

# The marker is written LAST and only on success, because it is what the waiting shell reads as "the records
# are up". A marker written unconditionally would report a matrix that failed as a matrix that finished.
if [ "$matrix_rc" = "0" ]; then
  echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
  aws s3 cp /tmp/DONE "s3://$BUCKET/$PREFIX/DONE"
fi
USERDATA

# The pilot's two deadlines (design page, "a hard stop that is a deadline, not a count"), from a clock started
# before the launch, so both fall no later than they would counted from the launch itself.
# The acquisition deadline leaves the 6-minute termination reserve before the hard stop. The matrix on the
# instance stops a further PILOT_TAIL_RESERVE_S earlier, so its archive and marker can be up before the wrapper
# stops waiting. The pilot measured that tail at 12 s in both stages (design page, "Pilot results"), so the reserve
# is 2 minutes, ten times it; at 10 minutes it cut 8 minutes off the diagnostic's registered acquisition window
# (final review, finding 5).
# The study-deadline tag the sweeper reads (infra/aws/bootstrap/sweeper.tf) is the hard stop plus 20 minutes, set
# in the launch's own tag specifications so it exists the moment the instance does.
PILOT_ACQ_DEADLINE=""
PILOT_MATRIX_DEADLINE=""
PILOT_STUDY_DEADLINE=""
PILOT_TAIL_RESERVE_S=120
if [ -n "${PILOT_STAGE:-}" ]; then
  _t0=$(date +%s)
  PILOT_ACQ_DEADLINE=$(( _t0 + HARD_STOP_SECONDS - 360 ))
  PILOT_MATRIX_DEADLINE=$(( PILOT_ACQ_DEADLINE - PILOT_TAIL_RESERVE_S ))
  PILOT_STUDY_DEADLINE=$(date -u -d "@$(( _t0 + HARD_STOP_SECONDS + 1200 ))" +%Y-%m-%dT%H:%M:%SZ)
fi

UD="$(mktemp)"
{
  # The shebang, re-emitted because the stripping below removes the heredoc's own.
  #
  # `tail -n +2` drops line 1, which is `#!/bin/bash`, and cloud-init runs user-data as a script ONLY when
  # it begins with `#!`. Without this line the instance boots, cloud-init treats the payload as an unknown
  # content type, nothing executes, and the machine sits idle until its backstop -- with no log, because the
  # trap that uploads one is inside the script that never ran.
  #
  # It is not a detail: omitting it cost a g5.2xlarge for 145 minutes on 2026-09-11, about $1.64, and bought
  # nothing. Every other runner in this directory has this line; this file was written from the shape of
  # theirs and dropped it, which is the "second copy written from memory of the first" that hack/lib/spot-run.sh
  # exists to argue against.
  echo "#!/bin/bash"
  sed -e "s|BACKSTOP_SECONDS_PLACEHOLDER|$BACKSTOP_SECONDS|g" \
      -e "s|HARD_STOP_SECONDS_PLACEHOLDER|$HARD_STOP_SECONDS|g" \
      -e "s|BUCKET_PLACEHOLDER|$BUCKET|" \
      -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" \
      -e "s|SOURCE_SHA_PLACEHOLDER|$SOURCE_SHA|" \
      -e "s|GATEWAY_SHA_PLACEHOLDER|$GATEWAY_SHA|" \
      -e "s|HARNESS_SHA_PLACEHOLDER|$HARNESS_SHA|" \
      -e "s|COMMIT_PLACEHOLDER|$COMMIT|" \
      -e "s|REPS_PLACEHOLDER|$REPS|" \
      -e "s|ARMS_PLACEHOLDER|$ARMS|" \
      -e "s|RATE_PLACEHOLDER|$RATE|" \
      -e "s|PREMIUM_WEIGHT_PLACEHOLDER|$PREMIUM_WEIGHT|" \
      -e "s|NOISY_WEIGHT_PLACEHOLDER|$NOISY_WEIGHT|" \
      -e "s|PROBE_WEIGHT_PLACEHOLDER|$PROBE_WEIGHT|" \
      -e "s|DURATION_MS_PLACEHOLDER|$DURATION_MS|" \
      -e "s|LADDER_PLACEHOLDER|$LADDER|" \
      -e "s|LADDER_STUDY_PLACEHOLDER|${LADDER_STUDY:-}|" \
      -e "s|SWEEP_PLACEHOLDER|${SWEEP:-}|" \
      -e "s|HELD_LC_PER_SEC_PLACEHOLDER|${PREMIUM_RATE:-}|" \
      -e "s|PILOT_STAGE_PLACEHOLDER|${PILOT_STAGE:-}|" \
      -e "s|PILOT_CONTENDER_PER_SEC_PLACEHOLDER|${PILOT_NOISY_RATE:-}|" \
      -e "s|PILOT_STATIC_R_PLACEHOLDER|${PILOT_STATIC_RATE:-}|" \
      -e "s|PILOT_MATRIX_DEADLINE_PLACEHOLDER|${PILOT_MATRIX_DEADLINE:-}|" \
      -e "s|PREMIUM_PROMPT_CHARS_PLACEHOLDER|${PREMIUM_PROMPT_CHARS:-}|" \
      -e "s|NOISY_PROMPT_CHARS_PLACEHOLDER|${NOISY_PROMPT_CHARS:-}|" \
      -e "s|REQUEST_TIMEOUT_MS_PLACEHOLDER|${REQUEST_TIMEOUT_MS:-}|" \
      -e "s|PREMIUM_OUTPUT_TOKENS_PLACEHOLDER|${PREMIUM_OUTPUT_TOKENS:-}|" \
      -e "s|NOISY_OUTPUT_TOKENS_PLACEHOLDER|${NOISY_OUTPUT_TOKENS:-}|" \
      -e "s|MODEL_REVISION_PLACEHOLDER|${MODEL_REVISION:-}|" \
      -e "s|STUDY_PLACEHOLDER|${STUDY:-}|" \
      -e "s|SEEDS_PLACEHOLDER|${SEEDS:-}|" \
      -e "s|BENCHMARK_CR_SHA256_PLACEHOLDER|${BENCHMARK_CR_SHA256:-}|" \
      -e "s|BENCHMARK_CR_TOKENIZER_REV_PLACEHOLDER|${BENCHMARK_CR_TOKENIZER_REV:-}|" \
      -e "s|RUN_NONCE_PLACEHOLDER|$RUN_NONCE|" "$RUNSCRIPT" | tail -n +2 \
    | sed -e '/^#/d' -e '/^[[:space:]]*$/d'
} > "$UD"

# The comments come off on the way out, and only on the way out.
#
# EC2 caps user-data at 25600 bytes ENCODED, and an earlier session's explanations grew past it: 19,914 raw
# became 26,552 base64 and all three zones returned InvalidParameterValue. The comments are why anything here
# is the way it is and they stay in the tracked file. Only column-0 comments are dropped, because the
# indented ones inside the kind.yaml heredoc are YAML a reader of the launched configuration should still
# see -- and deleting by indentation rather than by content is the rule that cannot cut a line out of a
# string.
cp "$UD" "$OUT/user-data.sh"
# The FIRST thing checked, because it is the one `bash -n` cannot see.
#
# A script with no shebang parses perfectly and does not run. cloud-init needs `#!` on line 1 to execute the
# payload at all, so this check is the difference between a run that fails and a run that silently does
# nothing for two hours on a card that is billing.
head -1 "$UD" | grep -q '^#!' \
  || fail "the generated user-data does not begin with a shebang, so cloud-init would not execute it and the instance would boot, do nothing, and bill until its backstop. See $OUT/user-data.sh"
bash -n "$UD" || fail "the generated user-data does not parse after its comments were stripped; see $OUT/user-data.sh"
grep -q 'containerPath: /var/run/nvidia-container-devices/all' "$UD" \
  || fail "the generated user-data lost the device mount, so the stripping cut something that mattered"
grep -q 'PLACEHOLDER' "$UD" \
  && fail "a placeholder survived substitution; the instance would run a script with a literal PLACEHOLDER in it. See $OUT/user-data.sh"

UD_LIMIT="${UD_LIMIT:-25600}"
UD_ENCODED=$(base64 -w0 "$UD" | wc -c)
if [ "$UD_ENCODED" -gt "$UD_LIMIT" ]; then
  fail "the user-data encodes to $UD_ENCODED bytes and EC2 accepts $UD_LIMIT. Nothing was launched. Move the bulk out of the heredoc rather than trimming prose: see $OUT/user-data.sh"
fi
say "user-data: $UD_ENCODED of $UD_LIMIT encoded bytes"

# THE PURCHASE PLAN IS CHECKED LOCALLY, BEFORE run-instances.
#
# It runs the real matrix in PLAN_ONLY mode, which generates every planned cell's trace with the real
# gen-trace and asks the real bench.LadderPlanRefusal whether the readings could score it. Every refusal it
# applies used to arrive ON THE CARD: `replay` validates the arm against its study after the engines are up,
# and the cell floors are applied after the replay finishes.
#
# The case that motivated it is not hypothetical. Omit DURATION_MS and this wrapper supplies 420000, which
# at the registered downward ladder's bottom rung generates 470 premium requests against a floor of 500 --
# a run that would have deployed, replayed and then been refused, for a bring-up each time.
#
# It uses the SAME binary the instance will run, so a check that passes here and fails there is a
# difference in the world rather than in the code.
#
# IT RUNS ON EVERY RUN, and it used to run only for a ladder.
#
# A frozen matrix therefore reached run-instances with nothing having asked whether its cells could be
# scored. DRY_RUN looked like that check and is not: it validates the user-data -- shebang, parse, surviving
# placeholder, device mount, encoded size -- and never generates a trace. The frozen matrix's floors are the
# same shape as the ladder's and arrive the same way, after the bring-up.
say "checking the purchase plan locally, before anything is rented"
# PLATFORM and KCTX are the MATRIXs variables and this wrapper has none; PLAN_ONLY exits before either
# is consulted, and they are passed only so the matrix does not refuse on an unset one.
plan_env=(PLAN_ONLY=1 PLATFORM=kind KCTX=none BENCHHARNESS_BIN="$OUT/benchharness"
          PREMIUM_WEIGHT="$PREMIUM_WEIGHT" PROBE_WEIGHT="$PROBE_WEIGHT" DURATION_MS="$DURATION_MS"
          OUT="$OUT/plan-check")
# The two loads are passed SEPARATELY because the matrix refuses them together.
#
# A ladder carries a rate and a contender weight per rung, so a single RATE or NOISY_WEIGHT beside it would
# be either ignored or an override -- and the matrix refuses rather than picking. Passing both sets here
# would make the plan check fail on that refusal for every ladder run.
if [ -n "$LADDER" ]; then
  plan_env+=(LADDER="$LADDER" LADDER_STUDY="${LADDER_STUDY:-}")
elif [ -n "$SWEEP" ]; then
  plan_env+=(REPS="$REPS" SWEEP="$SWEEP" PREMIUM_RATE="$PREMIUM_RATE")
  [ -z "${SEEDS:-}" ] || plan_env+=(SEEDS="$SEEDS")
elif [ -n "${PILOT_STAGE:-}" ]; then
  plan_env+=(REPS="$REPS" PREMIUM_RATE="$PREMIUM_RATE" PILOT_STAGE="$PILOT_STAGE" PILOT_NOISY_RATE="$PILOT_NOISY_RATE")
  [ -z "${PILOT_STATIC_RATE:-}" ] || plan_env+=(PILOT_STATIC_RATE="$PILOT_STATIC_RATE")
  [ -z "${SEEDS:-}" ] || plan_env+=(SEEDS="$SEEDS")
else
  plan_env+=(ARMS="$ARMS" REPS="$REPS" RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT")
  # And the reproduction claim, when the caller makes one.
  #
  # Unset means "this run claims to repeat nothing", which is the only honest default: the claim belongs in
  # the registration and the enforcement belongs here, before the card is rented.
  # With the gateway binary built above, so the plan can name the gateway by content as its target did.
  [ -z "${REPRODUCES:-}" ] || plan_env+=(REPRODUCES="$REPRODUCES" GATEWAY_BIN="$OUT/gateway")
  # The seeds the instance will use, so the plan check refuses a list the study cannot take while the
  # refusal is still free.
  [ -z "${SEEDS:-}" ] || plan_env+=(SEEDS="$SEEDS")
fi
if ! env "${plan_env[@]}" bash hack/m5c-matrix.sh; then
  fail "the purchase plan was refused before launch, and nothing was rented. The refusals above name the cell and the reason"
fi

# DRY_RUN stops here, with everything a launch depends on already built and checked.
#
# It exists because the only way to find out what this script sends to an instance used to be to rent one.
# Every check above -- the shebang, the parse, the surviving placeholder, the device mount, the encoded size
# -- runs first, so a dry run exercises them rather than skipping them. What it does not do is call
# run-instances, which is the line below it and the only one that costs anything.
if [ -n "${DRY_RUN:-}" ]; then
  say "DRY RUN: nothing was launched and nothing is billing. The user-data this run would have sent is in $OUT/user-data.sh"
  exit 0
fi

# ---------------------------------------------------------------- launch
say "launching $INSTANCE_TYPE spot (max \$$MAX_SPOT_PRICE/h)"
# The run tag carries RUN_NONCE so an instance can be traced back to the session that launched it.
#
# Without it the only tags are a fixed name and a fixed purpose, which every session shares -- so an instance
# left behind by an ambiguous launch is indistinguishable from one belonging to a session still running, and
# nothing can safely act on either. The nonce already exists and already separates this run's S3 records from
# another's; this puts the same identity on the instance.
#
# It is a LABEL, not an authorisation. Deciding what to terminate is done from the client token, which is
# unique to one launch attempt; RUN_NONCE is 32 bits with a seconds-based fallback and must never be given
# deletion authority on its own.
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=m5c-sharing-matrix},{Key=run,Value=$RUN_NONCE}${PILOT_STUDY_DEADLINE:+,{Key=study-deadline,Value=$PILOT_STUDY_DEADLINE\}}]"
# The trap is armed BEFORE the launch loop, not after it.
#
# It used to sit below the line that prints the instance id, which left a window in which run-instances had
# returned an id and nothing would terminate it. Under `set -euo pipefail` a failed write of the id file, a
# SIGPIPE, or a Ctrl-C in that window all exit with a GPU instance running and no terminator.
# spot_terminate returns 0 on an empty id, so arming it early costs nothing and closes the window.
# Termination is recorded as its own result, separate from whether the experiment succeeded.
#
# spot_terminate now returns non-zero when the instance is still billing, and nothing was reading that. A
# session could print "TERMINATE FAILED ... STILL running AND BILLING" and still exit 0, because a failing
# EXIT trap does not change a script's exit status -- measured, not assumed. So the outcome goes to a file
# the operator and the next run can both check.
# LAUNCH_UNCERTAIN holds the client token of a launch whose outcome this script does not know.
#
# It is set BEFORE the AWS call and cleared only once the answer is in, because the window that matters is
# the call itself: a signal arriving while run-instances is executing runs cleanup with IID still empty, and
# no amount of classification AFTER the call can reach that path. This is the one piece of state that makes
# an interrupted launch reconcilable, and it is not a journal -- it cannot hold an instance id the client
# never received. AWS is the journal; this is the key to query it with.
LAUNCH_UNCERTAIN=""
# The subnet that token was sent to, remembered with it: cleanup cannot see the loop's $SUBNET, and a
# reconcile without the subnet would ask a region-wide question the library now refuses.
LAUNCH_UNCERTAIN_SUBNET=""

# The reconciler this runner proved now lives in hack/lib/spot-run.sh as spot_reconcile_token, because
# three more paid runners need it and a second copy of termination-sensitive filtering is the risk, not
# the sharing. Every policy decision stays here: the token, the uncertain-token state, the classification
# of an error, and the traps. The library answers one question about one token and decides nothing.
#
# The tries count is passed explicitly rather than read from an environment default, which is the rule the
# library header states: a default every caller overrides is dead code that looks like a safety net.

cleanup_ran=0
cleanup() {
  # Run once, whichever of EXIT, INT and TERM gets here first.
  #
  # The same function is trapped on all three, and the `exit 1` below re-enters it through EXIT --
  # so an interrupted session called terminate-instances twice and polled for the state twice, up to
  # a minute each. The guard is set before the work rather than after it, because the second entry
  # arrives while the first is still inside that polling.
  [ "$cleanup_ran" = "1" ] && return 0
  cleanup_ran=1
  # The mktemp files this runner made are removed here, on every path that reaches cleanup.
  #
  # RUNSCRIPT, UD and MEASURE were never deleted by anything: one invocation left two or three files in
  # /tmp, which is tmpfs here, so they are RAM rather than disk. Driving the four runners through the
  # golden suite a few times put 6167 of them there. ${VAR:-} because cleanup can run before they are set.
  #
  # These files are created before `trap cleanup EXIT` is armed, so a run that refuses before the launch --
  # an unset REPS, a dirty tree, credentials too short -- used to leave them: four full suites, 59 scenarios,
  # left 2. An EXIT trap armed at the first mktemp now removes them on that path, and this one replaces it.
  rm -f "${RUNSCRIPT:-}" "${UD:-}" "${attempt_err:-}"
  # An unresolved launch is settled FIRST, because it is the instance nobody knows the id of.
  #
  # A signal during run-instances lands here with IID empty, and the terminate below would then report
  # `<none>` and exit 0 while an instance AWS accepted goes on billing. Resolving the token first is what
  # turns that into either a termination or a named, actionable refusal.
  if [ -n "$LAUNCH_UNCERTAIN" ]; then
    spot_reconcile_token "$REGION" "$LAUNCH_UNCERTAIN" "$LAUNCH_UNCERTAIN_SUBNET" 6 || {
      printf 'TERMINATION UNCONFIRMED for the launch under token %s -- check the console before the next paid run\n' \
        "$LAUNCH_UNCERTAIN" >"${OUT:-.}/termination.txt" 2>/dev/null || true
      exit 1
    }
    LAUNCH_UNCERTAIN=""
  fi
  if [ -n "${TERMINATED_FIRST:-}" ]; then
    : # the pilot terminated it before its downloads, and recorded that
  elif spot_terminate "$REGION" "$IID"; then
    printf 'terminated %s\n' "${IID:-<none>}" >"${OUT:-.}/termination.txt" 2>/dev/null || true
  else
    printf 'TERMINATION UNCONFIRMED for %s -- check the console before the next paid run\n' \
      "${IID:-<none>}" >"${OUT:-.}/termination.txt" 2>/dev/null || true
    printf 'TERMINATION UNCONFIRMED for %s\n' "${IID:-<none>}" >&2
    # A record is not a gate, and until now this was only a record.
    #
    # The comment above established that a failing EXIT trap does not change a script's exit status -- and
    # then settled for writing the outcome to a file. Nothing read the file, so a session that could not
    # confirm its instance was gone still exited 0, and a wrapper, a log reader or a CI step saw success.
    # `exit` inside the trap is the one thing that does set the status, so it is called here: a run whose
    # instance may still be billing is a failed run, whatever the experiment produced.
    exit 1
  fi
}
IID=""
# A signal ends the run; it does not just clean up and fall through.
#
# `trap cleanup EXIT INT TERM` ran cleanup on a signal and then RESUMED the script, because a trap handler
# that returns hands control back to where the signal arrived -- so an interrupted session could go on to
# launch an instance the guard had already marked as cleaned. Signals now exit with the conventional status,
# which re-enters cleanup through EXIT exactly once thanks to the guard inside it.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  say "trying $z ($SUBNET)"
  # One token per (run, zone), so a retry in the same zone is idempotent while a deliberate move to another
  # zone is a genuinely new request. EC2's idempotency is zonal because the subnet pins the zone, so a single
  # token across zones would be neither one thing nor the other.
  #
  # Built from LAUNCH_IDENTITY, not RUN_NONCE: this string is what decides which instance gets terminated.
  # EC2 caps a client token at 64 ASCII characters, and this is 52 -- "m5c-" plus 32 hex plus "-" plus a zone
  # name of 15 -- so a longer region name still fits.
  LAUNCH_TOKEN="m5c-$LAUNCH_IDENTITY-$z"
  # Only a refusal that names a ZONE's shortage may move to another zone.
  #
  # The classification is a whitelist, not a denylist, and the direction matters: an unrecognised error read
  # as "definitive" would send the loop on to buy a second instance, which is the defect being closed. An
  # unrecognised error read as "ambiguous" costs a retry and, at worst, a refused session. The expensive
  # mistake is the one that is not made.
  #
  # Capacity is the only zonal answer. An authorization denial, a validation error or a quota refusal is
  # definitive AND not helped by another zone, so LAUNCH_DEFINITIVE stops the whole loop -- the refusal block
  # below already reads launch-errors.txt and says which of the two it was.
  #
  # The flag exists because `break` leaves only the inner retry loop. Without it the outer `for z` ran on with
  # IID empty and asked the next zone a question this one had already answered, while the comment here claimed
  # it stopped: a policy denial was re-sent once per zone. Cheap in money, but it made the comment false.
  LAUNCH_DEFINITIVE=""
  attempt=0
  # The per-attempt buffer lives outside $OUT on purpose.
  #
  # Its whole job is to be classified and then appended to launch-errors.txt, which is the record an operator
  # reads and the refusal block below greps. Leaving it in the run directory put a file there holding only the
  # LAST attempt's stderr -- a second, thinner thing that looks like evidence beside the real log -- and it
  # moved eleven goldens for no behavioural reason at all.
  attempt_err=$(mktemp)
  while :; do
    attempt=$((attempt + 1))
    : > "$attempt_err"
    # Set BEFORE the call. Everything after this line, including a signal, can be reconciled.
    LAUNCH_UNCERTAIN="$LAUNCH_TOKEN"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
    IID=$(spot_launch "$REGION" "$AMI" "$INSTANCE_TYPE" "$SUBNET" "$STACK" \
          "$MAX_SPOT_PRICE" 200 "$UD" "$TAGS" "$LAUNCH_TOKEN" 2>"$attempt_err") || IID=""
    # The shared error log keeps accumulating, because the refusal block after this loop reads it.
    cat "$attempt_err" >> "$OUT/launch-errors.txt"

    if [ -n "$IID" ] && [ "$IID" != "None" ]; then LAUNCH_UNCERTAIN=""; break; fi
    IID=""

    if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$attempt_err" 2>/dev/null; then
      LAUNCH_UNCERTAIN=""            # AWS said it created nothing here; another zone is the right move
      break
    fi
    # IdempotentParameterMismatch is EVIDENCE AN INSTANCE EXISTS, and it used to sit in the definitive list
    # below, where it cleared LAUNCH_UNCERTAIN and moved on.
    #
    # AWS returns it only when this token was already used by a request that SUCCEEDED, with parameters that
    # differ from the ones just sent. So it is the opposite of "nothing was created": something was, under a
    # token this run now knows. Reading it as a clean refusal walked away from a billing instance -- the same
    # defect this loop was rewritten to close, through a door left open in the fix itself.
    if grep -q 'IdempotentParameterMismatch' "$attempt_err" 2>/dev/null; then
      # Cleared before the outcome is judged, for the reason spelled out at the end of this loop: `fail`
      # re-enters cleanup, which would otherwise reconcile the same token a second time.
      LAUNCH_UNCERTAIN=""
      spot_reconcile_token "$REGION" "$LAUNCH_TOKEN" "$SUBNET" 6 \
        || fail "a launch in $z was refused as a duplicate of an earlier request under the same token, so an instance exists, and AWS could not be asked which one. Nothing further is launched. See $OUT/launch-errors.txt"
      fail "a launch in $z was refused as a duplicate of an earlier request under the same token; whatever that earlier request created has been terminated. See $OUT/launch-errors.txt"
    fi
    if grep -qE 'UnauthorizedOperation|ValidationError|InvalidParameter|RequestLimitExceeded|InstanceLimitExceeded' \
         "$attempt_err" 2>/dev/null; then
      LAUNCH_UNCERTAIN=""            # AWS refused before creating anything
      LAUNCH_DEFINITIVE=1            # and no other zone would answer differently
      break
    fi

    # Ambiguous: the answer was lost, not given. Retry the SAME zone with the SAME token, which EC2's zonal
    # idempotency makes safe -- it returns the instance already created rather than making a second one.
    if [ "$attempt" -lt "${LAUNCH_AMBIGUOUS_TRIES:-3}" ]; then
      say "the launch in $z gave no answer this script can classify; retrying the same zone with the same token"
      continue
    fi
    # Still unresolved after retrying. Do NOT move zones: an instance may exist under this token, and a
    # second zone would make two. Resolve it and stop.
    # The token is cleared BEFORE the outcome is judged, and that ordering is not cosmetic.
    #
    # `fail` exits, which re-enters cleanup through the EXIT trap, and cleanup reconciles LAUNCH_UNCERTAIN if
    # it is still set. Clearing it after the branch meant the failing path reconciled twice -- a second round
    # of DescribeInstances and terminate calls, and the same refusal printed twice -- because the first
    # attempt had not yet recorded that it had happened.
    LAUNCH_UNCERTAIN=""
    spot_reconcile_token "$REGION" "$LAUNCH_TOKEN" "$SUBNET" 6 \
      || fail "a launch in $z was neither confirmed nor refused, and AWS could not be asked what it created. Nothing further is launched, because a second zone would risk a second instance. See $OUT/launch-errors.txt"
    fail "a launch in $z gave no classifiable answer after $attempt attempts; anything it created has been terminated. Re-run when the API is answering. See $OUT/launch-errors.txt"
  done
  rm -f "$attempt_err"
  [ -n "$IID" ] && break
  [ -n "$LAUNCH_DEFINITIVE" ] && break
done
# The buffer is also removed on the paths that leave this loop by exiting -- `fail` inside it, or a signal --
# because /tmp here is tmpfs, so a leaked file is memory rather than disk. cleanup runs on all of them.
rm -f "${attempt_err:-}" 2>/dev/null || true
if [ -z "$IID" ]; then
  # The refusal names the cause the errors actually give. An earlier version attributed every empty result to
  # Spot capacity while all three zones had in fact returned UnauthorizedOperation from a service control
  # policy -- describing a quantity by a cause its own evidence does not support.
  if grep -q "UnauthorizedOperation" "$OUT/launch-errors.txt" 2>/dev/null; then
    scp=$(grep -o 'service_control_policy/[a-z0-9-]*' "$OUT/launch-errors.txt" | head -1)
    fail "every zone refused $INSTANCE_TYPE with UnauthorizedOperation, not for want of capacity. An explicit deny in ${scp:-a service control policy} blocks ec2:RunInstances for this type, and an SCP is not something an account administrator can override. This account's policy allows t3.*, g4dn.* and g5.* only. See $OUT/launch-errors.txt"
  fi
  if grep -qi "InsufficientInstanceCapacity\|capacity-not-available" "$OUT/launch-errors.txt" 2>/dev/null; then
    fail "no zone had Spot capacity for $INSTANCE_TYPE: try again, or raise MAX_SPOT_PRICE. See $OUT/launch-errors.txt"
  fi
  fail "no zone would launch $INSTANCE_TYPE, and the errors name neither an authorization denial nor a capacity shortfall. See $OUT/launch-errors.txt"
fi
echo "$IID" > "$OUT/instance-id"
say "instance $IID"

say "waiting for results (driver, toolkit, cluster and preflight come first; about 25 minutes before the first cell)"
done_seen=0
ended_early=""
marker_rc=0
if [ -n "$PILOT_ACQ_DEADLINE" ]; then
  ended_early=$(spot_wait_for_marker_until "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" \
                "$PILOT_ACQ_DEADLINE" 30 "$((HARD_STOP_SECONDS / 30))") || marker_rc=$?
else
  ended_early=$(spot_wait_for_marker "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" \
                "$((HARD_STOP_SECONDS / 30))" 30) || marker_rc=$?
fi
case "$marker_rc" in
  0)
    # The marker must carry THIS launch's nonce. The prefix already does, so a stale marker can only appear
    # if a nonce is reused or a prefix is hand-edited -- and both are exactly the case this verification is
    # for. Reading it is one S3 GET and it is the difference between "the records are up" and "some records
    # are up".
    # The pilot's acquisition deadline still holds here: the read runs under the time left, at least 1 s.
    _left=1
    [ -z "$PILOT_ACQ_DEADLINE" ] || _left=$(( PILOT_ACQ_DEADLINE - $(date +%s) ))
    [ "$_left" -ge 1 ] || _left=1
    if [ -n "$PILOT_ACQ_DEADLINE" ]; then
      marker_says=$(timeout "$_left" aws s3 cp "s3://$BUCKET/$RUN_ID/DONE" - 2>/dev/null | tr -d '[:space:]')
    else
      marker_says=$(aws s3 cp "s3://$BUCKET/$RUN_ID/DONE" - 2>/dev/null | tr -d '[:space:]')
    fi
    if [ "$marker_says" != "$RUN_NONCE" ]; then
      fail "the completion marker at s3://$BUCKET/$RUN_ID/DONE says ${marker_says@Q} and this launch's nonce is ${RUN_NONCE@Q}. That is another session's record, and the evidence under this prefix is not this run's. Nothing has been downloaded"
    fi
    say "records are up (marker carries this launch's nonce)"
    done_seen=1 ;;
  2) say "instance ended before writing DONE" ;;
esac

# The pilot terminates its instance FIRST, before any evidence is downloaded, whether the marker came or not
# (design page, "on reaching the acquisition deadline, the runner terminates the instance first"). The evidence
# is in the bucket, so the download no longer needs the card, and a slow download no longer bills one.
# The call runs under its own fixed 5 minutes, the reserve the acquisition deadline left before the hard stop.
TERMINATED_FIRST=""
if [ -n "$PILOT_ACQ_DEADLINE" ]; then
  if timeout 300 bash -c '. "$1"; spot_terminate "$2" "$3"' _ "$(dirname "${BASH_SOURCE[0]}")/lib/spot-run.sh" "$REGION" "$IID"; then
    TERMINATED_FIRST=1
    printf 'terminated %s before any download\n' "$IID" >"$OUT/termination.txt"
  else
    fail "the instance $IID could not be confirmed terminated within 5 minutes; nothing has been downloaded, and the exit trap tries once more"
  fi
  # The session's own timing, for the pilot's duration formulas: the instance's EC2 LaunchTime, and the marker's
  # upload time. Asked after termination, which leaves both answerable.
  timeout 30 aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].LaunchTime' --output text > "$OUT/launch-time.txt" 2>/dev/null || true
  if [ "$done_seen" = 1 ]; then
    timeout 30 aws s3api head-object --bucket "$BUCKET" --key "$RUN_ID/DONE" \
      --query LastModified --output text > "$OUT/marker-uploaded.txt" 2>/dev/null || true
  fi
fi

for k in evidence.tgz log.txt commit.txt nodes.txt preflight-nvidia-smi.csv preflight-node-cards.txt \
         ${PILOT_ACQ_DEADLINE:+matrix-returned.txt}; do
  aws s3 cp "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" >/dev/null 2>&1 || true
done
# Whether the preflight files arrived is CHECKED, not merely attempted.
#
# `|| true` above is right -- a missing key is not an error worth aborting the download loop for -- but it
# made the two preflight files optional in practice, and the normal path ended `exit 0` without them. They
# name the card, the driver and the cards the node actually advertised; a session that reports numbers
# without them is reporting on an apparatus nobody identified, which is the one thing this study cannot do.
missing_preflight=""
for k in preflight-nvidia-smi.csv preflight-node-cards.txt; do
  [ -s "$OUT/$k" ] || missing_preflight="$missing_preflight $k"
done
[ -z "$missing_preflight" ] \
  || fail "the instance finished and these preflight files never arrived:$missing_preflight. They identify the card and driver the numbers were taken on, and a measurement whose apparatus is unidentified is not one this study can report"
# Unpacked, and the unpacking is CHECKED. An `&&` chain that quietly does nothing is how a session ends by
# naming an evidence directory it never created.
if [ -s "$OUT/evidence.tgz" ]; then
  tar -xzf "$OUT/evidence.tgz" -C "$OUT" || fail "the evidence archive came back and could not be unpacked; $OUT/evidence.tgz is whatever arrived"
  say "evidence unpacked to $OUT/m5c-run"
fi
# The pilot's session stamps, beside the cells they time: bring-up is LaunchTime to the first cell's start, and the
# session tail is the matrix's return to the marker's upload. An empty field is a stamp that did not arrive.
if [ -n "$PILOT_ACQ_DEADLINE" ]; then
  mkdir -p "$OUT/m5c-run"
  printf 'launch_time_utc\tmatrix_returned_epoch\tmarker_uploaded_utc\n%s\t%s\t%s\n' \
    "$(tr -d '[:space:]' < "$OUT/launch-time.txt" 2>/dev/null)" "$(tr -d '[:space:]' < "$OUT/matrix-returned.txt" 2>/dev/null)" \
    "$(tr -d '[:space:]' < "$OUT/marker-uploaded.txt" 2>/dev/null)" > "$OUT/m5c-run/session-timing.tsv"
fi

# The cells are pulled whenever the ARCHIVE did not arrive, marker or no marker.
#
# This was inside the `done_seen -eq 0` branch, so a run that wrote DONE and whose archive upload then
# failed recovered nothing at all -- the marker says the instance finished, not that its evidence landed.
# The two facts are separate and the recovery should follow the second.
# The cells are reconciled ALWAYS, not only when the archive is missing entirely.
#
# The gate here was "a README and at least one raw file exist", which is not the question. A partially
# downloaded directory -- a reused OUT, an interrupted transfer, an archive that unpacked some of what it
# held -- satisfies it while cells sit in the bucket already paid for, and nothing says so. Reconciling
# costs one list-objects call and copies only what is not already on disk, so the cheap version of this
# check is the complete one.
if true; then
  # The per-cell uploads are pulled down FIRST, because they are the only evidence an interruption leaves.
  #
  # Each cell is copied to s3://.../cells/ the moment it completes, and nothing here looked there. The
  # archive above is written by the instance after the whole matrix returns, so a session that STOPS has no
  # archive at all -- and this block would then count zero raw files and refuse, while five cells sat in
  # the bucket already paid for. Existing files are not overwritten: the archive is the complete record
  # when it exists, and these are the fallback.
  mkdir -p "$OUT/m5c-run"
  cells_pulled=0
  while read -r key; do
    [ -n "$key" ] || continue
    base="$(basename "$key")"
    [ -e "$OUT/m5c-run/$base" ] && continue
    aws s3 cp "s3://$BUCKET/$key" "$OUT/m5c-run/$base" >/dev/null 2>&1 && cells_pulled=$(( cells_pulled + 1 ))
  done < <(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$RUN_ID/cells/" \
             --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n')
  [ "$cells_pulled" -gt 0 ] && say "recovered $cells_pulled cell(s) that were uploaded as they completed"
  # The pilot's live snapshots and Spot notice, into their own directory, so a partial cell's rows are never read as
  # a completed cell's: they are what an interrupted replay leaves (review of c4eef3d).
  if [ -n "$PILOT_ACQ_DEADLINE" ]; then
    mkdir -p "$OUT/live"
    live_pulled=0
    while read -r key; do
      [ -n "$key" ] || continue
      aws s3 cp "s3://$BUCKET/$key" "$OUT/live/$(basename "$key")" >/dev/null 2>&1 && live_pulled=$(( live_pulled + 1 ))
    done < <(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$RUN_ID/live/" \
               --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n')
    [ "$live_pulled" -gt 0 ] && say "recovered $live_pulled live snapshot(s) into $OUT/live"
  fi
fi

if [ "$done_seen" -eq 0 ]; then
  # Partial evidence is the point of uploading before the marker, so it is reported rather than discarded.
  shopt -s nullglob
  recovered=("$OUT/m5c-run"/raw-*.jsonl)
  # A session-2 warm-up's rows match the glob and are not a cell's, so they are not counted as one.
  partial=0
  for _f in "${recovered[@]}"; do case "${_f##*/}" in raw-warmup-*) ;; *) partial=$(( partial + 1 )) ;; esac; done
  shopt -u nullglob
  say "raw files recovered before the end: $partial"
  if [ -n "$ended_early" ]; then
    fail "the instance was $ended_early before it wrote its completion marker; $partial raw file(s) were recovered and $OUT/log.txt is whatever it managed to upload"
  fi
  fail "no completion marker within the hard stop; $partial raw file(s) were recovered and $IID has been terminated"
fi

# A completion marker is the instance saying it finished. It is not evidence arriving.
#
# The instance's `upload` helper ends in `|| true`, deliberately, so that one failed upload cannot kill a run
# that still has records to send. The cost of that choice is here: a marker can be written while the archive
# that matters never made it, and without this check the session would print SESSION DONE and name a
# directory that does not exist. hack/queuelab-gpu-session.sh refuses on exactly this and this file did not.
# The evidence has to be THIS run's.
#
# RUN_ID is the output directory's basename, and the results bucket keeps objects for thirty days. Reuse a
# basename and the previous session's DONE marker and archive are both still there and both still eligible:
# the wait returns immediately, the download succeeds, the checks pass, and the operator reads a prior
# experiment's numbers while this run's instance is terminated underneath them. The commit the instance
# recorded is what settles it.
if [ -s "$OUT/commit.txt" ]; then
  got_commit=$(tr -d '[:space:]' < "$OUT/commit.txt")
  [ "$got_commit" = "$COMMIT" ] \
    || fail "the evidence in s3://$BUCKET/$RUN_ID was built from commit $got_commit and this session shipped $COMMIT. That is a previous run's evidence under a reused run id, and reporting it would attribute another experiment's numbers to this one. Use a fresh OUT."
fi
[ -s "$OUT/evidence.tgz" ] \
  || fail "the instance wrote its completion marker and no evidence archive arrived. $OUT/log.txt is whatever it managed to upload, and the run produced nothing this side can read"

# And the archive must contain an arm's worth of evidence for every arm that was asked for.
#
# A tar that unpacks is not a run that measured. The readings need R1 and `shared` at minimum -- R1 is the
# denominator of both bars -- and an arm whose raw file is missing is an arm the report will silently omit
# from its table rather than one it complains about.
# An arm REFUSED as a registered outcome is not a missing arm, and demanding evidence from it would turn a
# working refusal into a failed session. hack/m5c-matrix.sh writes refused-<arm>.txt beside the raw files and
# the report reads it as reading 4c.
missing=""
refused=""
# What the run was SUPPOSED to produce, derived from the plan rather than from the directory.
#
# For the matrix that is the arm list. For the ladder it is both topologies at every rung -- and NOT the
# baseline cell, because which rung that belongs to depends on where the stopping rule fired, which this
# script cannot know without reading the evidence it is checking. The baseline is checked separately below,
# by existence rather than by name.
expected_arms=""
if [ -n "$LADDER" ]; then
  _rung=0
  for _entry in $LADDER; do
    _rung=$(( _rung + 1 ))
    # A skipped rung holds its POSITION and buys nothing, so it must not be expected either.
    #
    # This loop was written before `skip` existed and kept counting positions as purchases. The repetition of
    # rungs 2 and 3 therefore finished every cell, downloaded all of them, and then failed its own final
    # check demanding rung01-shared and rung01-timeSlicing -- arms it had been told not to buy. Nothing was
    # lost and the instance was terminated correctly, but the session's last word on a successful run was
    # FAIL, which is the one thing an end-of-session check must never say wrongly.
    [ "$_entry" != skip ] || continue
    expected_arms="$expected_arms $(printf 'rung%02d-shared rung%02d-timeSlicing' "$_rung" "$_rung")"
  done
else
  expected_arms="$ARMS"
fi
# A ladder that stopped early legitimately has no cells ABOVE the rung it stopped on. Below and including
# that rung, every expected cell must be there.
#
# The highest rung with evidence is what says where it stopped, and it is read from the evidence rather than
# from the stopping rule, because this check exists to catch a run whose plan and whose output disagree.
# Clearing `missing` wholesale would have been the easy version of this and the wrong one: it would hide a
# missing cell at rung 1 as readily as an unbought rung 4.
ladder_reached=0
if [ -n "$LADDER" ]; then
  for f in "$OUT/m5c-run"/raw-rung*.jsonl; do
    [ -e "$f" ] || continue
    _b=$(basename "$f"); _b=${_b#raw-rung}; _n=${_b%%-*}
    _n=$(printf '%s' "$_n" | sed 's/^0*//'); [ -n "$_n" ] || _n=0
    [ "$_n" -le "$ladder_reached" ] || ladder_reached=$_n
  done
  [ "$ladder_reached" -gt 0 ] \
    || fail "the ladder finished and wrote no rung evidence at all"
  # Rungs above the one reached are waived ONLY against a recorded STOP.
  #
  # This check derived the stopping point from whatever survived, so a run that wrote rung-1 files, recorded
  # a verdict explicitly saying CONTINUE, and then died before rung 2 came back as SESSION DONE at exit 0 --
  # an interrupted ladder reported as a complete one. The verdict file is in the evidence; reading it is the
  # difference between "the stopping rule ended this" and "something did".
  ladder_planned_top=0
  _rung=0
  for _entry in $LADDER; do
    _rung=$(( _rung + 1 ))
    [ "$_entry" != skip ] || continue
    ladder_planned_top=$_rung
  done
  if [ "$ladder_reached" -lt "$ladder_planned_top" ]; then
    verdict="$OUT/m5c-run/ladder-verdict-rung$ladder_reached.txt"
    [ -s "$verdict" ] \
      || fail "the ladder planned $ladder_planned_top rungs, reached $ladder_reached, and left no verdict for that rung. Rungs are waived only against a recorded STOP, and an interrupted ladder is not a finished one"
    grep -qx "LADDER: STOP" "$verdict" \
      || fail "the ladder planned $ladder_planned_top rungs and reached $ladder_reached, but the verdict at rung $ladder_reached says $(tr -d '[:space:]' < "$verdict"). Only a STOP waives the rungs above it; this run ended for some other reason and the evidence is partial"
    say "rungs above $ladder_reached were waived against a recorded STOP at rung $ladder_reached"
  fi
fi
for arm in $expected_arms; do
  if [ -n "$LADDER" ]; then
    _r=${arm#rung}; _r=${_r%%-*}; _r=$(printf '%s' "$_r" | sed 's/^0*//'); [ -n "$_r" ] || _r=0
    # Above the rung the ladder reached is not missing evidence; it is evidence the stopping rule declined
    # to buy, which is the rule working.
    [ "$_r" -le "$ladder_reached" ] || continue
  fi
  # An INVALID arm is not an outcome, so it ends the session rather than joining the refusals.
  #
  # The pre-registration separates them: a refusal is evidence about this AMI and driver, an invalid run is
  # evidence about nothing. Recording the second as the first would put "the apparatus was broken" into the
  # report's table as though the card had been asked and had answered no.
  if [ -s "$OUT/m5c-run/invalid-$arm.txt" ]; then
    fail "arm $arm is INVALID, not refused: $(tr '\n' ' ' <"$OUT/m5c-run/invalid-$arm.txt")"
  fi
  if [ -s "$OUT/m5c-run/refused-$arm.txt" ]; then
    refused="$refused $arm"
    continue
  fi
  # The glob only ever asked whether a FILENAME exists, and an empty file has a filename.
  #
  # B5 asks that the arm's replay ran. A zero-row jsonl, and one whose every row is a 5xx, both satisfy a
  # glob and neither is a measurement. Rows carry httpStatus (internal/bench/replay.go), so the rows are
  # counted and the answered ones counted separately.
  _rows=0 _answered=0 _completed=0
  for _f in "$OUT/m5c-run/raw-$arm-"*.jsonl; do
    [ -f "$_f" ] || continue
    _rows=$(( _rows + $(grep -c . "$_f" 2>/dev/null || true) ))
    _answered=$(( _answered + $(grep -c '"httpStatus":[[:space:]]*[23][0-9][0-9]' "$_f" 2>/dev/null || true) ))
    # A 2xx is not a completion, and counting it as one is how a timed-out arm passed this check.
    #
    # TimeoutMs bounds the WHOLE request, so a response that began in time and then expired carries
    # httpStatus 200, a stamped first token and errorKind "timeout". Every row of an arm could look like
    # that and the old test -- "at least one 2xx" -- would have called the arm answered. A completed row is
    # one with no errorKind at all.
    _completed=$(( _completed + $(grep -cv '"errorKind"' "$_f" 2>/dev/null || true) ))
  done
  # EVERY repetition must have left a file, which counting rows across the glob cannot see.
  #
  # The glob sums whatever is there, so an arm that wrote repetition 1 and died before repetition 2 reports
  # a healthy row count. REPS is baked into this instance, so the expectation comes from the plan rather
  # than from the evidence being checked -- a check whose expectation is derived from its subject cannot
  # fail. The ladder is exempt: its cells are rungs, not repetitions, and it has its own completeness check
  # above.
  if [ -z "$LADDER" ]; then
    # The instrument-validation study buys each async arm once, as hack/m5c-matrix.sh plans it.
    _arm_reps="${REPS:-1}"
    if iv_is_study "${STUDY:-}"; then case "$arm" in *-async) _arm_reps=1 ;; esac; fi
    # The diagnostic's stage D runs R1 once, as its isolated anchor.
    if [ "${PILOT_STAGE:-}" = D ] && [ "$arm" = R1 ]; then _arm_reps=1; fi
    _rep=1
    while [ "$_rep" -le "$_arm_reps" ]; do
      # A block the study does not buy this arm in owes no file (the step-boundary session's serial and staggered
      # cells are in blocks 1, 3 and 5); the same predicate laid the matrix out.
      if iv_is_study "${STUDY:-}" && ! iv_arm_in_block "$STUDY" "$arm" "$_rep"; then _rep=$(( _rep + 1 )); continue; fi
      [ -s "$OUT/m5c-run/raw-$arm-$_rep.jsonl" ] \
        || fail "arm $arm is missing repetition $_rep of $_arm_reps. The run reported no refusal for it, so this is a repetition that was planned, was not recorded, and would have been pooled over as though it had been."
      _rep=$(( _rep + 1 ))
    done
  fi
  if [ "$_rows" -eq 0 ]; then
    missing="$missing $arm"
  elif [ "$_answered" -eq 0 ]; then
    fail "arm $arm came back with $_rows row(s) and not one carries a 2xx or 3xx httpStatus. The file exists, the replay never answered, and B5 asks for a replay that answered"
  elif [ "$_completed" -eq 0 ]; then
    fail "arm $arm came back with $_rows row(s), of which $_answered carry a 2xx or 3xx httpStatus and NONE completed -- every one records an errorKind. A request that was answered and then expired is not a measurement of this arm's tail."
  fi
done
# A ladder with no baseline cell at all is a fault whichever rung it ended on.
if [ -n "$LADDER" ]; then
  compgen -G "$OUT/m5c-run/raw-rung"'*-R1-*.jsonl' >/dev/null \
    || fail "the ladder finished and bought no isolated baseline cell. Without it, 'the split ran out of capacity' and 'one engine of this model on this card ran out of capacity' are the same observation"
  say "the ladder reached rung $ladder_reached and bought its baseline: $(cd "$OUT/m5c-run" && ls raw-rung*-R1-*.jsonl | tr '\n' ' ')"
fi
[ -z "$missing" ] \
  || fail "the run finished and these arms have no raw evidence and no recorded refusal either:$missing. The report would leave them out of its table rather than say they are absent, and any reading that divides by one of them would decline without naming it"
[ -z "$refused" ] && say "every arm in [$expected_arms] returned raw evidence" \
  || say "arms refused as registered outcomes:$refused -- reading 4c will report them, and the arms beside them stand"

say "SESSION DONE. Evidence in $OUT/m5c-run"
say "The readings are NOT evaluated here. Run them over the evidence:"
# raw-warmup-* are the instrument-validation warm-ups, which no arm's statistic may include.
say "  args=; for f in $OUT/m5c-run/raw-*.jsonl; do case \$f in */raw-warmup-*) continue ;; esac; args=\"\$args --raw \$f\"; done"
say "  go run ./cmd/benchharness report \$args"
say "That prints the pre-registered readings in their registered order and the first that fires."

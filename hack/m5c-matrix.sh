#!/usr/bin/env bash
#
# The sharing matrix: does giving each tenant its own engine beat giving them one to share?
#
# That is the question, and it is the same mechanism M5-b measures seen from the other side. In the shared
# arm two tenants multiplex one vLLM, so they share a KV cache and the long-context tenant's occupancy is
# what costs the other one latency -- the pressure the admission guard exists to relieve. In the
# time-sliced arm each tenant gets its own engine with its own cache on half the card, so the KV coupling is
# gone and what remains is contention for the SMs. Neither is obviously better, which is why it is worth
# measuring rather than asserting.
#
#   shared        one engine, whole card, both tenants routed to it        (M5-b's topology)
#   timeSlicing   two engines, half card each, one tenant routed to each
#   mps           the same two engines, sharing through MPS instead
#
# MPS is not a third topology, it is a second mechanism for the same one, and the difference is worth
# stating because it is the reason both arms exist. Time-slicing interleaves kernels and does NOT partition
# memory -- the two engines draw on one pool and only convention keeps their utilizations summing below 1.
# MPS runs their kernels concurrently in one context AND caps each client's memory: the pinned control
# daemon issues set_default_device_pinned_mem_limit, read out of the binary rather than the documentation.
# So the arms differ in whether the tenants contend for SM time serially or concurrently, and in whether
# their memory ceiling is enforced or agreed.
#
# The routing is built from mechanisms this control plane already has: the gateway resolves a backend from
# the requesting tenant's GPUQuotaPolicy targetNamespace, so putting each engine in its own namespace and
# pointing one policy at each is all it takes. No new code, and the arm is a deployment difference rather
# than a code path.
#
# What this does NOT report is per-engine GPU utilisation. Under time-slicing a busy SM belongs to no single
# Pod and DCGM cannot attribute it -- config/nvidia-device-plugin/daemonset.yaml says so, and it is why the
# sharing node deliberately has no observer. The matrix reports what the CLIENTS measured, which is
# unambiguous and is also what a tenant actually experiences.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export GOTOOLCHAIN=go1.26.6
# The instrument-validation study's per-arm durations, engine arguments and refusals.
# Sourced rather than restated because hack/m5c-gpu-session.sh needs the same durations for its credential
# margin, and two copies of a duration table are two answers to one question.
# shellcheck source=hack/lib/instrument-validation.sh
. hack/lib/instrument-validation.sh || { echo "MATRIX FAILED: could not source hack/lib/instrument-validation.sh" >&2; exit 1; }
# shellcheck source=hack/lib/prospective-pilot.sh
. hack/lib/prospective-pilot.sh || { echo "MATRIX FAILED: could not source hack/lib/prospective-pilot.sh" >&2; exit 1; }

# Where the card comes from, which is the only thing about this matrix that is not the experiment.
#
# eks is the original: a managed cluster with a GPU node group this script scales up and down, and an
# EventBridge deadline as the backstop for a shell that dies. kind is one rented Spot instance that is
# itself the node, with a kind cluster on it -- hack/queuelab-gpu-session.sh already builds exactly that on
# real A10Gs, and hack/m5c-gpu-session.sh is the wrapper that does it for this matrix.
#
# The reason both exist is that the cluster half of the AWS path has never been applied, so the eks branch
# below cannot be run today and cannot be tested. Its lines are therefore left exactly as they were and
# merely moved inside a function: a refactor of a paid-run path nobody can exercise is how a working script
# becomes a broken one silently. Everything the two platforms share -- the arms, the routing, the cells --
# is one copy, because a second written from memory of the first is the failure this repository has already
# paid for twice.
PLATFORM="${PLATFORM:-eks}"
KCTX="${KCTX:-$(kubectl config current-context 2>/dev/null)}"
NS_A="${NS_A:-m5c-a}"
NS_B="${NS_B:-m5c-b}"
MODEL="Qwen/Qwen2.5-3B-Instruct"
# The revision of that model, beside the name, because the two are one fact.
#
# RunManifest.TokenizerRev was declared for this and filled by nothing, and replay --require-provenance now
# refuses a manifest without it. The value is the upstream repository revision, measured 2026-09-30 and
# recorded with the tokenizer file hashes in internal/bench/testdata/tokenizer_calibration.json: a reader can
# fetch this revision and recompute those hashes.
#
# Overridable, because a run that serves a different revision must be able to say so -- and NOT defaulted to
# anything derived, because a wrong revision recorded confidently is worse than none.
# Whether the CALLER set each compiled value, snapshotted BEFORE the defaults below answer for them.
#
# The compiled-CR block further down asks "is this variable unset?" -- and by the time it asks, every
# one of them has been defaulted, so a block that omitted PREMIUM_OUTPUT_TOKENS passed the check with
# the generator's old literal 64 silently in its place. An external review built that case from the two
# statements alone. The emptiness test could never have caught it: the question is not whether the
# variable has a value, it is whether the COMPILED BLOCK supplied it.
#
# ARMS_FROM_CALLER below is the same device for the same reason, and its comment says so. This is that
# device applied to the six values the plan compiles, and it has to stay above the defaults.
PREMIUM_PROMPT_CHARS_FROM_CALLER="${PREMIUM_PROMPT_CHARS+set}"
NOISY_PROMPT_CHARS_FROM_CALLER="${NOISY_PROMPT_CHARS+set}"
REQUEST_TIMEOUT_MS_FROM_CALLER="${REQUEST_TIMEOUT_MS+set}"
MODEL_REVISION_FROM_CALLER="${MODEL_REVISION+set}"
PREMIUM_OUTPUT_TOKENS_FROM_CALLER="${PREMIUM_OUTPUT_TOKENS+set}"
NOISY_OUTPUT_TOKENS_FROM_CALLER="${NOISY_OUTPUT_TOKENS+set}"
MODEL_REVISION="${MODEL_REVISION:-aa8e72537993ba99e69dfaafa59ed015b17504d1}"
# The RESOLVED prompt lengths, in characters, and the per-request timeout.
#
# These were defaulted by gen-trace and never passed, so every paid run used 200 and 40,000 characters and a
# 30-second timeout -- whatever the registration said. An external review found it after the resolution
# table was measured: the table says 256 tokens is 1,174 characters and 8,192 is 42,579, and none of that
# reached the runner. A compiler that resolves a length and a runner that ignores it is the wrong-experiment
# failure the compiler exists to prevent, one layer down.
#
# Overridable, because a study that registers other lengths must be able to pass them, and NOT derived from
# anything here: the only source is hack/input-length-resolution.json, measured against the served tokenizer.
#
# Which of the four the CALLER set is captured before the defaults fill them, because the instrument-validation
# study refuses a caller's value and a defaulted one is indistinguishable from it afterwards.
SHAPE_FROM_CALLER=""
for _v in PREMIUM_PROMPT_CHARS NOISY_PROMPT_CHARS PREMIUM_OUTPUT_TOKENS NOISY_OUTPUT_TOKENS; do
  [ -z "${!_v:-}" ] || SHAPE_FROM_CALLER="$SHAPE_FROM_CALLER $_v=${!_v}"
done
PREMIUM_PROMPT_CHARS="${PREMIUM_PROMPT_CHARS:-1174}"
NOISY_PROMPT_CHARS="${NOISY_PROMPT_CHARS:-42579}"
REQUEST_TIMEOUT_MS="${REQUEST_TIMEOUT_MS:-60000}"
# The output caps, for the same reason and with the same hazard as the lengths above.
#
# gen-trace held these as the literals 64 and 16 until 2026-10-01, so CompilePlan refused any other
# declared value instead of carrying it. It carries them now, which means the value has to REACH the
# generator -- and the paragraph above is about exactly the failure of resolving a value and then not
# passing it. BOTH gen-trace call sites take them: the offline plan-check and the real run. Passing only
# one would make the check a check of a different load than the card buys.
PREMIUM_OUTPUT_TOKENS="${PREMIUM_OUTPUT_TOKENS:-64}"
NOISY_OUTPUT_TOKENS="${NOISY_OUTPUT_TOKENS:-16}"
OUT="${OUT:-hack/m5c-run-$(date +%Y%m%d-%H%M%S)}"
LOG="$OUT/evidence.log"
GW_IMAGE="${GW_IMAGE:-gateway:m5c}"
# Whether the CALLER set these, recorded before the defaults below overwrite the answer.
#
# The ladder mode further down refuses a run that was given both a ladder and a single load, and it cannot
# ask that question after ARMS and REPS have been defaulted -- every run would look as though the operator
# had set them. This is the whole reason the snapshot exists, and it has to stay above the defaults.
ARMS_FROM_CALLER="${ARMS+set}"
REPS_FROM_CALLER="${REPS+set}"
# Four, matching hack/gpu-session.sh and the design.
#
# This defaulted to 2, and the session script it is meant to complement defaults to 4. The scripts do not
# read each other, so a re-run bought half the repetitions the study was designed around -- silently, and in
# the direction that weakens it. Two independent reviews scored the design's statistical power at 30% when
# n was 2 per cell and named the run count as the binding limit; that is the number this default was quietly
# restoring every time an arm was re-run.
#
# Below four the incremental interval is a bootstrap over very few blocks. Two is a floor the report will
# tolerate, not a target anything argued for.
REPS="${REPS:-4}"
# One trace seed per repetition, space-separated, or empty for the one seed every archive before 2026-10-04
# replayed in every repetition (11).
#
# Which of the two a run may use is the STUDY's to say, read through `benchharness study-traces` by
# resolve_seeds: a study registering a trace per repetition is refused without REPS distinct seeds here,
# before anything is rented, rather than by the report after every cell is paid for.
SEEDS="${SEEDS:-}"
# The arms, in the order they are run.
#
# R1 FIRST, and it is not a formality: it is the isolated baseline both bars are ratios against, so a run
# that is cut short after one cell should have the denominator rather than a numerator with nothing to
# divide by. It was absent from this default until the first paid run, whose readings then declined to
# evaluate anything for want of it.
#
# A session that only has time for a subset should say which rather than silently getting the default.
ARMS="${ARMS:-R1 shared timeSlicing mps}"

k() { kubectl --context "$KCTX" "$@"; }
# Both tee to the evidence log ONCE IT EXISTS, and only print before that.
#
# The preflight refusals run before $OUT is created, so tee'ing unconditionally printed
# `evidence.log: No such file or directory` underneath every one of them. A refusal that arrives with a
# spurious error beside it is how people learn to read past errors, which is the opposite of what a refusal
# is for.
say() { if [ -d "$OUT" ]; then echo "== $*" | tee -a "$LOG"; else echo "== $*"; fi; }
fail() { if [ -d "$OUT" ]; then echo "MATRIX FAILED: $*" | tee -a "$LOG" >&2; else echo "MATRIX FAILED: $*" >&2; fi; exit 1; }

case "$PLATFORM" in
  eks|kind) ;;
  *) fail "PLATFORM is ${PLATFORM@Q}; it must be eks or kind. Refusing rather than picking one: the two differ in what stops the card billing." ;;
esac

# LADDER turns this script into the capacity ladder of
# docs/superpowers/specs/2026-09-13-what-the-split-costs-in-throughput.md, and unset it changes nothing.
#
# It is a mode of this script rather than a second script because everything below the load -- acquiring the
# card, swapping the device plugin, rolling out one engine or two, the port-forward that is proved before it
# is used, the per-cell handover, the deadline projection -- is the same instrument, and a copy of it would
# be a copy that drifts. What differs is only which loads are offered and in which order.
#
# The format is one rung per whitespace-separated entry, two numbers joined by a colon, in climbing order.
# What the numbers mean is the STUDY's arrival model, read from internal/bench's registry: "RATE:NOISY_WEIGHT"
# for a weighted ladder, "PREMIUM_RATE:NOISY_RATE" for one registered with independent arrivals. The values
# are the pre-registration's, solved offline against the real gen-trace so that every rung offers the
# contender 139 requests give or take two while the premium rate climbs. They are passed rather than
# defaulted for the reason RATE is: a load this script chose for itself is a load nobody derived.
LADDER="${LADDER:-}"
if [ -n "$LADDER" ]; then
  # RATE and the ladder both describe the load, and a run that was given both would obey one of them
  # silently. Which one is not something an operator should have to read this file to find out.
  [ -z "${RATE:-}" ] || fail "RATE and LADDER are both set. The ladder carries a rate per rung, so a single RATE is either ignored or overrides them -- refusing rather than picking."
  [ -z "$ARMS_FROM_CALLER" ] || fail "ARMS and LADDER are both set. The ladder's arms are its two topologies plus one isolated baseline cell at the rung it stops on, which is not known until it stops."
  # The frozen matrix pools repetitions of one load. The ladder's rungs are DIFFERENT loads, and a run that
  # repeated them would write two files an arm summary would pool into a p99 for a load never offered.
  # A borderline rung is repeated by re-running that rung, which the pre-registration says and this refuses
  # to do by accident.
  [ -z "$REPS_FROM_CALLER" ] || fail "REPS and LADDER are both set. Ladder rungs are different loads rather than repetitions of one, and pooling two of them would report a p99 for a load that was never offered."
fi

# WHICH STUDY THE NON-LADDER PATH FILES ITS EVIDENCE UNDER, decided here rather than three hundred lines down.
#
# This used to be `STUDY=sharing-matrix-2026-09-10`, an unconditional assignment in the matrix branch that
# read nothing from the environment. Measured on 2026-10-04: passing STUDY=tail-crossing-lc256-2026-10-04
# with the frozen five produced "PLAN OK: every planned cell generates a trace the readings can score" and
# the requested study appeared NOWHERE in the output -- the plan stood under sharing-matrix-2026-09-10. The
# two tail-crossing studies freeze the same five load quantities as the sharing matrix at the short level,
# so `refuse_unfrozen_load` compared against the overwritten study and passed as well. A check that cannot
# tell "ran under the study I asked for" from "ran under a different one" is this repository's commonest
# defect, and it was sitting on the last gate before a purchase.
#
# Decided BEFORE the compiled-CR block, which is what makes the STUDY_FROM_CR comparison below possible at
# all: that guard had to compare against a literal because $STUDY did not exist yet when it ran. Placing it
# here costs nothing -- `[ -n "$LADDER" ] && fail` inside that block already refuses a ladder beside a CR, so
# the ladder's own study assignment cannot collide with this one.
#
# The allow-list follows the ladder's precedent at LADDER_STUDY rather than inventing a second shape, and for
# the reason that refusal gives: gen-trace does NOT check the arm against the study, so an unregistered id
# travels as far as replay's manifest validation -- which fires on the rented card after the engines are up.
if [ -z "$LADDER" ]; then
  STUDY="${STUDY:-sharing-matrix-2026-09-10}"
  case "$STUDY" in
    sharing-matrix-2026-09-10|tail-crossing-lc256-2026-10-04|tail-crossing-lc2048-2026-10-05|tail-crossing-lc8192-2026-10-04|instrument-validation-2026-10-05|instrument-validation-s2-2026-10-05|instrument-validation-s3-2026-10-06|instrument-validation-s4-2026-10-06|step-boundary-2026-10-06|step-confirm-2026-10-07|prospective-pilot-2026-10-08|admission-diagnostic-2026-10-10|admission-frontier-2026-10-10) ;;
    *) fail "STUDY is ${STUDY@Q}; the non-ladder matrix files evidence under sharing-matrix-2026-09-10, tail-crossing-lc256-2026-10-04, tail-crossing-lc2048-2026-10-05, tail-crossing-lc8192-2026-10-04, instrument-validation-2026-10-05, instrument-validation-s2-2026-10-05, instrument-validation-s3-2026-10-06, instrument-validation-s4-2026-10-06 or step-boundary-2026-10-06, step-confirm-2026-10-07, prospective-pilot-2026-10-08, admission-diagnostic-2026-10-10, admission-frontier-2026-10-10. An unregistered id is not refused by gen-trace -- it writes a manifest for any string -- so this refusal is the one that stops it before anything is rented" ;;
  esac
fi

# The instrument-validation study carries its trace length in the arm, so a run-wide one is refused.
#
# Each of its traces is three complete cycles of one episode type and gen-trace refuses a duration shorter
# than the trace, so a single DURATION_MS would be wrong for two of the three episode types.
# Refused rather than ignored, because an operator who set it believes it was used.
# A sweep beside it is refused for the same reason: the sweep builds be<NN>-shared arms this study does not
# have, and its load is two tenants where this study registers one.
if [ -z "$LADDER" ] && iv_is_study "$STUDY"; then
  [ -z "${DURATION_MS:-}" ] \
    || fail "DURATION_MS is ${DURATION_MS@Q} and study $STUDY sets the trace length per arm ($(iv_duration_summary "$STUDY")). A single value would be shorter than some arm's trace, and gen-trace refuses that; unset it"
  [ -z "${SWEEP:-}" ] \
    || fail "SWEEP is set and study $STUDY registers no best-effort sweep; its arms are {serial,burst,stagger}-{log,nolog,async}"
  [ -n "$ARMS_FROM_CALLER" ] \
    || fail "ARMS is unset and study $STUDY has none of the default topologies; name its arms, e.g. ARMS=\"serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog serial-async burst-async stagger-async\""
  for _arm in $ARMS; do
    _why=$(iv_duration_ms "$STUDY" "$_arm") || fail "$_why"
  done
fi

# A best-effort SWEEP: the latency-critical rate held at PREMIUM_RATE, the BE rate stepped through SWEEP.
#
# The 2026-10-04 model-first registration crosses LC length with BE load, holding the LC request rate, and
# each BE rate is its own arm (be01-shared, be02-shared, ...) so two loads cannot pool into one p99. A
# weighted RATE and NOISY_WEIGHT describe one mix of both tenants and cannot hold one tenant still, so they
# are refused beside a sweep rather than reconciled with it. Whether the study wants a sweep is checked
# against its registered arrival model once the binary exists (resolve_arrivals).
SWEEP="${SWEEP:-}"
PREMIUM_RATE="${PREMIUM_RATE:-}"
if [ -n "$SWEEP" ]; then
  [ -z "$LADDER" ] || fail "SWEEP and LADDER are both set. The ladder climbs the premium rate and the sweep holds it; one run is one of the two."
  [ -z "${RATE:-}" ] || fail "RATE and SWEEP are both set. A sweep holds PREMIUM_RATE and steps the BE rate; a total RATE describes a weighted mix this sweep does not draw."
  [ -z "${NOISY_WEIGHT:-}" ] || fail "NOISY_WEIGHT and SWEEP are both set. The sweep's BE rates are absolute, one per level, so a weight would be ignored."
  [ -z "$ARMS_FROM_CALLER" ] || fail "ARMS and SWEEP are both set. A sweep's arms are R1 and one be<NN>-shared per SWEEP entry, built from SWEEP so the name and the rate cannot disagree."
  [ -z "${BENCHMARK_CR_SHA256:-}" ] || fail "SWEEP and BENCHMARK_CR_SHA256 are both set. A CR compiles one weighted load, and the swept studies are not compiled from one."
  [ -n "$PREMIUM_RATE" ] || fail "SWEEP is set and PREMIUM_RATE is not. The sweep holds the latency-critical rate fixed, so it has to be named."
  for w in $PREMIUM_RATE $SWEEP; do
    case "$w" in
      *[!0-9.]* | *.*.* | . | '') fail "SWEEP/PREMIUM_RATE entry ${w@Q} is not a plain positive decimal" ;;
    esac
    awk -v x="$w" 'BEGIN {exit !(x > 0)}' || fail "SWEEP/PREMIUM_RATE entry ${w@Q} is not positive"
  done
  sweep_n=$(printf '%s\n' $SWEEP | awk 'NF {c++} END {print c+0}')
  # internal/bench admits be01-shared .. be06-shared; a seventh level would be named and then refused by the
  # report as an arm the study does not have.
  [ "$sweep_n" -le 6 ] || fail "SWEEP names $sweep_n BE rates and the tail-crossing studies admit six levels"
  # Compared as NUMBERS: 0.0286 and 0.02860 are one rate, and as strings they passed as two levels -- found
  # by an independent review, which bought the same condition twice under two names in a plan check.
  [ "$(printf '%s\n' $SWEEP | awk 'NF { k = sprintf("%.12g", $1 + 0); if (!seen[k]++) c++ } END {print c+0}')" = "$sweep_n" ] \
    || fail "SWEEP repeats a rate ($SWEEP); two levels at one rate are one condition under two names"
  ARMS="R1"
  for i in $(seq 1 "$sweep_n"); do ARMS="$ARMS $(printf 'be%02d-shared' "$i")"; done
elif [ -n "$PREMIUM_RATE" ] && ! pp_is_study "${STUDY:-}"; then
  fail "PREMIUM_RATE is set without SWEEP. It is the held latency-critical rate of a sweep, and on its own it would be ignored."
fi

# A compiled CR owns the load, and the environment may not quietly disagree with it.
#
# `benchharness compile-plan` turns a GpuSharingBenchmark into exactly the exports below and sets
# BENCHMARK_CR_SHA256 beside them. Everything this script reads is an environment variable, so an operator
# who sourced that block and then also exported RATE by hand would run one load while the evidence named
# another -- and the CR's digest in the manifest would point at a file that does not describe the run.
#
# So the digest's presence is the switch: with it, these variables must come from the compiled block and a
# second source is a refusal; without it, nothing changes and every existing caller keeps working. The
# refusal cannot tell WHICH assignment came from the block, so it asks the operator to drop the extra one
# rather than guessing -- a guard that picks a winner silently is the thing being prevented.
if [ -n "${BENCHMARK_CR_SHA256:-}" ]; then
  case "$BENCHMARK_CR_SHA256" in
    *[!0-9a-f]* | "") fail "BENCHMARK_CR_SHA256 is ${BENCHMARK_CR_SHA256@Q}, which is not a sha256; it is written by benchharness compile-plan and should be sourced, not typed" ;;
  esac
  [ ${#BENCHMARK_CR_SHA256} -eq 64 ] || fail "BENCHMARK_CR_SHA256 is ${#BENCHMARK_CR_SHA256} characters; a sha256 is 64"
  [ -n "$LADDER" ] && fail "LADDER and BENCHMARK_CR_SHA256 are both set. A CR declares one load and the ladder is a sequence of different ones, so the compiled plan would be ignored for every rung."
  # STUDY is not on this list: compile-plan is told which study the evidence is filed under, because the CR
  # has no field for it, and it prints that value into the same block. It is passed, not compiled.
  # RATE and the three weights have NO default in this script, so emptiness is the right test for them.
  for v in RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT; do
    [ -n "${!v:-}" ] || fail "$v is unset although BENCHMARK_CR_SHA256 is set. Source the whole block benchharness compile-plan prints; a partial one leaves this script defaulting a value the CR declared."
  done
  # The six that DO have defaults are checked by their snapshots instead.
  #
  # Emptiness cannot see them: they were defaulted a hundred lines above this block, so a compiled block
  # missing PREMIUM_OUTPUT_TOKENS reached here holding 64 and passed. The snapshot records whether the
  # caller supplied the value, which is the question this check is actually asking.
  for v in PREMIUM_PROMPT_CHARS NOISY_PROMPT_CHARS REQUEST_TIMEOUT_MS MODEL_REVISION \
           PREMIUM_OUTPUT_TOKENS NOISY_OUTPUT_TOKENS; do
    snap="${v}_FROM_CALLER"
    [ -n "${!snap}" ] || fail "$v was not supplied although BENCHMARK_CR_SHA256 is set, so this run would use this script's own default while the CR declared a value. Source the whole block benchharness compile-plan prints."
  done
  # ARMS and REPS are checked through the FROM_CALLER flags and not for emptiness, because by this line they
  # are never empty: both were defaulted above, ARMS to all four topologies. A run that sourced a compiled
  # block without them would therefore have passed this guard and then bought FOUR arms for a CR that
  # compiled to two -- which is exactly the disagreement this block exists to refuse. Measured: dropping
  # ARMS from the block left the run reporting "load compiled from a GpuSharingBenchmark" and nothing else.
  [ -n "$ARMS_FROM_CALLER" ] || fail "ARMS is unset although BENCHMARK_CR_SHA256 is set, so this run would take the default of all four topologies while the CR compiled to a different set. Source the whole block benchharness compile-plan prints."
  [ -n "$REPS_FROM_CALLER" ] || fail "REPS is unset although BENCHMARK_CR_SHA256 is set, so this run would take the default repetition count rather than the one the CR declares. Source the whole block benchharness compile-plan prints."
  # MODEL_REVISION is the third defaulted one, and absence is the wrong test for it for the same reason:
  # line 65 fills it before this block runs, so a block missing that line produces a run at the default and
  # nothing looks wrong. It is compared instead, against the revision the plan resolved the prompt lengths
  # against -- which also refuses a revision overridden by hand, a case absence could never have caught.
  [ -n "${BENCHMARK_CR_TOKENIZER_REV:-}" ] \
    || fail "BENCHMARK_CR_TOKENIZER_REV is unset although BENCHMARK_CR_SHA256 is set. Source the whole block benchharness compile-plan prints; without it MODEL_REVISION cannot be checked against the plan and would silently take this script's default."
  [ "$MODEL_REVISION" = "$BENCHMARK_CR_TOKENIZER_REV" ] \
    || fail "MODEL_REVISION is $MODEL_REVISION but the compiled plan resolved its prompt lengths against $BENCHMARK_CR_TOKENIZER_REV. The character counts in this run were measured under one tokenizer and the manifest would name another."
  # The study the CR was compiled FOR, against the study this run files its evidence under.
  #
  # The frozen matrix sets STUDY itself a few hundred lines below, and compile-plan was told a study when it
  # translated the CR's two per-tenant rates into a total rate and a weight -- a translation that is only
  # this load under a weighted arrival model. If the two disagree, the trace was built for one experiment
  # and the evidence would be filed under another.
  #
  # Carried under its own name because the two arrive by different routes: compile-plan prints both STUDY and
  # STUDY_FROM_CR, and hack/m5c-gpu-session.sh bakes only the latter into the instance. Comparing them is what
  # catches a block compiled for one experiment sourced into a run filing evidence under another.
  #
  # Compared against $STUDY rather than against a literal, now that the block above has decided $STUDY before
  # this line runs. The literal was not a style choice -- $STUDY genuinely did not exist here -- and it meant
  # this guard could only ever defend one study. It now defends whichever the run declared.
  if [ -n "${STUDY_FROM_CR:-}" ] && [ -z "$LADDER" ] && [ "$STUDY_FROM_CR" != "$STUDY" ]; then
    fail "the plan was compiled for study $STUDY_FROM_CR but this run files its evidence under $STUDY. The arrival model the rates were translated under belongs to the compiled study, so the trace would not be the load this study registered."
  fi
  say "load compiled from a GpuSharingBenchmark, sha256 $BENCHMARK_CR_SHA256"
fi

# The instrument-validation study has no load to set: its episodes are laid out by the generator.
# A caller's load variable is refused rather than ignored, because a value that was set and silently unused
# reads, in load-source.txt, like the load the cells ran at; the cell specs then carry zeros, which nothing reads.
if [ -z "$LADDER" ] && iv_is_study "$STUDY"; then
  for v in RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT PREMIUM_RATE; do
    [ -z "${!v:-}" ] || fail "$v is ${!v@Q} and study $STUDY takes no load; its episodes are the registration's. Unset it"
  done
  # The prompt shape as well: its lengths and caps vary by row, and a caller's value would be dropped before
  # gen-trace while load-source.txt recorded it as declared (found by review, reproduced with PLAN_ONLY).
  [ -z "$SHAPE_FROM_CALLER" ] \
    || fail "${SHAPE_FROM_CALLER# } set, and study $STUDY's lengths and output caps are the registration's, varying by row. Unset them"
  RATE=0 PREMIUM_WEIGHT=0 NOISY_WEIGHT=0 PROBE_WEIGHT=0
fi
# The prospective-admission pilot: two tenants at fixed independent rates, one block of its stage's arms per
# repetition (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "The measurement pilot").
# Its load is the registration's and is required whole; a weighted RATE or a sweep would describe another load.
if [ -z "$LADDER" ] && pp_is_study "$STUDY"; then
  [ -z "${SWEEP:-}" ] || fail "SWEEP is set and the pilot is not a sweep; its contender rate is PILOT_NOISY_RATE"
  [ -z "${RATE:-}" ] || fail "RATE is ${RATE@Q} and the pilot's arrivals are independent; pass PREMIUM_RATE and PILOT_NOISY_RATE"
  [ -z "$ARMS_FROM_CALLER" ] || fail "ARMS is set and the pilot's arms are its stage's (PILOT_STAGE); unset it"
  _pp_arms=$(pp_stage_arms "${PILOT_STAGE:-}" 2>&1) || fail "$_pp_arms"
  # Each stage belongs to one study: evidence filed under another would be scored by rules it was not bought under.
  _pp_study=$(pp_stage_study "$PILOT_STAGE" 2>&1) || fail "$_pp_study"
  [ "$_pp_study" = "$STUDY" ] || fail "PILOT_STAGE ${PILOT_STAGE} does not belong to study $STUDY: it is $_pp_study's"
  # The plan check and the banner read ARMS; left at the sharing matrix's default, the check judged a set this run
  # never buys (v26 review, C6).
  ARMS=$(printf '%s\n' "$_pp_arms" | paste -sd' ')
  # v26's seeds are frozen with its traces' checksums; another seed would be another experiment under its name.
  if [ "$STUDY" = "$PP_FRONTIER_STUDY" ]; then
    [ "$(printf '%s ' $SEEDS)" = "$PP_FRONTIER_SEEDS " ] || fail "SEEDS is ${SEEDS@Q} and v26 froze $PP_FRONTIER_SEEDS"
  fi
  # Three blocks per stage, as the study registers: the main endpoint pools three, and pooling is not linear in
  # the number of blocks, so a stage of another size would measure a different quantity (review of 780929a).
  [ "$REPS" = 3 ] || fail "REPS is $REPS and each pilot stage is three blocks; pass REPS=3"
  # The engine's revision and model are the registration's, not the caller's: the validator compares the engine
  # against these, and a caller-supplied value would set both sides of that comparison (pilot review 11).
  [ "$MODEL_REVISION" = "$PP_MODEL_REVISION" ] \
    || fail "MODEL_REVISION is $MODEL_REVISION and the pilot registered $PP_MODEL_REVISION"
  [ "$MODEL" = "$PP_MODEL" ] || fail "MODEL is $MODEL and the pilot registered $PP_MODEL"
  [ "${PILOT_STAGE:-}" != B ] || pp_gateway_args static-cap "${PILOT_STATIC_RATE:-}" >/dev/null \
    || fail "stage B runs the static arm at the rate R fitted in stage A; set PILOT_STATIC_RATE"
  RATE=0 NOISY_WEIGHT=0
fi
[ -n "${RATE:-}" ] || [ -n "$LADDER" ] || [ -n "$SWEEP" ] || fail "RATE is unset. Measure it from a single contender prefill on THIS card, the way hack/m5b-gpu-session.sh does; the harness default of 20/s demands 3.8x an A10G's theoretical peak and would censor every arm."

# The whole load, passed rather than defaulted -- and RATE alone was never enough.
#
# hack/m5b-price-of-protection.sh says it in one line: "gen-trace's defaults are stub-calibrated and the
# first pilot ran them at a GPU at ten times its prefill capacity." This script asked for RATE and left the
# tenant MIX at those defaults, which is the larger half of the same mistake.
#
# The arithmetic, because it is the reason this is a refusal and not a default. gen-trace defaults to
# premium 1, noisy 1 and two probe tenants at 0.1, so the contender takes 45% of arrivals. Its prompt is
# 40,000 characters, about 7,744 tokens, which the paid evidence measured at roughly 1.03 s of engine each.
# At the price-of-protection run's RATE of 9.85 that is 4.5 contender arrivals a second against a card that
# can serve about one -- four to five times capacity, and every arm censored.
#
# AND NO RATE FIXES IT. Bringing the contender down to the ~0.5/s that run used means RATE near 1.1, which
# leaves the premium tenant at about 0.5/s too: fewer than a hundred premium requests in a trace of this
# length, under the MinTailSamples floor that reading 4b exists to enforce. The mix has to move, not the
# rate. The run that measured a workable one used premium 1, noisy 0.054, probe 0.0054.
#
# DURATION_MS is here for the same reason. It used to be derived as 500/(RATE/2), an arithmetic that assumes
# the two tenants split arrivals evenly -- true of the defaults above and false of any calibrated mix, so it
# would have sized the trace from a premise the run had just abandoned.
# In ladder mode the contender's load is a property of the RUNG, because that is what holds the contender at a
# fixed absolute count while the premium rate climbs. A single NOISY_WEIGHT beside a ladder would be silently
# ignored, so it is refused.
REQUIRED_LOAD_VARS="PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT DURATION_MS"
if [ -n "$LADDER" ]; then
  [ -z "${NOISY_WEIGHT:-}" ] || fail "NOISY_WEIGHT and LADDER are both set. The ladder carries the contender's load per rung -- a weight, or a rate under a study registered with independent arrivals -- and that is how it holds the contender fixed in absolute terms while the premium rate climbs, so a single weight here would be ignored."
  REQUIRED_LOAD_VARS="PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS"
fi
# A sweep carries the BE rate per level, as the ladder carries it per rung, and NOISY_WEIGHT was refused
# beside it above. PREMIUM_WEIGHT and PROBE_WEIGHT stay required: resolve_arrivals insists on 1 and 0 under
# independent arrivals, so a run says it has no probes rather than inheriting a weight that would be ignored.
[ -z "$SWEEP" ] || REQUIRED_LOAD_VARS="PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS"
# The instrument-validation study's duration comes from each arm, and a run-wide one was refused above.
# Nor does it have a load to require: its traces are episodes the generator lays out, and gen-trace refuses every
# rate, weight and prompt flag for it, so demanding them here would demand values that are then thrown away.
if [ -z "$LADDER" ] && iv_is_study "$STUDY"; then REQUIRED_LOAD_VARS=""; fi
if [ -z "$LADDER" ] && pp_is_study "$STUDY"; then REQUIRED_LOAD_VARS="PREMIUM_RATE PILOT_NOISY_RATE PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS"; fi
for v in $REQUIRED_LOAD_VARS; do
  [ -n "${!v:-}" ] || fail "$v is unset. RATE alone does not describe this load: gen-trace's default mix puts the 40,000-character contender at 45% of arrivals, which is four to five times an A10G's prefill capacity at any rate this study could use, and lowering RATE to compensate starves the premium tail below the MinTailSamples floor. Derive the mix on the card and pass all four. hack/m5b-price-of-protection.sh measured RATE=9.85 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0.0054 DURATION_MS=420000 for ONE engine with the whole card; this run gives each engine half of one, so it is a starting point and not an answer."
done
# The engine build every arm runs, taken from the manifests rather than written here.
#
# The paid manifests carried no image identity at all: gen-trace has accepted --engine-image since it was
# written and nothing ever passed it, so a run's numbers named no build. They are digest-pinned in the
# YAML, which is the only place that can be true, and reading it here is what puts it in the record.
#
# The three files must AGREE. Two topologies running different engine builds is not a comparison of
# topologies, and nothing else in this script would notice: each arm applies its own manifest.
# WHATEVER the manifests pin, not a particular repository -- but it has to be a DIGEST.
#
# This matched `vllm/vllm-openai@sha256:` by name, which is the image the paid run uses and not the only
# image this script ever runs: the kind rehearsal substitutes a stub engine in a throwaway copy, and a check
# written around the production repository refused the rehearsal instead of the thing it was guarding
# against. What matters is that the reference is immutable and that the three manifests agree, neither of
# which is a statement about who publishes the image.
engine_image_in() { grep -m1 -oE 'image: *[^ ]+' "$1" | sed 's/image: *//'; }
# Unquoted where it is used, because empty must expand to NO argument rather than to an empty one.
PROVENANCE_FLAG="--require-provenance"
ENGINE_IMAGE=$(engine_image_in config/vllm/deployment.yaml)
[ -n "$ENGINE_IMAGE" ] \
  || fail "config/vllm/deployment.yaml names no engine image, so this run could not record which build produced its numbers"
# The waiver exists for ONE caller and cannot reach a paid run.
#
# hack/test/rehearse-m5c-matrix.sh substitutes a stub engine it builds locally, and a locally built image
# has no registry digest a kubelet can resolve -- so the rehearsal's tree genuinely violates the invariant
# this check enforces. The alternatives were to weaken the check for everyone or to let the rehearsal stop
# covering the ladder. This is the third: an explicitly named waiver that says what it costs, and that
# hack/m5c-gpu-session.sh -- the only thing in this repository that rents a card -- refuses to pass on.
case "${ENGINE_PIN_WAIVED:-}${ENGINE_IMAGE}" in
  1*) say "WARNING: the engine image pin is WAIVED. This run's evidence cannot name the engine build that produced it, and no paid run may carry this waiver"
      PROVENANCE_FLAG="" ;;
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) fail "config/vllm/deployment.yaml pins the engine to ${ENGINE_IMAGE@Q}, which is a tag rather than a digest. A tag names whatever was pushed under it most recently, so the record would identify nothing after the next build" ;;
esac
# The agreement check is waived with the pin, and for the same reason.
#
# hack/test/rehearse-m5c-failures.sh makes an engine unstartable by pointing ONE manifest at an image that
# does not exist -- which is a deliberate disagreement, and refusing it here meant the scenario could never
# reach the diagnosis it exists to pin. A waived tree is a tree whose engine references are not the
# production ones, so this file does not judge them; the wrapper refuses to pass the waiver on to anything
# that rents a card.
if [ -z "${ENGINE_PIN_WAIVED:-}" ]; then
  for m in config/vllm-shared/engine-a.yaml config/vllm-shared/engine-b.yaml; do
    other=$(engine_image_in "$m")
    [ "$other" = "$ENGINE_IMAGE" ] \
      || fail "$m pins ${other:-no engine image} and config/vllm/deployment.yaml pins $ENGINE_IMAGE. Two topologies on two engine builds is not a comparison of topologies"
  done
fi
# The gateway's build is named three ways: the COMMIT this tree is at, the image ID the build below prints,
# and the gateway's content -- the binary's sha256 and the base it sits on.
# The image ID changes with every build of the same binary on the same base, so a reproduction compares the
# content instead (docs/superpowers/specs/2026-10-07-gateway-identity-for-reproduction.md).
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
# Pinned by digest: the tag this replaced could put two builds of one commit on two different bases.
GW_BASE="gcr.io/distroless/static@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3"

# The arrival model this run's study registered, and the gen-trace load flags for one cell under it.
#
# A rung entry is two numbers whose meaning the STUDY decides, so the model comes from internal/bench's
# registry through `benchharness study-arrivals` rather than from a variable here that could disagree with
# it. gen-trace refuses the other model's flags for any study that registered one, so a mismatch stops at
# generation instead of reaching a replay. Resolved once the binary exists, which is later on each path.
ARRIVALS=""
resolve_arrivals() {
  local out
  # Every study is asked now. The frozen sharing matrix registers no arrival model and has only ever been
  # generated weighted, so "registered no arrival model" -- and nothing else -- falls back to weighted; the
  # tail-crossing studies register independent arrivals since 2026-10-04, which the shell used to override
  # by hard-coding weighted on this path without asking.
  if out=$("$WORK/benchharness" study-arrivals --study "$STUDY" 2>&1); then
    ARRIVALS="$out"
  else
    case "$out" in
      *"registered no arrival model"*) ARRIVALS=weighted ;;
      *) fail "could not read study $STUDY's arrival model from the registry: $out" ;;
    esac
  fi
  if [ -z "$LADDER" ]; then
    # A study whose arrivals are independent is run as a sweep and only as a sweep, and the reverse.
    if [ "$ARRIVALS" = independent ] && [ -z "$SWEEP" ] && ! pp_is_study "$STUDY"; then
      fail "study $STUDY registers independent arrivals, so it is run as a SWEEP of BE rates with PREMIUM_RATE held; RATE and NOISY_WEIGHT describe a weighted mix it does not draw"
    fi
    if [ "$ARRIVALS" != independent ] && [ -n "$SWEEP" ]; then
      fail "study $STUDY registers $ARRIVALS arrivals, so a SWEEP of absolute BE rates is not its load; a sweep needs a study registered with independent arrivals"
    fi
  fi
  # Independent arrivals have no mix to weight and this ladder has no probes, so the two weights the load
  # still requires must say exactly that rather than describe a mix that would be ignored.
  if [ "$ARRIVALS" = independent ] && { [ "$PREMIUM_WEIGHT" != 1 ] || [ "$PROBE_WEIGHT" != 0 ]; }; then
    fail "study $STUDY registered independent arrivals, where each rung carries the premium and contender RATES and the probes are off; PREMIUM_WEIGHT=$PREMIUM_WEIGHT PROBE_WEIGHT=$PROBE_WEIGHT describe a weighted mix that would be ignored, so pass 1 and 0"
  fi
}
# The trace policy this run's study registered, and the seed list checked against it.
#
# A per-repetition study replaying one seed is the defect the 2026-10-04 registration found in every
# archive: five repetitions of one draw of the arrival process. The report refuses that evidence, and this
# refuses the run that would produce it while refusing is still free.
TRACE_POLICY=""
resolve_seeds() {
  local n distinct w
  TRACE_POLICY=$("$WORK/benchharness" study-traces --study "$STUDY") \
    || fail "could not read study $STUDY's trace policy from the registry"
  for w in $SEEDS; do
    case "$w" in
      '' | *[!0-9]*) fail "SEEDS entry ${w@Q} is not a non-negative integer" ;;
      # Canonical spelling only. gen-trace reads 07 as 7, so "7 07" passed the distinctness test below as
      # two strings and generated one trace twice -- found by an independent review.
      0?*) fail "SEEDS entry ${w@Q} has a leading zero; write it as $((10#$w)) so two spellings of one seed cannot pass as two seeds" ;;
    esac
  done
  # awk, not grep: with SEEDS empty `grep .` exits 1, and under pipefail that assignment ended the whole script
  # with no message -- measured, on the first run of this function, while refuse_unfrozen_load was still
  # switching errexit on for everything after it.
  n=$(printf '%s\n' $SEEDS | awk 'NF {c++} END {print c+0}')
  distinct=$(printf '%s\n' $SEEDS | awk 'NF && !seen[$1]++ {c++} END {print c+0}')
  case "$TRACE_POLICY" in
    one)
      [ "$distinct" -le 1 ] \
        || fail "study $STUDY replays one trace in every repetition, and SEEDS names $distinct different seeds; its report refuses an arm whose repetitions came from different traces"
      ;;
    per-repetition)
      [ "$n" -gt 0 ] \
        || fail "study $STUDY registers a trace per repetition, so SEEDS must name one seed for each of the $REPS repetitions; the default would replay seed 11 $REPS times, one draw of the arrival process measured again"
      [ "$n" = "$REPS" ] || fail "SEEDS names $n seed(s) and REPS is $REPS; study $STUDY needs exactly one per repetition"
      [ "$distinct" = "$n" ] || fail "SEEDS repeats a seed ($SEEDS); two repetitions of study $STUDY would replay one trace"
      ;;
    *) fail "study $STUDY's trace policy is ${TRACE_POLICY@Q}, which this script does not know" ;;
  esac
}
# seed_for_rep prints the seed repetition $1 is generated from.
seed_for_rep() {
  if [ -z "$SEEDS" ]; then
    echo 11
  elif [ "$TRACE_POLICY" = per-repetition ]; then
    printf '%s\n' $SEEDS | sed -n "${1}p"
  else
    printf '%s\n' $SEEDS | sed -n 1p
  fi
}
# load_banner says what this run offers, in the terms of its mode.
#
# A function at column zero so a harness can run THIS code under `set -u`. RATE and NOISY_WEIGHT do not
# exist in ladder or sweep mode, and naming them here is not cosmetic: the first ladder rehearsal died on
# this line with "RATE: unbound variable" after building the cluster and both images, and the sweep's first
# version reached it the same way -- PLAN_ONLY never runs it, so an independent review found it, not a test.
load_banner() {
  if [ -n "$LADDER" ]; then
    say "load: a ladder of $(printf '%s\n' $LADDER | wc -l | tr -d ' ') rungs, ${DURATION_MS}ms per cell, weights premium=$PREMIUM_WEIGHT probe=$PROBE_WEIGHT"
    say "      rungs: $LADDER (read under study $STUDY's registered arrival model)"
    say "run:  the two contended topologies at every rung, counterbalanced, plus one isolated baseline cell, on $PLATFORM, output $OUT"
  elif [ -n "$SWEEP" ]; then
    say "load: a sweep, ${DURATION_MS}ms per cell, latency-critical held at ${PREMIUM_RATE}/s, best-effort at $SWEEP /s, seeds ${SEEDS:-11 in every repetition}"
    say "run:  ${REPS} repetitions of [$ARMS] on $PLATFORM, output $OUT"
  elif iv_is_study "$STUDY"; then
    # DURATION_MS is refused for this study, so naming it here would die on `set -u`.
    say "load: none -- registered episodes, one tenant; the trace length per arm ($(for a in $ARMS; do printf '%s=%sms ' "$a" "$(iv_duration_ms "$STUDY" "$a")"; done))"
    say "run:  ${REPS} block(s) of the synchronous arms in [$ARMS], each block in its own order, then the async arms once, on $PLATFORM, output $OUT"
  else
    say "load: rate ${RATE}/s, ${DURATION_MS}ms per arm, weights premium=$PREMIUM_WEIGHT noisy=$NOISY_WEIGHT probe=$PROBE_WEIGHT"
    say "run:  ${REPS} repetitions of [$ARMS] on $PLATFORM, output $OUT"
  fi
}
# refuse_unfrozen_load compares the load this run will OFFER against the tuple its study froze.
#
# The registration froze five quantities on 2026-10-01 -- premium and contender prompt characters, the
# timeout, and both output caps -- and nothing compared them. Measured on 2026-10-02: every one of them
# could be overridden on the command line and the pre-purchase plan check passed unchanged, and the CR path
# enforced only the two lengths because compile-plan resolves those from the measured table while the
# timeout and the caps come straight from the CR with no comparison at all.
#
# FIVE, not four. The output caps are two fields; counting them as one is how a check gets written for four
# of them.
#
# The five variables compared here are the SAME variables both gen-trace calls read ($PREMIUM_PROMPT_CHARS
# and friends, at the two call sites), and they are assigned once each where their defaults are declared.
# So "the value checked" and "the value consumed" are the same shell variable rather than two copies that
# could drift -- which is the thing a check like this most easily gets wrong.
#
# Studies that froze nothing are not exempted by silence: `study-frozen-tuple` REFUSES for them, and this
# function treats that refusal as "no frozen tuple to enforce" only for a study that is registered. The
# ladder reaches here with its own study id and its own lengths -- the down ladder registers a 40,000-char
# contender against the matrix's 42,579 -- so enforcing the matrix tuple on the common path would wrongly
# block a ladder that has never been bought.
refuse_unfrozen_load() {
  local out rc
  # The status is taken WITHOUT touching the shell's options. This read `set +e; out=$(...); rc=$?; set -e`,
  # and the `set -e` turned ON an errexit this script never had (line 33 is `set -uo pipefail`), for every
  # line after the first call. Its first casualty was the gateway forward's `kill; wait` at the start of the
  # second cell: `wait` returns the killed forward's status, errexit ended the matrix with no message, and
  # both the kind rehearsal and the 2026-10-04 calibration on a rented card stopped there -- the "cell 2,
  # cause unidentified" failure recorded since 2026-10-03.
  if out=$("$WORK/benchharness" study-frozen-tuple --study "$STUDY" 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    # "froze no load tuple" is the only non-zero this may continue past, and only for a study the registry
    # knows. Any other failure -- an unregistered study, a drift between the frozen characters and the
    # resolution table, a binary that could not run -- is a refusal, because recovering to the defaults is
    # exactly how an unchecked load reached a rented card.
    case "$out" in
      *"froze no load tuple"*)
        say "study $STUDY froze no load tuple; the five load quantities are not compared for it"
        return 0 ;;
      *) fail "could not read study $STUDY's frozen load tuple: $out" ;;
    esac
  fi
  # Sourced into locals rather than the global namespace, so a FROZEN_* name cannot be mistaken later for
  # the value the run is actually offering.
  local FROZEN_PREMIUM_PROMPT_CHARS="" FROZEN_NOISY_PROMPT_CHARS="" FROZEN_REQUEST_TIMEOUT_MS=""
  local FROZEN_PREMIUM_OUTPUT_TOKENS="" FROZEN_NOISY_OUTPUT_TOKENS=""
  eval "$(printf '%s\n' "$out" | grep -E '^FROZEN_[A-Z_]+=[0-9]+$' || true)"
  local mismatch=0
  for pair in \
    "premium prompt characters|PREMIUM_PROMPT_CHARS|$PREMIUM_PROMPT_CHARS|$FROZEN_PREMIUM_PROMPT_CHARS" \
    "contender prompt characters|NOISY_PROMPT_CHARS|$NOISY_PROMPT_CHARS|$FROZEN_NOISY_PROMPT_CHARS" \
    "request timeout in ms|REQUEST_TIMEOUT_MS|$REQUEST_TIMEOUT_MS|$FROZEN_REQUEST_TIMEOUT_MS" \
    "premium output cap|PREMIUM_OUTPUT_TOKENS|$PREMIUM_OUTPUT_TOKENS|$FROZEN_PREMIUM_OUTPUT_TOKENS" \
    "contender output cap|NOISY_OUTPUT_TOKENS|$NOISY_OUTPUT_TOKENS|$FROZEN_NOISY_OUTPUT_TOKENS"; do
    IFS='|' read -r label var have want <<<"$pair"
    # An empty expectation means the lookup printed fewer than five assignments. That is a MISSING FIELD and
    # not a pass: a comparison against "" would succeed for any value and report the load as frozen.
    [ -n "$want" ] || fail "study $STUDY's frozen tuple did not carry the $label, so this run's $var could not be compared against it. The lookup printed: $out"
    if [ "$have" != "$want" ]; then
      echo "FROZEN LOAD MISMATCH: $label ($var) is $have and study $STUDY froze $want" >&2
      mismatch=$(( mismatch + 1 ))
    fi
  done
  [ "$mismatch" = 0 ] \
    || fail "$mismatch of the five frozen load quantities differ from what study $STUDY registered, so this run would offer a load that study did not freeze and file the evidence under it anyway. Change the load back, or register a different study with a dated amendment."
  say "load matches study $STUDY's frozen tuple (five quantities)"
}
# The trace length one cell is generated at, in ms.
#
# Every study but one has a single DURATION_MS and gets it back unchanged here.
# The instrument-validation study's length is its arm's, because each trace is three complete cycles of one
# episode type; both gen-trace calls, the deadline projection and load-source.txt read it from here so the
# four cannot disagree about one cell.
cell_duration_ms() {
  if [ -z "${LADDER:-}" ] && iv_is_study "${STUDY:-}"; then
    iv_duration_ms "$STUDY" "$1"
  else
    echo "$DURATION_MS"
  fi
}
# The card time one cell is charged in the deadline projections, in ms: its trace length plus its warm-up's.
#
# Separate from cell_duration_ms because that one is passed to gen-trace as --duration-ms, and the warm-up
# must not lengthen the measured trace.
# Every study without a warm-up is charged exactly its trace length, so its projections are as before.
cell_charge_ms() {
  local ms warm
  ms=$(cell_duration_ms "$1") || { echo "$ms"; return 1; }
  if [ -z "${LADDER:-}" ] && iv_has_warmup "${STUDY:-}"; then
    warm=$(warmup_span_ms "$1" "$2") || { echo "$warm"; return 1; }
    ms=$(( ms + warm ))
  fi
  echo "$ms"
}
# Generates one cell's warm-up trace: the arm's own gen-trace call, plus --warmup.
#
# The same seed, study, arm and flags as the measured trace, so the warm-up's unscored cycle is drawn from
# the cell's own episode type and the generator, not this file, decides what the warm-up holds.
# Only --duration-ms differs: the warm-up is one cycle and has its own registered bound.
# Arguments after the four paths are passed through, for the provenance flags only a real cell has.
# LOAD_FLAGS is empty under the episode arrivals these studies resolve to, and may not exist yet when a
# projection runs before the first cell, so it is expanded only if set.
warmup_gen_trace() {
  local label="$1" rep="$2" trace="$3" manifest="$4" dur
  shift 4
  dur=$(iv_warmup_duration_ms "$STUDY" "$label") || { echo "$dur"; return 1; }
  "$WORK/benchharness" gen-trace --warmup --seed "$(seed_for_rep "$rep")" --duration-ms "$dur" \
    ${LOAD_FLAGS[@]+"${LOAD_FLAGS[@]}"} \
    --study "$STUDY" --arm "$label" --model "$MODEL" --gateway-url "http://127.0.0.1:18080" \
    "$@" ${PROMPT_FLAGS[@]+"${PROMPT_FLAGS[@]}"} \
    --timeout-ms "$REQUEST_TIMEOUT_MS" \
    --trace-out "$trace" --manifest-out "$manifest"
}
# The warm-up's own span in ms, as iv_trace_span_ms reads it off the cell's generated warm-up trace.
#
# Read from the generated trace rather than estimated, because the warm-up holds one whole cycle of the
# cell's episode type and only the generator knows how long that is.
# The trace is generated once per cell into $WORK and reused, so a projection asked before every cell does
# not run gen-trace twenty-one times each time.
warmup_span_ms() {
  local label="$1" rep="$2" t="$WORK/warmup-plan-$1-$2.jsonl" out
  if [ ! -s "$t" ]; then
    out=$(warmup_gen_trace "$label" "$rep" "$t" "$WORK/warmup-plan-$1-$2.yaml" 2>&1) \
      || { echo "gen-trace --warmup could not build $label rep $rep's warm-up trace: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  fi
  iv_trace_span_ms "$t"
}
set_load_flags() {
  case "$ARRIVALS" in
    weighted)    LOAD_FLAGS=(--rate "$1" --premium-weight "$PREMIUM_WEIGHT" --noisy-weight "$2" --probe-weight "$PROBE_WEIGHT") ;;
    independent) LOAD_FLAGS=(--premium-rate "$1" --noisy-rate "$2" --probe-rate 0) ;;
    # The episode generator takes no load: lengths, caps and spacing are the registration's, not the caller's.
    episodes)    LOAD_FLAGS=() ;;
    *) fail "no arrival model was resolved for study $STUDY before generating a trace" ;;
  esac
}

# The prompt and output flags both gen-trace calls pass, held once so the plan and the run cannot differ.
#
# The instrument-validation study passes none: its lengths and caps vary by row and are the registration's, and
# gen-trace refuses these flags for it rather than let one value pretend to describe every row.
if [ -z "$LADDER" ] && iv_is_study "$STUDY"; then
  PROMPT_FLAGS=()
else
  PROMPT_FLAGS=(--premium-prompt-chars "$PREMIUM_PROMPT_CHARS" --noisy-prompt-chars "$NOISY_PROMPT_CHARS"
    --premium-output-tokens "$PREMIUM_OUTPUT_TOKENS" --noisy-output-tokens "$NOISY_OUTPUT_TOKENS")
fi

CELLS=()
if [ -n "$LADDER" ]; then
  # Which ladder this is. They carry the same arm names and the same criterion and differ in where their rungs
  # sit or in how their traces are generated, so the study id is what tells a reader -- and a report -- which
  # experiment a row belongs to. Defaulted to the first so an existing caller keeps working.
  STUDY="${LADDER_STUDY:-throughput-ladder-2026-09-13}"
  case "$STUDY" in
    throughput-ladder-2026-09-13|throughput-ladder-down-2026-09-13|throughput-ladder-independent-2026-09-15) ;;
    *) fail "LADDER_STUDY is ${STUDY@Q}; internal/bench registers throughput-ladder-2026-09-13, throughput-ladder-down-2026-09-13 and throughput-ladder-independent-2026-09-15. This refusal is the one that stops it: gen-trace does NOT check the arm against the study -- it writes a manifest for any string -- and the check that does is in replay's manifest validation, which fires on the rented card after the engines are up" ;;
  esac
  ladder_rung=0
  for entry in $LADDER; do
    ladder_rung=$(( ladder_rung + 1 ))
    # `skip` holds a rung's POSITION without buying it.
    #
    # A repetition of rungs 2 and 3 must write rung02-* and rung03-*, not rung01-* and rung02-*: the arm name
    # carries the rung so that two different offered loads can never pool into one summary, and a run that
    # renumbered them would file 2.31 req/s under the name the first run gave 1.16 req/s. Dropping the entry
    # instead of marking it would shift every rung below it by one.
    case "$entry" in
      skip) continue ;;
      *:*) ;;
      *) fail "LADDER entry ${entry@Q} is not two numbers joined by a colon (RATE:NOISY_WEIGHT, or PREMIUM_RATE:NOISY_RATE under independent arrivals) or the word skip" ;;
    esac
    rung_rate="${entry%%:*}"; rung_weight="${entry##*:}"
    [ -n "$rung_rate" ] && [ -n "$rung_weight" ] || fail "LADDER entry ${entry@Q} is missing one of its two numbers"
    # Odd rungs run the control first, even rungs run the split first.
    #
    # This is the counterbalance, and it is the whole reason the ladder can say anything about the topology
    # rather than about the position: across the rungs each contended arm occupies the first and the second
    # slot of a rung equally often. The frozen matrix cannot do this -- it registered a fixed order and says
    # so -- and here it costs nothing.
    if [ $(( ladder_rung % 2 )) -eq 1 ]; then rung_order="shared timeSlicing"; else rung_order="timeSlicing shared"; fi
    for topology in $rung_order; do
      CELLS+=("$topology|$(printf 'rung%02d' "$ladder_rung")-$topology|1|$rung_rate|$rung_weight|$ladder_rung")
    done
  done
  [ "${#CELLS[@]}" -gt 0 ] || fail "LADDER is set but describes no rungs to buy -- every entry was skip, or the list is empty"
  # One more cell than the rungs describe: the isolated baseline, bought once at whichever rung the ladder
  # stops on. It is counted here so the deadline projection does not discover it at the end.
  cells_total=$(( ${#CELLS[@]} + 1 ))
else
  # STUDY was decided above, before the compiled-CR block, so that the STUDY_FROM_CR comparison could use it.
  # The unconditional assignment that used to sit on this line discarded whatever the caller asked for.
  if [ -n "$SWEEP" ]; then
    # One baseline and one cell per BE level, per repetition. The rate field carries PREMIUM_RATE and the
    # weight field the level's absolute BE rate, which set_load_flags passes as --premium-rate and
    # --noisy-rate under independent arrivals. The baseline is generated at the first level's rate and has
    # its contender filtered out; independent arrivals make its LC rows the same at any level.
    #
    # The order WITHIN each repetition is randomised, and the order of the repetitions is not. A fixed order
    # puts the same level in the same slot of every block, so a drift in the card or the engine over a
    # session would be read as an effect of the level; the 2026-10-04 registration cites setup randomisation
    # (Mytkowicz et al., ASPLOS'09) for exactly this. The permutation is the sort of sha256("<the block's
    # trace seed>/<label>"), so it is reproducible from the seeds the archive already records, differs from
    # block to block, and needs no random-number generator whose output depends on which awk is installed.
    # What it costs: the baseline is no longer bought first, so a run cut short may hold a level with no
    # denominator -- the registration chose randomisation over that.
    sweep_first=$(printf '%s\n' $SWEEP | awk 'NF {print; exit}')
    for rep in $(seq 1 "$REPS"); do
      block_seed=$(printf '%s\n' $SEEDS | sed -n "${rep}p")
      block=("R1|R1|$rep|$PREMIUM_RATE|$sweep_first|0")
      sweep_level=0
      for be in $SWEEP; do
        sweep_level=$(( sweep_level + 1 ))
        block+=("shared|$(printf 'be%02d-shared' "$sweep_level")|$rep|$PREMIUM_RATE|$be|0")
      done
      while IFS= read -r spec; do
        CELLS+=("$spec")
      done < <(for spec in "${block[@]}"; do
        label=$(printf '%s' "$spec" | cut -d'|' -f2)
        printf '%s %s\n' "$(printf '%s/%s' "${block_seed:-11}" "$label" | sha256sum | cut -c1-16)" "$spec"
      done | LC_ALL=C sort | cut -d' ' -f2-)
    done
  elif pp_is_study "$STUDY"; then
    # One block per repetition: every arm of the stage, on the single-engine topology, in an order drawn from a
    # hash of the block's seed, the stage and the block, so no arm is always first (design page, build item 7).
    # The diagnostic's stage D and v26's stage E run R1 once, first, as the isolated anchor, and their blocks hold the
    # other arms (design page, "v25" and "v26").
    if [ "$PILOT_STAGE" = D ] || [ "$PILOT_STAGE" = E ]; then
      CELLS+=("R1|R1|1|$PREMIUM_RATE|$PILOT_NOISY_RATE|0")
    fi
    for rep in $(seq 1 "$REPS"); do
      block_seed=$(printf '%s\n' $SEEDS | sed -n "${rep}p")
      while IFS= read -r spec; do
        CELLS+=("$spec")
      done < <(pp_stage_arms "$PILOT_STAGE" | { if [ "$PILOT_STAGE" = D ] || [ "$PILOT_STAGE" = E ]; then grep -vx R1; else cat; fi; } | while read -r arm; do
        printf '%s R1|%s|%s|%s|%s|0\n' "$(printf '%s/%s/%s/%s' "${block_seed:-11}" "$PILOT_STAGE" "$rep" "$arm" | sha256sum | cut -c1-16)" \
          "$arm" "$rep" "$PREMIUM_RATE" "$PILOT_NOISY_RATE"
      done | LC_ALL=C sort | cut -d' ' -f2-)
    done
  elif iv_is_study "$STUDY"; then
    # The instrument-validation study's blocks, as its registration lays them out (section 4).
    #
    # REPS blocks of the synchronous arms, each block in its own order, then every async arm once: the async
    # control is "bought once, published, and never used to fit or correct anything", so repeating it would
    # buy cells the registration has no use for.
    # The order inside a block is the sort of sha256("<block>/<label>"), the sweep's device below, so it is
    # reproducible from the archive and differs between blocks without a random-number generator.
    #
    # The topology is R1 for every arm: one engine, the whole card, one tenant.
    # The arm name rides in the label, which is what gen-trace, the engine arguments and the readings key on.
    for rep in $(seq 1 "$REPS"); do
      while IFS= read -r spec; do
        CELLS+=("$spec")
      done < <(for arm in $ARMS; do
        case "$arm" in *-async) continue ;; esac
        # The step-boundary session buys serial and staggered cells in blocks 1, 3 and 5 only, spread over the
        # session rather than front-loaded, and burst cells in all six (its registration, section 2).
        iv_arm_in_block "$STUDY" "$arm" "$rep" || continue
        # Study s4's block 1 starts with a staggered cell, which of the two still chosen by the hash.
        # The matrix stops when the remaining cells, each charged the observed overhead so far, outrun the deadline,
        # and after a cold serial first cell that projection exceeded what the credentials allow (session 4, by one
        # minute); finishing the longest cell first leaves less work to carry the 20% headroom. The other cells and
        # blocks keep their hash order, and session 5's registration records the rule before purchase.
        printf '%s R1|%s|%s|%s|%s|0\n' "$(printf '%s/%s' "$rep" "$arm" | sha256sum | cut -c1-16)" "$arm" "$rep" "$RATE" "$NOISY_WEIGHT"
      done | LC_ALL=C sort | if [ "$rep" = 1 ] && { [ "$STUDY" = "$IV_S4_STUDY" ] || [ "$STUDY" = "$IV_STEP_STUDY" ] || [ "$STUDY" = "$IV_CONFIRM_STUDY" ]; }; then
        # Only the first staggered cell in hash order is moved to the front; the other five keep their order.
        awk '!moved && $2 ~ /^R1\|stagger-/ {first = $0; moved = 1; next} {rest[++n] = $0}
             END {if (first != "") print first; for (i = 1; i <= n; i++) print rest[i]}'
      else cat; fi | cut -d' ' -f2-)
    done
    while IFS= read -r spec; do
      CELLS+=("$spec")
    done < <(for arm in $ARMS; do
      case "$arm" in *-async) ;; *) continue ;; esac
      printf '%s R1|%s|1|%s|%s|0\n' "$(printf 'async/%s' "$arm" | sha256sum | cut -c1-16)" "$arm" "$RATE" "$NOISY_WEIGHT"
    done | LC_ALL=C sort | cut -d' ' -f2-)
  else
    for rep in $(seq 1 "$REPS"); do
      for arm in $ARMS; do
        CELLS+=("$arm|$arm|$rep|$RATE|$NOISY_WEIGHT|0")
      done
    done
  fi
  cells_total=${#CELLS[@]}
fi

# THE PLAN IS PRINTED BEFORE THE CARD IS TOUCHED.
#
# It used to be built after the cluster was acquired, so the first thing an operator saw of what they were
# buying was cell 1 of N already running. Everything here reads environment variables and nothing else, so
# there is no reason for it to wait -- and a plan printed before the first billable second is a plan that can
# be refused.
say "plan: $cells_total cell(s): $(for c in "${CELLS[@]}"; do printf '%s ' "${c#*|}" | cut -d'|' -f1; done | tr '\n' ' ')"

# Only EKS needs one. A kind node loads the image from the host daemon, and demanding a registry there would
# push an operator into standing one up for a cluster that can side-load.
[ "$PLATFORM" != eks ] || [ -n "${REGISTRY:-}" ] \
  || fail "REGISTRY is unset. EKS nodes cannot side-load an image, so the gateway must be pushed where they can pull it."

mkdir -p "$OUT" || fail "cannot create $OUT"
# WHERE EACH LOAD VALUE CAME FROM, beside the values themselves.
#
# refuse_unfrozen_load compares the EFFECTIVE value against the study's frozen tuple, so a wrong default is
# caught as surely as a wrong override. What the comparison cannot tell a later reader is whether the value
# was DECLARED or inherited from this script's default -- and that distinction is what made the 2026-10-02
# run hard to audit: its user-data set all five to empty, the wrapper exports only non-empty ones, so the
# matrix received none of them and used its own defaults. The manifest recorded 1174 and nothing recorded
# that 1174 was a default rather than a declaration.
#
# The *_FROM_CALLER snapshots already answer it; they were taken before the defaults were applied and were
# only ever read by the compiled-CR guard. Written here, next to $OUT's creation, because this is the first
# line at which both the effective values and the output directory exist.
{
  printf 'study: %s\n' "${STUDY:-<unset at this point>}"
  # The sweep's whole load, because a cell's manifest carries only its own level and seed.
  [ -z "$SWEEP" ] || printf 'sweep: best-effort %s /s with latency-critical held at %s /s\n' "$SWEEP" "$PREMIUM_RATE"
  # The order the cells will be bought in, which a randomised sweep makes a fact worth recording.
  printf 'order:'; for c in "${CELLS[@]}"; do printf ' %s/%s' "$(printf '%s' "$c" | cut -d'|' -f2)" "$(printf '%s' "$c" | cut -d'|' -f3)"; done; printf '\n'
  printf 'seeds: %s\n' "${SEEDS:-11 in every repetition}"
  # Each cell's trace length, for the one study whose length differs by arm.
  # Every other study's single DURATION_MS is in its manifests and its banner, so its record is unchanged.
  if [ -z "$LADDER" ] && iv_is_study "$STUDY"; then
    printf 'duration_ms:'; for c in "${CELLS[@]}"; do
      IFS='|' read -r _ _dl _dr _ <<<"$c"
      printf ' %s/%s=%s' "$_dl" "$_dr" "$(cell_duration_ms "$_dl")"
    done; printf '\n'
  fi
  for v in PREMIUM_PROMPT_CHARS NOISY_PROMPT_CHARS REQUEST_TIMEOUT_MS \
           PREMIUM_OUTPUT_TOKENS NOISY_OUTPUT_TOKENS MODEL_REVISION; do
    snap="${v}_FROM_CALLER"
    printf '%s: %s (%s)\n' "$v" "${!v}" "$([ -n "${!snap:-}" ] && echo declared || echo "default of hack/m5c-matrix.sh")"
  done
} > "$OUT/load-source.txt"
: > "$LOG"

WORK="$(mktemp -d)"
# Removed on every exit from here until the full cleanup trap below replaces this one.
#
# That trap is armed only after the functions it calls exist, and PLAN_ONLY exits long before then, as does
# every fail in between. So each plan check left this directory behind with a 34 MB benchharness in it, in
# /tmp, which is tmpfs here -- and 18 GB of them had accumulated by 2026-09-15.
trap 'rm -rf "$WORK"' EXIT
PF_PID=""
NODEGROUP=""

# PLAN_ONLY generates every planned trace and asks whether each cell could EVER be scored, then stops.
#
# Every refusal it applies already existed, and every one of them fired on the rented card: `replay`
# validates the arm against its study after the engines are up, and the cell floors are applied by the
# readings after the replay has finished. A mistyped study, a rung the registry does not admit, or a load
# whose counts the readings would refuse therefore cost a bring-up each time -- about 25 minutes of a
# billing instance, for a question that can be answered here in seconds.
#
# It runs the REAL gen-trace and asks the REAL bench.LadderPlanRefusal, so nothing about the registered
# floors is restated in this file. What it cannot check is anything that depends on results: whether an
# engine starts, whether the card fits two of them, or what any latency will be.
if [ -n "${PLAN_ONLY:-}" ]; then
  # It used to refuse everything but a ladder, and that refusal was the gap.
  #
  # The frozen matrix's CELLS are built from ARMS x REPS and carry the same six fields a rung's do, so the
  # loop below already worked for them; only this line stopped it. Meanwhile the wrapper ran the check only
  # when LADDER was set, so a frozen run had no pre-purchase plan check at all and DRY_RUN's success -- which
  # checks the user-data and not the plan -- was the only thing that looked like one.
  if [ -n "${BENCHHARNESS_BIN:-}" ]; then
    [ -x "$BENCHHARNESS_BIN" ] || fail "BENCHHARNESS_BIN=$BENCHHARNESS_BIN is not an executable file"
    cp "$BENCHHARNESS_BIN" "$WORK/benchharness" || fail "could not take the shipped benchharness binary"
  else
    command -v go >/dev/null || fail "PLAN_ONLY needs either a Go toolchain or BENCHHARNESS_BIN"
    go build -o "$WORK/benchharness" ./cmd/benchharness || fail "build benchharness"
  fi
  resolve_arrivals
  # The same check both paths run, before either generates a trace.
  #
  # PLAN_ONLY exists so a purchase can be refused before anything is rented, and a load that does not match
  # the registration is exactly such a refusal. Running it only on the real path would mean the dry run
  # approved a plan the real run then rejected -- or worse, approved one the real run also accepted.
  refuse_unfrozen_load
  resolve_seeds
  # A reproduction's plan carries the provenance its target recorded, or the comparison could only refuse it.
  # Only then: a plan that claims nothing invokes gen-trace exactly as before, so recorded plan calls still match.
  # The image ID is not among them -- it does not exist until the build after purchase -- and the gateway's
  # content stands in for it.
  plan_provenance=()
  if [ -n "${REPRODUCES:-}" ]; then
    [ -n "${GATEWAY_BIN:-}" ] && [ -x "$GATEWAY_BIN" ] \
      || fail "REPRODUCES needs GATEWAY_BIN, the gateway binary this run will ship, so the plan can name it by content"
    plan_provenance=(--gateway-sha "$SOURCE_COMMIT" --engine-image "$ENGINE_IMAGE" --tokenizer-rev "$MODEL_REVISION"
                     --gateway-binary-sha256 "$(sha256sum "$GATEWAY_BIN" | cut -c1-64)" --gateway-base "$GW_BASE")
  fi
  plan_top=0
  for spec in "${CELLS[@]}"; do
    IFS='|' read -r _ _ _ _ _ cell_rung <<<"$spec"
    [ "$cell_rung" -le "$plan_top" ] || plan_top=$cell_rung
  done
  plan_failures=0
  # The baseline is checked too, at the rung the ladder would end on if it ran every rung. That is the
  # latest it can be bought, and the earliest this file can name it.
  #
  # ONLY the ladder has a cell its rung list does not describe. The frozen matrix buys R1 as an arm like any
  # other, so synthesising one here would check a cell called rung00-R1 -- a name the sharing study does not
  # admit -- and the whole frozen plan would be refused for a cell the run never intended to buy.
  plan_specs=("${CELLS[@]}")
  [ -z "$LADDER" ] || plan_specs+=("BASELINE")
  for spec in "${plan_specs[@]}"; do
    if [ "$spec" = BASELINE ]; then
      for s2 in "${CELLS[@]}"; do
        IFS='|' read -r _ _ _ cell_rate cell_weight cell_rung <<<"$s2"
        [ "$cell_rung" = "$plan_top" ] || continue
        cell_topology=R1; cell_label="$(printf 'rung%02d' "$plan_top")-R1"; cell_rep=1
        break
      done
    else
      IFS='|' read -r cell_topology cell_label cell_rep cell_rate cell_weight cell_rung <<<"$spec"
    fi
    # Each repetition's own seed, so a per-repetition study has every trace it will buy checked here -- the
    # floors below are per trace, and one seed passing them says nothing about another.
    plan_seed=$(seed_for_rep "${cell_rep:-1}")
    plan_name="$cell_label-${cell_rep:-1}"
    set_load_flags "$cell_rate" "$cell_weight"
    plan_duration=$(cell_duration_ms "$cell_label") || fail "$plan_duration"
    "$WORK/benchharness" gen-trace --seed "$plan_seed" --duration-ms "$plan_duration" "${LOAD_FLAGS[@]}" \
      --study "$STUDY" --arm "$cell_label" --model "$MODEL" --gateway-url "http://127.0.0.1:18080" \
      "${PROMPT_FLAGS[@]}" ${plan_provenance[@]+"${plan_provenance[@]}"} \
      --timeout-ms "$REQUEST_TIMEOUT_MS" \
      --trace-out "$WORK/plan-$plan_name.jsonl" --manifest-out "$WORK/plan-$plan_name.yaml" >/dev/null \
      || { echo "PLAN REFUSED: gen-trace could not build $cell_label's trace" >&2; plan_failures=$(( plan_failures + 1 )); continue; }
    # v26's traces are frozen by checksum: a seed, rate, duration or prompt that differs from the registration's
    # changes it, so the plan cannot buy a lighter load under the study's name (v26 review, B6 and C5).
    if [ -z "$LADDER" ] && [ "$STUDY" = "$PP_FRONTIER_STUDY" ]; then
      plan_want=$(pp_frontier_checksum "$plan_seed" "$cell_label" 2>&1) \
        || { echo "PLAN REFUSED: $plan_want" >&2; plan_failures=$(( plan_failures + 1 )); continue; }
      plan_got=$(awk '/^traceChecksum:/ {print $2}' "$WORK/plan-$plan_name.yaml")
      [ "$plan_got" = "$plan_want" ] \
        || { echo "PLAN REFUSED: $plan_name's trace has checksum ${plan_got:-none}, and v26 froze $plan_want for seed $plan_seed" >&2; plan_failures=$(( plan_failures + 1 )); continue; }
    fi
    # A pilot cell's engine manifest and gateway arguments are rendered here too, so an arm the helpers do not
    # know, or a manifest anchor that moved, refuses before anything is rented (v26 review, C8).
    if [ -z "$LADDER" ] && pp_is_study "$STUDY"; then
      plan_cap=$(pp_arm_prefill_cap "$cell_label" 2>&1) \
        && plan_render=$(pp_render_manifest config/vllm/deployment.yaml "$WORK/plan-engine-$plan_name.yaml" "$MODEL_REVISION" "$plan_cap" 2>&1) \
        && plan_gw=$(pp_gateway_args "$cell_label" "${PILOT_STATIC_RATE:-}" 2>&1) \
        || { echo "PLAN REFUSED: $plan_name's engine or gateway could not be rendered: ${plan_render:-}${plan_gw:-}${plan_cap:-}" >&2; plan_failures=$(( plan_failures + 1 )); continue; }
    fi
    # A study that warms each engine first has its warm-up trace generated here too, by the cell's own call.
    # A warm-up gen-trace refuses would otherwise first refuse on the rented card, after the engine was up.
    if [ -z "$LADDER" ] && iv_has_warmup "$STUDY"; then
      if ! plan_warm=$(warmup_span_ms "$cell_label" "${cell_rep:-1}"); then
        echo "PLAN REFUSED: $plan_warm" >&2
        plan_failures=$(( plan_failures + 1 ))
        continue
      fi
      say "  $plan_name: warm-up span ${plan_warm} ms, its last request's offset plus 30 s"
    fi
    # The two experiments ask DIFFERENT questions of the same artefact, and their floors differ.
    #
    # The ladder holds the contender at a fixed count across rungs and needs 500 premium offers; asking that
    # of a frozen cell refuses it for "varying two things at once", which it is not doing. The frozen matrix
    # varies the topology at one load and needs MinTailSamples per REPETITION, because a cell is a repetition
    # and RegisteredEstimandFor refuses an arm whose smallest repetition tail falls below that floor.
    #
    # --arms carries the whole plan on every cell, because "is the isolated baseline in this run at all" is a
    # question about the SET and no single cell's trace can answer it.
    if [ -n "$LADDER" ]; then
      plan_cmd=(ladder-plan-check --trace "$WORK/plan-$plan_name.jsonl" --study "$STUDY" --arm "$cell_label")
    else
      plan_cmd=(matrix-plan-check --trace "$WORK/plan-$plan_name.jsonl" --study "$STUDY" --arm "$cell_label" --arms "$ARMS"
                --manifest "$WORK/plan-$plan_name.yaml")
      # REPRODUCES names the archive this run claims to repeat, and is absent for a run that claims nothing.
      #
      # Appended rather than always passed, so a run making no claim invokes exactly the command it did
      # before this existed. The 2026-10-02 run was registered as a reproduction of the 2026-09-13 pilot and
      # offered a 294-token premium prompt against that pilot's 50; every check here passed it, because they
      # ask whether a cell is scorable and not whether it is the same load as a named prior run.
      [ -z "${REPRODUCES:-}" ] || plan_cmd+=(--reproduces "$REPRODUCES")
    fi
    if ! out=$("$WORK/benchharness" "${plan_cmd[@]}" 2>&1); then
      echo "PLAN REFUSED: $out" >&2
      plan_failures=$(( plan_failures + 1 ))
      continue
    fi
    say "  $out"
  done
  [ "$plan_failures" = 0 ] \
    || fail "$plan_failures planned cell(s) could not be scored as specified. Nothing was rented. Fix the load or the study and re-check -- this is the refusal that used to arrive after a bring-up"
  # The study is named in the verdict, because a reader of "PLAN OK" cannot otherwise tell which experiment
  # was planned. On 2026-10-04 this line printed a pass for a plan standing under a study the caller had not
  # asked for, and nothing in the output contradicted them.
  say "PLAN OK under study $STUDY: every planned cell generates a trace the readings can score. Nothing was rented."
  exit 0
fi

# Scaling the node group back to zero, which this file's header claimed and this function did not do.
#
# It printed a banner. A banner is not a control: it depends on a human reading a terminal that may have
# scrolled, or that no longer exists because the laptop closed. The node group keeps desiredSize=1, the ASG
# keeps a GPU node, and this matrix's g5.xlarge bills $1.237/hour with nothing scheduled on it.
#
# The names are derived rather than asked for, because a prompt in a trap is a prompt nobody answers:
# the cluster comes from the kubeconfig context's EKS ARN and the node group from the node's own
# eks.amazonaws.com/nodegroup label. If either cannot be derived the function says so and prints the manual
# command -- degrading to the old behaviour rather than failing silently.
#
# KEEP_NODE=1 skips it, for a re-run against a node that is already warm rather than paying for a fresh
# warmup. The matrix has no separate re-run script, so this matters less here than in m5b-gpu-session.sh.
#
# What this does NOT solve, stated so it is not mistaken for solved: a trap cannot run after the laptop dies,
# loses power, or has its shell killed with SIGKILL. The backstop for that is the nightly destroy workflow,
# and the deadline this script registers with EventBridge Scheduler is what covers those.
# See hack/lib/gpu-ttl.sh.
gpu_scale_down() {
  # The deadline is NOT dropped here, and the ordering is the whole point.
  #
  # Removing it first means a scale-down that then fails leaves the account with a billing GPU and no
  # remaining backstop -- the one arrangement worse than either failure alone. The schedule costs nothing
  # while it waits and does nothing once the node is already at zero, so there is no reason to trade it away
  # before the thing it protects against is known not to have happened. It comes off at the bottom of this
  # function, after desiredSize has been read back as 0, and nowhere else.
  #
  # KEEP_NODE=1 keeps the node up; the deadline stays armed, so a session someone walks away from still ends.
  if [ "${KEEP_NODE:-}" = "1" ]; then
    echo "KEEP_NODE=1: leaving $NODEGROUP up. The TTL deadline stays armed; it bills until then." >&2
    return 0
  fi

  CLUSTER="${CLUSTER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's|.*cluster/||')}"

  # Ask EKS what is billing rather than trusting a flag set after the preflight checks. The same reasoning is
  # written out in m5b-gpu-session.sh: the refusals that run before the node group is identified used to exit
  # through a cleanup that believed nothing had been started.
  if [ -z "$NODEGROUP" ] && [ -n "$CLUSTER" ]; then
    for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" \
                  --query 'nodegroups[?starts_with(@, `gpu`)]' --output text 2>/dev/null); do
      size=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
               --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null)
      if [ -n "$size" ] && [ "$size" != "0" ] && [ "$size" != "None" ]; then
        echo "found $CLUSTER/$ng at desiredSize=$size without this session having recorded it" >&2
        # No break. The same fix went into hack/m5b-gpu-session.sh and this file was left with the old
        # shape, so a claim that "every stray group is scaled down" was true of one script and not the
        # other. Taking the first and stopping leaves the rest billing, in the function whose only job is
        # to find what is billing and stop it.
        if [ -z "$NODEGROUP" ]; then
          NODEGROUP="$ng"
        else
          aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
            --scaling-config minSize=0,maxSize=1,desiredSize=0 >/dev/null 2>&1 \
            && echo "also scaled $CLUSTER/$ng to zero" >&2 \
            || echo "WARNING: could not scale $CLUSTER/$ng down. IT IS STILL BILLING." >&2
        fi
      fi
    done
  fi

  if [ -z "$CLUSTER" ] || [ -z "${NODEGROUP:-}" ]; then
    echo
    echo "############################################################"
    echo "#  COULD NOT DERIVE cluster/nodegroup. SCALE TO 0 BY HAND. #"
    echo "#  It bills by the hour with nothing scheduled on it.      #"
    echo "#    aws eks update-nodegroup-config \\"
    echo "#      --cluster-name <cluster> --nodegroup-name <ng> \\"
    echo "#      --scaling-config minSize=0,maxSize=1,desiredSize=0  #"
    echo "############################################################"
    return 0
  fi

  echo "scaling $CLUSTER/$NODEGROUP to desiredSize=0" >&2
  # stderr is kept, so a failed scale-down says why rather than only that.
  if ! aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
        --scaling-config "minSize=0,maxSize=1,desiredSize=0" >/dev/null; then
    echo
    echo "############################################################"
    echo "#  SCALE-DOWN CALL FAILED. THE NODE IS STILL BILLING.      #"
    echo "#  Run this now:                                           #"
    echo "#    aws eks update-nodegroup-config --cluster-name $CLUSTER \\"
    echo "#      --nodegroup-name $NODEGROUP \\"
    echo "#      --scaling-config minSize=0,maxSize=1,desiredSize=0  #"
    echo "############################################################"
    return 0
  fi

  # Confirm it took. An accepted API call that left desiredSize at 1 is the failure this whole function
  # exists to make impossible, and it is silent unless something reads the value back.
  DESIRED=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null)
  if [ "$DESIRED" = "0" ]; then
    echo "$CLUSTER/$NODEGROUP is at desiredSize=0" >&2
    # Only now. The deadline has nothing left to protect, and this is the single place that knows that.
    command -v ttl_disarm >/dev/null 2>&1 && ttl_disarm
  else
    echo "WARNING: $CLUSTER/$NODEGROUP reports desiredSize=$DESIRED after the scale-down. It is billing." >&2
    echo "The TTL deadline is left armed on purpose. It is what remains." >&2
  fi
}

# The expected-versus-actual comparison, written from cleanup so that a run which DIED still carries it.
#
# It lived at the end of the script, after README.txt. That is the one path where the comparison is least
# interesting: a run that reaches the end has the files it owed. The runs worth comparing are the ones that
# stopped at a deadline boundary or hit `fail` -- money already spent, archive short -- and those exit
# through cleanup and never reached the old location. An external review named it, and the comment above the
# old block had already claimed the opposite ("a run that ends holding fewer files than it owed ... must not
# go unremarked"), so the code contradicted its own stated reason for existing.
#
# Recorded, never enforced. Failing here would stop the archive coming home, and the archive is the only
# record of what the money bought.
record_expected_files() {
  local pair actual self classes mismatched
  [ -d "$OUT" ] || return 0
  # cleanup is trapped at line 787 and expected_outputs is defined around 1746, with forty `fail` calls in
  # between. A run that dies acquiring the card or building an image therefore reaches this function before
  # the one it calls exists, and `command not found` would leave a file whose basis field was simply empty.
  # Said as a word instead, because "the count could not be computed" and "the count is zero" are the
  # distinction this whole file is about.
  if ! declare -F expected_outputs >/dev/null 2>&1; then
    {
      printf 'expected\tnot-computed\n'
      printf 'basis\tdied-before-expected_outputs-was-defined\n'
      printf 'actual\t%s\n' "$(find "$OUT" -maxdepth 1 -type f 2>/dev/null | wc -l)"
      printf 'agree\tnot-evaluable -- this run ended before the counting function existed, so there is no expectation to compare against\n'
    } > "$OUT/expected-files.txt"
    return 0
  fi
  pair=$(expected_outputs)
  # Counted BEFORE this file is written, and expected_outputs counts it as present, because by the time
  # anyone reads the archive it is there. Off-by-one in the other direction otherwise.
  #
  # `self` is 0 when a previous run already left the file in this directory -- hack/test/rehearse-m5c-matrix.sh
  # passes one OUT_DIR to three invocations and never empties it, so the unconditional +1 counted the file
  # twice from the second run on and could cancel out a genuinely missing file into `agree=yes`.
  self=1
  [ -f "$OUT/expected-files.txt" ] && self=0
  actual=$(( $(find "$OUT" -maxdepth 1 -type f 2>/dev/null | wc -l) + self ))
  # Per-class rows beside the total, and the verdict is theirs rather than the total's.
  #
  # The total agreeing means only that the errors summed to zero. Three rounds of review found three
  # different pairs that did exactly that, so `agree` is now yes only when EVERY class matches, and the
  # classes that did not are named in the line.
  # Its absence makes the verdict NOT-EVALUABLE, never yes.
  #
  # cleanup is trapped before either counting function is defined, so a signal arriving between the two
  # definitions leaves only the total. Writing `class none` beside `agree yes` then claimed a per-class
  # comparison that never ran -- the guard protected the total and left the verdict unguarded.
  classes=""
  mismatched=""
  if declare -F expected_outputs_by_class >/dev/null 2>&1; then
    classes=$(expected_outputs_by_class)
    mismatched=$(printf '%s\n' "$classes" | awk 'NF == 3 && $2 != $3 {printf "%s(%s!=%s) ", $1, $2, $3}')
  else
    mismatched="class-comparison-did-not-run"
  fi
  {
    printf 'expected\t%s\n' "${pair%% *}"
    printf 'basis\t%s\n' "${pair#* }"
    printf 'actual\t%s\n' "$actual"
    if [ -n "$classes" ]; then
      printf '%s\n' "$classes" | while read -r cname cexp cact; do
        printf 'class\t%s\texpected %s\tactual %s\n' "$cname" "$cexp" "$cact"
      done
    else
      printf 'class\tnone\texpected -\tactual -\n'
    fi
    case "${pair%% *}" in
      [0-9]*)
        if [ -n "$mismatched" ]; then
          printf 'agree\tno -- these classes disagree: %s\n' "$mismatched"
        elif [ "${pair%% *}" = "$actual" ]; then
          printf 'agree\tyes\n'
        else
          printf 'agree\tno -- the archive holds %s of the %s files this run owed it, with every class matching, so the totals disagree for a reason no class names\n' "$actual" "${pair%% *}"
        fi
        ;;
      *) printf 'agree\tnot-evaluable -- no expected count was produced, so this is not a comparison\n' ;;
    esac
  } > "$OUT/expected-files.txt"
  echo "expected-files.txt: expected=${pair%% *} actual=$actual basis=${pair#* } mismatched=${mismatched:-none}" >&2
}

# A signal must also END the script, and these traps did not.
#
# `trap cleanup INT` runs cleanup and then RESUMES where the signal arrived. During the ten-minute wait for
# a node to join, Ctrl-C therefore scaled the node group to zero, dropped the deadline, and went back to
# waiting for the node it had just cancelled -- for another ten minutes, on a card the operator had just
# asked to stop. The cost was cleaned up; the session was not.
#
# EXIT still runs cleanup for ordinary exits and for `fail`. The signal handlers do their own cleanup and
# exit with the conventional 128+signal status, and the guard makes the second call a no-op so the EXIT
# trap that follows does not repeat the work.
CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  record_expected_files
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  k delete namespace "$NS_A" "$NS_B" --wait=false >/dev/null 2>&1
  k delete gpuquotapolicy m5c-premium m5c-standard >/dev/null 2>&1
  k delete clusterrolebinding m5c-gateway-role >/dev/null 2>&1
  rm -rf "$WORK"
  release_card
}

# What stops the card billing, which is the one thing the two platforms cannot share.
#
# Under eks this is gpu_scale_down above, unchanged.
#
# Under kind the card IS the rented instance and this script does not own it: hack/m5c-gpu-session.sh rents
# it, arms a shutdown backstop inside it, and terminates it from outside. There is no node group to scale,
# and printing the COULD NOT DERIVE banner for a cluster that was never meant to have one would teach an
# operator to read past the banner on the day it means something. So it says plainly what it is not doing
# and which thing is.
release_card() {
  case "$PLATFORM" in
    eks) gpu_scale_down ;;
    kind)
      echo "the card is the rented instance, so nothing is scaled down here: hack/m5c-gpu-session.sh terminates it, and the instance's own shutdown backstop covers a shell that dies in this script" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

say "preflight"

# The EKS card: scale a managed node group up, and register the deadline before it exists.
#
# Every line of this function is the code that was here before, moved and indented and otherwise
# untouched. `git diff -w` on the commit that introduced it shows only the wrapper, which is the point:
# the cluster half of the AWS path has never been applied, so nothing here can be exercised, and a
# path nobody can run is a path nobody can prove a refactor kept working.
acquire_card_eks() {
  case "$KCTX" in kind-*) fail "context $KCTX is a kind cluster; this is the paid matrix" ;; esac

  # The sharing node, and it must be the sharing one: the exclusive plugin advertises one device per card, so
  # the second engine would sit Pending and the arm would silently become a one-engine arm with half the memory.
  # The deadline is registered BEFORE the card exists, which is why this script scales the group up itself.
  #
  # It used to refuse when no sharing node was present, print the aws command, and wait to be re-run -- so a
  # person scaled up, the node billed and took minutes to join, and only a re-run registered a deadline. This
  # is the longest run in the repository and therefore the one most likely to outlive the shell that started
  # it; starting it with an unbacked card was the wrong end to be careless at.
  #
  # The name cannot come off a node label before a node exists, so it comes from a default verified against
  # EKS. A name that does not resolve would produce a schedule that is accepted and then fires into nothing.
  CLUSTER="${CLUSTER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's|.*cluster/||')}"
  [ -n "$CLUSTER" ] || fail "could not determine the cluster name from the kubeconfig context"
  # Named into a candidate first, and promoted to NODEGROUP only once EKS confirms it exists.
  #
  # Assigning NODEGROUP before the check meant that when the check refused, the EXIT trap's scale-down saw a
  # node group name, skipped discovery, and called update-nodegroup-config against a group just proven not to
  # exist -- then printed THE NODE IS STILL BILLING for a session that had started nothing. A commit claimed
  # no refusal path calls update-nodegroup-config; this was the path that did.
  NG_CANDIDATE="${NODEGROUP:-gpu_shared}"
  aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_CANDIDATE" >/dev/null 2>&1 \
    || fail "no node group $NG_CANDIDATE in $CLUSTER. The deadline must name a group that exists, or it fires into nothing. Set NODEGROUP if the name is different."
  NODEGROUP="$NG_CANDIDATE"

  # One schedule names one node group, so a second GPU group left running is not covered by anything this
  # session registers. The deadline would fire, scale down the group it names, and leave the other billing --
  # and nothing in the run would look wrong.
  #
  # Refusing here rather than trying to cover both is deliberate. A session that finds another card already
  # running does not know whose it is: it may be another session mid-run, and scaling it down would destroy
  # someone else's paid work. Naming it and stopping is the only answer that is right in both cases.
  # Every AWS call here is checked, because the previous shape failed OPEN. It ran the listing inside a
  # command substitution, threw away stderr and the exit status, and iterated the result -- so expired
  # credentials, a permissions error, or a network failure all produced an empty list, which reads exactly
  # like "no other card is running". The same held one level down: a describe that failed left sz empty,
  # which the case treated as zero.
  #
  # That is the wrong direction for this particular guard. It exists for the moments when something is wrong
  # with the account, and those are the moments an unchecked call returns nothing.
  if ! ng_list=$(aws eks list-nodegroups --cluster-name "$CLUSTER" \
                   --query 'nodegroups[?starts_with(@, `gpu`)]' --output text 2>&1); then
    fail "could not list the node groups in $CLUSTER, so this session cannot tell whether another card is already running: $ng_list"
  fi
  others=""
  for ng in $ng_list; do
    [ "$ng" = "$NODEGROUP" ] && continue
    if ! sz=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
                --query 'nodegroup.scalingConfig.desiredSize' --output text 2>&1); then
      fail "could not read the size of $CLUSTER/$ng: $sz. An unreadable node group is not a stopped one."
    fi
    case "$sz" in
      0|None) ;;
      ''|*[!0-9]*) fail "the size of $CLUSTER/$ng came back as ${sz@Q}, which is not a number. Refusing rather than reading it as zero." ;;
      *) others="$others $ng($sz)" ;;
    esac
  done
  [ -z "$others" ] || fail "another GPU node group is already running:$others. This session's deadline names only $NODEGROUP, so that card would keep billing after the deadline fires. Scale it to zero, or if another session owns it, wait for it."

  TTL_ROLE_ARN="${TTL_ROLE_ARN:-$(terraform -chdir=infra/aws/bootstrap output -raw ttl_scaledown_role_arn 2>/dev/null)}"
  export TTL_ROLE_ARN
  # shellcheck source=hack/lib/gpu-ttl.sh
  . "$(dirname "$0")/lib/gpu-ttl.sh"
  if true; then
    ttl_arm "$CLUSTER" "$NODEGROUP" "${TTL_MINUTES:-240}" \
      || fail "could not register the TTL scale-down; refusing to start a card with no deadline"

    # What is checked here, and what is not.
    #
    # The first shape of this check multiplied the per-cell TIMEOUT budget by the cell count and refused if
    # the product exceeded the deadline. At the shipped defaults that is 456 minutes against 240, so the
    # design's own repetition count -- four, which a unit test pins because below it the incremental interval
    # is a bootstrap over very few blocks -- could never start. Lowering REPS to make the arithmetic work was
    # the wrong repair: it traded a statistical property for a scheduling one, quietly.
    #
    # Those 1800 seconds are two rollout TIMEOUTS, not two expected rollouts. A budget is what the script
    # waits before giving up, and refusing a run because the worst case does not fit refuses most runs that
    # would have finished. So the pessimistic product is gone and only the floor stays here: a deadline that
    # cannot hold even one cell is a session with nothing to gain. The real bound is measured per cell, in
    # the loop, where a slow matrix stops on a cell boundary with everything before it intact.
    ttl_min="${TTL_MINUTES:-240}"
    cell_floor_min=$(( (1800 + 180 + ${REPLAY_SECONDS:-300} + 59) / 60 ))
    if [ "$ttl_min" -lt "$cell_floor_min" ]; then
      ttl_disarm
      fail "the deadline is ${ttl_min} min but one cell can take up to ${cell_floor_min} min, so this session could not finish even a single cell. Raise TTL_MINUTES."
    fi
  fi

  # The card starts here, after the deadline exists.
  shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
  if [ "$shared_nodes" -eq 0 ]; then
    say "no sharing node present; scaling $NODEGROUP to 1 -- the card starts billing here, and the deadline is already registered"
    aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
      --scaling-config minSize=0,maxSize=1,desiredSize=1 >/dev/null || fail "could not scale $NODEGROUP up"
    say "wait for the node to join (this takes a few minutes)"
    for i in $(seq 1 60); do
      shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
      [ "$shared_nodes" -gt 0 ] && break
      [ "$i" = 60 ] && fail "the node never joined after ten minutes. The deadline will scale it down; to do it now: aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --scaling-config minSize=0,maxSize=1,desiredSize=0"
      sleep 10
    done
  fi

  # Cross-check, not re-derive: a node from a different group means the deadline would scale down a group this
  # matrix is not using while the one it is using bills on.
  node_ng=$(k get node -l 'platform.lkhun9311.github.io/gpu-sharing=true' \
    -o jsonpath='{.items[0].metadata.labels.eks\.amazonaws\.com/nodegroup}' 2>/dev/null)
  if [ -n "$node_ng" ] && [ "$node_ng" != "$NODEGROUP" ]; then
    fail "the deadline names $NODEGROUP but the sharing node belongs to $node_ng. Re-run with NODEGROUP=$node_ng."
  fi

  [ "$shared_nodes" -eq 1 ] || fail "$shared_nodes sharing nodes are up; two engines on two nodes are not sharing a card, and nothing downstream could tell that apart from a sharing result"
}

# The kind card: one rented Spot instance that IS the node, with a kind cluster on it.
#
# hack/m5c-gpu-session.sh rents it, installs the driver and the container toolkit, builds the cluster and
# runs this script inside it. Nothing here scales anything, because there is nothing to scale: the card
# arrived with the instance and leaves with it.
acquire_card_kind() {
  case "$KCTX" in
    kind-*) ;;
    *) fail "PLATFORM=kind but the context is ${KCTX@Q}. This path labels nodes and expects to own the cluster it is pointed at, and finding out afterwards that it was a real one is not a way to learn it." ;;
  esac

  # The node whose card this is. kind's control plane carries its own NoSchedule taint and the session
  # script deliberately leaves the worker untainted, so the worker is where every engine runs.
  GPU_NODE="${GPU_NODE:-$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"
  [ -n "$GPU_NODE" ] || fail "no non-control-plane node in $KCTX; hack/m5c-gpu-session.sh builds a cluster with one worker and the engines have nowhere else to run"

  # Nobody applies this label on kind, and the failure it causes is silent and expensive.
  #
  # Under EKS it comes off the node group (infra/aws/cluster/eks.tf). Here the cluster was built minutes ago
  # by the session script and the label is this script's to set. Without it every device-plugin overlay sits
  # Pending, the node advertises nothing, and the first arm fails at its 900-second rollout timeout having
  # billed for the card throughout. hack/queuelab-gpu-session.sh learned exactly this about the exclusive
  # plugin's own label and says so at the line that applies it.
  k label node "$GPU_NODE" platform.lkhun9311.github.io/gpu-sharing=true --overwrite >/dev/null \
    || fail "could not label $GPU_NODE; without platform.lkhun9311.github.io/gpu-sharing=true no device plugin will schedule and the node will advertise nothing"

  shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
  [ "$shared_nodes" -eq 1 ] || fail "$shared_nodes nodes carry the sharing label; two engines on two nodes are not sharing a card, and nothing downstream could tell that apart from a sharing result"
  say "card node $GPU_NODE labelled for sharing"

  # The deadline is the INSTANCE's, and this script only reads it.
  #
  # Under EKS the backstop is an EventBridge schedule this script registers, because the thing that bills is
  # a node group that outlives the shell. Here the thing that bills is the instance, the session script arms
  # its shutdown before handing over, and a second deadline registered here would be a second opinion about
  # when the money stops. So this refuses to run without being told when that is, rather than defaulting to
  # a number and reporting cell budgets against a deadline nobody set.
  [ -n "${DEADLINE_EPOCH:-}" ] || fail "DEADLINE_EPOCH is unset. hack/m5c-gpu-session.sh sets it to the instance's shutdown time; without it the per-cell budget check has no deadline to measure against and would let the matrix be cut mid-cell."
}

# Minutes left before the card stops, however this platform knows that.
#
# Both branches print nothing and return non-zero when they cannot tell, because cell_deadline_check treats
# an unreadable deadline as "carry on" -- a budget check that refused on a transient API error would end a
# paid run for no reason.
deadline_remaining_minutes() {
  case "$PLATFORM" in
    eks) ttl_remaining_minutes "$CLUSTER" "$NODEGROUP" ;;
    kind)
      local now
      now=$(date +%s)
      [ -n "${DEADLINE_EPOCH:-}" ] || return 1
      echo $(( (DEADLINE_EPOCH - now) / 60 ))
      ;;
  esac
}

# The card, from whichever platform this session is on. Everything below is the experiment and is one copy.
say "acquiring the card on $PLATFORM"
case "$PLATFORM" in
  eks)  acquire_card_eks ;;
  kind) acquire_card_kind ;;
esac

# The gateway's ClusterRole has to already exist, and this is checked because the failure is silent.
#
# Below, this script runs `kubectl create clusterrolebinding --clusterrole=gateway-role`. Kubernetes accepts
# a binding to a ClusterRole that does not exist -- it is a forward reference, not an error -- so the binding
# is created, the gateway starts, and every request then fails authorization when it tries to list the
# policies it routes from. Nothing before the first replay would look wrong.
#
# It is not applied here because it is not this run's to own: config/gateway/rbac.yaml is deployed with the
# gateway, by GitOps on EKS and by hack/m5c-gpu-session.sh on kind. Naming the file in the refusal is what
# turns this from a puzzle into a command.
k get clusterrole gateway-role >/dev/null 2>&1 \
  || fail "no ClusterRole gateway-role in this cluster. The gateway would start and then fail to list the GPUQuotaPolicy and InferenceDeployment it routes from, on every request, with nothing before the first replay looking wrong. Apply it: kubectl apply -f config/gateway/rbac.yaml"


# Every overlay here selects the SAME node, so exactly one may be applied at a time: two plugins registering
# nvidia.com/gpu against one kubelet socket is not a configuration worth debugging on a rented card.
# Deleting the others first is the mechanism; remembering is not.
#
# THREE modes, not two, and the third is why the `shared` arm could never have run.
#
# `shared` needs ONE device advertised on the sharing node, and nothing advertised one. The exclusive plugin
# selects a label the sharing node group deliberately does not carry, and the two sharing overlays advertise
# two. So the control arm's engine would have sat Pending to its 900-second timeout on a fresh node -- or,
# worse, scheduled onto a leftover replica from the previous arm and produced numbers for a control running
# on half a card. config/nvidia-device-plugin-whole-card is the plugin that was missing.
PLUGIN_NS="${PLUGIN_NS:-gpu-platform-control-plane-system}"
# plugin_diagnosis prints what the device plugin and the node actually reported.
#
# A refusal that names no evidence sends the next reader back to the card to find out what happened, and the
# card is gone. The seventh pilot refused an arm on a device count and recorded nothing about the DaemonSet,
# the Pods, the events or the node's own allocatable -- so "0 devices" was all anyone would ever know.
plugin_diagnosis() {
  local ds="$1"
  say "--- $PLUGIN_NS/$ds: what the plugin and the node report ---"
  k get ds "$ds" -n "$PLUGIN_NS" -o wide 2>&1 | sed 's/^/  /' | tee -a "$LOG" >&2
  k get pods -n "$PLUGIN_NS" -o wide 2>&1 | sed 's/^/  /' | tee -a "$LOG" >&2
  k logs -n "$PLUGIN_NS" "ds/$ds" --tail=40 2>&1 | sed 's/^/  /' | tee -a "$LOG" >&2
  # The PREVIOUS container's log, because the pod this diagnosis runs against is usually in CrashLoopBackOff.
  #
  # Measured on the eighth pilot's archive: the plugin was 0/1 with 6 restarts, and the log captured here was
  # the CURRENT attempt -- which had not yet reached the failure. The line that actually named the cause
  # ("using MPS requires --mps-root to be specified") lived in a terminated container nothing read. The engine
  # diagnosis below already does this; the plugin diagnosis did not, and the plugin is the one that crashes.
  k logs -n "$PLUGIN_NS" "ds/$ds" --tail=40 --previous 2>/dev/null \
    | sed 's/^/  [previous] /' | tee -a "$LOG" >&2
  k get events -n "$PLUGIN_NS" --sort-by=.lastTimestamp 2>&1 | tail -20 | sed 's/^/  /' | tee -a "$LOG" >&2
  k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' \
    -o jsonpath='{range .items[*]}  node {.metadata.name} allocatable nvidia.com/gpu={.status.allocatable.nvidia\.com/gpu} capacity={.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>&1 \
    | tee -a "$LOG" >&2
}

apply_device_plugin() {
  # label is the arm name a refusal is recorded under, which in ladder mode names the rung as well as the
  # topology. mode stays the topology, because it is what selects the overlay.
  local mode="$1" label="${2:-$1}" keep ds want other
  case "$mode" in
    shared)      keep=config/nvidia-device-plugin-whole-card;  ds=nvidia-device-plugin-whole-card;  want=1 ;;
    timeSlicing) keep=config/nvidia-device-plugin-timeslicing; ds=nvidia-device-plugin-timeslicing; want=2 ;;
    mps)         keep=config/nvidia-device-plugin-mps;         ds=nvidia-device-plugin-mps;         want=2 ;;
    *) fail "apply_device_plugin: unknown mode $mode" ;;
  esac
  for other in config/nvidia-device-plugin-whole-card config/nvidia-device-plugin-timeslicing config/nvidia-device-plugin-mps; do
    [ "$other" = "$keep" ] && continue
    k delete -k "$other" --ignore-not-found --wait=true >/dev/null 2>&1
  done
  # A split arm's setup failure is a REFUSAL OF THAT ARM. The control's is still fatal.
  #
  # `fail` calls exit, so every path below used to end the session -- and the caller's
  # `apply_device_plugin "$arm" || return 1` at the split-arm site was unreachable code. The seventh pilot
  # died on the device-count check with R1, shared and timeSlicing already measured and paid for: the
  # session stopped before it could run its own report, and the mps arm left no refusal for reading 4c to
  # read. R1 and `shared` keep `fail` because they are the baseline and the control, and nothing below them
  # can be scored without both.
  plugin_gone() {
    if [ "$mode" = shared ]; then fail "$1"; fi
    arm_refused "$label" "$1"
    return 1
  }

  k apply -k "$keep" >/dev/null || { plugin_gone "the $mode plugin could not be applied"; return 1; }

  # The KEPT plugin has to be running before its advertisement is believed, and this is not belt-and-braces.
  #
  # Time-slicing and MPS both advertise two, so a count check alone is satisfied by the outgoing arm's stale
  # advertisement: switching timeSlicing -> mps would have passed on the devices the time-slicing plugin was
  # still registering, and the MPS arm would have begun as time-slicing under another name. Waiting for THIS
  # DaemonSet is what tells the two apart, and the count check below then confirms what it registered.
  k rollout status "ds/$ds" -n "$PLUGIN_NS" --timeout=180s >/dev/null \
    || { plugin_diagnosis "$ds"; plugin_gone "the $mode device plugin never became ready in $PLUGIN_NS; whatever the node is advertising belongs to the previous arm"; return 1; }

  say "wait for the card to advertise exactly $want device(s) under $mode"
  for i in $(seq 1 60); do
    adv=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' \
      -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
    # Exactly, not at least. `-ge` reads the previous arm's larger number as success, which is how a
    # one-device arm would have started on a card the last arm had already split in two.
    [ "${adv:-0}" -eq "$want" ] 2>/dev/null && break
    # The COUNT is the evidence; the cause is not. This line used to assert "the plugin is ignoring
    # CONFIG_FILE", which a device count cannot establish -- zero devices is equally consistent with an
    # unhealthy device, a kubelet that has not re-registered, and a driver that went away. Naming a cause the
    # ledger does not support is the thing this repository puts above every other failure, and the seventh
    # pilot printed exactly that sentence about a card whose state it had not looked at.
    if [ "$i" = 60 ]; then
      plugin_diagnosis "$ds"
      plugin_gone "the node advertises ${adv:-0} device(s) after applying a $mode config that asks for $want, so this arm would run a topology other than the one it is labelled with. The diagnosis above says what the plugin and the node reported; this line does not claim to know why."
      return 1
    fi
    sleep 10
  done
  say "node advertises $adv device(s) for one physical card under $mode"

  # MPS has a second failure that time-slicing does not: the control daemon can be absent or unreachable
  # while the plugin still advertises, and every client then silently runs WITHOUT MPS. An arm that fell
  # back that way is the time-slicing arm under another name, and nothing downstream could tell.
  if [ "$mode" = mps ]; then
    # RECORDED and refused, not fatal. This is the same registered outcome as a client that never connected
    # -- reading 4c, "INVALID for that arm" -- and ending the session here would discard the arms beside it
    # and leave no evidence the report could read the refusal from.
    if ! k rollout status ds/nvidia-mps-control-daemon -n "$PLUGIN_NS" --timeout=180s >/dev/null; then
      arm_refused mps "the MPS control daemon never became ready, so clients would fall back to running without MPS and this arm would be time-slicing under another name"
      return 1
    fi
  fi
}

# Built here, or shipped in. The GPU AMI carries a driver, not a toolchain.
#
# `go build` on the instance fails with `go: command not found`, and it fails AFTER the driver, the cluster
# and the device plugin have all been paid for -- which is precisely the loss hack/queuelab-gpu-session.sh
# describes and answers by building on the laptop and shipping the binary. This is the same answer, and
# building stays the default so a run driven from a development machine needs nothing extra.
say "the gateway and the harness"
if [ -n "${GATEWAY_BIN:-}" ]; then
  [ -x "$GATEWAY_BIN" ] || fail "GATEWAY_BIN=$GATEWAY_BIN is not an executable file"
  cp "$GATEWAY_BIN" "$WORK/gateway" || fail "could not take the shipped gateway binary"
  say "  gateway: shipped, $(sha256sum "$WORK/gateway" | cut -c1-12)"
else
  command -v go >/dev/null || fail "no Go toolchain and GATEWAY_BIN is unset. On a rented GPU instance there is no compiler: build the binaries on the machine that has one and pass GATEWAY_BIN and BENCHHARNESS_BIN."
  CGO_ENABLED=0 GOOS=linux go build -o "$WORK/gateway" ./cmd/gateway || fail "build gateway"
fi
# The gateway by content, for the manifests: the image built below gets a new ID on every build of this binary.
GW_BINARY_SHA=$(sha256sum "$WORK/gateway" | cut -c1-64) || fail "hash the gateway binary"
if [ -n "${BENCHHARNESS_BIN:-}" ]; then
  [ -x "$BENCHHARNESS_BIN" ] || fail "BENCHHARNESS_BIN=$BENCHHARNESS_BIN is not an executable file"
  cp "$BENCHHARNESS_BIN" "$WORK/benchharness" || fail "could not take the shipped benchharness binary"
  say "  benchharness: shipped, $(sha256sum "$WORK/benchharness" | cut -c1-12)"
else
  go build -o "$WORK/benchharness" ./cmd/benchharness || fail "build benchharness"
fi
resolve_arrivals
# Before the first billable action, which is the docker build below.
#
# The binaries are ready on the line above and nothing has been created yet, so a mismatched load costs
# nothing to refuse here. Placing it after the image build would make the refusal true and late.
# The seeds are resolved first so the frozen-load refusal stays the line immediately ahead of the build.
resolve_seeds
refuse_unfrozen_load
printf 'FROM %s\nCOPY gateway /gateway\nUSER 65532:65532\nENTRYPOINT ["/gateway"]\n' "$GW_BASE" > "$WORK/Dockerfile"
# The image ID is CAPTURED, because it is the only thing that names this one build in the record.
# It does not name the gateway across builds -- that is the binary hash above and the pinned base.
#
# `docker build -q` prints sha256:<64 hex> -- the digest of the image's own config, which covers its layers
# and therefore the base it was built on as well as the binary copied into it. It went to /dev/null, and the
# paid manifests consequently named no gateway at all.
#
# What it is NOT is a registry digest. Nobody can pull this reference; it identifies the image that ran on
# the machine that ran it. That is the strongest true statement available here, because this image is built
# on the instance and pushed nowhere, and a reference that looked pullable would be worse than one that does
# not pretend to be.
GW_IMAGE_ID=$(docker build -q -t "$GW_IMAGE" "$WORK") || fail "build gateway image"
case "$GW_IMAGE_ID" in
  sha256:????????????????????????????????????????????????????????????????) ;;
  *) fail "docker build returned ${GW_IMAGE_ID@Q} where an image ID was expected, so this run could not name the gateway build that produced its numbers" ;;
esac
GATEWAY_IMAGE_REF="$GW_IMAGE@$GW_IMAGE_ID"
say "  gateway image $GW_IMAGE_ID"

# How the node gets the image, which is the second thing the two platforms cannot share.
#
# EKS nodes pull, so the image has to exist somewhere they can reach. A kind node is a container on the same
# daemon that just built it, so `kind load` hands it over directly -- and the Deployment must then NOT say
# `imagePullPolicy: Always`, or the kubelet would go looking for a registry that was never involved. The tag
# is unqualified on purpose for the same reason: a `docker.io/` prefix would send it to a real registry.
case "$PLATFORM" in
  eks)
    say "push the gateway to $REGISTRY"
    docker tag "$GW_IMAGE" "$REGISTRY/$GW_IMAGE" && docker push "$REGISTRY/$GW_IMAGE" >/dev/null || fail "push gateway image"
    GW_IMAGE="$REGISTRY/$GW_IMAGE"
    ;;
  kind)
    say "load the gateway into the kind cluster"
    kind load docker-image "$GW_IMAGE" --name "${KCTX#kind-}" >/dev/null \
      || fail "could not load $GW_IMAGE into kind cluster ${KCTX#kind-}; the node cannot pull it from anywhere else"
    ;;
esac

# One routing record per engine namespace, replicas 0 and a no-op image for the reason
# hack/m5b-gpu-session.sh gives: InferenceDeploymentSpec has no args and no volumes, so it cannot describe a
# vLLM container. The engine Deployment must exist FIRST or the operator takes the name.
routing_record() {
  local ns="$1" name="$2"
  k apply -f - >/dev/null <<EOF || fail "routing record in $ns"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: $name, namespace: $ns}
spec:
  model: {name: $MODEL, storageUri: "hf://$MODEL"}
  image: registry.k8s.io/pause:3.9
  gpuCount: 0
  replicas: 0
  port: 8000
EOF
}

# What an engine that never became ready was actually doing, captured before the refusal.
#
# `MATRIX FAILED: engine b never became ready` is what the first paid run of this matrix printed, and the
# whole log said nothing else about it. Whether the Pod was Pending for want of a device, CrashLooping on a
# CUDA error, still pulling fifteen gigabytes of image, or killed for memory are four different faults with
# four different fixes, and telling them apart cost a card.
#
# It goes to stdout so it lands in the run log the instance uploads, which is the only thing that outlives
# the machine. Everything here is best-effort: this function runs on the failure path, so a kubectl that
# also fails must not replace the diagnosis with its own error.
# What the engine ACTUALLY allocated, asked of the engine rather than computed.
#
# internal/bench/sharing.go sizes this run and says of its own arithmetic: "ESTIMATED, and the only
# estimated input here. vLLM prints the block count it actually allocated; compare KVTokensPerEngine against
# it at session start rather than trusting this." Nothing was doing the comparing.
#
# It matters most for the split arms and it is cheap everywhere, so it runs for every engine. Two engines at
# --gpu-memory-utilization=0.475 claim 21,877 of an A10G's 23,028 MiB and leave 1,151 for two CUDA contexts
# and the driver's reserve, which is the leading hypothesis for the engine b that would not start on
# 2026-09-11 -- and a hypothesis is all it is, because that run captured nothing that could settle it. These
# lines are what settle it next time, whether the arm succeeds or fails.
# Whether the ENGINES are actually MPS clients, which the daemon being ready does not establish.
#
# config/nvidia-device-plugin-mps/daemonset.yaml says the failure in its own words: "the control daemon can
# be absent or unreachable while the plugin still advertises, and every client then silently runs WITHOUT
# MPS", and "the control daemon and every client must share one IPC namespace, or the clients cannot reach
# the daemon's pipe". The only thing this runner checked was that the daemon had rolled out. That is the
# server side of a two-sided arrangement.
#
# It matters more than it looks. An mps arm whose clients never connected IS the timeSlicing arm, so the
# matrix would compare two mechanisms and have measured one of them twice -- and every number would look
# ordinary. Reading 4c exists for precisely this outcome and had no evidence it could act on.
#
# WHAT IS CHECKED, and what is not. CUDA_MPS_PIPE_DIRECTORY is what the plugin sets on a client container at
# allocation. This used to check the VARIABLE ALONE and claim, in this very comment, that it checked "a
# reachable pipe directory" too -- it did not, so any non-empty string passed: a stale value, a typo, a path
# that does not exist. A pre-spend review caught the gap before it was paid for a second time.
#
# It now requires the directory to exist, to be a directory, and to hold the control socket the daemon
# creates. That still does NOT prove kernels are routed through the MPS server; only nvidia-smi on the host
# can show that, and this runner deliberately puts no observer on the sharing node. What it does prove is
# that the client was given a pipe directory that is really there -- which is the difference between "the
# plugin set a variable" and "there is an MPS server at the other end of it".
#
# It REFUSES rather than warns. An arm mislabelled as a mechanism it did not use is the one result this study
# must not produce, and hack/m5c-matrix.sh's own header says MPS and time-slicing differing "is the reason
# both arms exist".
# Returns non-zero and RECORDS WHY, rather than ending the run.
#
# "The sharing mode did not engage" is reading 4c, and its own name says INVALID *for that arm*. A refused
# MPS arm says nothing about the time-slicing arm beside it, and ending the session would throw away
# measurements that were made and paid for. The reason goes to $OUT/refused-mps.txt, which is where
# `benchharness report` looks: the readings run over raw files and would otherwise never learn that an arm
# was declined, because the reason lived only in a log nothing reads back.
mps_clients_connected() {
  local ns_a="$1" dep_a="$2" ns_b="$3" dep_b="$4" ns dep out rc shared pair pod pods pod_n
  for pair in "$ns_a:$dep_a" "$ns_b:$dep_b"; do
    ns="${pair%%:*}"; dep="${pair##*:}"

    # The IPC namespace comes first, because without it the three facts below can all be true and the client
    # still not be one.
    #
    # config/nvidia-device-plugin-mps/daemonset.yaml states the requirement in the daemon's own spec: the
    # control daemon and every client must share one IPC namespace, or the client cannot reach the daemon's
    # pipe and falls back to running WITHOUT MPS. A pipe directory that exists and a control socket that is
    # visible say nothing about whether this pod can reach the daemon through it. This check read those two
    # and not `hostIPC`, so a pod in its own IPC namespace -- which is what both engine manifests declared
    # until today -- would have been reported as an MPS client.
    # The POD that will be probed, not the Deployment's template.
    #
    # A template is what was asked for; a Pod is what is running. They differ when an admission webhook
    # mutates the spec, and they differ when a Pod from an earlier arm is still the one `k exec` lands on --
    # which is the confusion this arm exists to rule out. So the Pod is named once, its own spec is read,
    # and the same name is used for the probe below.
    # "could not ask" is a different fact from "there is no Pod", and `2>/dev/null || true` made them one.
    #
    # An API timeout, an RBAC denial and a genuinely absent Pod all produced the identical refusal. The exec
    # probe below already keeps that distinction; the lookup above it did not. And `items[0]` picked whichever
    # Pod the API happened to list first, so a terminating Pod from the previous arm -- still phase=Running,
    # still carrying this label -- could be the one probed, which is the confusion this arm exists to rule out.
    pods=$(k get pod -n "$ns" -l app.kubernetes.io/component=vllm-shared \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>"$OUT/mps-pod-lookup.err") || {
      arm_invalid mps "could not ask the API which Pod is running in $ns: $(tr '\n' ' ' <"$OUT/mps-pod-lookup.err" | cut -c1-160). An unanswered question is not an answer about MPS"
      return 1
    }
    pods=$(printf '%s\n' "$pods" | awk 'NF')
    pod_n=$(printf '%s\n' "$pods" | awk 'NF' | wc -l)
    if [ "$pod_n" -gt 1 ]; then
      arm_invalid mps "$pod_n Running Pods carry $ns/$dep's label, so which one this probe reads would be decided by list order: $(printf '%s' "$pods" | tr '\n' ' ')"
      return 1
    fi
    pod=$pods
    if [ -z "$pod" ]; then
      arm_invalid mps "no Running Pod for $ns/$dep, so there is nothing to ask whether it is an MPS client. The pre-registration calls an engine that would not schedule or would not pull INVALID: that is a fact about this run, not about MPS on this card"
      return 1
    fi
    shared=$(k get pod -n "$ns" "$pod" -o jsonpath='{.spec.hostIPC}' 2>/dev/null || true)
    if [ "$shared" != "true" ]; then
      arm_invalid mps "$ns/$pod does not share the host IPC namespace (hostIPC=${shared:-absent}), so it cannot reach the MPS control daemon's pipe and would run without MPS while looking like a working arm. config/nvidia-device-plugin-mps/daemonset.yaml states the requirement, and the pre-registration voids a run whose manifest lacks it rather than recording it as a refusal."
      return 1
    fi
    # One probe, three facts: the variable, the directory, and the control socket inside it.
    #
    # Printed as a single line so a partial answer cannot be mistaken for a whole one.
    out=$(k exec -n "$ns" "$pod" -- sh -c '
      pipe="${CUDA_MPS_PIPE_DIRECTORY:-unset}"
      if [ "$pipe" = "unset" ]; then echo "PIPE=unset"; exit 0; fi
      if [ ! -d "$pipe" ]; then echo "PIPE=$pipe DIR=missing"; exit 0; fi
      sock=no
      for candidate in "$pipe"/control "$pipe"/nvidia-mps/control; do
        # A SOCKET, not a path that exists. `-e` accepted a regular file and the entry a dead server leaves
        # behind, so an arm with no MPS daemon at the other end could be labelled an MPS client and its
        # numbers published as MPS. That is the quiet misreading this whole check exists to prevent.
        [ -S "$candidate" ] && sock=yes && break
      done
      echo "PIPE=$pipe DIR=present CONTROL=$sock"
    ' 2>&1); rc=$?
    if [ "$rc" != "0" ]; then
      # A container with no shell is a DIFFERENT FACT from a client that did not connect, and calling the
      # first the second would report a mechanism failure nothing established. vLLM's image has a shell.
      arm_refused mps "could not ask $ns/$dep whether it is an MPS client, so this arm cannot be told apart from time-slicing: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
      return 1
    fi
    case "$out" in
      *PIPE=unset*)
        arm_refused mps "$ns/$dep has no CUDA_MPS_PIPE_DIRECTORY, so it is not an MPS client and this arm would be the time-slicing arm under another name. The control daemon being ready is the server half only; config/nvidia-device-plugin-mps/daemonset.yaml says clients fall back silently."
        return 1 ;;
      *DIR=missing*)
        arm_refused mps "$ns/$dep was given a CUDA_MPS_PIPE_DIRECTORY that does not exist on it, so the variable is decoration: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        return 1 ;;
      *CONTROL=no*)
        arm_refused mps "$ns/$dep has a pipe directory with no MPS control socket in it, so there is no server at the other end and this arm is time-slicing under another name: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        return 1 ;;
      *CONTROL=yes*) ;;
      *)
        arm_refused mps "could not read the MPS client state of $ns/$dep; the probe answered '$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)'"
        return 1 ;;
    esac
    say "  $ns/$dep is an MPS client ($(printf '%s' "$out" | head -1))"
    # B4's instrument, run where B4 can actually be answered: both engines are serving right now.
    #
    # The pre-registration names `nvidia-smi --query-compute-apps` as the only thing that can show the
    # daemon holding both clients -- the pipe-and-socket probe above is the client's own account of itself
    # -- and nothing in this repository ran it. Collected at preflight it would have returned an empty
    # table before any engine existed and satisfied the bar with a file, which is worse than not asking.
    # The bar stays UNMEASURED unless this file has a row per client, so it is written, not judged here.
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
      > "$OUT/mps-compute-apps-$ns.csv" 2>"$OUT/mps-compute-apps-$ns.err" \
      || say "  WARNING: nvidia-smi --query-compute-apps failed on $ns; B4 is UNMEASURED for this arm ($(tr '\n' ' ' <"$OUT/mps-compute-apps-$ns.err" | cut -c1-120))"
  done
}

# arm_refused records a registered refusal where the readings can find it.
arm_refused() {
  local arm="$1" why="$2"
  printf '%s\n' "$why" > "$OUT/refused-$arm.txt"
  say "REFUSED $arm: $why"
  say "  recorded in $OUT/refused-$arm.txt, which benchharness report reads as reading 4c"
}

# arm_invalid records a precondition that was never met, which is NOT a registered outcome.
#
# A refusal says the card was asked and the answer was no; an invalid run says the question was never put.
# The MPS pre-registration separates them because they license different things -- a refusal is evidence
# about this AMI and this driver, an invalid run is evidence about nothing -- and recording the second as
# the first is how "the apparatus was broken" gets reported as "the capability is absent".
arm_invalid() {
  local arm="$1" why="$2"
  printf '%s\n' "$why" > "$OUT/invalid-$arm.txt"
  say "INVALID $arm: $why"
  say "  recorded in $OUT/invalid-$arm.txt; the session fails on it rather than reporting it as an outcome"
}

# The same quantity at three stages, in one file, so "declared = applied = in effect" is machine-readable.
#
# WHY THIS EXISTS
#
# Two of the three stages were already recoverable and that was easy to miss. The DECLARED values are in
# config/vllm/deployment.yaml (0.90, 64) and config/vllm-shared/engine-{a,b}.yaml (0.475, 32). The values
# the engine ACTUALLY RAN WITH are in log.txt, because the launcher ships the whole instance log: vLLM
# prints `non-default args: {... 'gpu_memory_utilization': 0.9, 'max_num_seqs': 64}` at startup. I was about
# to record that the process stage was missing, on the strength of this function using `echo` rather than
# `say` -- wrong, and the archive says so.
#
# What was genuinely absent is the middle stage and the comparison. Nothing read the POD's own args: the
# jsonpath queries in this file ask for hostIPC and nodeName and nothing else. So a Deployment whose args
# were mutated by an admission webhook, or a Pod left from an earlier arm, matched the YAML on paper and
# ran something else. And with the three values in a YAML, a Pod and a log, checking them against each
# other was a human reading three places.
#
# ONE FILE PER RUN, not per cell, and that is deliberate: the output accounting expects exactly four files
# per completed cell, pinned in two places in this script and ten assertions in its gate. A fifth per-cell
# file would move all of them. This appends rows instead, and is counted as a conditional output -- present
# on runs that deploy an engine, absent under PLAN_ONLY and on an arm refused before rollout.
#
# EMPTY IS NEVER A VALUE. A pod that is not there, a query that failed and a log with no matching line are
# three different facts and each gets its own word.
# cell_environment_record writes the environment facts no later reader can recover, once per cell boundary.
#
# WHY PER CELL AND NOT ONCE BEFORE THE FIRST ONE
#
# hack/m5c-gpu-session.sh already runs `nvidia-smi --query-gpu=index,name,memory.total,driver_version` before
# any cell and uploads it as preflight-nvidia-smi.csv. That answers "what card did this instance have"; it
# cannot answer "what was resident on the card while THIS cell ran", which is the question a reader asks when
# one cell's tail differs from its neighbour's. The MPS block below already makes the same argument for
# --query-compute-apps: collected at preflight it "would have returned an empty table before any engine
# existed and satisfied the bar with a file, which is worse than not asking".
#
# THREE OUTCOMES, THREE WORDS. nvidia-smi missing, nvidia-smi failing, and nvidia-smi returning an empty
# table are different facts, and one empty field for all three would make a card whose driver could not be
# read indistinguishable from one nobody asked about. An empty PROCESS table in particular is a measurement
# rather than a failure -- at a cell boundary nothing should hold the card yet -- so it gets its own word.
#
# Every value is flattened to one line before it is written. A multi-GPU host returns one row per card, and a
# newline inside a field would move the columns of a TSV whose column count is asserted by
# hack/test/check-cell-timing-record.sh.
cell_environment_record() {
  local label="$1" stage="$2" out
  [ -s "$OUT/cell-environment.tsv" ] \
    || printf 'cell\tarm\tstage\tfact\tvalue\n' > "$OUT/cell-environment.tsv"

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf '%s\t%s\t%s\tgpu\tno-nvidia-smi-on-this-host\n' "$cell_n" "$label" "$stage" \
      >> "$OUT/cell-environment.tsv"
    printf '%s\t%s\t%s\tprocesses\tno-nvidia-smi-on-this-host\n' "$cell_n" "$label" "$stage" \
      >> "$OUT/cell-environment.tsv"
    return 0
  fi

  # Driver and UUID come from ONE query. Two calls could straddle a driver reload and record a pair that
  # never co-existed, which is the same class of defect as reading a figure from two runs.
  if out=$(nvidia-smi --query-gpu=index,uuid,driver_version --format=csv,noheader 2>&1); then
    out=$(printf '%s' "$out" | tr '\n\t' '; ')
    printf '%s\t%s\t%s\tgpu\t%s\n' "$cell_n" "$label" "$stage" \
      "${out:-query-gpu-returned-no-rows}" >> "$OUT/cell-environment.tsv"
  else
    printf '%s\t%s\t%s\tgpu\tquery-gpu-failed: %s\n' "$cell_n" "$label" "$stage" \
      "$(printf '%s' "$out" | tr '\n\t' '; ' | cut -c1-120)" >> "$OUT/cell-environment.tsv"
  fi

  if out=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1); then
    out=$(printf '%s' "$out" | tr '\n\t' '; ')
    printf '%s\t%s\t%s\tprocesses\t%s\n' "$cell_n" "$label" "$stage" \
      "${out:-no-resident-compute-process}" >> "$OUT/cell-environment.tsv"
  else
    printf '%s\t%s\t%s\tprocesses\tquery-compute-apps-failed: %s\n' "$cell_n" "$label" "$stage" \
      "$(printf '%s' "$out" | tr '\n\t' '; ' | cut -c1-120)" >> "$OUT/cell-environment.tsv"
  fi
}

# ENGINE_PROCESS_ARGS holds the last process-stage value recorded, so a caller can judge the line it wrote.
ENGINE_PROCESS_ARGS=""
engine_applied_record() {
  # source names the manifest in the record; it differs from manifest only when the file read is a rendered
  # copy in $WORK, whose temporary path would tell a later reader nothing.
  local ns="$1" deploy="$2" manifest="$3" label="$4" source="${5:-$3}" args declared process
  [ -s "$OUT/applied-values.tsv" ] \
    || printf 'cell\tarm\tdeploy\tstage\tsource\tvalue\n' > "$OUT/applied-values.tsv"

  # Stage 1: what the manifest asks for. Only `- --flag=value` lines, because the same numbers appear in
  # this repository's comments explaining them -- engine-a.yaml mentions 0.475 four times and declares it
  # once, and grepping the file would have recorded the explanation as a second declaration.
  #
  # The instrument-validation study also records bare flags, because the arguments its arms vary are bare
  # (--no-async-scheduling) and the `=` pattern would leave them out of the very row meant to show them.
  # Every other study keeps the pattern it always had, so their rows read exactly as before.
  if iv_is_study "${STUDY:-}"; then
    declared=$(grep -E '^[[:space:]]*- --' "$manifest" 2>/dev/null \
      | grep -oE -- '--[a-z-]+(=[0-9A-Za-z./-]*)?' | tr '\n' ' ')
  else
    declared=$(grep -E '^[[:space:]]*- --' "$manifest" 2>/dev/null \
      | grep -o -- '--[a-z-]*=[0-9A-Za-z./-]*' | tr '\n' ' ')
  fi
  printf '%s\t%s\t%s\tdeclared\t%s\t%s\n' \
    "$cell_n" "$label" "$deploy" "$source" "${declared:-no-flag-lines-in-manifest}" \
    >> "$OUT/applied-values.tsv"

  # Stage 2: what the cluster actually holds, read off the DEPLOYMENT and not off a Pod.
  #
  # The first version of this selected a Pod by `app.kubernetes.io/name=$deploy`, which is wrong twice over,
  # and the live cluster said so: that label is `gpu-platform-control-plane` on every object here, and
  # `component` is `vllm-shared` for engine-a AND engine-b, so no label distinguishes the two engines whose
  # args this is meant to compare. The only thing that does is the Deployment name.
  #
  # So the applied template is the middle stage. It is the object the API server stored after any admission
  # webhook had its turn, which is exactly the difference from stage 1, and it needs no guess about which
  # Pod belongs to which Deployment. engine_diagnosis above already reads deployments and `deploy/<name>`
  # logs the same way.
  args=$(k get deploy -n "$ns" "$deploy" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null) || args=""
  printf '%s\t%s\t%s\tapplied\tdeploy/%s\t%s\n' \
    "$cell_n" "$label" "$deploy" "$deploy" "${args:-no-deployment-or-query-failed}" \
    >> "$OUT/applied-values.tsv"

  # Stage 3: what the engine says it is running with, from its own startup line.
  #
  # The whole log for the instrument-validation study, because its -log arms print a line per iteration and
  # warm-up alone could push the startup line out of the last 400 -- which would refuse a correctly
  # configured cell as though the engine had not said what it ran.
  local tail_flag=(--tail=400)
  if iv_is_study "${STUDY:-}"; then tail_flag=(); fi
  process=$(k logs -n "$ns" "deploy/$deploy" "${tail_flag[@]}" 2>/dev/null \
    | grep -o "non-default args: {.*}" | tail -1)
  ENGINE_PROCESS_ARGS="${process:-no-non-default-args-line}"
  printf '%s\t%s\t%s\tprocess\t%s\t%s\n' \
    "$cell_n" "$label" "$deploy" "deploy/$deploy" "$ENGINE_PROCESS_ARGS" \
    >> "$OUT/applied-values.tsv"
}

engine_kv_report() {
  local ns="$1" deploy="$2"
  echo "--- $ns/$deploy: what the engine says it allocated ---"
  k logs -n "$ns" "deploy/$deploy" --tail=400 2>/dev/null \
    | grep -iE "KV cache|GPU blocks|gpu_memory_utilization|memory profiling|Available KV cache" \
    | tail -8 | sed 's/^/  /' \
    || echo "  (the engine printed no line naming its KV cache, which is itself worth knowing)"
}

engine_diagnosis() {
  local ns="$1" deploy="$2"
  echo "=== why $ns/$deploy never became ready ==="
  k get pods -n "$ns" -o wide 2>&1 | sed 's/^/  /'
  echo "--- deployment conditions ---"
  k get deploy "$deploy" -n "$ns" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1 | sed 's/^/  /'
  echo "--- pod events, which name a scheduling or image failure ---"
  k get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -20 | sed 's/^/  /'
  echo "--- the engine's own output, which names a CUDA or memory failure ---"
  k logs -n "$ns" "deploy/$deploy" --tail=40 --all-containers 2>&1 | sed 's/^/  /'
  k logs -n "$ns" "deploy/$deploy" --tail=40 --all-containers --previous 2>/dev/null | sed 's/^/  [previous] /'
  echo "--- what the node had left to give ---"
  k get node "${GPU_NODE:-}" -o jsonpath='{.status.allocatable}' 2>&1 | sed 's/^/  /'

  # THE PLUGIN AND THE MPS DAEMON, which live in another namespace and were the missing half.
  #
  # The 2026-09-12 pilot's mps arm failed with `Allocate failed due to no healthy devices present`. That is
  # the kubelet quoting the device plugin, so the answer to "why" is in the plugin's own log and in the MPS
  # control daemon's -- and this function captured neither, because it only ever looked in the engine's
  # namespace. It bought the symptom and not the cause.
  echo "--- the device plugins, which are what told the kubelet the devices are unhealthy ---"
  k get pods -n "$PLUGIN_NS" -o wide 2>&1 | sed 's/^/  /'
  for ds in nvidia-device-plugin-whole-card nvidia-device-plugin-timeslicing nvidia-device-plugin-mps nvidia-mps-control-daemon; do
    if k get ds "$ds" -n "$PLUGIN_NS" >/dev/null 2>&1; then
      echo "  --- $ds ---"
      k logs -n "$PLUGIN_NS" "ds/$ds" --tail=30 --all-containers 2>&1 | sed 's/^/    /'
    fi
  done
  echo
  echo "=== end of diagnosis ==="
}

deploy_arm() {
  # arm is the TOPOLOGY -- what to deploy. label is the arm name the evidence carries, which in ladder mode
  # also names the rung. They are the same string in the frozen matrix and differ in the ladder, and keeping
  # them separate is what lets one deployment path serve both: a refusal has to be recorded under the name
  # the readings look for, and the readings look for the arm in the rows.
  local arm="$1" label="${2:-$1}"
  k delete namespace "$NS_A" "$NS_B" --wait=true >/dev/null 2>&1
  # The policies go too, and they are NOT covered by deleting the namespaces.
  #
  # GPUQuotaPolicy is cluster-scoped, so it outlives both namespaces, and its targetNamespace is immutable:
  # api/v1/gpuquotapolicy_types.go carries `XValidation: self == oldSelf` with the message "targetNamespace
  # is immutable", because a policy enforces quota in exactly one namespace for its lifetime.
  #
  # Pointing one policy at each engine's namespace is this matrix's whole routing mechanism, and moving the
  # contending tenant from NS_A to NS_B is exactly what the split arms do. Re-applying over a surviving
  # object is therefore refused by the API, every time, on the first sharing arm -- `MATRIX FAILED: policies
  # for timeSlicing`. The exclusive arms never hit it because both of their policies name NS_A.
  #
  # The paid run of 2026-09-11 did not reach this: its engine b timed out first, one step earlier in this
  # same function. hack/test/rehearse-m5c-matrix.sh found it on a kind cluster for nothing.
  k delete gpuquotapolicy m5c-premium m5c-standard --ignore-not-found --wait=true >/dev/null 2>&1
  k create ns "$NS_A" >/dev/null; k create ns "$NS_B" >/dev/null
  case "$arm" in
    R1|shared)
      # One engine with the whole card. Both policies point at the same namespace, so both tenants resolve
      # to it -- which is exactly M5-b's topology and exactly what makes their KV caches one cache.
      #
      # R1 IS THIS TOPOLOGY, and it differs only in the trace. `benchharness gen-trace --arm R1` filters the
      # contending tenant out of the SAME trace, so premium arrives on the identical schedule it has in the
      # contended arms and the baseline is not inflated by running premium at twice its share. The matrix
      # already passes --arm "$arm", so nothing else here has to know.
      #
      # It was missing entirely. deploy_arm had cases for shared and for the sharing pair and none for R1,
      # so the runner could not produce the isolated baseline that is the DENOMINATOR of both of this
      # study's bars. The first paid run made that concrete: the readings declined to evaluate anything,
      # correctly, for want of an R1 the matrix had no way to measure.
      #
      # The plugin comes first and is not optional. This arm's engine asks for one nvidia.com/gpu, and until
      # config/nvidia-device-plugin-whole-card existed nothing advertised one on this node -- so the arm
      # either timed out Pending or inherited the previous arm's split card.
      apply_device_plugin shared "$label"
      # The manifest this cell applies, which is the checked-in file for every study but one.
      #
      # The instrument-validation study's arms append engine arguments, and this is where they are applied:
      # deploy_arm deletes both namespaces at its top, so every cell starts a new engine from this manifest.
      # The copy lives in $WORK because it is a derivation; applied-values.tsv names the source and the arm.
      local engine_manifest=config/vllm/deployment.yaml engine_source=config/vllm/deployment.yaml why
      if iv_is_study "${STUDY:-}" && [ -z "${LADDER:-}" ]; then
        engine_manifest="$WORK/engine-$label.yaml"
        why=$(iv_render_manifest "$STUDY" "$label" config/vllm/deployment.yaml "$engine_manifest" "$MODEL_REVISION") \
          || fail "could not render the engine manifest for $label: $why"
        engine_source="config/vllm/deployment.yaml+$label"
      elif pp_is_study "${STUDY:-}" && [ -z "${LADDER:-}" ]; then
        # Every pilot arm runs the same engine: priority policy, budget 512, the pilot's step logger and the
        # weights on a host path, so the restart between arms reuses them.
        engine_manifest="$WORK/engine-$label.yaml"
        why=$(pp_render_manifest config/vllm/deployment.yaml "$engine_manifest" "$MODEL_REVISION" "$(pp_arm_prefill_cap "$label")") \
          || fail "could not render the pilot engine for $label: $why"
        engine_source="config/vllm/deployment.yaml+pilot"
        k create configmap "$PP_CONFIGMAP" -n "$NS_A" --from-file="pilot_step_logger.py=$PP_PLUGIN" \
          --dry-run=client -o yaml | k apply -f - >/dev/null || fail "create the pilot step logger's ConfigMap for $label"
      fi
      # A -step engine imports the instrument from a ConfigMap of the checked-in file, created beside it.
      case "$label" in
        *-step)
          k create configmap "$IV_STEP_CONFIGMAP" -n "$NS_A" --from-file="step_logging_scheduler.py=$IV_STEP_PLUGIN" \
            --dry-run=client -o yaml | k apply -f - >/dev/null || fail "create the instrument's ConfigMap for $label" ;;
      esac
      k apply -f "$engine_manifest" -n "$NS_A" >/dev/null || fail "apply the exclusive engine"
      k apply -f config/vllm/service.yaml -n "$NS_A" >/dev/null || fail "apply the exclusive service"
      k rollout status deploy/vllm-qwen25-3b -n "$NS_A" --timeout=900s >/dev/null \
        || { engine_diagnosis "$NS_A" vllm-qwen25-3b; fail "the exclusive engine never became ready -- the diagnosis above says what it was doing"; }
      engine_kv_report "$NS_A" vllm-qwen25-3b
      engine_applied_record "$NS_A" vllm-qwen25-3b "$engine_manifest" "$label" "$engine_source"
      # Before any request: an engine that is not the arm's configuration would measure another arm.
      if iv_is_study "${STUDY:-}" && [ -z "${LADDER:-}" ]; then
        # $rep is run_cell's local, which bash's dynamic scope makes visible here.
        why=$(iv_process_args_refusal "$STUDY" "$label" "$ENGINE_PROCESS_ARGS" "$MODEL_REVISION") \
          || cell_refused_stop "$label" "${rep:-unknown}" before-replay "REFUSED $label before replay: $why"
      elif pp_is_study "${STUDY:-}" && [ -z "${LADDER:-}" ]; then
        # An engine that is not the registered apparatus stops the pilot: its measurements would be of another one.
        why=$(pp_process_args_refusal "$ENGINE_PROCESS_ARGS" "$(pp_arm_prefill_cap "$label")") \
          || cell_refused_stop "$label" "${rep:-unknown}" before-replay "REFUSED $label before replay: $why"
      fi
      routing_record "$NS_A" vllm-qwen25-3b
      PREMIUM_NS="$NS_A"; STANDARD_NS="$NS_A"
      ;;
    timeSlicing|mps)
      # The plugin step can now REFUSE the arm rather than end the run -- an MPS control daemon that never
      # became ready is reading 4c's business, not a reason to discard the arms beside it.
      apply_device_plugin "$arm" "$label" || return 1
      # A split engine that cannot be APPLIED refuses its arm, for the same reason one that cannot START
      # does: the arms beside it were measured and a manifest this arm could not apply says nothing about
      # them. These two were the last `fail` calls left inside the split-arm branch.
      k apply -f config/vllm-shared/engine-a.yaml -n "$NS_A" >/dev/null || {
        arm_refused "$label" "engine a's manifest could not be applied to $NS_A, so this arm never had two engines"; return 1; }
      k apply -f config/vllm-shared/engine-b.yaml -n "$NS_B" >/dev/null || {
        arm_refused "$label" "engine b's manifest could not be applied to $NS_B, so this arm never had two engines"; return 1; }
      # Both are diagnosed on failure, and BOTH are diagnosed when either fails.
      #
      # The engines share one card, so the one that came up is half the explanation for the one that did
      # not: what engine a reserved is what engine b did not get. Reporting only the failing Pod would leave
      # the reader with the symptom and not the arithmetic.
      # An engine that cannot start is a REGISTERED OUTCOME for its own arm, not the end of the session.
      #
      # The 2026-09-12 pilot met this: under mps every Pod came back
      # `Allocate failed due to no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu`
      # -- the plugin advertises and the kubelet will not allocate, which is the MPS engagement failure
      # reading 4c exists for. The session ended there, so the arm's refusal existed only in a log the report
      # does not read, and the R1 and shared and timeSlicing cells that had already been bought were the only
      # thing to show for it.
      #
      # Now the reason is written where `benchharness report` finds it and the matrix moves on. The
      # diagnosis still runs first: what the Pods were doing is the evidence for the refusal, not a
      # substitute for it.
      if ! k rollout status deploy/vllm-shared-a -n "$NS_A" --timeout=900s >/dev/null; then
        engine_diagnosis "$NS_A" vllm-shared-a
        arm_refused "$label" "engine a never became ready. The diagnosis in this run's log says what its Pods were doing; on one card, why one engine could not start is also why the other could not."
        return 1
      fi
      if ! k rollout status deploy/vllm-shared-b -n "$NS_B" --timeout=900s >/dev/null; then
        engine_diagnosis "$NS_B" vllm-shared-b
        engine_diagnosis "$NS_A" vllm-shared-a
        arm_refused "$label" "engine b never became ready while engine a did. On one card what a came to hold is what b did not get, so both diagnoses are in this run's log."
        return 1
      fi
      # Both engines must be on the SAME node or they are not sharing a card. max_size 1 should guarantee
      # it; checking is cheap and the failure is invisible in the numbers.
      na=$(k get pod -n "$NS_A" -l app.kubernetes.io/component=vllm-shared -o jsonpath='{.items[0].spec.nodeName}')
      nb=$(k get pod -n "$NS_B" -l app.kubernetes.io/component=vllm-shared -o jsonpath='{.items[0].spec.nodeName}')
      if [ -z "$na" ] || [ "$na" != "$nb" ]; then
        arm_refused "$label" "the two engines are on different nodes (${na:-none}, ${nb:-none}), so this arm is two engines on two cards and not a shared one. Nothing it measured would be about sharing"
        return 1
      fi
      if [ "$arm" = mps ] && ! mps_clients_connected "$NS_A" vllm-shared-a "$NS_B" vllm-shared-b; then
        return 1
      fi
      engine_kv_report "$NS_A" vllm-shared-a
      engine_kv_report "$NS_B" vllm-shared-b
      engine_applied_record "$NS_A" vllm-shared-a config/vllm-shared/engine-a.yaml "$label"
      engine_applied_record "$NS_B" vllm-shared-b config/vllm-shared/engine-b.yaml "$label"
      routing_record "$NS_A" vllm-shared-a
      routing_record "$NS_B" vllm-shared-b
      PREMIUM_NS="$NS_A"; STANDARD_NS="$NS_B"
      ;;
  esac

  k apply -f - >/dev/null <<EOF || fail "policies for $arm"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: m5c-premium
  annotations: {platform.lkhun9311.github.io/tier: premium}
spec: {tenant: premium-1, targetNamespace: $PREMIUM_NS, gpuClass: a10g, limits: {gpuCount: 1}}
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata: {name: m5c-standard}
spec: {tenant: standard-noisy, targetNamespace: $STANDARD_NS, gpuClass: a10g, limits: {gpuCount: 1}}
EOF

  k create secret generic gateway-api-keys -n "$NS_A" \
    --from-literal=premium-key=premium-1 --from-literal=standard-key=standard-noisy \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create serviceaccount gateway -n "$NS_A" --dry-run=client -o yaml | k apply -f - >/dev/null
  k create clusterrolebinding m5c-gateway-role --clusterrole=gateway-role \
    --serviceaccount="$NS_A:gateway" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f - >/dev/null <<EOF || fail "secret-reader role"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: gateway-secret-reader, namespace: $NS_A}
rules: [{apiGroups: [""], resources: ["secrets"], verbs: ["get","list","watch"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: gateway-secret-reader, namespace: $NS_A}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: gateway-secret-reader}
subjects: [{kind: ServiceAccount, name: gateway, namespace: $NS_A}]
EOF

  # Admission OFF in both arms. The matrix varies the TOPOLOGY; leaving the guard on would vary two things
  # and hand the difference to whichever one the reader already believed.
  #
  # The prospective-admission pilot is the exception: its arms ARE the admission modes, on one topology, and every
  # one of them binds priority, enforces the benchmark profile and writes the per-request record to a volume
  # capture reads before the namespace is deleted.
  local gw_args='["-admission-mode=off"]' gw_mounts="" gw_volumes=""
  if pp_is_study "${STUDY:-}" && [ -z "${LADDER:-}" ]; then
    gw_args=$(pp_gateway_args_yaml "$label" "${PILOT_STATIC_RATE:-}" 2>&1) || fail "gateway arguments for $label: $gw_args"
    gw_mounts="volumeMounts: [{name: gwrecord, mountPath: $(dirname "$PP_GATEWAY_RECORD")}]"
    gw_volumes="volumes: [{name: gwrecord, emptyDir: {}}]"
  fi
  k apply -f - >/dev/null <<EOF || fail "gateway for $arm"
apiVersion: apps/v1
kind: Deployment
metadata: {name: gateway, namespace: $NS_A}
spec:
  replicas: 1
  selector: {matchLabels: {app: m5c-gateway}}
  template:
    metadata:
      labels: {app: m5c-gateway}
      annotations: {arm: "$label"}
    spec:
      serviceAccountName: gateway
      containers:
        - name: gateway
          image: $GW_IMAGE
          args: $gw_args
          env:
            - {name: GATEWAY_NAMESPACE, value: $NS_A}
            - {name: GATEWAY_API_KEY_SECRET, value: gateway-api-keys}
          ports: [{containerPort: 8080, name: http}]
          $gw_mounts
          # A READINESS PROBE, because without one "rollout status" means only that the container started.
          #
          # Quoted with "" and not with backticks, which is not a style note: this heredoc is unquoted so
          # that $arm, $GW_IMAGE and $NS_A expand, and an unquoted heredoc expands backticks too. This line
          # used to run "rollout status" as a command on every gateway deploy and print "rollout: command
          # not found" to stderr four times a run. It was harmless only by luck -- the substitution landed
          # inside a YAML comment -- and it put spurious errors in the log an operator reads for real ones.
          #
          # The first draft of this very comment quoted the offending command in backticks and put the
          # defect straight back. internal/bench's TestNoUnquotedHeredocExecutesItsOwnProse caught that.
          #
          # The gateway serves /readyz and flips it only once its Kubernetes cache has synced -- it cannot
          # route before it can list the policies and deployments. Without the probe the rollout returns on a
          # process that is running and not yet listening, the port-forward accepts TCP because the kubelet
          # holds the socket, and the replay pours every request into a connection the pod refuses.
          #
          # That is not hypothetical. On 2026-09-12 the R1 cell sent 3882 requests and completed ZERO, all of
          # them errorKind=transport, and the port-forward log holds the reason: "failed to connect to
          # localhost:8080 inside namespace ... connection refused". An independent review had named this
          # exact gap the day before and it was read and not acted on.
          readinessProbe:
            httpGet: {path: /readyz, port: http}
            periodSeconds: 2
            failureThreshold: 60
      $gw_volumes
EOF
  k rollout status deploy/gateway -n "$NS_A" --timeout=180s >/dev/null || fail "gateway never became ready for $arm"
}

# The load is REPORTED here, not derived here. It arrives whole from the caller and is refused if it does
# not, for the reasons written out beside that refusal.
#
# This line used to recompute DURATION_MS as 500/(RATE/2), which silently overwrote whatever was passed --
# so a caller that had derived a trace length on the card would have had it replaced by an arithmetic that
# assumes an even tenant split.
load_banner

# Measured, like the M6 wrapper's: after the first cell, the elapsed time IS the budget, and it knows the
# node's real speed and how long the rollouts actually took rather than how long they were allowed to take.

# The cell budget, measured rather than assumed: after the first cell the elapsed time IS the budget, and it
# knows the node's real speed and how long the rollouts actually took rather than how long they were allowed
# to take.
#
# The plan the projection divides by is built much further up, before the card is touched; the comment that
# described it used to sit here, orphaned above these counters, describing a block that had moved.
cell_secs=0; cells_done=0; cell_n=0

# Every cell's own elapsed time, and every boundary judgement, written where a reader can find them.
#
# WHY: the fifteen-cell run's per-cell duration is NOWHERE in its archive. The 11.61 min/cell figure this
# repository published was BACK-COMPUTED from raw request timestamps, because `cell_secs` is a running total
# used for the projection and nothing wrote the parts. So "did the stop/continue judgement use a sane
# number" could not be answered after the fact at all -- which is the ninth of the nine questions the next
# run has to answer about itself.
#
# TWO call sites, and both are required. A refused cell consumes card time and increments both counters
# (`:1691` records what went wrong when it did not), so a timing file written only on the completed path
# would disagree with the projection that drove the stop decision -- and the disagreement would look like a
# measurement error rather than a missing row.
#
# Append, with a header written once. The file has to survive the run being cut mid-cell, so it is flushed
# per cell rather than assembled at the end: a matrix that stops on a boundary is the case this record is
# most needed for.
# FAIL-SAFE, deliberately. A recorder that can damage a paid cell is worse than no recorder.
#
# `date -u -d "@$t0"` is loud rather than silent on bad input: it prints `date: invalid date '@'` and exits
# 1. This script runs under `set -uo pipefail` and NOT `set -e` -- measured, line 33 -- so that failure
# would not abort the run today. What it WOULD do is put an empty string in the middle of a tab-separated
# row, shifting every column after it, and a timing file whose columns move is worse than one that is
# missing: the first is read, the second is noticed.
#
# So each conversion falls back to the raw epoch. The `|| true` at the call sites is for the same reason one
# step out, and it costs nothing if `set -e` is ever added above.
cell_timing_record() {
  local label="$1" rep="$2" outcome="$3" t0="$4" t1="$5" s0 s1 el
  s0=$(date -u -d "@${t0:-0}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'epoch:%s' "${t0:-?}")
  s1=$(date -u -d "@${t1:-0}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'epoch:%s' "${t1:-?}")
  # The SUBTRACTION needs the same guard the dates got, and the first version did not have it.
  #
  # `$(( t1 - t0 ))` on a non-numeric t0 is an arithmetic error, and bash returns non-zero from the whole
  # function at that point -- so the row was never printed at all. The synthetic harness found it: the
  # column count came back EMPTY rather than wrong, because there was no second line to count. A recorder
  # whose failure mode is "no row" is the one shape this file was written to stop, and I had guarded the
  # dates and left the arithmetic open.
  if [ -n "${t0//[0-9]/}" ] || [ -n "${t1//[0-9]/}" ] || [ -z "$t0" ] || [ -z "$t1" ]; then
    el='?'
  else
    el=$(( t1 - t0 ))
  fi
  [ -s "$OUT/cell-timings.tsv" ] || printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT/cell-timings.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cell_n" "$label" "$rep" "$outcome" "$s0" "$s1" "$el" "$cell_secs" "$cells_done" \
    >> "$OUT/cell-timings.tsv"
}

# The judgement itself, not just its inputs, and on EVERY boundary including the ones that continued.
#
# An external review of the projection asked for exactly this: record the judgement at the boundaries that
# continued too. Recording only the stops makes the continues invisible, and afterwards "the projection was
# wrong" and "the projection was never consulted" read identically.
#
# WRITTEN BY A WRAPPER, not by each branch. cell_deadline_check has SEVEN exits -- two refusals and five
# returns, several of them early bail-outs when the deadline cannot be read -- and a record placed in each
# is a record that the eighth branch will silently not have. The wrapper runs the real check, keeps its
# status, and writes one row whatever path it took. Same shape as the declared-load gate attached on both of
# its caller's exits, and for the same reason.
#
# JUDGE_* are set by the inner function where the values are computed. They are globals rather than returns
# because the shell has one return value and it is already carrying the decision.
JUDGE_REMAIN=""; JUDGE_BASIS=""; JUDGE_PROJECTED=""; JUDGE_WARM_N=""; JUDGE_WARM_PER=""
cell_judgement_record() {
  local decision="$1"
  [ -s "$OUT/cell-judgements.tsv" ] || printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT/cell-judgements.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')" \
    "$cell_n" "$cells_done" "${cells_total:-?}" \
    "${JUDGE_REMAIN:-unreadable}" "${JUDGE_BASIS:-none}" "${JUDGE_PROJECTED:-none}" "$decision" \
    "${JUDGE_WARM_N:-unmeasured}" "${JUDGE_WARM_PER:-unmeasured}" \
    >> "$OUT/cell-judgements.tsv"
}

# How many files this run OWED its archive, counted from what the cells actually did.
#
# WHY A COUNT AT ALL
#
# The published digest lists are verified against their own line count: `verify-published-evidence.sh` reads
# `n_want` out of the SHA256SUMS it was handed. That catches a file that changed or went missing AFTER the
# list was made, and it cannot catch a file that was never written -- the list was made from the directory,
# so a run that wrote fourteen files when it owed fifteen produces a fifteen-line... no, a fourteen-line list
# that verifies perfectly. The expected number has to come from the PLAN and the OUTCOMES, not from the
# directory being checked.
#
# THE ARITHMETIC
#
#   completed cells x 4   trace-, raw-, manifest-, port-forward- per cell
#   + refused arms        refused-<arm>.txt, ONE per arm and not per repetition: arm_refused takes $arm
#                         alone, so five refused repetitions of one arm overwrite one file
#   + invalid arms        invalid-<arm>.txt, same shape. An invalid arm still ships its archive: arm_invalid
#                         writes the file and returns 1, and what fails the session is the LAUNCHER reading
#                         that file after the evidence is home (hack/m5c-gpu-session.sh:1454)
#   + the fixed files     ENUMERATED below with their conditions, not added as a constant
#
# ⚠️ THE CONSTANT WAS WRONG, AND THE FOUR ARCHIVES DID NOT CATCH IT
#
# This started as `+ 2` for evidence.log and README.txt, "checked against four real archives":
#
#   m5c-20260912-084918   3x4 + 1 + 0 + 2 = 15   archive holds 15
#   m5c-20260913-011031   6x4 + 0 + 0 + 2 = 26   archive holds 26
#   m5c-20261001-023515  10x4 + 0 + 0 + 2 = 42   archive holds 42
#   m5c-20261002-014903  15x4 + 0 + 0 + 2 = 62   archive holds 62
#
# Four for four, and it was not evidence that the formula was right. Those archives predate three files
# this script now always writes -- load-source.txt (line 501, unconditional) and the two cell-*.tsv
# recorders added 2026-10-03 -- and all three are absent from every one of them. So the agreement measured
# what those runs happened to contain, and the NEXT run would have reported `agree=no` on a complete
# archive. An external review found it; the synthetic gate, which pinned the same four numbers, could not.
#
# The fixed files are therefore enumerated with the condition each one appears under:
#
#   evidence.log         always: LOG is $OUT/evidence.log and it is truncated right after mkdir
#   load-source.txt      always: written at line 501, before any cell
#   expected-files.txt   always: this comparison's own output, which is in the archive it counts
#   cell-timings.tsv     once any cell has reported an outcome
#   cell-judgements.tsv  once any deadline boundary has been judged
#   README.txt           only on a run that reached the end
#
# (The tarballs list one more entry each: the `m5c-run/` directory itself.)
#
# WHAT IT REFUSES TO COUNT
#
# The ladder. Its cell structure is different -- `cells_total` is the rungs plus one isolated baseline, and
# it writes ladder-verdict-rung<N>.txt per rung besides -- so the matrix arithmetic above is not its
# arithmetic. A number produced by the wrong formula is worse here than no number, so the ladder gets
# `ladder-not-expressed` and whoever buys a ladder run reads that instead of a figure that looks checked.
#
# Prints "<expected> <basis>". The basis words are deliberately not numbers, for the same reason the warm
# estimate's are: an aggregation that could not run must not be readable as a count.
expected_outputs() {
  local completed refused invalid orphan fixed cond metrics
  if [ -n "${LADDER:-}" ]; then
    printf 'ladder-not-expressed ladder-cells-are-not-matrix-cells'
    return 0
  fi
  if [ ! -s "$OUT/cell-timings.tsv" ]; then
    printf 'no-file no-timings-file'
    return 0
  fi
  completed=$(awk -F'\t' '$4 == "completed" {c++} END {print c+0}' "$OUT/cell-timings.tsv") || {
    printf 'unreadable aggregation-failed'
    return 0
  }
  # Refused arms come from the TIMING ROWS, not from the files, so a row with no file is a disagreement.
  #
  # Counting `refused-*.txt` made the expectation and the actual count move together: an arm that was
  # refused and whose file was never written lowered both sides by one and agreed. The rows are per cell and
  # the file is per arm, so the unique arm is what matches the file -- `sort -u` on the label column.
  #
  # The label column IS the arm here because the matrix builds every cell as `arm|arm|rep|...`. Under the
  # ladder the label is `rung03-shared` and this equality breaks, which is one more reason the ladder is
  # refused above rather than approximated.
  # Refusal and invalidity are NOT exclusive, and the arm is the wrong unit to exclude by.
  #
  # mps_clients_connected calls arm_invalid and returns 1 from inside deploy_arm; the caller's
  # `if ! deploy_arm` then writes a `refused` timing row. So a refused row can belong to an invalid arm, and
  # the first attempt at this excluded the whole arm whenever invalid-<arm>.txt existed. CELLS is built
  # repetition-major (`for rep; for arm`), so one arm is deployed again on every repetition and can be
  # refused on one and invalid on another -- leaving BOTH files. Excluding the arm then under-expected by
  # one, and an external review showed the worse half: with cell-judgements.tsv also missing, the
  # under-expectation and the shortfall cancelled into `agree=yes`. Two gaps hid each other.
  #
  # So each file is counted as itself, and the timing rows add only what no file accounts for.
  refused=$(find "$OUT" -maxdepth 1 -name 'refused-*.txt' 2>/dev/null | wc -l)
  invalid=$(find "$OUT" -maxdepth 1 -name 'invalid-*.txt' 2>/dev/null | wc -l)
  # An arm with a refused row and NEITHER file: the one case the files cannot show, because what is missing
  # is the file itself. Expecting it is what makes "the refusal was never written down" a shortfall rather
  # than a quiet agreement between two counts that moved together.
  orphan=$(awk -F'\t' 'NR > 1 && $4 == "refused" {print $2}' "$OUT/cell-timings.tsv" | sort -u | while read -r a; do
    [ -f "$OUT/refused-$a.txt" ] || [ -f "$OUT/invalid-$a.txt" ] || echo "$a"
  done | wc -l)
  # The fixed files, each counted only under the condition it appears under.
  # `-f`, not `-s`: an empty file is in the archive and `find -type f` counts it.
  #
  # This was `-s` and the gate caught it. A README.txt or cell-judgements.tsv that exists and is empty was
  # then missing from the expectation and present in the actual count, so a complete archive reported a
  # permanent one-file shortfall -- the two sides were asking different questions about the same file.
  # cell-judgements.tsv is expected UNCONDITIONALLY once any cell exists, and that matters.
  #
  # cell_deadline_check is the first line of run_cell (1956) and its wrapper writes a row on every one of
  # the inner check's seven exits (1828). So a timings file with any row means a judgements file too, and
  # testing for the file would make the expectation fall with the actual count -- the same defect as
  # counting the refusal files, which is what an external review found here.
  fixed=4 # evidence.log, load-source.txt, expected-files.txt, cell-judgements.tsv
  fixed=$(( fixed + 1 )) # cell-timings.tsv, which the -s test above already proved is there
  # README.txt only on a run that reached the end, and `-f` is right for it: its absence is a FACT about the
  # run, not a missing file. A stopped run owes no README.txt and must still be able to agree.
  [ -f "$OUT/README.txt" ] && fixed=$(( fixed + 1 ))
  # The conditional outputs belong in the total too, and leaving them out made a normal MPS run disagree.
  #
  # mps-compute-apps-<ns>.{csv,err}, mps-pod-lookup.err and ladder-verdict-rung<N>.txt are written only on
  # paths a given run may not take, so whatever is there is expected. They were counted in the per-class
  # rows and NOT here, which meant one mps-pod-lookup.err on an otherwise complete archive produced
  # `expected=9 actual=10` with every class matching -- a disagreement no class could explain.
  # engine-log-<cell>.txt is written only under the instrument-validation study, and a completed cell of that
  # study without one cannot exist: capture_engine_log refuses the run when the log cannot be saved.
  # step-log-<cell>.jsonl and step-plugin-<cell>.sha256 are written only by a -step cell, which capture_step_log
  # refuses rather than lets complete without them.
  # The warm-up's four files are written only under sessions 2 and 3 and the same holds: run_warmup ends the run
  # rather than let a cell go on without them.
  # The prospective-admission pilot's capture files (hack/lib/prospective-pilot.sh) are written only under that
  # study, and a cell it could not capture says so in ineligible-<cell>.txt rather than by a missing file.
  cond=$(find "$OUT" -maxdepth 1 \( -name 'mps-compute-apps-*.csv' -o -name 'mps-compute-apps-*.err' \
    -o -name 'mps-pod-lookup.err' -o -name 'ladder-verdict-rung*.txt' \
    -o -name 'applied-values.tsv' -o -name 'cell-environment.tsv' -o -name 'engine-log-*.txt' \
    -o -name 'raw-warmup-*.jsonl' -o -name 'warmup-boundary-*.txt' -o -name 'warmup-trace-*.jsonl' \
    -o -name 'warmup-manifest-*.yaml' -o -name 'step-log-*.jsonl' -o -name 'step-plugin-*.sha256' \
    -o -name 'fence-*.json' -o -name 'fence-forward-*.log' -o -name 'gateway-record-*.jsonl' -o -name 'raw-*.jsonl.sender.json' \
    -o -name 'ineligible-*.txt' -o -name 'phases.tsv' -o -name 'cell-uploads.tsv' -o -name 'calibration.txt' \
    -o -name 'calibration-forward.log' -o -name 'live-raw-*.jsonl' -o -name 'live-gateway-record-*.jsonl' \
    -o -name 'sidecar-uploads.tsv' -o -name 'engine-samples-*.tsv' \) 2>/dev/null | wc -l)
  # The engine-metrics files are in the total as whatever is there, like the conditional outputs above.
  #
  # How many a cell owes depends on its topology -- one engine or two -- which this count cannot see, so
  # whether every completed cell has them is the per-class row's job, not this sum's.
  metrics=$(find "$OUT" -maxdepth 1 \( -name 'engine-metrics-*.prom' -o -name 'engine-metrics-*.err' \) 2>/dev/null | wc -l)
  # A cell cell_refused_stop ended the run on owes, from its row, its cell-refused file and what it left on disk.
  #
  # Expected from the rows rather than the files, so a refusal whose file was never written is a shortfall.
  # Its metrics files are in the count above with every other cell's.
  # Named in the basis only when there is one, so a run without such a refusal reads exactly as it did.
  local cellref cellref_basis=""
  cellref=$(cell_refusal_rows | awk -F'\t' '
    { n++ } $1 == "refused-at-warmup" { n += 1 } $1 == "refused-after-replay" { n += 4 } END { print n + 0 }')
  [ "$cellref" = 0 ] || cellref_basis="+cell-refusals-$cellref"
  printf '%s completed-%sx4+refused-%s+invalid-%s+unwritten-%s+conditional-%s+metrics-%s%s+fixed-%s' \
    $(( completed * 4 + refused + invalid + orphan + cond + metrics + cellref + fixed )) \
    "$completed" "$refused" "$invalid" "$orphan" "$cond" "$metrics" "$cellref_basis" "$fixed"
}

# One "<outcome>\t<label>-<rep>" line per cell that cell_refused_stop recorded, each cell once.
cell_refusal_rows() {
  awk -F'\t' 'NR > 1 && $4 ~ /^refused-(before-replay|at-warmup|after-replay)$/ && !seen[$2 "-" $3]++ {
    print $4 "\t" $2 "-" $3 }' "$OUT/cell-timings.tsv"
}

# The same accounting, PER CLASS, because one total has one degree of freedom.
#
# WHY THIS EXISTS BESIDE THE TOTAL
#
# The total was corrected three times and an external review found a different cancelling pair each time:
# an arm excluded from the refusal expectation beside a missing judgements file; a refusal file never
# written beside an invalid file that silenced the expectation; an unwritten refusal beside the
# port-forward log of a cell that died before replay. None of those are arithmetic slips. Comparing two
# scalars cannot distinguish "no errors" from "two errors of opposite sign", so any fix to one combination
# leaves the structure that produced it.
#
# Per class, the same two gaps land in two different rows and neither can pay for the other. The total
# stays, because the file's existing readers parse it and because a reader wants one line first.
#
# Prints one "<class> <expected> <actual>" per line. Classes:
#
#   cell-outputs    four per completed cell: trace-, raw-, manifest-, port-forward-
#   engine-metrics  two phases per completed cell, before and after the replay, each holding at least one
#                   engine-metrics-<cell>-<phase>[-a|-b].{prom,err}; strays go to stray-cell-outputs
#   refusal-files   one per arm with a refused ROW -- the row is the claim, the file is the evidence, and
#                   counting files here is what let a never-written refusal agree with itself
#   invalid-files   counted from the files: an invalid arm's row is indistinguishable from a refused one,
#                   so a missing invalid-<arm>.txt is NOT detectable. Stated, not hidden.
#   fixed-files     the unconditional ones, plus README.txt only on a run that reached the end
#   conditional     mps-compute-apps-<ns>.{csv,err}, mps-pod-lookup.err, ladder-verdict-rung<N>.txt --
#                   written only on paths this run may not have taken, so whatever is there is expected
#   unattributed    anything matching no known name. Expected ZERO always: a file nobody can account for is
#                   its own finding, never change for another class's shortfall.
expected_outputs_by_class() {
  local completed refused invalid cell_expected cell_actual stray fixed_expected fixed_actual cond unattr f base cellname
  local metrics_expected metrics_actual metrics_owned metrics_all phase
  local outcome owed phases cref_expected cref_actual cref_all
  if [ -n "${LADDER:-}" ]; then
    printf 'all-classes not-expressed ladder-cells-are-not-matrix-cells\n'
    return 0
  fi
  if [ ! -s "$OUT/cell-timings.tsv" ]; then
    printf 'all-classes no-file no-timings-file\n'
    return 0
  fi
  completed=$(awk -F'\t' '$4 == "completed" {c++} END {print c+0}' "$OUT/cell-timings.tsv") || {
    printf 'all-classes unreadable aggregation-failed\n'
    return 0
  }
  # The refusal expectation skips arms that are INVALID, exactly as the total does.
  #
  # mps_clients_connected calls arm_invalid from inside deploy_arm and returns 1, and the caller writes a
  # `refused` timing row. Such an arm owes invalid-<arm>.txt and NOT refused-<arm>.txt. The total already
  # subtracted them; this function did not, so a complete INVALID run was reported as one whose refusal
  # evidence was missing -- the exclusion existed in one of the two places that needed it.
  # EXCLUDING BY ARM IS WRONG IN BOTH DIRECTIONS, and I got it wrong once each way.
  #
  # Expecting a refusal file for every arm with a refused row reports a complete INVALID run as missing
  # evidence. Excluding the arm whenever invalid-<arm>.txt exists reports an arm that was refused on one
  # repetition and invalid on another -- both files rightly present -- as carrying a surplus. The arm is not
  # the unit; the FILE is. So a file that exists is expected, and a refused row with neither file is the
  # only thing the files cannot show.
  refused=$(find "$OUT" -maxdepth 1 -name 'refused-*.txt' 2>/dev/null | wc -l)
  # Per CELL, not one sum over the directory, because a sum cancels inside its own class.
  #
  # `cell-outputs 4 4` was reached by a completed cell missing its raw-*.jsonl beside the port-forward log
  # of a different cell that died before replay: four owed, four present, two defects. So each completed
  # cell's four files are counted by NAME, and any cell output that belongs to no completed cell is its own
  # row (`stray-cell-outputs`) rather than credit against the expectation.
  cell_expected=0
  cell_actual=0
  metrics_expected=0
  metrics_actual=0
  metrics_owned=0
  cref_expected=0
  cref_actual=0
  # A cell cell_refused_stop ended the run on owes what its stage left on disk, so its outputs are not strays.
  #
  # Session 2's refused staggered cell had no row at all, and its six files read as stray-cell-outputs 0 != 6.
  # after-replay ran everything a completed cell runs; at-warmup had opened only its port-forward log;
  # before-replay had written no cell output.
  while read -r outcome cellname; do
    [ -n "$cellname" ] || continue
    owed=()
    phases=""
    case "$outcome" in
      completed | refused-after-replay)
        owed=("trace-$cellname.jsonl" "raw-$cellname.jsonl" "manifest-$cellname.yaml" "port-forward-$cellname.log")
        phases="before after" ;;
      refused-at-warmup) owed=("port-forward-$cellname.log") ;;
    esac
    case "$outcome" in
      refused-*)
        cref_expected=$(( cref_expected + 1 ))
        [ -f "$OUT/cell-refused-$cellname.txt" ] && cref_actual=$(( cref_actual + 1 )) ;;
    esac
    # `sort -u` above: one cell counted twice owes eight files and holds its four twice over, so a
    # duplicate row cancelled a set of outputs belonging to no completed cell. A cell is a cell once.
    cell_expected=$(( cell_expected + ${#owed[@]} ))
    for base in "${owed[@]}"; do
      [ -f "$OUT/$base" ] && cell_actual=$(( cell_actual + 1 ))
    done
    # Two phases per completed cell, each owing at least one file: a .prom per engine, or an .err saying
    # why not. Counted per PHASE, because a split topology writes two files per phase and a count of files
    # would let one engine's surplus pay for another phase's absence.
    for phase in $phases; do
      metrics_expected=$(( metrics_expected + 1 ))
      if compgen -G "$OUT/engine-metrics-$cellname-$phase*.prom" >/dev/null || compgen -G "$OUT/engine-metrics-$cellname-$phase*.err" >/dev/null; then
        metrics_actual=$(( metrics_actual + 1 ))
      fi
      metrics_owned=$(( metrics_owned + $(find "$OUT" -maxdepth 1 \( -name "engine-metrics-$cellname-$phase*.prom" -o -name "engine-metrics-$cellname-$phase*.err" \) 2>/dev/null | wc -l) ))
    done
  done <<EOF
$(awk -F'\t' 'NR > 1 && $4 == "completed" {print "completed " $2 "-" $3}' "$OUT/cell-timings.tsv" | sort -u)
$(cell_refusal_rows | tr '\t' ' ')
EOF
  # raw-warmup-* matches raw-*, and is a warm-up's rows rather than a cell's, so it is the conditional row's.
  stray=$(( $(find "$OUT" -maxdepth 1 \( -name 'trace-*.jsonl' -o \( -name 'raw-*.jsonl' ! -name 'raw-warmup-*' \) \
    -o -name 'manifest-*.yaml' -o -name 'port-forward-*.log' \) 2>/dev/null | wc -l) - cell_actual ))
  # A metrics file whose cell did not complete -- a cell that died after its `before` scrape -- is a stray
  # like that cell's port-forward log, not credit for a completed cell's missing phase.
  metrics_all=$(find "$OUT" -maxdepth 1 \( -name 'engine-metrics-*.prom' -o -name 'engine-metrics-*.err' \) 2>/dev/null | wc -l)
  stray=$(( stray + metrics_all - metrics_owned ))
  # A cell-refused file with no refusal row is a stray too, rather than credit for a row whose file is missing.
  cref_all=$(find "$OUT" -maxdepth 1 -name 'cell-refused-*.txt' 2>/dev/null | wc -l)
  stray=$(( stray + cref_all - cref_actual ))
  invalid=$(find "$OUT" -maxdepth 1 -name 'invalid-*.txt' 2>/dev/null | wc -l)
  fixed_expected=5 # evidence.log, load-source.txt, expected-files.txt, cell-timings.tsv, cell-judgements.tsv
  [ -f "$OUT/README.txt" ] && fixed_expected=$(( fixed_expected + 1 ))
  fixed_actual=0
  for base in evidence.log load-source.txt cell-timings.tsv cell-judgements.tsv README.txt; do
    [ -f "$OUT/$base" ] && fixed_actual=$(( fixed_actual + 1 ))
  done
  # expected-files.txt counts as present whether or not it is on disk yet: this runs before it is written,
  # and by the time anyone reads the archive it is there.
  fixed_actual=$(( fixed_actual + 1 ))
  cond=$(find "$OUT" -maxdepth 1 \( -name 'mps-compute-apps-*.csv' -o -name 'mps-compute-apps-*.err' \
    -o -name 'mps-pod-lookup.err' -o -name 'ladder-verdict-rung*.txt' \
    -o -name 'applied-values.tsv' -o -name 'cell-environment.tsv' -o -name 'engine-log-*.txt' \
    -o -name 'raw-warmup-*.jsonl' -o -name 'warmup-boundary-*.txt' -o -name 'warmup-trace-*.jsonl' \
    -o -name 'warmup-manifest-*.yaml' -o -name 'step-log-*.jsonl' -o -name 'step-plugin-*.sha256' \
    -o -name 'fence-*.json' -o -name 'fence-forward-*.log' -o -name 'gateway-record-*.jsonl' -o -name 'raw-*.jsonl.sender.json' \
    -o -name 'ineligible-*.txt' -o -name 'phases.tsv' -o -name 'cell-uploads.tsv' -o -name 'calibration.txt' \
    -o -name 'calibration-forward.log' -o -name 'live-raw-*.jsonl' -o -name 'live-gateway-record-*.jsonl' \
    -o -name 'sidecar-uploads.tsv' -o -name 'engine-samples-*.tsv' \) 2>/dev/null | wc -l)
  unattr=0
  for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    base=${f##*/}
    case "$base" in
      raw-warmup-*.jsonl | warmup-boundary-*.txt | warmup-trace-*.jsonl | warmup-manifest-*.yaml) ;;
      trace-*.jsonl | raw-*.jsonl | manifest-*.yaml | port-forward-*.log) ;;
      engine-metrics-*.prom | engine-metrics-*.err) ;;
      refused-*.txt | invalid-*.txt | cell-refused-*.txt) ;;
      evidence.log | load-source.txt | cell-timings.tsv | cell-judgements.tsv | expected-files.txt | README.txt) ;;
      mps-compute-apps-*.csv | mps-compute-apps-*.err | mps-pod-lookup.err | ladder-verdict-rung*.txt) ;;
      applied-values.tsv | cell-environment.tsv | engine-log-*.txt) ;;
      step-log-*.jsonl | step-plugin-*.sha256) ;;
      fence-*.json | fence-forward-*.log | gateway-record-*.jsonl | raw-*.jsonl.sender.json | ineligible-*.txt) ;;
      phases.tsv | cell-uploads.tsv | calibration.txt | calibration-forward.log) ;;
      live-raw-*.jsonl | live-gateway-record-*.jsonl | sidecar-uploads.tsv | engine-samples-*.tsv) ;;
      *) unattr=$(( unattr + 1 )) ;;
    esac
  done
  printf 'cell-outputs %s %s\n' "$cell_expected" "$cell_actual"
  # A cell output belonging to no completed cell: the leftovers of a cell that died mid-way. Expected zero,
  # like unattributed, so it is reported rather than spent on another class's shortfall.
  printf 'stray-cell-outputs 0 %s\n' "$stray"
  printf 'engine-metrics %s %s\n' "$metrics_expected" "$metrics_actual"
  printf 'refusal-files %s %s\n' "$refused" "$refused"
  printf 'invalid-files %s %s\n' "$invalid" "$invalid"
  # The one thing the two rows above cannot show, because what is missing is the file itself: an arm whose
  # refused row has neither a refusal nor an invalid file. Expected zero; anything here is a refusal nobody
  # wrote down.
  printf 'unwritten-refusals 0 %s\n' "$(awk -F'\t' 'NR > 1 && $4 == "refused" {print $2}' "$OUT/cell-timings.tsv" | sort -u | while read -r a; do
    [ -f "$OUT/refused-$a.txt" ] || [ -f "$OUT/invalid-$a.txt" ] || echo "$a"
  done | wc -l)"
  # One per cell cell_refused_stop recorded, printed only when there is one so other runs read as before.
  if [ "$cref_expected" != 0 ] || [ "$cref_all" != 0 ]; then
    printf 'cell-refusal-files %s %s\n' "$cref_expected" "$cref_actual"
  fi
  printf 'fixed-files %s %s\n' "$fixed_expected" "$fixed_actual"
  printf 'conditional %s %s\n' "$cond" "$cond"
  printf 'unattributed 0 %s\n' "$unattr"
}

# The parallel warm-cell estimate, in a function of its own so a test can run THIS code.
#
# It was eleven lines inside cell_deadline_check_inner, and the gate that claimed to cover it had copied the
# case statement into itself: changing `none-completed` to anything at all, or putting the refused cell back
# into the average, left that gate green on the real script. An instruction-free external review found it.
# The repair is the move this file already made for the two recorders -- one function at column zero, which
# the gate extracts and drives for real.
#
# Prints "<n> <per>", space-separated because neither field ever contains a space.
#
# The failure words are deliberately not numbers. An aggregation that could not run is a different fact from
# a run that found no completed cell, and `[ -s ]` cannot tell them apart: a file with size and no read
# permission passes `-s`, fails awk, and the previous `|| echo 0` printed `none-completed` for a file
# holding two completed cells. "Did not run" must not be readable as a measurement of zero.
warm_cell_estimate() {
  local warm_n
  if [ ! -s "$OUT/cell-timings.tsv" ]; then
    printf 'no-file no-timings-file'
    return 0
  fi
  warm_n=$(awk -F'\t' '$4 == "completed" {c++} END {print c+0}' "$OUT/cell-timings.tsv") || {
    printf 'unreadable aggregation-failed'
    return 0
  }
  # Zero and one are reported as themselves rather than smoothed into a number.
  #
  # A mean over no cells is not a long estimate, it is no estimate, and a mean over one is a single
  # observation wearing an average's name. Printing "none" and naming the single value keeps a reader from
  # reading either as a rate.
  case "$warm_n" in
    0) printf '0 none-completed' ;;
    1) printf '1 single-observation-%ss' "$(awk -F'\t' '$4 == "completed" {print $7; exit}' "$OUT/cell-timings.tsv")" ;;
    *) printf '%s %ss' "$warm_n" "$(awk -F'\t' '$4 == "completed" {s += $7; c++} END {if (c > 0) printf "%d", (s + c - 1) / c}' "$OUT/cell-timings.tsv")" ;;
  esac
}

# The two projections for cells of different lengths, as functions so a harness can drive them.
#
# iv_cold_projection_min prints the whole run in minutes before any cell: 8 min beyond each cell's replay
# floor, plus a fifth.
# The 8 is the measured cold cell (16 min) less the replay floor of the 420 s trace it was measured on.
# Both charge a cell cell_charge_ms, which is its trace length and, for a study that warms up, its warm-up.
iv_cold_projection_min() {
  local c lbl ms sum=0
  for c in "${CELLS[@]}"; do
    lbl=$(printf '%s' "$c" | cut -d'|' -f2)
    ms=$(cell_charge_ms "$lbl" "$(printf '%s' "$c" | cut -d'|' -f3)") || return 1
    sum=$(( sum + 8 + (ms + 59999) / 60000 + 1 ))
  done
  echo $(( sum * 12 / 10 ))
}
# iv_remaining_projection prints "<projected min> <mean remaining cell s> <mean overhead s>" mid-run.
#
# The overhead is the time the done cells took beyond their replays; CELLS[cells_done..] are the cells left,
# because the matrix runs CELLS in order and counts every cell it starts, refused or not.
# Overhead is floored at zero so a run whose replays somehow outran the clock cannot charge negative time.
iv_remaining_projection() {
  local i lbl ms done_ms=0 left_s=0 left_n=0 over
  [ "$cells_done" -gt 0 ] || return 1
  for (( i = 0; i < cells_done && i < ${#CELLS[@]}; i++ )); do
    lbl=$(printf '%s' "${CELLS[$i]}" | cut -d'|' -f2)
    ms=$(cell_charge_ms "$lbl" "$(printf '%s' "${CELLS[$i]}" | cut -d'|' -f3)") || return 1
    done_ms=$(( done_ms + ms ))
  done
  over=$(( (cell_secs - done_ms / 1000 + cells_done - 1) / cells_done ))
  [ "$over" -ge 0 ] || over=0
  for (( i = cells_done; i < ${#CELLS[@]}; i++ )); do
    lbl=$(printf '%s' "${CELLS[$i]}" | cut -d'|' -f2)
    ms=$(cell_charge_ms "$lbl" "$(printf '%s' "${CELLS[$i]}" | cut -d'|' -f3)") || return 1
    left_s=$(( left_s + over + ms / 1000 ))
    left_n=$(( left_n + 1 ))
  done
  [ "$left_n" -gt 0 ] || { echo "0 0 $over"; return 0; }
  echo "$(( (left_s * 12 / 10 + 59) / 60 )) $(( left_s / left_n )) $over"
}

cell_deadline_check() {
  JUDGE_REMAIN=""; JUDGE_BASIS=""; JUDGE_PROJECTED=""; JUDGE_WARM_N=""; JUDGE_WARM_PER=""
  local rc=0
  cell_deadline_check_inner || rc=$?
  cell_judgement_record "$([ "$rc" = 0 ] && echo continue || echo stop)" || true
  return "$rc"
}

cell_deadline_check_inner() {
  local remain per projected floor warm_pair
  # The pilot has no projection stop and no forecast floor (design page, build item 10; pilot review 11, finding
  # 4). Its projection would include the cold first cell and multiply by 1.2, which refuses every pilot session
  # after its first cell, and no minimum cell time is established. Its cell count is the registration's, its
  # deadlines are sized from that count, and the hard stop and the sweeper bound its time; a cell cut short is
  # an ineligible cell, which the report says.
  if [ -z "${LADDER:-}" ] && pp_is_study "${STUDY:-}"; then
    JUDGE_BASIS="pilot: no projection stop"
    JUDGE_REMAIN=$(deadline_remaining_minutes 2>/dev/null || true)
    return 0
  fi
  # BEFORE the first cell there is no measured rate to project from -- but there is still a deadline, and
  # "no projection" is not "enough time".
  #
  # This returned 0 unconditionally, so a matrix handed an already-expired deadline started its first cell
  # anyway: it rolled out the engines, replayed, and was cut mid-cell with nothing archived. A lower bound
  # is available without any measurement at all, because no cell can finish faster than its own replay.
  if [ "$cells_done" -eq 0 ]; then
    remain=$(deadline_remaining_minutes 2>/dev/null) || return 0
    [ -n "$remain" ] || return 0
    # The FIRST cell's own length, which is DURATION_MS for every study whose cells share one.
    # Its warm-up too, for a study that has one, since the replay floor is then two replays.
    first_ms=$(cell_charge_ms "$(printf '%s' "${CELLS[0]:-}" | cut -d'|' -f2)" "$(printf '%s' "${CELLS[0]:-}" | cut -d'|' -f3)") || first_ms="${DURATION_MS:-0}"
    floor=$(( (first_ms + 59999) / 60000 + 1 ))
    # And the WHOLE matrix, projected by the same conservative rule the mid-run check uses.
    #
    # The floor above refuses a deadline that cannot fit one cell's replay. It says nothing about the other
    # nine, so a run with time for exactly one cell started, bought it, and stopped on the boundary -- which
    # is what happened on 2026-10-01 morning for $0.25. The stop was correct and the SURPRISE was the
    # defect: the same arithmetic was available before anything was rolled out.
    #
    # The per-cell figure is the measured cold first cell, not the steady one, and that is deliberate. Cell
    # 1 downloads the model weights: 15.58 min against the steady 11.34 over nine cells on 2026-10-01. An
    # external review put the choice plainly -- the projection should err toward OVER-estimating, because
    # this is the judgement that stops spending, and a replay lower bound is "it cannot finish sooner"
    # rather than "it will finish by then". So one cold cell is charged for every cell. On a ten-cell run
    # that asks for about 65% more than the steady rate would, and the alternative is discovering the
    # shortfall after the card is rented.
    #
    # It WARNS and does not refuse. The deadline is a cap on spending rather than a promise of completion,
    # and a matrix that completes six of ten cells has bought six comparable cells. Refusing here would
    # turn a conservative estimate into a veto over runs that would have finished.
    cold_cell_min=16
    whole=$(( cells_total * cold_cell_min * 12 / 10 ))
    JUDGE_REMAIN="$remain"; JUDGE_BASIS="cold-${cold_cell_min}min-per-cell"; JUDGE_PROJECTED="$whole"
    # Cells of different lengths, charged each at its own length.
    #
    # The 16 min was measured on cells whose replay floor is 8 min (420 s), so 8 is what a cell costs beyond
    # its replay, and a cell of another length is charged that plus its own floor.
    # At 420 s this is exactly the 16 above; a stagger cell at 630 s is charged 20 and a serial one 12.
    if [ -z "${LADDER:-}" ] && iv_is_study "${STUDY:-}"; then
      whole=$(iv_cold_projection_min) || whole=$(( cells_total * cold_cell_min * 12 / 10 ))
      JUDGE_BASIS="cold-overhead-8min-plus-each-cells-replay"; JUDGE_PROJECTED="$whole"
    fi
    if [ "$remain" -lt "$whole" ]; then
      echo >&2
      echo "NOTE before the first cell: ${cells_total} cells at a cold-start ${cold_cell_min} min each plus a fifth" >&2
      echo "  of headroom is about ${whole} min, and the deadline fires in ${remain} min. This run is likely to stop" >&2
      echo "  on a boundary before finishing the matrix. That is not a failure -- completed cells are kept and" >&2
      echo "  uploaded -- but if a COMPLETE matrix is what this run is for, raise the deadline now rather than" >&2
      echo "  after the card is paid for. The 16 min is the measured FIRST cell (weights download); steady" >&2
      echo "  cells measured 11.34, so this is deliberately pessimistic." >&2
      echo >&2
    fi
    if [ "$remain" -lt "$floor" ]; then
      echo >&2
      echo "STOPPING before the first cell: the deadline fires in ${remain} min and one cell's replay alone" >&2
      echo "  is ${floor} min. Nothing has been rolled out, so nothing is half-bought. Give the run a longer" >&2
      echo "  deadline: TTL_MINUTES on EKS, or HARD_STOP_SECONDS (and BACKSTOP_SECONDS above it) on a rented" >&2
      echo "  instance -- hack/m5c-gpu-session.sh has no TTL_MINUTES at all." >&2
      return 1
    fi
    return 0
  fi
  remain=$(deadline_remaining_minutes 2>/dev/null) || return 0
  [ -n "$remain" ] || return 0
  per=$(( (cell_secs + cells_done - 1) / cells_done ))
  # A SECOND estimate, recorded beside the judgement and never used to make it.
  #
  # `per` above is the mean over every cell that consumed time, refusals included. That is correct for
  # "how much card time has this bought", and it is the wrong sample for "how long does a cell take": a
  # refused mps arm spent ten minutes waiting for a device count before declining, which is most of a cell
  # and none of a measurement.
  #
  # An external review named three sample boundaries `cells_done` cannot express -- zero valid warm cells,
  # exactly one, and zero cells for a particular arm -- and the same review was explicit that changing the
  # STOPPING rule is a policy choice about acceptable loss that today's data does not get to make. The
  # 2026-10-02 decision was to leave the rule alone and record a parallel figure instead, so that is what
  # this is: written to cell-judgements.tsv, read by nobody at run time, and comparable afterwards against
  # what actually happened.
  #
  # It is computed from cell-timings.tsv rather than a new counter, because that file already separates
  # `completed` from `refused` -- the recorder added earlier today is what makes this possible at all.
  # Both fields come from one call, so the printed sample size is the one the average was taken over.
  # Splitting them across two aggregations is how a count and a mean drift apart.
  warm_pair=$(warm_cell_estimate)
  JUDGE_WARM_N=${warm_pair%% *}
  JUDGE_WARM_PER=${warm_pair#* }
  # A fifth of headroom, because cells differ by arm, and a projection that only just fits is one slow
  # cell from being cut.
  #
  # This comment used to say "the sharing arms roll out two engines and the exclusive arm rolls out one",
  # which puts `shared` on the wrong side: deploy_arm groups R1|shared together and the device plugin asks
  # want=1 for both of them (see the arm cases above), while timeSlicing and mps are the want=2 arms. The
  # wrong half of that sentence was then quoted into a deadline argument and used to predict a 22.9-minute
  # shared cell; ten measured cells put it at 11.31, against R1's 11.19. The arms DO differ -- the plateau
  # intervals do not overlap -- by 7.2 seconds, and what causes those seconds was never measured. The real
  # spread is the FIRST cell of a run, which downloads the model weights: 15.58 minutes against 11.34.
  #
  # `per` is the average over completed cells, so after cell 1 it IS the cold cell and the projection runs
  # about 37% high. That is left as it is, on purpose, and an external review confirmed the direction:
  # removing the over-estimate trades it for an UNDER-estimate, and this judgement stops spending. Excluding
  # cell 1 would also need evidence that the cold start is always cell 1 -- two runs is not that evidence --
  # and would have to separate download and setup time from replay time, which nothing measures yet.
  projected=$(( ((cells_total - cells_done) * per * 12 / 10 + 59) / 60 ))
  JUDGE_REMAIN="$remain"; JUDGE_BASIS="mean-of-${cells_done}-completed-cells-${per}s"; JUDGE_PROJECTED="$projected"
  # A mean cell is the wrong unit when the cells left are longer than the cells done.
  #
  # The instrument-validation study's stagger cells replay 630 s against a serial cell's 180, so a mean taken
  # over a block that happened to start serial would under-project every stagger cell still to come.
  # What is averaged instead is the time a cell spent beyond its own replay, and each remaining cell is
  # charged that plus its own length, with the same fifth of headroom.
  if [ -z "${LADDER:-}" ] && iv_is_study "${STUDY:-}"; then
    local iv_triple iv_over
    if iv_triple=$(iv_remaining_projection); then
      read -r projected per iv_over <<<"$iv_triple"
      JUDGE_BASIS="overhead-mean-of-${cells_done}-cells-${iv_over}s-plus-each-cells-replay"; JUDGE_PROJECTED="$projected"
    fi
  fi
  if [ "$projected" -ge "$remain" ]; then
    echo >&2
    echo "STOPPING: $(( cells_total - cells_done )) cells left at ~$(( per / 60 )) min each needs about ${projected} min," >&2
    echo "  and the deadline fires in ${remain} min. Being cut mid-cell would waste that cell's rollouts and" >&2
    echo "  leave a matrix missing one of the topologies it exists to compare, so it stops on a boundary." >&2
    # The knob depends on who armed the deadline, and naming only one of them sent an operator to a
    # variable their path does not read.
    #
    # Measured 2026-10-01: a spot-instance run stopped here after cell 1 of 10 and said "Re-arm with a
    # longer TTL_MINUTES". hack/m5c-gpu-session.sh contains that name ZERO times -- it derives
    # DEADLINE_EPOCH from HARD_STOP_SECONDS -- so following the advice would have changed nothing and
    # bought the same first cell again.
    echo "  ${cells_done} of ${cells_total} cells are complete. To continue, give the run a longer deadline:" >&2
    echo "  TTL_MINUTES on EKS, or HARD_STOP_SECONDS (with BACKSTOP_SECONDS above it) on a rented instance." >&2
    return 1
  fi
  return 0
}


# run_cell measures ONE cell: deploy the topology, prove the tunnel, generate this cell's load, replay it,
# and hand the evidence over.
#
# It is a function rather than the inside of a loop because the ladder calls it from two places -- the rungs
# it climbs, and the single isolated-baseline cell it buys at whichever rung it stopped on. A second copy of
# this body for the second caller is the failure this repository has paid for more than once.
# Reads each engine's /metrics for one cell phase, so the cell's TTFT can be split into waiting and prefill.
#
# The 2026-10-04 model-first registration found that a mechanism model explains between a fifth and two
# thirds of the shared tail the fifteen-cell run measured, and the archive cannot say where the rest went:
# every timestamp in it is the client's. The engine's own counters, read before and after the replay, are
# the one level deeper that run never recorded.
#
# It never fails the cell. A paid cell lost to secondary evidence is the worse outcome, so a scrape that
# cannot complete writes an .err naming why instead -- never nothing, because a phase with no file would
# read later as "this run did not measure it" rather than "it tried and the engine did not answer".
#
# The forward is started on kubectl itself, not on `k`, for the reason the gateway's forward in run_cell
# gives: `&` on a function backgrounds a subshell, and killing that pid leaves kubectl holding the port.
#
# Usage: scrape_engine_metrics <topology> <label> <rep> <before|after>
scrape_engine_metrics() {
  local topology="$1" label="$2" rep="$3" phase="$4" targets t ns deploy suffix base pf tries port i reason bound
  tries="${METRICS_SCRAPE_TRIES:-15}"
  port="${METRICS_PORT:-18081}"
  case "$topology" in
    R1 | shared) targets="$NS_A|vllm-qwen25-3b|" ;;
    timeSlicing | mps) targets="$NS_A|vllm-shared-a|-a $NS_B|vllm-shared-b|-b" ;;
    *)
      printf 'no engine is known for topology %s, so nothing was scraped\n' "$topology" \
        > "$OUT/engine-metrics-$label-$rep-$phase.err"
      return 0 ;;
  esac
  for t in $targets; do
    IFS='|' read -r ns deploy suffix <<<"$t"
    base="$OUT/engine-metrics-$label-$rep-$phase$suffix"
    # The forward's log goes to $WORK and not into $OUT: its content belongs in the .err when the scrape
    # fails, and a third file per phase would be one more output for the accounting to explain.
    pf="$WORK/engine-metrics-pf.log"
    # A page read from a port this forward does not own would be another engine's counters filed under this
    # cell's name, so ownership is proved twice: the port is free before the forward starts, and kubectl has
    # said it bound the port before anything is read. A live kubectl pid alone proves neither -- an external
    # review showed the first curl can succeed against a leftover forward while the new kubectl is still
    # resolving its target and has not tried to bind yet.
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      printf '%s was already held before this forward started, so a page read from it would belong to whatever held it\n' "$port" > "$base.err"
      continue
    fi
    kubectl --context "$KCTX" port-forward -n "$ns" "deploy/$deploy" "$port:8000" >"$pf" 2>&1 &
    local pf_pid=$!
    reason="the engine did not answer /metrics within $tries attempts"
    bound=0
    for i in $(seq 1 "$tries"); do
      if [ "$bound" = 0 ]; then
        # kubectl prints this line only after its listener is up, so it is the forward's own claim of the port.
        if grep -q "Forwarding from 127.0.0.1:$port" "$pf" 2>/dev/null; then
          bound=1
        elif ! kill -0 "$pf_pid" 2>/dev/null; then
          reason="the port-forward to deploy/$deploy in $ns exited before it bound $port"
          break
        else
          sleep 1
          continue
        fi
      fi
      if curl -fsS --max-time 5 -o "$base.prom.part" "http://127.0.0.1:$port/metrics" 2>"$WORK/engine-metrics-curl.err"; then
        # The forward bound the port, but it can still have died since; then the page came from whatever
        # took the port after it.
        if ! kill -0 "$pf_pid" 2>/dev/null; then
          reason="the port-forward to deploy/$deploy in $ns had exited, so the page on $port was not this engine's"
        # And whether it was the engine at all, because a forward that landed on the wrong pod still serves
        # a /metrics page.
        elif grep -q '^vllm:' "$base.prom.part"; then
          mv "$base.prom.part" "$base.prom"
          reason=""
        else
          reason="$port answered /metrics with no vllm: series, so it was not the engine"
        fi
        break
      fi
      if ! kill -0 "$pf_pid" 2>/dev/null; then
        reason="the port-forward to deploy/$deploy in $ns exited before /metrics answered"
        break
      fi
      sleep 1
    done
    [ "$bound" = 1 ] || [ "$reason" != "the engine did not answer /metrics within $tries attempts" ] \
      || reason="the port-forward to deploy/$deploy in $ns never reported binding $port within $tries attempts"
    # curl's own last word, because "did not answer" and "answered 404" are different findings: the first
    # is a network or a process, the second an engine that has no /metrics. The first rehearsal of this
    # scrape recorded every phase as not answering while the stub was answering 404 each time.
    if [ "$bound" = 1 ] && [ "$reason" = "the engine did not answer /metrics within $tries attempts" ]; then
      reason="$reason; curl's last error: $(tail -n 1 "$WORK/engine-metrics-curl.err" 2>/dev/null)"
    fi
    rm -f "$WORK/engine-metrics-curl.err"
    # A forward that already exited makes `kill` fail and the killed one makes `wait` fail; neither may end
    # the run. See the gateway forward's kill in run_cell.
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
    rm -f "$base.prom.part"
    if [ -n "$reason" ]; then
      { echo "$reason"; echo "-- port-forward log:"; tail -n 5 "$pf" 2>/dev/null; } > "$base.err"
    fi
    rm -f "$pf"
  done
  return 0
}

# Saves the engine's log for one cell to $OUT/engine-log-<label>-<rep>.txt and judges it against the arm.
#
# The log is the cell's lifetime and no more because deploy_arm deletes the engine's namespace at the top of
# every cell, so the container read here was started by this cell.
# A restarted container breaks that: `kubectl logs` returns only the newest instance, so a log that looks
# whole would be missing the part before the restart, and the cell refuses rather than judge a fragment.
#
# Prints the refusal and returns 1; prints nothing and returns 0 for a log that agrees with its arm.
# Only the instrument-validation study calls this, and it runs only the one-engine topology.
capture_engine_log() {
  local label="$1" rep="$2" dest restarts err
  dest="$OUT/engine-log-$label-$rep.txt"
  err="$WORK/engine-log-$label-$rep.err"
  if ! restarts=$(k get pods -n "$NS_A" -l app.kubernetes.io/component=vllm \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}' 2>"$err"); then
    echo "could not read the engine pod's restart count, so whether its log covers the whole cell is unknown: $(tr '\n' ' ' <"$err" | cut -c1-200)"
    return 1
  fi
  # Exactly one pod that never restarted; two pods would be two KV pools and two logs, and this reads one.
  [ "$restarts" = "0 " ] || {
    echo "the engine pod's restart counts read ${restarts:-nothing}, not one pod at 0, so its log would not cover the whole cell"
    return 1
  }
  if ! k logs -n "$NS_A" deploy/vllm-qwen25-3b >"$dest" 2>"$err"; then
    echo "could not read the engine log for $label rep $rep: $(tr '\n' ' ' <"$err" | cut -c1-200)"
    return 1
  fi
  rm -f "$err"
  # A logged engine's first iteration is 0, because the container was started by this cell.
  # A later first index means the kubelet rotated the log and `kubectl logs` returned only its newest file: the
  # S1 confirmation's staggered cells reached 11.4 MiB against the 10 MiB default and were judged only at the
  # evaluator, after 5.3 hours (docs/superpowers/specs/2026-10-07-confirming-s1-on-unseen-settings.md).
  # Refusing here stops a session at its first such cell.
  local first
  first=$(grep -m1 -oE 'Iteration\([0-9]+\)' "$dest" | tr -dc '0-9')
  if [ -n "$first" ] && [ "$first" != 0 ]; then
    echo "the engine log for $label rep $rep starts at iteration $first, not 0: the container's log was rotated, so the cell's earlier iterations are not in it"
    return 1
  fi
  iv_engine_log_refusal "$STUDY" "$label" "$dest"
}

# Saves a -step cell's instrument log to $OUT/step-log-<label>-<rep>.jsonl and proves the engine ran the checked-in file.
#
# The instrument writes on a thread after each drain, so the log is read only once it ends on a flush record
# that follows the cell's last request; reading earlier would save a log missing its last batch, which
# check_step_log.py would refuse after the money was spent. The plugin's sha256 inside the pod is compared with
# the file in this tree, so the instrument the cell measured with is the one the commit names.
capture_step_log() {
  local label="$1" rep="$2" dest pod want got last
  dest="$OUT/step-log-$label-$rep.jsonl"
  pod=$(k get pods -n "$NS_A" -l app.kubernetes.io/component=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
    || { echo "could not find the engine pod to read the instrument log from"; return 1; }
  want=$(sha256sum "$IV_STEP_PLUGIN" | cut -c1-64)
  got=$(k exec -n "$NS_A" "$pod" -- sha256sum /opt/step-plugin/step_logging_scheduler.py 2>/dev/null | cut -c1-64)
  [ "$got" = "$want" ] || { echo "the engine loaded an instrument with sha256 ${got:-unreadable}, not this tree's $want"; return 1; }
  # The cell's LAST measured request, by trace index, must be in the log before its closing flush: any earlier
  # request followed by a flush is an earlier episode's batch, and accepting it saved a truncated log (found by review).
  last=$(awk -F'"index":' 'NF > 1 {split($2, a, /[,}]/); if (a[1] + 0 > m) m = a[1] + 0} END {print m + 0}' \
    "$OUT/trace-$label-$rep.jsonl") || { echo "could not read the last index of trace-$label-$rep.jsonl"; return 1; }
  for _ in $(seq 1 60); do
    k exec -n "$NS_A" "$pod" -- cat "$IV_STEP_LOG" > "$dest" 2>/dev/null || true
    if [ -s "$dest" ] && tail -1 "$dest" | grep -q '"ev":"flush"' \
       && grep -q "\"id\":\"chatcmpl-$label-$rep-measured-$last-" "$dest"; then
      printf '%s  %s\n' "$want" "$IV_STEP_PLUGIN" > "$OUT/step-plugin-$label-$rep.sha256"
      return 0
    fi
    sleep 1
  done
  echo "the instrument log for $label rep $rep did not end on a flush after the measured requests within 60 s"
  return 1
}

# Writes $OUT/warmup-boundary-<label>-<rep>.txt: the last warm-up iteration index, or `none`.
#
# Read from the engine log as it stands after the warm-up replay, because the measured replay has not sent
# anything yet, so every Iteration line in it so far belongs to the warm-up.
# Only a -log arm prints iteration lines, so only a -log arm reads the log at all.
# Prints the refusal and returns 1 with no file written; returns 0 once the file holds the boundary.
warmup_boundary_record() {
  local label="$1" rep="$2" log="" err boundary
  case "$label" in
    *-log | *-step)
      log="$WORK/warmup-log-$label-$rep.txt"
      err="$WORK/warmup-log-$label-$rep.err"
      if ! k logs -n "$NS_A" deploy/vllm-qwen25-3b >"$log" 2>"$err"; then
        echo "could not read the engine log after $label rep $rep's warm-up: $(tr '\n' ' ' <"$err" | cut -c1-200)"
        return 1
      fi ;;
  esac
  boundary=$(iv_warmup_boundary "$STUDY" "$label" "$log") || { echo "$boundary"; return 1; }
  printf '%s\n' "$boundary" > "$OUT/warmup-boundary-$label-$rep.txt" \
    || { echo "could not write $OUT/warmup-boundary-$label-$rep.txt"; return 1; }
}

# Warms one cell's fresh engine and proves it warm before the measured replay (section 2 of session 2).
#
# The warm-up trace and manifest go to $OUT beside its rows, so what was replayed is in the archive and the
# rows can be checked against the trace they came from.
# Its replay takes the measured replay's flags, so the warm-up passes through the same gateway, keys and
# provenance demand the measured requests will.
# Every failure here ends the run: the registration stops the session on a W refusal and never repeats a
# warm-up until it passes, and a cell measured on an engine not proved warm is not a cell it registers.
run_warmup() {
  local label="$1" rep="$2" why
  say "  warm-up for $label rep $rep, excluded from the measurement"
  warmup_gen_trace "$label" "$rep" "$OUT/warmup-trace-$label-$rep.jsonl" "$OUT/warmup-manifest-$label-$rep.yaml" \
    --engine-image "$ENGINE_IMAGE" --gateway-image "$GATEWAY_IMAGE_REF" --gateway-sha "$SOURCE_COMMIT" \
    --gateway-binary-sha256 "$GW_BINARY_SHA" --gateway-base "$GW_BASE" \
    --tokenizer-rev "$MODEL_REVISION" || fail "gen-trace --warmup $label"
  local idflag
  idflag=$(iv_request_id_flag "$STUDY" "$label" "$rep" warmup) || fail "request ids for $label warm-up"
  "$WORK/benchharness" replay --manifest "$OUT/warmup-manifest-$label-$rep.yaml" \
    $PROVENANCE_FLAG ${idflag:+"$idflag"} \
    --target "http://127.0.0.1:18080" \
    --api-keys "premium-1=premium-key,standard-noisy=standard-key" \
    --raw-out "$OUT/raw-warmup-$label-$rep.jsonl" || fail "warm-up replay $label"
  why=$(warmup_boundary_record "$label" "$rep") \
    || cell_refused_stop "$label" "$rep" at-warmup "REFUSED $label rep $rep at its warm-up boundary: $why"
  why=$(iv_warmup_refusal "$OUT/raw-warmup-$label-$rep.jsonl") \
    || cell_refused_stop "$label" "$rep" at-warmup "W REFUSED $label rep $rep: $why"
  # Gate S on the warm-up's own staggered cycle, before the measured replay is bought.
  #
  # Session 2's warm-up violated S too, so a measured replay after it would buy a cell that S then refuses.
  if [[ "$label" == stagger-* ]]; then
    why=$(iv_stagger_refusal "$STUDY" "$label" "$OUT" "$rep" warmup) \
      || cell_refused_stop "$label" "$rep" at-warmup "REFUSED $label rep $rep at its warm-up: gate S: $why"
  fi
  say "  warm-up passed W; last warm-up iteration $(cat "$OUT/warmup-boundary-$label-$rep.txt")"
}

# Records a refused instrument-validation cell as an outcome, then ends the run with $4 as its message.
#
# The run stops on every one of these refusals, and session 2's stopped before its refused cell had a timing row,
# so the accounting read that cell's outputs as strays (stray-cell-outputs 0 != 6) instead of as a refused cell.
# $3 is where the cell was refused, because what it leaves on disk differs: before-replay leaves no cell output,
# at-warmup leaves its port-forward log, and after-replay leaves all four and both metrics phases.
# cell-refused-<label>-<rep>.txt is per cell and not refused-<arm>.txt, because benchharness report reads the
# latter as a sharing arm's registered refusal, and these end the session rather than stand beside other arms.
#
# Session 4 also keeps the engine log of a cell refused at its warm-up and hands the cell to the per-cell upload.
# Session 3's refused cell had no engine log, and fail reaches only the end-of-run archive, which a stopped instance never writes.
# A log that could not be kept is named in the message rather than ending the stop early, because the refusal is the finding.
cell_refused_stop() {
  local label="$1" rep="$2" stage="$3" msg="$4" upload="${5:-}" t1 kept=0 why
  if [ "$stage" = at-warmup ] && iv_keeps_warmup_refusal_log "${STUDY:-}"; then
    kept=1
    why=$(warmup_refusal_log "$label" "$rep") || msg="$msg [engine log: ${why:-warmup_refusal_log failed without saying why}]"
  fi
  printf '%s\n' "$msg" > "$OUT/cell-refused-$label-$rep.txt" \
    || say "  WARNING: could not write $OUT/cell-refused-$label-$rep.txt"
  t1=$(date +%s)
  cell_secs=$(( cell_secs + t1 - ${CELL_T0:-$t1} ))
  cells_done=$(( cells_done + 1 ))
  cell_timing_record "$label" "$rep" "refused-$stage" "${CELL_T0:-}" "$t1" || true
  # After the timing row, so the upload carries the row that names this cell's outcome.
  # The raw path is the measured one the hook expects; it does not exist yet, and the hook sends only what does.
  # A fifth argument "upload" asks for the same, for a refusal after the cell's evidence was captured.
  if { [ "$kept" = 1 ] || [ "$upload" = upload ]; } && [ -n "${CELL_DONE_HOOK:-}" ]; then
    local hook_t0
    hook_t0=$(date +%s)
    OUT="$OUT" timeout "${CELL_DONE_HOOK_TIMEOUT:-120}" "$CELL_DONE_HOOK" "$OUT/raw-$label-$rep.jsonl" "$label" "$rep" \
      || say "  WARNING: CELL_DONE_HOOK failed or timed out for $label rep $rep's refused cell; its files are still on local disk"
    # The pilot's upload record, as a completed cell writes it after its hook, so the stopped cell's time is
    # whole in the final archive (review of bdb92fa).
    if [ "$upload" = upload ]; then
      [ -s "$OUT/cell-uploads.tsv" ] || printf 'cell\tarm\trep\thook_start_utc\thook_end_utc\thook_s\n' > "$OUT/cell-uploads.tsv"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${cell_n:-}" "$label" "$rep" "$(date -u -d "@$hook_t0" +%Y-%m-%dT%H:%M:%SZ)" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( $(date +%s) - hook_t0 ))" >> "$OUT/cell-uploads.tsv"
    fi
  fi
  fail "$msg"
}

# Saves the engine log of a cell refused at its warm-up to $OUT/engine-log-<label>-<rep>.txt, unjudged.
#
# The cell is already refused, so the log is evidence for the refusal rather than a measurement to accept or refuse.
# A restarted container is named but its log is still kept: `kubectl logs` then returns the newest instance only.
# Prints why and returns 1 when the log is missing or partial; prints nothing and returns 0 when it was kept whole.
warmup_refusal_log() {
  local label="$1" rep="$2" dest err restarts
  dest="$OUT/engine-log-$label-$rep.txt"
  err="$WORK/engine-log-$label-$rep.err"
  if ! k logs -n "$NS_A" deploy/vllm-qwen25-3b >"$dest" 2>"$err"; then
    rm -f "$dest"
    echo "could not read the engine log for $label rep $rep: $(tr '\n' ' ' <"$err" | cut -c1-200)"
    return 1
  fi
  if ! restarts=$(k get pods -n "$NS_A" -l app.kubernetes.io/component=vllm \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}' 2>"$err"); then
    echo "kept $dest, but the engine pod's restart count could not be read, so whether it covers the whole cell is unknown: $(tr '\n' ' ' <"$err" | cut -c1-200)"
    return 1
  fi
  [ "$restarts" = "0 " ] || {
    echo "kept $dest, but the engine pod's restart counts read ${restarts:-nothing}, not one pod at 0, so it covers the newest container only"
    return 1; }
  rm -f "$err"
}

run_cell() {
  local arm="$1" label="$2" rep="$3" RATE_CELL="$4" NOISY_CELL="$5"
  cell_n=$(( cell_n + 1 ))
  cell_deadline_check || exit 1
  CELL_T0=$(date +%s)
  say "cell $cell_n/$cells_total: $label (rep $rep) at load $RATE_CELL:$NOISY_CELL under $ARRIVALS arrivals"
  if ! deploy_arm "$arm" "$label"; then
    say "skipping the rest of cell $cell_n: $label was refused as a registered outcome, and the arms beside it stand"
    # The time it TOOK to be refused counts too.
    #
    # cells_done went up and cell_secs did not, so the budget divided real elapsed time by a cell count
    # that included cells which contributed none of it -- and the projection for the cells still to come
    # came out low. A refusal is not free: the mps arm spent ten minutes waiting for a device count before
    # declining, which is most of a cell.
    CELL_T1=$(date +%s)
    cell_secs=$(( cell_secs + CELL_T1 - CELL_T0 ))
    cells_done=$(( cells_done + 1 ))
    # The refused cell goes in the timing record TOO, and that is the half a one-sided recorder would miss.
    #
    # It consumed card time and it incremented both counters, so a file written only on the completed path
    # would disagree with the projection that drove the next stop decision -- and the disagreement would
    # read as a measurement error rather than a missing row.
    cell_timing_record "$label" "$rep" refused "$CELL_T0" "$CELL_T1" || true
    # A REFUSED cell gets its environment recorded too, under its own stage word.
    #
    # The first version of this skipped it, on the reasoning that a refused arm never had engines so its
    # environment says nothing. That reasoning is wrong in the direction that matters: what was resident on
    # the card when the arm was refused is a candidate EXPLANATION for the refusal -- a previous cell's
    # process still holding memory is exactly the shape of "the plugin advertised and the kubelet would not
    # allocate". The stage word differs from the completed path's so the two cannot be read as one.
    cell_environment_record "$label" refused
    # `return`, not `continue`: this is a function body and the loop is at the call site.
    #
    # bash prints "continue: only meaningful in a for, while, or until loop" and then CARRIES ON with the
    # next statement -- so a refused cell went on to the port-forward setup it was supposed to skip. The
    # message goes to stderr in the middle of a paid session and the run looks like it obeyed. Reproduced
    # minimally before changing this: the line after `continue` ran, and so did the rest of the function.
    return 0
  fi
  # The card's state for THIS cell, recorded once the engines are up and before any request goes through.
  #
  # Here and not inside deploy_arm, because deploy_arm places one engine on the exclusive branch and two on
  # the split branch: a call in there would leave one row per ENGINE and the per-cell row count would differ
  # by arm. run_cell calls deploy_arm exactly once per cell, so this is the only place that is per cell.
  cell_environment_record "$label" engines-ready
  # The tunnel every request of this cell goes through, replaced between cells and then PROVED.
  #
  # This was `kill $PF_PID` followed immediately by a new port-forward and `sleep 3`. kill does not wait,
  # so the new forward raced the old one's release of 18080, lost, and exited -- and because its output
  # went to /dev/null nothing said so. The replay then sent every request of that cell into a port nothing
  # was listening on and recorded them all with httpStatus 0, which the report describes as a censored
  # tail: a plumbing failure wearing a load failure's name.
  #
  # It alternated, which is the signature. Cell 1 bound cleanly, cell 2 lost the race and died, cell 3
  # found the port free because cell 2's forward was already gone, cell 4 lost it again. Two of four arms
  # produced nothing. hack/test/rehearse-m5c-matrix.sh saw R1 and timeSlicing complete every request while
  # shared and mps completed none; the paid runs never reached a second cell, so it had never been visible.
  # And the kill has to reach KUBECTL, which is why this one line does not go through `k`.
  #
  # `k` is a shell function. Backgrounding a function runs it in a SUBSHELL, and bash only replaces that
  # subshell with the command when it has no traps to run -- this script installs three. So `$!` was the
  # subshell's pid, `kill` killed the subshell, `wait` reaped it and returned, and kubectl went on living
  # as an orphan holding 18080. The fix for the race could not have worked: it was waiting on a process
  # that was never the one holding the port.
  #
  # Measured on 2026-09-12, on a rented card. R1 replayed 3,882 rows cleanly, the `shared` cell asked for
  # the same port and got `bind: address already in use`, and the session ended with one arm of four. It
  # had passed on earlier runs because the old forward usually dies on its own when its target pod is
  # replaced -- usually, which is the word that makes it a race rather than a bug that shows up.
  if [ -n "$PF_PID" ]; then
    # `wait` returns the killed forward's own status, which is never 0 here, and `kill` fails on a forward
    # that already exited. `|| true` on both so that an errexit switched on anywhere above -- as
    # refuse_unfrozen_load once did -- cannot end the run on these lines.
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  # Then PROVE the port is free, rather than assuming the kill above was enough.
  #
  # This is the same rule the readiness probe below follows, applied to the other end: the previous check
  # here assumed its own success, and an assumption is exactly what a race defeats. If something still
  # holds the port after ten seconds, say so with the holder named -- that is a different morning from a
  # gateway that never became ready, and the old message conflated them.
  port_free=0
  for _ in $(seq 1 10); do
    if ! (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null; then port_free=1; break; fi
    sleep 1
  done
  if [ "$port_free" != "1" ]; then
    say "  18080 is still held after the previous cell's forward was killed. What holds it:"
    (ss -lptn 'sport = :18080' 2>/dev/null || lsof -i :18080 2>/dev/null || echo "  (no ss or lsof to ask)") | tee -a "$LOG" >&2
    fail "port 18080 was still in use when $label rep $rep asked for it, so this cell's tunnel could not be built. The previous cell's port-forward outlived the kill that was meant to end it."
  fi
  # stderr is kept, because "why is the tunnel not up" is unanswerable without it.
  kubectl --context "$KCTX" port-forward -n "$NS_A" deploy/gateway 18080:8080 >"$OUT/port-forward-$label-$rep.log" 2>&1 &
  PF_PID=$!
  # Proved rather than slept for. A fixed sleep is a guess about a machine's speed, and the failure it
  # misses is silent.
  # Proved by asking the GATEWAY, not by opening a socket.
  #
  # A TCP connect succeeds the moment kubectl holds the local port, whether or not anything answers at the
  # other end -- so the previous check passed while the pod was still refusing connections. /readyz is the
  # gateway's own answer and is false until its cache has synced.
  pf_up=0
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:18080/readyz" 2>/dev/null; then pf_up=1; break; fi
    kill -0 "$PF_PID" 2>/dev/null || break
    sleep 1
  done
  # There is NO TCP fallback any more, and removing it is the point.
  #
  # It set pf_up=1 when a plain connect to 127.0.0.1:18080 succeeded, which proves only that kubectl holds
  # the local port -- exactly the thing defect 39 established is worthless, because the kubelet holds that
  # socket whether or not the pod behind it answers. Keeping it as a "weaker guarantee" meant a cell could
  # begin against a gateway that was not ready and record every request as transport failure, which the
  # report then describes as a censored tail. The gateway this script deploys serves /readyz and carries a
  # readinessProbe on it, so there is no build here for the fallback to be tolerant of: it could only ever
  # turn a clear refusal into eleven minutes of plumbing errors wearing a workload's name.
  [ "$pf_up" = "1" ] || fail "the gateway never answered /readyz and its port never accepted a connection for $label rep $rep. Every request of this cell would have been recorded with no HTTP status at all, and the report would have called the result a censored tail. See $OUT/port-forward-$label-$rep.log"

  # The arm is the SHARING MODE, and it is now spelled that way in the manifest.
  #
  # It used to be spelled "off" -- the admission vocabulary's name for a disabled guard -- because that was
  # the only arm name the harness would accept here, and the run then had to ship a README telling readers
  # never to run `benchharness report` over its own evidence, since pooling would collapse three topologies
  # into one row. internal/bench now carries a study whose arms ARE the topologies, so the evidence says
  # what it is and the pre-registered readings can be evaluated by the code that was written for them.
  # --model is not optional, and its absence would have been silent until the first request.
  #
  # gen-trace defaults to "llama-3-8b" and writes it into the manifest; replay sends it as the requested
  # model; internal/gateway resolves a backend by matching that name against the InferenceDeployment index
  # in the tenant's target namespace. The routing records this script writes serve Qwen2.5-3B, so every
  # request of every arm would have come back ErrNoRoute -- after both engines had loaded.
  set_load_flags "$RATE_CELL" "$NOISY_CELL"
  cell_duration=$(cell_duration_ms "$label") || fail "$cell_duration"
  # The warm-up, after deploy_arm proved the engine is the arm's and before anything measured is sent.
  # Before the `before` metrics scrape as well, so the engine's counters around the replay cover only it.
  if [ -z "${LADDER:-}" ] && iv_has_warmup "${STUDY:-}"; then
    run_warmup "$label" "$rep"
  fi
  "$WORK/benchharness" gen-trace --seed "$(seed_for_rep "$rep")" --duration-ms "$cell_duration" "${LOAD_FLAGS[@]}" \
    --study "$STUDY" --arm "$label" --model "$MODEL" --gateway-url "http://127.0.0.1:18080" \
    --engine-image "$ENGINE_IMAGE" --gateway-image "$GATEWAY_IMAGE_REF" --gateway-sha "$SOURCE_COMMIT" \
    --gateway-binary-sha256 "$GW_BINARY_SHA" --gateway-base "$GW_BASE" \
    --tokenizer-rev "$MODEL_REVISION" \
    "${PROMPT_FLAGS[@]}" \
    --timeout-ms "$REQUEST_TIMEOUT_MS" \
    --trace-out "$OUT/trace-$label-$rep.jsonl" --manifest-out "$OUT/manifest-$label-$rep.yaml" || fail "gen-trace $label"
  # --require-provenance, now that there is provenance to require.
  #
  # RunManifest has carried gatewaySHA and imageDigests since it was written and nothing ever filled them;
  # the guard that demands them has existed just as long and nothing ever asked for it. A paid run's numbers
  # belong to a build, and after the cluster is gone the manifest is the only place that association lives.
  #
  # A WAIVED run does not ask for it, because there is nothing to ask for: the waiver exists precisely for a
  # tree whose engine cannot be digest-pinned, and demanding provenance from it would be demanding that the
  # rehearsal fail. The waiver cannot reach a paid run -- hack/m5c-gpu-session.sh refuses to pass it -- so
  # the demand is on wherever it matters.
  scrape_engine_metrics "$arm" "$label" "$rep" before
  local idflag=""
  if [ -z "${LADDER:-}" ] && iv_is_study "${STUDY:-}"; then
    idflag=$(iv_request_id_flag "$STUDY" "$label" "$rep" measured) || fail "request ids for $label"
  elif [ -z "${LADDER:-}" ] && pp_is_study "${STUDY:-}"; then
    idflag=$(pp_request_id_flag "$PILOT_STAGE" "$label" "$rep") || fail "request ids for $label"
    pp_phase "$label" "$rep" replay-start
    pp_sidecar_start "$label" "$rep"
    pp_sampler_start "$label" "$rep"
  fi
  "$WORK/benchharness" replay --manifest "$OUT/manifest-$label-$rep.yaml" \
    $PROVENANCE_FLAG ${idflag:+"$idflag"} \
    --target "http://127.0.0.1:18080" \
    --api-keys "premium-1=premium-key,standard-noisy=standard-key" \
    --raw-out "$OUT/raw-$label-$rep.jsonl" || fail "replay $label"
  [ -s "$OUT/raw-$label-$rep.jsonl" ] || fail "no raw evidence for $label rep $rep"
  # The pilot's capture bound runs from the replay's return, before anything else is done (pilot review 11).
  local replay_done_epoch
  replay_done_epoch=$(date +%s)
  pp_sidecar_stop
  pp_sampler_stop
  scrape_engine_metrics "$arm" "$label" "$rep" after
  # The pilot's capture: fence, terminal record, logs, the gateway's record and the priority witness. An
  # ineligible cell goes on to the next arm; an apparatus that was not the registered one stops the pilot below.
  local pilot_stop=""
  if [ -z "${LADDER:-}" ] && pp_is_study "${STUDY:-}"; then
    pp_phase "$label" "$rep" replay-done
    local pc_out pc_rc
    pc_out=$(pp_capture "$label" "$rep" "$replay_done_epoch") && pc_rc=0 || pc_rc=$?
    [ -z "$pc_out" ] || printf '%s\n' "$pc_out" | tee -a "$LOG"
    [ "$pc_rc" != 3 ] || pilot_stop="the engine was not the registered apparatus: $pc_out"
    if [ -z "$pilot_stop" ] && [ -z "${PP_CALIBRATED:-}" ]; then
      local cal_out
      cal_out=$(pp_calibrate) || pilot_stop="the engine does not count the frozen exact tokens: $cal_out"
      PP_CALIBRATED=1
    fi
  fi
  say "  $(wc -l < "$OUT/raw-$label-$rep.jsonl") rows"
  # The engine's own log for this cell, judged before the cell is handed over and refused after it is.
  #
  # Judged here because the hook below uploads what exists, and a refused cell's log is the evidence for the
  # refusal; failing first would leave it on a disk the instance takes with it.
  engine_log_refusal=""
  if [ -z "${LADDER:-}" ] && iv_is_study "${STUDY:-}"; then
    engine_log_refusal=$(capture_engine_log "$label" "$rep") || {
      [ -n "$engine_log_refusal" ] || engine_log_refusal="capture_engine_log refused without saying why"
    }
    # A -step cell without its instrument log measured nothing this study bought it for.
    if [ -z "$engine_log_refusal" ] && [[ "$label" == *-step ]]; then
      engine_log_refusal=$(capture_step_log "$label" "$rep") && engine_log_refusal="" || {
        [ -n "$engine_log_refusal" ] || engine_log_refusal="capture_step_log refused without saying why"
      }
    fi
  fi
  # Session 2's gate S, on this cell, before the next one is bought.
  #
  # A staggered episode whose prefill arrived before every decoder's first token, or after one had finished, is
  # not the registered composition, and the registration stops acquisition on it. The evaluator's own function
  # judges it, so the cell is refused by exactly the rule the verdict will apply; it ran only after the session
  # until a review found that a violation would otherwise have bought every remaining cell.
  # Session 3 also refuses a decoder that did not produce its 512 tokens; iv_stagger_refusal says which.
  if [ -z "$engine_log_refusal" ] && [ -z "${LADDER:-}" ] && iv_has_warmup "${STUDY:-}" && [[ "$label" == stagger-* ]]; then
    if ! s_out=$(iv_stagger_refusal "$STUDY" "$label" "$OUT" "$rep" measured); then
      engine_log_refusal="gate S: ${s_out:-the staggered composition check failed without saying why}"
    fi
  fi
  # This cell is BOUGHT. Hand it to the caller now rather than at the end of the matrix.
  #
  # Everything this script writes goes up as one archive after the whole matrix returns, which is fine for
  # a matrix that fails -- the wrapper still archives what exists -- and worthless for an instance that
  # STOPS. A Spot interruption on the last cell takes every cell before it, and at two repetitions a run
  # is six cells and about ninety minutes of rented card.
  #
  # A hook rather than an uploader, because this script also runs on a local kind cluster in three
  # rehearsals where there is no bucket and nothing to upload to. Unset, nothing happens and the behaviour
  # is exactly what it was. A failing hook does NOT fail the cell: the evidence is already on disk, and a
  # transient S3 error is not a reason to throw away a measurement that was paid for.
  # The pilot writes its timing row BEFORE the hook, so the row leaves the instance with the cell, and the hook's
  # own start and end AFTER it, in cell-uploads.tsv, which the next cell's hook carries (design page, "The arm's
  # timing is complete, in two records"). A row written after the hook could not include the hook, and one written
  # before could not include its end.
  local pilot_timed=""
  if [ -z "${LADDER:-}" ] && pp_is_study "${STUDY:-}"; then
    # A cell already known to stop the pilot is recorded once, as refused, and uploaded with that row: written
    # after the hook, the row stayed on an instance that might not survive to the final archive (review of ffe3047),
    # and written beside a completed row it counted the cell twice (review of 20cbf33).
    [ -z "$pilot_stop" ] \
      || cell_refused_stop "$label" "$rep" after-replay "REFUSED $label rep $rep after its capture: $pilot_stop" upload
    cell_timing_record "$label" "$rep" completed "$CELL_T0" "$(date +%s)" || true
    pilot_timed=1
  fi
  local hook_t0
  hook_t0=$(date +%s)
  if [ -n "${CELL_DONE_HOOK:-}" ]; then
    # BOUNDED, because a hook that hangs costs card time the cell budget has already promised elsewhere.
    #
    # It cannot fail the cell -- the evidence is on local disk either way -- but without a limit a stalled
    # upload blocks every cell behind it until the hard stop, and a merely slow one inflates the next
    # cell's projection and can stop the matrix on a boundary it would otherwise have cleared.
    # OUT travels in the ENVIRONMENT rather than as a fourth argument.
    #
    # The hook needs the output directory to find the cell's manifest and trace and the run's accumulating
    # TSVs, and it could derive it from the raw file's dirname -- but a hook that is handed the directory
    # cannot disagree with the one the matrix is writing to. A fourth positional argument would have been
    # the obvious way and it breaks the recorder in hack/test/rehearse-m5c-matrix.sh, which reads exactly
    # $1 $2 $3; an environment variable leaves every existing hook working unchanged.
    OUT="$OUT" timeout "${CELL_DONE_HOOK_TIMEOUT:-120}" "$CELL_DONE_HOOK" "$OUT/raw-$label-$rep.jsonl" "$label" "$rep" \
      || say "  WARNING: CELL_DONE_HOOK failed or timed out for $label rep $rep; the cell is still on local disk and will go up with the rest"
  fi
  if [ -n "$pilot_timed" ]; then
    [ -s "$OUT/cell-uploads.tsv" ] || printf 'cell\tarm\trep\thook_start_utc\thook_end_utc\thook_s\n' > "$OUT/cell-uploads.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cell_n" "$label" "$rep" "$(date -u -d "@$hook_t0" +%Y-%m-%dT%H:%M:%SZ)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( $(date +%s) - hook_t0 ))" >> "$OUT/cell-uploads.tsv"
  fi
  [ -z "$engine_log_refusal" ] \
    || cell_refused_stop "$label" "$rep" after-replay "REFUSED $label rep $rep after replay: $engine_log_refusal"
  CELL_T1=$(date +%s)
  cell_secs=$(( cell_secs + CELL_T1 - CELL_T0 ))
  cells_done=$(( cells_done + 1 ))
  # Flushed per cell rather than assembled at the end: a matrix that stops on a boundary, or is cut
  # mid-cell, is exactly the run whose per-cell times someone will want afterwards.
  [ -n "$pilot_timed" ] || cell_timing_record "$label" "$rep" completed "$CELL_T0" "$CELL_T1" || true
}

for spec in "${CELLS[@]}"; do
  IFS='|' read -r cell_topology cell_label cell_rep cell_rate cell_weight cell_rung <<<"$spec"
  run_cell "$cell_topology" "$cell_label" "$cell_rep" "$cell_rate" "$cell_weight"
  [ -n "$LADDER" ] || continue
  # The stopping rule is asked of the INSTRUMENT, once both cells of a rung exist.
  #
  # The threshold it compares against lives in internal/bench beside the criterion that defines it. A copy
  # of 139.0 ms in this file would be a second place for the pre-registration's number to be edited, and the
  # pre-registration's whole claim is that the number was fixed before any rung ran.
  [ $(( cell_n % 2 )) -eq 0 ] || continue
  ladder_raws=()
  for f in "$OUT"/raw-rung*.jsonl; do [ -e "$f" ] && ladder_raws+=(--raw "$f"); done
  verdict_out="$OUT/ladder-verdict-rung$cell_rung.txt"
  # The status is captured BESIDE the call, not read back afterwards.
  #
  # This was `if benchharness ladder-verdict ...; then ... fi` followed by `verdict_code=$?`, and $? after an
  # `if` is the IF STATEMENT's status -- which is 0 when the condition failed and no else ran. So a verdict
  # that correctly said STOP and exited 10 reached this script as 0 and fell through to the refusal below,
  # which reported the rung unscorable and ended a paid session at its first stopping point. The verdict file
  # said "LADDER: STOP" the whole time; nothing read it.
  #
  # The rehearsal could not have caught it: a stub answers in milliseconds, so on a free cluster every rung
  # CONTINUEs and this branch never runs. The exit code was pinned in hack/test/check-ladder-refusals.sh --
  # of the COMMAND, not of this script's reading of it. That gap is now closed there too.
  verdict_code=0
  "$WORK/benchharness" ladder-verdict "${ladder_raws[@]}" --rung "$cell_rung" >"$verdict_out" 2>>"$LOG" || verdict_code=$?
  if [ "$verdict_code" -eq 0 ]; then
    grep -qx "LADDER: CONTINUE" "$verdict_out" \
      || fail "ladder-verdict exited 0 for rung $cell_rung without saying CONTINUE. Its exit code and its line disagree, and this script will not guess which one meant to climb. See $verdict_out"
    say "rung $cell_rung: at least one topology still meets the target, so the ladder climbs"
    continue
  fi
  if [ "$verdict_code" -eq 10 ]; then
    grep -qx "LADDER: STOP" "$verdict_out" \
      || fail "ladder-verdict exited 10 for rung $cell_rung without saying STOP. See $verdict_out"
    say "rung $cell_rung: both topologies breached the target, which is the registered stopping point"
    LADDER_STOPPED_AT="$cell_rung"
    # The budget has to learn that the rungs above this one will not be bought.
    #
    # cells_total still counted every planned cell, so after a STOP at rung 1 of a four-rung ladder the
    # deadline projection asked for seven more cells when only the baseline remained -- and would refuse to
    # buy it with twenty minutes in hand. The stopping rule cancelled the purchases; nothing cancelled the
    # estimate of them.
    cells_total=$(( cells_done + 1 ))
    break
  fi
  fail "ladder-verdict could not score rung $cell_rung (exit $verdict_code). The cells it refused are named in $verdict_out and in this run's log; a rung that cannot be scored is not a rung that breached, and climbing past it would build the bracket on it."
done

# The isolated baseline, bought once, at the rung the ladder stopped on.
#
# Without it "the split ran out of capacity" and "one engine of this model on this card ran out of capacity"
# are the same observation. It is one cell because the criterion is an absolute millisecond figure fixed
# before the run, which is what makes a per-rung baseline unnecessary -- see the pre-registration.
if [ -n "$LADDER" ]; then
  # The fallback is the highest rung that HAS CELLS, not the last position in the list.
  #
  # $ladder_rung counts every entry including `skip`, so a ladder ending in a skip made ladder_top name a
  # rung with no cells: the loop below matched nothing, bought no baseline, and the `say` line above it
  # announced a purchase that did not happen. Nothing downstream said so until the session's final check,
  # which is a long way from the decision.
  ladder_planned_top=0
  for spec in "${CELLS[@]}"; do
    IFS='|' read -r _ _ _ _ _ cell_rung <<<"$spec"
    [ "$cell_rung" -le "$ladder_planned_top" ] || ladder_planned_top=$cell_rung
  done
  ladder_top="${LADDER_STOPPED_AT:-$ladder_planned_top}"
  say "buying the isolated baseline at rung $ladder_top, the rung this ladder ended on"
  ladder_baseline_bought=0
  for spec in "${CELLS[@]}"; do
    IFS='|' read -r cell_topology cell_label cell_rep cell_rate cell_weight cell_rung <<<"$spec"
    [ "$cell_rung" = "$ladder_top" ] || continue
    run_cell R1 "$(printf 'rung%02d' "$ladder_top")-R1" 1 "$cell_rate" "$cell_weight"
    ladder_baseline_bought=1
    break
  done
  # A loop that can find nothing must say so. Without this the run ends looking complete and the readings
  # lose the cell that tells a topology's limit apart from this model's on this card.
  [ "$ladder_baseline_bought" = 1 ] \
    || fail "the ladder ended at rung $ladder_top and no cell of that rung is in the plan, so its isolated baseline was never bought. Without it, 'the split ran out of capacity' and 'one engine ran out of capacity' are the same observation"
fi


# The raw files are NOT report inputs, and saying so here is cheaper than the confusion. Both arms replay
# with --arm off, because the harness's arm vocabulary is the ADMISSION arms and the sharing mode is this
# run's variable; feeding both files to `benchharness report` would pool them into one arm and produce a
# number for a comparison that was never made.
cat > "$OUT/README.txt" <<EOF
Raw evidence from the M5-c sharing matrix.

The variable is the SHARING MODE, and every row now carries it as its arm: R1, shared, timeSlicing or mps,
under study sharing-matrix-2026-09-10. Admission was off in every arm, which is a constant of this run
rather than its variable, so it is not what the arm field names.

  for f in $OUT/raw-*.jsonl; do args="\$args --raw \$f"; done; benchharness report \$args

The study is read from the evidence rows themselves, not passed as a flag, so the arm names above are what
select the readings. That evaluates the pre-registered readings from
docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md, in the registered order, and
prints the first that fires. Do not evaluate them by hand: a run whose readings are read off a table by a
person is not the instrument the pre-registration describes.

This file used to say the opposite -- that these files must never be passed to \`benchharness report\` --
because every arm was replayed as "off" and pooling would have collapsed three topologies into one row.

EACH ROW NOW CARRIES WHY THE ENGINE STOPPED, and the silences are not pooled.

  finishReason   the engine's own word: "length" when the output cap cut the response, "stop" when the
                 model ended on its own. Added 2026-10-03, and added because it was being DISCARDED: the
                 engine had been sending it on the final SSE frame all along and the parser declared only
                 the content delta, so a run whose cap truncated every answer and one whose model finished
                 early left identical rows. The output cap is one of the five load quantities this study
                 freezes, which made "the cap was not reached" unsupportable in either direction.

Read the absence of the field as its own fact. The report counts three things separately and they license
different sentences: rows that named a reason, rows that answered 200 and named none (a gap in the
instrument), and rows with no successful response at all (unobservable). An empty reason is NOT a stop.

WHAT THE TIMEOUT BOUNDS, and how to tell its two expiries apart in these rows.

The manifest now carries timeoutScope beside timeoutMs. The budget covers the WHOLE request -- connection,
TLS, headers and the entire stream -- so timeoutMs is not a first-token budget, and a response that starts
in time and then stalls expires as well. Both expiries write errorKind "timeout", and one field separates
them:

  firstTokenUnixNanos = 0   nothing arrived before the deadline; httpStatus is 0 too
  firstTokenUnixNanos > 0   the stream stalled mid-response, and the token that did arrive is kept

So "no request was censored by the timeout" needs both the count of timeout rows AND the scope named. An
empty timeoutScope means the manifest predates the field, which is not the same as having no scope.

TWO FILES BESIDE THE ROWS ANSWER "was the budget judgement made on a sane number".

  cell-timings.tsv     one row per cell, completed AND refused, with its own elapsed seconds
  cell-judgements.tsv  one row per deadline boundary, including the ones that CONTINUED

Added 2026-10-03, and added because they were missing: the fifteen-cell run's per-cell duration is nowhere
in its archive, so the 11.61 min/cell figure this project published had to be back-computed from raw request
timestamps. cell_secs is a running total for the projection and nothing wrote the parts.

Read them together. A judgement row carries the remaining minutes, the basis it projected from, the
projected figure and the decision, so a stop can be re-examined against the cell times that produced it.
A refused cell is in the timing file too: it consumed card time and the projection counted it, so a file
that omitted refusals would disagree with the arithmetic that drove the next decision.

Neither file says the judgement was CORRECT. It says the judgement can now be re-examined.
EOF

# The expected-versus-actual comparison is NOT written here any more.
#
# record_expected_files runs from cleanup, which every exit passes through -- the deadline stop, `fail`, and
# the signals. Writing it here as well would count a file that the cleanup pass then rewrites, and would
# leave the short runs, the only ones where the comparison means anything, without one.
say "MATRIX DONE. Raw evidence in $OUT (see its README.txt before analysing)."
say "The comparison is premium TTFT p99 across the sharing modes at equal offered load."
say "Per-engine GPU utilisation is deliberately absent: under time-slicing nothing can attribute it."

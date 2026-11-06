#!/usr/bin/env bash
# Checks the guards hack/lib/spot-run.sh puts in front of every Spot launch, against a stub aws: the account the
# credentials belong to, credentials in the environment, and the study-deadline tag the termination sweeper reads
# (gpt-6-astra's review of 116092ef, r5 findings 4 and 8).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
case "$1 $2" in
  "sts get-caller-identity") echo "${STUB_ACCOUNT:-007635145730}" ;;
  "ec2 run-instances") echo i-0stub ;;
esac
EOF
chmod +x "$work/bin/aws"
export CALLS="$work/calls"
# guard NAME CODE...: runs CODE with the library sourced and the stub first on PATH, the environment's credentials
# removed unless CODE sets them, and prints its output and status.
guard() {
  : >"$CALLS"
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN PATH="$work/bin:$PATH" bash -c \
    '. hack/lib/spot-run.sh; '"$1"'; echo "rc=$?"' 2>&1
}
future="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
past="$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)"
tags="ResourceType=instance,Tags=[{Key=Name,Value=x},{Key=purpose,Value=y}]"

out="$(guard 'spot_account')"
[[ "$out" == "007635145730rc=0" ]] && ok "the lab account is accepted" || bad "the lab account: $out"
out="$(STUB_ACCOUNT=123456789012 guard 'spot_account')"
[[ "$out" == *"account 123456789012; paid runs launch only in gpu-lab"*"rc=1" ]] && ok "another account is refused" || bad "another account: $out"
out="$(guard 'AWS_ACCESS_KEY_ID=AKIASTUB spot_account')"
if [[ "$out" == *"AWS_ACCESS_KEY_ID is set in the environment"*"rc=1" ]] && ! grep -q sts "$CALLS"; then
  ok "credentials in the environment are refused before anything is asked"
else
  bad "credentials in the environment: $out"
fi

for c in "ap-northeast-2|$tags|no study-deadline tag" \
  "us-east-1|${tags%]},{Key=study-deadline,Value=$future}]|watches only ap-northeast-2" \
  "ap-northeast-2|${tags%]},{Key=study-deadline,Value=$past}]|not a zoned ISO-8601 time in the future" \
  "ap-northeast-2|${tags%]},{Key=study-deadline,Value=2099-01-01T00:00:00}]|not a zoned ISO-8601 time in the future" \
  "ap-northeast-2|${tags%]},{Key=study-deadline,Value=$future}]|"; do
  IFS='|' read -r region t want <<<"$c"
  out="$(guard "spot_deadline_refusal $region '$t'")"
  if [[ -z "$want" ]]; then
    [[ "$out" == "rc=0" ]] && ok "a future zoned deadline in $region is accepted" || bad "the accepted deadline: $out"
  elif [[ "$out" == *"$want"*"rc=1" ]]; then
    ok "refused: $want"
  else
    bad "wanted '$want': $out"
  fi
done

# The launch itself refuses, and never reaches run-instances, without the tag; with it, it launches.
out="$(guard "spot_launch ap-northeast-2 ami-0 g5.xlarge subnet-0 prof 0.8 100 /dev/null '$tags' tok")"
if [[ "$out" == *"refusing the launch: the launch carries no study-deadline tag"*"rc=1" ]] && ! grep -q run-instances "$CALLS"; then
  ok "spot_launch refuses a launch without a study-deadline and asks nothing"
else
  bad "spot_launch without a deadline: $out, calls: $(cat "$CALLS")"
fi
out="$(guard "spot_launch ap-northeast-2 ami-0 g5.xlarge subnet-0 prof 0.8 100 /dev/null \"\$(spot_tags_with_deadline '$tags' 3600)\" tok")"
if [[ "$out" == $'i-0stub\nrc=0' ]] && grep -q 'run-instances .*{Key=purpose,Value=y},{Key=study-deadline,Value=20[0-9-]*T[0-9:]*Z}]' "$CALLS"; then
  ok "spot_tags_with_deadline adds a deadline inside the tag list, and the launch goes ahead"
else
  bad "the launch with a deadline: $out, calls: $(cat "$CALLS")"
fi
kept="$(guard "spot_tags_with_deadline '${tags%]},{Key=study-deadline,Value=$future}]' 60")"
[[ "$kept" == "${tags%]},{Key=study-deadline,Value=$future}]rc=0" ]] && ok "a deadline the runner set is kept" || bad "the runner's deadline: $kept"

# Every runner that launches through spot_launch passes a deadline, its own or one added at the launch.
for f in $(grep -l 'IID=$(spot_launch' hack/*.sh hack/holdcap-conformance/*.sh); do
  if grep -A1 'IID=$(spot_launch' "$f" | grep -q 'spot_tags_with_deadline\|study-deadline' ||
    grep -q 'Key=study-deadline,Value=\$' "$f"; then
    ok "$f passes a study-deadline"
  else
    bad "$f launches without a study-deadline"
  fi
done

if ((fails == 0)); then echo "check-spot-run-guards: all checks passed"; else echo "check-spot-run-guards: $fails check(s) failed"; exit 1; fi

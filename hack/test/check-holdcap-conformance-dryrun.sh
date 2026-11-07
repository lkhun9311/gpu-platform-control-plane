#!/usr/bin/env bash
#
# Checks that hack/holdcap-conformance/session.sh with DRY_RUN=1 changes nothing in the account, with aws, git and go
# replaced by recording stubs, without credentials or money.
#
#   bash hack/test/check-holdcap-conformance-dryrun.sh
#
# The dry run used to ensure the results bucket and the instance profile before its stop, so in an account without them
# it created an S3 bucket, a lifecycle rule, an IAM role and an instance profile (review r6, 2026-11-07).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# aws: every call is recorded; reads answer as for an account that has neither the bucket nor the profile.
cat > "$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
case "$1 $2" in
  "sts get-caller-identity") echo 007635145730 ;;
  "ssm get-parameter") echo ami-00000000000000000 ;;
  "ec2 describe-instance-type-offerings") echo ap-northeast-2a ;;
  "s3api head-bucket"|"iam get-instance-profile") exit 254 ;;
  *) exit 0 ;;
esac
EOF
# git: the checkout is clean and HEAD is fixed, so the script's provenance checks pass without a commit.
cat > "$work/bin/git" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "rev-parse --show-toplevel") echo "$ROOT" ;;
  "rev-parse HEAD") echo 0000000000000000000000000000000000000000 ;;
  "status --porcelain") : ;;
  "archive --format=tar.gz") out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done; echo stub > "\$out" ;;
  *) exit 1 ;;
esac
EOF
# go: the manager binary only has to exist for its checksum.
cat > "$work/bin/go" <<'EOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
echo stub > "$out"
EOF
chmod +x "$work/bin/aws" "$work/bin/git" "$work/bin/go"

export CALLS="$work/calls"
: > "$CALLS"
# The stub answers as the lab account, and environment credentials are dropped, because spot_account refuses any other
# account and any key in the environment; a CI runner with OIDC credentials exported would otherwise fail this for that.
out=$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN PATH="$work/bin:$PATH" AWS_PROFILE=gpu-lab DRY_RUN=1 OUT="$work/out" bash hack/holdcap-conformance/session.sh 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'DRY_RUN: nothing created' <<<"$out"; then
  ok "the dry run reaches its stop"
else
  bad "the dry run exited $rc: $(tail -3 <<<"$out")"
fi
# A call that is not a read is a change to the account.
mutating=$(grep -vE '^aws (sts get-caller-identity|ssm get-parameter|ec2 describe-|s3api head-bucket|iam get-)' "$CALLS")
if [ -z "$mutating" ]; then
  ok "the dry run made only read calls ($(wc -l < "$CALLS") of them)"
else
  bad "the dry run changed the account: $mutating"
fi
# The check above must be able to see a mutating call, or its silence means nothing.
if grep -q '^aws s3api head-bucket' "$CALLS"; then
  bad "the dry run still asked for the bucket, which only the ensure step does"
else
  ok "nothing on the way to the stop asks for the bucket"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"

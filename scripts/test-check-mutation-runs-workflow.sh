#!/bin/sh
# Tests of the check of the bulk mutation runs' workflow
# (scripts/check-mutation-runs-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-mutation-runs-workflow.sh
#
# The ${{ ... }} below is the workflow's own syntax, which the shell must
# leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/mutation-runs.yml

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# check <name>: runs the check on the copy, its output into $tmp/<name>.out
# and its exit status into $tmp/<name>.status.
check() {
  status=0
  scripts/check-mutation-runs-workflow.sh "$tmp/mutation-runs.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/mutation-runs.yml"
  yq --inplace "$expression" "$tmp/mutation-runs.yml"
  check "$name"
  if [ "$(cat "$tmp/$name.status")" != 1 ]; then
    fail "$name: exits with $(cat "$tmp/$name.status"), not 1: $(cat "$tmp/$name.out")"
    return
  fi
  for message in "$@"; do
    if grep -qF -- "$message" "$tmp/$name.out"; then
      pass "$name: says \"$message\""
    else
      fail "$name: does not say \"$message\" but: $(cat "$tmp/$name.out")"
    fi
  done
}

# --- The workflow as it is ---------------------------------------------------

cp "$workflow" "$tmp/mutation-runs.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

status=0
scripts/check-mutation-runs-workflow.sh "$tmp/no-such-file.yml" >"$tmp/missing.out" 2>&1 || status=$?
if [ "$status" = 1 ] && grep -qF "no-such-file.yml does not exist" "$tmp/missing.out"; then
  pass "missing: a workflow that does not exist is refused"
else
  fail "missing: exits with $status: $(cat "$tmp/missing.out")"
fi

# --- Only by hand ---------------------------------------------------------------

refuses on-push \
  '.on.push = {}' \
  "it should run only when started by hand (workflow_dispatch), not on: push workflow_dispatch"

refuses on-pull-requests-only \
  '.on = "pull_request"' \
  "it should run only when started by hand (workflow_dispatch), not on: pull_request"

# --- What a run takes ------------------------------------------------------------

refuses a-mode-missing \
  '.on.workflow_dispatch.inputs.mode.options |= map(select(. != "body"))' \
  "its input mode should offer the modes body, list, matrix, packages, sample, timing, not: list, matrix, packages, sample, timing"

refuses no-width \
  'del(.on.workflow_dispatch.inputs.width)' \
  "it should take the width as an input whose default is 20, the account's concurrent jobs"

refuses a-narrower-default-width \
  '.on.workflow_dispatch.inputs.width.default = 10' \
  "it should take the width as an input whose default is 20, the account's concurrent jobs"

refuses an-input-left-out \
  '(.jobs.plan.steps[] | select(.id == "plan") | .run) |= sub("--seed [^ ]+ "; "")' \
  "the plan should pass the input seed to scripts/mutation/bulk.py plan as --seed"

# --- Read-only, and no secrets ---------------------------------------------------

refuses write-permission \
  '.permissions.contents = "write"' \
  "its permissions should be read-only"

refuses no-permissions \
  'del(.permissions)' \
  "its permissions should be read-only"

refuses a-job-that-writes \
  '.jobs.finish.permissions.issues = "write"' \
  "its permissions should be read-only"

refuses a-secret \
  '.jobs.shard.steps[1].env = {"TOKEN": "${{ secrets.GITHUB_TOKEN }}"}' \
  "it should use no secrets"

refuses a-job-that-goes-on-after-an-error \
  '.jobs.shard."continue-on-error" = true' \
  "job shard should not continue on error"

# --- The plan --------------------------------------------------------------------

refuses no-plan \
  'del(.jobs.plan.steps[] | select(.id == "plan"))' \
  "it should plan the run (scripts/mutation/bulk.py plan) in one job, not in: nothing"

refuses a-plan-not-kept \
  'del(.jobs.plan.steps[] | select(.uses == "actions/upload-artifact@v7"))' \
  "job plan should keep the plan as the artifact mutation-plan"

refuses no-shards-out-of-the-plan \
  'del(.jobs.plan.outputs.shards)' \
  "job plan should give the plan step's outputs shards and width"

# --- The shards ------------------------------------------------------------------

refuses no-shards \
  'del(.jobs.shard)' \
  "it should run the shards (scripts/mutation/bulk.py shard) in one job, not in: nothing"

refuses shards-of-another-matrix \
  '.jobs.shard.strategy.matrix = {"include": [{"name": "1-of-1"}]}' \
  "job shard should take its matrix from the plan: include: \${{ fromJSON(needs.plan.outputs.shards) }}"

refuses shards-all-at-once \
  'del(.jobs.shard.strategy."max-parallel")' \
  "job shard should run at most the plan's width at once: max-parallel: \${{ fromJSON(needs.plan.outputs.width) }}"

refuses one-failed-shard-cancels-the-others \
  'del(.jobs.shard.strategy."fail-fast")' \
  "job shard should let every shard end when one fails (fail-fast: false)"

refuses shards-on-arm64 \
  '.jobs.shard."runs-on" = "ubuntu-24.04-arm"' \
  "job shard should run on an amd64 runner (ubuntu-24.04), where native verdicts decide, not on: ubuntu-24.04-arm"

refuses shards-on-a-runner-the-matrix-chooses \
  '.jobs.shard."runs-on" = "${{ matrix.runner }}"' \
  "job shard should run on an amd64 runner (ubuntu-24.04), where native verdicts decide, not on: \${{ matrix.runner }}"

refuses a-native-setup-for-arm64 \
  '(.jobs.shard.steps[] | select(.uses == "./.github/actions/native-setup") | .with.machine) = "aarch64"' \
  "job shard should set up the native build for x86_64 (./.github/actions/native-setup)"

refuses longer-than-a-job-may-run \
  '.jobs.shard."timeout-minutes" = 720' \
  "job shard should stop within the 360 minutes a job may run (timeout-minutes), not after: 720"

refuses no-time-limit \
  'del(.jobs.shard."timeout-minutes")' \
  "job shard should stop within the 360 minutes a job may run (timeout-minutes), not after: none"

refuses a-shard-not-kept-when-it-fails \
  'del(.jobs.shard.steps[] | select(.uses == "actions/upload-artifact@v7") | .if)' \
  "job shard should keep its output as an artifact with if: always()"

refuses a-shard-without-the-plan \
  'del(.jobs.shard.needs)' \
  "job shard should need the plan"

# --- The finish ------------------------------------------------------------------

refuses no-finish \
  'del(.jobs.finish)' \
  "it should merge the shards (scripts/mutation/bulk.py finish) in one job, not in: nothing"

refuses a-finish-before-the-shards \
  '.jobs.finish.needs = ["plan"]' \
  "job finish should need the shards"

refuses a-finish-only-when-every-shard-passed \
  'del(.jobs.finish.if)' \
  "job finish should run also when a shard failed: if: \${{ !cancelled() && ... }}"

refuses a-report-not-kept \
  'del(.jobs.finish.steps[] | select(.uses == "actions/upload-artifact@v7"))' \
  "job finish should keep the report as the artifact mutation-report, also when the merge fails"

echo
echo "test-check-mutation-runs-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

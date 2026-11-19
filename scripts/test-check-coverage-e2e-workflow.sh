#!/bin/sh
# Tests of the check of the e2e coverage workflow
# (scripts/check-coverage-e2e-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-coverage-e2e-workflow.sh
#
# The ${{ ... }} below is the workflow's own syntax, which the shell must
# leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/coverage-e2e.yml

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
  scripts/check-coverage-e2e-workflow.sh "$tmp/coverage-e2e.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/coverage-e2e.yml"
  yq --inplace "$expression" "$tmp/coverage-e2e.yml"
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

cp "$workflow" "$tmp/coverage-e2e.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

status=0
scripts/check-coverage-e2e-workflow.sh "$tmp/no-such-file.yml" >"$tmp/missing.out" 2>&1 || status=$?
if [ "$status" = 1 ] && grep -qF "no-such-file.yml does not exist" "$tmp/missing.out"; then
  pass "missing: a workflow that does not exist is refused"
else
  fail "missing: exits with $status: $(cat "$tmp/missing.out")"
fi

# --- Only by hand, or from the weekly run ------------------------------------------

refuses on-push \
  '.on.push = {}' \
  "it should run only when started by hand (workflow_dispatch) or called by the weekly mutation run (workflow_call), not on: push workflow_call workflow_dispatch"

refuses on-a-schedule-of-its-own \
  '.on.schedule = [{"cron": "23 20 * * 5"}]' \
  "it should run only when started by hand (workflow_dispatch) or called by the weekly mutation run (workflow_call), not on: schedule workflow_call workflow_dispatch"

refuses on-pull-requests-only \
  '.on = "pull_request"' \
  "it should run only when started by hand (workflow_dispatch) or called by the weekly mutation run (workflow_call), not on: pull_request"

refuses not-callable-by-the-weekly-run \
  'del(.on.workflow_call)' \
  "it should run only when started by hand (workflow_dispatch) or called by the weekly mutation run (workflow_call), not on: workflow_dispatch"

refuses not-by-hand \
  'del(.on.workflow_dispatch)' \
  "it should run only when started by hand (workflow_dispatch) or called by the weekly mutation run (workflow_call), not on: workflow_call"

# --- Read-only, no secrets, no error passed over -----------------------------------

refuses write-permission \
  '.permissions.contents = "write"' \
  "its permissions should be read-only"

refuses no-permissions \
  'del(.permissions)' \
  "its permissions should be read-only"

refuses a-job-that-writes \
  '.jobs."coverage-e2e".permissions = {"contents": "read", "issues": "write"}' \
  "its permissions should be read-only"

refuses a-secret \
  '.jobs."coverage-e2e".steps[2].env = {"TOKEN": "${{ secrets.GITHUB_TOKEN }}"}' \
  "it should use no secrets"

refuses a-job-that-goes-on-after-an-error \
  '.jobs."coverage-e2e"."continue-on-error" = true' \
  "job coverage-e2e should not continue on error"

refuses a-step-that-goes-on-after-an-error \
  '.jobs."coverage-e2e".steps[2]."continue-on-error" = true' \
  "a step of job coverage-e2e should not continue on error"

# --- The run, on amd64 ---------------------------------------------------------------

refuses no-report \
  'del(.jobs."coverage-e2e".steps[] | select((.run // "") | test("coverage-e2e.sh")))' \
  "it should run scripts/coverage-e2e.sh in one job, not in: nothing"

refuses a-second-job \
  '.jobs.again = .jobs."coverage-e2e"' \
  "it should run scripts/coverage-e2e.sh in one job, not in: coverage-e2e, again"

refuses the-report-twice \
  '.jobs."coverage-e2e".steps += [{"run": "scripts/coverage-e2e.sh --out again"}]' \
  "job coverage-e2e should run scripts/coverage-e2e.sh once, not 2 times"

refuses on-arm64 \
  '.jobs."coverage-e2e"."runs-on" = "ubuntu-24.04-arm"' \
  "job coverage-e2e should run on an amd64 runner (ubuntu-24.04), not on: ubuntu-24.04-arm"

refuses a-native-setup-for-arm64 \
  '(.jobs."coverage-e2e".steps[] | select(.uses == "./.github/actions/native-setup") | .with.machine) = "aarch64"' \
  "job coverage-e2e should set up the native build for x86_64 (./.github/actions/native-setup)"

refuses no-native-setup \
  'del(.jobs."coverage-e2e".steps[] | select(.uses == "./.github/actions/native-setup"))' \
  "job coverage-e2e should set up the native build for x86_64 (./.github/actions/native-setup)"

refuses longer-than-a-job-may-run \
  '.jobs."coverage-e2e"."timeout-minutes" = 720' \
  "job coverage-e2e should stop within the 360 minutes a job may run (timeout-minutes), not after: 720"

refuses no-time-limit \
  'del(.jobs."coverage-e2e"."timeout-minutes")' \
  "job coverage-e2e should stop within the 360 minutes a job may run (timeout-minutes), not after: none"

# --- The report kept -----------------------------------------------------------------

refuses kept-only-on-success \
  'del(.jobs."coverage-e2e".steps[] | select(.uses == "actions/upload-artifact@v7") | .if)' \
  "job coverage-e2e should keep what scripts/coverage-e2e.sh writes as the artifact coverage-e2e, also when a step before failed (if: \${{ !cancelled() }})"

refuses kept-under-another-name \
  '(.jobs."coverage-e2e".steps[] | select(.uses == "actions/upload-artifact@v7") | .with.name) = "report"' \
  "job coverage-e2e should keep what scripts/coverage-e2e.sh writes as the artifact coverage-e2e, also when a step before failed (if: \${{ !cancelled() }})"

refuses not-kept \
  'del(.jobs."coverage-e2e".steps[] | select(.uses == "actions/upload-artifact@v7"))' \
  "job coverage-e2e should keep what scripts/coverage-e2e.sh writes as the artifact coverage-e2e, also when a step before failed (if: \${{ !cancelled() }})"

echo
echo "test-check-coverage-e2e-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

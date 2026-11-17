#!/bin/sh
# Tests of the check of the workflow that measures the tests' costs on CI's
# runners (scripts/check-measure-costs-workflow.sh). The check must pass on
# the workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-measure-costs-workflow.sh
#
# The ${{ ... }} below is the workflow's own syntax, which the shell must
# leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/measure-costs.yml

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
  scripts/check-measure-costs-workflow.sh "$tmp/measure-costs.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/measure-costs.yml"
  yq --inplace "$expression" "$tmp/measure-costs.yml"
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

cp "$workflow" "$tmp/measure-costs.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

status=0
scripts/check-measure-costs-workflow.sh "$tmp/no-such-file.yml" >"$tmp/missing.out" 2>&1 || status=$?
if [ "$status" = 1 ] && grep -qF "no-such-file.yml does not exist" "$tmp/missing.out"; then
  pass "missing: a workflow that does not exist is refused"
else
  fail "missing: exits with $status: $(cat "$tmp/missing.out")"
fi

# --- Only by hand ---------------------------------------------------------------

refuses on-push \
  '.on.push = {}' \
  "it should run only when started by hand (workflow_dispatch), not on: push workflow_dispatch"

refuses on-a-schedule \
  '.on.schedule = [{"cron": "0 3 * * 1"}]' \
  "it should run only when started by hand (workflow_dispatch), not on: schedule workflow_dispatch"

refuses on-pull-requests-only \
  '.on = "pull_request"' \
  "it should run only when started by hand (workflow_dispatch), not on: pull_request"

# --- Read-only, and no secrets ---------------------------------------------------

refuses write-permission \
  '.permissions.contents = "write"' \
  "its permissions should be read-only"

refuses no-permissions \
  'del(.permissions)' \
  "its permissions should be read-only"

refuses a-job-that-writes \
  '.jobs.measure.permissions = {"contents": "read", "actions": "write"}' \
  "its permissions should be read-only"

refuses a-secret \
  '.jobs.measure.steps[0].env = {"TOKEN": "${{ secrets.GITHUB_TOKEN }}"}' \
  "it should use no secrets"

echo
echo "test-check-measure-costs-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

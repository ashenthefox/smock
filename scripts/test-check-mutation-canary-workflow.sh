#!/bin/sh
# Tests of the check of the mutation canary's workflow
# (scripts/check-mutation-canary-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-mutation-canary-workflow.sh
#
# The ${{ ... }} below is the workflow's own syntax, which the shell must
# leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/mutation-canary.yml

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
  scripts/check-mutation-canary-workflow.sh "$tmp/mutation-canary.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/mutation-canary.yml"
  yq --inplace "$expression" "$tmp/mutation-canary.yml"
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

cp "$workflow" "$tmp/mutation-canary.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

status=0
scripts/check-mutation-canary-workflow.sh "$tmp/no-such-file.yml" >"$tmp/missing.out" 2>&1 || status=$?
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
  '.jobs.canary.permissions = {"contents": "read", "issues": "write"}' \
  "its permissions should be read-only"

refuses a-secret \
  '.jobs.canary.steps[1].env = {"TOKEN": "${{ secrets.GITHUB_TOKEN }}"}' \
  "it should use no secrets"

# --- The replay, on the history, with the commit's toolchain ----------------------

refuses no-replay \
  'del(.jobs.canary.steps[] | select((.run // "") | test("canary.py run")))' \
  "it should replay the canary (scripts/mutation/canary.py run)"

refuses a-shallow-checkout \
  'del(.jobs.canary.steps[0].with)' \
  "job canary should check out the whole history (actions/checkout with fetch-depth: 0)"

refuses a-checkout-of-the-last-commits \
  '.jobs.canary.steps[0].with.fetch-depth = 50' \
  "job canary should check out the whole history (actions/checkout with fetch-depth: 0)"

refuses no-install \
  'del(.jobs.canary.steps[] | select((.run // "") | test("canary.py install")))' \
  "job canary should run scripts/mutation/canary.py install, then moon update, then scripts/mutation/canary.py run, not: update, run"

refuses no-update \
  'del(.jobs.canary.steps[] | select(.run == "moon update"))' \
  "job canary should run scripts/mutation/canary.py install, then moon update, then scripts/mutation/canary.py run, not: install, run"

refuses the-install-after-the-replay \
  '.jobs.canary.steps |= ([.[] | select((.run // "") | test("canary.py install") | not)] + [.[] | select((.run // "") | test("canary.py install"))])' \
  "job canary should run scripts/mutation/canary.py install, then moon update, then scripts/mutation/canary.py run, not: update, run, install"

refuses the-toolchain-of-this-commit \
  '(.jobs.canary.steps[] | select((.run // "") | test("canary.py install")) | .run) = "scripts/install-moonbit.sh pinned && python3 scripts/mutation/canary.py install"' \
  "job canary should install only the toolchain the canary's commit pins, but runs scripts/install-moonbit.sh"

# --- The output kept ---------------------------------------------------------------

refuses upload-only-on-success \
  'del(.jobs.canary.steps[] | select(.uses == "actions/upload-artifact@v7") | .if)' \
  "job canary should upload what the replay writes as artifacts with if: always()"

refuses no-upload \
  'del(.jobs.canary.steps[] | select(.uses == "actions/upload-artifact@v7"))' \
  "job canary should upload what the replay writes as artifacts with if: always()"

echo
echo "test-check-mutation-canary-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

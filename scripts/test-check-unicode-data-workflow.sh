#!/bin/sh
# Tests of the check of the Unicode data workflow
# (scripts/check-unicode-data-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong:
# each change would let a hand edit or a stale table go unnoticed, or would
# run the download on every push.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-unicode-data-workflow.sh
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/unicode-data.yml
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
  scripts/check-unicode-data-workflow.sh "$tmp/unicode-data.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each
# message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/unicode-data.yml"
  yq --inplace "$expression" "$tmp/unicode-data.yml"
  if cmp -s "$workflow" "$tmp/unicode-data.yml"; then
    fail "$name: the expression changed nothing"
    return
  fi
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

# --- The workflow as it is -----------------------------------------------------

cp "$workflow" "$tmp/unicode-data.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

# --- When it runs --------------------------------------------------------------

refuses no-schedule \
  'del(.on.schedule)' \
  "it should run on a push, on a pull request, on a weekly schedule and by hand" \
  "not on: pull_request push workflow_dispatch"

# A push or a pull request runs the download only when it changes one of
# the three files that the check reads or that say what it runs.
refuses push-on-every-change \
  'del(.on.push.paths)' \
  "on a push, it should run only when the table, the generator or this workflow changes, and not on a dependabot/** branch"

refuses pull-request-on-every-change \
  'del(.on.pull_request.paths)' \
  "on a pull request, it should run only when the table, the generator or this workflow changes"

refuses push-without-the-table \
  '.on.push.paths -= ["unicode/data.mbt"]' \
  "on a push, it should run only when" \
  '"paths":["scripts/gen-unicode-data.py",".github/workflows/unicode-data.yml"]'

refuses push-without-the-generator \
  '.on.push.paths -= ["scripts/gen-unicode-data.py"]' \
  "on a push, it should run only when"

refuses push-without-the-workflow \
  '.on.push.paths -= [".github/workflows/unicode-data.yml"]' \
  "on a push, it should run only when"

refuses pull-request-without-the-table \
  '.on.pull_request.paths -= ["unicode/data.mbt"]' \
  "on a pull request, it should run only when"

refuses pull-request-without-the-generator \
  '.on.pull_request.paths -= ["scripts/gen-unicode-data.py"]' \
  "on a pull request, it should run only when"

refuses pull-request-without-the-workflow \
  '.on.pull_request.paths -= [".github/workflows/unicode-data.yml"]' \
  "on a pull request, it should run only when"

refuses pull-request-with-ignored-paths \
  '.on.pull_request.paths-ignore = ["unicode/*.mbt"]' \
  "on a pull request, it should run only when"

# Dependabot opens a pull request for each of its branches, and the pull
# request's run checks the same change.
refuses push-on-dependabot-branches \
  'del(.on.push.branches-ignore)' \
  "on a push, it should run only when"

# Once a week: at one minute of one hour, on one day of the week.
refuses schedule-every-day \
  '.on.schedule[0].cron = "23 4 * * *"' \
  "it should run once a week (one schedule at one minute, hour and day of the week)" \
  "not: 23 4 * * *"

refuses schedule-twice-a-week \
  '.on.schedule[0].cron = "23 4 * * 2,5"' \
  "it should run once a week"

refuses schedule-every-hour-of-the-day \
  '.on.schedule[0].cron = "23 * * * 2"' \
  "it should run once a week"

refuses schedule-on-a-day-of-the-month \
  '.on.schedule[0].cron = "23 4 1 * 2"' \
  "it should run once a week"

refuses schedule-in-one-month \
  '.on.schedule[0].cron = "23 4 * 1 2"' \
  "it should run once a week"

refuses two-schedules \
  '.on.schedule += [{"cron": "41 5 * * 5"}]' \
  "it should run once a week" \
  "not: 23 4 * * 2; 41 5 * * 5"

echo
echo "test-check-unicode-data-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

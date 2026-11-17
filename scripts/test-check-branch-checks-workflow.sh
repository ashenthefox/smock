#!/bin/sh
# Tests of the check of the branch checks workflow
# (scripts/check-branch-checks-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong:
# each change would let a branch reach the merge into main without its
# weakening report, or would hold up or skip CI's keeping of main's
# binaries.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-branch-checks-workflow.sh
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/branch-checks.yml
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
  scripts/check-branch-checks-workflow.sh "$tmp/branch-checks.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each
# message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/branch-checks.yml"
  yq --inplace "$expression" "$tmp/branch-checks.yml"
  if cmp -s "$workflow" "$tmp/branch-checks.yml"; then
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

# The job that writes the report, and its steps.
job='.jobs.weakening'
report_step="$job.steps[] | select(.run // \"\" | test(\"weakening-report.py\"))"
upload_step="$job.steps[] | select(.uses // \"\" | test(\"upload-artifact\"))"
checkout_step="$job.steps[] | select(.uses // \"\" | test(\"checkout\"))"

# --- The workflow as it is -----------------------------------------------------

cp "$workflow" "$tmp/branch-checks.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

rm -f "$tmp/branch-checks.yml"
check missing
if [ "$(cat "$tmp/missing.status")" = 1 ] && grep -qF "does not exist" "$tmp/missing.out"; then
  pass "missing: a missing workflow fails"
else
  fail "missing: exits with $(cat "$tmp/missing.status"): $(cat "$tmp/missing.out")"
fi

# --- When it runs --------------------------------------------------------------

refuses pull-request \
  '.on.pull_request = null' \
  "it should run on a push to every branch but main and dependabot/**, and on nothing else"
refuses by-hand \
  '.on.workflow_dispatch = null' \
  "it should run on a push to every branch but main and dependabot/**, and on nothing else"
refuses on-main \
  '.on.push.branches-ignore = ["dependabot/**"]' \
  "it should run on a push to every branch but main and dependabot/**"
refuses on-dependabot \
  '.on.push.branches-ignore = ["main"]' \
  "it should run on a push to every branch but main and dependabot/**"
refuses branches \
  '.on.push = {"branches": ["**"]}' \
  "it should run on a push to every branch but main and dependabot/**"
refuses paths \
  '.on.push.paths = ["scripts/**"]' \
  "it should run on a push to every branch but main and dependabot/**"
refuses tags \
  '.on.push.tags = ["v*"]' \
  "it should run on a push to every branch but main and dependabot/**"
# The maintainer confirmed on 2026-11-17 (#275) that a newer push cancels
# the run of an older one on the same branch, and no other run.
refuses cancels-every-branch \
  '.concurrency.group = "branch-checks"' \
  "it should cancel an older run of the same branch, and no other run"
refuses keeps-older-runs \
  '.concurrency.cancel-in-progress = false' \
  "it should cancel an older run of the same branch, and no other run"

# --- What it runs --------------------------------------------------------------

refuses no-report \
  "del($report_step)" \
  "one job should write the weakening report, with a step that runs python3 scripts/weakening-report.py --base origin/main, not 0"
refuses other-base \
  "($report_step).run |= sub(\"--base origin/main\"; \"--base origin/integration\")" \
  "one step should run python3 scripts/weakening-report.py --base origin/main"
refuses hidden-failure \
  "($report_step).run |= sub(\"origin/main\"; \"origin/main || true\")" \
  "should fail when a command of it fails"
refuses shell \
  "($report_step).shell = \"sh {0}\"" \
  "should not set its shell or working directory"
refuses no-summary \
  "($report_step).run |= sub(\"GITHUB_STEP_SUMMARY\"; \"GITHUB_OUTPUT\")" \
  "the job that writes the report should write it to the job summary"
refuses shallow \
  "del(($checkout_step).with)" \
  "the job that writes the report should check out the whole history (fetch-depth: 0)"
refuses no-artifact \
  "del($upload_step)" \
  "the job that writes the report should keep it as the artifact weakening-report"
refuses other-artifact \
  "($upload_step).with.name = \"report\"" \
  "the job that writes the report should keep it as the artifact weakening-report"
refuses job-condition \
  "$job.if = \"github.ref != 'refs/heads/x'\"" \
  "the job that writes the report should run in every run"
refuses step-condition \
  "($upload_step).if = \"always()\"" \
  "the job that writes the report should run each of its steps in every run"
refuses job-needs \
  "$job.needs = [\"other\"] | .jobs.other = {\"runs-on\": \"ubuntu-24.04\", \"steps\": [{\"run\": \"true\"}]}" \
  "the job that writes the report should need no other job"
refuses slow \
  "$job.timeout-minutes = 30" \
  "the job that writes the report should take seconds, with a timeout of at most 10 minutes"
refuses continues \
  "$job.continue-on-error = true" \
  "job weakening should not continue on error"
refuses step-continues \
  "($report_step).continue-on-error = true" \
  "should not continue on error"

# --- What it may do ------------------------------------------------------------

refuses writes \
  '.permissions.contents = "write"' \
  "its permissions should be read-only"
refuses job-writes \
  "$job.permissions = {\"issues\": \"write\"}" \
  "its permissions should be read-only"
refuses secrets \
  "($report_step).env.TOKEN = \"\${{ secrets.TOKEN }}\"" \
  "it should use no secrets"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

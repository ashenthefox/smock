#!/bin/sh
# Tests of the check of the branch checks workflow
# (scripts/check-branch-checks-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong:
# each change would let a branch reach the merge into main without its
# weakening report or the report of the mutants on its changed lines, or
# with a report that ran them by other rules, or would hold up or skip
# CI's keeping of main's binaries.
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
refuses schedule \
  '.on.schedule = [{"cron": "0 4 * * 1"}]' \
  "it should run on a push to every branch but main and dependabot/**, and on nothing else"
# #311: a diff too large for a push's shards runs whole in a run started by
# hand, on 20 shards unless another number from 1 to 20 is given.
refuses not-by-hand \
  'del(.on.workflow_dispatch)' \
  "it should also run when started by hand (workflow_dispatch), with one input, shards, a number whose default is 20"
refuses other-width \
  '.on.workflow_dispatch.inputs.shards.default = 3' \
  "it should also run when started by hand (workflow_dispatch), with one input, shards, a number whose default is 20"
refuses other-input \
  '.on.workflow_dispatch.inputs.base = {"type": "string"}' \
  "it should also run when started by hand (workflow_dispatch), with one input, shards, a number whose default is 20"
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

# --- The mutants on the changed lines --------------------------------------------

plan_job='.jobs.changed-lines-plan'
plan_step="$plan_job.steps[] | select(.run // \"\" | test(\"changed-lines.py plan\"))"
shard_job='.jobs.changed-lines'
shard_step="$shard_job.steps[] | select(.run // \"\" | test(\"changed-lines.py shard\"))"
report_job='.jobs.changed-lines-report'
changed_report_step="$report_job.steps[] | select(.run // \"\" | test(\"changed-lines.py report\"))"

refuses no-plan \
  "del($plan_step)" \
  "one job should plan the mutants on the changed lines, with a step that runs python3 scripts/changed-lines.py plan, not 0"
refuses plan-other-base \
  "($plan_step).run |= sub(\"--by-hand\"; \"--runner run.py --by-hand\")" \
  "the plan's step should run python3 scripts/changed-lines.py plan --by-hand \"\$BY_HAND\" --out changed-lines-plan >>\"\$GITHUB_OUTPUT\""
refuses plan-not-by-hand \
  "($plan_step).env.BY_HAND = \"5\"" \
  "the plan's step should take the shards of a run started by hand from the input (BY_HAND: \${{ inputs.shards }})"
refuses plan-output \
  "$plan_job.outputs.shards = \"[1]\"" \
  "the plan's job should give the shards that its step plans as its output (shards: \${{ steps.<id>.outputs.shards }})"
refuses plan-shallow \
  "del(($plan_job.steps[] | select(.uses // \"\" | test(\"checkout\"))).with)" \
  "the plan's job should check out the whole history (fetch-depth: 0), to find the merge base with main"
refuses plan-no-moonbit \
  "del($plan_job.steps[] | select(.run // \"\" | test(\"install-moonbit\")))" \
  "the plan's job should install the pinned MoonBit (scripts/install-moonbit.sh pinned) before the plan, for the site finder"
refuses plan-condition \
  "$plan_job.if = \"github.event_name == 'push'\"" \
  "the plan's job should run in every run and need no other job"
refuses plan-artifact \
  "($plan_job.steps[] | select(.uses // \"\" | test(\"upload-artifact\"))).with.name = \"plan\"" \
  "the plan's job should keep the plan as the artifact changed-lines-plan"

refuses no-shard \
  "del($shard_step)" \
  "one job should run the shards of the mutants on the changed lines, with a step that runs python3 scripts/changed-lines.py shard, not 0"
refuses shard-other-runner \
  "($shard_step).run |= sub(\"--plan\"; \"--runner run.py --plan\")" \
  "the shards' step should run python3 scripts/changed-lines.py shard --plan changed-lines-plan --shard \"\$SHARD\" --out changed-lines-shard"
refuses shard-condition \
  "$shard_job.if = \"always()\"" \
  "the shards' job should need the plan's job, run when it planned shards (if: needs.changed-lines-plan.outputs.shards != '[]'), one for each shard it planned"
refuses shard-matrix \
  "$shard_job.strategy.matrix.shard = [1, 2, 3]" \
  "the shards' job should need the plan's job, run when it planned shards (if: needs.changed-lines-plan.outputs.shards != '[]'), one for each shard it planned"
refuses shard-needs \
  "$shard_job.needs = \"weakening\"" \
  "the shards' job should need the plan's job"
refuses shard-not-each \
  "($shard_step).env.SHARD = \"1\"" \
  "the shards' step should run the job's shard (SHARD: \${{ matrix.shard }})"
refuses shard-arm64 \
  "$shard_job.runs-on = \"ubuntu-24.04-arm\"" \
  "the shards' job should run on amd64, where the native verdict decides (runs-on: ubuntu-24.04, and ./.github/actions/native-setup with machine: x86_64)"
refuses shard-machine \
  "($shard_job.steps[] | select(.uses // \"\" | test(\"native-setup\"))).with.machine = \"aarch64\"" \
  "the shards' job should run on amd64, where the native verdict decides"
refuses shard-shallow \
  "del(($shard_job.steps[] | select(.uses // \"\" | test(\"checkout\"))).with)" \
  "the shards' job should check out the whole history (fetch-depth: 0), where the plan's merge base is"
refuses shard-no-plan \
  "del($shard_job.steps[] | select(.uses // \"\" | test(\"download-artifact\")))" \
  "the shards' job should take the plan (the artifact changed-lines-plan) before the shard runs"
refuses shard-artifact \
  "($shard_job.steps[] | select(.uses // \"\" | test(\"upload-artifact\"))).with.name = \"shard\"" \
  "the shards' job should keep each shard's records as the artifact changed-lines-shard-\${{ matrix.shard }}"
refuses shard-fails-fast \
  "$shard_job.strategy.fail-fast = true" \
  "the shards' job should let the other shards finish when one fails (fail-fast: false), so that a failed shard can run again alone"
refuses shard-continues \
  "$shard_job.continue-on-error = true" \
  "job changed-lines should not continue on error"

refuses no-changed-report \
  "del($changed_report_step)" \
  "one job should report the mutants on the changed lines, with a step that runs python3 scripts/changed-lines.py report, not 0"
refuses changed-report-command \
  "($changed_report_step).run |= sub(\"--shards changed-lines-shards \"; \"\")" \
  "the report's step should run python3 scripts/changed-lines.py report --plan changed-lines-plan --shards changed-lines-shards --out changed-lines"
refuses changed-report-no-summary \
  "($changed_report_step).run |= sub(\"GITHUB_STEP_SUMMARY\"; \"GITHUB_OUTPUT\")" \
  "the report's step should write the report to the job summary"
refuses changed-report-needs \
  "$report_job.needs = [\"changed-lines-plan\"]" \
  "the report's job should need the plan's job and the shards' job, and run when the plan passed and the shards passed or did not run"
refuses changed-report-always \
  "$report_job.if = \"\${{ always() }}\"" \
  "the report's job should need the plan's job and the shards' job, and run when the plan passed and the shards passed or did not run"
refuses changed-report-no-shards \
  "del($report_job.steps[] | select(.with.pattern // \"\" | test(\"changed-lines-shard-\")))" \
  "the report's job should take the plan and the shards' records (the artifacts changed-lines-plan and changed-lines-shard-*, into changed-lines-shards)"
refuses changed-report-artifact \
  "($report_job.steps[] | select(.uses // \"\" | test(\"upload-artifact\"))).with.name = \"report\"" \
  "the report's job should keep the report as the artifact changed-lines, for 90 days"
refuses changed-report-kept-shortly \
  "($report_job.steps[] | select(.uses // \"\" | test(\"upload-artifact\"))).with.retention-days = 7" \
  "the report's job should keep the report as the artifact changed-lines, for 90 days"
refuses changed-report-hidden-failure \
  "($changed_report_step).run |= sub(\"--out changed-lines\"; \"--out changed-lines || true\")" \
  "should fail when a command of it fails"

# --- What it may do ------------------------------------------------------------

refuses writes \
  '.permissions.contents = "write"' \
  "its permissions should be read-only"
refuses job-writes \
  "$job.permissions = {\"issues\": \"write\"}" \
  "its permissions should be read-only"
refuses shard-writes \
  "$shard_job.permissions = {\"contents\": \"write\"}" \
  "its permissions should be read-only"
refuses secrets \
  "($report_step).env.TOKEN = \"\${{ secrets.TOKEN }}\"" \
  "it should use no secrets"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

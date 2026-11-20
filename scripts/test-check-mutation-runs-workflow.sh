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

# --- On its schedules and by hand ------------------------------------------------

refuses on-push \
  '.on.push = {}' \
  "it should run only on its schedules and when started by hand (schedule, workflow_dispatch), not on: push schedule workflow_dispatch"

refuses on-pull-requests-only \
  '.on = "pull_request"' \
  "it should run only on its schedules and when started by hand (schedule, workflow_dispatch), not on: pull_request"

refuses no-schedule \
  'del(.on.schedule)' \
  "it should run only on its schedules and when started by hand (schedule, workflow_dispatch), not on: workflow_dispatch"

refuses another-schedule \
  '.on.schedule[0].cron = "17 3 * * 1"' \
  "its schedules should be the weekly run's, 23 20 * * 5, and the monthly run's, 43 22 1 * *, as scripts/mutation/bulk.py's SCHEDULES gives them, not: 17 3 * * 1, 43 22 1 * *"

refuses a-third-schedule \
  '.on.schedule += [{"cron": "0 12 * * 3"}]' \
  "its schedules should be the weekly run's, 23 20 * * 5, and the monthly run's, 43 22 1 * *, as scripts/mutation/bulk.py's SCHEDULES gives them, not: 23 20 * * 5, 43 22 1 * *, 0 12 * * 3"

# --- A run's name says its mode ---------------------------------------------------

# The release check (scripts/check-weekly-run.py, #316) finds the weekly
# runs by their name, "Mutation runs: weekly", whether a schedule or a
# person started them.
run_name_message="it should name each run by its mode, as the release check finds the weekly runs by their names: run-name: \"Mutation runs: \${{ github.event.schedule == '23 20 * * 5' && 'weekly' || github.event.schedule == '43 22 1 * *' && 'monthly' || inputs.mode }}\""

refuses no-run-name \
  'del(."run-name")' \
  "$run_name_message"

refuses a-run-name-without-the-mode \
  '."run-name" = "Mutation runs"' \
  "$run_name_message"

refuses a-run-name-of-another-schedule \
  '."run-name" |= sub("23 20"; "17 3")' \
  "$run_name_message"

refuses a-run-name-that-swaps-the-modes \
  '."run-name" |= sub("'"'"'weekly'"'"'"; "'"'"'monthly'"'"'")' \
  "$run_name_message"

# --- What a run takes ------------------------------------------------------------

refuses a-mode-missing \
  '.on.workflow_dispatch.inputs.mode.options |= map(select(. != "body"))' \
  "its input mode should offer the modes body, list, matrix, monthly, packages, sample, timing, weekly, not: list, matrix, monthly, packages, sample, timing, weekly"

refuses no-monthly-run-by-hand \
  '.on.workflow_dispatch.inputs.mode.options |= map(select(. != "monthly"))' \
  "its input mode should offer the modes body, list, matrix, monthly, packages, sample, timing, weekly, not: body, list, matrix, packages, sample, timing, weekly"

refuses no-width \
  'del(.on.workflow_dispatch.inputs.width)' \
  "it should take the width as an input whose default is 20, the account's concurrent jobs"

refuses a-narrower-default-width \
  '.on.workflow_dispatch.inputs.width.default = 10' \
  "it should take the width as an input whose default is 20, the account's concurrent jobs"

refuses more-mutants-at-once-by-default \
  '.on.workflow_dispatch.inputs.workers.default = 2' \
  "it should take the mutants at once as an input whose default is 1: in the baseline's timing, two at once gained 4% and four lost 5%"

refuses no-mutants-at-once \
  'del(.on.workflow_dispatch.inputs.workers)' \
  "it should take the mutants at once as an input whose default is 1: in the baseline's timing, two at once gained 4% and four lost 5%"

refuses an-input-left-out \
  '(.jobs.plan.steps[] | select(.id == "plan") | .run) |= sub("--seed [^ ]+ "; "")' \
  "the plan should pass the input seed to scripts/mutation/bulk.py plan as --seed"

refuses the-schedule-left-out \
  'del(.jobs.plan.steps[] | select(.id == "plan") | .env.SCHEDULE)' \
  "the plan should pass the schedule that started the run to scripts/mutation/bulk.py plan as --schedule"

refuses no-flake-records \
  'del(.jobs.plan.steps[] | select((.run // "") | test("gh run download")))' \
  "job plan should download the flake records of the latest weekly run (the artifact mutation-flakes) before the plan, and pass them as --flakes"

# --- Read-only but for one job's issues, and no secrets ----------------------------

refuses write-permission \
  '.permissions.contents = "write"' \
  "its permissions should be read-only, but for issues: write in the one job that opens the issue of the stale entries"

refuses no-permissions \
  'del(.permissions)' \
  "its permissions should be read-only, but for issues: write in the one job that opens the issue of the stale entries"

refuses a-second-job-that-writes \
  '.jobs.finish.permissions.issues = "write"' \
  "its permissions should be read-only, but for issues: write in the one job that opens the issue of the stale entries"

refuses the-issue-job-writes-more \
  '.jobs."stale-entries".permissions.contents = "write"' \
  "its permissions should be read-only, but for issues: write in the one job that opens the issue of the stale entries"

refuses the-issue-job-checks-out-the-repository \
  '.jobs."stale-entries".steps = [{"uses": "actions/checkout@v7"}] + .jobs."stale-entries".steps' \
  "job stale-entries writes issues, so it should run nothing of the repository's: no checkout, no script"

refuses the-issue-job-runs-a-script \
  '.jobs."stale-entries".steps += [{"run": "python3 scripts/mutation/bulk.py stale --out x"}]' \
  "job stale-entries writes issues, so it should run nothing of the repository's: no checkout, no script"

refuses the-issue-job-in-every-run \
  'del(.jobs."stale-entries".if)' \
  "job stale-entries should run only in a weekly run that lists stale entries: if: needs.plan.outputs.mode == 'weekly' && needs.plan.outputs.stale != '0' ..."

refuses no-issue-job \
  'del(.jobs."stale-entries")' \
  "it should open the issue of the stale entries (gh issue create) in one job, not in: nothing"

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
  "job plan should give the plan step's outputs shards, width and mode"

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

# --- The weekly run's other jobs and steps ----------------------------------------

refuses no-canary \
  'del(.jobs.canary)' \
  "it should replay the canary in the weekly run, in a job that calls ./.github/workflows/mutation-canary.yml with if: needs.plan.outputs.mode == 'weekly'"

refuses a-canary-in-every-run \
  'del(.jobs.canary.if)' \
  "it should replay the canary in the weekly run, in a job that calls ./.github/workflows/mutation-canary.yml with if: needs.plan.outputs.mode == 'weekly'"

refuses no-coverage-from-e2e \
  'del(.jobs."coverage-e2e")' \
  "it should report the coverage from the e2e tests in the weekly run, in a job that calls ./.github/workflows/coverage-e2e.yml with if: needs.plan.outputs.mode == 'weekly'"

refuses coverage-from-e2e-in-every-run \
  'del(.jobs."coverage-e2e".if)' \
  "it should report the coverage from the e2e tests in the weekly run, in a job that calls ./.github/workflows/coverage-e2e.yml with if: needs.plan.outputs.mode == 'weekly'"

refuses coverage-from-e2e-without-the-plan \
  'del(.jobs."coverage-e2e".needs)' \
  "it should report the coverage from the e2e tests in the weekly run, in a job that calls ./.github/workflows/coverage-e2e.yml with if: needs.plan.outputs.mode == 'weekly'"

refuses no-random-seeds \
  'del(.jobs.seeds)' \
  "it should run the properties with random seeds (scripts/mutation/bulk.py seeds) in one job, not in: nothing"

refuses random-seeds-in-every-run \
  'del(.jobs.seeds.if)' \
  "job seeds should run only in the weekly run: if: needs.plan.outputs.mode == 'weekly'"

refuses random-seeds-in-a-shard \
  '.jobs.shard.steps += [{"run": "python3 scripts/random-seeds.py"}]' \
  "job shard writes random seeds, but the shards and their kill confirmations run the properties with their committed seeds"

refuses random-seeds-not-kept \
  'del(.jobs.seeds.steps[] | select(.uses == "actions/upload-artifact@v7"))' \
  "job seeds should keep the seeds and their results as an artifact with if: always()"

refuses no-site-count-check \
  'del(.jobs.plan.steps[] | select((.run // "") | test("ratchet.py check")))' \
  "job plan should check the site counts (scripts/mutation/ratchet.py check) in the weekly run"

refuses no-stale-entries-listed \
  'del(.jobs.plan.steps[] | select(.id == "stale"))' \
  "job plan should list the stale entries (scripts/mutation/bulk.py stale) in the weekly run, as the step stale whose output the job gives as stale"

refuses no-flake-records-kept \
  'del(.jobs.finish.steps[] | select(.with.name == "mutation-flakes"))' \
  "job finish should keep the weekly run's flake records as the artifact mutation-flakes"

# --- The finish ------------------------------------------------------------------

refuses a-finish-without-the-weekly-jobs \
  '.jobs.finish.needs = ["plan", "shard"]' \
  "job finish should need the canary and the properties with random seeds, so that the report names a failure of theirs"

refuses a-finish-that-waits-for-the-coverage-from-e2e \
  '.jobs.finish.needs += ["coverage-e2e"]' \
  "job finish should not wait for the coverage from the e2e tests, which reports only"

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

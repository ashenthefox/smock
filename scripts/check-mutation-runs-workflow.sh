#!/bin/sh
# Checks the rules of the bulk mutation runs' workflow
# (.github/workflows/mutation-runs.yml, CONTRIBUTING.md, "Bulk runs on
# Actions"):
#
# - it runs on its two schedules, the weekly run's and the monthly run's,
#   as scripts/mutation/bulk.py's SCHEDULES gives them, and when started by
#   hand (workflow_dispatch), so never on pull requests or on pushes: a
#   bulk run holds the account's jobs;
# - it takes the mode (each of bulk.py's, the weekly and the monthly run
#   among them), the packages, the set, the seed, the size, the list, the
#   width, whose default is the account's 20 concurrent jobs, and the
#   mutants at once, whose default is 1, as the baseline's timing measured
#   (CONTRIBUTING.md, "Bulk runs on Actions"), and passes each to the plan,
#   with the schedule that started the run and the flake records of the
#   latest weekly run, which it downloads before the plan;
# - its permissions are read-only but in one job, which opens or comments
#   on the issue of the stale entries: it may write issues and nothing
#   else, checks out nothing, runs no script of the repository's, and runs
#   only in a weekly run that lists stale entries; it uses no secrets, and
#   no job goes on after an error;
# - one job plans the run (bulk.py plan), keeps the plan as the artifact
#   mutation-plan, and gives the shards, the width, the mode and the count
#   of stale entries as outputs; in the weekly run it checks the site
#   counts and lists the stale entries;
# - one job runs the shards (bulk.py shard): it needs the plan, takes its
#   matrix and its max-parallel from the plan's outputs, lets every shard
#   end when one fails, runs on an amd64 runner set up for x86_64, where
#   native verdicts decide, stops within a job's 6 hours, keeps each
#   shard's output, also when the shard fails, and writes no random seed;
# - in the weekly run, a job replays the canary (mutation-canary.yml), and
#   one of its own runs the properties with random seeds (bulk.py seeds)
#   and keeps their seeds and results;
# - one job merges the shards (bulk.py finish): it needs the shards, the
#   canary and the properties with random seeds, runs also when one of
#   them failed, keeps the report as the artifact mutation-report, and, in
#   the weekly run, the flake records as the artifact mutation-flakes.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-mutation-runs-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/mutation-runs.yml}

# The schedules, in the order the workflow gives them: the weekly run's,
# then the monthly run's (bulk.py's SCHEDULES).
schedules="23 20 * * 5, 43 22 1 * *"

failed=0
fail() {
  echo "check-mutation-runs-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-mutation-runs-workflow: $workflow does not exist" >&2
  exit 1
fi
json=$(yq --output-format=json "$workflow")

triggers=$(printf '%s\n' "$json" | jq -r '.on | if type == "object" then keys | join(" ") else tostring end')
[ "$triggers" = "schedule workflow_dispatch" ] ||
  fail "it should run only on its schedules and when started by hand (schedule, workflow_dispatch), not on: $triggers"
if [ "$triggers" = "schedule workflow_dispatch" ]; then
  crons=$(printf '%s\n' "$json" | jq -r '[.on.schedule[]?.cron] | join(", ")')
  [ "$crons" = "$schedules" ] ||
    fail "its schedules should be the weekly run's, 23 20 * * 5, and the monthly run's, 43 22 1 * *, as scripts/mutation/bulk.py's SCHEDULES gives them, not: $crons"
fi

printf '%s\n' "$json" | jq -e '
  def writes: type != "object" or any(.[]; . == "write");
  (.permissions | type == "object" and (writes | not))
  and ([.jobs[] | select(.permissions != null and (.permissions | writes))] as $writers
       | ($writers | length) <= 1 and all($writers[]; .permissions == {"issues": "write"}))' >/dev/null ||
  fail "its permissions should be read-only, but for issues: write in the one job that opens the issue of the stale entries"
if grep -q 'secrets\.' "$workflow"; then
  fail "it should use no secrets"
fi

# What is wrong, one line each.
problems=$(printf '%s\n' "$json" | jq -r '
  def command: (.run // "") | tostring;
  def needs: (.needs // []) | if type == "string" then [.] else . end;
  def jobs_running($pattern): [.jobs | to_entries[] | select(any(.value.steps[]?; command | test($pattern)))];
  def bulk($step): jobs_running("scripts/mutation/bulk\\.py " + $step + "( |$)");
  def always: . == "always()" or . == "${{ always() }}";
  def not_cancelled: test("!cancelled\\(\\)") or always;
  def weekly($plan): (. // "" | tostring) | contains("needs.\($plan).outputs.mode == '"'"'weekly'"'"'");
  def step_weekly: (. // "" | tostring) | contains("steps.plan.outputs.mode == '"'"'weekly'"'"'");
  def uploads($name): any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .with.name == $name);
  def one($jobs; $what):
    if ($jobs | length) == 1 then empty
    else "it should \($what) in one job, not in: \(if ($jobs | length) == 0 then "nothing" else [$jobs[].key] | join(", ") end)" end;
  ((if (.on | type) == "object" then .on.workflow_dispatch.inputs else null end) // {}) as $inputs
  | bulk("plan") as $plans | bulk("shard") as $shards | bulk("finish") as $finishes | bulk("seeds") as $seeds
  | jobs_running("gh issue create") as $issues
  | ($plans[0].key // "plan") as $plan
  | ($shards[0].key // "shard") as $shard
  | ($seeds[0].key // "seeds") as $seed
  | ([.jobs | to_entries[] | select(.value.uses == "./.github/workflows/mutation-canary.yml") | .key][0] // "canary")
    as $canary

  # The inputs.
  | ([$inputs.mode.options[]?] | sort | join(", ")) as $modes
  | (if $modes == "body, list, matrix, monthly, packages, sample, timing, weekly" then empty
     else "its input mode should offer the modes body, list, matrix, monthly, packages, sample, timing, weekly, not: \($modes)" end),
    (if ($inputs.width.default | tostring) == "20" then empty
     else "it should take the width as an input whose default is 20, the account'"'"'s concurrent jobs" end),
    (if ($inputs.workers.default | tostring) == "1" then empty
     else "it should take the mutants at once as an input whose default is 1: in the baseline'"'"'s timing, two at once gained 4% and four lost 5%" end),

  # No job goes on after an error.
    (.jobs | to_entries[] | select(.value["continue-on-error"] != null and .value["continue-on-error"] != false)
     | "job \(.key) should not continue on error"),

  # The plan.
    one($plans; "plan the run (scripts/mutation/bulk.py plan)"),
    ($plans[] | .key as $job | .value
     | ([.steps | to_entries[] | select(.value | command | test("scripts/mutation/bulk\\.py plan"))][0]) as $at
     | $at.value as $step
     | (("mode packages set seed size list width workers" | split(" ")[]) as $input
        | ($input | ascii_upcase) as $variable
        | if (($step.run | tostring) | contains("--\($input) \"$\($variable)\""))
             and (($step.env // {})[$variable] == "${{ inputs.\($input) }}") then empty
          else "the plan should pass the input \($input) to scripts/mutation/bulk.py plan as --\($input)" end),
       (if (($step.run | tostring) | contains("--schedule \"$SCHEDULE\""))
           and (($step.env // {}).SCHEDULE == "${{ github.event.schedule }}") then empty
        else "the plan should pass the schedule that started the run to scripts/mutation/bulk.py plan as --schedule" end),
       (if any(.steps[:$at.key][]; command | test("gh run download") and test("mutation-flakes"))
           and (($step.run | tostring) | contains("--flakes ")) then empty
        else "job \($job) should download the flake records of the latest weekly run (the artifact mutation-flakes) before the plan, and pass them as --flakes" end),
       (if uploads("mutation-plan") then empty else "job \($job) should keep the plan as the artifact mutation-plan" end),
       ($step.id) as $id
       | (if $id != null and .outputs.shards == "${{ steps.\($id).outputs.shards }}"
             and .outputs.width == "${{ steps.\($id).outputs.width }}"
             and .outputs.mode == "${{ steps.\($id).outputs.mode }}" then empty
          else "job \($job) should give the plan step'"'"'s outputs shards, width and mode" end),
         (if any(.steps[]; (command | test("scripts/mutation/ratchet\\.py check")) and (.if | step_weekly)) then empty
          else "job \($job) should check the site counts (scripts/mutation/ratchet.py check) in the weekly run" end),
         (if any(.steps[]; .id == "stale" and (command | test("scripts/mutation/bulk\\.py stale")) and (.if | step_weekly))
             and .outputs.stale == "${{ steps.stale.outputs.stale }}" then empty
          else "job \($job) should list the stale entries (scripts/mutation/bulk.py stale) in the weekly run, as the step stale whose output the job gives as stale" end)),

  # The shards.
    one($shards; "run the shards (scripts/mutation/bulk.py shard)"),
    ($shards[] | .key as $job | .value
     | (if any(needs[]; . == $plan) then empty else "job \($job) should need the plan" end),
       (if .strategy.matrix == {"include": "${{ fromJSON(needs.\($plan).outputs.shards) }}"} then empty
        else "job \($job) should take its matrix from the plan: include: ${{ fromJSON(needs.\($plan).outputs.shards) }}" end),
       (if .strategy["max-parallel"] == "${{ fromJSON(needs.\($plan).outputs.width) }}" then empty
        else "job \($job) should run at most the plan'"'"'s width at once: max-parallel: ${{ fromJSON(needs.\($plan).outputs.width) }}" end),
       (if .strategy["fail-fast"] == false then empty
        else "job \($job) should let every shard end when one fails (fail-fast: false)" end),
       (if .["runs-on"] == "ubuntu-24.04" then empty
        else "job \($job) should run on an amd64 runner (ubuntu-24.04), where native verdicts decide, not on: \(.["runs-on"])" end),
       (if any(.steps[]; .uses == "./.github/actions/native-setup" and .with.machine == "x86_64") then empty
        else "job \($job) should set up the native build for x86_64 (./.github/actions/native-setup)" end),
       (.["timeout-minutes"] as $limit
        | if ($limit | type) == "number" and $limit <= 360 then empty
          else "job \($job) should stop within the 360 minutes a job may run (timeout-minutes), not after: \($limit // "none")" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and (.if // "" | always)) then empty
        else "job \($job) should keep its output as an artifact with if: always()" end),
       (if any(.steps[]; command | test("random-seeds\\.py|bulk\\.py seeds")) then
          "job \($job) writes random seeds, but the shards and their kill confirmations run the properties with their committed seeds"
        else empty end)),

  # The weekly run: the canary and the properties with random seeds.
    (.jobs[$canary] // {}) as $called
    | (if $called.uses == "./.github/workflows/mutation-canary.yml" and ($called.if | weekly($plan))
          and any($called | needs[]; . == $plan) then empty
       else "it should replay the canary in the weekly run, in a job that calls ./.github/workflows/mutation-canary.yml with if: needs.\($plan).outputs.mode == '"'"'weekly'"'"'" end),
    one($seeds; "run the properties with random seeds (scripts/mutation/bulk.py seeds)"),
    ($seeds[] | .key as $job | .value
     | (if (.if | weekly($plan)) then empty
        else "job \($job) should run only in the weekly run: if: needs.\($plan).outputs.mode == '"'"'weekly'"'"'" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and (.if // "" | always)) then empty
        else "job \($job) should keep the seeds and their results as an artifact with if: always()" end)),

  # The issue of the stale entries, the one job that writes.
    one($issues; "open the issue of the stale entries (gh issue create)"),
    ($issues[] | .key as $job | .value
     | (if any(.steps[]; (.uses // "" | startswith("actions/checkout@")) or (command | test("scripts/|python3")))
        then "job \($job) writes issues, so it should run nothing of the repository'"'"'s: no checkout, no script"
        else empty end),
       (if (.if | weekly($plan)) and (.if | tostring | contains("needs.\($plan).outputs.stale != '"'"'0'"'"'")) then empty
        else "job \($job) should run only in a weekly run that lists stale entries: if: needs.\($plan).outputs.mode == '"'"'weekly'"'"' && needs.\($plan).outputs.stale != '"'"'0'"'"' ..." end)),

  # The finish.
    one($finishes; "merge the shards (scripts/mutation/bulk.py finish)"),
    ($finishes[] | .key as $job | .value
     | (if any(needs[]; . == $shard) then empty else "job \($job) should need the shards" end),
       (if any(needs[]; . == $canary) and any(needs[]; . == $seed) then empty
        else "job \($job) should need the canary and the properties with random seeds, so that the report names a failure of theirs" end),
       (if (.if // "" | tostring | not_cancelled) then empty
        else "job \($job) should run also when a shard failed: if: ${{ !cancelled() && ... }}" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .with.name == "mutation-report"
                         and (.if // "" | tostring | not_cancelled)) then empty
        else "job \($job) should keep the report as the artifact mutation-report, also when the merge fails" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .with.name == "mutation-flakes"
                         and (.if | weekly($plan))) then empty
        else "job \($job) should keep the weekly run'"'"'s flake records as the artifact mutation-flakes" end))
')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | while IFS= read -r problem; do
    echo "check-mutation-runs-workflow: $workflow: $problem" >&2
  done
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-mutation-runs-workflow: $workflow runs on its schedules and by hand, plans its shards within the width and a job's 6 hours, runs them on amd64, runs the weekly run's canary and random seeds, and keeps the merged report"

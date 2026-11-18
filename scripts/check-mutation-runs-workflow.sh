#!/bin/sh
# Checks the rules of the bulk mutation runs' workflow
# (.github/workflows/mutation-runs.yml, CONTRIBUTING.md, "Bulk runs on
# Actions"):
#
# - it runs only when started by hand (workflow_dispatch), so never on
#   pull requests or on pushes: a bulk run holds the account's jobs;
# - it takes the mode (each of scripts/mutation/bulk.py's), the packages,
#   the set, the seed, the size, the list, the width, whose default is the
#   account's 20 concurrent jobs, and the mutants at once, and passes each
#   to the plan;
# - its permissions are read-only, it uses no secrets, and no job goes on
#   after an error;
# - one job plans the run (bulk.py plan), keeps the plan as the artifact
#   mutation-plan, and gives the shards and the width as outputs;
# - one job runs the shards (bulk.py shard): it needs the plan, takes its
#   matrix and its max-parallel from the plan's outputs, lets every shard
#   end when one fails, runs on an amd64 runner set up for x86_64, where
#   native verdicts decide, stops within a job's 6 hours, and keeps each
#   shard's output, also when the shard fails;
# - one job merges them (bulk.py finish): it needs the shards, runs also
#   when one failed, and keeps the report as the artifact mutation-report.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-mutation-runs-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/mutation-runs.yml}

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
[ "$triggers" = workflow_dispatch ] ||
  fail "it should run only when started by hand (workflow_dispatch), not on: $triggers"

printf '%s\n' "$json" | jq -e '
  (.permissions | type == "object" and all(.[]; . != "write"))
  and all(.jobs[]; (.permissions // {}) | type == "object" and all(.[]; . != "write"))' >/dev/null ||
  fail "its permissions should be read-only"
if grep -q 'secrets\.' "$workflow"; then
  fail "it should use no secrets"
fi

# What is wrong, one line each.
problems=$(printf '%s\n' "$json" | jq -r '
  def command: (.run // "") | tostring;
  def needs: (.needs // []) | if type == "string" then [.] else . end;
  def jobs_running($script):
    [.jobs | to_entries[] | select(any(.value.steps[]?; command | test("scripts/mutation/bulk\\.py " + $script + "( |$)")))];
  def always: . == "always()" or . == "${{ always() }}";
  def not_cancelled: test("!cancelled\\(\\)") or always;
  def one($jobs; $what):
    if ($jobs | length) == 1 then empty
    else "it should \($what) in one job, not in: \(if ($jobs | length) == 0 then "nothing" else [$jobs[].key] | join(", ") end)" end;
  ((if (.on | type) == "object" then .on.workflow_dispatch.inputs else null end) // {}) as $inputs
  | jobs_running("plan") as $plans | jobs_running("shard") as $shards | jobs_running("finish") as $finishes
  | ($plans[0].key // "plan") as $plan
  | ($shards[0].key // "shard") as $shard

  # The inputs.
  | ([$inputs.mode.options[]?] | sort | join(", ")) as $modes
  | (if $modes == "body, list, matrix, packages, sample, timing" then empty
     else "its input mode should offer the modes body, list, matrix, packages, sample, timing, not: \($modes)" end),
    (if ($inputs.width.default | tostring) == "20" then empty
     else "it should take the width as an input whose default is 20, the account'"'"'s concurrent jobs" end),

  # No job goes on after an error.
    (.jobs | to_entries[] | select(.value["continue-on-error"] != null and .value["continue-on-error"] != false)
     | "job \(.key) should not continue on error"),

  # The plan.
    one($plans; "plan the run (scripts/mutation/bulk.py plan)"),
    ($plans[] | .key as $job | .value
     | ([.steps[] | select(command | test("scripts/mutation/bulk\\.py plan"))][0]) as $step
     | ("mode packages set seed size list width workers" | split(" ")[]) as $input
     | ($input | ascii_upcase) as $variable
     | if (($step.run | tostring) | contains("--\($input) \"$\($variable)\""))
          and (($step.env // {})[$variable] == "${{ inputs.\($input) }}") then empty
       else "the plan should pass the input \($input) to scripts/mutation/bulk.py plan as --\($input)" end),
    ($plans[] | .key as $job | .value
     | (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .with.name == "mutation-plan") then empty
        else "job \($job) should keep the plan as the artifact mutation-plan" end),
       ([.steps[] | select(command | test("scripts/mutation/bulk\\.py plan"))][0].id) as $id
       | (if $id != null and .outputs.shards == "${{ steps.\($id).outputs.shards }}"
             and .outputs.width == "${{ steps.\($id).outputs.width }}" then empty
          else "job \($job) should give the plan step'"'"'s outputs shards and width" end)),

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
        else "job \($job) should keep its output as an artifact with if: always()" end)),

  # The finish.
    one($finishes; "merge the shards (scripts/mutation/bulk.py finish)"),
    ($finishes[] | .key as $job | .value
     | (if any(needs[]; . == $shard) then empty else "job \($job) should need the shards" end),
       (if (.if // "" | tostring | not_cancelled) then empty
        else "job \($job) should run also when a shard failed: if: ${{ !cancelled() && ... }}" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .with.name == "mutation-report"
                         and (.if // "" | tostring | not_cancelled)) then empty
        else "job \($job) should keep the report as the artifact mutation-report, also when the merge fails" end))
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
echo "check-mutation-runs-workflow: $workflow runs only by hand, plans its shards within the width and a job's 6 hours, runs them on amd64, and keeps the merged report"

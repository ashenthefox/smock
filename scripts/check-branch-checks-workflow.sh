#!/bin/sh
# Checks the rules of the branch checks workflow
# (.github/workflows/branch-checks.yml), which writes the weakening report
# and the report of the mutants on the changed lines, which the
# maintainer reads before merging a branch into main.
#
# - It runs on a push to every branch but main and dependabot/** branches,
#   with no filter on paths, and on nothing else: this project merges
#   branches locally and opens no pull requests, so a check on pull
#   requests would never run on its work. Dependabot's pull requests keep
#   their own path. It also runs when started by hand, with one input,
#   shards, a number whose default is 20: a diff with more mutants on its
#   changed lines than a push's shards run runs whole so (#311).
# - It cancels an older run of the same branch, and no other run, as the
#   maintainer confirmed on 2026-11-17 (#275): the report of a branch's
#   head is the one read before a merge.
# - One job writes the report: one of its steps runs
#   `python3 scripts/weakening-report.py --base origin/main`, against the
#   merge base with main, which needs the whole history (the checkout's
#   fetch-depth: 0), and writes the report to the job summary; a step keeps
#   it as the artifact weakening-report. That job and its steps run in
#   every run (no condition), the job needs no other job, and it takes
#   seconds (timeout-minutes of at most 10).
# - Three jobs run the mutants on the changed lines
#   (scripts/changed-lines.py, CONTRIBUTING.md, "The changed-lines job"),
#   each with its command exactly, so that no option changes the runner's
#   rules: the plan, in every run, after checking out the whole history
#   and installing the pinned MoonBit, takes the input shards of a run
#   started by hand, gives the shards it plans as its job's output, and
#   keeps the plan as the artifact changed-lines-plan; the shards, when it
#   planned some, one job for each, on amd64, where the native verdict
#   decides (ubuntu-24.04 and the native setup for x86_64), after checking
#   out the whole history and taking the plan, keep their records as the
#   artifacts changed-lines-shard-<k>, and a failed shard leaves the
#   others to finish; the report, when the plan passed and the shards
#   passed or did not run, takes the plan and the shards' records, writes
#   the report to the job summary, and keeps it as the artifact
#   changed-lines for 90 days.
# - No job or step continues on error, no command ends in `|| ...` or turns
#   off `set -e`, and no step sets its shell or working directory: a report
#   that could not be written fails the run.
# - Its permissions are read-only, and it uses no secrets.
#
# scripts/test-check-branch-checks-workflow.sh tests this check. It needs
# yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-branch-checks-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/branch-checks.yml}

if [ ! -f "$workflow" ]; then
  echo "check-branch-checks-workflow: $workflow does not exist" >&2
  exit 1
fi

# What is wrong with the workflow, one line each.
# shellcheck disable=SC2016 # jq's variables and the workflow's ${{ }}, not this shell's
problems=$(yq --output-format=json "$workflow" | jq -r \
  --arg command "python3 scripts/weakening-report.py --base origin/main" \
  --arg plan_command 'python3 scripts/changed-lines.py plan --by-hand "$BY_HAND" --out changed-lines-plan >>"$GITHUB_OUTPUT"' \
  --arg shard_command 'python3 scripts/changed-lines.py shard --plan changed-lines-plan --shard "$SHARD" --out changed-lines-shard' \
  --arg report_command 'python3 scripts/changed-lines.py report --plan changed-lines-plan --shards changed-lines-shards --out changed-lines' '
  def command: (.run // "") | tostring;
  def step_name: .name // .run // .uses | tostring;
  def continues: (.["continue-on-error"] // false) != false;
  def flat: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def needs_of: [.needs // empty] | flatten | sort;
  def checks_out_all: any(.steps[]?; ((.uses // "") | startswith("actions/checkout@")) and .with["fetch-depth"] == 0);
  def uploads($name): [.steps[]? | select(((.uses // "") | startswith("actions/upload-artifact@")) and .with.name == $name)];
  def downloads($name): any(.steps[]?; ((.uses // "") | startswith("actions/download-artifact@")) and .with.name == $name);
  def running($text): [.value.steps[]? | select(command | contains($text))];
  [.jobs | to_entries[]] as $all
  | [$all[] | select(any(.value.steps[]?; command | contains("scripts/weakening-report.py")))] as $report
  | [$all[] | select(running("scripts/changed-lines.py plan") | length > 0)] as $plans
  | [$all[] | select(running("scripts/changed-lines.py shard") | length > 0)] as $shards
  | [$all[] | select(running("scripts/changed-lines.py report") | length > 0)] as $reports

  # When it runs, and which runs it cancels.
  | (if (.on | type) != "object" or ((.on | keys) - ["push", "workflow_dispatch"]) != [] or (.on | has("push") | not)
        or (.on.push | type) != "object" or (.on.push | keys) != ["branches-ignore"]
        or (.on.push["branches-ignore"] | sort) != ["dependabot/**", "main"] then
       "it should run on a push to every branch but main and dependabot/**, and on nothing else (on: push: branches-ignore: [main, dependabot/**], with no paths), not on: \(.on | tojson)"
     else empty end),
    (if (.on | type) != "object" or (.on.workflow_dispatch | type) != "object"
        or (.on.workflow_dispatch | keys) != ["inputs"] or (.on.workflow_dispatch.inputs | keys) != ["shards"]
        or (.on.workflow_dispatch.inputs.shards | del(.description)) != {"type": "number", "default": 20} then
       "it should also run when started by hand (workflow_dispatch), with one input, shards, a number whose default is 20, for a diff too large for the shards of a push, not: \(.on.workflow_dispatch // null | tojson)"
     else empty end),
    (if .concurrency != {"group": "branch-checks-${{ github.ref }}", "cancel-in-progress": true} then
       "it should cancel an older run of the same branch, and no other run (concurrency group branch-checks-${{ github.ref }}, cancel-in-progress: true), not \(.concurrency | tojson)"
     else empty end),

  # The job that writes the report.
    (if ($report | length) != 1 then
       "one job should write the weakening report, with a step that runs \($command), not \($report | length)"
     else
       $report[0] as $job
       | [$job.value.steps[] | select(command | contains("scripts/weakening-report.py"))] as $runs
       | (if ($runs | length) != 1 or ($runs[0] | command | gsub("\\s+"; " ") | contains($command + " ") | not) then
            "one step should run \($command), against the merge base with main, not: \([$runs[] | command] | join("; "))"
          else empty end),
         (if any($runs[]; command | contains("GITHUB_STEP_SUMMARY")) | not then
            "the job that writes the report should write it to the job summary (GITHUB_STEP_SUMMARY)"
          else empty end),
         (if any($job.value.steps[]; ((.uses // "") | startswith("actions/checkout@")) and .with["fetch-depth"] == 0) | not then
            "the job that writes the report should check out the whole history (fetch-depth: 0), to find the merge base with main"
          else empty end),
         (if any($job.value.steps[]; ((.uses // "") | startswith("actions/upload-artifact@")) and .with.name == "weakening-report") | not then
            "the job that writes the report should keep it as the artifact weakening-report"
          else empty end),
         (if $job.value.if != null then
            "the job that writes the report should run in every run, not if: \($job.value.if)"
          else empty end),
         ($job.value.steps[] | select(.if != null)
          | "the job that writes the report should run each of its steps in every run, but the step \"\(step_name)\" has if: \(.if)"),
         (if ([$job.value.needs // empty] | flatten) != [] then
            "the job that writes the report should need no other job, not \([$job.value.needs] | flatten | join(", "))"
          else empty end),
         (if ($job.value["timeout-minutes"] | type) != "number" or $job.value["timeout-minutes"] > 10 then
            "the job that writes the report should take seconds, with a timeout of at most 10 minutes, not timeout-minutes: \($job.value["timeout-minutes"])"
          else empty end)
     end),

  # The jobs that run the mutants on the changed lines.
    (if ($plans | length) != 1 then
       "one job should plan the mutants on the changed lines, with a step that runs python3 scripts/changed-lines.py plan, not \($plans | length)"
     else
       $plans[0] as $plan | ($plan | running("scripts/changed-lines.py plan")) as $steps
       | (if ($steps | length) != 1 or ($steps[0] | command | flat) != $plan_command then
            "the plan'"'"'s step should run \($plan_command), not: \([$steps[] | command] | join("; "))"
          else empty end),
         (if any($steps[]; .env.BY_HAND != "${{ inputs.shards }}") then
            "the plan'"'"'s step should take the shards of a run started by hand from the input (BY_HAND: ${{ inputs.shards }})"
          else empty end),
         (if ($steps | length) != 1 or ($steps[0].id | type) != "string"
             or $plan.value.outputs != {"shards": "${{ steps.\($steps[0].id).outputs.shards }}"} then
            "the plan'"'"'s job should give the shards that its step plans as its output (shards: ${{ steps.<id>.outputs.shards }}), not: \($plan.value.outputs | tojson)"
          else empty end),
         (if $plan.value | checks_out_all | not then
            "the plan'"'"'s job should check out the whole history (fetch-depth: 0), to find the merge base with main"
          else empty end),
         ([$plan.value.steps[] | command] | index("scripts/install-moonbit.sh pinned")) as $install
         | ([$plan.value.steps[] | command | contains("scripts/changed-lines.py plan")] | index(true)) as $at
         | (if $install == null or $at == null or $install > $at then
              "the plan'"'"'s job should install the pinned MoonBit (scripts/install-moonbit.sh pinned) before the plan, for the site finder"
            else empty end),
         (if $plan.value.if != null or ($plan.value | needs_of) != [] then
            "the plan'"'"'s job should run in every run and need no other job"
          else empty end),
         (if ($plan.value | uploads("changed-lines-plan") | length) != 1 then
            "the plan'"'"'s job should keep the plan as the artifact changed-lines-plan"
          else empty end)
     end),
    (if ($shards | length) != 1 then
       "one job should run the shards of the mutants on the changed lines, with a step that runs python3 scripts/changed-lines.py shard, not \($shards | length)"
     else
       $shards[0] as $shard | ($shard | running("scripts/changed-lines.py shard")) as $steps
       | (if ($plans | length) == 1 then $plans[0].key else "<the plan'"'"'s job>" end) as $p
       | (if ($shard.value | needs_of) != [$p]
             or $shard.value.if != "needs.\($p).outputs.shards != '"'"'[]'"'"'"
             or ($shard.value.strategy.matrix | del(.["fail-fast"])) != {"shard": "${{ fromJSON(needs.\($p).outputs.shards) }}"} then
            "the shards'"'"' job should need the plan'"'"'s job, run when it planned shards (if: needs.\($p).outputs.shards != '"'"'[]'"'"'), one for each shard it planned (matrix: shard: ${{ fromJSON(needs.\($p).outputs.shards) }})"
          else empty end),
         (if $shard.value.strategy["fail-fast"] != false then
            "the shards'"'"' job should let the other shards finish when one fails (fail-fast: false), so that a failed shard can run again alone"
          else empty end),
         (if ($steps | length) != 1 or ($steps[0] | command | flat) != $shard_command then
            "the shards'"'"' step should run \($shard_command), not: \([$steps[] | command] | join("; "))"
          else empty end),
         (if any($steps[]; .env.SHARD != "${{ matrix.shard }}") then
            "the shards'"'"' step should run the job'"'"'s shard (SHARD: ${{ matrix.shard }})"
          else empty end),
         (if $shard.value["runs-on"] != "ubuntu-24.04"
             or (any($shard.value.steps[]; .uses == "./.github/actions/native-setup" and .with.machine == "x86_64") | not) then
            "the shards'"'"' job should run on amd64, where the native verdict decides (runs-on: ubuntu-24.04, and ./.github/actions/native-setup with machine: x86_64)"
          else empty end),
         (if $shard.value | checks_out_all | not then
            "the shards'"'"' job should check out the whole history (fetch-depth: 0), where the plan'"'"'s merge base is"
          else empty end),
         (if $shard.value | downloads("changed-lines-plan") | not then
            "the shards'"'"' job should take the plan (the artifact changed-lines-plan) before the shard runs"
          else empty end),
         (if ($shard.value | uploads("changed-lines-shard-${{ matrix.shard }}") | length) != 1 then
            "the shards'"'"' job should keep each shard'"'"'s records as the artifact changed-lines-shard-${{ matrix.shard }}"
          else empty end)
     end),
    (if ($reports | length) != 1 then
       "one job should report the mutants on the changed lines, with a step that runs python3 scripts/changed-lines.py report, not \($reports | length)"
     else
       $reports[0] as $changed | ($changed | running("scripts/changed-lines.py report")) as $steps
       | (if ($plans | length) == 1 then $plans[0].key else "<the plan'"'"'s job>" end) as $p
       | (if ($shards | length) == 1 then $shards[0].key else "<the shards'"'"' job>" end) as $s
       | (if ($steps | length) != 1
             or ([$steps[0] | command | split("\n")[] | flat] | index($report_command)) == null then
            "the report'"'"'s step should run \($report_command), not: \([$steps[] | command] | join("; "))"
          else empty end),
         (if any($steps[]; command | contains("GITHUB_STEP_SUMMARY")) | not then
            "the report'"'"'s step should write the report to the job summary (GITHUB_STEP_SUMMARY)"
          else empty end),
         (if ($changed.value | needs_of) != ([$p, $s] | sort)
             or $changed.value.if != "${{ !cancelled() && needs.\($p).result == '"'"'success'"'"' && (needs.\($s).result == '"'"'success'"'"' || needs.\($s).result == '"'"'skipped'"'"') }}" then
            "the report'"'"'s job should need the plan'"'"'s job and the shards'"'"' job, and run when the plan passed and the shards passed or did not run (if: ${{ !cancelled() && needs.\($p).result == '"'"'success'"'"' && (needs.\($s).result == '"'"'success'"'"' || needs.\($s).result == '"'"'skipped'"'"') }})"
          else empty end),
         (if ($changed.value | downloads("changed-lines-plan") | not)
             or (any($changed.value.steps[]; ((.uses // "") | startswith("actions/download-artifact@"))
                    and .with.pattern == "changed-lines-shard-*" and .with.path == "changed-lines-shards") | not) then
            "the report'"'"'s job should take the plan and the shards'"'"' records (the artifacts changed-lines-plan and changed-lines-shard-*, into changed-lines-shards)"
          else empty end),
         (if ($changed.value | uploads("changed-lines") | length) != 1
             or ($changed.value | uploads("changed-lines") | .[0].with["retention-days"]) != 90 then
            "the report'"'"'s job should keep the report as the artifact changed-lines, for 90 days"
          else empty end)
     end),

  # Nothing hides a failure.
    ($all[] | select(.value | continues) | "job \(.key) should not continue on error: a failed report would pass"),
    ($all[] | .key as $job | .value.steps[]? | select(continues)
     | "the step \"\(step_name)\" of job \($job) should not continue on error: a failed report would pass"),
    ($all[] | .key as $job | .value.steps[]? | select(has("run"))
     | select(command | test("\\|\\||set +[+][a-z]"))
     | "the step \"\(step_name)\" of job \($job) should fail when a command of it fails: no || and no set +e"),
    ($all[] | .key as $job | .value.steps[]? | select(has("shell") or has("working-directory"))
     | "the step \"\(step_name)\" of job \($job) should not set its shell or working directory"),
    (if has("defaults") or any(.jobs[]; has("defaults")) then
       "it should set no defaults: a shell of another kind may not stop at a failed command"
     else empty end),

  # What it may do.
    (if (.permissions | type == "object" and all(.[]; . != "write"))
        and all(.jobs[]; (.permissions // {}) | type == "object" and all(.[]; . != "write")) | not then
       "its permissions should be read-only"
     else empty end)')

if grep -q 'secrets\.' "$workflow"; then
  problems=$(printf '%s\n%s' "$problems" "it should use no secrets" | sed '/^$/d')
fi

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed "s|^|check-branch-checks-workflow: $workflow: |" >&2
  exit 1
fi
echo "check-branch-checks-workflow: $workflow writes the weakening report and runs the mutants on the changed lines on each push to a branch but main"

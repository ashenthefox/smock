#!/bin/sh
# Checks the rules of the branch checks workflow
# (.github/workflows/branch-checks.yml), which writes the weakening report
# that the maintainer reads before merging a branch into main.
#
# - It runs on a push to every branch but main and dependabot/** branches,
#   with no filter on paths, and on nothing else: this project merges
#   branches locally and opens no pull requests, so a check on pull
#   requests would never run on its work. Dependabot's pull requests keep
#   their own path.
# - It cancels an older run of the same branch, and no other run.
# - One job writes the report: one of its steps runs
#   `python3 scripts/weakening-report.py --base origin/main`, against the
#   merge base with main, which needs the whole history (the checkout's
#   fetch-depth: 0), and writes the report to the job summary; a step keeps
#   it as the artifact weakening-report. That job and its steps run in
#   every run (no condition), the job needs no other job, and it takes
#   seconds (timeout-minutes of at most 10).
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
  --arg command "python3 scripts/weakening-report.py --base origin/main" '
  def command: (.run // "") | tostring;
  def step_name: .name // .run // .uses | tostring;
  def continues: (.["continue-on-error"] // false) != false;
  [.jobs | to_entries[]] as $all
  | [$all[] | select(any(.value.steps[]?; command | contains("scripts/weakening-report.py")))] as $report

  # When it runs, and which runs it cancels.
  | (if (.on | type) != "object" or (.on | keys) != ["push"]
        or (.on.push | type) != "object" or (.on.push | keys) != ["branches-ignore"]
        or (.on.push["branches-ignore"] | sort) != ["dependabot/**", "main"] then
       "it should run on a push to every branch but main and dependabot/**, and on nothing else (on: push: branches-ignore: [main, dependabot/**], with no paths), not on: \(.on | tojson)"
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
echo "check-branch-checks-workflow: $workflow writes the weakening report on each push to a branch but main"

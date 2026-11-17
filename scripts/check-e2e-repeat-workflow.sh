#!/bin/sh
# Checks the rules of the e2e repeat workflow
# (.github/workflows/e2e-repeat.yml):
#
# - it runs only when started by hand (workflow_dispatch), so never on a
#   schedule, on pull requests or on pushes: it ties up a runner for as long
#   as its runs take;
# - its permissions are read-only, and it uses no secrets;
# - it asks for the architecture, amd64 or arm64, and for the number of
#   runs;
# - each job that runs the e2e tests again and again (scripts/repeat-e2e.sh)
#   runs on a runner of the chosen architecture, checked to be that machine
#   by the native setup, and runs them the number of times asked for;
# - such a job keeps what the runs printed as a workflow artifact, also when
#   a run fails.
#
# A value is compared whole, not searched for a part.
#
# scripts/test-check-e2e-repeat-workflow.sh tests this check. It needs yq
# (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-e2e-repeat-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/e2e-repeat.yml}

failed=0
fail() {
  echo "check-e2e-repeat-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-e2e-repeat-workflow: $workflow does not exist" >&2
  exit 1
fi
json=$(yq --output-format=json "$workflow")

# What the workflow writes, as it writes it.
# shellcheck disable=SC2016 # the workflow's own ${{ }}, not this shell's
runner='${{ inputs.arch == '"'arm64'"' && '"'ubuntu-24.04-arm'"' || '"'ubuntu-24.04'"' }}'
# shellcheck disable=SC2016
machine='${{ inputs.arch == '"'arm64'"' && '"'aarch64'"' || '"'x86_64'"' }}'
# shellcheck disable=SC2016
runs='${{ inputs.runs }}'

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

printf '%s\n' "$json" | jq -e '
  .on.workflow_dispatch.inputs.arch | .type == "choice" and .options == ["amd64", "arm64"]' >/dev/null ||
  fail "it should ask for the architecture as a choice of amd64 and arm64 (inputs.arch)"
printf '%s\n' "$json" | jq -e '.on.workflow_dispatch.inputs.runs.type == "number"' >/dev/null ||
  fail "it should ask for the number of runs as a number (inputs.runs)"

# The jobs that run the e2e tests again and again.
jobs=$(printf '%s\n' "$json" | jq -c '[.jobs | to_entries[]
  | select(any(.value.steps[]?; (.run // "") | test("(^|[;&|[:space:]])scripts/repeat-e2e\\.sh")))]')
if [ "$(printf '%s\n' "$jobs" | jq length)" -eq 0 ]; then
  fail "a job should run the e2e tests again and again with scripts/repeat-e2e.sh"
fi
problems=$(printf '%s\n' "$jobs" | jq -r --arg runner "$runner" --arg machine "$machine" --arg runs "$runs" '
  .[] | .key as $job | .value as $value
  | (if $value["runs-on"] != $runner then
       "job \($job) should run on the runner of the chosen architecture (runs-on: \($runner)), not on \($value["runs-on"] | tostring)"
     else empty end),
    (if [$value.steps[] | select(.uses == "./.github/actions/native-setup") | .with.machine] != [$machine] then
       "job \($job) should check that its runner is the machine of the chosen architecture, once, with the native setup (machine: \($machine))"
     else empty end),
    ($value.steps[] | select((.run // "") | test("scripts/repeat-e2e\\.sh"))
     | if (.run | test("scripts/repeat-e2e\\.sh \"\\$RUNS\" ")) and .env.RUNS == $runs then empty
       else "job \($job) should run the e2e tests the number of times asked for (scripts/repeat-e2e.sh \"$RUNS\" with RUNS: \($runs)), not: \(.run | rtrimstr("\n")) with RUNS: \(.env.RUNS // "none")"
       end),
    (if any($value.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .if == "always()") then empty
     else "job \($job) should upload what the runs printed as an artifact with if: always()" end)')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | while IFS= read -r problem; do fail "$problem"; done
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-e2e-repeat-workflow: $workflow runs only by hand, on the architecture asked for, as many times as asked, and keeps each run's output"

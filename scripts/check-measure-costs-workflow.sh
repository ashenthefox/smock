#!/bin/sh
# Checks the rules of the workflow that measures the tests' costs on CI's
# runners (.github/workflows/measure-costs.yml):
#
# - it runs only when started by hand (workflow_dispatch), so never on a
#   schedule, on pull requests or on pushes;
# - its permissions are read-only, and it uses no secrets;
# - the jobs that measure (scripts/measure-costs.py) run once for amd64 on
#   x86_64 and once for arm64 on aarch64, each on the runner its matrix
#   names and checked to be that machine by the native setup, and one
#   architecture's failure does not cancel the other's job;
# - each of them keeps what it measured as workflow artifacts, also when a
#   measurement fails (if: always());
#
# scripts/test-check-measure-costs-workflow.sh tests this check. It needs yq
# (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-measure-costs-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/measure-costs.yml}

failed=0
fail() {
  echo "check-measure-costs-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-measure-costs-workflow: $workflow does not exist" >&2
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

# The jobs that measure: those with a step that runs scripts/measure-costs.py.
# What is wrong with them, one line each.
# shellcheck disable=SC2016 # jq's variables and the workflow's ${{ }}, not this shell's
problems=$(printf '%s\n' "$json" | jq -r '
  def measures: (.run // "") | tostring | test("scripts/measure-costs\\.py");
  def always: . == "always()" or . == "${{ always() }}";
  [.jobs | to_entries[] | select(any(.value.steps[]?; measures))] as $jobs
  | ([$jobs[].value.strategy.matrix.include[]? | "\(.arch) on \(.machine)"] | sort | join(", ")) as $where
  | (if $where == "amd64 on x86_64, arm64 on aarch64" then empty
     else "it should measure on amd64 on x86_64 and on arm64 on aarch64, not on: \(if $where == "" then "nothing" else $where end)" end),
    ($jobs[] | .key as $job | .value
     | (if .["runs-on"] == "${{ matrix.runner }}" then empty
        else "job \($job) should run on the runner its matrix names (runs-on: ${{ matrix.runner }}), not on \(.["runs-on"])" end),
       (if any(.steps[]; .uses == "./.github/actions/native-setup" and .with.machine == "${{ matrix.machine }}") then empty
        else "job \($job) should check that its runner is the machine of its matrix (the native setup with machine: ${{ matrix.machine }})" end),
       (if .strategy["fail-fast"] == false then empty
        else "job \($job) should go on measuring on one architecture when the other fails (fail-fast: false)" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and (.if // "" | always)) then empty
        else "job \($job) should upload what it measured as artifacts with if: always()" end))
')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | while IFS= read -r problem; do
    echo "check-measure-costs-workflow: $workflow: $problem" >&2
  done
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-measure-costs-workflow: $workflow runs only by hand"

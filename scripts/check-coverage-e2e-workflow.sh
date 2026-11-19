#!/bin/sh
# Checks the rules of the e2e coverage workflow
# (.github/workflows/coverage-e2e.yml, CONTRIBUTING.md, "Coverage from the
# e2e tests"):
#
# - it runs only when started by hand (workflow_dispatch) or when the
#   weekly mutation run calls it (workflow_call; mutation-runs.yml), so
#   never on a schedule of its own, on pull requests or on pushes: it
#   builds the binary with coverage and runs every e2e test;
# - its permissions are read-only, it uses no secrets, and no job goes on
#   after an error;
# - one job runs scripts/coverage-e2e.sh, once, on an amd64 runner
#   (ubuntu-24.04) set up for x86_64 by the native setup, where native
#   builds are about six times faster than on arm64 (#276), and stops
#   within the 360 minutes a job may run;
# - that job keeps what the script writes as the artifact coverage-e2e,
#   also when a step before failed.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-coverage-e2e-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/coverage-e2e.yml}

failed=0
fail() {
  echo "check-coverage-e2e-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-coverage-e2e-workflow: $workflow does not exist" >&2
  exit 1
fi
json=$(yq --output-format=json "$workflow")

triggers=$(printf '%s\n' "$json" | jq -r '.on | if type == "object" then keys | join(" ") else tostring end')
[ "$triggers" = "workflow_call workflow_dispatch" ] ||
  fail "it should run only when started by hand (workflow_dispatch) or called by the weekly mutation run (workflow_call), not on: $triggers"

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
  def runs_report: command | test("(^|[;&|[:space:]])scripts/coverage-e2e\\.sh([[:space:]]|$)");
  def kept: . == "always()" or . == "${{ always() }}" or test("^\\$\\{\\{ ?!cancelled\\(\\) ?\\}\\}$") or . == "!cancelled()";
  [.jobs | to_entries[] | select(any(.value.steps[]?; runs_report))] as $jobs
  | (if ($jobs | length) == 1 then empty
     else "it should run scripts/coverage-e2e.sh in one job, not in: \(if ($jobs | length) == 0 then "nothing" else [$jobs[].key] | join(", ") end)" end),
    (.jobs | to_entries[] | select(.value["continue-on-error"] != null and .value["continue-on-error"] != false)
     | "job \(.key) should not continue on error"),
    (.jobs | to_entries[] | .key as $job | .value.steps[]? | select((.["continue-on-error"] // false) != false)
     | "a step of job \($job) should not continue on error"),
    ($jobs[] | .key as $job | .value
     | ([.steps[] | select(runs_report)] | length) as $times
     | (if $times == 1 then empty else "job \($job) should run scripts/coverage-e2e.sh once, not \($times) times" end),
       (if .["runs-on"] == "ubuntu-24.04" then empty
        else "job \($job) should run on an amd64 runner (ubuntu-24.04), not on: \(.["runs-on"])" end),
       (if any(.steps[]; .uses == "./.github/actions/native-setup" and .with.machine == "x86_64") then empty
        else "job \($job) should set up the native build for x86_64 (./.github/actions/native-setup)" end),
       (.["timeout-minutes"] as $limit
        | if ($limit | type) == "number" and $limit <= 360 then empty
          else "job \($job) should stop within the 360 minutes a job may run (timeout-minutes), not after: \($limit // "none")" end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .with.name == "coverage-e2e"
                         and (.if // "" | tostring | kept)) then empty
        else "job \($job) should keep what scripts/coverage-e2e.sh writes as the artifact coverage-e2e, also when a step before failed (if: ${{ !cancelled() }})" end))
')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | while IFS= read -r problem; do
    echo "check-coverage-e2e-workflow: $workflow: $problem" >&2
  done
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-coverage-e2e-workflow: $workflow runs only by hand or from the weekly run, on amd64, and keeps the report"

#!/bin/sh
# Checks the rules of the mutation canary's workflow
# (.github/workflows/mutation-canary.yml, CONTRIBUTING.md, "The canary"):
#
# - it runs only when started by hand (workflow_dispatch) or when the
#   weekly mutation run calls it (workflow_call; mutation-runs.yml), so
#   never on a schedule of its own, on pull requests or on pushes: the
#   replay is a bulk run;
# - its permissions are read-only, and it uses no secrets;
# - each job that replays the canary (scripts/mutation/canary.py run)
#   checks out the whole history, where the canary's commit is; installs
#   the toolchain that commit pins (canary.py install), then updates the
#   registry index (moon update), then replays, in that order, and
#   installs no other toolchain (scripts/install-moonbit.sh);
# - it keeps what the replay writes as workflow artifacts, also when the
#   replay fails.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-mutation-canary-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/mutation-canary.yml}

failed=0
fail() {
  echo "check-mutation-canary-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-mutation-canary-workflow: $workflow does not exist" >&2
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

# The jobs that replay the canary: those with a step that runs
# scripts/mutation/canary.py run. What is wrong with them, one line each.
problems=$(printf '%s\n' "$json" | jq -r '
  def command: (.run // "") | tostring;
  def step_kind:
    if command | test("scripts/mutation/canary\\.py install") then "install"
    elif command | test("(^|[;&|[:space:]])moon update([[:space:]]|$)") then "update"
    elif command | test("scripts/mutation/canary\\.py run") then "run"
    else empty end;
  def always: . == "always()" or . == "${{ always() }}";
  [.jobs | to_entries[] | select(any(.value.steps[]?; command | test("scripts/mutation/canary\\.py run")))] as $jobs
  | (if ($jobs | length) > 0 then empty else "it should replay the canary (scripts/mutation/canary.py run)" end),
    ($jobs[] | .key as $job | .value
     | (if any(.steps[]; (.uses // "" | startswith("actions/checkout@"))
                         and ((.with // {})["fetch-depth"] | tostring) == "0") then empty
        else "job \($job) should check out the whole history (actions/checkout with fetch-depth: 0)" end),
       ([.steps[] | step_kind] | join(", ")) as $order
       | (if $order == "install, update, run" then empty
          else "job \($job) should run scripts/mutation/canary.py install, then moon update, then scripts/mutation/canary.py run, not: \(if $order == "" then "nothing" else $order end)" end),
       (if any(.steps[]; command | test("scripts/install-moonbit\\.sh")) then
          "job \($job) should install only the toolchain the canary'"'"'s commit pins, but runs scripts/install-moonbit.sh"
        else empty end),
       (if any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and (.if // "" | always)) then empty
        else "job \($job) should upload what the replay writes as artifacts with if: always()" end))
')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | while IFS= read -r problem; do
    echo "check-mutation-canary-workflow: $workflow: $problem" >&2
  done
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-mutation-canary-workflow: $workflow runs only by hand or from the weekly run, installs the canary commit's toolchain before the replay, and keeps its output"

#!/bin/sh
# Checks the rules of the workflow that measures the tests' costs on CI's
# runners (.github/workflows/measure-costs.yml):
#
# - it runs only when started by hand (workflow_dispatch), so never on a
#   schedule, on pull requests or on pushes;
# - its permissions are read-only, and it uses no secrets;
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

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-measure-costs-workflow: $workflow runs only by hand"

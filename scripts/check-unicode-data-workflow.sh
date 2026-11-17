#!/bin/sh
# Checks the rules of the Unicode data workflow
# (.github/workflows/unicode-data.yml), which runs the check of
# scripts/gen-unicode-data.py: that unicode/data.mbt is what the generator
# writes from the pinned version of the Unicode Character Database.
#
# - It runs on a push and on a pull request, on a weekly schedule and when
#   started by hand (workflow_dispatch), and on nothing else.
#
# scripts/test-check-unicode-data-workflow.sh tests this check. It needs yq
# (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-unicode-data-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/unicode-data.yml}

failed=0
fail() {
  echo "check-unicode-data-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-unicode-data-workflow: $workflow does not exist" >&2
  exit 1
fi
json=$(yq --output-format=json "$workflow")

triggers=$(printf '%s\n' "$json" | jq -r '.on | if type == "object" then keys | join(" ") else tostring end')
[ "$triggers" = "pull_request push schedule workflow_dispatch" ] ||
  fail "it should run on a push, on a pull request, on a weekly schedule and by hand, not on: $triggers"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-unicode-data-workflow: $workflow checks the Unicode data"

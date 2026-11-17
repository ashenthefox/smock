#!/bin/sh
# Checks the rules of the Unicode data workflow
# (.github/workflows/unicode-data.yml), which runs the check of
# scripts/gen-unicode-data.py: that unicode/data.mbt is what the generator
# writes from the pinned version of the Unicode Character Database.
#
# - It runs on a push and on a pull request, on a weekly schedule and when
#   started by hand (workflow_dispatch), and on nothing else.
# - A push or a pull request runs it only when it changes the table
#   (unicode/data.mbt), the generator or the workflow itself (paths), and
#   on every such change: the check downloads its sources from unicode.org,
#   so it does not run on every push. A push to a dependabot/** branch does
#   not run it; Dependabot's pull request does.
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

# A trigger with its paths in order, as JSON on one line.
sorted() {
  printf '%s\n' "$json" | jq -c "$1"' | if type == "object" and (.paths | type) == "array" then .paths |= sort else . end'
}
paths='["unicode/data.mbt", "scripts/gen-unicode-data.py", ".github/workflows/unicode-data.yml"]'
push=$(jq -cn --argjson paths "$paths" '{"branches-ignore": ["dependabot/**"], "paths": $paths}')
pull_request=$(jq -cn --argjson paths "$paths" '{"paths": $paths}')
[ "$(sorted .on.push)" = "$(printf '%s\n' "$push" | jq -c '.paths |= sort')" ] ||
  fail "on a push, it should run only when the table, the generator or this workflow changes, and not on a dependabot/** branch ($push), not: $(printf '%s\n' "$json" | jq -c .on.push)"
[ "$(sorted .on.pull_request)" = "$(printf '%s\n' "$pull_request" | jq -c '.paths |= sort')" ] ||
  fail "on a pull request, it should run only when the table, the generator or this workflow changes ($pull_request), not: $(printf '%s\n' "$json" | jq -c .on.pull_request)"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-unicode-data-workflow: $workflow checks the Unicode data"

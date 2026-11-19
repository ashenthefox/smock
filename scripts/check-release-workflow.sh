#!/bin/sh
# Checks the rules that keep publishing in the release workflow
# (.github/workflows/release.yml) to version tags:
#
# - it runs when a v* tag is pushed and when started by hand, and on nothing
#   else, so never on pull requests;
# - its default permissions are read-only, and it uses no secrets;
# - every job that gets a write permission runs only for a pushed tag.
#
# A run by hand can therefore build and test, but not publish: its token can
# neither push nor sign the image, nor create a release.
#
# It also checks that a release waits for the checks of the job plan
# (docs/releasing.md, "What a tag does"):
#
# - every job that gets a write permission needs plan;
# - for a pushed tag, plan checks that the tag names the version in
#   moon.mod (scripts/check-tag-version.sh), that CI passed on the tagged
#   commit (scripts/check-ci-passed.sh) and that the latest weekly mutation
#   run is clean in the packages at L4 (scripts/check-weekly-run.py, #316),
#   the last two on the tagged commit, with the run's token, each as a
#   command of its own that nothing can make pass;
# - neither plan nor any of its steps continues on error;
# - plan checks out the whole history, which scripts/check-weekly-run.py
#   reads, and may read the Actions API, which both checks of runs ask.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-release-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/release.yml}
publish_condition="github.event_name == 'push' && github.ref_type == 'tag'"

failed=0
fail() {
  echo "check-release-workflow: $workflow: $*" >&2
  failed=1
}

json=$(yq --output-format=json "$workflow")

triggers=$(printf '%s\n' "$json" | jq -r '.on | keys | join(" ")')
[ "$triggers" = "push workflow_dispatch" ] ||
  fail "it should run on push and workflow_dispatch only, not on: $triggers"
push=$(printf '%s\n' "$json" | jq -r '.on.push | keys | join(" ")')
[ "$push" = tags ] || fail "it should run on pushed tags only, but on.push has: $push"
for pattern in $(printf '%s\n' "$json" | jq -r '.on.push.tags[]?'); do
  case $pattern in
  v*) ;;
  *) fail "it should run on version tags (v*) only, not on $pattern" ;;
  esac
done

printf '%s\n' "$json" | jq -e '.permissions | type == "object" and all(.[]; . != "write")' >/dev/null ||
  fail "its default permissions should be read-only"
if grep -q 'secrets\.' "$workflow"; then
  fail "it should use no secrets, only its own token"
fi

for job in $(printf '%s\n' "$json" | jq -r --arg condition "$publish_condition" '
  .jobs | to_entries[]
  | select(.value.permissions | tostring | test("write"))
  | select(.value.if != $condition)
  | .key'); do
  fail "job $job gets a write permission, so it should run only if: $publish_condition"
done

# The checks a release waits for. The ${{ ... }} and $(...) are the
# workflow's own syntax.
# shellcheck disable=SC2016
problems=$(printf '%s\n' "$json" | jq -r --arg condition "$publish_condition" '
  def needs: (.needs // []) | if type == "string" then [.] else . end;
  def for_a_pushed_tag: . == null or . == $condition or . == "github.ref_type == '"'tag'"'";
  def runs($command; $token):
    any(.jobs.plan.steps[]?; .run == $command and (.if | for_a_pushed_tag)
                             and (($token | not) or .env.GH_TOKEN == "${{ github.token }}"));
  (.jobs | to_entries[] | select(.value.permissions | tostring | test("write"))
   | select(any(.value | needs[]; . == "plan") | not)
   | "job \(.key) gets a write permission, so it should need plan, whose checks a release waits for"),
  (if runs("scripts/check-tag-version.sh \"$VERSION\""; false) then empty
   else "job plan should check that the tag names the version in moon.mod, for a pushed tag: scripts/check-tag-version.sh \"$VERSION\"" end),
  (if runs("scripts/check-ci-passed.sh \"$(git rev-parse HEAD)\""; true) then empty
   else "job plan should check that CI passed on the tagged commit, for a pushed tag: scripts/check-ci-passed.sh \"$(git rev-parse HEAD)\", with GH_TOKEN" end),
  (if runs("python3 scripts/check-weekly-run.py \"$(git rev-parse HEAD)\""; true) then empty
   else "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"$(git rev-parse HEAD)\", with GH_TOKEN" end),
  (if ([.jobs.plan, .jobs.plan.steps[]?] | all(.["continue-on-error"] == null or .["continue-on-error"] == false))
   then empty else "job plan should not continue on error, nor any of its steps" end),
  (if any(.jobs.plan.steps[]?; (.uses // "" | startswith("actions/checkout@")) and (.with["fetch-depth"] | tostring) == "0")
   then empty else "job plan should check out the whole history (fetch-depth: 0), which scripts/check-weekly-run.py reads" end),
  (if .jobs.plan.permissions.actions == "read" then empty
   else "job plan should read the Actions API (actions: read), which its checks of CI'"'"'s run and of the weekly run ask" end)
')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | while IFS= read -r problem; do
    echo "check-release-workflow: $workflow: $problem" >&2
  done
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-release-workflow: $workflow publishes only for pushed version tags, after the checks of its job plan"

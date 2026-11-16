#!/bin/sh
# Checks that CI passed on a commit: that the Actions API lists a run of
# ci.yml for a push of the commit that succeeded. The release workflow
# (.github/workflows/release.yml) checks the commit of a pushed tag with it,
# so that nothing is published from a commit that CI did not pass. CI does
# not run for tags, so its run is the one for a push of a branch that holds
# the commit, as main does.
#
# It prints the run's URL and exits 0 when there is such a run. It exits 1
# when there is none, as while CI is still running on the commit; the
# release workflow can then be run again once CI has passed. It exits 1 too
# when gh fails or its answer cannot be read, since a release must not go
# ahead on doubt, and 2 when the argument is not a commit's full SHA.
#
# It needs jq and the gh CLI, GITHUB_REPOSITORY, and GH_TOKEN with actions:
# read, or, run by hand, a gh that is logged in (docs/releasing.md).
#
# usage: scripts/check-ci-passed.sh <commit sha>
set -eu

usage="usage: $0 <commit sha>"
if [ "$#" -ne 1 ]; then
  echo "$usage" >&2
  exit 2
fi
sha=$1
case $sha in
*[!0-9a-f]* | '') sha="" ;;
esac
if [ "${#sha}" -ne 40 ]; then
  echo "check-ci-passed: '$1' is not a commit's full SHA in lower case" >&2
  echo "$usage" >&2
  exit 2
fi

# fail <reason>: says that CI has not passed on the commit, and why, and
# exits 1.
fail() {
  echo "check-ci-passed: CI has not passed on $sha: $*" >&2
  echo "check-ci-passed: run the release workflow again once CI has passed on $sha" >&2
  exit 1
}

case ${GITHUB_REPOSITORY:-} in
*[!A-Za-z0-9._/-]* | /* | */ | */*/*) repository="" ;;
*/*) repository=$GITHUB_REPOSITORY ;;
*) repository="" ;;
esac
[ -n "$repository" ] ||
  fail "cannot ask GitHub, since GITHUB_REPOSITORY is not owner/repository: '${GITHUB_REPOSITORY:-}'"

answer=$(gh api "repos/$repository/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&status=success&per_page=100") ||
  fail "gh cannot list the runs of ci.yml for it"

# The answer must be one JSON object with a list of runs. jq prints the URL
# of the first run that passed, or nothing.
url=$(printf '%s\n' "$answer" | jq -rs --arg sha "$sha" '
  if length != 1 or (.[0].workflow_runs | type) != "array" then
    error("the answer is not one object with a list of workflow_runs")
  else .[0].workflow_runs end
  | map(select(.head_sha == $sha and .event == "push" and .conclusion == "success"))
  | if length > 0 then .[0].html_url | tostring else empty end') ||
  fail "the Actions API gave an answer that cannot be read"

case $url in
'') fail "no run of ci.yml for a push of it succeeded" ;;
*'
'*) fail "the Actions API gave an answer that cannot be read" ;;
esac
echo "check-ci-passed: CI passed on $sha: $url"

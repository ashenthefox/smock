#!/bin/sh
# Decides whether the weekly run with the latest MoonBit toolchain
# (.github/workflows/latest-toolchain.yml) may skip its build and tests,
# because they would only repeat CI's. The workflow appends what it prints
# to $GITHUB_OUTPUT.
#
# It prints run=false only when all of these hold:
#
# - the workflow runs on its schedule (GITHUB_EVENT_NAME is schedule), not
#   by hand, since a run by hand is asked for;
# - the latest toolchain is the pinned one: the two outputs of
#   `moon version --all` are the same but for the paths. Each tool's line
#   ends with its path, which differs between the two installations, so
#   the comparison leaves the paths out; it compares the rest, the line of
#   feature flags too;
# - the Actions API lists a run of ci.yml for a push of the commit
#   ($GITHUB_SHA) that succeeded, updated at most 7 days ago. That run, or
#   the run of the merged branch whose tests it did not repeat
#   (scripts/ci-plan.sh), tested the commit's tree with the pinned
#   toolchain, which is the latest. Since the clocks of the runner and of
#   GitHub may differ, a run may be dated up to 5 minutes after the time
#   now, but no later.
#
# Anything else prints run=true: another version, a file that is missing,
# empty or names no version of moon or of moonc, no such run, an error of gh
# or jq, an answer that is not what the API gives, or doubt of any other
# kind. A wrong run=false would skip the weekly check; a wrong run=true only
# runs it. It says why on standard error, and always exits 0, so that it
# never fails the workflow.
#
# moon finds moonc and moonrun in $MOON_HOME, so run each `moon version
# --all` with MOON_HOME set to that toolchain's installation.
#
# It needs jq and the gh CLI, GITHUB_EVENT_NAME, GITHUB_SHA,
# GITHUB_REPOSITORY, and GH_TOKEN with actions: read. When PLAN_NOW is set,
# it stands for the time now, in seconds since the epoch, as the tests set
# it.
#
# usage: scripts/latest-toolchain-plan.sh <pinned's moon version --all> <latest's moon version --all>

max_age=604800
max_skew=300

say() {
  printf 'latest-toolchain-plan: %s\n' "$*"
}

# versions <file>: prints the lines of `moon version --all` in <file>
# without blank lines and without each tool's path: what follows the first
# space before a / or a ~/, so that a path with a space goes too.
versions() {
  sed -e 's/[[:space:]]*$//' -e '/^$/d' -e 's| ~/.*$||' -e 's| /.*$||' "$1"
}

# plan <pinned> <latest>: returns 0 when the run may be skipped, and 1,
# having said why, when it must go ahead.
plan() {
  if [ "$#" -ne 2 ]; then
    say "usage: scripts/latest-toolchain-plan.sh <pinned's moon version --all> <latest's moon version --all>"
    return 1
  fi

  if [ "${GITHUB_EVENT_NAME:-}" != schedule ]; then
    say "the workflow was started by '${GITHUB_EVENT_NAME:-}', not by its schedule"
    return 1
  fi

  for file in "$1" "$2"; do
    if [ ! -s "$file" ]; then
      say "$file is missing or empty"
      return 1
    fi
  done
  pinned=$(versions "$1") || pinned=""
  latest=$(versions "$2") || latest=""
  for tool in moon moonc; do
    for output in "$pinned" "$latest"; do
      if ! printf '%s\n' "$output" | grep -Eq "^$tool [^ ]*[0-9]"; then
        say "the output of moon version --all names no version of $tool:"
        printf '%s\n' "$output" | sed 's/^/    /'
        return 1
      fi
    done
  done
  if [ "$pinned" != "$latest" ]; then
    say "the latest toolchain is not the pinned one:"
    printf '%s\n' "$pinned" | sed 's/^/    pinned: /'
    printf '%s\n' "$latest" | sed 's/^/    latest: /'
    return 1
  fi
  say "the latest toolchain is the pinned one:"
  printf '%s\n' "$pinned" | sed 's/^/    /'

  case ${GITHUB_SHA:-} in
  *[!0-9a-f]* | '') sha="" ;;
  *) sha=$GITHUB_SHA ;;
  esac
  if [ "${#sha}" -ne 40 ]; then
    say "GITHUB_SHA is not a commit's full SHA: '${GITHUB_SHA:-}'"
    return 1
  fi
  case ${GITHUB_REPOSITORY:-} in
  *[!A-Za-z0-9._/-]* | /* | */ | */*/*) repository="" ;;
  */*) repository=$GITHUB_REPOSITORY ;;
  *) repository="" ;;
  esac
  if [ -z "$repository" ]; then
    say "GITHUB_REPOSITORY is not owner/repository: '${GITHUB_REPOSITORY:-}'"
    return 1
  fi
  now=${PLAN_NOW:-$(date +%s)}
  case $now in
  '' | *[!0-9]*)
    say "the time now is not a number of seconds: '$now'"
    return 1
    ;;
  esac

  if ! answer=$(gh api "repos/$repository/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&status=success&per_page=100"); then
    say "gh cannot list the runs of ci.yml for $sha"
    return 1
  fi

  # The answer must be one JSON object with a list of runs. jq prints one
  # line: "passed" and the run, or why no run counts.
  if ! verdict=$(printf '%s\n' "$answer" | jq -rs --arg sha "$sha" --argjson now "$now" \
    --argjson max_age "$max_age" --argjson max_skew "$max_skew" '
    if length != 1 or (.[0].workflow_runs | type) != "array" then
      error("the answer is not one object with a list of workflow_runs")
    else .[0].workflow_runs end
    | map(select(.head_sha == $sha and .event == "push" and .conclusion == "success")
        | .age = $now - (.updated_at | fromdateiso8601)) as $passed
    | ($passed | map(select(.age + $max_skew >= 0 and .age <= $max_age))) as $recent
    | ($passed | map(select(.age + $max_skew < 0))) as $future
    | if ($recent | length) > 0 then
        $recent[0] | "passed in \(.html_url) on \(.head_branch), updated \(.updated_at)"
      elif ($future | length) > 0 then
        $future[0] | "the push run of ci.yml \(.html_url) that succeeded is dated \(.updated_at), more than \($max_skew / 60) minutes after the time now, \($now | todate)"
      elif ($passed | length) > 0 then
        "the push runs of ci.yml that succeeded are older than \($max_age / 86400) days"
      else
        "no push run of ci.yml succeeded"
      end'); then
    say "the Actions API gave an answer that cannot be read"
    return 1
  fi
  case $verdict in
  *'
'*)
    say "the Actions API gave an answer that cannot be read"
    return 1
    ;;
  'passed in '*)
    say "CI on $sha $verdict"
    return 0
    ;;
  *)
    say "for $sha, $verdict"
    return 1
    ;;
  esac
}

# Everything the checks print goes to standard error, so that standard
# output holds the one line of the decision.
if plan "$@" >&2; then
  say "the weekly run can be skipped" >&2
  echo "run=false"
else
  say "the weekly run goes ahead" >&2
  echo "run=true"
fi
exit 0

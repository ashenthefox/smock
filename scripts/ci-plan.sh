#!/bin/sh
# Decides whether CI may skip the tests on a push to main, because the same
# tree already passed them on the branch that was merged. CI runs it on
# pushes to main and appends what it prints to $GITHUB_OUTPUT.
#
# It prints full=false only when all of these hold:
#
# - the commit has exactly two parents;
# - its tree is its second parent's tree, as `git merge --no-ff` of a
#   branch that holds all of main leaves it;
# - the Actions API lists a run of ci.yml for a push of the second parent
#   that succeeded, on a branch other than main that the run names, updated
#   at most 24 hours ago. CI skips the tests only on main, so a push run on
#   any other branch ran all of them on that tree. The age limit leaves
#   little time for what lies outside the tree, such as the runner image and
#   the tools the jobs download, to change. Since the clocks of the runner
#   and of GitHub may differ, a run may be dated up to 5 minutes after the
#   time now, but no later.
#
# Anything else prints full=true: a commit that is not such a merge, a
# parent missing from the checkout, no such run, an error of git, gh or jq,
# an answer that is not what the API gives, or doubt of any other kind. A
# wrong full=false would skip the tests; a wrong full=true only runs them
# again. It says why on standard error, and always exits 0, so that it
# never fails the workflow.
#
# It needs git, jq and the gh CLI, a checkout of the commit with its
# parents (fetch-depth: 2), GITHUB_REPOSITORY, and GH_TOKEN with actions:
# read. The commit is $GITHUB_SHA, else HEAD. When PLAN_NOW is set, it
# stands for the time now, in seconds since the epoch, as the tests set it.
#
# usage: scripts/ci-plan.sh

max_age=86400
max_skew=300

say() {
  printf 'ci-plan: %s\n' "$*"
}

# plan: returns 0 when the tests may be skipped, and 1, having said why,
# when they must run.
plan() {
  if [ "$#" -ne 0 ]; then
    say "usage: scripts/ci-plan.sh (it takes no argument)"
    return 1
  fi

  name=${GITHUB_SHA:-HEAD}
  commit=$(git rev-parse --verify --quiet "$name^{commit}") || commit=""
  if [ -z "$commit" ]; then
    say "the commit $name is not in this checkout"
    return 1
  fi

  # The commit object names its parents even in a shallow checkout, where
  # git log and git rev-list show none.
  parents=$(git cat-file commit "$commit" | sed -n -e '/^$/q' -e 's/^parent //p') || parents=""
  count=0
  second=""
  for parent in $parents; do
    count=$((count + 1))
    [ "$count" -eq 2 ] && second=$parent
  done
  if [ "$count" -ne 2 ]; then
    if [ "$count" -eq 1 ]; then
      say "$commit has 1 parent, so it is not the merge of one branch"
    else
      say "$commit has $count parents, so it is not the merge of one branch"
    fi
    return 1
  fi

  tree=$(git rev-parse --verify --quiet "$commit^{tree}") || tree=""
  second_tree=$(git rev-parse --verify --quiet "$second^{tree}") || second_tree=""
  if [ -z "$tree" ] || [ -z "$second_tree" ]; then
    say "the second parent $second of $commit is not in this checkout: check out with fetch-depth: 2"
    return 1
  fi
  if [ "$tree" != "$second_tree" ]; then
    say "the tree of $commit is not that of its second parent $second"
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

  if ! answer=$(gh api "repos/$repository/actions/workflows/ci.yml/runs?head_sha=$second&event=push&status=success&per_page=100"); then
    say "gh cannot list the runs of ci.yml for $second"
    return 1
  fi

  # The answer must be one JSON object with a list of runs. jq prints one
  # line: "passed" and the run, or why no run counts. A run whose
  # head_branch names no branch may have been on main.
  if ! verdict=$(printf '%s\n' "$answer" | jq -rs --arg sha "$second" --argjson now "$now" \
    --argjson max_age "$max_age" --argjson max_skew "$max_skew" '
    if length != 1 or (.[0].workflow_runs | type) != "array" then
      error("the answer is not one object with a list of workflow_runs")
    else .[0].workflow_runs end
    | map(select(.head_sha == $sha and .event == "push" and .conclusion == "success")) as $passed
    | ($passed | map(select((.head_branch | type) != "string" or .head_branch == ""))) as $unnamed
    | ($passed | map(select((.head_branch | type) == "string" and .head_branch != "" and .head_branch != "main")
        | .age = $now - (.updated_at | fromdateiso8601))) as $branch
    | ($branch | map(select(.age + $max_skew >= 0 and .age <= $max_age))) as $recent
    | ($branch | map(select(.age + $max_skew < 0))) as $future
    | if ($recent | length) > 0 then
        $recent[0] | "passed in \(.html_url) on \(.head_branch), updated \(.updated_at)"
      elif ($future | length) > 0 then
        $future[0] | "its successful push run \(.html_url) on \(.head_branch) is dated \(.updated_at), more than \($max_skew / 60) minutes after the time now, \($now | todate)"
      elif ($branch | length) > 0 then
        "its successful push runs on branches other than main are older than \($max_age / 3600) hours"
      elif ($unnamed | length) > 0 then
        $unnamed[0] | "its successful push runs name no branch other than main: \(.html_url) names none, so it may have been on main, which may have skipped the tests"
      elif ($passed | length) > 0 then
        "its only successful push runs are on main, which may have skipped the tests"
      else
        "no push run of ci.yml for it succeeded"
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
    say "the tree of $commit is that of its second parent $second, which $verdict"
    return 0
    ;;
  *)
    say "the tree of $commit is that of its second parent $second, but $verdict"
    return 1
    ;;
  esac
}

# Everything the checks print goes to standard error, so that standard
# output holds the one line of the decision.
if plan "$@" >&2; then
  say "the tests can be skipped" >&2
  echo "full=false"
else
  say "the tests run in full" >&2
  echo "full=true"
fi
exit 0

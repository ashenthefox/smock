#!/bin/sh
# Tests of the decision whether CI may skip the tests on a push to main
# (scripts/ci-plan.sh). Each test makes commits in a git repository in a
# temporary directory, has a fake gh answer for the Actions API from a
# canned answer, or fail, runs the plan on a commit, and checks that it
# exits 0, prints exactly one line, full=true or full=false, and says why.
# The time now is fixed through PLAN_NOW.
#
# It needs git and jq, and no network.
#
# usage: scripts/test-ci-plan.sh
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo

# git looks for a repository no higher than the temporary directory, should
# that be in a checkout, and reads no configuration of this machine's.
export GIT_CEILING_DIRECTORIES="$tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# The fake gh records its arguments in $tmp/gh.args. It prints
# $tmp/answer.json, or with FAKE_GH=fail fails as gh does when the API
# answers with an error.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_GH_DIR/gh.args"
if [ "${FAKE_GH:-}" = fail ]; then
  echo "gh: Server Error (HTTP 502)" >&2
  exit 1
fi
cat "$FAKE_GH_DIR/answer.json"
SH
chmod +x "$tmp/bin/gh"
export FAKE_GH_DIR="$tmp"

# The time now: 2026-11-16T12:00:00Z.
now=$(jq -n '"2026-11-16T12:00:00Z" | fromdateiso8601')

# run <id> <head_sha> <head_branch> <updated_at> [<event> [<conclusion>]]:
# prints the run <id> of ci.yml as the Actions API lists it, by default one
# for a push that succeeded.
run() {
  jq -n --argjson id "$1" --arg sha "$2" --arg branch "$3" --arg updated "$4" \
    --arg event "${5:-push}" --arg conclusion "${6:-success}" '{
      id: $id, name: "CI", path: ".github/workflows/ci.yml",
      head_branch: $branch, head_sha: $sha, event: $event,
      status: "completed", conclusion: $conclusion,
      html_url: "https://github.com/hirunefu/smock/actions/runs/\($id)",
      created_at: $updated, updated_at: $updated, run_attempt: 1
    }'
}

# answer <run>...: writes $tmp/answer.json, an answer that lists the runs.
answer() {
  printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' >"$tmp/answer.json"
}

# commit <message> <file>: adds <file> to the work tree and commits it,
# with the message <message>, on top of HEAD, and prints the new commit.
commit() {
  echo "$2" >"$repo/$2"
  git -C "$repo" add "$2"
  git -C "$repo" commit --quiet -m "$1"
  git -C "$repo" rev-parse HEAD
}

# merge <message> <tree's commit> <parent>...: prints a new commit, a merge
# of the parents with the tree of <tree's commit>.
merge() {
  message=$1 tree=$2
  shift 2
  for parent in "$@"; do
    set -- "$@" -p "$parent"
    shift
  done
  git -C "$repo" commit-tree "$tree^{tree}" -m "$message" "$@"
}

# The history: base holds a.txt. A branch from it adds b.txt (branch), and
# then c.txt (both). main adds c.txt on its own (main), and another branch
# adds d.txt (other).
git init --quiet "$repo"
base=$(commit base a.txt)
branch=$(commit branch b.txt)
both=$(commit both c.txt)
git -C "$repo" checkout --quiet "$base"
main=$(commit main c.txt)
git -C "$repo" checkout --quiet "$base"
other=$(commit other d.txt)
git -C "$repo" checkout --quiet "$base"

# merged: the merge of the branch into main at base, whose tree is the
# branch's, as `git merge --no-ff` leaves it.
merged=$(merge merged "$branch" "$base" "$branch")
# moved: the merge of the branch after main moved on, whose tree holds the
# files of both.
moved=$(merge moved "$both" "$main" "$branch")
# octopus: a merge of three parents, the second of which is the branch,
# whose tree it has.
octopus=$(merge octopus "$branch" "$base" "$branch" "$other")

# plan <name> <directory> [-u <variable>...] [<variable>=<value>...]: runs
# the plan in <directory> with GITHUB_SHA unset, GITHUB_REPOSITORY set,
# PLAN_NOW at now and the fake gh, and then with these variables unset or
# set, as env takes them. Its standard output goes into $tmp/<name>.out,
# its standard error into $tmp/<name>.err, its exit status into
# $tmp/<name>.status, and gh's arguments into $tmp/<name>.args.
plan() {
  name=$1 directory=$2
  shift 2
  rm -f "$tmp/gh.args"
  status=0
  (cd "$directory" && env -u GITHUB_SHA -u FAKE_GH GITHUB_REPOSITORY=hirunefu/smock \
    PLAN_NOW="$now" PATH="$tmp/bin:$PATH" env "$@" "$root/scripts/ci-plan.sh") \
    >"$tmp/$name.out" 2>"$tmp/$name.err" || status=$?
  echo "$status" >"$tmp/$name.status"
  touch "$tmp/gh.args"
  mv "$tmp/gh.args" "$tmp/$name.args"
}

# show <name>: prints what the plan <name> printed, indented.
show() {
  sed 's/^/     out: /' "$tmp/$1.out"
  sed 's/^/     err: /' "$tmp/$1.err"
}

# decides <name> <true | false>: the plan <name> exited 0 and printed
# exactly the line full=<true | false> on standard output.
decides() {
  if [ "$(cat "$tmp/$1.status")" = 0 ] && [ "$(cat "$tmp/$1.out")" = "full=$2" ] &&
    [ "$(wc -l <"$tmp/$1.out")" -eq 1 ]; then
    pass "$1: exits 0 and prints only full=$2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), and does not print only full=$2"
    show "$1"
  fi
}

# explains <name> <text>: the plan <name> said <text> in some line of its
# standard error.
explains() {
  if grep -qF -- "$2" "$tmp/$1.err"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    show "$1"
  fi
}

# asks <name> <sha>: the plan <name> asked the API once, for the runs of
# ci.yml for a push of <sha> that succeeded.
asks() {
  query="api repos/hirunefu/smock/actions/workflows/ci.yml/runs?head_sha=$2&event=push&status=success&per_page=100"
  if [ "$(cat "$tmp/$1.args")" = "$query" ]; then
    pass "$1: asks for the runs of $2"
  else
    fail "$1: does not ask once for the runs of $2, but: $(cat "$tmp/$1.args")"
  fi
}

# asks_nothing <name>: the plan <name> did not ask the API.
asks_nothing() {
  if [ ! -s "$tmp/$1.args" ]; then
    pass "$1: asks GitHub nothing"
  else
    fail "$1: asks GitHub: $(cat "$tmp/$1.args")"
  fi
}

# --- The tests may be skipped ------------------------------------------------

# A merge whose tree is its second parent's, which passed CI on its branch
# two hours ago: the only case that skips the tests. The answer also lists
# runs that do not count.
answer "$(run 101 "$branch" issue/1 2026-11-16T10:00:00Z)" \
  "$(run 102 "$other" issue/2 2026-11-16T11:00:00Z)" \
  "$(run 103 "$branch" issue/1 2026-11-16T09:00:00Z push failure)"
plan recent "$repo" GITHUB_SHA="$merged"
decides recent false
asks recent "$branch"
explains recent "the tree of $merged is that of its second parent $branch, which passed in https://github.com/hirunefu/smock/actions/runs/101 on issue/1, updated 2026-11-16T10:00:00Z"

# Exactly 24 hours is not too old.
answer "$(run 104 "$branch" issue/1 2026-11-15T12:00:00Z)"
plan a-day-old "$repo" GITHUB_SHA="$merged"
decides a-day-old false

# The clocks of the runner and of GitHub may differ: a run dated exactly 5
# minutes after the time now still counts.
answer "$(run 115 "$branch" issue/1 2026-11-16T12:05:00Z)"
plan five-minutes-ahead "$repo" GITHUB_SHA="$merged"
decides five-minutes-ahead false

# A run dated later does not hide one that counts.
answer "$(run 116 "$branch" issue/1 2026-11-16T12:05:01Z)" \
  "$(run 117 "$branch" issue/1 2026-11-16T10:00:00Z)"
plan future-and-recent "$repo" GITHUB_SHA="$merged"
decides future-and-recent false
explains future-and-recent "which passed in https://github.com/hirunefu/smock/actions/runs/117 on issue/1"

# A clone of depth 2, as actions/checkout makes with fetch-depth: 2, holds
# the parents. Without GITHUB_SHA, the commit is HEAD.
git -C "$repo" update-ref refs/heads/main "$merged"
git clone --quiet --depth 2 --branch main "file://$repo" "$tmp/depth-2"
answer "$(run 105 "$branch" issue/1 2026-11-16T10:00:00Z)"
plan depth-2 "$tmp/depth-2"
decides depth-2 false

# --- The commit -------------------------------------------------------------

answer "$(run 106 "$branch" issue/1 2026-11-16T10:00:00Z)"
plan not-a-merge "$repo" GITHUB_SHA="$branch"
decides not-a-merge true
explains not-a-merge "$branch has 1 parent, so it is not the merge of one branch"
asks_nothing not-a-merge

plan three-parents "$repo" GITHUB_SHA="$octopus"
decides three-parents true
explains three-parents "$octopus has 3 parents"
asks_nothing three-parents

plan tree-differs "$repo" GITHUB_SHA="$moved"
decides tree-differs true
explains tree-differs "the tree of $moved is not that of its second parent $branch"
asks_nothing tree-differs

# Without GITHUB_SHA, the commit is HEAD, here base.
plan head "$repo"
decides head true
explains head "$base has 0 parents"

plan no-commit "$repo" GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
decides no-commit true
explains no-commit "the commit 0123456789abcdef0123456789abcdef01234567 is not in this checkout"

# A clone of depth 1, actions/checkout's default, lacks the parents.
git clone --quiet --depth 1 --branch main "file://$repo" "$tmp/depth-1"
plan shallow "$tmp/depth-1"
decides shallow true
explains shallow "the second parent $branch of $merged is not in this checkout: check out with fetch-depth: 2"
asks_nothing shallow

mkdir "$tmp/plain"
plan no-repository "$tmp/plain"
decides no-repository true
explains no-repository "the commit HEAD is not in this checkout"

# --- The runs ---------------------------------------------------------------

answer "$(run 107 "$branch" issue/1 2026-11-15T11:00:00Z)"
plan too-old "$repo" GITHUB_SHA="$merged"
decides too-old true
explains too-old "its successful push runs on branches other than main are older than 24 hours"

# A run dated more than 5 minutes after the time now leaves doubt.
answer "$(run 118 "$branch" issue/1 2026-11-16T12:05:01Z)"
plan future "$repo" GITHUB_SHA="$merged"
decides future true
explains future "its successful push run https://github.com/hirunefu/smock/actions/runs/118 on issue/1 is dated 2026-11-16T12:05:01Z, more than 5 minutes after the time now, 2026-11-16T12:00:00Z"

answer "$(run 108 "$branch" main 2026-11-16T10:00:00Z)"
plan only-on-main "$repo" GITHUB_SHA="$merged"
decides only-on-main true
explains only-on-main "its only successful push runs are on main, which may have skipped the tests"

# A run that names no branch may have been on main.
run 119 "$branch" issue/1 2026-11-16T10:00:00Z | jq '{workflow_runs: [.head_branch = null]}' >"$tmp/answer.json"
plan no-branch "$repo" GITHUB_SHA="$merged"
decides no-branch true
explains no-branch "its successful push runs name no branch other than main: https://github.com/hirunefu/smock/actions/runs/119 names none, so it may have been on main, which may have skipped the tests"

answer "$(run 120 "$branch" main 2026-11-16T10:00:00Z)" "$(run 121 "$branch" "" 2026-11-16T10:00:00Z)"
plan main-and-empty-branch "$repo" GITHUB_SHA="$merged"
decides main-and-empty-branch true
explains main-and-empty-branch "its successful push runs name no branch other than main: https://github.com/hirunefu/smock/actions/runs/121 names none"

answer
plan no-run "$repo" GITHUB_SHA="$merged"
decides no-run true
explains no-run "no push run of ci.yml for it succeeded"

# The API filters by head_sha, but an answer that lists only another
# commit's run does not count.
answer "$(run 109 "$other" issue/2 2026-11-16T10:00:00Z)"
plan other-sha "$repo" GITHUB_SHA="$merged"
decides other-sha true
explains other-sha "no push run of ci.yml for it succeeded"

answer "$(run 110 "$branch" issue/1 2026-11-16T10:00:00Z pull_request)" \
  "$(run 111 "$branch" issue/1 2026-11-16T10:00:00Z push failure)"
plan not-a-push "$repo" GITHUB_SHA="$merged"
decides not-a-push true
explains not-a-push "no push run of ci.yml for it succeeded"

# --- Errors ------------------------------------------------------------------

answer "$(run 112 "$branch" issue/1 2026-11-16T10:00:00Z)"
plan gh-fails "$repo" GITHUB_SHA="$merged" FAKE_GH=fail
decides gh-fails true
explains gh-fails "gh cannot list the runs of ci.yml for $branch"

echo '<html>Unicorn!</html>' >"$tmp/answer.json"
plan not-json "$repo" GITHUB_SHA="$merged"
decides not-json true
explains not-json "the Actions API gave an answer that cannot be read"

echo '{"message": "Not Found"}' >"$tmp/answer.json"
plan no-runs-list "$repo" GITHUB_SHA="$merged"
decides no-runs-list true
explains no-runs-list "the Actions API gave an answer that cannot be read"

: >"$tmp/answer.json"
plan empty-answer "$repo" GITHUB_SHA="$merged"
decides empty-answer true
explains empty-answer "the Actions API gave an answer that cannot be read"

# A run with no date in updated_at leaves doubt.
run 113 "$branch" issue/1 2026-11-16T10:00:00Z | jq '{workflow_runs: [.updated_at = null]}' >"$tmp/answer.json"
plan no-date "$repo" GITHUB_SHA="$merged"
decides no-date true
explains no-date "the Actions API gave an answer that cannot be read"

answer "$(run 114 "$branch" issue/1 2026-11-16T10:00:00Z)"
plan no-repository-name "$repo" GITHUB_SHA="$merged" GITHUB_REPOSITORY=
decides no-repository-name true
explains no-repository-name "GITHUB_REPOSITORY is not owner/repository: ''"
asks_nothing no-repository-name

plan unset-repository-name "$repo" -u GITHUB_REPOSITORY GITHUB_SHA="$merged"
decides unset-repository-name true
explains unset-repository-name "GITHUB_REPOSITORY is not owner/repository: ''"

plan bad-now "$repo" GITHUB_SHA="$merged" PLAN_NOW=yesterday
decides bad-now true
explains bad-now "the time now is not a number of seconds: 'yesterday'"

echo
echo "test-ci-plan: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

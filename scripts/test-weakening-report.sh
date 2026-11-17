#!/bin/sh
# Tests of the weakening report (scripts/weakening-report.py), which the
# branch checks workflow writes on each push to a branch other than main.
# Each test makes a small git repository in a temporary directory: a commit
# on main, then a branch with one kind of change. It runs the report on the
# branch and checks what the report lists: each kind of weakening shows,
# and a branch that weakens nothing gives an empty report.
#
# It needs what the report needs: python3 and git.
#
# usage: scripts/test-weakening-report.sh
set -eu
cd "$(dirname "$0")/.."

script=$PWD/scripts/weakening-report.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo

# git looks for a repository no higher than the temporary directory, should
# that be in a checkout, and reads no configuration of the machine's.
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

# tree: makes $repo anew, a git repository on main with no commit.
tree() {
  rm -rf "$repo"
  git init --quiet --initial-branch=main "$repo"
}

# file <path>: writes its standard input to <path> in the tree.
file() {
  mkdir -p "$(dirname "$repo/$1")"
  cat >"$repo/$1"
}

# remove <path>: removes <path> from the tree.
remove() {
  rm -rf "${repo:?}/$1"
}

# commit <message>: commits everything in the tree.
commit() {
  git -C "$repo" add --all
  git -C "$repo" commit --quiet --allow-empty -m "$1"
}

# branch: commits the tree on main as the base, and starts the branch
# topic from it.
branch() {
  commit base
  git -C "$repo" switch --quiet -c topic
}

# report <name>: commits the tree on the branch, runs the report against
# main, its output into $tmp/<name>.out and its exit status into
# $tmp/<name>.status.
report() {
  commit "$1"
  status=0
  python3 "$script" --repo "$repo" --base main >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
  if [ "$status" != 0 ]; then
    fail "$1: exits with $status, not 0"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# mentions <name> <text>: the report <name> holds <text> in some line.
mentions() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: mentions $2"
  else
    fail "$1: does not mention $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# lacks <name> <text>: the report <name> holds <text> in no line.
lacks() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    fail "$1: mentions $2"
    sed 's/^/     /' "$tmp/$1.out"
  else
    pass "$1: does not mention $2"
  fi
}

# empty <name>: the report <name> lists nothing.
empty() {
  if grep -qxF -- "Nothing to report." "$tmp/$1.out" && ! grep -q '^## ' "$tmp/$1.out"; then
    pass "$1: lists nothing"
  else
    fail "$1: lists something"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# A package with two tests and the function they test.
package() {
  file add/add.mbt <<'MBT'
///|
/// The sum of two numbers.
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
MBT
  file add/add_test.mbt <<'MBT'
///|
test "adds two numbers" {
  assert_eq(@add.add(2, 3), 5)
}

///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
}

# --- A branch that weakens nothing ---------------------------------------------

# A new test, a changed function and a new document weaken nothing.
tree
package
branch
cat >>"$repo/add/add_test.mbt" <<'MBT'

///|
test "adds zero" {
  assert_eq(@add.add(2, 0), 2)
}
MBT
file add/add.mbt <<'MBT'
///|
/// The sum of two numbers, a and b.
pub fn add(a : Int, b : Int) -> Int {
  b + a
}
MBT
file README.md <<'MD'
# Add
MD
report nothing
empty nothing
mentions nothing "against \`$(git -C "$repo" rev-parse --short main)\`, its merge base with \`main\`"

# --- Tests deleted -------------------------------------------------------------

tree
package
branch
file add/add_test.mbt <<'MBT'
///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
report deleted
mentions deleted "## Tests deleted"
mentions deleted '`add/add_test.mbt:2`: test "adds two numbers"'
lacks deleted 'test "adds a negative number"'

# A test file deleted whole deletes each of its tests.
tree
package
branch
remove add/add_test.mbt
report deleted-file
mentions deleted-file '`add/add_test.mbt:2`: test "adds two numbers"'
mentions deleted-file '`add/add_test.mbt:7`: test "adds a negative number"'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

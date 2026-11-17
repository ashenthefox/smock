#!/bin/sh
# Tests of the coverage ratchet (scripts/coverage-ratchet.py), which CI's
# job coverage runs on the bisect report that scripts/coverage.sh makes.
# Each test makes a small git repository in a temporary directory: the
# small source tree of scripts/coverage-tests/, with the floors in
# coverage/, committed on main, then a branch that changes the floors, the
# approved raises or the source. It runs the ratchet on the branch against
# main, with one of the small bisect reports of scripts/coverage-tests/,
# and checks its exit status and what it prints.
#
# The rules come from the ticket of the floors (#297): the ratchet fails
# when a package's uncovered points rise above its floor, naming the
# package and the new uncovered points, and passes when they are at or
# below it; it says so when a floor can be lowered; and a floor raised
# above the base's fails it unless the change records the raise, with its
# reason, in the list of approved raises. The counts are those that
# scripts/test-coverage-report.sh checks on the same reports.
#
# It needs what the ratchet needs: python3 and git.
#
# usage: scripts/test-coverage-ratchet.sh
set -eu
cd "$(dirname "$0")/.."

script=$PWD/scripts/coverage-ratchet.py
fixtures=$PWD/scripts/coverage-tests
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

# tree: makes $repo anew, a git repository on main with the small source
# tree and no commit.
tree() {
  rm -rf "$repo"
  git init --quiet --initial-branch=main "$repo"
  cp -R "$fixtures/tree/." "$repo/"
}

# floors <line>...: writes the floors, one package and its floor a line.
floors() {
  mkdir -p "$repo/coverage"
  printf '# The floors of a test.\n' >"$repo/coverage/floors.txt"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$repo/coverage/floors.txt"
  done
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

# ratchet <name> <report> [option]...: commits the tree on the branch, and
# runs the ratchet's check against main on the bisect report <report> of
# scripts/coverage-tests/, its output into $tmp/<name>.out and its exit
# status into $tmp/<name>.status.
ratchet() {
  name=$1
  report=$2
  shift 2
  commit "$name"
  status=0
  python3 "$script" --root "$repo" check --base main "$@" "$fixtures/$report" \
    >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# exits <name> <status>: the ratchet <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <text>: the ratchet <name> printed <text> in some line.
says() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# --- Above a floor, and at it --------------------------------------------------

# partly.bisect leaves one of prng's four points uncovered: the then arm's
# abort, at line 16, column 19, of Generator::below.
tree
floors "prng 0"
branch
ratchet above partly.bisect
exits above 1
says above "prng: 1 uncovered point, above its floor of 0"
says above "prng/prng.mbt:16:19  Generator::below"

tree
floors "prng 1"
branch
ratchet at partly.bisect
exits at 0
says at "prng: 1 uncovered point, at its floor of 1"

echo
echo "test-coverage-ratchet: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

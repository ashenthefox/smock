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

# The new uncovered points are those on the lines that the change adds or
# changes. At the base, line 16 of prng.mbt had no abort arm; the branch
# adds it, uncovered.
tree
floors "prng 0"
sed -i '16s/.*/  self.next() % count/' "$repo/prng/prng.mbt"
branch
cp "$fixtures/tree/prng/prng.mbt" "$repo/prng/prng.mbt"
ratchet new-line partly.bisect
exits new-line 1
says new-line "prng: 1 uncovered point, above its floor of 0. Its new uncovered points, on the lines that the change adds or changes:"
says new-line "prng/prng.mbt:16:19  Generator::below"

# A file that the merge base does not have is new in every line.
tree
mv "$repo/prng/prng.mbt" "$tmp/prng.mbt"
floors "prng 0"
branch
mv "$tmp/prng.mbt" "$repo/prng/prng.mbt"
ratchet new-file partly.bisect
exits new-file 1
says new-file "Its new uncovered points, on the lines that the change adds or changes:"

# Where no uncovered point is on such a line, as when a test that reached
# one is gone, the ratchet names every uncovered point of the package.
tree
floors "prng 0"
branch
ratchet old-line partly.bisect
exits old-line 1
says old-line "prng: 1 uncovered point, above its floor of 0. None is on a line that the change adds or changes, so a test may no longer reach them; its uncovered points:"
says old-line "prng/prng.mbt:16:19  Generator::below"

# --- Each package of the report has a floor, and each floor a package --------

tree
floors "cmd/smock 4" "prng 1"
branch
ratchet no-floor packages.bisect
exits no-floor 1
says no-floor 'server: 4 uncovered points, and no floor: add "server 4" to coverage/floors.txt'

tree
floors "gone 3" "prng 1"
branch
ratchet stray-floor partly.bisect
exits stray-floor 1
says stray-floor "gone: a floor of 3, but the report has no such package: remove its line from coverage/floors.txt"

tree
floors "prng one"
branch
ratchet malformed-floor partly.bisect
exits malformed-floor 1
says malformed-floor "coverage/floors.txt:2: should be <package> <uncovered points>, not: prng one"

# --- The job summary ---------------------------------------------------------------

# --summary appends to a file a table of the packages, in Markdown, as CI's
# job summary shows it, and what the ratchet found.
tree
floors "cmd/smock 4" "prng 2" "server 3"
branch
ratchet summary packages.bisect --summary "$tmp/summary.md"
exits summary 1
cp "$tmp/summary.md" "$tmp/summary.out"
says summary "| Package | Points | Covered | Uncovered | Floor |"
says summary "| cmd/smock | 4 | 0 | 4 | 4 |"
says summary "| prng | 4 | 3 | 1 | 2 |"
says summary "| server | 6 | 2 | 4 | 3 |"
says summary "server: 4 uncovered points, above its floor of 3."
says summary "prng: 1 uncovered point, below its floor of 2"

# --- Below a floor, and as it falls ----------------------------------------------

# covered.bisect covers all of prng's points: the floor of 1 can be
# lowered, and the ratchet says how.
tree
floors "prng 1"
branch
ratchet below covered.bisect
exits below 0
says below "prng: 0 uncovered points, below its floor of 1: lower it to 0 in this change"
says below "python3 scripts/coverage-ratchet.py write"

# The change that covers the point lowers the floor with it.
tree
floors "prng 1"
branch
floors "prng 0"
ratchet falls covered.bisect
exits falls 0
says falls "prng: 0 uncovered points, at its floor of 0"

# --- A raised floor ----------------------------------------------------------------

# raises <line>...: writes the list of approved raises, one a line.
raises() {
  mkdir -p "$repo/coverage"
  printf '# The approved raises of a test.\n' >"$repo/coverage/approved-raises.txt"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$repo/coverage/approved-raises.txt"
  done
}

# A floor raised to let the uncovered point in, with no recorded raise.
tree
floors "prng 0"
branch
floors "prng 1"
ratchet raised partly.bisect
exits raised 1
says raised "prng: its floor rose from 0 to 1 against the merge base"
says raised 'add "prng 1 <reason>" to coverage/approved-raises.txt in the same change'

# The same raise, recorded with its reason, passes, and the ratchet says so.
tree
floors "prng 0"
raises
branch
floors "prng 1"
raises "prng 1 the abort arm of an invariant waits for the exclusion list (#302)"
ratchet recorded partly.bisect
exits recorded 0
says recorded "prng: its floor rose by 1, as coverage/approved-raises.txt records: the abort arm of an invariant waits for the exclusion list (#302)"

# A raise recorded at the base approved that change's raise, not this one.
tree
floors "prng 0"
raises "prng 1 an earlier raise"
branch
floors "prng 1"
ratchet recorded-before partly.bisect
exits recorded-before 1
says recorded-before "prng: its floor rose from 0 to 1 against the merge base"

# A record must cover the whole raise.
tree
floors "prng 0"
raises
branch
floors "prng 2"
raises "prng 1 one point"
ratchet short partly.bisect
exits short 1
says short "prng: its floor rose from 0 to 2 against the merge base"
says short "coverage/approved-raises.txt records 1 point of it"
says short 'add "prng 1 <reason>" to coverage/approved-raises.txt in the same change'

# A package without a floor at the base had none: its first floor is a
# raise from 0.
tree
floors "prng 1"
branch
floors "cmd/smock 4" "prng 1" "server 4"
raises "server 4 the parsers' callers wait for e2e coverage (#342)"
ratchet new-packages packages.bisect
exits new-packages 1
says new-packages "cmd/smock: its floor rose from none to 4 against the merge base"
says new-packages "server: its floor rose by 4, as coverage/approved-raises.txt records"

# A line that is not <package> <points> <reason> fails the check.
tree
floors "prng 1"
branch
raises "prng one the abort arm"
ratchet malformed-raise partly.bisect
exits malformed-raise 1
says malformed-raise "coverage/approved-raises.txt:2: should be <package> <points> <reason>"

# Before the floors are committed at the merge base, there is nothing to
# compare with.
tree
branch
floors "prng 1"
ratchet first partly.bisect
exits first 0
says first "has no committed floors: nothing to compare with"

# write sets each package's floor to its uncovered points, in the order of
# the packages' names, and keeps the comments at the start of the file.
tree
floors "prng 3" "gone 7"
python3 "$script" --root "$repo" write "$fixtures/packages.bisect" >"$tmp/write.out" 2>&1
printf '%s\n' "# The floors of a test." "" "cmd/smock 4" "prng 1" "server 4" >"$tmp/write.expected"
if cmp -s "$tmp/write.expected" "$repo/coverage/floors.txt"; then
  pass "write: writes the floors of packages.bisect"
else
  fail "write: writes other floors than those of packages.bisect"
  diff "$tmp/write.expected" "$repo/coverage/floors.txt" | sed 's/^/     /'
fi

echo
echo "test-coverage-ratchet: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

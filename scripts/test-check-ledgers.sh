#!/bin/sh
# Tests of the check of the use-case and boundary ledgers
# (scripts/check-ledgers.py), which CI runs on every push. Each test writes
# a small tree into a temporary directory, the two ledgers and the files
# their rows name, runs the check on it, and checks its exit status and what
# it prints: each problem, and the count, which says that it found no other.
#
# It needs what the check needs: python3, 3.9 or later.
#
# usage: scripts/test-check-ledgers.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/tree

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

# tree: makes $root anew, with the test files and checks that the ledgers
# below name, and no ledger.
tree() {
  rm -rf "$root"
  mkdir -p "$root"
  files
}

# file <path>: writes its standard input to <path> in the tree.
file() {
  mkdir -p "$(dirname "$root/$1")"
  cat >"$root/$1"
}

# check <name>: runs the check on the tree, its output into $tmp/<name>.out
# and its exit status into $tmp/<name>.status.
check() {
  status=0
  python3 scripts/check-ledgers.py "$root" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# exits <name> <status>: the check <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <line>: the check <name> printed <line>.
says() {
  if grep -qxF -- "$2" "$tmp/$1.out"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# lines <name> <count>: the check <name> printed <count> lines.
lines() {
  if [ "$(wc -l <"$tmp/$1.out" | tr -d ' ')" = "$2" ]; then
    pass "$1: prints $2 lines"
  else
    fail "$1: prints $(wc -l <"$tmp/$1.out" | tr -d ' ') lines, not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# files: writes the test files and the check that the ledgers name: a test
# and an async test in a black-box test file, a white-box test, a name with
# escaped quotes, texts that look like a test without being one, a script,
# and two packages.
files() {
  file e2e/serve_test.mbt <<'MBT'
// test "a test in a comment" is no test.

///|
async test "smock serve answers a request that matches a Stub" {
  let text = "test \"a test in a string\" {"
  ignore(text)
}

///|
test "a name with \"quotes\"" {
  ()
}

///|
test "a name and more" {
  ()
}
MBT
  file http1/limits_test.mbt <<'MBT'
///|
test "a head of 16384 bytes is read, and one of 16385 gets 431" {
  ()
}
MBT
  file server/reset_wbtest.mbt <<'MBT'
///|
test "a reset is sent" {
  ()
}
MBT
  file scripts/smoke-test-image.sh <<'SH'
#!/bin/sh
SH
  file http1/moon.pkg <<'PKG'
{}
PKG
  file server/moon.pkg <<'PKG'
{}
PKG
}

# ledgers: writes two ledgers with a row of each kind, each of which the
# check passes.
ledgers() {
  file docs/ledgers/use-cases.md <<'MD'
# The use-case ledger

## Features

| ID | Feature | Source | Status | Checked by |
|---|---|---|---|---|
| F01 | Quick start | [Run](../../README.md#run) | tested | `e2e/serve_test.mbt` "smock serve answers a request that matches a Stub"<br>`scripts/smoke-test-image.sh` runs the image |

## Messages

| ID | Message | Source | Seen by | Status | Checked by |
|---|---|---|---|---|---|
| M01 | "a name" | [#283](https://github.com/hirunefu/smock/issues/283) | user | asserted | `e2e/serve_test.mbt` "a name with \"quotes\"" |
MD
  file docs/ledgers/boundaries.md <<'MD'
# The boundary ledger

| ID | Limit | Source | Package | Status | At the limit | Just past it |
|---|---|---|---|---|---|---|
| L01 | Header size, 16384 | [Settings](../running.md#settings) | `http1` | tested | `http1/limits_test.mbt` "a head of 16384 bytes is read, and one of 16385 gets 431" | `http1/limits_test.mbt` "a head of 16384 bytes is read, and one of 16385 gets 431" |
MD
}

# --- Valid ledgers -------------------------------------------------------------

tree
ledgers
check valid
exits valid 0
says valid "check-ledgers: 1 feature, 1 message and 1 limit, each test and check found"
lines valid 1

# --- A test that is not there --------------------------------------------------

tree
ledgers
sed -i 's/"a head of 16384 bytes is read, and one of 16385 gets 431" |$/"a head of 16385 bytes" |/' "$root/docs/ledgers/boundaries.md"
check missing-test
exits missing-test 1
says missing-test 'docs/ledgers/boundaries.md:5: L01: http1/limits_test.mbt: no test named "a head of 16385 bytes"'
says missing-test "check-ledgers: 1 feature, 1 message and 1 limit, 1 problem"
lines missing-test 2

# --- Entries of every kind -----------------------------------------------------

# A test, a check, a ticket and a manual check are each an entry, with text
# after them; a name in a comment or a string, or the start of a longer
# name, is no test; a file with two tests of a name names neither.
tree
ledgers
cat >>"$root/e2e/serve_test.mbt" <<'MBT'

///|
test "a name with \"quotes\"" {
  ()
}
MBT
cat >>"$root/docs/ledgers/use-cases.md" <<'MD'

| ID | Feature | Source | Status | Checked by |
|---|---|---|---|---|
| F02 | Kinds | [Run](../../README.md#run) | manual | `server/reset_wbtest.mbt` "a reset is sent" (white-box)<br>`scripts/smoke-test-image.sh`<br>#287 adds the rest<br>Manual: only an operating-system failure shows it |
| F03 | Not tests | [Run](../../README.md#run) | tested | `e2e/serve_test.mbt` "a test in a comment"<br>`e2e/serve_test.mbt` "a test in a string"<br>`e2e/serve_test.mbt` "a name"<br>`e2e/serve_test.mbt` "a name with \"quotes\""<br>`e2e/missing_test.mbt` "a test"<br>`scripts/missing.sh` runs<br>the image runs<br>Manual:<br>#<br> |
MD
check kinds
exits kinds 1
says kinds 'docs/ledgers/use-cases.md:18: F03: e2e/serve_test.mbt: no test named "a test in a comment"'
says kinds 'docs/ledgers/use-cases.md:18: F03: e2e/serve_test.mbt: no test named "a test in a string"'
says kinds 'docs/ledgers/use-cases.md:18: F03: e2e/serve_test.mbt: no test named "a name"'
says kinds 'docs/ledgers/use-cases.md:18: F03: e2e/serve_test.mbt: 2 tests are named "a name with \"quotes\""'
says kinds 'docs/ledgers/use-cases.md:18: F03: e2e/missing_test.mbt: no such file'
says kinds 'docs/ledgers/use-cases.md:18: F03: scripts/missing.sh: no such file or directory'
says kinds 'docs/ledgers/use-cases.md:18: F03: "the image runs" is not a test, a check, a ticket or a manual check'
says kinds 'docs/ledgers/use-cases.md:18: F03: "Manual:" is not a test, a check, a ticket or a manual check'
says kinds 'docs/ledgers/use-cases.md:18: F03: "#" is not a test, a check, a ticket or a manual check'
says kinds 'docs/ledgers/use-cases.md:18: F03: an entry of Checked by is empty'
says kinds 'docs/ledgers/use-cases.md:13: M01: e2e/serve_test.mbt: 2 tests are named "a name with \"quotes\""'
says kinds "check-ledgers: 3 features, 1 message and 1 limit, 11 problems"
lines kinds 12

# --- Ids and sources -----------------------------------------------------------

# An id is the kind's letter and two digits, a limit's with a letter after
# them, and no two rows of the two ledgers share one; a source is a link or
# an issue.
tree
ledgers
cat >>"$root/docs/ledgers/boundaries.md" <<'MD'
| L01a | Another | [#285](https://github.com/hirunefu/smock/issues/285) | `http1` | tested | `scripts/smoke-test-image.sh` | `scripts/smoke-test-image.sh` |
| F01 | A feature's id | #285 | `http1` | tested | `scripts/smoke-test-image.sh` | `scripts/smoke-test-image.sh` |
| L1 | Short | RFC 9293 | `http1` | tested | `scripts/smoke-test-image.sh` | `scripts/smoke-test-image.sh` |
| L02 | No source |  | `http1` | tested | `scripts/smoke-test-image.sh` | `scripts/smoke-test-image.sh` |
| L01 | Twice | [Settings](../running.md#settings) | `http1` | tested | `scripts/smoke-test-image.sh` | `scripts/smoke-test-image.sh` |
MD
check ids
exits ids 1
says ids "docs/ledgers/boundaries.md:7: F01: the id is not L, two digits and maybe a lower-case letter"
says ids "docs/ledgers/boundaries.md:7: F01: docs/ledgers/use-cases.md:7 has the id F01 too"
says ids "docs/ledgers/boundaries.md:8: L1: the id is not L, two digits and maybe a lower-case letter"
says ids "docs/ledgers/boundaries.md:8: L1: the source has no link and names no issue"
says ids "docs/ledgers/boundaries.md:9: L02: the source has no link and names no issue"
says ids "docs/ledgers/boundaries.md:10: L01: docs/ledgers/boundaries.md:5 has the id L01 too"
says ids "check-ledgers: 1 feature, 1 message and 6 limits, 6 problems"
lines ids 7

# --- Statuses ------------------------------------------------------------------

# Each kind has its statuses, and each status says which entries its row
# has: tested only tests and checks, partly tests or checks and a ticket,
# manual a manual check, open a ticket and no test, deleted a ticket.
tree
ledgers
cat >>"$root/docs/ledgers/use-cases.md" <<'MD'

| ID | Feature | Source | Status | Checked by |
|---|---|---|---|---|
| F10 | Tested with a ticket | #1 | tested | `scripts/smoke-test-image.sh`<br>#287 |
| F11 | Tested by hand | #1 | tested | Manual: by hand |
| F12 | Partly without a ticket | #1 | partly | `scripts/smoke-test-image.sh` |
| F13 | Partly without a test | #1 | partly | #287 |
| F14 | Manual without a reason | #1 | manual | #287 |
| F15 | Open with a test | #1 | open | `scripts/smoke-test-image.sh`<br>#287 |
| F16 | Open without a ticket | #1 | open | Manual: by hand |
| F17 | Asserted | #1 | asserted | `scripts/smoke-test-image.sh` |
| F18 | Manual | #1 | manual | Manual: only an operating-system failure shows it |
| F19 | Open | #1 | open | #287 adds it |

| ID | Message | Source | Seen by | Status | Checked by |
|---|---|---|---|---|---|
| M10 | Asserted by hand | #1 | user | asserted | Manual: by hand |
| M11 | Deleted with a test | #1 | user | deleted | #280 deleted it<br>`scripts/smoke-test-image.sh` |
| M12 | Seen by nobody | #1 | nobody | open | #283 |
| M13 | Deleted | #1 | user | deleted | #280 deleted it |
| M14 | Open | #1 | package | open | #283 |
| M15 | Manual | #1 | user | manual | Manual: only an operating-system failure shows it |
MD
cat >>"$root/docs/ledgers/boundaries.md" <<'MD'
| L10 | Tested on one side | #1 | `http1` | tested | `scripts/smoke-test-image.sh` | #324 |
| L11 | Partly | #1 | `http1` | partly | #324 | `scripts/smoke-test-image.sh` |
| L12 | Open | #1 | `http1` | open | #324 | #324 |
| L13 | Partly with nothing on one side | #1 | `http1` | partly | `scripts/smoke-test-image.sh` | Manual: by hand |
| L14 | Open with a test | #1 | `http1` | open | `scripts/smoke-test-image.sh` | #324 |
MD
check statuses
exits statuses 1
says statuses "docs/ledgers/use-cases.md:17: F10: a tested row names tests and checks alone"
says statuses "docs/ledgers/use-cases.md:18: F11: a tested row names tests and checks alone"
says statuses "docs/ledgers/use-cases.md:19: F12: a partly tested row names tests, checks and tickets alone, with at least one ticket and one test or check"
says statuses "docs/ledgers/use-cases.md:20: F13: a partly tested row names tests, checks and tickets alone, with at least one ticket and one test or check"
says statuses "docs/ledgers/use-cases.md:21: F14: a manual row names a manual check with its reason"
says statuses "docs/ledgers/use-cases.md:22: F15: an open row names tickets alone"
says statuses "docs/ledgers/use-cases.md:23: F16: an open row names tickets alone"
says statuses "docs/ledgers/use-cases.md:24: F17: the status is not tested, partly, manual or open"
says statuses "docs/ledgers/use-cases.md:30: M10: an asserted row names tests and checks alone"
says statuses "docs/ledgers/use-cases.md:31: M11: a deleted row names tickets alone: the one that deleted it"
says statuses "docs/ledgers/use-cases.md:32: M12: seen by is not user or package"
says statuses "docs/ledgers/boundaries.md:6: L10: a tested row names tests and checks alone"
says statuses "docs/ledgers/boundaries.md:9: L13: a partly tested row names tests, checks and tickets alone, with at least one ticket and one test or check"
says statuses "docs/ledgers/boundaries.md:10: L14: an open row names tickets alone"
says statuses "check-ledgers: 11 features, 7 messages and 6 limits, 14 problems"
lines statuses 15

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

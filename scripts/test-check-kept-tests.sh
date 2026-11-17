#!/bin/sh
# Tests of the check of the keep list (scripts/check-kept-tests.py), which
# CI runs on every push. Each test writes a small tree into a temporary
# directory, a keep list and the test files it names, runs the check on it,
# and checks its exit status and what it prints: each problem, and the
# count, which says that it found no other.
#
# It needs what the check needs: python3, 3.11 or later.
#
# usage: scripts/test-check-kept-tests.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/tree
list=kept.toml

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

# tree: makes $root anew, with no file.
tree() {
  rm -rf "$root"
  mkdir -p "$root"
}

# file <path>: writes its standard input to <path> in the tree.
file() {
  mkdir -p "$(dirname "$root/$1")"
  cat >"$root/$1"
}

# check <name> [list]: runs the check on the tree with the list <list>, or
# kept.toml, its output into $tmp/<name>.out and its exit status into
# $tmp/<name>.status.
check() {
  status=0
  python3 scripts/check-kept-tests.py "$root/${2:-$list}" "$root" >"$tmp/$1.out" 2>&1 || status=$?
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

# mentions <name> <text>: the check <name> printed <text> in some line.
mentions() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: mentions $2"
  else
    fail "$1: does not mention $2"
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

# tests: writes the test files that the lists below name: a test and an
# async test in a black-box test file, a white-box test, a test in a
# README's fenced code, a name that holds escaped quotes and braces, and
# texts that look like a test without being one.
tests() {
  file grpc/status_test.mbt <<'MBT'
// A comment that names test "the code in a comment" is no test.

///|
test "a status's code is the decimal text grpc-status carries" {
  inspect(13, content="13")
}

///|
async test "a call gets grpc-status 0" {
  let text = "test \"a string that looks like a test\" {"
  ignore(text)
}

///|
test "a name with \"quotes\" and {braces}" (b : @bench.T) {
  ignore(b)
}

///|
test "a name and more" {
  ()
}
MBT
  file engine/store_wbtest.mbt <<'MBT'
///|
test "a white-box test" {
  ()
}
MBT
  file xml/README.mbt.md <<'MD'
# xml

```mbt check
///|
test "a documented example" {
  ()
}
```
MD
}

# head_of <file>: writes the head of a keep list, its derived reasons, to
# <file> in the tree; the reasons follow with `reason`.
head_of() {
  file "$1" <<'TOML'
[derived]
reasons = ["the only test of a feature, from the ledgers"]
TOML
}

# reason <file> <id> <rule>: appends a reason with its search to <file>.
reason() {
  cat >>"$root/$1" <<TOML

[[reason]]
id = "$2"
rule = "$3"
title = "A reason"
source = "Where the reason comes from"
search = ["git grep -n test"]
found = "What the search found"
TOML
}

# kept <file> <path> <name>: appends a test of <path> named <name>, as a
# TOML literal string, which takes quotes and backslashes as they are, to
# the last reason of <file>.
kept() {
  cat >>"$root/$1" <<TOML

[[reason.test]]
file = "$2"
name = '''$3'''
source = "The spec, section 1"
TOML
}

# --- A list whose every test is there ---------------------------------------

# Each kind of test file, a name with escapes, a test kept for two reasons,
# and a reason with no test.
tree
tests
head_of "$list"
reason "$list" spec-constant "spec constant"
kept "$list" grpc/status_test.mbt "a status's code is the decimal text grpc-status carries"
kept "$list" grpc/status_test.mbt 'a call gets grpc-status 0'
kept "$list" grpc/status_test.mbt 'a name with \"quotes\" and {braces}'
reason "$list" overlap-goldens "deliberate overlap"
kept "$list" engine/store_wbtest.mbt 'a white-box test'
kept "$list" xml/README.mbt.md 'a documented example'
kept "$list" grpc/status_test.mbt 'a call gets grpc-status 0'
reason "$list" dependency-async "dependency"
check good
exits good 0
says good "check-kept-tests: 6 tests under 3 reasons, each found"
lines good 1

# Every rule of rule (C) that the list holds: the four of #275, and the
# tests of smock's own C, which the maintainer added on 2026-11-17.
tree
tests
head_of "$list"
reason "$list" a "spec constant"
reason "$list" b "backend agreement"
reason "$list" c "dependency"
reason "$list" d "deliberate overlap"
reason "$list" e "smock's own C"
check rules
exits rules 0
says rules "check-kept-tests: 0 tests under 5 reasons, each found"

# --- A listed test that is gone ---------------------------------------------

# A test renamed, a file removed, and names that only look like a test's: in
# a comment, in a string, and the start of a longer name. Each is reported
# with its reason, and the others are still checked.
tree
tests
head_of "$list"
reason "$list" spec-constant "spec constant"
kept "$list" grpc/status_test.mbt "a status code is the decimal text grpc-status carries"
kept "$list" grpc/missing_test.mbt 'a test of a file that is gone'
kept "$list" grpc/status_test.mbt 'the code in a comment'
kept "$list" grpc/status_test.mbt 'a string that looks like a test'
kept "$list" grpc/status_test.mbt 'a name'
kept "$list" grpc/status_test.mbt 'a call gets grpc-status 0'
check gone
exits gone 1
says gone "$root/$list: spec-constant: grpc/status_test.mbt: no test named \"a status code is the decimal text grpc-status carries\""
says gone "$root/$list: spec-constant: grpc/missing_test.mbt: no such file"
says gone "$root/$list: spec-constant: grpc/status_test.mbt: no test named \"the code in a comment\""
says gone "$root/$list: spec-constant: grpc/status_test.mbt: no test named \"a string that looks like a test\""
says gone "$root/$list: spec-constant: grpc/status_test.mbt: no test named \"a name\""
says gone "check-kept-tests: 6 tests under 1 reason, 5 problems"
lines gone 6

# A name is compared as the source writes it, escapes included, as moon's
# test metadata names the test: the quotes without their backslashes are
# another name.
tree
tests
head_of "$list"
reason "$list" spec-constant "spec constant"
kept "$list" grpc/status_test.mbt 'a name with "quotes" and {braces}'
check unescaped
exits unescaped 1
says unescaped "$root/$list: spec-constant: grpc/status_test.mbt: no test named \"a name with \"quotes\" and {braces}\""

# A name that two tests of the file have does not tell which one is kept.
tree
tests
cat >>"$root/grpc/status_test.mbt" <<'MBT'

///|
async test "a call gets grpc-status 0" {
  ()
}
MBT
head_of "$list"
reason "$list" spec-constant "spec constant"
kept "$list" grpc/status_test.mbt 'a call gets grpc-status 0'
check twice-in-file
exits twice-in-file 1
says twice-in-file "$root/$list: spec-constant: grpc/status_test.mbt: 2 tests are named \"a call gets grpc-status 0\""

# --- What the list says of each test and reason -----------------------------

# A test listed twice under one reason.
tree
tests
head_of "$list"
reason "$list" spec-constant "spec constant"
kept "$list" grpc/status_test.mbt 'a call gets grpc-status 0'
kept "$list" grpc/status_test.mbt 'a call gets grpc-status 0'
check twice-listed
exits twice-listed 1
says twice-listed "$root/$list: spec-constant: grpc/status_test.mbt: \"a call gets grpc-status 0\" is listed twice"

# A test without its source, with an empty name, with a key the list does
# not know, and with a file that is no test file, or outside the tree.
tree
tests
head_of "$list"
reason "$list" spec-constant "spec constant"
cat >>"$root/$list" <<'TOML'

[[reason.test]]
file = "grpc/status_test.mbt"
name = "a call gets grpc-status 0"

[[reason.test]]
file = "grpc/status_test.mbt"
name = ""
source = "The spec"

[[reason.test]]
file = "grpc/status_test.mbt"
name = "a call gets grpc-status 0"
source = "The spec"
why = "a key the list does not know"

[[reason.test]]
file = "grpc/status.mbt"
name = "a call gets grpc-status 0"
source = "The spec"

[[reason.test]]
file = "../grpc/status_test.mbt"
name = "a call gets grpc-status 0"
source = "The spec"

[[reason.test]]
file = "/grpc/status_test.mbt"
name = "a call gets grpc-status 0"
source = "The spec"

[[reason.test]]
file = "grpc/status_test.mbt"
name = 13
source = "The spec"
TOML
check entries
exits entries 1
says entries "$root/$list: spec-constant: test 1: no source"
says entries "$root/$list: spec-constant: test 2: the name is empty"
says entries "$root/$list: spec-constant: test 3: why is not a key of a test"
says entries "$root/$list: spec-constant: test 4: grpc/status.mbt is not a test file: its name ends in _test.mbt, _wbtest.mbt or .mbt.md"
says entries "$root/$list: spec-constant: test 5: ../grpc/status_test.mbt is not a path inside the tree"
says entries "$root/$list: spec-constant: test 6: /grpc/status_test.mbt is not a path inside the tree"
says entries "$root/$list: spec-constant: test 7: the name is not a string"
says entries "check-kept-tests: 7 tests under 1 reason, 7 problems"
lines entries 8

# A reason without its search, with an empty one, without what the search
# found, with a rule that is not one of rule (C)'s, with an id another
# reason has, and with a key the list does not know.
tree
tests
head_of "$list"
cat >>"$root/$list" <<'TOML'

[[reason]]
id = "no-search"
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
found = "What the search found"

[[reason]]
id = "empty-search"
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
search = []
found = "What the search found"

[[reason]]
id = "nothing-found"
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
search = ["git grep -n test"]

[[reason]]
id = "other-rule"
rule = "a test that is old"
title = "A reason"
source = "Where the reason comes from"
search = ["git grep -n test"]
found = "What the search found"

[[reason]]
id = "no-search"
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
search = ["git grep -n test"]
found = "What the search found"
owner = "a key the list does not know"
TOML
check reasons
exits reasons 1
says reasons "$root/$list: no-search: no search"
says reasons "$root/$list: empty-search: the search is empty"
says reasons "$root/$list: nothing-found: no found"
says reasons "$root/$list: other-rule: the rule is not one of spec constant, backend agreement, dependency, deliberate overlap and smock's own C"
says reasons "$root/$list: no-search: another reason has the id no-search"
says reasons "$root/$list: no-search: owner is not a key of a reason"
says reasons "check-kept-tests: 0 tests under 5 reasons, 6 problems"

# A search that is a string, and one that holds an empty string and a
# number; tests that are not tables.
tree
tests
head_of "$list"
cat >>"$root/$list" <<'TOML'

[[reason]]
id = "string-search"
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
search = "git grep -n test"
found = "What the search found"
test = ["grpc/status_test.mbt"]

[[reason]]
id = "odd-search"
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
search = ["", 1]
found = "What the search found"
test = "grpc/status_test.mbt"
TOML
check shapes
exits shapes 1
says shapes "$root/$list: string-search: the search is not a list"
says shapes "$root/$list: string-search: test 1: is not a table"
says shapes "$root/$list: odd-search: the search holds something that is not a string, or an empty one"
says shapes "$root/$list: odd-search: the test is not a list of tables"
says shapes "check-kept-tests: 1 test under 2 reasons, 4 problems"

# A reason whose id is not lower-case words joined by hyphens, and one with
# no id.
tree
tests
head_of "$list"
reason "$list" "Spec constant" "spec constant"
cat >>"$root/$list" <<'TOML'

[[reason]]
rule = "spec constant"
title = "A reason"
source = "Where the reason comes from"
search = ["git grep -n test"]
found = "What the search found"
TOML
check ids
exits ids 1
says ids "$root/$list: reason 1: the id is not lower-case words joined by hyphens"
says ids "$root/$list: reason 2: no id"

# --- The list as a whole ----------------------------------------------------

# The derived reasons of rule (C) are said, and nothing else stands at the
# top of the list.
tree
tests
file "$list" <<'TOML'
owner = "a key the list does not know"
TOML
reason "$list" spec-constant "spec constant"
check top
exits top 1
says top "$root/$list: no derived: the list says which keep reasons are derived per batch"
says top "$root/$list: owner is not a key of the list"

tree
tests
file "$list" <<'TOML'
[derived]
reasons = []
owner = "a key the list does not know"
TOML
reason "$list" spec-constant "spec constant"
check no-derived
exits no-derived 1
says no-derived "$root/$list: derived: no reasons"
says no-derived "$root/$list: derived: owner is not a key of derived"

# derived and reason of another kind than the list says.
tree
tests
file "$list" <<'TOML'
derived = "the only test of a feature"
reason = "spec constant"
TOML
check kinds
exits kinds 1
says kinds "$root/$list: derived is not a table"
says kinds "$root/$list: reason is not a list of tables"

# A list with no reason.
tree
tests
head_of "$list"
check no-reason
exits no-reason 1
says no-reason "$root/$list: no reason"

# A list that is not TOML, and one that is not there, cannot be checked.
tree
tests
file "$list" <<'TOML'
[derived
TOML
check not-toml
exits not-toml 2
mentions not-toml "check-kept-tests: $root/$list is not TOML:"

tree
check no-list
exits no-list 2
mentions no-list "check-kept-tests: cannot read $root/$list:"

echo
echo "test-check-kept-tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

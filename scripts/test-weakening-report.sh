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
#
# shellcheck disable=SC2016 # the backticks are the report's Markdown, not commands
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

# --- Assertions removed or changed in a test that stays -------------------------

# A timed test: an upper bound in a guard, a comparison kept in a variable,
# and an assertion over several lines.
timed() {
  file add/timed_test.mbt <<'MBT'
///|
test "answers in time" {
  let took = 120L
  guard took < 250L else { fail("took \{took} ms") }
  let fast = took < 300L
  inspect(fast, content="true")
  assert_eq(
    @add.add(took.to_int(), 1),
    121,
  )
}

///|
/// Fails unless the text is short.
fn check_short(text : String) -> Unit raise {
  if text.length() > 10 {
    fail("too long: \{text}")
  }
}
MBT
}

# An exact comparison made weaker.
tree
package
branch
file add/add_test.mbt <<'MBT'
///|
test "adds two numbers" {
  assert_true(@add.add(2, 3) > 0)
}

///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
report weaker
mentions weaker "## Assertions removed or changed in tests that stay"
mentions weaker '`add/add_test.mbt:2`: test "adds two numbers"'
mentions weaker '-  assert_eq(@add.add(2, 3), 5)'
mentions weaker '+  assert_true(@add.add(2, 3) > 0)'
lacks weaker "## Tests deleted"
lacks weaker 'test "adds a negative number"'

# An upper bound raised, in a guard and in a variable.
tree
package
timed
branch
sed -i 's/took < 250L/took < 2500L/; s/took < 300L/took < 3000L/' "$repo/add/timed_test.mbt"
report bound
mentions bound '`add/timed_test.mbt:2`: test "answers in time"'
mentions bound '-  guard took < 250L else { fail("took \{took} ms") }'
mentions bound '+  guard took < 2500L else { fail("took \{took} ms") }'
mentions bound '-  let fast = took < 300L'
mentions bound '+  let fast = took < 3000L'

# The bound in the variable alone: a comparison is an assertion line of
# its own, whatever the lines beside it.
tree
package
timed
branch
sed -i 's/took < 300L/took < 3000L/' "$repo/add/timed_test.mbt"
report bound-variable
mentions bound-variable '-  let fast = took < 300L'
mentions bound-variable '+  let fast = took < 3000L'
lacks bound-variable 'guard'

# A guard whose pattern matches more, and an if whose failure can no longer
# happen, with no comparison on their lines.
tree
package
file add/patterns_test.mbt <<'MBT'
///|
test "answers with a reply" {
  let reply : Int? = Some(5)
  guard reply is Some(5) else {
    fail("no reply")
  }
}

///|
/// Fails when the text is empty.
fn check_filled(text : String) -> Unit raise {
  if text.is_empty() {
    fail("empty")
  }
}
MBT
branch
sed -i 's/Some(5) else/Some(_) else/; s/if text.is_empty() {/if text.is_empty() \&\& false {/' "$repo/add/patterns_test.mbt"
report patterns
mentions patterns '-  guard reply is Some(5) else {'
mentions patterns '+  guard reply is Some(_) else {'
mentions patterns '-  if text.is_empty() {'
mentions patterns '+  if text.is_empty() && false {'

# An assertion removed, and a line changed inside one that spans lines.
tree
package
timed
branch
sed -i '/inspect(fast/d; s/^    121,$/    122,/' "$repo/add/timed_test.mbt"
report removed
mentions removed '-  inspect(fast, content="true")'
mentions removed '-    121,'
mentions removed '+    122,'

# A helper of a test file that no longer fails.
tree
package
timed
branch
sed -i '/fail("too long/d' "$repo/add/timed_test.mbt"
report helper
mentions helper '`add/timed_test.mbt:15`: fn check_short'
mentions helper '-    fail("too long: \{text}")'

# Assertions added to a test that stays, a changed line that asserts
# nothing, and the same test indented in a block of its own weaken nothing.
tree
package
timed
branch
file add/timed_test.mbt <<'MBT'
///|
test "answers in time" {
  let took = 121L
  {
    guard took < 250L else { fail("took \{took} ms") }
    let fast = took < 300L
    inspect(fast, content="true")
    inspect(took > 0L, content="true")
    assert_eq(
      @add.add(took.to_int(), 1),
      121,
    )
  }
}

///|
/// Fails unless the text is short.
fn check_short(text : String) -> Unit raise {
  if text.length() > 10 {
    fail("too long: \{text}")
  }
}
MBT
report extended
empty extended

# A case added inside an assertion, as extending a test adds one, weakens
# nothing.
tree
package
timed
branch
sed -i 's/^    @add.add(took.to_int(), 1),$/    @add.add(took.to_int(), 1),\n    @add.add(1, 1),/' "$repo/add/timed_test.mbt"
report case-added
empty case-added

# A test whose name is extended, with a case added, stays; one whose name
# changes with an assertion is listed under its new name.
tree
package
timed
branch
sed -i 's/test "answers in time"/test "answers in time, under 250 ms"/; s/^  inspect(fast, content="true")$/  inspect(fast, content="true")\n  inspect(took > 100L, content="true")/' "$repo/add/timed_test.mbt"
sed -i 's/test "adds two numbers"/test "adds two positive numbers"/; s/assert_eq(@add.add(2, 3), 5)/assert_eq(@add.add(2, 3), 6)/' "$repo/add/add_test.mbt"
report renamed
lacks renamed "## Tests deleted"
lacks renamed 'answers in time'
mentions renamed '### `add/add_test.mbt:2`: test "adds two numbers"'
mentions renamed 'Now `add/add_test.mbt:2`: test "adds two positive numbers".'
mentions renamed '-  assert_eq(@add.add(2, 3), 5)'
mentions renamed '+  assert_eq(@add.add(2, 3), 6)'

# --- Snapshot lines changed ------------------------------------------------------

# Snapshots: written in the call, over several lines, and in a constant and
# a variable that content= names. The test also reads a multi-line string
# that is its input, not a snapshot.
snapshots() {
  file add/lines_test.mbt <<'MBT'
///|
/// The lines that start_up writes.
let startup : String =
  #|starting
  #|listening

///|
test "writes lines" {
  let input =
    #|a: 1
    #|b: 2
  let expected =
    #|a=1
    #|b=2
  inspect(input.length(), content="9")
  inspect(
    [input, "end"].join("\n"),
    content=(
      #|a: 1
      #|b: 2
      #|end
    ),
  )
  inspect(input, content=expected)
  inspect(input, content=startup)
}
MBT
}

# A snapshot written in the call: the line counts as a snapshot line, not
# as another assertion.
tree
package
branch
sed -i 's/content="-1"/content="-2"/' "$repo/add/add_test.mbt"
report inline
mentions inline "## Snapshot lines changed"
mentions inline '`add/add_test.mbt:7`: test "adds a negative number"'
mentions inline '-  inspect(@add.add(2, -3), content="-1")'
mentions inline '+  inspect(@add.add(2, -3), content="-2")'
lacks inline "## Assertions removed or changed in tests that stay"

# A line of a snapshot over several lines changed, and one added to it.
tree
package
snapshots
branch
sed -i 's/^      #|b: 2$/      #|b: 3/; s/^      #|end$/      #|end\n      #|more/' "$repo/add/lines_test.mbt"
report multiline
mentions multiline '`add/lines_test.mbt:8`: test "writes lines"'
mentions multiline '-      #|b: 2'
mentions multiline '+      #|b: 3'
mentions multiline '+      #|more'
lacks multiline '#|a: 1'

# A snapshot in a variable and in a constant that content= names.
tree
package
snapshots
branch
sed -i 's/^    #|b=2$/    #|b=3/; s/^  #|listening$/  #|ready/' "$repo/add/lines_test.mbt"
report named
mentions named '-    #|b=2'
mentions named '+    #|b=3'
mentions named '`add/lines_test.mbt:3`: let startup'
mentions named '-  #|listening'
mentions named '+  #|ready'
lacks named "## Assertions removed or changed in tests that stay"

# A snapshot of a file in __snapshot__, changed and deleted; a new one is
# not a change.
tree
package
file add/__snapshot__/sum.txt <<'TXT'
5
TXT
file add/__snapshot__/difference.txt <<'TXT'
-1
TXT
branch
echo 6 >"$repo/add/__snapshot__/sum.txt"
remove add/__snapshot__/difference.txt
echo 0 >"$repo/add/__snapshot__/zero.txt"
report snapshot-file
mentions snapshot-file '`add/__snapshot__/sum.txt`'
mentions snapshot-file '+6'
mentions snapshot-file '`add/__snapshot__/difference.txt`'
lacks snapshot-file 'zero.txt'

# The test's input changed, and a new snapshot added, weaken nothing.
tree
package
snapshots
branch
sed -i 's/^    #|b: 2$/    #|b: 2\n    #|c: 3/' "$repo/add/lines_test.mbt"
cat >>"$repo/add/lines_test.mbt" <<'MBT'

///|
test "writes one line" {
  inspect(
    "a",
    content=(
      #|a
    ),
  )
}
MBT
report input
empty input

# --- Skip attributes and settings that keep tests off wasm-gc ---------------------

# A test skipped, a new test skipped, and a test compiled for native alone.
tree
package
branch
file add/add_test.mbt <<'MBT'
///|
#skip
test "adds two numbers" {
  assert_eq(@add.add(2, 3), 5)
}

///|
#cfg(target="native")
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}

///|
#skip("flaky")
test "adds zero" {
  assert_eq(@add.add(2, 0), 2)
}
MBT
report skip
mentions skip "## Skip attributes and target settings added"
mentions skip '`add/add_test.mbt:3`: test "adds two numbers": `#skip`'
mentions skip '`add/add_test.mbt:9`: test "adds a negative number": `#cfg(target="native")`'
mentions skip '`add/add_test.mbt:15`: test "adds zero": `#skip("flaky")`'
lacks skip "## Tests deleted"

# A test that keeps the attribute it had, and gains a skip: only the skip
# is listed.
tree
file add/add_test.mbt <<'MBT'
///|
#cfg(target="native")
test "adds two numbers" {
  assert_eq(2 + 3, 5)
}
MBT
branch
sed -i 's/^#cfg(target="native")$/#cfg(target="native")\n#skip/' "$repo/add/add_test.mbt"
report skip-kept
mentions skip-kept '`add/add_test.mbt:4`: test "adds two numbers": `#skip`'
lacks skip-kept '`#cfg'

# A package whose tests no longer run on wasm-gc.
tree
package
file add/moon.pkg <<'PKG'
import {
  "moonbitlang/core/json",
}
PKG
branch
cat >>"$repo/add/moon.pkg" <<'PKG'

supported_targets = "native"
PKG
report package-targets
mentions package-targets '`add/moon.pkg`: the tests of `add` no longer run on wasm-gc: `supported_targets = "native"`'

# The same in a package's JSON settings, by a list of targets.
tree
package
echo '{ "import": [] }' >"$repo/add/moon.pkg.json"
branch
echo '{ "import": [], "supported-targets": ["native", "js"] }' >"$repo/add/moon.pkg.json"
report package-targets-json
mentions package-targets-json '`add/moon.pkg.json`: the tests of `add` no longer run on wasm-gc'

# A test file that no longer builds for wasm-gc.
tree
package
file add/moon.pkg <<'PKG'
options(
  targets: {
    "add_test.mbt": [ "native", "wasm-gc" ],
  },
)
PKG
branch
sed -i 's/"native", "wasm-gc"/"native"/' "$repo/add/moon.pkg"
report file-targets
mentions file-targets '`add/moon.pkg`: `add/add_test.mbt` no longer runs on wasm-gc: `"add_test.mbt": [ "native" ]`'

# The same in settings that the package had not.
tree
package
branch
file add/moon.pkg <<'PKG'
options(targets: { "add_test.mbt": ["native"] })
PKG
report file-targets-new
mentions file-targets-new '`add/moon.pkg`: `add/add_test.mbt` no longer runs on wasm-gc: `"add_test.mbt": ["native"]`'

# Another import, a package that runs on wasm-gc as well, and one that
# stays native-only weaken nothing.
tree
package
file add/moon.pkg <<'PKG'
supported_targets = "native"
PKG
file sub/sub_test.mbt <<'MBT'
///|
test "subtracts" {
  assert_eq(3 - 2, 1)
}
MBT
file sub/moon.pkg <<'PKG'
supported_targets = "native"
PKG
branch
file add/moon.pkg <<'PKG'
import {
  "moonbitlang/core/json",
}

supported_targets = "native+wasm-gc"
PKG
file sub/moon.pkg <<'PKG'
supported_targets = "-all+native"
PKG
report targets-kept
empty targets-kept

# --- Files that decide a verdict ----------------------------------------------------

# A list of watched paths: a file, a directory and a pattern.
watched() {
  file scripts/verdict-files.txt <<'TXT'
# A comment, and a blank line.

floors.txt          the coverage floors
runner/             the mutation runner and its data
ci/mutation*.yml    the mutation workflows
TXT
  file floors.txt <<'TXT'
add 3
TXT
  file runner/data/sites.txt <<'TXT'
add 12
TXT
}

# A floor raised, a file of the runner's data changed and one added, a
# workflow added; a file beside them that is not listed.
tree
package
watched
branch
echo "add 4" | file floors.txt
echo "add 11" | file runner/data/sites.txt
echo "operators" | file runner/operators.txt
echo "on: push" | file ci/mutation-weekly.yml
echo "on: push" | file ci/other.yml
echo "not runner" | file runner.txt
echo "on: push" | file ci/mutation/deeper.yml
report verdict
mentions verdict "## Files that decide a verdict changed"
mentions verdict '### `floors.txt` (changed)'
mentions verdict 'The coverage floors (listed as `floors.txt`).'
mentions verdict '-add 3'
mentions verdict '+add 4'
mentions verdict '### `runner/data/sites.txt` (changed)'
mentions verdict 'The mutation runner and its data (listed as `runner/`).'
mentions verdict '### `runner/operators.txt` (added)'
mentions verdict '### `ci/mutation-weekly.yml` (added)'
mentions verdict 'The mutation workflows (listed as `ci/mutation*.yml`).'
lacks verdict 'ci/other.yml'
lacks verdict 'runner.txt'
lacks verdict 'ci/mutation/deeper.yml'

# A file deleted, and a path taken off the list while its file changes:
# the list of the base and the head's both count, and a change to the list
# shows whatever it names.
tree
package
watched
branch
remove runner
sed -i '/^floors.txt/d' "$repo/scripts/verdict-files.txt"
echo "add 2" | file floors.txt
report verdict-off
mentions verdict-off '### `runner/data/sites.txt` (deleted)'
mentions verdict-off '### `floors.txt` (changed)'
mentions verdict-off '### `scripts/verdict-files.txt` (changed)'
mentions verdict-off 'The list of the files that decide a verdict (listed as `scripts/verdict-files.txt`).'
mentions verdict-off '-floors.txt          the coverage floors'

# --- The exclusion list's reviewers --------------------------------------------------

# Only the maintainer fills in an entry's reviewer, in a commit the
# maintainer makes or acknowledges at the merge: the report lists every
# entry whose reviewer changed, by its id, and an entry that comes with a
# reviewer (#302). A change to another field shows only in the list's
# diff.
exclusions() {
  file exclusions.toml <<TOML
[[exclusion]]
mutant = "calc/calc.mbt,is_odd,INT,0,-1,0"
text = "90e6c82aa9560cde"
category = "ARID"
reason = "$1"
reviewer = "$2"

[[exclusion]]
file = "engine/crud.mbt"
definition = "crud_call"
position = "5:13"
text = "0123456789abcdef"
category = "UNREACHABLE"
reason = "An abort arm."
reviewer = "$3"
TOML
}
tree
package
exclusions "A default." "" ""
branch
exclusions "Another reason." "" "the maintainer"
cat >>"$repo/exclusions.toml" <<'TOML'

[[exclusion]]
mutant = "calc/calc.mbt,is_blank,NOT,!,,0"
text = "5fd10e41baf9fa48"
category = "ARID"
reason = "A new entry."
reviewer = "the maintainer"

[[exclusion]]
mutant = "calc/calc.mbt,is_blank,INT,0,1,0"
text = "5fd10e41baf9fa48"
category = "ARID"
reason = "A new entry, not reviewed."
reviewer = ""
TOML
report reviewers
mentions reviewers "## Exclusion entries whose reviewer changed"
mentions reviewers '- `engine/crud.mbt,crud_call,5:13`: from none to "the maintainer"'
mentions reviewers '- `calc/calc.mbt,is_blank,NOT,!,,0`: a new entry, reviewed by "the maintainer"'
lacks reviewers '- `calc/calc.mbt,is_odd,INT,0,-1,0`'
lacks reviewers '- `calc/calc.mbt,is_blank,INT,0,1,0`'

# A reviewer taken away shows too.
tree
package
exclusions "A default." "the maintainer" ""
branch
exclusions "A default." "" ""
report reviewer-gone
mentions reviewer-gone '- `calc/calc.mbt,is_odd,INT,0,-1,0`: from "the maintainer" to none'

# A watched Markdown file whose diff holds a fence of its own: the report
# fences the diff with more backticks, so that the fence does not end it.
tree
package
file scripts/verdict-files.txt <<'TXT'
docs/rules.md    the rules
TXT
file docs/rules.md <<'MD'
# Rules
MD
branch
cat >>"$repo/docs/rules.md" <<'MD'

```sh
run it
```
MD
report fence
mentions fence '````diff'
mentions fence '+```sh'
if [ "$(grep -c '^````$' "$tmp/fence.out")" = 1 ]; then
  pass "fence: the diff's fence ends once"
else
  fail "fence: the diff's fence does not end once"
  sed 's/^/     /' "$tmp/fence.out"
fi

# Each path that the committed list names shows, with what the list says
# it is. A path with * or ending in / stands for a file it matches.
list=scripts/verdict-files.txt
tree
package
branch
mkdir -p "$repo/scripts"
cp "$list" "$repo/$list"
entries=0
# shellcheck disable=SC2094 # file writes into the repository, not the list
while read -r pattern description; do
  case $pattern in '' | '#'*) continue ;; esac
  entries=$((entries + 1))
  path=$(printf '%s\n' "$pattern" | sed 's|\*|x|g; s|/$|/x|')
  if [ "$path" != "$list" ]; then
    file "$path" </dev/null
  fi
  printf '%s\t%s\t%s\n' "$path" "$pattern" "$description" >>"$tmp/entries"
done <"$list"
report committed-list
while IFS="$(printf '\t')" read -r path pattern description; do
  first=$(printf '%s' "$description" | cut -c1 | tr '[:lower:]' '[:upper:]')
  mentions committed-list "### \`$path\` (added)"
  mentions committed-list "$first$(printf '%s' "$description" | cut -c2-) (listed as \`$pattern\`)."
done <"$tmp/entries"
if [ "$entries" -ge 10 ]; then
  pass "committed-list: names $entries paths"
else
  fail "committed-list: names $entries paths, fewer than the kinds of file it must name"
fi

# Under the committed list, a change to the coverage floors and a recorded
# raise show line by line: the maintainer's acknowledgment of the report at
# the merge is the approval of each changed floor and recorded raise
# (#297).
tree
package
mkdir -p "$repo/scripts"
cp "$list" "$repo/$list"
printf '%s\n' "# The floors." "engine 103" "prng 0" | file coverage/floors.txt
printf '%s\n' "# The raises." | file coverage/approved-raises.txt
branch
printf '%s\n' "# The floors." "engine 101" "prng 1" | file coverage/floors.txt
printf '%s\n' "# The raises." "prng 1 the abort arm waits for the exclusion list (#302)" | file coverage/approved-raises.txt
report floors
mentions floors '### `coverage/floors.txt` (changed)'
mentions floors '-engine 103'
mentions floors '+engine 101'
mentions floors '-prng 0'
mentions floors '+prng 1'
mentions floors '### `coverage/approved-raises.txt` (changed)'
mentions floors '+prng 1 the abort arm waits for the exclusion list (#302)'

# The committed list names every file of the tools that decide a verdict,
# where the checkout has them, so that a change to any of them is listed:
# #310 lists "the runner and its data" and "the coverage wrapper with its
# floors and scope" among the files that decide a verdict. The mutation
# runner is scripts/mutation/ (#298, #299), and the coverage wrapper, its
# bisect parser and the parser's test data are scripts/coverage.sh,
# scripts/coverage-report.py and scripts/coverage-tests/ (#296); the
# ratchet that holds the floors is scripts/coverage-ratchet.py (#297).
# #308: "Changes to the list and to the recorded verdicts show in the
# weakening report": the canary's mutants with their recorded verdicts,
# its list of explained differences (mutation/canary/) and its workflow.
# #275, "Weakening report": "the mutation and coverage workflows", among
# them the bulk runs' (#313).
tree
package
branch
mkdir -p "$repo/scripts"
cp "$list" "$repo/$list"
git ls-files -- scripts/mutation scripts/coverage.sh scripts/coverage-report.py scripts/coverage-tests \
  scripts/coverage-ratchet.py mutation/canary .github/workflows/mutation-canary.yml \
  .github/workflows/mutation-runs.yml >"$tmp/tool-files"
tools=0
while read -r path; do
  tools=$((tools + 1))
  file "$path" </dev/null
done <"$tmp/tool-files"
report tool-files
while read -r path; do
  mentions tool-files "### \`$path\` (added)"
done <"$tmp/tool-files"
if [ "$tools" -ge 5 ]; then
  pass "tool-files: the checkout has $tools files of the tools"
else
  fail "tool-files: the checkout has $tools files of the tools, fewer than the five it names"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

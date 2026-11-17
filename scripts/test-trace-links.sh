#!/bin/sh
# Tests of the trace links (scripts/trace-links.py), which tie each test to
# the commit that introduced it, the ticket that commit names and that
# issue's acceptance criteria, for the removal proof of #275's removal
# rule. Each test makes a small git repository in a
# temporary directory, with a history in which tests are added, moved and
# changed, runs the script on it with a stand-in for gh that gives the
# issues the test writes, and checks the links it writes out.
#
# It needs what the script needs: python3 and git.
#
# usage: scripts/test-trace-links.sh
set -eu
cd "$(dirname "$0")/.."

script=$PWD/scripts/trace-links.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo

# git looks for a repository no higher than the temporary directory, should
# that be in a checkout, and reads no configuration of the machine's.
export GIT_CEILING_DIRECTORIES="$tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# The stand-in for gh: it notes its arguments in $tmp/gh.args and the
# directory it runs in, whose repository gh asks GitHub about, in
# $tmp/gh.dir, and prints $tmp/issues.jsonl, the issues as `gh api` gives
# them with the script's --jq filter: one JSON object a line. It fails when
# $tmp/gh.fails exists.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TRACE_TEST_TMP/gh.args"
pwd -P >>"$TRACE_TEST_TMP/gh.dir"
if [ -e "$TRACE_TEST_TMP/gh.fails" ]; then
  echo "gh: HTTP 401: Bad credentials" >&2
  exit 1
fi
cat "$TRACE_TEST_TMP/issues.jsonl"
EOF
chmod +x "$tmp/bin/gh"
export TRACE_TEST_TMP="$tmp"
PATH="$tmp/bin:$PATH"

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

# tree: makes $repo anew, a git repository on main with no commit, holding
# one MoonBit module, fix/fix, which is the whole workspace. No issue is
# known yet.
tree() {
  rm -rf "$repo" "$tmp/gh.args" "$tmp/gh.dir" "$tmp/gh.fails"
  : >"$tmp/issues.jsonl"
  git init --quiet --initial-branch=main "$repo"
  file moon.mod <<'EOF'
name = "fix/fix"
EOF
}

# file <path>: writes its standard input to <path> in the tree.
file() {
  mkdir -p "$(dirname "$repo/$1")"
  cat >"$repo/$1"
}

# commit <subject>: commits everything in the tree.
commit() {
  git -C "$repo" add --all
  git -C "$repo" commit --quiet --allow-empty -m "$1"
}

# head: the commit the tree's history ends with now.
head() {
  git -C "$repo" rev-parse HEAD
}

# issue <number> <title> <state>: an issue that gh knows, whose body is the
# standard input.
issue() {
  python3 -c '
import json, sys
labels = sys.argv[4].split(",") if len(sys.argv) > 4 and sys.argv[4] else []
print(json.dumps({"number": int(sys.argv[1]), "title": sys.argv[2], "state": sys.argv[3],
                  "labels": labels, "pull_request": False, "body": sys.stdin.read()}))
' "$@" >>"$tmp/issues.jsonl"
}

# links <name> [arguments]: runs the script on the tree with the arguments,
# its output into $tmp/<name>.json, what it says on its standard error
# into $tmp/<name>.err and its exit status into $tmp/<name>.status.
links() {
  name=$1
  shift
  status=0
  python3 "$script" --repo "$repo" --jobs 2 "$@" >"$tmp/$name.json" 2>"$tmp/$name.err" || status=$?
  echo "$status" >"$tmp/$name.status"
}

# exits <name> <status>: the run <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.err"
  fi
}

# value <name> <expression> <expected>: the Python <expression>, evaluated
# on the output of the run <name> and printed as compact JSON, is
# <expected>. In the expression, `out` is the output, and
# test(<file>, <name>) is the record of the test of that file and name.
value() {
  got=$(python3 -c '
import json, sys
try:
    out = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit("(no JSON output)")
def test(path, name):
    found = [t for t in out["tests"] if t["file"] == path and t["name"] == name]
    if len(found) != 1:
        sys.exit(f"({len(found)} tests named {name!r} in {path})")
    return found[0]
try:
    print(json.dumps(eval(sys.argv[2]), ensure_ascii=False, separators=(",", ":")))
except (KeyError, IndexError, TypeError) as error:
    sys.exit(f"({type(error).__name__}: {error})")
' "$tmp/$1.json" "$2" 2>&1) || true
  if [ "$got" = "$3" ]; then
    pass "$1: $2 is $3"
  else
    fail "$1: $2 is $got, not $3"
  fi
}

# --- A test moved to another file -------------------------------------------

# The ticket's own case (#352): a test block moves from one file to
# another, in another package, and its link still leads to the commit
# that introduced it, the ticket its subject names, and that issue's
# acceptance criteria.
tree
file a/a_test.mbt <<'EOF'
///|
test "a total counts every request" {
  let total = @a.Total::new()
  total.add(2)
  inspect(total.count(), content="2")
}

///|
test "a total starts at zero" {
  inspect(@a.Total::new().count(), content="0")
}
EOF
file b/b_test.mbt <<'EOF'
///|
test "b reads a total back" {
  inspect(@b.read(@a.Total::new()), content="0")
}
EOF
commit "Count requests in totals (#12)"
introduced=$(head)
file a/a_test.mbt <<'EOF'
///|
test "a total starts at zero" {
  inspect(@a.Total::new().count(), content="0")
}
EOF
file b/b_test.mbt <<'EOF'
///|
test "b reads a total back" {
  inspect(@b.read(@a.Total::new()), content="0")
}

///|
test "a total counts every request" {
  let total = @a.Total::new()
  total.add(2)
  inspect(total.count(), content="2")
}
EOF
commit "Move the tests of totals beside their reader (#20)"
issue 12 "Count requests in totals" closed <<'EOF'
## What to build

Totals.

## Acceptance criteria

- [ ] A total counts every request.
- [x] A new total is zero.

## Notes

- Not a criterion.
EOF
issue 20 "Move tests" closed <<'EOF'
## Acceptance criteria

- [ ] The tests of totals are beside their reader.
EOF
links moved
exits moved 0
value moved 'test("b/b_test.mbt", "a total counts every request")["commit"]' "\"$introduced\""
value moved 'test("b/b_test.mbt", "a total counts every request")["introduced_in"]' '"a/a_test.mbt"'
value moved 'test("b/b_test.mbt", "a total counts every request")["issue"]' '12'
value moved 'out["issues"]["12"]["criteria"]' '["A total counts every request.","A new total is zero."]'

# gh is asked once for every issue and pull request, in the checkout, so
# that it asks about the checkout's repository.
if [ "$(cat "$tmp/gh.args")" = "api --paginate repos/{owner}/{repo}/issues?state=all&per_page=100 --jq .[] | {number, title, state, labels: [.labels[].name], pull_request: (.pull_request != null), body}" ]; then
  pass "moved: asks gh once for every issue"
else
  fail "moved: asks gh $(cat "$tmp/gh.args")"
fi
if [ "$(cat "$tmp/gh.dir")" = "$(cd "$repo" && pwd -P)" ]; then
  pass "moved: runs gh in the checkout"
else
  fail "moved: runs gh in $(cat "$tmp/gh.dir")"
fi

# --dump-issues prints the issues as gh gives them, and --issues reads them
# from such a file instead of asking gh, so that the links before and after
# a removal read the same issues.
links dump --dump-issues
exits dump 0
if cmp -s "$tmp/dump.json" "$tmp/issues.jsonl"; then
  pass "dump: prints the issues as gh gives them"
else
  fail "dump: prints something else"
  sed 's/^/     /' "$tmp/dump.json"
fi
sed 's/"Count requests in totals"/"Count requests in totals, as saved"/' "$tmp/issues.jsonl" >"$tmp/saved.jsonl"
rm "$tmp/gh.args"
links saved --issues "$tmp/saved.jsonl"
exits saved 0
value saved 'out["issues"]["12"]["title"]' '"Count requests in totals, as saved"'
value saved 'out["issues"]["12"]["criteria"]' '["A total counts every request.","A new total is zero."]'
if [ -e "$tmp/gh.args" ]; then
  fail "saved: asks gh"
else
  pass "saved: does not ask gh"
fi

# Paths limit the files read, as for the packages a batch touches, and
# the issues to those that the tests read name. What was read is counted
# on the standard error, for CI's log.
links only_b --issues "$tmp/saved.jsonl" b
exits only_b 0
value only_b '[t["name"] for t in out["tests"]]' '["b reads a total back","a total counts every request"]'
value only_b 'sorted(out["issues"])' '["12"]'
if grep -qxF "trace-links: 2 tests, 2 with a ticket; 1 ticket, 0 of them without acceptance criteria" "$tmp/only_b.err"; then
  pass "only_b: counts what it read"
else
  fail "only_b: says $(cat "$tmp/only_b.err")"
fi

# --- When it cannot answer ---------------------------------------------------

# It exits with 2, saying why, when git or gh cannot answer, and prints no
# links then.
links bad_rev --rev no-such-commit
exits bad_rev 2
links no_file --issues "$tmp/no-such-file.jsonl"
exits no_file 2
touch "$tmp/gh.fails"
links gh_fails
exits gh_fails 2
for name in bad_rev no_file gh_fails; do
  if [ -s "$tmp/$name.json" ]; then
    fail "$name: prints links"
  else
    pass "$name: prints no links"
  fi
done
if grep -q "Bad credentials" "$tmp/gh_fails.err"; then
  pass "gh_fails: says what gh said"
else
  fail "gh_fails: says $(cat "$tmp/gh_fails.err")"
fi
if grep -q "no-such-file.jsonl" "$tmp/no_file.err"; then
  pass "no_file: names the file"
else
  fail "no_file: says $(cat "$tmp/no_file.err")"
fi

# A history without tests has no links, and gh is not asked.
tree
file a/a.mbt <<'EOF'
///|
pub fn one() -> Int {
  1
}
EOF
commit "Add a package without tests (#5)"
links no_tests
exits no_tests 0
value no_tests 'out["tests"]' '[]'
value no_tests 'out["issues"]' '{}'
if [ -e "$tmp/gh.args" ]; then
  fail "no_tests: asks gh"
else
  pass "no_tests: does not ask gh"
fi

# A test copied into a file that was there before, and removed from its
# first file in a later commit: blame must look for copies from any file
# of any commit (-C three times) to find where it came from.
tree
file a/a_test.mbt <<'EOF'
///|
test "a total resets to zero when the window ends" {
  let total = @a.Total::new()
  total.add(5)
  total.end_window()
  inspect(total.count(), content="0")
}
EOF
file b/b_test.mbt <<'EOF'
///|
test "b reads a total back" {
  inspect(@b.read(@a.Total::new()), content="0")
}
EOF
commit "Reset totals at the end of each window (#30)"
introduced=$(head)
file b/b_test.mbt <<'EOF'
///|
test "b reads a total back" {
  inspect(@b.read(@a.Total::new()), content="0")
}

///|
test "a total resets to zero when the window ends" {
  let total = @a.Total::new()
  total.add(5)
  total.end_window()
  inspect(total.count(), content="0")
}
EOF
commit "Copy the test of windows beside the reader (#31)"
file a/a_test.mbt </dev/null
commit "Remove the test of windows from a (#32)"
links copied
exits copied 0
value copied 'test("b/b_test.mbt", "a total resets to zero when the window ends")["commit"]' "\"$introduced\""
value copied 'test("b/b_test.mbt", "a total resets to zero when the window ends")["issue"]' '30'

# Tests that change places in their file, and a test that a later commit
# extends with more lines, keep the commit that introduced them.
tree
file a/a_test.mbt <<'EOF'
///|
test "a total counts one request" {
  let total = @a.Total::new()
  total.add(1)
  inspect(total.count(), content="1")
}

///|
test "a total counts no request" {
  let total = @a.Total::new()
  inspect(total.count(), content="0")
}
EOF
commit "Count requests in totals (#40)"
introduced=$(head)
file a/a_test.mbt <<'EOF'
///|
test "a total counts no request" {
  let total = @a.Total::new()
  inspect(total.count(), content="0")
}

///|
test "a total counts one request" {
  let total = @a.Total::new()
  total.add(1)
  inspect(total.count(), content="1")
  total.add(1)
  inspect(total.count(), content="2")
}
EOF
commit "Count a second request, and order the tests by size (#41)"
links in_place
exits in_place 0
value in_place 'test("a/a_test.mbt", "a total counts one request")["commit"]' "\"$introduced\""
value in_place 'test("a/a_test.mbt", "a total counts no request")["commit"]' "\"$introduced\""
value in_place '[t["issue"] for t in out["tests"]]' '[40,40]'

# A test whose name changes keeps the commit that introduced its block:
# the commit that renamed it wrote no other line of the block, so the
# block's commit is the one that wrote most of its lines, though another
# commit wrote the first of them.
tree
file a/a_test.mbt <<'EOF'
///|
test "a total counts requests" {
  let total = @a.Total::new()
  total.add(1)
  inspect(total.count(), content="1")
}
EOF
commit "Count requests in totals (#50)"
introduced=$(head)
file a/a_test.mbt <<'EOF'
///|
test "a total counts requests" {
  inspect(@a.Total::new().count(), content="0")
  let total = @a.Total::new()
  total.add(1)
  inspect(total.count(), content="1")
}
EOF
commit "Check that a total starts at zero (#52)"
file a/a_test.mbt <<'EOF'
///|
test "a total counts each request once" {
  inspect(@a.Total::new().count(), content="0")
  let total = @a.Total::new()
  total.add(1)
  inspect(total.count(), content="1")
}
EOF
commit "Say that a total counts each request once (#51)"
links renamed
value renamed 'test("a/a_test.mbt", "a total counts each request once")["commit"]' "\"$introduced\""
value renamed 'test("a/a_test.mbt", "a total counts each request once")["issue"]' '50'

# A new test that takes the name of an older test in another package is
# not a copy of it: blame finds the header line in the older file, but no
# other line of the block, so the block's commit is the one that wrote
# the rest. (xml/path_test.mbt has such a test: its name is a test's of
# re2/regex_test.mbt.) A line without a letter or a digit, such as the
# blank line that blame finds beside the header in the older file, does
# not count.
tree
file r/r_test.mbt <<'EOF'
///|
test "a compile error position counts characters, not bytes" {

  inspect(@r.error_of("é😀a)"), content="position 3: unexpected )")
}
EOF
commit "Add the regular expressions (#12)"
file x/x_test.mbt <<'EOF'
///|
test "a compile error position counts characters, not bytes" {

  inspect(@x.path_errors(["/名😀/*"]), content="position 4: wildcard * is not supported")
}
EOF
commit "Add the XML paths (#66)"
named=$(head)
links same_name
value same_name 'test("x/x_test.mbt", "a compile error position counts characters, not bytes")["commit"]' "\"$named\""
value same_name 'test("x/x_test.mbt", "a compile error position counts characters, not bytes")["introduced_in"]' '"x/x_test.mbt"'
value same_name 'test("x/x_test.mbt", "a compile error position counts characters, not bytes")["issue"]' '66'
value same_name 'test("r/r_test.mbt", "a compile error position counts characters, not bytes")["issue"]' '12'

# --- The ticket a subject names ---------------------------------------------

# subject <n> <subject>: commits a test file of its own, s/s<n>_test.mbt,
# whose one test is named after <n>.
subject() {
  file "s/s$1_test.mbt" <<EOF
///|
test "subject $1" {
  inspect(@s.subject_number_$1(), content="$1")
}
EOF
  commit "$2"
}

tree
subject 1 "Count requests in totals (#12)"
subject 2 "Say how far one binary's CPU differed between nodes in #39"
subject 3 "Merge integration/grpc: gRPC unary calls with Descriptor sets (spec #134)"
subject 4 "Read the watched files at a poll only when their metadata changed"
subject 5 "Raise moonc and the async runtime (#258, #43)"
subject 6 "Work around moonbitlang/async#725 until it is released"
subject 7 "Mention #12 in a fix that names its own ticket (#40)"
subject 8 "Name an issue that GitHub does not know (#999)"
issue 12 "Count requests in totals" closed </dev/null
issue 39 "CPU between nodes" closed </dev/null
issue 40 "A fix" closed </dev/null
issue 134 "Spec: gRPC unary calls" closed </dev/null
links subjects
exits subjects 0
value subjects '[t["issue"] for t in out["tests"]]' '[12,39,134,null,null,null,40,999]'
value subjects 'sorted(out["issues"])' '["12","134","39","40","999"]'
value subjects 'out["issues"]["999"]' '{"found":false}'
value subjects 'out["issues"]["134"]["title"]' '"Spec: gRPC unary calls"'

# --- An issue's acceptance criteria -----------------------------------------

# The criteria are the items of the list under the heading, or under the
# bold label that a bug's Agent Brief uses, each with the lines indented
# under it, and without its check box, ticked or not. A paragraph between
# items is not a criterion, and the section ends at the next heading of its
# level or above, or, after a label, at the next label. An issue without
# them, such as a spec, has null.
tree
subject 1 "Add the first feature (#61)"
subject 2 "Fix the bug the Agent Brief describes (#62)"
subject 3 "Start the spec (#63)"
subject 4 "Add the second feature (#64)"
issue 61 "First feature" closed <<'EOF'
## What to build

- Not a criterion either.

## Acceptance criteria

- [ ] **Copies.** A Session reads a bucket's initial value.
  - Copies are kept per Mock.
  - The store is sparse.
- [x] **Docs.** The guide says so.

Some prose that is not a criterion.

1. A numbered criterion.
   It goes on here.

### A sub-heading inside the section

- [ ] The last criterion.

## Notes

- [ ] Not a criterion.
EOF
issue 62 "A bug" closed bug <<'EOF'
## Agent Brief

**Category:** bug

**Acceptance criteria:**
- [ ] A test that creates and writes files.
- [ ] An idle poll reads no file's contents, as now.

**Out of scope:**
- Patching moonbitlang/async.
EOF
issue 63 "Spec: everything" open <<'EOF'
## User Stories

1. As a user, I want everything.
EOF
printf '## Acceptance criteria\r\n\r\n- [ ] A criterion written on Windows.\r\n' |
  issue 64 "Second feature" closed
links criteria
exits criteria 0
value criteria 'out["issues"]["61"]["criteria"]' '["**Copies.** A Session reads a bucket'"'"'s initial value.\n  - Copies are kept per Mock.\n  - The store is sparse.","**Docs.** The guide says so.","A numbered criterion.\n   It goes on here.","The last criterion."]'
value criteria 'out["issues"]["62"]["criteria"]' '["A test that creates and writes files.","An idle poll reads no file'"'"'s contents, as now."]'
value criteria 'out["issues"]["62"]["labels"]' '["bug"]'
value criteria 'out["issues"]["63"]["criteria"]' 'null'
value criteria 'out["issues"]["63"]["state"]' '"open"'
value criteria 'out["issues"]["64"]["criteria"]' '["A criterion written on Windows."]'

# --- Which tests, and how they are named ------------------------------------

# Each test is named as moon test names it, so that the kill matrix's
# records can be joined with the links: its package (the module's name and
# the directory), its file, its index among the file's test blocks from 0,
# and its name, or null for a test without one. The name is the literal's
# text with its escapes, as moon test --test-failure-json gives test_name
# (a test "a\u{41}\x42" fails there as "test_name":"a\\u{41}\\x42"). A doc
# test, in a doc comment's mbt block, is of kind doc and has an index of
# its own, as moon test gives it (http1/target.mbt:44 is its #0). The
# tests of a module that is not a member of the workspace, such as a
# fixture of the mutation runner, are not read, and neither is text
# outside a .mbt.md's mbt blocks.
tree
file moon.work <<'EOF'
members = [
  ".",
  "./sub",
]
EOF
file sub/moon.mod <<'EOF'
name = "fix/sub"
EOF
file other/moon.mod <<'EOF'
name = "fix/other"
EOF
file a/a_test.mbt <<'EOF'
///|
fn helper() -> Int {
  1
}

///|
test "a plain test" {
  inspect(helper(), content="1")
}

///|
#skip
async test "an \"escaped\" name, and a backslash \\ too" {
  inspect(helper(), content="1")
}

///|
test "a benchmark" (b : @bench.T) {
  b.bench(fn() { ignore(helper()) })
}
EOF
file sub/README.mbt.md <<'EOF'
# sub

test "not code, but prose" {

```mbt check
///|
test "the first example" {
  inspect(@sub.one(), content="1")
}

///|
test "the second example" {
  inspect(@sub.two(), content="2")
}
```

More prose.

```mbt check
///|
test "the third example" {
  inspect(@sub.one() + @sub.two(), content="3")
}
```
EOF
file sub/doc.mbt <<'EOF'
///|
/// The number one.
///
/// ```mbt check
/// test {
///   inspect(@sub.one(), content="1")
/// }
/// ```
pub fn one() -> Int {
  1
}

///|
/// The number two.
///
/// ```mbt check
/// test {
///   inspect(@sub.two(), content="2")
/// }
/// ```
pub fn two() -> Int {
  2
}
EOF
file other/o_test.mbt <<'EOF'
///|
test "a test of a module outside the workspace" {
  inspect(1, content="1")
}
EOF
commit "Add the packages (#70)"
links naming
exits naming 0
value naming '[[t["package"], t["file"], t["line"], t["index"], t["kind"], t["name"]] for t in out["tests"]]' \
  '[["fix/fix/a","a/a_test.mbt",7,0,"test","a plain test"],["fix/fix/a","a/a_test.mbt",13,1,"test","an \\\"escaped\\\" name, and a backslash \\\\ too"],["fix/fix/a","a/a_test.mbt",18,2,"test","a benchmark"],["fix/sub","sub/README.mbt.md",7,0,"test","the first example"],["fix/sub","sub/README.mbt.md",12,1,"test","the second example"],["fix/sub","sub/README.mbt.md",21,2,"test","the third example"],["fix/sub","sub/doc.mbt",5,0,"doc",null],["fix/sub","sub/doc.mbt",17,1,"doc",null]]'
value naming '{t["issue"] for t in out["tests"]} == {70}' 'true'

# A doc test moves with the function whose doc comment holds it: blame
# reads it together with the rest of that item, since its own few lines
# are too short for git to tell where they came from.
file sub/doc.mbt <<'EOF'
///|
/// The number one.
///
/// ```mbt check
/// test {
///   inspect(@sub.one(), content="1")
/// }
/// ```
pub fn one() -> Int {
  1
}
EOF
file sub/two.mbt <<'EOF'
///|
/// The number two.
///
/// ```mbt check
/// test {
///   inspect(@sub.two(), content="2")
/// }
/// ```
pub fn two() -> Int {
  2
}
EOF
commit "Give the number two a file of its own (#71)"
links doc_moved
value doc_moved '[[t["file"], t["index"], t["issue"], t["introduced_in"]] for t in out["tests"] if t["kind"] == "doc"]' \
  '[["sub/doc.mbt",0,70,"sub/doc.mbt"],["sub/two.mbt",0,70,"sub/doc.mbt"]]'

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]

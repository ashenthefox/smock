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

# The stand-in for gh: it notes its arguments in $tmp/gh.args and prints
# $tmp/issues.jsonl, the issues as `gh api` gives them with the script's
# --jq filter: one JSON object a line. It fails when $tmp/gh.fails exists.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TRACE_TEST_TMP/gh.args"
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
  rm -rf "$repo" "$tmp/gh.args" "$tmp/gh.fails"
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

# A test whose name changes is, for moon and for its header line, a new
# test: its link is the commit that gave it the name it has.
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
file a/a_test.mbt <<'EOF'
///|
test "a total counts each request once" {
  let total = @a.Total::new()
  total.add(1)
  inspect(total.count(), content="1")
}
EOF
commit "Say that a total counts each request once (#51)"
renamed=$(head)
links renamed
value renamed 'test("a/a_test.mbt", "a total counts each request once")["commit"]' "\"$renamed\""
value renamed 'test("a/a_test.mbt", "a total counts each request once")["issue"]' '51'

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

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]

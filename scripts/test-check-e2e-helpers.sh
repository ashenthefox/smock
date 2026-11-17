#!/bin/sh
# Tests of the check that no e2e test file uses what another test file
# defines (scripts/check-e2e-helpers.py). Each test writes a small module
# into a temporary directory, with a package of test files, runs the check
# on it, and checks its exit status and what it prints: each use, and the
# count, which says that it found no other.
#
# It needs what the check needs: python3, and moon and moonc on PATH.
#
# usage: scripts/test-check-e2e-helpers.sh
set -eu
cd "$(dirname "$0")/.."
repo=$(pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/module

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

# module [package]: makes $root anew, a module with one native package,
# e2e or <package>, that holds no file yet. The package imports nothing.
module() {
  rm -rf "$root"
  mkdir -p "$root/${1:-e2e}"
  printf 'name = "example/fixture"\n' >"$root/moon.mod"
  printf 'supported_targets = "native"\n' >"$root/${1:-e2e}/moon.pkg"
}

# file <path>: writes its standard input to <path> in the module.
file() {
  mkdir -p "$(dirname "$root/$1")"
  cat >"$root/$1"
}

# harness: writes the harness file e2e/harness_test.mbt, with a type, a
# trait, a function and a value that every test file may use.
harness() {
  file e2e/harness_test.mbt <<'MBT'
///|
/// What the harness serves.
struct Thing {
  n : Int
}

///|
trait Greet {
  greet(Self) -> String
}

///|
fn shared() -> Int {
  1
}

///|
let patience : Int = 20
MBT
}

# check <name> [package]: runs the check in the module, on e2e or on
# <package>, its output into $tmp/<name>.out and its exit status into
# $tmp/<name>.status.
check() {
  status=0
  (cd "$root" && python3 "$repo/scripts/check-e2e-helpers.py" ${2:+"$2"}) \
    >"$tmp/$1.out" 2>&1 || status=$?
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

# A test file that uses only the harness and what it defines itself passes,
# and so does a local name that another file also defines at the top level:
# the compiler, not the text, decides what a name refers to.
module
harness
file e2e/a_test.mbt <<'MBT'
///|
fn only_a() -> Int {
  2
}

///|
test "a" {
  assert_eq(shared() + only_a(), 3)
}
MBT
file e2e/b_test.mbt <<'MBT'
///|
test "b" {
  let only_a = patience
  assert_eq(only_a + shared(), 21)
}
MBT
check clean
exits clean 0
says clean "check-e2e-helpers: e2e: each of the 2 test files checks with the 1 harness file alone"
lines clean 1

# Each kind of top-level item that a test file can define, used by another
# test file, is named with the file that defines it, at the line of its
# first use. A use the check cannot name keeps the compiler's message.
module
harness
file e2e/a_test.mbt <<'MBT'
///|
fn only_a() -> Int {
  2
}

///|
let a_value : Int = 3

///|
const A_CONST : Int = 4

///|
enum Shape {
  Circle
  Square(Int)
}

///|
struct Point {
  x : Int
  mut y : Int
}

///|
fn Thing::twice(self : Thing) -> Int {
  self.n * 2
}

///|
async fn Thing::slowly(self : Thing) -> Int {
  self.n
}

///|
impl Show for Thing with output(_self, logger) {
  logger.write_string("thing")
}

///|
impl Greet for Thing with greet(_self) {
  "hi"
}

///|
suberror Oops

///|
fn pairs() -> Map[String, Int] {
  { "k": 1 }
}

///|
async fn later() -> Int {
  5
}

///|
fn[T] first(xs : Array[T]) -> T {
  xs[0]
}

///|
test "a" {
  assert_eq(only_a(), 2)
}
MBT
file e2e/b_test.mbt <<'MBT'
///|
test "b" {
  assert_eq(only_a(), 2)
  assert_eq(only_a(), 2)
  assert_eq(a_value, 3)
  assert_eq(A_CONST, 4)
  let s : Shape = Circle
  ignore(s)
  ignore(Square(1))
  ignore({ x: 1, y: 2 })
  let t = Thing::{ n: 1 }
  assert_eq(t.twice(), 2)
  inspect(t, content="thing")
  let e : Error = Oops
  ignore(e)
  match pairs() {
    { "k": v, .. } => assert_eq(v, 1)
    _ => ()
  }
  assert_eq(first([1]), 1)
  assert_eq(t.greet(), "hi")
}

///|
async fn sooner(t : Thing) -> Int {
  later() - t.slowly()
}
MBT
check kinds
exits kinds 1
says kinds "e2e/b_test.mbt:3: uses only_a, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:5: uses a_value, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:6: uses A_CONST, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:7: uses Shape, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:9: uses Square, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:10: uses Point, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:12: uses Thing::twice, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:13: uses impl Show for Thing, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:14: uses Oops, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:16: uses pairs, which e2e/a_test.mbt defines"
mentions kinds "e2e/b_test.mbt:17: Please implement method \`get\`"
says kinds "e2e/b_test.mbt:20: uses first, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:21: uses Thing::greet, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:26: uses later, which e2e/a_test.mbt defines"
says kinds "e2e/b_test.mbt:26: uses Thing::slowly, which e2e/a_test.mbt defines"
says kinds "check-e2e-helpers: e2e: 1 of 2 test files uses what another test file defines"
lines kinds 16

# The harness files may use each other, but nothing a test file defines.
module
harness
file e2e/http2_harness_test.mbt <<'MBT'
///|
fn twice_shared() -> Int {
  shared() * 2
}

///|
fn needs_a() -> Int {
  only_a()
}
MBT
file e2e/a_test.mbt <<'MBT'
///|
fn only_a() -> Int {
  2
}

///|
test "a" {
  assert_eq(twice_shared() + needs_a(), 4)
}
MBT
file e2e/b_test.mbt <<'MBT'
///|
test "b" {
  assert_eq(twice_shared(), 2)
}
MBT
check harness
exits harness 1
says harness "e2e/http2_harness_test.mbt:8: uses only_a, which e2e/a_test.mbt defines"
says harness "check-e2e-helpers: e2e: the 2 harness files use what a test file defines"
lines harness 2

# With that use gone, the harness files check alone, and so does the file.
file e2e/http2_harness_test.mbt <<'MBT'
///|
fn twice_shared() -> Int {
  shared() * 2
}
MBT
file e2e/a_test.mbt <<'MBT'
///|
test "a" {
  assert_eq(twice_shared(), 2)
}
MBT
check harnesses
exits harnesses 0
says harnesses "check-e2e-helpers: e2e: each of the 2 test files checks with the 2 harness files alone"

# Several files that use what others define are each named, in name order,
# and a file that two others use is named for each.
module
harness
file e2e/c_test.mbt <<'MBT'
///|
fn from_c() -> Int {
  3
}
MBT
file e2e/b_test.mbt <<'MBT'
///|
test "b" {
  assert_eq(from_c(), 3)
}
MBT
file e2e/a_test.mbt <<'MBT'
///|
test "a" {
  assert_eq(from_c(), 3)
}
MBT
check several
exits several 1
says several "e2e/a_test.mbt:3: uses from_c, which e2e/c_test.mbt defines"
says several "e2e/b_test.mbt:3: uses from_c, which e2e/c_test.mbt defines"
says several "check-e2e-helpers: e2e: 2 of 3 test files use what another test file defines"
lines several 3
if [ "$(head -1 "$tmp/several.out")" = "e2e/a_test.mbt:3: uses from_c, which e2e/c_test.mbt defines" ]; then
  pass "several: a_test.mbt comes first"
else
  fail "several: a_test.mbt does not come first"
fi

# Another package than e2e is checked the same way.
module journeys
file journeys/harness_test.mbt <<'MBT'
///|
fn shared() -> Int {
  1
}
MBT
file journeys/a_test.mbt <<'MBT'
///|
fn only_a() -> Int {
  2
}
MBT
file journeys/b_test.mbt <<'MBT'
///|
test "b" {
  assert_eq(only_a() + shared(), 3)
}
MBT
check package journeys
exits package 1
says package "journeys/b_test.mbt:3: uses only_a, which journeys/a_test.mbt defines"
says package "check-e2e-helpers: journeys: 1 of 2 test files uses what another test file defines"

# A package that does not check as a whole cannot be judged file by file.
module
harness
file e2e/a_test.mbt <<'MBT'
///|
test "a" {
  assert_eq(nowhere(), 1)
}
MBT
check broken
exits broken 2
mentions broken "The value identifier nowhere is unbound"
says broken "check-e2e-helpers: e2e does not check as a whole"

# A package with no harness file, or with no test file, is not what the
# check is for.
module
file e2e/a_test.mbt <<'MBT'
///|
test "a" {
  ()
}
MBT
check no-harness
exits no-harness 2
says no-harness "check-e2e-helpers: e2e has no harness file (a name that ends in harness_test.mbt)"

module
harness
check no-tests
exits no-tests 2
says no-tests "check-e2e-helpers: e2e has no test file besides the harness files"

module
rm -rf "$root/e2e"
check no-package
exits no-package 2
says no-package "check-e2e-helpers: e2e is not a directory"

echo
echo "test-check-e2e-helpers: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

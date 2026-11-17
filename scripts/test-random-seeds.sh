#!/bin/sh
# Tests of scripts/random-seeds.py, which writes a random seed into each
# property's seed constant in a working copy and prints it, for the weekly
# run of the properties with random seeds (CONTRIBUTING.md, "Seeds"). Each
# test runs it on a copy of re2's property, or on a small tree of test
# files, and checks what it prints, its exit status, and that it changed
# only the seed constants' values, to the seeds it printed.
#
# usage: scripts/test-random-seeds.sh
set -eu
cd "$(dirname "$0")/.."

root=$(pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

property=re2/full_match_wbtest.mbt
cr=$(printf '\r')

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

# seeds <name> [<path>...]: runs the script in $tmp/tree on the paths into
# $tmp/<name>.out, and its exit status into $tmp/<name>.status.
seeds() {
  name=$1
  shift
  status=0
  (cd "$tmp/tree" && python3 "$root/scripts/random-seeds.py" "$@") >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# exits <name> <status>: the run <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <line>: the run <name> printed <line>.
says() {
  if grep -qxF -- "$2" "$tmp/$1.out"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# lines <name> <count>: the run <name> printed <count> lines.
lines() {
  count=$(wc -l <"$tmp/$1.out" | tr -d ' ')
  if [ "$count" = "$2" ]; then
    pass "$1: prints $2 line(s)"
  else
    fail "$1: prints $count line(s), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# printed <name> <file> <constant>: the seed that the run <name> printed for
# <constant> in <file>, at the line where <file> holds it.
printed() {
  line=$(grep -n "^const $3 : UInt64 = " "$tmp/tree/$2" | cut -d: -f1)
  sed -n "s|^$2:$line: $3 = \\([0-9]*\\)\$|\\1|p" "$tmp/$1.out"
}

# rewritten <name> <file> <original> <constant>...: the run <name> printed a
# seed for each constant of <file>, each seed is a UInt64, and <file> is
# <original> with each constant's value replaced by its seed, and nothing
# else changed.
rewritten() {
  name=$1
  file=$2
  cp "$3" "$tmp/expected"
  shift 3
  for constant in "$@"; do
    seed=$(printed "$name" "$file" "$constant")
    if [ -z "$seed" ]; then
      fail "$name: prints no seed for $constant at its line of $file"
      sed 's/^/     /' "$tmp/$name.out"
      return
    fi
    if python3 -c 'import sys; sys.exit(0 if 0 <= int(sys.argv[1]) < 2**64 else 1)' "$seed"; then
      pass "$name: the seed of $constant is a UInt64 ($seed)"
    else
      fail "$name: the seed of $constant, $seed, is not a UInt64"
    fi
    sed "s|^const $constant : UInt64 = [0-9]*\\($cr\\{0,1\\}\\)\$|const $constant : UInt64 = $seed\\1|" "$tmp/expected" >"$tmp/expected.next"
    mv "$tmp/expected.next" "$tmp/expected"
  done
  if cmp -s "$tmp/expected" "$tmp/tree/$file"; then
    pass "$name: $file changed only in its seeds' values, to the seeds printed"
  else
    fail "$name: $file changed otherwise:"
    diff "$tmp/expected" "$tmp/tree/$file" | sed 's/^/     /' || true
  fi
}

# unchanged <name> <file> <original>: the run <name> left <file> as it was.
unchanged() {
  if cmp -s "$2" "$tmp/tree/$1"; then
    pass "$3: leaves $1 as it was"
  else
    fail "$3: changed $1"
    diff "$2" "$tmp/tree/$1" | sed 's/^/     /' || true
  fi
}

# tree: empties $tmp/tree.
tree() {
  rm -rf "$tmp/tree"
  mkdir -p "$tmp/tree"
}

# --- re2's property ----------------------------------------------------------

# On a copy of the property's file, the script changes only the seed
# constant's value, to the seed it prints.
tree
mkdir -p "$tmp/tree/re2"
cp "$property" "$tmp/tree/re2/"
seeds property re2/full_match_wbtest.mbt
exits property 0
lines property 1
rewritten property re2/full_match_wbtest.mbt "$property" FULL_MATCH_SEED

# Each run draws another seed.
cp "$tmp/tree/re2/full_match_wbtest.mbt" "$tmp/first.mbt"
seeds again re2/full_match_wbtest.mbt
exits again 0
rewritten again re2/full_match_wbtest.mbt "$tmp/first.mbt" FULL_MATCH_SEED
if [ "$(printed property re2/full_match_wbtest.mbt FULL_MATCH_SEED)" != "$(printed again re2/full_match_wbtest.mbt FULL_MATCH_SEED)" ]; then
  pass "again: draws another seed"
else
  fail "again: draws the same seed twice"
fi

# Given a directory, it finds the property in it.
tree
mkdir -p "$tmp/tree/re2"
cp "$property" "$tmp/tree/re2/"
seeds directory re2
exits directory 0
lines directory 1
rewritten directory re2/full_match_wbtest.mbt "$property" FULL_MATCH_SEED

# --- A tree of test files ----------------------------------------------------

# Without a path, it reads every test file of the tree it runs in, black-box
# and white-box, and only test files: a constant elsewhere, or in a build
# directory, is not a property's seed.
tree
mkdir -p "$tmp/tree/a" "$tmp/tree/b/c" "$tmp/tree/_build/a" "$tmp/tree/.mooncakes/x" "$tmp/tree/target/a"
cat >"$tmp/a.mbt" <<'MBT'
///|
/// Two properties in one file.
const FIRST_SEED : UInt64 = 1

///|
const SECOND_SEED : UInt64 = 18446744073709551615

///|
test "uses them" {
  inspect(FIRST_SEED + SECOND_SEED, content="0")
}
MBT
cat >"$tmp/c.mbt" <<'MBT'
///|
const THIRD_SEED : UInt64 = 42
MBT
cat >"$tmp/other.mbt" <<'MBT'
///|
/// Not a test file.
const CODE_SEED : UInt64 = 7
MBT
# Lines that end in CR LF, and no line break at the end: both stay.
printf '///|\r\nconst FOURTH_SEED : UInt64 = 4\r\n\r\n///|\r\ntest "x" {\r\n}' >"$tmp/b.mbt"
# The files are made out of order, so that the order in which a directory
# lists them is not likely to be theirs.
cp "$tmp/a.mbt" "$tmp/tree/a/a_test.mbt"
cp "$tmp/c.mbt" "$tmp/tree/a/c_test.mbt"
cp "$tmp/b.mbt" "$tmp/tree/a/b_test.mbt"
cp "$tmp/c.mbt" "$tmp/tree/b/c/c_wbtest.mbt"
cp "$tmp/other.mbt" "$tmp/tree/a/other.mbt"
for dir in _build/a .mooncakes/x target/a; do
  cp "$tmp/c.mbt" "$tmp/tree/$dir/c_test.mbt"
done
seeds tree
exits tree 0
lines tree 5
rewritten tree a/a_test.mbt "$tmp/a.mbt" FIRST_SEED SECOND_SEED
rewritten tree a/b_test.mbt "$tmp/b.mbt" FOURTH_SEED
rewritten tree a/c_test.mbt "$tmp/c.mbt" THIRD_SEED
rewritten tree b/c/c_wbtest.mbt "$tmp/c.mbt" THIRD_SEED
unchanged a/other.mbt "$tmp/other.mbt" tree
for dir in _build/a .mooncakes/x target/a; do
  unchanged "$dir/c_test.mbt" "$tmp/c.mbt" tree
done
if [ "$(cut -d: -f1 "$tmp/tree.out" | tr '\n' ' ')" = "a/a_test.mbt a/a_test.mbt a/b_test.mbt a/c_test.mbt b/c/c_wbtest.mbt " ]; then
  pass "tree: prints the constants in the order of their files and lines"
else
  fail "tree: prints the constants in another order"
  sed 's/^/     /' "$tmp/tree.out"
fi

# --- What it refuses ---------------------------------------------------------

# A line that declares a seed constant in another form fails the run, and
# the script writes no seed anywhere, so that no property keeps its fixed
# seed in a weekly run unnoticed.
for form in \
  "const BAD_SEED : UInt64 = 0x2a" \
  "const BAD_SEED : UInt64 = 42UL" \
  "const BAD_SEED : Int64 = 42" \
  "const BAD_SEED = 42" \
  "  const BAD_SEED : UInt64 = 42" \
  "const BAD_SEED : UInt64 = 42 // a comment" \
  "pub const BAD_SEED : UInt64 = 42" \
  "let BAD_SEED : UInt64 = 42"; do
  tree
  mkdir -p "$tmp/tree/a"
  cp "$tmp/c.mbt" "$tmp/tree/a/c_test.mbt"
  printf '///|\n%s\n' "$form" >"$tmp/bad.mbt"
  cp "$tmp/bad.mbt" "$tmp/tree/a/later_test.mbt"
  seeds malformed
  exits malformed 2
  says malformed "random-seeds: a/later_test.mbt:2: a seed constant is written 'const <NAME>_SEED : UInt64 = <digits>', alone on its line: $form"
  unchanged a/c_test.mbt "$tmp/c.mbt" "malformed ($form)"
  unchanged a/later_test.mbt "$tmp/bad.mbt" "malformed ($form)"
done

# A seed too large for a UInt64 is refused too: the committed seed would not
# build.
tree
printf 'const BIG_SEED : UInt64 = 18446744073709551616\n' >"$tmp/tree/big_test.mbt"
seeds too-large
exits too-large 2
says too-large "random-seeds: big_test.mbt:1: BIG_SEED's value is larger than a UInt64 holds"

# No seed constant at all: nothing to run with a random seed.
tree
mkdir -p "$tmp/tree/a"
cp "$tmp/other.mbt" "$tmp/tree/a/other_test.mbt"
sed -i 's/CODE_SEED/CODE_SEEDS/' "$tmp/tree/a/other_test.mbt"
seeds none
exits none 1
says none "random-seeds: no seed constant in ."

# A path that does not exist.
tree
seeds missing nowhere
exits missing 2
says missing "random-seeds: nowhere does not exist"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

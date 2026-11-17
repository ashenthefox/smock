#!/bin/sh
# Tests of the changed-lines job (scripts/changed-lines.py), which the
# branch checks workflow runs on each push to a branch other than main:
# its plan counts the mutants on the lines that the branch changes and
# shards them, each shard runs its part, and its report lists the
# survivors. Each test makes a small git repository in a temporary
# directory, as CI's checkout is: a module with a pure package and a
# package that builds only natively on main, origin/main naming main's
# last commit, and a branch that changes lines. A fake runner stands in
# for scripts/mutation/run.py: it finds the changed lines with the
# runner's own diff mode (scripts/mutation/changed.py, which runs only
# git), makes one mutant on each, and gives each the outcome that a word
# on its line names. The tests run the job's steps as the workflow does,
# the plan, each shard it plans and the report, and check the runner's
# calls, the plan's outputs and the report.
#
# The rules come from the ticket (#311): a diff within the shards' budget
# runs every mutant on its changed lines and is reported covered; a larger
# one is reported as not covered, and its report says so, while a run
# started by hand runs it whole; a push that changes no non-test line of a
# pure package runs nothing; the report lists each unexplained survivor
# with its package, diff and enclosing definition, and each stale-covered
# one with its stale entry's id. The budget is CONTRIBUTING.md's, "The
# changed-lines job".
#
# It needs python3, git and jq.
#
# usage: scripts/test-changed-lines.sh
#
# shellcheck disable=SC2016 # the backticks are the report's Markdown, not commands
set -eu
cd "$(dirname "$0")/.."

script=$PWD/scripts/changed-lines.py
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

# The fake runner. It takes the options of run.py that the job passes,
# appends its arguments to $FAKE_RUNNER_LOG, with the temporary directory
# written as <tmp>, and fails as the runner does with FAKE_RUNNER=fail.
# Each changed line that changed.py gives holds one mutant, unless the line
# says "nosite"; a line that says "survives", "deferred", "stale" or
# "accepted" holds a survivor, which is unexplained, unexplained with a
# DEFERRED entry, stale-covered or accepted by the exclusion list; any
# other line's mutant is killed. With --sites-only it writes the summary
# alone; with --shard k/n, the records of the k-th of n parts of the
# mutants, in order, whose sizes differ by one at most.
cat >"$tmp/fake-run.py" <<'PY'
import argparse, json, os, posixpath, sys
from pathlib import Path

sys.path.insert(0, os.environ["MUTATION_SCRIPTS"])
import changed

parser = argparse.ArgumentParser()
parser.add_argument("--root", default=".")
parser.add_argument("--out", required=True)
parser.add_argument("--changed", action="store_true")
parser.add_argument("--base")
parser.add_argument("--sites-only", action="store_true")
parser.add_argument("--shard")
args = parser.parse_args()
with open(os.environ["FAKE_RUNNER_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(sys.argv[1:]).replace(os.environ["FAKE_TMP"], "<tmp>") + "\n")
if os.environ.get("FAKE_RUNNER") == "fail":
    print("run: the tests of calc fail without a mutant", file=sys.stderr)
    sys.exit(1)
root = Path(args.root)
info = changed.find(root, args.base, [])
mutants = []
for file, numbers in info["lines"].items():
    lines = (root / file).read_text(encoding="utf-8").split("\n")
    for n in numbers:
        text = lines[n - 1]
        if "nosite" in text:
            continue
        record = {"id": f"{file},line_{n},FAKE,{n},{n + 1},0", "file": file, "definition": f"line_{n}",
                  "definition_lines": [n, n], "package": "test/m/" + posixpath.dirname(file),
                  "outcome": "killed", "killing_tests": ["test/m/calc/calc_test.mbt::t"]}
        for word, exclusion in (
                ("survives", {"status": "unexplained"}),
                ("deferred", {"status": "unexplained", "entry": f"{file},line_{n},FAKE,{n},{n + 1},0",
                              "category": "DEFERRED", "issue": 7}),
                ("stale", {"status": "stale-covered", "entry": f"{file},line_{n},FAKE,{n},{n + 1},0",
                           "category": "EQUIVALENT"}),
                ("accepted", {"status": "accepted", "entry": f"{file},line_{n},FAKE,{n},{n + 1},0",
                              "category": "EQUIVALENT"})):
            if word in text:
                record.update(outcome="survived", killing_tests=[], exclusion=exclusion,
                              diff=f"--- {file}\n+++ {file}\n@@ -{n} +{n} @@\n-{text}\n+{text} + 1\n")
        mutants.append(record)
info["mutants"] = len(mutants)
selection = {"set": "pinned", "shard": None}
if args.shard:
    k, n = map(int, args.shard.split("/"))
    size, extra = divmod(len(mutants), n)
    start = (k - 1) * size + min(k - 1, extra)
    mutants = mutants[start:start + size + (1 if k <= extra else 0)]
    selection["shard"] = {"index": k, "count": n}
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
(out / "summary.json").write_text(json.dumps({"operator_set": "v1", "set": "pinned", "selection": selection,
                                               "changed": info, "packages": []}, indent=2))
with open(out / "mutants.jsonl", "w", encoding="utf-8") as f:
    for record in [] if args.sites_only else mutants:
        f.write(json.dumps(record) + "\n")
(out / "report.md").write_text("# Mutants on changed lines\n")
PY
export MUTATION_SCRIPTS="$PWD/scripts/mutation"
export FAKE_TMP="$tmp"
runner="python3 $tmp/fake-run.py"

# history: makes $repo anew, a repository with the module test/m on main:
# the pure package calc (calc.mbt, its test and a generated file) and the
# package host, which builds only natively. A branch, topic, is checked
# out from that commit, and main then moves on with a change of its own
# to calc.mbt, which origin/main names, as in CI's checkout. Its first
# commit is $base.
history() {
  rm -rf "$repo"
  git init --quiet --initial-branch=main "$repo"
  printf '{ "name": "test/m" }\n' >"$repo/moon.mod.json"
  mkdir -p "$repo/calc" "$repo/host"
  : >"$repo/calc/moon.pkg"
  printf 'supported_targets = "native"\n' >"$repo/host/moon.pkg"
  i=1
  while [ "$i" -le 9 ]; do
    printf 'let a%s : Int = %s\n' "$i" "$i"
    i=$((i + 1))
  done >"$repo/calc/calc.mbt"
  printf 'test "t" {\n  assert_eq(1, 1)\n}\n' >"$repo/calc/calc_test.mbt"
  printf '// Generated by a test. Do not edit.\nlet g : Int = 0\n' >"$repo/calc/gen.mbt"
  printf 'let h : Int = 0\n' >"$repo/host/host.mbt"
  git -C "$repo" add --all
  git -C "$repo" commit --quiet -m base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout --quiet -b topic
  git -C "$repo" checkout --quiet main
  sed -i 's/^let a9 : Int = 9$/let a9 : Int = 90 \/\/ survives/' "$repo/calc/calc.mbt"
  git -C "$repo" commit --quiet -am "main moves on"
  git -C "$repo" update-ref refs/remotes/origin/main main
  git -C "$repo" checkout --quiet topic
}

# change <message>: commits on topic what its standard input, a shell
# script run in $repo, changes.
change() {
  (cd "$repo" && sh -eu)
  git -C "$repo" add --all
  git -C "$repo" commit --quiet -m "$1"
}

# lines <file> <count> <word>: appends <count> lines to <file> in $repo,
# each with <word> in a comment.
lines() {
  i=1
  while [ "$i" -le "$2" ]; do
    printf 'let b%s : Int = %s // %s\n' "$i" "$i" "$3"
    i=$((i + 1))
  done >>"$repo/$1"
}

# job <name> [<by hand>]: runs the job's steps in $repo as the workflow
# does, into $tmp/<name>: the plan (with --by-hand <by hand>, empty for a
# push), each shard it plans, and the report. Each step's exit status goes
# into $tmp/<name>/<step>.status and its output into
# $tmp/<name>/<step>.out and .err; the runner's calls into
# $tmp/<name>/runner.log. A step that fails stops the job, as in the
# workflow.
job() {
  dir=$tmp/$1
  rm -rf "$dir"
  mkdir -p "$dir/shards"
  export FAKE_RUNNER_LOG="$dir/runner.log"
  : >"$FAKE_RUNNER_LOG"
  step "$1" plan plan --root "$repo" --runner "$runner" --by-hand "${2:-}" --out "$dir/plan" || return 0
  for shard in $(sed -n 's/^shards=//p' "$dir/plan.out" | jq -r '.[]'); do
    step "$1" "shard-$shard" shard --root "$repo" --runner "$runner" --plan "$dir/plan" --shard "$shard" \
      --out "$dir/shards/changed-lines-shard-$shard" || return 0
  done
  step "$1" report report --plan "$dir/plan" --shards "$dir/shards" --out "$dir/report" || return 0
}

# step <job> <step> <argument>...: runs the script with the arguments, as
# the step <step> of the job <job>.
step() {
  name=$1 what=$2
  shift 2
  status=0
  python3 "$script" "$@" >"$tmp/$name/$what.out" 2>"$tmp/$name/$what.err" || status=$?
  echo "$status" >"$tmp/$name/$what.status"
  return "$status"
}

# Each check below names its job and what it checks.

# status <job> <step> <status>: the step exited with <status>.
status() {
  if [ "$(cat "$tmp/$1/$2.status" 2>/dev/null)" = "$3" ]; then
    pass "$1: $2 exits with $3"
  else
    fail "$1: $2 exits with $(cat "$tmp/$1/$2.status" 2>/dev/null || echo nothing), not $3"
    sed 's/^/     /' "$tmp/$1/$2.err" 2>/dev/null || true
  fi
}

# outputs <job> <line>...: the plan printed these lines, the step's
# outputs, and nothing else.
outputs() {
  name=$1
  shift
  if [ "$(cat "$tmp/$name/plan.out")" = "$(printf '%s\n' "$@")" ]; then
    pass "$name: the plan's outputs are $*"
  else
    fail "$name: the plan's outputs are $(cat "$tmp/$name/plan.out"), not $*"
  fi
}

# calls <job> <call>...: the runner was called so, in this order, and no
# more.
calls() {
  name=$1
  shift
  if [ "$(cat "$tmp/$name/runner.log")" = "$(printf '%s\n' "$@")" ]; then
    pass "$name: the runner ran $#"
  else
    fail "$name: the runner ran:"
    sed 's/^/     /' "$tmp/$name/runner.log"
    echo "     not:"
    printf '     %s\n' "$@"
  fi
}

# json <job> <jq filter> <value>: the filter gives <value> on the
# report's report.json.
json() {
  got=$(jq -c "$2" "$tmp/$1/report/report.json" 2>&1) || true
  if [ "$got" = "$3" ]; then
    pass "$1: report.json's $2 is $3"
  else
    fail "$1: report.json's $2 is $got, not $3"
  fi
}

# says <job> <text>: the report (report.md) holds <text>.
says() {
  if grep -qF -- "$2" "$tmp/$1/report/report.md" 2>/dev/null; then
    pass "$1: the report says $2"
  else
    fail "$1: the report does not say $2"
    sed 's/^/     /' "$tmp/$1/report/report.md" 2>/dev/null || true
  fi
}

# says_not <job> <text>: the report does not hold <text>.
says_not() {
  if [ ! -f "$tmp/$1/report/report.md" ]; then
    fail "$1: there is no report"
  elif grep -qF -- "$2" "$tmp/$1/report/report.md"; then
    fail "$1: the report says $2"
  else
    pass "$1: the report does not say $2"
  fi
}

# --- A diff within the shards' budget ------------------------------------------

# 120 changed lines in calc, one mutant each: three shards, a shard for
# each 50 mutants and at most three. Among them, five survivors of each
# kind, and a line with no mutant. The test file, the generated file and
# the package that builds only natively change too, and none of their
# lines counts; nor does main's own later change.
history
change "120 lines" <<'SH'
sed -i 's/^let a1 : Int = 1$/let a1 : Int = 10 \/\/ survives/' calc/calc.mbt
sed -i 's/^let a2 : Int = 2$/let a2 : Int = 20 \/\/ deferred/' calc/calc.mbt
sed -i 's/^let a3 : Int = 3$/let a3 : Int = 30 \/\/ stale/' calc/calc.mbt
sed -i 's/^let a4 : Int = 4$/let a4 : Int = 40 \/\/ accepted/' calc/calc.mbt
sed -i 's/^let a5 : Int = 5$/let a5 : Int = 50 \/\/ nosite/' calc/calc.mbt
printf 'test "u" {\n  assert_eq(2, 2)\n}\n' >>calc/calc_test.mbt
printf 'let g2 : Int = 0\n' >>calc/gen.mbt
printf 'let h2 : Int = 0\n' >>host/host.mbt
SH
lines calc/calc.mbt 116 killed
git -C "$repo" commit --quiet -am "116 more lines"
head=$(git -C "$repo" rev-parse HEAD)
job within

status within plan 0
outputs within 'shards=[1,2,3]'
calls within \
  "--root <tmp>/repo --out <tmp>/within/plan/sites --changed --base origin/main --sites-only" \
  "--root <tmp>/repo --out <tmp>/within/shards/changed-lines-shard-1 --changed --base $base --shard 1/3" \
  "--root <tmp>/repo --out <tmp>/within/shards/changed-lines-shard-2 --changed --base $base --shard 2/3" \
  "--root <tmp>/repo --out <tmp>/within/shards/changed-lines-shard-3 --changed --base $base --shard 3/3"
status within shard-1 0
status within shard-3 0
status within report 0
json within '[.head, .base, .merge_base]' "[\"$head\",\"origin/main\",\"$base\"]"
json within '[.event, .covered, .lines, .packages, .mutants, .shards, .ran]' \
  '["push",true,121,["calc"],120,3,120]'
json within '[.survivors[] | [.status, .directory, .definition, .entry]]' \
  '[["unexplained","calc","line_1",null],["unexplained","calc","line_2","calc/calc.mbt,line_2,FAKE,2,3,0"],["stale-covered","calc","line_3","calc/calc.mbt,line_3,FAKE,3,4,0"],["accepted","calc","line_4","calc/calc.mbt,line_4,FAKE,4,5,0"]]'
json within '.counts.calc' \
  '{"mutants":120,"killed":116,"timed out":0,"survived":4,"unviable":0,"unconfirmed":0,"equivalent":0,"duplicate":0,"unexplained":2,"stale-covered":1,"accepted":1}'
says within "Head \`$(echo "$head" | cut -c1-12)\`, against \`origin/main\`, merge base \`$(echo "$base" | cut -c1-12)\`, on a push."
says within "**The whole diff is covered**: 121 changed non-test lines in the pure packages (calc), with 120 mutants of the pinned set on them, all run on 3 shards."
says within "| calc | 120 | 116 | 0 | 4 | 0 | 0 | 0 | 0 | 2 | 1 | 1 |"
says within "## Unexplained survivors (2)"
says within "### \`calc/calc.mbt,line_1,FAKE,1,2,0\`"
says within "In package \`calc\`, \`line_1\`, calc/calc.mbt lines 1 to 1:"
says within "+let a1 : Int = 10 // survives + 1"
says within "Unexplained: DEFERRED to #7."
says within "## Stale-covered survivors (1)"
says within "Stale-covered: its only entry, \`calc/calc.mbt,line_3,FAKE,3,4,0\`, is stale."
says_not within "calc/calc.mbt,line_4,FAKE,4,5,0"
for kept in plan.json report.md report.json shard-1/summary.json shard-2/mutants.jsonl shard-3/report.md; do
  if [ -f "$tmp/within/report/$kept" ]; then
    pass "within: the report's directory keeps $kept"
  else
    fail "within: the report's directory does not keep $kept"
  fi
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

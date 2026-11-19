#!/bin/sh
# Tests of the release workflow's checks of a pushed tag: that CI passed on
# its commit (scripts/check-ci-passed.sh), with a fake gh that answers for
# the Actions API from a canned answer, or fails; and that the tag names the
# version in moon.mod (scripts/check-tag-version.sh), on small moon.mod
# files. Each test checks the exit status and what the check prints.
#
# It needs jq, and no network.
#
# usage: scripts/test-release-gates.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

# The fake gh records its arguments in $tmp/gh.args. It prints
# $tmp/answer.json, or with FAKE_GH=fail fails as gh does when the API
# answers with an error.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_GH_DIR/gh.args"
if [ "${FAKE_GH:-}" = fail ]; then
  echo "gh: Server Error (HTTP 502)" >&2
  exit 1
fi
cat "$FAKE_GH_DIR/answer.json"
SH
chmod +x "$tmp/bin/gh"
export FAKE_GH_DIR="$tmp"

sha=0123456789abcdef0123456789abcdef01234567
another=fedcba9876543210fedcba9876543210fedcba98

# run <id> <head_sha> [<event> [<conclusion>]]: prints the run <id> of
# ci.yml on main as the Actions API lists it, by default one for a push
# that succeeded.
run() {
  jq -n --argjson id "$1" --arg sha "$2" --arg event "${3:-push}" --arg conclusion "${4:-success}" '{
    id: $id, name: "CI", path: ".github/workflows/ci.yml",
    head_branch: "main", head_sha: $sha, event: $event,
    status: "completed", conclusion: $conclusion,
    html_url: "https://github.com/hirunefu/smock/actions/runs/\($id)",
    created_at: "2026-11-16T10:00:00Z", updated_at: "2026-11-16T10:10:00Z", run_attempt: 1
  }'
}

# answer <run>...: writes $tmp/answer.json, an answer that lists the runs.
answer() {
  printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' >"$tmp/answer.json"
}

# ci <name> <commit> [-u <variable>...] [<variable>=<value>...]: runs
# check-ci-passed.sh on <commit> with GITHUB_REPOSITORY set and the fake gh,
# and then with these variables unset or set, as env takes them. Its output
# goes into $tmp/<name>.out, its exit status into $tmp/<name>.status, and
# gh's arguments into $tmp/<name>.args.
ci() {
  name=$1 commit=$2
  shift 2
  rm -f "$tmp/gh.args"
  status=0
  env -u FAKE_GH GITHUB_REPOSITORY=hirunefu/smock PATH="$tmp/bin:$PATH" \
    env "$@" scripts/check-ci-passed.sh "$commit" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
  touch "$tmp/gh.args"
  mv "$tmp/gh.args" "$tmp/$name.args"
}

# tag <name> <argument>...: runs check-tag-version.sh with these arguments.
# Its output goes into $tmp/<name>.out, its exit status into
# $tmp/<name>.status.
tag() {
  name=$1
  shift
  status=0
  scripts/check-tag-version.sh "$@" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
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

# asks <name>: the check <name> asked the API once, for the runs of ci.yml
# for a push of $sha that succeeded.
asks() {
  query="api repos/hirunefu/smock/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&status=success&per_page=100"
  if [ "$(cat "$tmp/$1.args")" = "$query" ]; then
    pass "$1: asks for the runs of $sha"
  else
    fail "$1: does not ask once for the runs of $sha, but: $(cat "$tmp/$1.args")"
  fi
}

# --- CI passed on the commit -------------------------------------------------

# A run that passed, after one that failed, and runs that do not count.
answer "$(run 301 "$sha" push failure)" "$(run 302 "$sha" pull_request)" \
  "$(run 303 "$another")" "$(run 304 "$sha")"
ci passed "$sha"
exits passed 0
asks passed
says passed "check-ci-passed: CI passed on $sha: https://github.com/hirunefu/smock/actions/runs/304"

answer
ci no-run "$sha"
exits no-run 1
says no-run "check-ci-passed: CI has not passed on $sha: no run of ci.yml for a push of it succeeded"
says no-run "check-ci-passed: run the release workflow again once CI has passed on $sha"

answer "$(run 305 "$another")"
ci another-commit "$sha"
exits another-commit 1
says another-commit "check-ci-passed: CI has not passed on $sha: no run of ci.yml for a push of it succeeded"

answer "$(run 306 "$sha" push failure)" "$(run 307 "$sha" pull_request)" \
  "$(run 308 "$sha" push cancelled)"
ci no-run-that-counts "$sha"
exits no-run-that-counts 1
says no-run-that-counts "check-ci-passed: CI has not passed on $sha: no run of ci.yml for a push of it succeeded"

# A failing gh or an answer that cannot be read stops the release too.
answer "$(run 309 "$sha")"
ci gh-fails "$sha" FAKE_GH=fail
exits gh-fails 1
says gh-fails "check-ci-passed: CI has not passed on $sha: gh cannot list the runs of ci.yml for it"
says gh-fails "check-ci-passed: run the release workflow again once CI has passed on $sha"

echo '<html>Unicorn!</html>' >"$tmp/answer.json"
ci not-json "$sha"
exits not-json 1
says not-json "check-ci-passed: CI has not passed on $sha: the Actions API gave an answer that cannot be read"

echo '{"message": "Not Found"}' >"$tmp/answer.json"
ci no-runs-list "$sha"
exits no-runs-list 1
says no-runs-list "check-ci-passed: CI has not passed on $sha: the Actions API gave an answer that cannot be read"

: >"$tmp/answer.json"
ci empty-answer "$sha"
exits empty-answer 1
says empty-answer "check-ci-passed: CI has not passed on $sha: the Actions API gave an answer that cannot be read"

answer "$(run 310 "$sha")"
ci no-repository-name "$sha" -u GITHUB_REPOSITORY
exits no-repository-name 1
mentions no-repository-name "check-ci-passed: CI has not passed on $sha: cannot ask GitHub, since GITHUB_REPOSITORY is not owner/repository: ''"

status=0
scripts/check-ci-passed.sh >"$tmp/no-argument.out" 2>&1 || status=$?
echo "$status" >"$tmp/no-argument.status"
exits no-argument 2
mentions no-argument "usage: "

ci short-sha 0123456
exits short-sha 2
says short-sha "check-ci-passed: '0123456' is not a commit's full SHA in lower case"

# --- The tag names the version in moon.mod ----------------------------------

# mod <file> <version>: writes a moon.mod with that version to <file>, as
# moon.mod is laid out, with a module's version in its imports.
mod() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<MOD
name = "smock/smock"

version = "$2"

license = "Apache-2.0"

import {
  "smock/grpc@9.9.9",
}
MOD
}

mod "$tmp/0.4.0/moon.mod" 0.4.0
mod "$tmp/0.1.0/moon.mod" 0.1.0

tag release 0.4.0 "$tmp/0.4.0/moon.mod"
exits release 0
says release "check-tag-version: the tag names 0.4.0 and $tmp/0.4.0/moon.mod names 0.4.0"

# v0.1.0-rc.1 and v0.4.0-rc.1 were tagged with moon.mod at 0.1.0 and 0.4.0.
tag pre-release 0.4.0-rc.1 "$tmp/0.4.0/moon.mod"
exits pre-release 0
says pre-release "check-tag-version: the tag names 0.4.0-rc.1, a pre-release of 0.4.0, and $tmp/0.4.0/moon.mod names 0.4.0"

tag first-pre-release 0.1.0-rc.1 "$tmp/0.1.0/moon.mod"
exits first-pre-release 0

tag other-version 0.4.1 "$tmp/0.4.0/moon.mod"
exits other-version 1
says other-version "check-tag-version: the tag names 0.4.1 but $tmp/0.4.0/moon.mod names 0.4.0"

tag other-pre-release 0.5.0-rc.1 "$tmp/0.4.0/moon.mod"
exits other-pre-release 1
says other-pre-release "check-tag-version: the tag names 0.5.0-rc.1, a pre-release of 0.5.0, but $tmp/0.4.0/moon.mod names 0.4.0"

# Without a file, the check reads moon.mod at the root of the repository
# that holds the script.
mkdir "$tmp/repository" "$tmp/repository/scripts"
cp scripts/check-tag-version.sh "$tmp/repository/scripts/"
mod "$tmp/repository/moon.mod" 1.2.3
mod "$tmp/repository/scripts/moon.mod" 9.9.9
status=0
(cd "$tmp/repository/scripts" && ./check-tag-version.sh 1.2.3-rc.2) >"$tmp/root.out" 2>&1 || status=$?
echo "$status" >"$tmp/root.status"
exits root 0
says root "check-tag-version: the tag names 1.2.3-rc.2, a pre-release of 1.2.3, and moon.mod names 1.2.3"

# a_version <name> <version>: the check accepts <version>, a SemVer 2.0
# version, when moon.mod names it without its pre-release.
a_version() {
  mod "$tmp/$1/moon.mod" "${2%%-*}"
  tag "$1" "$2" "$tmp/$1/moon.mod"
  exits "$1" 0
  mentions "$1" "check-tag-version: the tag names $2"
}
a_version numeric-pre-release 1.2.3-alpha.0
a_version digits-then-letter 1.2.3-0a
a_version hyphen-in-pre-release 1.2.3-rc-1
a_version only-hyphens 1.2.3--
a_version zero-pre-release 1.2.3-0
a_version many-identifiers 1.0.0-x.7.z.92
a_version two-digit-numbers 10.20.30

# not_a_version <name> <version>: the check refuses <version>, which is not
# <major>.<minor>.<patch>[-<pre-release>] as SemVer 2.0 defines it.
not_a_version() {
  tag "$1" "$2" "$tmp/0.4.0/moon.mod"
  exits "$1" 1
  says "$1" "check-tag-version: '$2' is not a SemVer 2.0 version <major>.<minor>.<patch>[-<pre-release>]"
}
not_a_version with-v v0.4.0
not_a_version two-numbers 0.4
not_a_version four-numbers 0.4.0.1
not_a_version build-metadata 0.4.0+build.1
not_a_version pre-release-and-build-metadata 0.4.0-rc.1+build.1
not_a_version empty-pre-release 0.4.0-
not_a_version underscore 0.4.0-rc_1
not_a_version trailing-space "0.4.0 "
not_a_version empty ""
# helm refuses these pre-releases: an identifier that is empty, or a number
# with a leading zero.
not_a_version only-a-dot 0.4.0-.
not_a_version two-dots 0.4.0-rc..1
not_a_version trailing-dot 0.4.0-rc.
not_a_version leading-dot 0.4.0-.rc
not_a_version leading-zero-pre-release 0.4.0-01
not_a_version leading-zero-identifier 0.4.0-rc.01
not_a_version two-zeros 0.4.0-00
# SemVer gives none of the three numbers a leading zero.
not_a_version leading-zero-major 01.2.3
not_a_version leading-zero-minor 1.02.3
not_a_version leading-zero-patch 1.2.03
not_a_version zeros-major 00.4.0
tag two-lines "$(printf '0.4.0\n0.4.0')" "$tmp/0.4.0/moon.mod"
exits two-lines 1
mentions two-lines "is not a SemVer 2.0 version <major>.<minor>.<patch>[-<pre-release>]"

tag no-file 0.4.0 "$tmp/missing/moon.mod"
exits no-file 1
says no-file "check-tag-version: $tmp/missing/moon.mod does not exist"

# Only a line that is not indented gives the module's version.
cat >"$tmp/no-version.mod" <<'MOD'
name = "smock/smock"

options(
  version = "0.4.0"
)
MOD
tag no-version 0.4.0 "$tmp/no-version.mod"
exits no-version 1
says no-version "check-tag-version: $tmp/no-version.mod has no line version = \"...\""

{
  echo 'version = "0.4.0"'
  echo 'version = "0.4.0"'
} >"$tmp/two-versions.mod"
tag two-versions 0.4.0 "$tmp/two-versions.mod"
exits two-versions 1
says two-versions "check-tag-version: $tmp/two-versions.mod has more than one line version = \"...\""

tag no-arguments
exits no-arguments 2
mentions no-arguments "usage: "

# --- The latest weekly mutation run ---------------------------------------------

# The rules come from the ticket (#316) and ADR 0006 ("What L4 and a
# release read"): the release reads the latest weekly run over the pinned
# set on main, never the monthly run; for each package at L4 that run must
# show no unexplained survivor, stale-covered ones counted as unexplained,
# and it must be on the tag's commit or on an ancestor whose later changes
# a branch's changed-lines report covers whole, with no unexplained
# survivor in a package at L4, or touch no non-test source of a package at
# L4. With no package at L4, the check passes.
#
# A small git repository stands for smock's: the list of packages at L4 as
# committed, the package calc with its source, its test and a generated
# table, the package grid, moon.mod and CHANGELOG.md. A second fake gh
# answers for the Actions API: the runs of the mutation runs' workflow
# from $tmp/mutation-runs.json, the runs of the branch checks on a commit
# from $tmp/branch-checks/<commit>.json, and each run's artifacts from
# $tmp/artifacts/<id>/<name>/.
export GIT_CEILING_DIRECTORIES="$tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkdir "$tmp/runs-bin" "$tmp/branch-checks"
cat >"$tmp/runs-bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_GH_DIR/gh.args"
if [ "${FAKE_GH:-}" = fail ]; then
  echo "gh: Server Error (HTTP 502)" >&2
  exit 1
fi
case "$1 $2" in
"api "*/workflows/mutation-runs.yml/runs*)
  cat "$FAKE_GH_DIR/mutation-runs.json"
  ;;
"api "*/workflows/branch-checks.yml/runs*)
  sha=${2#*head_sha=}
  sha=${sha%%&*}
  if [ -f "$FAKE_GH_DIR/branch-checks/$sha.json" ]; then
    cat "$FAKE_GH_DIR/branch-checks/$sha.json"
  else
    echo '{"total_count": 0, "workflow_runs": []}'
  fi
  ;;
"run download")
  id=$3
  shift 3
  name="" dir=""
  while [ "$#" -gt 0 ]; do
    case $1 in
    -n | --name) name=$2 && shift 2 ;;
    -D | --dir) dir=$2 && shift 2 ;;
    -R | --repo) shift 2 ;;
    *) shift ;;
    esac
  done
  if [ ! -d "$FAKE_GH_DIR/artifacts/$id/$name" ]; then
    echo "no valid artifacts found to download" >&2
    exit 1
  fi
  mkdir -p "$dir"
  cp -R "$FAKE_GH_DIR/artifacts/$id/$name/." "$dir/"
  ;;
*)
  echo "the fake gh does not answer: $*" >&2
  exit 2
  ;;
esac
SH
chmod +x "$tmp/runs-bin/gh"

repo=$tmp/repo
git init --quiet --initial-branch=main "$repo"
mkdir -p "$repo/mutation" "$repo/calc" "$repo/grid"
cp mutation/l4-packages.txt "$repo/mutation/l4-packages.txt"
printf 'pub fn add(a : Int, b : Int) -> Int {\n  a + b\n}\n' >"$repo/calc/calc.mbt"
printf 'test "add" {\n  inspect(add(1, 2), content="3")\n}\n' >"$repo/calc/calc_test.mbt"
printf '// Generated by scripts/gen-table.py. Do not edit.\nlet table : Array[Int] = [1, 2]\n' >"$repo/calc/table.mbt"
printf 'pub fn width() -> Int {\n  80\n}\n' >"$repo/grid/grid.mbt"
printf 'name = "smock/smock"\n\nversion = "0.4.0"\n' >"$repo/moon.mod"
printf '# Changelog\n\n## [Unreleased]\n' >"$repo/CHANGELOG.md"
git -C "$repo" add --all
git -C "$repo" commit --quiet -m "the list of packages at L4 as committed"
listless=$(git -C "$repo" rev-parse HEAD)

# short <commit>: the commit's first 12 digits, as the check names it.
short() {
  echo "$1" | cut -c1-12
}

# weekly <name> <commit> [<argument>...]: runs check-weekly-run.py on
# <commit> of the repository, with GITHUB_REPOSITORY set, the second fake
# gh, and these arguments before the commit. Its output goes into
# $tmp/<name>.out, its exit status into $tmp/<name>.status, and gh's
# arguments into $tmp/<name>.args.
weekly() {
  name=$1 commit=$2
  shift 2
  rm -f "$tmp/gh.args"
  status=0
  GITHUB_REPOSITORY=hirunefu/smock PATH="$tmp/runs-bin:$PATH" \
    python3 scripts/check-weekly-run.py --repo "$repo" "$@" "$commit" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
  touch "$tmp/gh.args"
  mv "$tmp/gh.args" "$tmp/$name.args"
}

# asks_nothing <name>: the check <name> did not run gh.
asks_nothing() {
  if [ -s "$tmp/$1.args" ]; then
    fail "$1: runs gh: $(cat "$tmp/$1.args")"
  else
    pass "$1: runs no gh"
  fi
}

# With the list as committed, which names no package, the check passes
# and reads nothing (#316: "With the list empty, it passes").
weekly no-package-at-l4 "$listless"
exits no-package-at-l4 0
says no-package-at-l4 "check-weekly-run: no package is at L4 on $(short "$listless") (mutation/l4-packages.txt names none), so the release reads no weekly run and waits for none"
asks_nothing no-package-at-l4

# Then calc joins L4, and the weekly run runs on that commit.
printf 'calc\n' >>"$repo/mutation/l4-packages.txt"
git -C "$repo" commit --quiet -am "calc at L4"
at_run=$(git -C "$repo" rev-parse HEAD)
url=https://github.com/hirunefu/smock/actions/runs

# mrun <id> <commit> [<jq update>]: prints the run <id> of the mutation
# runs' workflow on <commit> as the Actions API lists it: by default a
# weekly run on main that its schedule started and that succeeded, with
# the name the workflow gives it, changed by the update.
mrun() {
  jq -n --argjson id "$1" --arg sha "$2" '{
    id: $id, name: "Mutation runs", path: ".github/workflows/mutation-runs.yml",
    display_title: "Mutation runs: weekly", head_branch: "main", head_sha: $sha, event: "schedule",
    status: "completed", conclusion: "success",
    html_url: "https://github.com/hirunefu/smock/actions/runs/\($id)",
    created_at: "2026-11-20T20:30:00Z", updated_at: "2026-11-20T22:30:00Z", run_attempt: 1
  }' | jq "${3:-.}"
}

# mruns <run>...: writes the answer that lists the runs of the mutation
# runs' workflow.
mruns() {
  printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' >"$tmp/mutation-runs.json"
}

# weekly_report <id> [<jq update>]: writes the artifact mutation-report of
# the run <id>, its summary.json as scripts/mutation/merge.py writes it,
# changed by the update: by default the pinned set over calc and grid,
# calc with no survivor, grid with two unexplained ones.
weekly_report() {
  rm -rf "$tmp/artifacts/$1/mutation-report"
  mkdir -p "$tmp/artifacts/$1/mutation-report"
  jq -n '{
    operator_set: "v1", set: "pinned",
    selection: {set: "pinned", packages: ["calc", "grid"], mutants: [], operators: [], list: null, sample: null,
                shard: null},
    packages: [
      {package: "smock/smock/calc", directory: "calc", operator_set: "v1", set: "pinned", mutants: 40, killed: 38,
       timed_out: 2, survived: 0, unviable: 1, unconfirmed: 0},
      {package: "smock/smock/grid", directory: "grid", operator_set: "v1", set: "pinned", mutants: 10, killed: 8,
       timed_out: 0, survived: 2, unviable: 0, unconfirmed: 0,
       exclusions: {unexplained: 2, stale_covered: 0, accepted: 0, accepted_by_category: {}}}
    ]
  }' | jq "${2:-.}" >"$tmp/artifacts/$1/mutation-report/summary.json"
  printf '# Mutation run: the weekly run\n' >"$tmp/artifacts/$1/mutation-report/report.md"
}

# A clean weekly run on the tag's commit: survivors in grid, which is not
# at L4, stop no release.
mruns "$(mrun 201 "$at_run")"
weekly_report 201
weekly on-the-run "$at_run"
exits on-the-run 0
says on-the-run "check-weekly-run: $(short "$at_run") may be released: the latest weekly run over the pinned set, on the tag's commit, shows no unexplained survivor in the packages at L4 (calc): $url/201"
if grep -qxF "api repos/hirunefu/smock/actions/workflows/mutation-runs.yml/runs?branch=main&per_page=100" \
  "$tmp/on-the-run.args"; then
  pass "on-the-run: asks for the runs of the mutation runs' workflow on main"
else
  fail "on-the-run: asks gh: $(cat "$tmp/on-the-run.args")"
fi

# downloads <name> <id>: the check <name> downloaded an artifact of the run
# <id>; downloads_not: it did not.
downloads() {
  if grep -q "^run download $2 " "$tmp/$1.args"; then
    pass "$1: reads the run $2"
  else
    fail "$1: does not read the run $2: $(cat "$tmp/$1.args")"
  fi
}
downloads_not() {
  if grep -q "^run download $2 " "$tmp/$1.args"; then
    fail "$1: reads the run $2"
  else
    pass "$1: does not read the run $2"
  fi
}

# --- Which run: the latest weekly run on main that has ended ---------------------

start_weekly="check-weekly-run: start a weekly run on main once it holds the tag's commit, and run the release workflow again once it has passed: gh workflow run mutation-runs.yml -R hirunefu/smock --ref main -f mode=weekly"

# No weekly run: the runs of other modes, a run from before the workflow
# named its runs, and the monthly run do not count.
mruns "$(mrun 211 "$at_run" '.display_title = "Mutation runs: sample" | .event = "workflow_dispatch"')" \
  "$(mrun 212 "$at_run" '.display_title = "Mutation runs"')" \
  "$(mrun 213 "$at_run" '.display_title = "Mutation runs: monthly"')"
weekly_report 211
weekly_report 212
weekly_report 213
weekly no-weekly-run "$at_run"
exits no-weekly-run 1
says no-weekly-run "check-weekly-run: $(short "$at_run") may not be released: no weekly run over the pinned set on main has ended"
says no-weekly-run "$start_weekly"
downloads_not no-weekly-run 211
downloads_not no-weekly-run 212
downloads_not no-weekly-run 213

mruns
weekly no-run-at-all "$at_run"
exits no-run-at-all 1
says no-run-at-all "check-weekly-run: $(short "$at_run") may not be released: no weekly run over the pinned set on main has ended"

# A weekly run on another branch does not count.
mruns "$(mrun 214 "$at_run" '.head_branch = "integration/x" | .event = "workflow_dispatch"')"
weekly_report 214
weekly other-branch "$at_run"
exits other-branch 1
says other-branch "check-weekly-run: $(short "$at_run") may not be released: no weekly run over the pinned set on main has ended"

# One still running is not a result yet: with none ended, the release waits
# for it; after one that ended, that one decides.
mruns "$(mrun 215 "$at_run" '.status = "in_progress" | .conclusion = null')"
weekly only-running "$at_run"
exits only-running 1
says only-running "check-weekly-run: $(short "$at_run") may not be released: no weekly run over the pinned set on main has ended, and $url/215 is still running"
says only-running "check-weekly-run: run the release workflow again once it has passed"

mruns "$(mrun 216 "$at_run" '.status = "queued" | .conclusion = null | .created_at = "2026-11-27T20:30:00Z"')" \
  "$(mrun 201 "$at_run")"
weekly running-after-one-that-passed "$at_run"
exits running-after-one-that-passed 0
mentions running-after-one-that-passed "may be released: the latest weekly run over the pinned set, on the tag's commit, shows no unexplained survivor in the packages at L4 (calc): $url/201"
says running-after-one-that-passed "check-weekly-run: a later weekly run, $url/216, is still running, and does not decide"

# The latest that ended decides, in whatever order the API lists them: when
# it failed, an earlier one that passed does not let the release go ahead.
mruns "$(mrun 201 "$at_run")" \
  "$(mrun 217 "$at_run" '.conclusion = "failure" | .created_at = "2026-11-27T20:30:00Z"')"
weekly_report 217
weekly failed "$at_run"
exits failed 1
says failed "check-weekly-run: $(short "$at_run") may not be released: the latest weekly run over the pinned set on main failed (failure): $url/217"
says failed "$start_weekly"
downloads_not failed 201

mruns "$(mrun 218 "$at_run" '.conclusion = "cancelled" | .event = "workflow_dispatch"')"
weekly cancelled "$at_run"
exits cancelled 1
says cancelled "check-weekly-run: $(short "$at_run") may not be released: the latest weekly run over the pinned set on main failed (cancelled): $url/218"

# The monthly run over the full set is reported, never gated: a later one
# that failed, with survivors in calc, is not read.
mruns "$(mrun 219 "$at_run" '.display_title = "Mutation runs: monthly" | .conclusion = "failure" | .created_at = "2026-12-01T22:50:00Z"')" \
  "$(mrun 201 "$at_run")"
weekly_report 219 '.set = "full" | .packages[0].survived = 5 | .packages[0].exclusions = {unexplained: 5, stale_covered: 0, accepted: 0, accepted_by_category: {}}'
weekly monthly-not-read "$at_run"
exits monthly-not-read 0
mentions monthly-not-read "$url/201"
downloads_not monthly-not-read 219
downloads monthly-not-read 201

# --- What the run's report shows ----------------------------------------------------

# report_case <name> <jq update>: the latest weekly run, 221, is on the
# tag's commit, and its report is changed by the update; the check runs.
report_case() {
  mruns "$(mrun 221 "$at_run")"
  weekly_report 221 "$2"
  weekly "$1" "$at_run"
}
exclusions() {
  echo "{unexplained: $1, stale_covered: $2, accepted: $3, accepted_by_category: {}}"
}
read_survivors="check-weekly-run: its report lists them: gh run download 221 -R hirunefu/smock --name mutation-report --dir mutation-report"

# An unexplained survivor in calc, those that a DEFERRED entry covers
# among them, stops the release.
report_case unexplained ".packages[0].survived = 3 | .packages[0].exclusions = $(exclusions 2 0 1)"
exits unexplained 1
says unexplained "check-weekly-run: $(short "$at_run") may not be released: the latest weekly run over the pinned set on main shows unexplained survivors in a package at L4: calc 2: $url/221"
says unexplained "$read_survivors"

# A stale-covered survivor counts as unexplained (#316, "Which run").
report_case stale-covered ".packages[0].survived = 1 | .packages[0].exclusions = $(exclusions 0 1 0)"
exits stale-covered 1
says stale-covered "check-weekly-run: $(short "$at_run") may not be released: the latest weekly run over the pinned set on main shows unexplained survivors in a package at L4: calc 1 (1 stale-covered): $url/221"

report_case both ".packages[0].survived = 4 | .packages[0].exclusions = $(exclusions 2 1 1)"
exits both 1
mentions both "shows unexplained survivors in a package at L4: calc 3 (1 stale-covered): $url/221"

# Survivors that no exclusion list judged are unexplained, as the report
# counts them.
report_case no-exclusion-list ".packages[0].survived = 1"
exits no-exclusion-list 1
mentions no-exclusion-list "shows unexplained survivors in a package at L4: calc 1: $url/221"

# Accepted survivors do not stop it.
report_case accepted ".packages[0].survived = 2 | .packages[0].exclusions = $(exclusions 0 0 2)"
exits accepted 0
mentions accepted "may be released"

# A package at L4 that the run ran no mutant of shows no survivor; one it
# did not run at all shows nothing, and stops the release.
report_case no-mutant 'del(.packages[0])'
exits no-mutant 0
mentions no-mutant "may be released"

report_case not-run '.selection.packages = ["grid"] | del(.packages[0])'
exits not-run 1
says not-run "check-weekly-run: $(short "$at_run") may not be released: the latest weekly run over the pinned set on main did not run calc, a package at L4: $url/221"
says not-run "$start_weekly"

# The report must be of the pinned set, and readable.
report_case full-set '.set = "full" | .selection.set = "full"'
exits full-set 1
says full-set "check-weekly-run: $(short "$at_run") may not be released: the report of the latest weekly run over the pinned set on main is of the full set, not the pinned set: $url/221"

mruns "$(mrun 222 "$at_run")"
weekly no-report "$at_run"
exits no-report 1
says no-report "check-weekly-run: $(short "$at_run") may not be released: the report of the latest weekly run over the pinned set on main (the artifact mutation-report, summary.json) cannot be read: $url/222"

weekly_report 222
echo 'not json' >"$tmp/artifacts/222/mutation-report/summary.json"
weekly report-not-json "$at_run"
exits report-not-json 1
mentions report-not-json "(the artifact mutation-report, summary.json) cannot be read: $url/222"

weekly_report 222 '.packages = {}'
weekly report-of-another-shape "$at_run"
exits report-of-another-shape 1
mentions report-of-another-shape "(the artifact mutation-report, summary.json) cannot be read: $url/222"

# --- Which commit: the changes to main after the run --------------------------------

# From here on, the latest weekly run, 231, is a clean one on the commit
# where calc joined L4. Each case's history starts there, on a branch of
# its own that stands for main, and its head is the tag's commit.
mruns "$(mrun 231 "$at_run")"
weekly_report 231

# on <branch>: starts the history <branch> at the run's commit.
on() {
  git -C "$repo" checkout --quiet -b "$1" "$at_run"
}

# straight <subject> <file> <line>: a commit pushed straight to main that
# adds <line> at the end of <file>.
straight() {
  mkdir -p "$repo/$(dirname "$2")"
  printf '%s\n' "$3" >>"$repo/$2"
  git -C "$repo" add --all
  git -C "$repo" commit --quiet -m "$1"
}

# release_commit: the release commit, which gives the version in moon.mod
# and its section in CHANGELOG.md, pushed straight to main.
release_commit() {
  printf 'name = "smock/smock"\n\nversion = "0.5.0"\n' >"$repo/moon.mod"
  printf '# Changelog\n\n## [Unreleased]\n\n## [0.5.0] - 2026-11-21\n' >"$repo/CHANGELOG.md"
  git -C "$repo" commit --quiet -am "Make the version 0.5.0, and give it its CHANGELOG section"
}

# head: the current commit.
head() {
  git -C "$repo" rev-parse HEAD
}

asks_no_branch_checks() {
  if grep -q "branch-checks.yml" "$tmp/$1.args"; then
    fail "$1: asks for the branch checks: $(cat "$tmp/$1.args")"
  else
    pass "$1: does not ask for the branch checks"
  fi
}

# A release commit pushed straight to main after the run meets the second
# condition: it touches no non-test source of a package at L4.
on release
release_commit
release=$(head)
weekly release-commit "$release"
exits release-commit 0
says release-commit "check-weekly-run: $(short "$release") may be released: the latest weekly run over the pinned set, on $(short "$at_run"), an ancestor of the tag's commit, shows no unexplained survivor in the packages at L4 (calc): $url/231"
says release-commit "check-weekly-run: the one change to main after it is covered:"
says release-commit "check-weekly-run:   $(short "$release") Make the version 0.5.0, and give it its CHANGELOG section: it touches no non-test source of a package at L4"
asks_no_branch_checks release-commit

# Nor do tests, generated files, another package, or a package in a
# directory below calc, which is a package of its own.
on quiet
straight "Test add" calc/calc_test.mbt 'test "add again" { inspect(add(2, 2), content="4") }'
straight "Test add from inside" calc/calc_wbtest.mbt 'test "inside" { inspect(add(0, 0), content="0") }'
straight "Grow the table" calc/table.mbt 'let more : Array[Int] = [3]'
straight "Widen the grid" grid/grid.mbt 'pub fn height() -> Int { 24 }'
straight "Add a package below calc" calc/deep/deep.mbt 'pub fn deep() -> Int { 1 }'
straight "Configure calc" calc/moon.pkg 'options("is-main": false)'
weekly quiet-changes "$(head)"
exits quiet-changes 0
says quiet-changes "check-weekly-run: each of the 6 changes to main after it is covered:"
for subject in "Test add" "Test add from inside" "Grow the table" "Widen the grid" "Add a package below calc" \
  "Configure calc"; do
  mentions quiet-changes " $subject: it touches no non-test source of a package at L4"
done
asks_no_branch_checks quiet-changes

# A source change pushed straight to main has no branch's report, so it
# stops the release (#316); so does a deleted source file.
on straight
straight "Fix add" calc/calc.mbt '// add adds'
fixed=$(head)
release_commit
weekly straight-source "$(head)"
exits straight-source 1
says straight-source "check-weekly-run: $(short "$(head)") may not be released: $(short "$fixed") (Fix add), a change to main after the latest weekly run over the pinned set ($url/231), changes non-test source of calc, a package at L4, and no run of the branch checks is on $(short "$fixed"), as none is on a change pushed straight to main"
says straight-source "$start_weekly"

on deleted
git -C "$repo" rm --quiet calc/calc.mbt
git -C "$repo" commit --quiet -m "Drop add"
weekly deleted-source "$(head)"
exits deleted-source 1
mentions deleted-source "(Drop add), a change to main after the latest weekly run over the pinned set ($url/231), changes non-test source of calc, a package at L4"

# A generated file that a person rewrote is source.
on ungenerated
printf 'let table : Array[Int] = [1, 2, 3]\n' >"$repo/calc/table.mbt"
git -C "$repo" commit --quiet -am "Write the table by hand"
weekly ungenerated "$(head)"
exits ungenerated 1
mentions ungenerated "(Write the table by hand), a change to main after the latest weekly run over the pinned set ($url/231), changes non-test source of calc, a package at L4"

# The run must be on the tag's commit or on its first-parent history,
# main's: not on a commit the tag's commit does not hold, nor on one it
# holds only through a merge.
git -C "$repo" checkout --quiet -b elsewhere "$listless"
printf 'calc\n' >>"$repo/mutation/l4-packages.txt"
git -C "$repo" commit --quiet -am "calc at L4, elsewhere"
weekly not-held "$(head)"
exits not-held 1
says not-held "check-weekly-run: $(short "$(head)") may not be released: the latest weekly run over the pinned set on main ran on $(short "$at_run"), which the tag's commit does not hold: $url/231"
says not-held "$start_weekly"

git -C "$repo" merge --quiet --no-ff -m "Merge main" "$at_run"
weekly through-a-merge "$(head)"
exits through-a-merge 1
says through-a-merge "check-weekly-run: $(short "$(head)") may not be released: the latest weekly run over the pinned set on main ran on $(short "$at_run"), which is not on the first-parent history of the tag's commit, as main's commits are: $url/231"

# A run on a later commit than the tag's does not cover it.
mruns "$(mrun 232 "$fixed")"
weekly_report 232
weekly later-run "$at_run"
exits later-run 1
says later-run "check-weekly-run: $(short "$at_run") may not be released: the latest weekly run over the pinned set on main ran on $(short "$fixed"), which the tag's commit does not hold: $url/232"
mruns "$(mrun 231 "$at_run")"

echo
echo "test-release-gates: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

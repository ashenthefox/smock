#!/bin/sh
# Tests of the decision whether the weekly run with the latest MoonBit may
# be skipped (scripts/latest-toolchain-plan.sh). Each test writes the
# output of `moon version --all` for the pinned and the latest toolchain,
# installed in different directories, has a fake gh answer for the Actions
# API from a canned answer, or fail, runs the plan, and checks that it
# exits 0, prints exactly one line, run=true or run=false, and says why.
# The time now is fixed through PLAN_NOW.
#
# It needs jq, and no network and no MoonBit.
#
# usage: scripts/test-latest-toolchain-plan.sh
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

# The time now: 2026-11-16T03:17:00Z, a Monday's scheduled run.
now=$(jq -n '"2026-11-16T03:17:00Z" | fromdateiso8601')
sha=0123456789abcdef0123456789abcdef01234567

# run <id> <head_sha> <updated_at> [<event> [<conclusion>]]: prints the run
# <id> of ci.yml on main as the Actions API lists it, by default one for a
# push that succeeded.
run() {
  jq -n --argjson id "$1" --arg sha "$2" --arg updated "$3" \
    --arg event "${4:-push}" --arg conclusion "${5:-success}" '{
      id: $id, name: "CI", path: ".github/workflows/ci.yml",
      head_branch: "main", head_sha: $sha, event: $event,
      status: "completed", conclusion: $conclusion,
      html_url: "https://github.com/hirunefu/smock/actions/runs/\($id)",
      created_at: $updated, updated_at: $updated, run_attempt: 1
    }'
}

# answer <run>...: writes $tmp/answer.json, an answer that lists the runs.
answer() {
  printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' >"$tmp/answer.json"
}

# toolchain <file> <directory> <moon> <moonc>: writes to <file> what
# `moon version --all` prints for a toolchain in <directory> with these
# versions of moon (and moonrun) and moonc, as moon 0.1.20261104 prints it.
toolchain() {
  cat >"$1" <<TEXT
moon $3 $2/bin/moon
moonc $4 $2/bin/moonc
moonrun $3 $2/bin/moonrun

Feature flags enabled: rr_moon_mod,rr_moon_pkg
TEXT
}

moon="0.1.20261104 (940aa18 2026-11-04)"
# shellcheck disable=SC2088 # moon writes the home directory as ~ in a path
home="~"
moonc="v0.10.20+65efd5b93 (2026-11-05)"
pinned=$tmp/pinned.txt
latest=$tmp/latest.txt

# plan <name> [-u <variable>...] [<variable>=<value>...]: runs the plan on
# $pinned and $latest as the scheduled run, with GITHUB_SHA at $sha,
# GITHUB_REPOSITORY set, PLAN_NOW at now and the fake gh, and then with
# these variables unset or set, as env takes them. Its standard output
# goes into $tmp/<name>.out, its standard error into $tmp/<name>.err, its
# exit status into $tmp/<name>.status, and gh's arguments into
# $tmp/<name>.args.
plan() {
  name=$1
  shift
  rm -f "$tmp/gh.args"
  status=0
  env -u FAKE_GH GITHUB_EVENT_NAME=schedule GITHUB_SHA="$sha" GITHUB_REPOSITORY=hirunefu/smock \
    PLAN_NOW="$now" PATH="$tmp/bin:$PATH" env "$@" scripts/latest-toolchain-plan.sh "$pinned" "$latest" \
    >"$tmp/$name.out" 2>"$tmp/$name.err" || status=$?
  echo "$status" >"$tmp/$name.status"
  touch "$tmp/gh.args"
  mv "$tmp/gh.args" "$tmp/$name.args"
}

# show <name>: prints what the plan <name> printed, indented.
show() {
  sed 's/^/     out: /' "$tmp/$1.out"
  sed 's/^/     err: /' "$tmp/$1.err"
}

# decides <name> <true | false>: the plan <name> exited 0 and printed
# exactly the line run=<true | false> on standard output.
decides() {
  if [ "$(cat "$tmp/$1.status")" = 0 ] && [ "$(cat "$tmp/$1.out")" = "run=$2" ] &&
    [ "$(wc -l <"$tmp/$1.out")" -eq 1 ]; then
    pass "$1: exits 0 and prints only run=$2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), and does not print only run=$2"
    show "$1"
  fi
}

# explains <name> <text>: the plan <name> said <text> in some line of its
# standard error.
explains() {
  if grep -qF -- "$2" "$tmp/$1.err"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    show "$1"
  fi
}

# asks <name>: the plan <name> asked the API once, for the runs of ci.yml
# for a push of $sha that succeeded.
asks() {
  query="api repos/hirunefu/smock/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&status=success&per_page=100"
  if [ "$(cat "$tmp/$1.args")" = "$query" ]; then
    pass "$1: asks for the runs of $sha"
  else
    fail "$1: does not ask once for the runs of $sha, but: $(cat "$tmp/$1.args")"
  fi
}

# asks_nothing <name>: the plan <name> did not ask the API.
asks_nothing() {
  if [ ! -s "$tmp/$1.args" ]; then
    pass "$1: asks GitHub nothing"
  else
    fail "$1: asks GitHub: $(cat "$tmp/$1.args")"
  fi
}

# --- The run may be skipped --------------------------------------------------

# The same versions, each in a directory of its own under RUNNER_TEMP, which
# is under the home directory on the runners, and CI passed on main's
# commit two days ago: the only case that skips the run. The answer also
# lists runs that do not count.
toolchain "$pinned" "$home/work/_temp/moon-pinned" "$moon" "$moonc"
toolchain "$latest" "$home/work/_temp/moon-latest" "$moon" "$moonc"
answer "$(run 201 "$sha" 2026-11-14T10:00:00Z)" \
  "$(run 202 "$sha" 2026-11-15T10:00:00Z pull_request)" \
  "$(run 203 fedcba9876543210fedcba9876543210fedcba98 2026-11-16T01:00:00Z)"
plan same
decides same false
asks same
explains same "the latest toolchain is the pinned one:"
explains same "    moonc v0.10.20+65efd5b93 (2026-11-05)"
explains same "CI on $sha passed in https://github.com/hirunefu/smock/actions/runs/201 on main, updated 2026-11-14T10:00:00Z"

# Exactly 7 days is not too old.
answer "$(run 204 "$sha" 2026-11-09T03:17:00Z)"
plan a-week-old
decides a-week-old false

# The clocks of the runner and of GitHub may differ: a run dated exactly 5
# minutes after the time now still counts.
answer "$(run 212 "$sha" 2026-11-16T03:22:00Z)"
plan five-minutes-ahead
decides five-minutes-ahead false

# A run dated later does not hide one that counts.
answer "$(run 213 "$sha" 2026-11-16T03:22:01Z)" "$(run 214 "$sha" 2026-11-14T10:00:00Z)"
plan future-and-recent
decides future-and-recent false
explains future-and-recent "CI on $sha passed in https://github.com/hirunefu/smock/actions/runs/214 on main"

# A path from the root, also with a space, is left out too.
toolchain "$pinned" "$home/.moon" "$moon" "$moonc"
toolchain "$latest" "/opt/moon latest" "$moon" "$moonc"
answer "$(run 205 "$sha" 2026-11-14T10:00:00Z)"
plan path-with-space
decides path-with-space false

# --- The toolchains ----------------------------------------------------------

toolchain "$latest" /home/runner/work/_temp/moon-latest "$moon" "v0.10.21+0123abcde (2026-11-12)"
plan other-moonc
decides other-moonc true
explains other-moonc "the latest toolchain is not the pinned one:"
explains other-moonc "    latest: moonc v0.10.21+0123abcde (2026-11-12)"
asks_nothing other-moonc

toolchain "$latest" /home/runner/work/_temp/moon-latest "0.1.20261111 (1a2b3c4 2026-11-11)" "$moonc"
plan other-moon
decides other-moon true
explains other-moon "    latest: moon 0.1.20261111 (1a2b3c4 2026-11-11)"
asks_nothing other-moon

toolchain "$latest" /home/runner/work/_temp/moon-latest "$moon" "$moonc"
rm "$pinned"
plan missing-file
decides missing-file true
explains missing-file "$pinned is missing or empty"
asks_nothing missing-file

: >"$pinned"
plan empty-file
decides empty-file true
explains empty-file "$pinned is missing or empty"

# Two outputs that are the same, but name no version, are no toolchains.
echo "moon: command not found" >"$pinned"
echo "moon: command not found" >"$latest"
plan no-version
decides no-version true
explains no-version "the output of moon version --all names no version of moon:"
asks_nothing no-version

toolchain "$pinned" "$home/.moon" "$moon" "$moonc"
toolchain "$latest" /home/runner/work/_temp/moon-latest "$moon" "$moonc"
status=0
env GITHUB_EVENT_NAME=schedule scripts/latest-toolchain-plan.sh "$pinned" >"$tmp/one-file.out" 2>"$tmp/one-file.err" ||
  status=$?
echo "$status" >"$tmp/one-file.status"
decides one-file true
explains one-file "usage: scripts/latest-toolchain-plan.sh"

# --- The event ---------------------------------------------------------------

answer "$(run 206 "$sha" 2026-11-14T10:00:00Z)"
plan by-hand GITHUB_EVENT_NAME=workflow_dispatch
decides by-hand true
explains by-hand "the workflow was started by 'workflow_dispatch', not by its schedule"
asks_nothing by-hand

plan no-event -u GITHUB_EVENT_NAME
decides no-event true

# --- The runs ----------------------------------------------------------------

answer "$(run 207 "$sha" 2026-11-08T03:17:00Z)"
plan too-old
decides too-old true
explains too-old "for $sha, the push runs of ci.yml that succeeded are older than 7 days"

# A run dated more than 5 minutes after the time now leaves doubt.
answer "$(run 215 "$sha" 2026-11-16T03:22:01Z)"
plan future
decides future true
explains future "for $sha, the push run of ci.yml https://github.com/hirunefu/smock/actions/runs/215 that succeeded is dated 2026-11-16T03:22:01Z, more than 5 minutes after the time now, 2026-11-16T03:17:00Z"

answer
plan no-run
decides no-run true
explains no-run "for $sha, no push run of ci.yml succeeded"

answer "$(run 208 "$sha" 2026-11-14T10:00:00Z push failure)" \
  "$(run 209 fedcba9876543210fedcba9876543210fedcba98 2026-11-14T10:00:00Z)"
plan no-run-that-counts
decides no-run-that-counts true
explains no-run-that-counts "for $sha, no push run of ci.yml succeeded"

# --- Errors ------------------------------------------------------------------

answer "$(run 210 "$sha" 2026-11-14T10:00:00Z)"
plan gh-fails FAKE_GH=fail
decides gh-fails true
explains gh-fails "gh cannot list the runs of ci.yml for $sha"

echo '<html>Unicorn!</html>' >"$tmp/answer.json"
plan not-json
decides not-json true
explains not-json "the Actions API gave an answer that cannot be read"

echo '{"message": "Not Found"}' >"$tmp/answer.json"
plan no-runs-list
decides no-runs-list true
explains no-runs-list "the Actions API gave an answer that cannot be read"

answer "$(run 211 "$sha" 2026-11-14T10:00:00Z)"
plan no-sha -u GITHUB_SHA
decides no-sha true
explains no-sha "GITHUB_SHA is not a commit's full SHA: ''"
asks_nothing no-sha

plan no-repository-name GITHUB_REPOSITORY=
decides no-repository-name true
explains no-repository-name "GITHUB_REPOSITORY is not owner/repository: ''"
asks_nothing no-repository-name

plan bad-now PLAN_NOW=yesterday
decides bad-now true
explains bad-now "the time now is not a number of seconds: 'yesterday'"

echo
echo "test-latest-toolchain-plan: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

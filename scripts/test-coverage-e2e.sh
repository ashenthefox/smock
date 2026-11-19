#!/bin/sh
# Tests of the e2e coverage report (scripts/coverage-e2e.py), which
# scripts/coverage-e2e.sh runs on the in-process tests' and the e2e
# tests' bisect reports. Each test runs the report on the small reports
# committed in scripts/coverage-tests/e2e/, over the small source tree
# beside them and the compiler's parse trees of its server and cmd/smock
# files, and checks its exit status, what it prints and what it writes.
#
# The fixture's points are where the pinned compiler put them, in the
# format moon_cove writes (BISECT-COVERAGE-4); their counts are set by
# hand, as scripts/coverage-tests/e2e/README.md lists them. The expected
# values are counted by hand from those files, by the rules of #342: a
# point is reached when its count is above 0 in either report, and a
# position counts as covered by e2e when the point that starts the
# innermost function, then, else or match-arm body around it has a count
# above zero in the e2e tests' report.
#
# usage: scripts/test-coverage-e2e.sh
set -eu
cd "$(dirname "$0")/.."

fixtures=scripts/coverage-tests/e2e
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

# report <name> <in-process report> <e2e report> [option]...: runs the
# report over $fixtures/tree, its output into $tmp/<name>.out, its files
# into $tmp/<name>/ and its exit status into $tmp/<name>.status.
report() {
  name=$1
  in_process=$2
  e2e=$3
  shift 3
  status=0
  python3 scripts/coverage-e2e.py report --root "$fixtures/tree" --trees "$fixtures/trees" \
    --in-process "$in_process" --e2e "$e2e" --out "$tmp/$name" "$@" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# exits <name> <status>: the report <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <line>: the report <name> printed <line>, where any run of
# spaces matches any other.
says() {
  want=$(printf '%s\n' "$2" | tr -s ' ')
  if tr -s ' ' <"$tmp/$1.out" | grep -qxF -- "$want"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# --- Points reached in-process, by e2e and by either, per package --------------

report fixture "$fixtures/in-process.bisect" "$fixtures/e2e.bisect"
exits fixture 0
says fixture "| package | points | in-process | e2e | either | unreached |"
# cmd/smock: no in-process test; e2e reaches all but the unused closure's
# body, 7:41.
says fixture "| cmd/smock | 9 | 0 (0.0%) | 8 (88.9%) | 8 (88.9%) | 1 |"
# prng: only e2e reaches it, the then of next not.
says fixture "| prng | 3 | 0 (0.0%) | 2 (66.7%) | 2 (66.7%) | 1 |"
# server: in-process reaches 7 of 14, e2e 8; the then at 20:5 only
# in-process, the else at 22:5 and stop's body at 33:3 only e2e.
says fixture "| server | 14 | 7 (50.0%) | 8 (57.1%) | 9 (64.3%) | 5 |"
says fixture "| watch | 3 | 2 (66.7%) | 2 (66.7%) | 2 (66.7%) | 1 |"
says fixture "| all | 29 | 9 (31.0%) | 20 (69.0%) | 21 (72.4%) | 8 |"

# --- The positions e2e covers ---------------------------------------------------

# positions <name> <list>: the positions of the list <list>.jsonl that the
# report <name> wrote, as "<file>:<line>:<column> <operator>", one a line,
# into $tmp/<name>.<list>; the runner's own reader of lists
# (scripts/mutation/choice.py) must read the list.
positions() {
  python3 - "$tmp/$1/$2.jsonl" >"$tmp/$1.$2" 2>"$tmp/$1.$2.err" <<'PY' ||
import json, sys
sys.path.insert(0, "scripts/mutation")
import choice
path = sys.argv[1]
choice.read_list(path)
for line in open(path, encoding="utf-8"):
    entry = json.loads(line)
    print(f"{entry['file']}:{entry['line']}:{entry['column']} {entry['operator']}")
PY
    fail "$1: the runner's reader of lists does not read $2.jsonl: $(cat "$tmp/$1.$2.err")"
}

# in_list <name> <list> <position>: the list holds the position, once for
# each of its mutants.
in_list() {
  if grep -qxF -- "$3" "$tmp/$1.$2"; then
    pass "$1: $2 holds $3"
  else
    fail "$1: $2 does not hold $3"
    sed 's/^/     /' "$tmp/$1.$2"
  fi
}

positions fixture covered-by-e2e
positions fixture not-covered-by-e2e

# The rule, as #342 states it.
says fixture "A position counts as covered by e2e when the point that starts the innermost function, then, else or match-arm body around it has a count above zero in the e2e tests' report."
says fixture "| package | positions | covered by e2e | not covered | mutants of the pinned set at covered positions |"
# server: 31 positions, 32 mutants (INT in a comparison makes two at
# 36:21); 9 positions not covered, listed below.
says fixture "| server | 31 | 22 | 9 | 23 |"
says fixture "| cmd/smock | 4 | 2 | 2 | 2 |"
if [ "$(wc -l <"$tmp/fixture.covered-by-e2e")" = 25 ] && [ "$(wc -l <"$tmp/fixture.not-covered-by-e2e")" = 11 ]; then
  pass "fixture: lists 25 mutants at covered positions and 11 at the others"
else
  fail "fixture: lists $(wc -l <"$tmp/fixture.covered-by-e2e") and $(wc -l <"$tmp/fixture.not-covered-by-e2e") mutants"
fi

# A function's body: serve's (e2e 2) and unused's (0), whose BODY site
# starts at its brace.
in_list fixture covered-by-e2e "server/serve.mbt:17:59 BODY"
in_list fixture covered-by-e2e "server/serve.mbt:19:6 IFC"
in_list fixture not-covered-by-e2e "server/serve.mbt:44:45 BODY"
in_list fixture not-covered-by-e2e "server/serve.mbt:45:13 AOR"
# A then that only the in-process tests ran, and an else that e2e ran.
in_list fixture not-covered-by-e2e "server/serve.mbt:20:27 AOR"
in_list fixture covered-by-e2e "server/serve.mbt:22:27 AOR"
# A match arm that ran, and one that did not.
in_list fixture covered-by-e2e "server/serve.mbt:26:20 AOR"
in_list fixture not-covered-by-e2e "server/serve.mbt:25:10 INT"
# A guard's else is an else.
in_list fixture not-covered-by-e2e "server/serve.mbt:18:34 INT"
# After an if whose then-body did not run (34:5), the position is in
# stop's body, which ran.
in_list fixture not-covered-by-e2e "server/serve.mbt:34:17 INT"
in_list fixture covered-by-e2e "server/serve.mbt:39:25 AOR"
# A loop's body is none of the four: its position counts as stop's body,
# though the loop's own point (37:5) is 0.
in_list fixture covered-by-e2e "server/serve.mbt:37:27 AOR"
# A parameter's default value is in its function.
in_list fixture covered-by-e2e "server/serve.mbt:32:52 BOOL"
# A top-level value, outside every function, counts with its package.
in_list fixture covered-by-e2e "server/serve.mbt:50:23 INT"
# A closure is a function: main's body ran, the unused closure's did not.
in_list fixture covered-by-e2e "cmd/smock/main.mbt:8:3 DEL"
in_list fixture not-covered-by-e2e "cmd/smock/main.mbt:7:46 AOR"

# A body that the compiler starts with no point counts as none: without
# the point of the arm 0 (25:10), its position counts as serve's body.
sed 's/ 632 645 / 645 /; s/ 14 1 1 0 1 1 0 1 1 0 1 0 0 0 0 / 13 1 1 0 1 1 0 1 1 1 0 0 0 0 /; s/^BISECT-COVERAGE-4 4 16 server\/serve.mbt 14 /BISECT-COVERAGE-4 4 16 server\/serve.mbt 13 /' \
  "$fixtures/in-process.bisect" >"$tmp/no-point-in-process.bisect"
sed 's/ 632 645 / 645 /; s/ 14 1 2 0 2 0 2 2 2 0 2 1 0 0 0 / 13 1 2 0 2 0 2 2 2 2 1 0 0 0 /; s/^BISECT-COVERAGE-4 4 16 server\/serve.mbt 14 /BISECT-COVERAGE-4 4 16 server\/serve.mbt 13 /' \
  "$fixtures/e2e.bisect" >"$tmp/no-point-e2e.bisect"
report no-point "$tmp/no-point-in-process.bisect" "$tmp/no-point-e2e.bisect"
exits no-point 0
positions no-point covered-by-e2e
in_list no-point covered-by-e2e "server/serve.mbt:25:10 INT"
says no-point "| server | 31 | 23 | 8 | 24 |"
says no-point "- \`server/serve.mbt:25:10\`, a match arm in \`Server::serve\`"

# --- The e2e run, and the times --------------------------------------------------

# What moon printed of the e2e tests, and the times of the steps, as
# scripts/coverage-e2e.sh gives them. moon names a failed test
# `[<module>] test <file>:<line> ("<name>") failed`.
printf '%s\n' "Total tests: 644, passed: 644, failed: 0." >"$tmp/passed.txt"
printf '%s\t%s\n' 79 "the in-process tests with coverage, and the instrumented binary" \
  95 "the e2e tests' build" 36 "the e2e tests, with the instrumented binary" >"$tmp/times.txt"
report ran "$fixtures/in-process.bisect" "$fixtures/e2e.bisect" --tests "$tmp/passed.txt" --tests-status 0 \
  --times "$tmp/times.txt"
exits ran 0
says ran "The e2e tests ran 644 tests with the instrumented binary: 644 passed, 0 failed."
says ran "| the in-process tests with coverage, and the instrumented binary | 1 min 19 s |"
says ran "| the e2e tests' build | 1 min 35 s |"
says ran "| the e2e tests, with the instrumented binary | 36 s |"
says ran "| all | 3 min 30 s |"

# Failed tests are named; the report reports only, so it still exits 0.
cat >"$tmp/failed.txt" <<'TXT'
[smock/smock] test e2e/drain_test.mbt:12 ("the drain ends at once") failed: timed out
[smock/smock] test e2e/tls_test.mbt:300 ("a rotation keeps the old certificate") failed
Total tests: 644, passed: 642, failed: 2.
TXT
report failed "$fixtures/in-process.bisect" "$fixtures/e2e.bisect" --tests "$tmp/failed.txt" --tests-status 1
exits failed 0
says failed "**2 of the 644 e2e tests failed**, so the e2e tests' report may lack points they would have reached after they failed. The report reports only, and fails nothing for it:"
says failed "- \`e2e/drain_test.mbt:12\` the drain ends at once"
says failed "- \`e2e/tls_test.mbt:300\` a rotation keeps the old certificate"

# A run that printed no summary, such as one whose build failed.
printf '%s\n' "error: something went wrong" >"$tmp/no-summary.txt"
report no-summary "$fixtures/in-process.bisect" "$fixtures/e2e.bisect" --tests "$tmp/no-summary.txt" \
  --tests-status 2
exits no-summary 0
says no-summary "**moon printed no summary of the e2e tests, and exited with 2**, so the e2e tests' report may lack the points they reach."

# --- The points no test reaches -------------------------------------------------

# lacks <name> <text>: the report <name> printed no line that holds <text>.
lacks() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    fail "$1: says $2"
  else
    pass "$1: does not say $2"
  fi
}

# Those of server, cmd/smock, defdir, watch and openssl, by file and
# definition: the points whose count is 0 in both reports.
says fixture "### server: 5 of 14 points unreached"
says fixture "- \`server/serve.mbt:18:27\` in \`Server::serve\`"
says fixture "- \`server/serve.mbt:25:10\` in \`Server::serve\`"
says fixture "- \`server/serve.mbt:34:5\` in \`Server::stop\`"
says fixture "- \`server/serve.mbt:37:5\` in \`Server::stop\`"
says fixture "- \`server/serve.mbt:45:3\` in \`Server::unused\`"
says fixture "### cmd/smock: 1 of 9 points unreached"
says fixture "- \`cmd/smock/main.mbt:7:41\` in \`main\`"
says fixture "### watch: 1 of 3 points unreached"
says fixture "- \`watch/watch.mbt:5:5\` in \`changed\`"
# The then that only the in-process tests reach is reached.
lacks fixture "server/serve.mbt:20:5"
# prng's unreached point is counted in the table, not listed.
lacks fixture "### prng"
lacks fixture "prng/prng.mbt:5:5"

# unreached.json holds the same points, which the triage reads.
if python3 - "$tmp/fixture/unreached.json" >"$tmp/unreached.out" 2>&1 <<'PY'; then
import json, sys
found = json.load(open(sys.argv[1], encoding="utf-8"))["packages"]
assert sorted(found) == ["cmd/smock", "server", "watch"], sorted(found)
assert found["server"]["points"] == 14
assert [p["point"] for p in found["server"]["unreached"]] == [
    "server/serve.mbt:18:27", "server/serve.mbt:25:10", "server/serve.mbt:34:5", "server/serve.mbt:37:5",
    "server/serve.mbt:45:3"], found["server"]["unreached"]
assert found["server"]["unreached"][2] == {"point": "server/serve.mbt:34:5", "file": "server/serve.mbt",
                                           "line": 34, "column": 5, "definition": "Server::stop", "deferred": None}
assert [p["point"] for p in found["cmd/smock"]["unreached"]] == ["cmd/smock/main.mbt:7:41"]
assert found["server"]["accepted"] == []
PY
  pass "fixture: unreached.json holds the unreached points of server, cmd/smock and watch"
else
  fail "fixture: unreached.json: $(cat "$tmp/unreached.out")"
fi

# With an exclusion list, whose definitions the site finder's parser
# reads, so only where moonc is installed: a DEFERRED entry's point stays
# unreached, with its issue; another entry's point is accepted, apart.
if command -v moonc >/dev/null 2>&1; then
  cp -R "$fixtures/tree" "$tmp/listed-tree"
  {
    python3 scripts/mutation/exclusions.py --root "$tmp/listed-tree" new server/serve.mbt:34:5 |
      sed 's/^category = .*/category = "DEFERRED"/; s/^reason = .*/reason = "a test of a forced stop"/'
    echo 'issue = 9001'
    python3 scripts/mutation/exclusions.py --root "$tmp/listed-tree" new server/serve.mbt:45:3 |
      sed 's/^category = .*/category = "UNREACHABLE"/; s/^reason = .*/reason = "nothing calls it"/'
    echo 'argument = "no caller"'
  } >"$tmp/listed-tree/exclusions.toml"
  status=0
  python3 scripts/coverage-e2e.py report --root "$tmp/listed-tree" --trees "$fixtures/trees" \
    --in-process "$fixtures/in-process.bisect" --e2e "$fixtures/e2e.bisect" --out "$tmp/listed" \
    >"$tmp/listed.out" 2>&1 || status=$?
  echo "$status" >"$tmp/listed.status"
  exits listed 0
  says listed "### server: 4 of 14 points unreached"
  says listed "- \`server/serve.mbt:34:5\` in \`Server::stop\` (DEFERRED to #9001)"
  says listed "### server: 1 point accepted by the exclusion list"
  says listed "- \`server/serve.mbt:45:3\` in \`Server::unused\`, UNREACHABLE"
  says listed "| server | 14 | 7 (50.0%) | 8 (57.1%) | 9 (64.3%) | 4 |"
else
  echo "skip listed: moonc is not installed, and the exclusion list's definitions need it"
fi

# --- The triage tickets ---------------------------------------------------------

# triage <name> [option]...: cuts the unreached points of the report
# fixture into triage tickets, into $tmp/<name>/, its output into
# $tmp/<name>.out and its exit status into $tmp/<name>.status.
triage() {
  name=$1
  shift
  status=0
  python3 scripts/coverage-e2e.py triage --report "$tmp/fixture" --out "$tmp/$name" "$@" \
    >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# holds <name> <file> <line>: the file <file> that the triage <name> wrote
# holds the line <line>.
holds() {
  if [ -f "$tmp/$1/$2" ] && grep -qxF -- "$3" "$tmp/$1/$2"; then
    pass "$1: $2 holds $3"
  else
    fail "$1: $2 does not hold $3"
    sed 's/^/     /' "$tmp/$1/$2" 2>/dev/null || true
  fi
}

# tickets <name> <expected>: tickets.json lists, for each ticket, its body's
# file, its points, its title, labels, blockers and the ticket it blocks,
# as <expected>, one ticket a line.
tickets() {
  if python3 - "$tmp/$1/tickets.json" >"$tmp/$1.tickets" 2>&1 <<'PY'; then
import json, sys
for ticket in json.load(open(sys.argv[1], encoding="utf-8")):
    print(ticket["body"], " ".join(ticket["points"]), "|", ticket["title"], "|", ",".join(ticket["labels"]),
          "|", " ".join(f"#{n}" for n in ticket["blocked_by"]), "| blocks", f"#{ticket['blocks']}")
PY
    if [ "$(cat "$tmp/$1.tickets")" = "$2" ]; then
      pass "$1: tickets.json lists the tickets"
      return
    fi
  fi
  fail "$1: tickets.json lists: $(cat "$tmp/$1.tickets")"
}

# The closing ticket's body, as the triage reads it from --bodies: its
# criteria for a point's class, dead code, missing tests, exclusions, the
# points no dump can show and the request path are carried; the one that
# checks the result after the triage is not.
mkdir -p "$tmp/bodies"
cat >"$tmp/bodies/343.md" <<'MD'
## Acceptance criteria

- [ ] Every point of server and cmd/smock that the merged report shows unreached has a class.
- [ ] **Dead code** is deleted.
- [ ] **Missing tests** go through e2e.
- [ ] **Exclusions** go in the exclusion list.
- [ ] **Points no dump can show.** A point that a test reaches only in a process that writes no dump is listed.
- [ ] After the triage, the weekly report shows no unreached point in server or cmd/smock outside exclusions.
- [ ] Request path: tests only.
MD

# Six points of server and cmd/smock unreached, no more than about 40: no
# ticket; #343 triages them itself.
triage few --bodies "$tmp/bodies"
exits few 0
holds few tickets.md "| #343 | server, cmd/smock | 6 | none: triaged in #343 |"
tickets few ""

# At most 5 a ticket: server/serve.mbt holds 5, so it is never split, and
# cmd/smock/main.mbt's point goes into a ticket of its own.
triage at-most-5 --max 5 --bodies "$tmp/bodies" --run-url https://example.com/runs/1
exits at-most-5 0
holds at-most-5 tickets.md "| #343 | server, cmd/smock | 6 | 2 |"
tickets at-most-5 "343-1.md server/serve.mbt:18:27 server/serve.mbt:25:10 server/serve.mbt:34:5 server/serve.mbt:37:5 server/serve.mbt:45:3 | Triage the points no test reaches in server/serve.mbt (1 of 2) | ready-for-agent | #342 #318 #319 | blocks #343
343-2.md cmd/smock/main.mbt:7:41 | Triage the points no test reaches in cmd/smock/main.mbt (2 of 2) | ready-for-agent | #342 #318 #319 | blocks #343"
holds at-most-5 343-1.md "#343"
holds at-most-5 343-1.md "Part 1 of 2 of the triage of what no test reaches in server and cmd/smock for #343, in step 5 of #275: the 5 points of [the e2e coverage report](https://example.com/runs/1) that no test reaches, in server/serve.mbt. A point that a DEFERRED entry of the exclusion list covers counts as unreached."
holds at-most-5 343-1.md "- \`server/serve.mbt:34:5\` in \`Server::stop\`"
holds at-most-5 343-1.md "For the 5 points above only."
holds at-most-5 343-1.md "- [ ] Every point of server and cmd/smock that the merged report shows unreached has a class."
holds at-most-5 343-1.md "- [ ] **Dead code** is deleted."
holds at-most-5 343-1.md "- [ ] **Missing tests** go through e2e."
holds at-most-5 343-1.md "- [ ] **Exclusions** go in the exclusion list."
holds at-most-5 343-1.md "- [ ] **Points no dump can show.** A point that a test reaches only in a process that writes no dump is listed."
holds at-most-5 343-1.md "- [ ] Request path: tests only."
holds at-most-5 343-1.md "- #319"
holds at-most-5 343-2.md "- \`cmd/smock/main.mbt:7:41\` in \`main\`"
if grep -qF "After the triage" "$tmp/at-most-5/343-1.md"; then
  fail "at-most-5: 343-1.md carries the criterion that checks the result after the triage"
else
  pass "at-most-5: 343-1.md leaves out the criterion that checks the result after the triage"
fi

# At most 2 a ticket: server/serve.mbt holds more, so it is cut into equal
# parts, 2, 2 and 1. Without the closing ticket's body, a ticket names its
# criteria.
triage at-most-2 --max 2
exits at-most-2 0
holds at-most-2 tickets.md "| #343 | server, cmd/smock | 6 | 4 |"
tickets at-most-2 "343-1.md server/serve.mbt:18:27 server/serve.mbt:25:10 | Triage the points no test reaches in server/serve.mbt (1 of 4) | ready-for-agent | #342 #318 #319 | blocks #343
343-2.md server/serve.mbt:34:5 server/serve.mbt:37:5 | Triage the points no test reaches in server/serve.mbt (2 of 4) | ready-for-agent | #342 #318 #319 | blocks #343
343-3.md server/serve.mbt:45:3 | Triage the points no test reaches in server/serve.mbt (3 of 4) | ready-for-agent | #342 #318 #319 | blocks #343
343-4.md cmd/smock/main.mbt:7:41 | Triage the points no test reaches in cmd/smock/main.mbt (4 of 4) | ready-for-agent | #342 #318 #319 | blocks #343"
holds at-most-2 343-3.md "- [ ] #343's criteria on each point's class, dead code, missing tests, exclusions, the points no dump can show and the request path, as #343 states them."

# Files that hold fewer than the most share a ticket, in order; a title
# names one file, two, or the first and the last with their count, since
# GitHub's titles hold at most 256 characters. A DEFERRED point counts.
mkdir -p "$tmp/several"
python3 - "$tmp/several/unreached.json" <<'PY'
import json, sys
def point(file, line, deferred=None):
    return {"point": f"{file}:{line}:3", "file": file, "line": line, "column": 3, "definition": "f",
            "deferred": deferred}
server = [point("server/a.mbt", n) for n in (1, 2, 3)] + [point("server/b.mbt", 4)]
server += [point("server/c.mbt", 5, deferred=9001), point("server/d.mbt", 6)]
cmd = [point("cmd/smock/main.mbt", n) for n in (7, 8)]
json.dump({"packages": {"server": {"points": 60, "unreached": server, "accepted": []},
                        "cmd/smock": {"points": 9, "unreached": cmd, "accepted": []},
                        "watch": {"points": 3, "unreached": [point("watch/watch.mbt", 9)], "accepted": []}}},
          open(sys.argv[1], "w"))
PY
status=0
python3 scripts/coverage-e2e.py triage --report "$tmp/several" --out "$tmp/several-tickets" --max 4 \
  >"$tmp/several-tickets.out" 2>&1 || status=$?
echo "$status" >"$tmp/several-tickets.status"
exits several-tickets 0
holds several-tickets tickets.md "| #343 | server, cmd/smock | 8 | 2 |"
tickets several-tickets "343-1.md server/a.mbt:1:3 server/a.mbt:2:3 server/a.mbt:3:3 server/b.mbt:4:3 | Triage the points no test reaches in server/a.mbt and server/b.mbt (1 of 2) | ready-for-agent | #342 #318 #319 | blocks #343
343-2.md server/c.mbt:5:3 server/d.mbt:6:3 cmd/smock/main.mbt:7:3 cmd/smock/main.mbt:8:3 | Triage the points no test reaches in server/c.mbt to cmd/smock/main.mbt, 3 files (2 of 2) | ready-for-agent | #342 #318 #319 | blocks #343"
holds several-tickets 343-2.md "- \`server/c.mbt:5:3\` in \`f\` (DEFERRED to #9001)"

# --- Reports it cannot read together --------------------------------------------

# broken <name> <in-process text> <e2e text> <message>: the report of the
# two texts exits with 2 and says <message>.
broken() {
  printf '%s\n' "$2" >"$tmp/$1-in-process.bisect"
  printf '%s\n' "$3" >"$tmp/$1-e2e.bisect"
  report "$1" "$tmp/$1-in-process.bisect" "$tmp/$1-e2e.bisect"
  exits "$1" 2
  says "$1" "coverage-e2e: $4"
}

# Two reports made of other trace sources: the points differ.
broken other-points "BISECT-COVERAGE-4 1 13 prng/prng.mbt 3 103 122 139 3 0 0 0" \
  "BISECT-COVERAGE-4 1 13 prng/prng.mbt 2 103 139 2 1 1" \
  "the two reports do not hold the same points: prng/prng.mbt differs"
broken other-files "BISECT-COVERAGE-4 1 13 prng/prng.mbt 3 103 122 139 3 0 0 0" \
  "BISECT-COVERAGE-4 1 15 watch/watch.mbt 3 128 153 174 3 1 0 1" \
  "the two reports do not hold the same points: prng/prng.mbt is in one only"
broken not-a-report "BISECT-COVERAGE-4 1 13 prng/prng.mbt 3 103 122 139 3 0 0 0" \
  '<?xml version="1.0"?>' \
  "$tmp/not-a-report-e2e.bisect: not a bisect report of format 4 (BISECT-COVERAGE-4)"

echo "test-coverage-e2e: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

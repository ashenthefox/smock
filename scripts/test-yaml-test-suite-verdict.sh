#!/bin/sh
# Tests of the yaml-test-suite verdict (scripts/yaml-test-suite-verdict.py),
# which scripts/check-yaml-test-suite.sh runs on the testee's answers. Each
# test writes a small suite, its cases laid out as in yaml-test-suite's data
# release, the testee's answers for them, and a list of cases for one mode,
# runs the verdict on them, and checks its exit status and what it prints.
#
# usage: scripts/test-yaml-test-suite-verdict.sh
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

# suite: starts a new, empty suite in $tmp/suite, with no answers, and
# empty lists.
suite() {
  rm -rf "$tmp/suite"
  mkdir -p "$tmp/suite"
  : >"$tmp/answers"
  list safe
  list openapi
}

# testcase <id> <name> <in.yaml> <test.event> [<in.json> | error]: adds the case
# <id> to the suite, as the data release lays it out: its name, its input,
# the events a YAML parser reads from it (one per line, as \n separates
# them here), and the JSON it reads as, or that it is an error. Without
# either, the suite gives the case no JSON.
testcase() {
  mkdir -p "$tmp/suite/$1"
  printf '%s\n' "$2" >"$tmp/suite/$1/==="
  printf '%b' "$3" >"$tmp/suite/$1/in.yaml"
  printf '%b\n' "$4" >"$tmp/suite/$1/test.event"
  case ${5-} in
  "") ;;
  error) : >"$tmp/suite/$1/error" ;;
  *) printf '%s\n' "$5" >"$tmp/suite/$1/in.json" ;;
  esac
}

# answer <id> <safe reading> <openapi reading>: adds the testee's answer for
# the case <id>, each reading as the testee writes it, such as
# {"value":{"a":1}}.
answer() {
  printf '{"case":"%s","safe":%s,"openapi":%s}\n' "$1" "$2" "$3" >>"$tmp/answers"
}

# list <mode> <line>...: writes $tmp/<mode>.txt, a list of cases with a
# comment first, one entry for each line.
list() {
  mode=$1
  shift
  printf '# A list of cases for the tests.\n' >"$tmp/$mode.txt"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp/$mode.txt"
  done
}

# verdict <name> [<mode> [github]]: runs the verdict on $tmp/<mode>.txt
# (default: safe), the suite and the answers, into $tmp/<name>.out, and its
# exit status into $tmp/<name>.status; with github, as on GitHub Actions,
# and otherwise as elsewhere, wherever the tests run.
verdict() {
  mode=${2:-safe}
  github=""
  [ "${3:-}" = github ] && github=true
  status=0
  env GITHUB_ACTIONS="$github" python3 scripts/yaml-test-suite-verdict.py \
    "$tmp/$mode.txt" "$tmp/suite" "$tmp/answers" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# exits <name> <status>: the verdict <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <line>: the verdict <name> printed <line>.
says() {
  if grep -qxF -- "$2" "$tmp/$1.out"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# never <name> <text>: the verdict <name> printed no line with <text>.
never() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    fail "$1: mentions $2"
    sed 's/^/     /' "$tmp/$1.out"
  else
    pass "$1: does not mention $2"
  fi
}

# A mapping of one member, which a YAML parser reads as {"a": 1}, and the
# events it gives for it.
mapping='+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :1\n-MAP\n-DOC\n-STR'
value_a='{"value":{"a":1}}'

# --- Cases that pass ---------------------------------------------------------

suite
testcase AAAA "One member" 'a: 1\n' "$mapping" '{"a": 1}'
answer AAAA "$value_a" "$value_a"
verdict all-pass
exits all-pass 0
says all-pass "yaml-test-suite safe: 1 case, 1 passed, 0 skipped, 0 failed"
says all-pass "yaml-test-suite safe: every case passed or is listed"

# --- Cases that fail, listed or not ------------------------------------------

# A case that smock reads otherwise than the suite fails the run, with what
# each reads.
suite
testcase AAAA "One member" 'a: 1\n' "$mapping" '{"a": 1}'
answer AAAA '{"value":{"a":"1"}}' "$value_a"
list safe
verdict unlisted-failure
exits unlisted-failure 1
says unlisted-failure "yaml-test-suite safe: 1 case, 0 passed, 0 skipped, 1 failed"
says unlisted-failure "yaml-test-suite safe: AAAA failed, and is not listed: One member"
says unlisted-failure '    the suite reads: {"a": 1}'
says unlisted-failure '    smock reads: {"a": "1"}'
says unlisted-failure "yaml-test-suite safe: 1 case failed or was skipped, and safe.txt does not list it with that outcome"

# A case listed as a known difference may fail, and the run lists it with
# its reason.
list safe "AAAA  differs  smock reads the number as a string."
verdict listed-difference
exits listed-difference 0
says listed-difference "yaml-test-suite safe: listed in safe.txt, with the reason:"
says listed-difference "  AAAA failed, listed as a known difference: smock reads the number as a string."
says listed-difference "yaml-test-suite safe: every case passed or is listed"

# A case listed as a bug, with its issue, may fail too.
list safe "AAAA  #123  smock reads the number as a string."
verdict listed-bug
exits listed-bug 0
says listed-bug "  AAAA failed, listed until #123: smock reads the number as a string."

# A listed case that passes fails the run, so that it comes off the list.
suite
testcase AAAA "One member" 'a: 1\n' "$mapping" '{"a": 1}'
answer AAAA "$value_a" "$value_a"
list safe "AAAA  #123  smock reads the number as a string."
verdict listed-passes
exits listed-passes 1
says listed-passes "  AAAA passed, listed until #123: smock reads the number as a string."
says listed-passes "yaml-test-suite safe: 1 listed case passed, so it must come off safe.txt: AAAA"
never listed-passes "::notice"

# On GitHub Actions, it is also an error on its line of the list.
verdict listed-passes-on-github safe github
exits listed-passes-on-github 1
says listed-passes-on-github "::error file=$tmp/safe.txt,line=2,title=yaml-test-suite safe::AAAA passes now, so it must come off the list"

# --- Errors, cases without JSON, skipped cases --------------------------------

# Where the suite marks the input an error, smock must refuse it, with any
# message.
suite
testcase BBBB "A tab before a key" '\ta: 1\n' '+STR' error
answer BBBB '{"error":{"pointer":"","message":"tabs are not allowed in indentation"}}' '{"value":{"a":1}}'
verdict error-refused
exits error-refused 0
verdict error-read openapi
exits error-read 1
says error-read "yaml-test-suite openapi: BBBB failed, and is not listed: A tab before a key"
says error-read "    the suite marks the input an error"
says error-read '    smock reads: {"a": 1}'

# Where the suite gives no JSON for a valid input, smock must read it, as
# anything.
suite
testcase CCCC "A long key" 'a: 1\n' "$mapping"
answer CCCC '{"value":{"b":2}}' '{"error":{"pointer":"/a","message":"bad indentation"}}'
verdict no-json-read
exits no-json-read 0
verdict no-json-refused openapi
exits no-json-refused 1
says no-json-refused "    the suite gives no JSON for it, so smock should read it"
says no-json-refused "    smock refuses it: /a: bad indentation"

# A case that the testee skips fails the run, unless it is listed as
# skipped; a case listed as skipped that fails does too.
suite
testcase DDDD "Not UTF-8" 'a: 1\n' "$mapping" '{"a": 1}'
answer DDDD '{"skipped":"not valid UTF-8"}' '{"value":{"a":2}}'
list safe
verdict unlisted-skip
exits unlisted-skip 1
says unlisted-skip "yaml-test-suite safe: 1 case, 0 passed, 1 skipped, 0 failed"
says unlisted-skip "yaml-test-suite safe: DDDD skipped, and is not listed: Not UTF-8"
says unlisted-skip "    the testee skips it: not valid UTF-8"
list safe "DDDD  skipped  The input is not UTF-8."
verdict listed-skip
exits listed-skip 0
says listed-skip "  DDDD skipped, listed as skipped: The input is not UTF-8."
list openapi "DDDD  skipped  The input is not UTF-8."
verdict listed-skip-fails openapi
exits listed-skip-fails 1
says listed-skip-fails "yaml-test-suite openapi: DDDD failed, but is listed as skipped: Not UTF-8"

# --- What the run cannot judge -------------------------------------------------

# A listed case that the suite does not have fails the run: the list is out
# of date.
suite
testcase AAAA "One member" 'a: 1\n' "$mapping" '{"a": 1}'
answer AAAA "$value_a" "$value_a"
list safe "ZZZZ  differs  A case of another release."
verdict stale-entry
exits stale-entry 1
says stale-entry "yaml-test-suite safe: ZZZZ is listed in safe.txt, but the suite has no such case"

# A case of the suite that the testee did not answer fails the run.
testcase EEEE "Unanswered" 'a: 1\n' "$mapping" '{"a": 1}'
list safe
verdict unanswered
exits unanswered 1
says unanswered "yaml-test-suite safe: EEEE has no answer from the testee: Unanswered"

# A list it cannot read, or a list of no mode, stops it with 2.
list safe "AAAA  later  A reason of the wrong kind."
verdict unreadable-list
exits unreadable-list 2
says unreadable-list "yaml-test-suite safe: safe.txt:2: AAAA is listed as 'later', not as differs, skipped or #<issue>"
list safe "AAAA  differs"
verdict list-without-reason
exits list-without-reason 2
list strict
verdict no-such-mode strict
exits no-such-mode 2

# --- What the documents say smock refuses -------------------------------------

# error <message> [<pointer>]: a refusal, as the testee writes it.
error() {
  printf '{"error":{"pointer":"%s","message":"%s"}}' "${2-}" "$1"
}

# A case with a construct that the documents say a mode refuses passes in
# that mode when smock refuses it with the message the documents give for
# it: a message that names it, or "quote this value" or "quote this key"
# for a plain scalar that YAML 1.1 or 1.2 types otherwise. The messages
# below are smock's (yaml/parser.mbt). A mode that reads the construct is
# judged by the suite's JSON as usual.
constructs() {
  suite
  testcase ANCH "An anchor" 'a: &x 1\n' '+STR\n+DOC\n+MAP\n=VAL :a\n=VAL &x :1\n-MAP\n-DOC\n-STR' '{"a": 1}'
  answer ANCH "$(error 'anchors (&) are not supported; quote the value if it is text' /a)" \
    "$(error 'anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text' /a)"
  testcase ALIA "An alias" '- &x a\n- *x\n' '+STR\n+DOC\n+SEQ\n=VAL &x :a\n=ALI *x\n-SEQ\n-DOC\n-STR' '["a", "a"]'
  answer ALIA "$(error 'aliases (*) are not supported; quote the value if it is text' /1)" \
    "$(error 'aliases (*) are not supported; reuse parts with $ref, or quote the value if it is text' /1)"
  testcase TAGS "A tag" 'a: !!str 1\n' '+STR\n+DOC\n+MAP\n=VAL :a\n=VAL <tag:yaml.org,2002:str> :1\n-MAP\n-DOC\n-STR' '{"a": "1"}'
  answer TAGS "$(error 'tags (!) are not supported; quote the value if it is text' /a)" \
    "$(error 'tags (!) are not supported; quote the value if it is text' /a)"
  testcase MERG "A merge key" '<<: {a: 1}\n' '+STR\n+DOC\n+MAP\n=VAL :<<\n+MAP {}\n=VAL :a\n=VAL :1\n-MAP\n-MAP\n-DOC\n-STR' '{"<<": {"a": 1}}'
  answer MERG "$(error 'merge keys (<<) are not supported' '/<<')" "$(error 'merge keys (<<) are not supported' '/<<')"
  testcase DUPL "A duplicate key" '{a: 1, "a": 2}\n' '+STR\n+DOC\n+MAP {}\n=VAL :a\n=VAL :1\n=VAL "a\n=VAL :2\n-MAP\n-DOC\n-STR'
  answer DUPL "$(error 'duplicate key' /a)" "$(error 'duplicate key' /a)"
  testcase DOCS "Two documents" 'a\n---\nb\n' '+STR\n+DOC\n=VAL :a\n-DOC\n+DOC ---\n=VAL :b\n-DOC\n-STR' '"a"
"b"'
  answer DOCS "$(error 'multiple documents are not supported')" "$(error 'multiple documents are not supported')"
  testcase DIRE "A directive" '%YAML 1.2\n---\na\n' '+STR\n+DOC ---\n=VAL :a\n-DOC\n-STR' '"a"'
  answer DIRE "$(error 'directives (%) are not supported')" "$(error 'directives (%) are not supported')"
  testcase EXPL "An explicit key" '? a\n: 1\n' "$mapping" '{"a": 1}'
  answer EXPL "$(error 'explicit keys (?) are not supported')" "$(error 'explicit keys (?) are not supported')"
  testcase EMPT "An empty value" 'a:\n' '+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :\n-MAP\n-DOC\n-STR' '{"a": null}'
  answer EMPT "$(error 'empty value: write null, or \"\" for an empty string' /a)" '{"value":{"a":null}}'
  testcase EKEY "An empty key" ': a\n' '+STR\n+DOC\n+MAP\n=VAL :\n=VAL :a\n-MAP\n-DOC\n-STR'
  answer EKEY "$(error 'a key must not be empty')" "$(error 'a key must not be empty')"
  testcase INDI "An indentation indicator" 'a: |1\n  b\n' '+STR\n+DOC\n+MAP\n=VAL :a\n=VAL | b\\n\n-MAP\n-DOC\n-STR' '{"a": " b\n"}'
  answer INDI "$(error 'block scalar indentation indicators are not supported' /a)" '{"value":{"a":" b\n"}}'
  testcase YES1 "A YAML 1.1 boolean" 'a: yes\n' '+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :yes\n-MAP\n-DOC\n-STR' '{"a": "yes"}'
  answer YES1 "$(error '\"yes\" may be read as a boolean; quote this value' /a)" '{"value":{"a":"yes"}}'
  testcase OCT2 "A YAML 1.2 octal number" 'a: 0o17\n' '+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :0o17\n-MAP\n-DOC\n-STR' '{"a": 15}'
  answer OCT2 "$(error '\"0o17\" may be read as a number; quote this value' /a)" '{"value":{"a":15}}'
  testcase KEY1 "A number as a key" '1: a\n' '+STR\n+DOC\n+MAP\n=VAL :1\n=VAL :a\n-MAP\n-DOC\n-STR' '{"1": "a"}'
  answer KEY1 "$(error '\"1\" is read as a number; quote this key' /1)" '{"value":{"1":"a"}}'
  # yaml.org's timestamp page gives this as a timestamp, "space separated",
  # though its regular expression takes blanks only before Z.
  testcase TIME "A YAML 1.1 timestamp" '- 2001-12-14 21:59:43.10 -5\n' '+STR\n+DOC\n+SEQ\n=VAL :2001-12-14 21:59:43.10 -5\n-SEQ\n-DOC\n-STR' '["2001-12-14 21:59:43.10 -5"]'
  answer TIME "$(error '\"2001-12-14 21:59:43.10 -5\" may be read as a timestamp; quote this value' /0)" \
    '{"value":["2001-12-14 21:59:43.10 -5"]}'
  testcase INFI "Infinity" '- .inf\n' '+STR\n+DOC\n+SEQ\n=VAL :.inf\n-SEQ\n-DOC\n-STR'
  answer INFI "$(error '\".inf\" may be read as a number; quote this value' /0)" \
    "$(error '\".inf\" is infinity, which JSON cannot hold; quote this value' /0)"
  # What only looks like those: a number in JSON syntax, which YAML 1.1
  # reads as a string, plain scalars with ? or yes in them, and lines that
  # start with %, but are no directive.
  testcase NEAR "Near misses" '- 1e3\n- yes!\n- a ? b\n- x?\n' '+STR\n+DOC\n+SEQ\n=VAL :1e3\n=VAL :yes!\n=VAL :a ? b\n=VAL :x?\n-SEQ\n-DOC\n-STR' '[1000, "yes!", "a ? b", "x?"]'
  answer NEAR '{"value":[1000,"yes!","a ? b","x?"]}' '{"value":[1000,"yes!","a ? b","x?"]}'
  testcase PCNT "A key that ends in %" '{ matches\n% : 20 }\n' '+STR\n+DOC\n+MAP {}\n=VAL :matches %\n=VAL :20\n-MAP\n-DOC\n-STR' '{"matches %": 20}'
  answer PCNT '{"value":{"matches %":20}}' '{"value":{"matches %":20}}'
  testcase PSCR "A literal that starts with %" '--- |\n%!PS\n' '+STR\n+DOC ---\n=VAL |%!PS\\n\n-DOC\n-STR' '"%!PS\n"'
  answer PSCR '{"value":"%!PS\n"}' '{"value":"%!PS\n"}'
}

constructs
verdict constructs-refused
exits constructs-refused 0
says constructs-refused "yaml-test-suite safe: 19 cases, 19 passed, 0 skipped, 0 failed"
verdict constructs-refused-openapi openapi
exits constructs-refused-openapi 0
says constructs-refused-openapi "yaml-test-suite openapi: 19 cases, 19 passed, 0 skipped, 0 failed"

# A refusal for another reason does not count, nor does reading it.
constructs
sed -i 's|"anchors (&) are not supported; quote the value if it is text"|"bad indentation"|' "$tmp/answers"
sed -i 's|{"error":{"pointer":"/a","message":"\\"yes\\" may be read as a boolean; quote this value"}}|{"value":{"a":"yes"}}|' "$tmp/answers"
sed -i 's|quote this key|quote this value|' "$tmp/answers"
sed -i 's|"directives (%) are not supported"|"multiple documents are not supported"|' "$tmp/answers"
verdict constructs-otherwise
exits constructs-otherwise 1
says constructs-otherwise "yaml-test-suite safe: 19 cases, 15 passed, 0 skipped, 4 failed"
says constructs-otherwise "yaml-test-suite safe: ANCH failed, and is not listed: An anchor"
says constructs-otherwise "    the documents say the safe subset refuses an anchor, with a message that names it"
says constructs-otherwise "    smock refuses it: /a: bad indentation"
says constructs-otherwise "yaml-test-suite safe: YES1 failed, and is not listed: A YAML 1.1 boolean"
says constructs-otherwise '    the documents say the safe subset refuses the plain value "yes", which YAML 1.1 or 1.2 types otherwise, with "quote this value"'
says constructs-otherwise '    smock reads: {"a": "yes"}'
says constructs-otherwise "yaml-test-suite safe: KEY1 failed, and is not listed: A number as a key"
says constructs-otherwise '    the documents say the safe subset refuses the plain key "1", which YAML 1.1 or 1.2 does not read as a string, with "quote this key"'
says constructs-otherwise "yaml-test-suite safe: DIRE failed, and is not listed: A directive"
says constructs-otherwise "    the documents say the safe subset refuses a directive, with a message that names it"

echo
echo "test-yaml-test-suite-verdict: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

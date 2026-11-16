#!/bin/sh
# Tests of the cross-check of the JSON Schema with smock
# (scripts/check-schema.sh), which CI runs in every run: that it passes
# when each fixture gets the verdicts its directory expects, from one
# validator run for all the fixtures and one smock check for each; that it
# fails, naming the fixture and showing the validator's own report, when a
# fixture does not; and that it judges nothing when the validator's run
# goes wrong. Each test runs a copy of the check in a temporary tree that
# holds a small Schema and a few fixtures, and checks its exit status, what
# it prints, and how it ran the validator and smock.
#
# The validator and smock are fakes that judge a fixture by the words in it.
# The check finds the validator as uvx, or as pipx, on a PATH that holds
# only the fakes and the few other commands it runs, so no real validator
# or smock runs. It needs no network and no moon; it needs jq, as the check
# does.
#
# usage: scripts/test-check-schema.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
fixtures=schema/v1/fixtures

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

# The check-jsonschema version the check pins, read as
# .github/workflows/schema-pages.yml reads it.
version=$(sed -n 's/^validator_version=//p' scripts/check-schema.sh)
if [ -n "$version" ]; then
  pass "scripts/check-schema.sh has the validator_version line schema-pages.yml reads"
else
  fail "scripts/check-schema.sh has no validator_version line for schema-pages.yml"
fi

# The commands that the check and the fakes run, each as a script in one
# directory that runs the command with this script's PATH. The check's PATH
# is then that directory and the fakes', and holds no real uvx, pipx or
# smock. A script, not a link, since a version manager's shim, as mise puts
# on PATH, may look for the command on PATH again.
sys=$tmp/sys
mkdir "$sys"
for command in cp dirname grep head jq mkdir mktemp rm sed; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "test-check-schema: needs $command" >&2
    exit 2
  fi
  printf '#!/bin/sh\nPATH=%s exec %s "$@"\n' "'$PATH'" "$command" >"$sys/$command"
  chmod +x "$sys/$command"
done

# A fake check-jsonschema. It rejects a file once for each line that holds
# schema-rejects, cannot parse a file that holds unparsable, and accepts the
# others. Its JSON report takes the shapes that check-jsonschema 0.38.2's
# does: {"status": "ok", "errors": []} when it rejects no file, and status
# fail with both errors and parse_errors, their entries with the same keys,
# when it rejects any. It logs each run, after the runner that started it,
# as "metaschema <schema>", "json <files>" or "text <files>".
# FAKE_VALIDATOR makes a JSON run go wrong: crash, status-2, not-json,
# nothing-rejected (it exits with status 1 all the same), rejects-with-0 (it
# exits with status 0 all the same), stranger (its report rejects a file it
# was not given), not-a-list (its report's parse_errors is not an array) or
# no-filename (an entry of its report names no file); bad-metaschema makes
# the Schema fail its check.
{
  echo '#!/bin/sh'
  echo "log='$tmp/validator.log'"
  cat <<'SH'
format=text
metaschema=false
schemafile=
while [ "$#" -gt 0 ]; do
  case $1 in
  --check-metaschema)
    metaschema=true
    shift
    ;;
  --output-format)
    format=$2
    shift 2
    ;;
  --schemafile)
    schemafile=$2
    shift 2
    ;;
  -*)
    echo "fake check-jsonschema: unknown option $1" >&2
    exit 2
    ;;
  *) break ;;
  esac
done
if $metaschema; then
  echo "$FAKE_RUNNER: metaschema $*" >>"$log"
  if [ "${FAKE_VALIDATOR:-}" = bad-metaschema ]; then
    echo "fake check-jsonschema: $1 is not a valid JSON Schema"
    exit 1
  fi
  echo "ok -- validation done"
  exit 0
fi
if [ -z "$schemafile" ] || [ "$#" -eq 0 ]; then
  echo "fake check-jsonschema: needs --schemafile and files" >&2
  exit 2
fi
echo "$FAKE_RUNNER: $format $*" >>"$log"

errors=
parse_errors=
text=
for file; do
  if grep -q unparsable "$file"; then
    parse_errors="$parse_errors, {\"filename\": \"$file\", \"message\": \"Failed to parse $file\"}"
    text="$text  $file: fake: cannot parse it
"
    continue
  fi
  rejections=$(grep -c schema-rejects "$file") || :
  while [ "$rejections" -gt 0 ]; do
    errors="$errors, {\"filename\": \"$file\", \"path\": \"\$\", \"message\": \"fake: the Schema rejects it\", \"has_sub_errors\": false}"
    text="$text  $file::\$: fake: the Schema rejects it
"
    rejections=$((rejections - 1))
  done
done

if [ "$format" = text ]; then
  if [ -n "$text" ]; then
    echo "Schema validation errors were encountered."
    printf '%s' "$text"
    exit 1
  fi
  echo "ok -- validation done"
  exit 0
fi

status=0
[ -z "$errors$parse_errors" ] || status=1
case ${FAKE_VALIDATOR:-} in
crash)
  echo "Traceback (most recent call last):" >&2
  echo "RuntimeError: fake crash" >&2
  exit 1
  ;;
status-2)
  echo "Error: fake usage error" >&2
  exit 2
  ;;
not-json)
  echo "Schema validation errors were encountered."
  exit 1
  ;;
nothing-rejected) errors= parse_errors= status=1 ;;
rejects-with-0) status=0 ;;
stranger) errors=", {\"filename\": \"elsewhere.json\", \"path\": \"\$\", \"message\": \"fake\", \"has_sub_errors\": false}" ;;
not-a-list)
  echo '{"status": "ok", "errors": [], "parse_errors": false}'
  exit 0
  ;;
no-filename) errors="$errors, {\"path\": \"\$\", \"message\": \"fake\", \"has_sub_errors\": false}" ;;
esac
if [ "$status" -eq 0 ]; then
  printf '{"status": "ok", "errors": [%s]}\n' "${errors#, }"
else
  printf '{"status": "fail", "errors": [%s], "parse_errors": [%s]}\n' "${errors#, }" "${parse_errors#, }"
fi
exit "$status"
SH
} >"$tmp/check-jsonschema"

# The runners, each in a directory of its own: uvx and pipx, which check how
# they are asked to run check-jsonschema and run the fake.
mkdir "$tmp/uvx" "$tmp/pipx"
{
  echo '#!/bin/sh'
  echo "validator='$tmp/check-jsonschema'"
  cat <<'SH'
case $1 in
check-jsonschema@*) ;;
*)
  echo "fake uvx: cannot run $1" >&2
  exit 2
  ;;
esac
FAKE_RUNNER="uvx $1"
export FAKE_RUNNER
shift
exec "$validator" "$@"
SH
} >"$tmp/uvx/uvx"
{
  echo '#!/bin/sh'
  echo "validator='$tmp/check-jsonschema'"
  cat <<'SH'
if [ "$1 $2 $4" != "run --spec check-jsonschema" ]; then
  echo "fake pipx: cannot run $*" >&2
  exit 2
fi
FAKE_RUNNER="pipx $3"
export FAKE_RUNNER
shift 4
exec "$validator" "$@"
SH
} >"$tmp/pipx/pipx"

# A fake smock, of which the check runs `smock check <directory>`. It logs
# the fixture in the directory, and rejects it when it holds smock-rejects,
# or when the directory lacks the body files. It exits with status 3 when
# the fixture holds smock-crashes.
{
  echo '#!/bin/sh'
  echo "log='$tmp/smock.log'"
  cat <<'SH'
[ "$#" -eq 2 ] && [ "$1" = check ] || exit 64
names=
for file in "$2"/*; do
  [ "$file" = "$2/files" ] || names="$names ${file##*/}"
done
echo "${names# }" >>"$log"
if [ ! -f "$2/files/body.txt" ]; then
  echo "fake smock: no body files"
  exit 1
fi
for file in "$2"/*; do
  [ -f "$file" ] || continue
  if grep -q smock-crashes "$file"; then
    echo "fake smock: crashed"
    exit 3
  fi
  if grep -q smock-rejects "$file"; then
    echo "fake smock: ${file##*/} is invalid"
    exit 1
  fi
done
echo "fake smock: all good"
SH
} >"$tmp/smock"
chmod +x "$tmp/check-jsonschema" "$tmp/uvx/uvx" "$tmp/pipx/pipx" "$tmp/smock"

# fixture <path> <text>: writes the fixture at <path> under the fixtures'
# directory.
fixture() {
  printf '%s\n' "$2" >"$repo/$fixtures/$1"
}

# tree: makes $repo anew, with the check, a Schema that passes its own
# checks, the body files, and five fixtures, each in the directory that
# its verdicts call for.
tree() {
  rm -rf "$repo"
  mkdir -p "$repo/scripts" "$repo/$fixtures/valid" "$repo/$fixtures/invalid" \
    "$repo/$fixtures/invalid-beyond-schema" "$repo/$fixtures/body-files"
  cp scripts/check-schema.sh "$repo/scripts/"
  cat >"$repo/schema/v1/definitions.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://hirunefu.github.io/smock/schema/v1/definitions.json",
  "type": "object",
  "properties": {
    "stubs": { "description": "The Stubs.", "type": "array" },
    "mock": { "$ref": "#/$defs/mock" }
  },
  "$defs": {
    "mock": { "description": "A Mock.", "type": "object" }
  }
}
JSON
  echo "a body" >"$repo/$fixtures/body-files/body.txt"
  fixture valid/also.yaml 'stubs: []'
  fixture valid/plain.json '{"stubs": []}'
  fixture invalid/rejected.json '{"stubs": "schema-rejects",
 "mock": "schema-rejects smock-rejects"}'
  fixture invalid/unparsable.yaml 'unparsable smock-rejects'
  fixture invalid-beyond-schema/across.json '{"stubs": ["smock-rejects"]}'
}

# The tree's fixtures, as the check names them.
v=$fixtures/valid
i=$fixtures/invalid
b=$fixtures/invalid-beyond-schema
all="$v/also.yaml $v/plain.json $i/rejected.json $i/unparsable.yaml $b/across.json"

# check <name> [<FAKE_VALIDATOR>] [<runner directory>]: runs the check in
# the tree, with the validator going wrong as asked, and uvx unless another
# runner's directory is given ("" for none). Its output goes into
# $tmp/<name>.out, its exit status into $tmp/<name>.status, and the logs of
# the validator's and smock's runs into $tmp/<name>.validator and
# $tmp/<name>.smock.
check() {
  : >"$tmp/validator.log"
  : >"$tmp/smock.log"
  runner=$tmp/uvx
  [ "$#" -lt 3 ] || runner=$3
  status=0
  FAKE_VALIDATOR=${2:-} PATH="${runner:+$runner:}$sys" \
    "$repo/scripts/check-schema.sh" "$tmp/smock" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
  cp "$tmp/validator.log" "$tmp/$1.validator"
  cp "$tmp/smock.log" "$tmp/$1.smock"
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

# never <name> <text>: the check <name> printed <text> in no line.
never() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    fail "$1: says $2"
    sed 's/^/     /' "$tmp/$1.out"
  else
    pass "$1: never says $2"
  fi
}

# ran <name> <validator|smock> <line>...: the check <name> ran the validator
# or smock as these lines of its log say, and no more.
ran() {
  name=$1
  log=$2
  shift 2
  if [ "$#" -eq 0 ]; then
    : >"$tmp/expected"
  else
    printf '%s\n' "$@" >"$tmp/expected"
  fi
  if cmp -s "$tmp/expected" "$tmp/$name.$log"; then
    pass "$name: runs $log $# times as it should"
  else
    fail "$name: runs $log otherwise:"
    diff "$tmp/expected" "$tmp/$name.$log" | sed 's/^/     /'
  fi
}

uvx="uvx check-jsonschema@$version"
schema=schema/v1/definitions.json

# --- Verdicts as expected ----------------------------------------------------

# Each fixture gets the verdicts its directory calls for. The validator
# runs on the Schema, then once on all the fixtures, and smock once on each
# fixture alone, with the body files beside it. A fixture with two errors
# is rejected once.
tree
check good
exits good 0
says good "valid/also.yaml: the Schema says valid, smock says valid"
says good "    fake smock: all good"
says good "valid/plain.json: the Schema says valid, smock says valid"
says good "invalid/rejected.json: the Schema says invalid, smock says invalid"
says good "    fake smock: rejected.json is invalid"
says good "invalid/unparsable.yaml: the Schema says invalid, smock says invalid"
says good "invalid-beyond-schema/across.json: the Schema says valid, smock says invalid"
says good "check-schema: the Schema and smock agree on all 5 fixtures"
ran good validator "$uvx: metaschema $schema" "$uvx: json $all"
ran good smock also.yaml plain.json rejected.json unparsable.yaml across.json

# Without uvx, pipx runs the validator, at the same version.
tree
check pipx "" "$tmp/pipx"
exits pipx 0
says pipx "check-schema: the Schema and smock agree on all 5 fixtures"
pipx="pipx check-jsonschema==$version"
ran pipx validator "$pipx: metaschema $schema" "$pipx: json $all"

# A directory with no fixture has nothing to check, and no fixture at all
# leaves the validator nothing to run on.
tree
rm "$repo/$b/across.json"
check empty-category
exits empty-category 0
says empty-category "check-schema: the Schema and smock agree on all 4 fixtures"
rm "$repo/$v/"* "$repo/$i/"*
check no-fixtures
exits no-fixtures 0
says no-fixtures "check-schema: the Schema and smock agree on all 0 fixtures"
ran no-fixtures validator "$uvx: metaschema $schema"
ran no-fixtures smock

# Fixtures that the Schema all accepts: the validator exits with 0, and its
# report lists no parse_errors.
tree
rm "$repo/$i/"*
check accepts-all
exits accepts-all 0
says accepts-all "valid/plain.json: the Schema says valid, smock says valid"
says accepts-all "invalid-beyond-schema/across.json: the Schema says valid, smock says invalid"
says accepts-all "check-schema: the Schema and smock agree on all 3 fixtures"
ran accepts-all validator "$uvx: metaschema $schema" "$uvx: json $v/also.yaml $v/plain.json $b/across.json"
ran accepts-all smock also.yaml plain.json across.json

# --- Verdicts that are not as expected ---------------------------------------

# A valid fixture in invalid/: both verdicts are wrong, and the validator's
# own report on the fixture alone shows why the Schema accepts it.
tree
fixture invalid/accepted.json '{"stubs": []}'
check valid-in-invalid
exits valid-in-invalid 1
says valid-in-invalid "invalid/accepted.json: the Schema says valid, smock says valid"
says valid-in-invalid "check-schema: $i/accepted.json: the Schema should say invalid:"
says valid-in-invalid "    ok -- validation done"
says valid-in-invalid "check-schema: $i/accepted.json: smock should say invalid"
never valid-in-invalid "agree on all"
ran valid-in-invalid validator "$uvx: metaschema $schema" \
  "$uvx: json $v/also.yaml $v/plain.json $i/accepted.json $i/rejected.json $i/unparsable.yaml $b/across.json" \
  "$uvx: text $i/accepted.json"

# The same when the Schema accepts every fixture, so that the validator
# exits with 0: the check still names the invalid fixture.
tree
rm "$repo/$i/"*
fixture invalid/accepted.json '{"stubs": ["smock-rejects"]}'
check accepts-invalid
exits accepts-invalid 1
says accepts-invalid "invalid/accepted.json: the Schema says valid, smock says invalid"
says accepts-invalid "check-schema: $i/accepted.json: the Schema should say invalid:"
says accepts-invalid "    ok -- validation done"
never accepts-invalid "smock should say"
never accepts-invalid "trusted"
ran accepts-invalid validator "$uvx: metaschema $schema" \
  "$uvx: json $v/also.yaml $v/plain.json $i/accepted.json $b/across.json" \
  "$uvx: text $i/accepted.json"

# An invalid fixture in valid/, which the Schema rejects with the
# validator's own message, and one that the validator cannot parse.
tree
fixture valid/rejected.json '{"stubs": "schema-rejects smock-rejects"}'
fixture valid/unparsable.json 'unparsable'
check invalid-in-valid
exits invalid-in-valid 1
says invalid-in-valid "valid/rejected.json: the Schema says invalid, smock says invalid"
says invalid-in-valid "check-schema: $v/rejected.json: the Schema should say valid:"
says invalid-in-valid "      $v/rejected.json::\$: fake: the Schema rejects it"
says invalid-in-valid "check-schema: $v/rejected.json: smock should say valid"
says invalid-in-valid "valid/unparsable.json: the Schema says invalid, smock says valid"
says invalid-in-valid "check-schema: $v/unparsable.json: the Schema should say valid:"
says invalid-in-valid "      $v/unparsable.json: fake: cannot parse it"
never invalid-in-valid "check-schema: $v/unparsable.json: smock should say"

# A fixture in invalid-beyond-schema/ that smock accepts: only smock is
# wrong.
tree
fixture invalid-beyond-schema/accepted.json '{"stubs": []}'
check beyond-accepted
exits beyond-accepted 1
says beyond-accepted "invalid-beyond-schema/accepted.json: the Schema says valid, smock says valid"
says beyond-accepted "check-schema: $b/accepted.json: smock should say invalid"
never beyond-accepted "the Schema should say"

# A file whose name is not a fixture's is reported, and not given to the
# validator. smock exiting with another status than 0 or 1 gives no verdict.
tree
fixture valid/notes.txt 'stubs: []'
fixture valid/crash.json '{"stubs": ["smock-crashes"]}'
check names-and-crash
exits names-and-crash 1
says names-and-crash "check-schema: $v/notes.txt: a fixture's name ends in .json, .yaml or .yml"
says names-and-crash "check-schema: $v/crash.json: smock check exited with status 3:"
says names-and-crash "    fake smock: crashed"
never names-and-crash "valid/crash.json: the Schema says"
ran names-and-crash validator "$uvx: metaschema $schema" \
  "$uvx: json $v/also.yaml $v/crash.json $v/plain.json $i/rejected.json $i/unparsable.yaml $b/across.json"

# --- The validator's run goes wrong ------------------------------------------

# Whenever the validator exits with another status than 0 or 1, its report
# is not one that check-jsonschema prints, or the two do not tell the same
# thing, the check judges no fixture and shows all that the validator
# printed.
untrusted=", so none of the Schema's verdicts can be trusted; it printed:"
tree
check crash crash
exits crash 1
says crash "check-schema: check-jsonschema exited with status 1, and its report is not one JSON object that names a file for each of its errors and parse_errors$untrusted"
says crash "    Traceback (most recent call last):"
never crash "the Schema says"
ran crash smock

check status-2 status-2
exits status-2 1
says status-2 "check-schema: check-jsonschema exited with status 2, which is neither 0 nor 1$untrusted"
says status-2 "    Error: fake usage error"
ran status-2 smock

check not-json not-json
exits not-json 1
says not-json "check-schema: check-jsonschema exited with status 1, and its report is not one JSON object that names a file for each of its errors and parse_errors$untrusted"
says not-json "    Schema validation errors were encountered."

check nothing-rejected nothing-rejected
exits nothing-rejected 1
says nothing-rejected "check-schema: check-jsonschema exited with status 1, but its report rejects no file$untrusted"
says nothing-rejected '    {"status": "fail", "errors": [], "parse_errors": []}'
ran nothing-rejected smock

check rejects-with-0 rejects-with-0
exits rejects-with-0 1
says rejects-with-0 "check-schema: check-jsonschema exited with status 0, but its report rejects files$untrusted"

check stranger stranger
exits stranger 1
says stranger "check-schema: check-jsonschema's report rejects elsewhere.json, which it was not given$untrusted"

check not-a-list not-a-list
exits not-a-list 1
says not-a-list "check-schema: check-jsonschema exited with status 0, and its report is not one JSON object that names a file for each of its errors and parse_errors$untrusted"
says not-a-list '    {"status": "ok", "errors": [], "parse_errors": false}'
ran not-a-list smock

check no-filename no-filename
exits no-filename 1
says no-filename "check-schema: check-jsonschema exited with status 1, and its report is not one JSON object that names a file for each of its errors and parse_errors$untrusted"
ran no-filename smock

# --- The Schema itself, and how the check is run -----------------------------

# The Schema fails its own checks: the validator's, its $id, and a field
# with no description.
tree
jq '."$id" = "https://example.com/definitions.json" | .properties.hosts = {"type": "array"}' \
  "$repo/$schema" >"$tmp/schema.json"
cp "$tmp/schema.json" "$repo/$schema"
check schema bad-metaschema
exits schema 1
says schema "check-schema: $schema is not a valid JSON Schema"
says schema "check-schema: $schema has \$id https://example.com/definitions.json, not the URL it is published at, https://hirunefu.github.io/smock/$schema"
says schema "check-schema: $schema: the field at /properties/hosts has no description"
says schema "invalid/rejected.json: the Schema says invalid, smock says invalid"

# With neither uvx nor pipx, or with more than one argument, nothing is
# checked.
tree
check no-runner "" ""
exits no-runner 2
says no-runner "check-schema: needs uvx or pipx to run check-jsonschema"
ran no-runner smock
status=0
PATH="$tmp/uvx:$sys" "$repo/scripts/check-schema.sh" "$tmp/smock" extra >"$tmp/usage.out" 2>&1 || status=$?
echo "$status" >"$tmp/usage.status"
exits usage 2
says usage "usage: $repo/scripts/check-schema.sh [smock binary]"

echo
echo "test-check-schema: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

#!/bin/sh
# Cross-checks the Definition-file JSON Schema (schema/v1/definitions.json)
# with smock's own validation, which is written by hand.
#
# First it checks the Schema itself: it is a valid JSON Schema, its $id is
# the URL it is published at, and every field has a description.
#
# Then it checks every fixture under schema/v1/fixtures/ twice: with an
# external JSON Schema validator (check-jsonschema), and with `smock check`,
# each fixture alone in a definitions directory. Both verdicts must match
# the directory the fixture is in:
#
#   valid/                  the Schema accepts it, and so does smock
#   invalid/                the Schema rejects it, and so does smock
#   invalid-beyond-schema/  the Schema accepts it, but smock rejects it for
#                           a reason the Schema cannot see, such as a rule
#                           across the files of a definition set
#
# The validator takes all the fixtures in one run, since a run spends most
# of its time starting Python, and its JSON report names each file that the
# Schema rejects or that it cannot parse. For a fixture that gets the wrong
# verdict from the Schema, it runs once more on that fixture alone, to show
# its own report. When the run over all the fixtures goes wrong, as when
# one of them crashes the validator, no fixture gets a verdict and the check
# fails: such a run does not tell which files it rejected, and taking the
# others as accepted could pass a fixture that the Schema rejects.
#
# Each definitions directory also gets the files under body-files/ as its
# body-file subdirectory (files/, the default), so that fixtures can refer
# to them with bodyFile.
#
# Adding a fixture file is enough to add it to the cross-check.
#
# It exits with 1 when a check fails, or when the validator's run over the
# fixtures goes wrong, and with 2 when it cannot run the validator or is
# run wrongly. A Schema that jq cannot read stops it with jq's exit status.
# scripts/test-check-schema.sh tests it.
#
# usage: scripts/check-schema.sh [smock binary]
#   Without a binary, it builds and uses the native debug build. It runs
#   check-jsonschema with uvx, or with pipx when uvx is not installed.
set -eu
cd "$(dirname "$0")/.."

# .github/workflows/schema-pages.yml reads this line too.
validator_version=0.38.2
schema=schema/v1/definitions.json
fixtures=schema/v1/fixtures
published_at=https://hirunefu.github.io/smock/$schema

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [smock binary]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  smock=$1
else
  moon build --target native cmd/smock >&2
  smock=_build/native/debug/build/smock/smock/cmd/smock/smock.exe
fi

if command -v uvx >/dev/null 2>&1; then
  runner=uvx
elif command -v pipx >/dev/null 2>&1; then
  runner=pipx
else
  echo "check-schema: needs uvx or pipx to run check-jsonschema" >&2
  exit 2
fi

# validator <argument>...: runs check-jsonschema with the arguments.
validator() {
  case $runner in
  uvx) uvx "check-jsonschema@$validator_version" "$@" ;;
  pipx) pipx run --spec "check-jsonschema==$validator_version" check-jsonschema "$@" ;;
  esac
}

failed=0
fail() {
  echo "check-schema: $*" >&2
  failed=1
}

# The Schema itself.
validator --check-metaschema "$schema" >/dev/null || fail "$schema is not a valid JSON Schema"
id=$(jq -r '."$id"' "$schema")
[ "$id" = "$published_at" ] || fail "$schema has \$id $id, not the URL it is published at, $published_at"
# Every member of a "properties" object describes itself, or refers to a
# definition that does.
undescribed=$(jq -r '
  . as $schema
  | paths(objects)
  | select(length >= 2 and .[-2] == "properties") as $path
  | ($schema | getpath($path)) as $field
  | select($field.description == null)
  | select(($field["$ref"] // "" | ltrimstr("#/$defs/")) as $def
      | $schema["$defs"][$def].description == null)
  | $path | map(tostring) | join("/")
' "$schema")
for path in $undescribed; do
  fail "$schema: the field at /$path has no description"
done

# The fixtures.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
categories="valid invalid invalid-beyond-schema"

# From here on, "$@" lists the fixtures, those files in the categories'
# directories whose names end as a fixture's should. The loop over the
# fixtures below reports the other files.
set --
for category in $categories; do
  for fixture in "$fixtures/$category"/*; do
    [ -e "$fixture" ] || continue
    case ${fixture##*/} in
    *.json | *.yaml | *.yml) set -- "$@" "$fixture" ;;
    esac
  done
done

# untrusted <sentence>: stops the check, since the validator's run went
# wrong and none of its verdicts can be trusted, with all that it printed.
untrusted() {
  echo "check-schema: $1, so none of the Schema's verdicts can be trusted; it printed:" >&2
  sed 's/^/    /' "$tmp/validator.err" "$tmp/report.json" >&2
  exit 1
}

# The validator's verdicts, from one run over all the fixtures: the files
# its report names, one a line, are those it rejects, and the others it
# accepts. It exits with status 1 when it rejects any file, and its report
# then lists the errors and the parse_errors. It exits with 0 when it
# rejects none, and its report then has an empty list of errors and no
# parse_errors at all, so a list the report leaves out counts as empty. Any
# other status, a report that is not one JSON object, a list in it that is
# not an array, an entry that names no file, or a report that disagrees
# with the status or names a file it was not given means the run went
# wrong.
: >"$tmp/rejected"
if [ "$#" -gt 0 ]; then
  status=0
  validator --output-format json --schemafile "$schema" "$@" \
    >"$tmp/report.json" 2>"$tmp/validator.err" || status=$?
  case $status in
  0 | 1) ;;
  *) untrusted "check-jsonschema exited with status $status, which is neither 0 nor 1" ;;
  esac
  if ! jq -r -s '
    def list($key): if has($key) then .[$key] else [] end;
    if length == 1 and (.[0] | type == "object"
        and (list("errors") | type) == "array"
        and (list("parse_errors") | type) == "array"
        and all(list("errors")[], list("parse_errors")[];
          type == "object" and (.filename | type) == "string"))
    then .[0] | list("errors")[], list("parse_errors")[] | .filename
    else error("not a report")
    end
  ' "$tmp/report.json" >"$tmp/rejected" 2>/dev/null; then
    untrusted "check-jsonschema exited with status $status, and its report is not one JSON object that names a file for each of its errors and parse_errors"
  fi
  if [ "$status" -eq 1 ] && [ ! -s "$tmp/rejected" ]; then
    untrusted "check-jsonschema exited with status 1, but its report rejects no file"
  fi
  if [ "$status" -eq 0 ] && [ -s "$tmp/rejected" ]; then
    untrusted "check-jsonschema exited with status 0, but its report rejects files"
  fi
  printf '%s\n' "$@" >"$tmp/given"
  unknown=$(grep -vxF -f "$tmp/given" "$tmp/rejected" | head -n 1) || :
  if [ -n "$unknown" ]; then
    untrusted "check-jsonschema's report rejects $unknown, which it was not given"
  fi
fi

count=0
for category in $categories; do
  case $category in
  valid) schema_expects=valid smock_expects=valid ;;
  invalid) schema_expects=invalid smock_expects=invalid ;;
  invalid-beyond-schema) schema_expects=valid smock_expects=invalid ;;
  esac
  for fixture in "$fixtures/$category"/*; do
    [ -e "$fixture" ] || continue
    name=${fixture##*/}
    case $name in
    *.json | *.yaml | *.yml) ;;
    *)
      fail "$fixture: a fixture's name ends in .json, .yaml or .yml"
      continue
      ;;
    esac
    count=$((count + 1))

    if grep -qxF -- "$fixture" "$tmp/rejected"; then
      schema_says=invalid
    else
      schema_says=valid
    fi

    rm -rf "$tmp/definitions"
    mkdir "$tmp/definitions"
    cp "$fixture" "$tmp/definitions/$name"
    cp -R "$fixtures/body-files" "$tmp/definitions/files"
    status=0
    "$smock" check "$tmp/definitions" >"$tmp/smock.out" 2>&1 || status=$?
    case $status in
    0) smock_says=valid ;;
    1) smock_says=invalid ;;
    *)
      fail "$fixture: smock check exited with status $status:"
      sed 's/^/    /' "$tmp/smock.out" >&2
      continue
      ;;
    esac

    echo "$category/$name: the Schema says $schema_says, smock says $smock_says"
    sed 's/^/    /' "$tmp/smock.out"
    if [ "$schema_says" != "$schema_expects" ]; then
      fail "$fixture: the Schema should say $schema_expects:"
      # The validator's own report on this fixture alone, as text.
      validator --schemafile "$schema" "$fixture" >"$tmp/schema.out" 2>&1 || :
      sed 's/^/    /' "$tmp/schema.out" >&2
    fi
    if [ "$smock_says" != "$smock_expects" ]; then
      fail "$fixture: smock should say $smock_expects"
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-schema: the Schema and smock agree on all $count fixtures"

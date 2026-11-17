#!/bin/sh
# Runs yaml-test-suite against smock's YAML parser, in both of its modes
# (yaml-test-suite/README.md): the testee, the package yaml-test-suite,
# which this builds with moon first, reads every case's input as smock reads
# a Definition file and an OpenAPI document, and scripts/yaml-test-suite-verdict.py
# judges its answers in each mode against the mode's list of the cases that
# do not pass, yaml-test-suite/safe.txt and yaml-test-suite/openapi.txt.
#
# Without a directory, it fetches the pinned release of the suite into
# _build/yaml-test-suite first, with scripts/fetch-yaml-test-suite.sh;
# with one, it runs the cases there.
#
# It fails when a case fails or is skipped without being listed so, when a
# listed case passes, which must then come off its list, when a listed case
# is not in the suite, or when the testee answers no case. The verdict of
# each mode lists every listed case with its outcome and reason.
#
# CI runs it on every push (.github/workflows/ci.yml, job yaml-test-suite).
# It needs moon, python3, and what the fetch needs: curl, tar and sha256sum.
#
# usage: scripts/check-yaml-test-suite.sh [<suite directory>]
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [<suite directory>]" >&2
  exit 2
fi
suite=${1:-}
if [ -z "$suite" ]; then
  suite=_build/yaml-test-suite
  scripts/fetch-yaml-test-suite.sh "$suite"
fi

moon build --target native yaml-test-suite
testee=$PWD/_build/native/debug/build/smock/smock/yaml-test-suite/yaml-test-suite.exe

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every case, by its directory in the suite, such as 229Q or 2G84/00. find
# does not follow the links of the release's directories name/ and tags/.
cases=$(cd "$suite" && find . -name in.yaml | sed 's|^\./||; s|/in\.yaml$||' | sort)
if [ -z "$cases" ]; then
  echo "check-yaml-test-suite: $suite holds no case" >&2
  exit 1
fi
# shellcheck disable=SC2086 # one argument for each case; their names have no blanks
"$testee" "$suite" $cases >"$tmp/answers"

failed=0
for mode in safe openapi; do
  python3 scripts/yaml-test-suite-verdict.py "yaml-test-suite/$mode.txt" "$suite" "$tmp/answers" || failed=1
done
exit "$failed"

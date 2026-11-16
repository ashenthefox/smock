#!/bin/sh
# Runs protobuf's conformance suite against smock/protobuf
# (protobuf-conformance/README.md): protobuf's conformance_test_runner
# drives the testee, the package protobuf-conformance, built on
# smock/protobuf, which this builds with moon first. The testee decodes and
# encodes the suite's messages with the committed Descriptor set of them,
# fixtures/protobuf/conformance/conformance.binpb.
#
# Every case of the binary and JSON suite runs, editions cases included,
# with the Recommended cases enforced, and so does the text-format suite,
# whose cases the testee skips. The run fails on a case that fails and is
# not in protobuf-conformance/failure_list.txt, on a listed case that
# passes, and on a listed case that fails with another message. The runner
# then writes what differs from the list into the output directory (default:
# _build/protobuf-conformance), one file a kind, each line ready to add to
# the list or to remove from it, and this names each file.
#
# CI runs it on linux/amd64 (.github/workflows/build-test.yml, job
# protobuf-conformance), with a runner that scripts/build-conformance-runner.sh
# builds and CI caches. It needs moon and the runner, which it takes from
# PATH unless given.
#
# usage: scripts/check-conformance.sh [<runner> [<output directory>]]
set -eu
cd "$(dirname "$0")/.."

runner=${1:-conformance_test_runner}
output=${2:-_build/protobuf-conformance}
if ! command -v "$runner" >/dev/null 2>&1; then
  echo "check-conformance: cannot find the runner $runner; build it with scripts/build-conformance-runner.sh" >&2
  exit 2
fi

moon build --target native --release protobuf-conformance
testee=$PWD/_build/native/release/build/smock/smock/protobuf-conformance/protobuf-conformance.exe
set=$PWD/fixtures/protobuf/conformance/conformance.binpb
list=protobuf-conformance/failure_list.txt

rm -rf "$output"
mkdir -p "$output"
if "$runner" --enforce_recommended --maximum_edition 2023 \
  --failure_list "$list" --output_dir "$output" "$testee" "$set"; then
  exit 0
fi

# What each file the runner writes says, and what to do with it.
echo >&2
for kind in \
  "failing_tests.txt:cases that fail and are not listed; add them to $list, or fix them" \
  "succeeding_tests.txt:listed cases that pass; remove them from $list" \
  "unexpected_failure_messages.txt:listed cases that fail with another message; give them that message in $list" \
  "expected_failure_messages.txt:the lines of $list that those cases had" \
  "unmatched.txt:lines of $list that name no case; remove them" \
  "exceeded_max_matches.txt:lines of $list whose wildcard names more than 20 cases"; do
  file=$output/${kind%%:*}
  if [ -s "$file" ]; then
    echo "check-conformance: $file: $(wc -l <"$file") ${kind#*:}" >&2
  fi
done
exit 1

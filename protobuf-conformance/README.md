# protobuf's conformance suite

protobuf's conformance suite checks smock/protobuf, the codec smock decodes
and encodes gRPC messages with ([protobuf/README.mbt.md](../protobuf/README.mbt.md)),
against protobuf's own: the binary encoding, ProtoJSON and their edge
cases. protobuf's `conformance_test_runner` sends a testee thousands of
messages, each with the form to answer in, and checks each answer. A
regression in the codec fails the run, and so does a fix, until the list
of cases that fail says so.

## What is here

| File | What it is |
|---|---|
| `main.mbt`, `testee.mbt` | The testee, a native program built on smock/protobuf. smock's image does not hold it. |
| `failure_list.txt` | The cases that smock/protobuf fails, by reason, each with the runner's message. |
| `testee_wbtest.mbt` | Tests of the testee's answers, with requests and responses that protoc encodes. |

The testee reads the Descriptor set of the suite's messages,
`fixtures/protobuf/conformance/conformance.binpb`, which the fixture script
builds from protobuf's `.proto` files beside it
([fixtures/protobuf/README.md](../fixtures/protobuf/README.md)). Then it
answers the runner's requests, each a `ConformanceRequest` of protobuf's
`conformance.proto`, on its stdin and stdout, until its stdin ends:

- A message in protobuf's binary encoding is decoded with
  `decode_canonical_json`. It is answered as that JSON, or encoded again
  with `encode_json`.
- A message in JSON is read with `@json.parse`, as smock reads the JSON of
  a gRPC Stub's reply, and encoded with `encode_json`. It is answered in
  that encoding, or decoded again with `decode_canonical_json`.
- A request that gives or asks for JSPB or protobuf's text format, which
  smock does not have, is skipped, and so is a message of a type of an
  editions file, which smock/protobuf does not decode or encode yet.
- smock/protobuf's error is a parse error when it reads the input, the
  input in the binary encoding printed as JSON included, since
  smock/protobuf reads and prints it in one step; and a serialize error
  when it writes the answer after that.

## How it runs

`scripts/check-conformance.sh` builds the testee with moon, then runs the
runner on it. Every case of the binary and JSON suite runs, with the
Recommended cases enforced as the Required ones, and so do its editions
cases and the text-format suite, which the testee skips. The runner fails
the run on a case that fails and is not listed, on a listed case that
passes, and on a listed case that fails with another message.

CI runs it on linux/amd64 (`.github/workflows/build-test.yml`, job
`protobuf-conformance`), on every push and in the weekly run with the latest
MoonBit. protobuf publishes no runner, so `scripts/build-conformance-runner.sh`
builds it from protobuf's release 36.2, the release of the protoc that
builds the fixtures, with the versions of Abseil and JsonCpp that the
release names, each checked against its pinned SHA-256. CI caches the
runner until the script, or the protoc version it checks, changes. The
build takes a few minutes. When the run fails, CI keeps the runner's lists
of what differs from the failure list as the artifact
`protobuf-conformance`.

## Running it locally

The build needs CMake 3.16 or later and a C++17 compiler, and uses Ninja
when it finds it. It takes about 1.5 GB of disk in `$TMPDIR`, and 1.5 GB
of memory or more for each compile job:

```sh
CMAKE_BUILD_PARALLEL_LEVEL=2 scripts/build-conformance-runner.sh
scripts/check-conformance.sh
```

The build installs `conformance_test_runner`, with the JsonCpp library it
loads, into `~/.local/bin`, or into the directory given as its argument.
The check takes the runner from `PATH`, or the path given as its first
argument. The run itself takes a second or two:

```
CONFORMANCE SUITE PASSED: 2769 successes, 2832 skipped, 48 expected failures, 0 unexpected failures.
CONFORMANCE SUITE PASSED: 0 successes, 909 skipped, 0 expected failures, 0 unexpected failures.
```

The first line is the binary and JSON suite, the second the text-format
suite.

## Updating the failure list

When the run fails, the runner writes what differs from the failure list
into `_build/protobuf-conformance/`, or the directory given as the check's
second argument, and the check names each file it wrote. Each line is a
case and the runner's message, `<case> # <message>`, as the list holds it:

- `failing_tests.txt`: cases that fail and are not listed. Fix the codec,
  or add the lines to the list, under the reason they fail for.
- `succeeding_tests.txt`: listed cases that pass. Remove them from the list.
- `unexpected_failure_messages.txt`: listed cases that fail with another
  message. Replace their lines with these.

The runner matches a case's message as a prefix of the one it gives, and
reads `*` in a name as any one part of it, for at most 20 cases. `#` starts
a comment, which the list uses for the reasons. To run one case alone, give
its name to the runner with `--test`, and the flags the check passes;
`--debug` also writes the request into the output directory:

```sh
moon build --target native --release protobuf-conformance
conformance_test_runner --enforce_recommended --maximum_edition 2023 \
  --test Required.Proto3.JsonInput.Uint64FieldMaxValue.JsonOutput --debug \
  --output_dir /tmp/conformance \
  "$PWD/_build/native/release/build/smock/smock/protobuf-conformance/protobuf-conformance.exe" \
  "$PWD/fixtures/protobuf/conformance/conformance.binpb"
```

## Editions

The editions cases are skipped, not listed. smock/protobuf reads editions
files in a set but does not decode or encode their types yet, so it gives
an error for each of their messages. The runner of protobuf 36.2 stops the
whole run when a testee answers its `UnknownOrdering` case with an error,
which it does for each editions type. When smock/protobuf decodes editions
types, the testee stops skipping them, and their cases join the run.

# yaml-test-suite

yaml-test-suite checks smock/yaml, the parser smock reads YAML Definition
files and OpenAPI documents with ([yaml/yaml.mbt](../yaml/yaml.mbt)),
against the [YAML test suite](https://github.com/yaml/yaml-test-suite):
some 400 small YAML inputs, each with what a YAML parser reads from it.
Each case runs in both of the parser's modes: the safe subset, which
Definition files use, and the mode for OpenAPI documents. A regression in
the parser fails the run, and so does a fix, until the list of cases that
do not pass says so.

## What is here

| File | What it is |
|---|---|
| `main.mbt`, `testee.mbt` | The testee, a native program built on smock/yaml. smock's image does not hold it. |
| `safe.txt`, `openapi.txt` | The cases that do not pass in each mode, each with its reason. |
| `testee_wbtest.mbt` | Tests of the testee's answers. |

The testee is a package of its own, outside the yaml module, because
nothing in yaml can read the suite's files: yaml's tests may import
nothing but the standard library (`scripts/check-no-io.sh` reads test
imports too), and wasm-gc has no file access. The repository holds none
of the suite. `scripts/fetch-yaml-test-suite.sh` fetches the pinned
release, `data-2022-01-17`, checks it against its SHA-256 and unpacks it;
NOTICE names the suite and its licence, the MIT License.

The release has a directory for each case, such as `229Q` or `2G84/00`,
with its input, `in.yaml`; the events a YAML parser reads from it,
`test.event`; and the JSON it reads as, `in.json`, or a file `error` where
the input is not YAML. The testee reads each input as smock reads a file
of each kind (`definitions/read.mbt`, `importopenapi/document.mbt`), parses
it in both modes, and prints what it read, or its refusal, one line of
JSON for each case. It skips an input that is not UTF-8, as smock refuses
such a file before parsing it.

## How a case is judged

`scripts/yaml-test-suite-verdict.py` judges the answers of one mode:

- Where the suite marks the input an error, smock must refuse it.
- Where the input has one of the constructs of the table below, which
  the documents say the mode refuses, smock must refuse it with the
  message the documents give for that construct. A refusal for another
  reason fails, so that it cannot pass as "outside the subset".
- Otherwise, where the suite gives JSON, smock must read that JSON: the
  same values, and the members of each object in the same order, as
  `parse`'s documentation says ("The members of a mapping are read in the
  order they are written").
- Otherwise, the suite gives no JSON, and smock must read the input.

The constructs are those that `parse`'s documentation and
[Writing Definition files in YAML](../docs/definition-files.md#writing-definition-files-in-yaml)
name with their messages, the rules that `parse` "also holds to" included
(an empty key, a duplicate key, a number JSON cannot hold), each found from
the suite's events or from the input:

| Construct | Found from | Refused in | The message |
|---|---|---|---|
| An anchor, an alias, a tag | the events | both modes | names it |
| A merge key (`<<`), a duplicate key | the events | both modes | names it |
| Several documents | the events | both modes | names it ("multiple documents") |
| A directive (`%`) | a line that starts with `%` where a document may start | both modes | names it |
| An explicit key (`?`) | a `?` and a blank where a node may start | both modes | names it |
| An empty key | the events | both modes | names it ("empty") |
| An empty value | the events | the safe subset | names it ("empty") |
| An indentation indicator | a block scalar header with a digit | the safe subset | names it |
| A plain value that YAML 1.1 or 1.2 types otherwise | the events | the safe subset | "quote this value" |
| A plain key that YAML 1.1 or 1.2 does not read as a string | the events | the safe subset | "quote this key" |
| A plain value that is a number JSON cannot hold | the events | the mode for OpenAPI documents | "quote this value" |

A message names a construct when it holds the construct's name, as the
table gives it, as whole words, in the singular or the plural: "anchor"
or "anchors" names an anchor, "multiple documents" several documents, and
"empty" an empty value or key, while a longer word that holds the name,
such as "unanchored", names nothing. The maintainer gave this reading of
`parse`'s "each with a message naming it" on 2026-11-17 (#275).

A plain scalar's type comes from the regular expressions of YAML 1.1's
types ([yaml.org/type](https://yaml.org/type/): bool, int, float, null,
timestamp, merge and value) and of the YAML 1.2 core schema (YAML 1.2.2,
section 10.3.2). The safe subset types `true`, `false`, `null` and
numbers in JSON syntax itself, so it refuses a plain value only when it
is none of those.

## The lists

Each line of `safe.txt` and `openapi.txt` names a case, why it is listed,
and the reason:

- `differs`: a known difference, where smock reads the case otherwise on
  purpose, such as a key that is a collection, which no JSON key can be.
  The documents list each one among the valid YAML that smock refuses:
  a file with no document, a key that is a collection, a `key: value`
  pair in a flow sequence without braces, a key of a flow mapping written
  over several lines, and a tab in the white space at the start of a
  line. Each entry quotes and cites the sentence.
- `skipped`: the testee skips the case.
- `#<issue>`: a bug, which fails until the issue is done.

A case with one of the constructs of the table is not listed: it
passes when smock refuses it as the documents say, and fails
otherwise. One exception, which the maintainer allowed on 2026-11-17: a
case that smock refuses first for one of the known differences, before
it reaches the construct, is listed as `differs`, and its reason says
that the case holds the construct too. UT92, a key of a flow mapping over
several lines in a stream of two documents, is such a case. The run fails on a case that fails or is skipped without being
listed so, on a listed case that passes, which must come off the list, and
on a listed case that the suite does not have. Its output lists every
listed case with its outcome and reason.

Unlike h2spec's lists, these may keep entries marked as bugs, each with
its issue, when a branch merges into `main`, until yaml's L4 ticket (#323)
fixes them ([Before merging into main](../docs/merging-into-main.md)).
Each bug has an issue of its own, which its entries name: #365 to #369.

## How it runs

CI runs it on every push, as the job `yaml-test-suite` of
`.github/workflows/ci.yml`, beside the workflow's other jobs; the job that
keeps the release binaries waits for it. The job `scripts` runs the
verdict's own test, `scripts/test-yaml-test-suite-verdict.sh`, on small
made-up suites.

To run it locally, with moon and python3:

```sh
scripts/check-yaml-test-suite.sh
```

It fetches the suite into `_build/yaml-test-suite`, builds the testee,
runs every case, and prints the verdict of each mode. Given a directory
that holds the suite, it runs the cases there instead.

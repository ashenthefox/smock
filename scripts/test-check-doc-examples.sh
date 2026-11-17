#!/bin/sh
# Tests of the check of the documented examples
# (scripts/check-doc-examples.py), which CI runs on the release binary in
# every run. Each test writes a small tree into a temporary directory, user
# documents with fenced blocks and a Mockoon guide with commands, runs the
# check on it with a fake smock, and checks its exit status, what it
# prints, and how it ran smock.
#
# The fake smock judges a Definition file by the words in it, as the JSON
# Schema cross-check's test does, and renders a Stub as a line of JSON made
# of its arguments. The check finds no real smock: it is given the fake by
# its path, on a PATH that holds only the few other commands it and the
# documents' commands run. It needs python3, 3.9 or later, and jq, which
# the guide's commands run.
#
# usage: scripts/test-check-doc-examples.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/tree

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

# The interpreter itself, not a version manager's shim, which may need a
# PATH that the check's runs do not have.
python=$(python3 -c 'import sys; print(sys.executable)') || {
  echo "test-check-doc-examples: needs python3" >&2
  exit 2
}

# The commands that the fake and the documents' commands run, each as a
# script in one directory that runs the command with this script's PATH.
# The check's PATH is then that directory and the fakes', and holds no real
# smock. A script, not a link, since a version manager's shim may look for
# the command on PATH again.
sys=$tmp/sys
mkdir "$sys"
for command in cat cp find grep jq mkdir sed sort tr; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "test-check-doc-examples: needs $command" >&2
    exit 2
  fi
  printf '#!/bin/sh\nPATH=%s exec %s "$@"\n' "'$PATH'" "$command" >"$sys/$command"
  chmod +x "$sys/$command"
done

# A fake smock. Of `smock check <directory>`, it logs the files of the
# directory, one line per run, and rejects a Definition file that holds
# fake-problem, or that holds needs-file: <name> when the body-file
# subdirectory has no file of that name. It warns, on stderr, about one
# that holds fake-warning, and exits with status 3 when one holds
# fake-crash. `smock render --dir <directory> --request <file> [--seed
# <seed>] <stub>` prints {"stub", "seed", "request"}, the request being the
# file's JSON; the stub's name gains ", changed" while $tmp/renders-changed
# exists.
fakes=$tmp/fakes
mkdir "$fakes"
{
  echo '#!/bin/sh'
  echo "log='$tmp/smock.log'"
  echo "changed='$tmp/renders-changed'"
  cat <<'SH'
case $1 in
check)
  [ "$#" -eq 2 ] || exit 64
  (cd "$2" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ') >>"$log"
  echo >>"$log"
  status=0
  for file in "$2"/*.yaml "$2"/*.yml "$2"/*.json; do
    [ -f "$file" ] || continue
    name=${file##*/}
    if grep -q fake-crash "$file"; then
      echo "fake smock: crashed" >&2
      exit 3
    fi
    if grep -q fake-problem "$file"; then
      echo "$name: /stubs/0: a fake problem"
      status=1
    fi
    if grep -q fake-warning "$file"; then
      echo "$name: a fake warning" >&2
    fi
    for needed in $(sed -n 's/.*needs-file: *\([^ ]*\).*/\1/p' "$file"); do
      if [ ! -f "$2/files/$needed" ]; then
        echo "$name: no body file \"$needed\""
        status=1
      fi
    done
  done
  exit "$status"
  ;;
render)
  shift
  dir=
  request=
  seed=
  while [ "$#" -gt 1 ]; do
    case $1 in
    --dir) dir=$2 ;;
    --request) request=$2 ;;
    --seed) seed=$2 ;;
    *) exit 64 ;;
    esac
    shift 2
  done
  if [ ! -d "$dir" ]; then
    echo "fake smock: cannot read $dir" >&2
    exit 1
  fi
  stub=$1
  [ ! -e "$changed" ] || stub="$stub, changed"
  printf '{"stub":"%s","seed":"%s","request":%s}\n' "$stub" "$seed" "$(cat "$request")"
  ;;
*) exit 64 ;;
esac
SH
} >"$fakes/smock"
chmod +x "$fakes/smock"

# file <path>: writes its standard input to <path> in the tree.
file() {
  mkdir -p "$(dirname "$root/$1")"
  cat >"$root/$1"
}

# tree: makes $root anew, with the documents' index, which lists the user
# documents before its section for contributors, a user document whose
# blocks are of every kind, two whole Definition files and blocks that the
# check sets aside, and the Mockoon guide.
tree() {
  rm -rf "$root"
  mkdir -p "$root"
  guide
  file docs/README.md <<'MD'
# Documentation

The [README](../README.md) says what smock is.

## Using smock

- [a.md](a.md) shows examples.

## Contributing to smock

- [c.md](c.md) is for contributors.
MD
  file README.md <<'MD'
# smock
MD
  file docs/a.md <<'MD'
# Examples

A whole Definition file:

```yaml
mocks:
  - name: shop
stubs:
  - id: hello
    mock: shop
```

A Stub, which is not a whole file:

```yaml
- id: hello
  mock: shop
```

A whole file in JSON:

```json
{"mocks": [{"name": "shop"}]}
```

A command:

```sh
smock check defs
```
MD
  file docs/c.md <<'MD'
# For contributors

```yaml
mocks: [] # fake-problem, but not in a user document
```
MD
}

# guide: writes the Mockoon guide, with a block that checks the example's
# definitions directory and prints nothing, a block that renders a Stub
# and prints what jq makes of it, after a comment that says what it does,
# blocks that run other commands, one of which names smock check in a
# comment, and a console block, which shows a prompt; and the example's
# directory.
guide() {
  file docs/migrating-from-mockoon.md <<'MD'
# Migrating from Mockoon

## Checking the migration

```sh
smock check defs   # prints nothing and exits with 0 for the example
```

```sh
# Render the Stub of one route.
echo '{"path":"/users/42"}' >sample.json
smock render --dir defs --request sample.json --seed 7 get-user |
  jq -c '[.stub, .seed, .request.path]'
# ["get-user","7","/users/42"]
```

Then send both servers the same requests:

```sh
curl -s localhost:3000/users
```
MD
  file docs/mockoon/worked-example.md <<'MD'
# A worked example

```sh
# smock check defs would check the directory first.
smock serve --dir defs/shop-api --port 3000 &
```

```console
$ smock check defs
defs/users-api.yaml: a warning
```
MD
  file docs/examples/from-mockoon/defs/users-api.yaml <<'YAML'
mocks: [{ name: users-api }]
YAML
}

# check <name>: runs the check on the tree with the fake smock, its output
# into $tmp/<name>.out, its exit status into $tmp/<name>.status, and the
# log of smock's runs into $tmp/<name>.smock.
check() {
  : >"$tmp/smock.log"
  status=0
  PATH="$sys" "$python" scripts/check-doc-examples.py "$fakes/smock" "$root" \
    >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
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

# ran <name> <line>...: the check <name> ran smock check on directories
# that held these files, one line per run, and no more.
ran() {
  name=$1
  shift
  if [ "$#" -eq 0 ]; then
    : >"$tmp/expected"
  else
    printf '%s \n' "$@" >"$tmp/expected"
  fi
  if cmp -s "$tmp/expected" "$tmp/$name.smock"; then
    pass "$name: runs smock $# times as it should"
  else
    fail "$name: runs smock otherwise:"
    diff "$tmp/expected" "$tmp/$name.smock" | sed 's/^/     /'
  fi
}

# --- Whole Definition files ----------------------------------------------------

# Each whole Definition file of a user document passes smock check, alone
# in a definitions directory; the other blocks are set aside, and so is a
# contributor's document.
tree
check good
exits good 0
says good "docs/a.md:5 (example 1): passes smock check"
says good "docs/a.md:22 (example 2): passes smock check"
says good "check-doc-examples: found 2 whole Definition files, and set aside 2 other fenced blocks as fragments"
says good "check-doc-examples: every example passes"
never good "c.md"
ran good example.yaml example.json users-api.yaml

# A whole Definition file that smock check rejects fails the check, which
# names the block and shows what smock printed.
tree
sed -i 's/  - id: hello$/  - id: hello # fake-problem/' "$root/docs/a.md"
check broken
exits broken 1
says broken "docs/a.md:5 (example 1): smock check exits with 1:"
says broken "    example.yaml: /stubs/0: a fake problem"
says broken "docs/a.md:22 (example 2): passes smock check"
says broken "check-doc-examples: found 2 whole Definition files, and set aside 2 other fenced blocks as fragments"
says broken "check-doc-examples: 1 problem"

# --- The rule that tells a whole file from a fragment -----------------------------

# A user document is one the index links to before its section for
# contributors, also by a link with a fragment. A block is a whole file by
# its language and its top-level keys, wherever its fence is: in a list
# item, of tildes, or longer than a fence inside it. Its comments and
# document markers are no keys; a key that is no field of a Definition
# file, a line that is no key, and a language that is neither YAML nor
# JSON make it a fragment, and so does a JSON object whose members are no
# fields, though deeper members are.
tree
sed -i 's|^- \[a.md\](a.md) shows examples.$|&\n\n## Operating smock\n\n- [b.md](b.md#rules) and [examples/](examples/) show more.|' \
  "$root/docs/README.md"
file docs/b.md <<'MD'
# Rules

- In a list item:

  ```yaml
  # a comment
  version: 1
  mocks:
    - name: a
  ```

~~~
---
stubs: []
...
~~~

```yml
"data":
  - { mock: shop, name: orders, json: [] }
```

````yaml
stubs:
  - id: x
  ```
````

```json
{"stubs": [{"id": "x{[", "data": 1}], "version": 1}
```

```yaml
mocks: []
request: { path: / }
```

```yaml
stubs:
…
```

```json
{"method": "GET", "data": {"stubs": []}}
```

```text
data: {"stubs": []}
```

```yaml
# only a comment
```
MD
check rule
exits rule 0
says rule "docs/b.md:5 (example 1): passes smock check"
says rule "docs/b.md:12 (example 2): passes smock check"
says rule "docs/b.md:18 (example 3): passes smock check"
says rule "docs/b.md:23 (example 4): passes smock check"
says rule "docs/b.md:29 (example 5): passes smock check"
says rule "check-doc-examples: found 7 whole Definition files, and set aside 7 other fenced blocks as fragments"
ran rule example.yaml example.json example.yaml example.yaml example.yaml example.yaml example.json users-api.yaml

# A document that the index links to and that cannot be read stops the
# check.
tree
sed -i 's|^- \[a.md\](a.md) shows examples.$|&\n- [gone.md](gone.md) is gone.|' "$root/docs/README.md"
check unreadable
exits unreadable 2
says unreadable "check-doc-examples: cannot read docs/gone.md: No such file or directory"

# A warning that smock check prints is shown under the example, which
# passes. Another exit status than 0 or 1 fails it.
tree
sed -i 's/  - id: hello$/  - id: hello # fake-warning/' "$root/docs/a.md"
sed -i 's/{"mocks": \[{"name": "shop"}\]}/{"mocks": [{"name": "shop fake-crash"}]}/' "$root/docs/a.md"
check warning-and-crash
exits warning-and-crash 1
says warning-and-crash "docs/a.md:5 (example 1): passes smock check"
says warning-and-crash "    example.yaml: a fake warning"
says warning-and-crash "docs/a.md:22 (example 2): smock check exits with 3:"
says warning-and-crash "    fake smock: crashed"
says warning-and-crash "check-doc-examples: 1 problem"

# --- The context an example leaves out ------------------------------------------

# Each line of scripts/doc-examples/context.txt gives one example of a
# document, by its number among the document's whole Definition files, one
# file of its definitions directory, copied from a file of the tree.
tree
sed -i 's/  - id: hello$/  - id: hello # needs-file: orders.json/' "$root/docs/a.md"
file scripts/doc-examples/empty.json <<'JSON'
[]
JSON
file scripts/doc-examples/shop.yaml <<'YAML'
mocks: [{ name: shop }]
YAML
file scripts/doc-examples/context.txt <<'TXT'
# The context of the examples.

docs/a.md 1 files/orders.json scripts/doc-examples/empty.json
docs/a.md  1  context.yaml  scripts/doc-examples/shop.yaml
TXT
check context
exits context 0
says context "docs/a.md:5 (example 1): passes smock check, with its context: files/orders.json, context.yaml"
says context "docs/a.md:22 (example 2): passes smock check"
ran context "context.yaml example.yaml files/orders.json" example.json users-api.yaml

# Without its context, the example fails, as smock check says.
rm "$root/scripts/doc-examples/context.txt"
check no-context
exits no-context 1
says no-context "docs/a.md:5 (example 1): smock check exits with 1:"
says no-context '    example.yaml: no body file "orders.json"'
says no-context "check-doc-examples: 1 problem"

# A line that serves no example, gives a path outside the definitions
# directory or the example's own file, takes a file the tree does not
# hold, gives a path twice, or is not written as a line should be is a
# problem, and gives the example nothing.
tree
file scripts/doc-examples/empty.json <<'JSON'
[]
JSON
touch "$tmp/outside.json"
file scripts/doc-examples/context.txt <<'TXT'
docs/a.md 3 files/x.json scripts/doc-examples/empty.json
docs/c.md 1 files/x.json scripts/doc-examples/empty.json
docs/a.md 1 files/x.json scripts/doc-examples/missing.json
docs/a.md 1 ../x.json scripts/doc-examples/empty.json
docs/a.md 1 example.yaml scripts/doc-examples/empty.json
docs/a.md x files/x.json scripts/doc-examples/empty.json
docs/a.md 1 files/x.json
docs/a.md 2 files/y.json scripts/doc-examples/empty.json
docs/a.md 2 files/y.json scripts/doc-examples/empty.json
docs/a.md 2 files/z.json ../outside.json
docs/a.md 0 files/x.json scripts/doc-examples/empty.json
docs/a.md 1 /x.json scripts/doc-examples/empty.json
docs/a.md 1 files/x.json /etc/hostname
TXT
check context-problems
exits context-problems 1
context=scripts/doc-examples/context.txt
says context-problems "$context:1: docs/a.md has no example 3: it has 2 whole Definition files"
says context-problems "$context:2: docs/c.md is not a user document"
says context-problems "$context:3: scripts/doc-examples/missing.json is not a file of the tree"
says context-problems "$context:4: ../x.json is not a path inside the definitions directory"
says context-problems "$context:5: example.yaml is the example's own file"
says context-problems "$context:6: a line gives <document> <example> <path> <source>, the example a number from 1"
says context-problems "$context:7: a line gives <document> <example> <path> <source>, the example a number from 1"
says context-problems "$context:9: example 2 of docs/a.md gets files/y.json twice"
says context-problems "$context:10: ../outside.json is not a file of the tree"
says context-problems "$context:11: a line gives <document> <example> <path> <source>, the example a number from 1"
says context-problems "$context:12: /x.json is not a path inside the definitions directory"
says context-problems "$context:13: /etc/hostname is not a file of the tree"
says context-problems "docs/a.md:5 (example 1): passes smock check"
says context-problems "docs/a.md:22 (example 2): passes smock check, with its context: files/y.json"
says context-problems "check-doc-examples: 12 problems"
ran context-problems example.yaml "example.json files/y.json" users-api.yaml

# --- The Mockoon guide ------------------------------------------------------------

# The guide's blocks that run smock check or smock render run as the guide
# writes them, one after another, in a copy of the example's directory,
# with the smock the check is given. Each prints what the comments after
# its first command show: nothing, for the first.
tree
check mockoon
exits mockoon 0
says mockoon "docs/migrating-from-mockoon.md:5: prints what the guide shows"
says mockoon "docs/migrating-from-mockoon.md:9: prints what the guide shows"
says mockoon "check-doc-examples: found 2 blocks of the Mockoon guide that run smock check or smock render"
never mockoon "docs/migrating-from-mockoon.md:19"
never mockoon "worked-example.md"
if [ -e "$root/docs/examples/from-mockoon/sample.json" ]; then
  fail "mockoon: writes into the tree"
else
  pass "mockoon: writes nothing into the tree"
fi

# Output that differs from what the guide shows fails the check, with a
# diff of the two, whether the guide or smock changed.
tree
sed -i 's|^# \["get-user","7","/users/42"\]$|# ["get-user","8","/users/42"]|' "$root/docs/migrating-from-mockoon.md"
check guide-differs
exits guide-differs 1
says guide-differs "docs/migrating-from-mockoon.md:9: prints otherwise than the guide shows:"
says guide-differs '    -["get-user","8","/users/42"]'
says guide-differs '    +["get-user","7","/users/42"]'
says guide-differs "check-doc-examples: 1 problem"

tree
touch "$tmp/renders-changed"
check render-differs
rm "$tmp/renders-changed"
exits render-differs 1
says render-differs "docs/migrating-from-mockoon.md:9: prints otherwise than the guide shows:"
says render-differs '    -["get-user","7","/users/42"]'
says render-differs '    +["get-user, changed","7","/users/42"]'

# A block whose command fails fails the check, with what it printed.
tree
echo "# fake-problem" >>"$root/docs/examples/from-mockoon/defs/users-api.yaml"
check guide-fails
exits guide-fails 1
says guide-fails "docs/migrating-from-mockoon.md:5: exits with 1:"
says guide-fails "    users-api.yaml: /stubs/0: a fake problem"
says guide-fails "docs/migrating-from-mockoon.md:9: prints what the guide shows"

# A block stops at the first command that fails.
tree
sed -i 's|^echo .{"path":"/users/42"}. >sample.json$|smock render --dir nowhere --request sample.json get-user\n&|' \
  "$root/docs/migrating-from-mockoon.md"
check guide-stops
exits guide-stops 1
says guide-stops "docs/migrating-from-mockoon.md:9: exits with 1:"
says guide-stops "    fake smock: cannot read nowhere"
never guide-stops "/users/42"

# A guide that shows none of these commands fails the check.
tree
sed -i 's/smock check defs/smock serve --dir defs/; s/smock render/smock serve/' "$root/docs/migrating-from-mockoon.md"
check no-commands
exits no-commands 1
says no-commands "check-doc-examples: the Mockoon guide, docs/migrating-from-mockoon.md and docs/mockoon/*.md, runs smock check or smock render in no block"

# --- How the check is run ---------------------------------------------------------

tree
status=0
PATH="$sys" "$python" scripts/check-doc-examples.py "$fakes/smock" "$root" extra \
  >"$tmp/usage.out" 2>&1 || status=$?
echo "$status" >"$tmp/usage.status"
exits usage 2
says usage "usage: python3 scripts/check-doc-examples.py <smock> [<tree>]"

status=0
PATH="$sys" "$python" scripts/check-doc-examples.py "$tmp/no-smock" "$root" \
  >"$tmp/no-smock.out" 2>&1 || status=$?
echo "$status" >"$tmp/no-smock.status"
exits no-smock 2
says no-smock "check-doc-examples: cannot run $tmp/no-smock"

echo
echo "test-check-doc-examples: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

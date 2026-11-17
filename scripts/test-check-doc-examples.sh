#!/bin/sh
# Tests of the check of the documented examples
# (scripts/check-doc-examples.py), which CI runs on the release binary in
# every run. Each test writes a small tree into a temporary directory, user
# documents with fenced blocks, runs the check on it with a fake smock, and
# checks its exit status, what it prints, and how it ran smock.
#
# The fake smock judges a Definition file by the words in it, as the JSON
# Schema cross-check's test does. The check finds no real smock: it runs
# the fake by its path, on a PATH that holds only the fake and the few
# other commands it and the documents' commands run. It needs python3, 3.9
# or later, and nothing else the check does not need.
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
for command in cat cp find grep mkdir sed sort tr; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "test-check-doc-examples: needs $command" >&2
    exit 2
  fi
  printf '#!/bin/sh\nPATH=%s exec %s "$@"\n' "'$PATH'" "$command" >"$sys/$command"
  chmod +x "$sys/$command"
done

# A fake smock, of which the check runs `smock check <directory>`. It logs
# the files of the directory, one line per run, and rejects a Definition
# file that holds fake-problem, or that holds needs-file: <name> when the
# body-file subdirectory has no file of that name. It warns, on stderr,
# about one that holds fake-warning, and exits with status 3 when one
# holds fake-crash.
fakes=$tmp/fakes
mkdir "$fakes"
{
  echo '#!/bin/sh'
  echo "log='$tmp/smock.log'"
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
# documents before its section for contributors, and a user document whose
# blocks are of every kind: two whole Definition files, and blocks that the
# check sets aside.
tree() {
  rm -rf "$root"
  mkdir -p "$root"
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

# check <name>: runs the check on the tree with the fake smock, its output
# into $tmp/<name>.out, its exit status into $tmp/<name>.status, and the
# log of smock's runs into $tmp/<name>.smock.
check() {
  : >"$tmp/smock.log"
  status=0
  PATH="$fakes:$sys" "$python" scripts/check-doc-examples.py "$fakes/smock" "$root" \
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
says good "docs/a.md:5: passes smock check"
says good "docs/a.md:22: passes smock check"
says good "check-doc-examples: 2 whole Definition files pass smock check; 2 other fenced blocks set aside as fragments"
never good "c.md"
ran good example.yaml example.json

# A whole Definition file that smock check rejects fails the check, which
# names the block and shows what smock printed.
tree
sed -i 's/  - id: hello$/  - id: hello # fake-problem/' "$root/docs/a.md"
check broken
exits broken 1
says broken "docs/a.md:5: smock check exits with 1:"
says broken "    example.yaml: /stubs/0: a fake problem"
says broken "docs/a.md:22: passes smock check"
says broken "check-doc-examples: 2 whole Definition files, 1 of which fails smock check; 2 other fenced blocks set aside as fragments"

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
says rule "docs/b.md:5: passes smock check"
says rule "docs/b.md:12: passes smock check"
says rule "docs/b.md:18: passes smock check"
says rule "docs/b.md:23: passes smock check"
says rule "docs/b.md:29: passes smock check"
says rule "check-doc-examples: 7 whole Definition files pass smock check; 7 other fenced blocks set aside as fragments"
ran rule example.yaml example.json example.yaml example.yaml example.yaml example.yaml example.json

# A document that the index links to and that cannot be read stops the
# check.
tree
sed -i 's|^- \[a.md\](a.md) shows examples.$|&\n- [gone.md](gone.md) is gone.|' "$root/docs/README.md"
check unreadable
exits unreadable 2
says unreadable "check-doc-examples: cannot read docs/gone.md: No such file or directory"

echo
echo "test-check-doc-examples: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

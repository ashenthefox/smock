#!/bin/sh
# Tests of the check of the documents' links (scripts/check-doc-links.py),
# which CI runs on every push. Each test writes a few files into a new git
# repository in a temporary directory, since the check asks git for the
# files, runs the check on that tree, and checks its exit status and what
# it prints: each broken link, and the count, which says that it reported
# no other link.
#
# It needs what the check needs: python3 and git.
#
# usage: scripts/test-check-doc-links.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo

# git looks for a repository no higher than the temporary directory, should
# that be in a checkout.
export GIT_CEILING_DIRECTORIES="$tmp"

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

# tree: makes $repo anew, a git repository with no file.
tree() {
  rm -rf "$repo"
  git init --quiet "$repo"
}

# file <path>: writes its standard input to <path> in the tree. git does
# not track the file, and does not ignore it, unless the test says so.
file() {
  mkdir -p "$(dirname "$repo/$1")"
  cat >"$repo/$1"
}

# check <name> [directory]: runs the check on the tree, or on <directory>,
# its output into $tmp/<name>.out and its exit status into
# $tmp/<name>.status.
check() {
  status=0
  python3 scripts/check-doc-links.py "${2:-$repo}" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
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

# mentions <name> <text>: the check <name> printed <text> in some line.
mentions() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: mentions $2"
  else
    fail "$1: does not mention $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# --- Links that lead somewhere -----------------------------------------------

# Paths from the file's directory and from the root, to files, to a
# directory and to an image, with and without a fragment. git tracks one of
# the files, and would track the others. The links that lead elsewhere are
# not counted.
tree
file README.md <<'MARKDOWN'
# Example

Read [the guide](docs/guide.md), [its limits](docs/guide.md#limits) and
[the other documents](docs/). [The licence](#licence) is below, and
[line 3 of the script](scripts/run.sh#L3) is not Markdown.

![The parts](docs/parts.svg)

Elsewhere: [a site](https://example.com/missing.md#nowhere),
<https://example.com/missing.md> and [a file by FTP](ftp://example.com/missing.md).

## Licence

[limits]: docs/guide.md#limits
MARKDOWN
file docs/guide.md <<'MARKDOWN'
# The guide

Back to [the example](../README.md#licence), or from the root to
[this guide](/docs/guide.md#the-guide) and to [the root](/).

## Limits
MARKDOWN
file docs/parts.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg"/>
SVG
file scripts/run.sh <<'SH'
#!/bin/sh
SH
git -C "$repo" add README.md
check good
exits good 0
says good "check-doc-links: 10 links into the repository in 2 Markdown files, none broken"

# --- Files -------------------------------------------------------------------

# A link names a file from the directory of the file that holds it. A file
# that git ignores is not in the repository, and its own links are not
# checked. Nor is a file there that git tracks and the tree has lost.
tree
file .gitignore <<'GITIGNORE'
dist/
GITIGNORE
file README.md <<'MARKDOWN'
# Example

[A file that is not there](missing.md), also with
[a fragment](docs/missing.md#limits).

![An image that is not there](docs/missing.svg)

[A file that git ignores](dist/notes.md) and [one that was
deleted](docs/deleted.md).

[Above the root](../outside.md).

[label]: docs/missing-definition.md
MARKDOWN
file docs/guide.md <<'MARKDOWN'
# The guide

[From the root, not from here](README.md), but [from here](guide.md).
MARKDOWN
file dist/notes.md <<'MARKDOWN'
[A broken link in a file that git ignores](missing.md)
MARKDOWN
file docs/deleted.md <<'MARKDOWN'
# Deleted
MARKDOWN
git -C "$repo" add docs/deleted.md
rm "$repo/docs/deleted.md"
check files
exits files 1
says files "README.md:3: missing.md: no such file"
says files "README.md:4: docs/missing.md#limits: no such file"
says files "README.md:6: docs/missing.svg: no such file"
says files "README.md:8: dist/notes.md: no such file in the repository: git ignores the one here"
says files "README.md:9: docs/deleted.md: no such file"
says files "README.md:11: ../outside.md: leads out of the repository"
says files "README.md:13: docs/missing-definition.md: no such file"
says files "docs/guide.md:3: README.md: no such file"
says files "check-doc-links: 9 links into the repository in 2 Markdown files, 8 broken"

# --- Anchors -----------------------------------------------------------------

# A heading's anchor is its text in lower case, without punctuation, with a
# hyphen for each space. A code span gives its text as written, and a link
# its text. The second heading of a text gets -1. A fragment is compared
# as written. A directory's fragment is looked for in its README.md.
tree
file README.md <<'MARKDOWN'
# Example

- [Startup](docs/guide.md#startup-ports-and-protocols)
- [The flag](docs/guide.md#smock-check-and-its---format-name-flag)
- [Limits](docs/guide.md#the-limits--timeouts)
- [What is new](docs/guide.md#whats-new-in-12)
- [Closed](docs/guide.md#closed)
- [The first notes](docs/guide.md#notes)
- [The second notes](docs/guide.md#notes-1)
- [The third notes](docs/guide.md#notes-2)
- [Upper case](docs/guide.md#Notes)
- [No such heading](docs/guide.md#nope)
- [No such heading here](#nope)
- [The documents](docs#the-documents)
- [No such heading in a directory's README](docs#nope)
- [A directory with no README](docs/more#nope)
MARKDOWN
file docs/README.md <<'MARKDOWN'
# The documents
MARKDOWN
file docs/more/notes.md <<'MARKDOWN'
# More notes
MARKDOWN
file docs/guide.md <<'MARKDOWN'
# The guide

## Startup, ports and protocols

## `smock check` and its `--format <name>` flag

## [The `limits`](https://example.com/limits) & timeouts

## What's new in 1.2?

## Closed ##

## Notes

### Notes
MARKDOWN
check anchors
exits anchors 1
says anchors "README.md:10: docs/guide.md#notes-2: no heading with that anchor"
says anchors "README.md:11: docs/guide.md#Notes: no heading with that anchor"
says anchors "README.md:12: docs/guide.md#nope: no heading with that anchor"
says anchors "README.md:13: #nope: no heading with that anchor"
says anchors "README.md:15: docs#nope: no heading with that anchor"
says anchors "README.md:16: docs/more#nope: no heading with that anchor"
says anchors "check-doc-links: 14 links into the repository in 4 Markdown files, 6 broken"

# The id or the name of an <a> element is an anchor too, as where a
# heading got another name and the links to the old one should hold.
tree
file README.md <<'MARKDOWN'
# Example

<a id="old-name"></a><a name="older-name"></a>
## New name

[By its id](#old-name), [by its name](#older-name), [by the
heading](#new-name) and [by neither](#oldest-name).
MARKDOWN
check anchor-elements
exits anchor-elements 1
says anchor-elements "README.md:7: #oldest-name: no heading with that anchor"
says anchor-elements "check-doc-links: 4 links into the repository in 1 Markdown file, 1 broken"

# --- Code --------------------------------------------------------------------

# Fenced code and code spans show links, headings and <a> elements, and
# hold none. A fence closes with one of its kind that is as long, alone on
# its line; a fence in a list item is indented. Three backticks before a
# code span open no fence, and a backtick opens no span over a blank line.
# The lines after the code keep their numbers.
tree
file README.md <<'MARKDOWN'
# Example

```sh
# Not a heading
echo "[in fenced code](missing-in-fence.md)"
```sh
echo "[after a fence with a word, which closes nothing](missing-in-fence-still.md)"
```

~~~~markdown
```
[after backticks in a fence of tildes](missing-in-tildes.md)
~~~
[after three tildes in a fence of four](missing-in-four-tildes.md)
~~~~

1. A step:

    ```
    echo "a fence in a list item"

    [in a list item's fence](missing-in-list.md)
    ```

Write a link as `[text](missing-in-span.md)`, an anchor as
`<a id="not-an-anchor"></a>`, and a span over two lines as ``[text](missing-in-
long-span.md)``.

```[A span of three backticks](missing-in-backticks.md)``` opens no fence, so
[the link after it](missing-after-span.md) is read, and [the comment](#not-a-heading)
and [the element](#not-an-anchor) are no anchors.

A lone ` backtick opens no span

[over a blank line](missing-after-backtick.md)

up to the next ` one.
MARKDOWN
check code
exits code 1
says code "README.md:30: missing-after-span.md: no such file"
says code "README.md:30: #not-a-heading: no heading with that anchor"
says code "README.md:31: #not-an-anchor: no heading with that anchor"
says code "README.md:35: missing-after-backtick.md: no such file"
says code "check-doc-links: 4 links into the repository in 1 Markdown file, 4 broken"

# --- How a link is written ---------------------------------------------------

# A link's text may wrap over lines, but not cross a blank line, and may
# hold brackets. The target may hold parentheses and escaped characters and
# stand between < and >, and a title may follow it. An escaped bracket
# opens no link, and neither a footnote nor a line with more words is a
# link's definition. A broken link is reported on the line of its target.
tree
file README.md <<'MARKDOWN'
# Example

Read [the guide, whose name
wraps](docs/guide.md), and [the guide that
is not there](docs/missing-wrapped.md).

[No link, since a blank line

parts it](docs/missing-paragraph.md)

[The [bracketed] guide](docs/missing-brackets.md),
[the guide (old)](docs/guide_(old).md) and [(new)](docs/guide_(new).md),
[with a title](docs/missing-title.md "The guide"),
[between angle brackets](<docs/missing-angles.md>) and
[with escaped characters](docs/the%20guide.md#caf%C3%A9).

\[No link, since the bracket is escaped\](docs/missing-escaped.md)

- [ ] [In a task list](docs/missing-task.md)

[^note]: Footnote.

[Note]: a line that defines no link, since words follow its first.
MARKDOWN
file docs/guide.md <<'MARKDOWN'
# The guide
MARKDOWN
file 'docs/guide_(old).md' <<'MARKDOWN'
# The old guide
MARKDOWN
# The heading is Caf and an e with an acute accent, in UTF-8.
printf '# Caf\303\251\n' | file 'docs/the guide.md'
check written
exits written 1
says written "README.md:5: docs/missing-wrapped.md: no such file"
says written "README.md:11: docs/missing-brackets.md: no such file"
says written "README.md:12: docs/guide_(new).md: no such file"
says written "README.md:13: docs/missing-title.md: no such file"
says written "README.md:14: docs/missing-angles.md: no such file"
says written "README.md:19: docs/missing-task.md: no such file"
says written "check-doc-links: 9 links into the repository in 4 Markdown files, 6 broken"

# --- URLs of the repository --------------------------------------------------

# A URL of the main branch is checked as its path from the root, and one of
# the repository as the root, whose README.md holds its anchors. Other
# URLs are not checked: a tag, an issue, a URL with a query, another
# repository, another site.
tree
file README.md <<'MARKDOWN'
# Example

## Licence
MARKDOWN
file docs/guide.md <<'MARKDOWN'
# The guide

## Limits
MARKDOWN
file charts/example/README.md <<'MARKDOWN'
# The chart

Installs [the example](https://github.com/hirunefu/smock), under
[its licence](https://github.com/hirunefu/smock#licence), not
[its warranty](https://github.com/hirunefu/smock#warranty).

- [The guide](https://github.com/hirunefu/smock/blob/main/docs/guide.md)
- [Its limits](https://github.com/hirunefu/smock/blob/main/docs/guide.md#limits)
- [Its timeouts](https://github.com/hirunefu/smock/blob/main/docs/guide.md#timeouts)
- [Another guide](https://github.com/hirunefu/smock/blob/main/docs/missing.md#limits)
- [The documents](https://github.com/hirunefu/smock/tree/main/docs)
- [Other documents](https://github.com/hirunefu/smock/tree/main/missing)
- <https://github.com/hirunefu/smock/blob/main/docs/missing-url.md>

Not checked:
[a tag](https://github.com/hirunefu/smock/blob/v1.2.0/docs/missing.md),
[an issue](https://github.com/hirunefu/smock/issues/1),
[the source](https://github.com/hirunefu/smock/blob/main/docs/guide.md?plain=1#L3),
[another repository](https://github.com/hirunefu/smock-other/blob/main/missing.md),
[another site](https://example.com/hirunefu/smock/blob/main/missing.md).
MARKDOWN
check urls
exits urls 1
says urls "charts/example/README.md:5: https://github.com/hirunefu/smock#warranty: no heading with that anchor"
says urls "charts/example/README.md:9: https://github.com/hirunefu/smock/blob/main/docs/guide.md#timeouts: no heading with that anchor"
says urls "charts/example/README.md:10: https://github.com/hirunefu/smock/blob/main/docs/missing.md#limits: no such file"
says urls "charts/example/README.md:12: https://github.com/hirunefu/smock/tree/main/missing: no such file"
says urls "charts/example/README.md:13: https://github.com/hirunefu/smock/blob/main/docs/missing-url.md: no such file"
says urls "check-doc-links: 10 links into the repository in 3 Markdown files, 5 broken"

# --- Nothing to check --------------------------------------------------------

# A tree with no Markdown file fails, since nothing was checked.
tree
file notes.txt <<'TEXT'
[A link in a file that is not Markdown](missing.md)
TEXT
check no-document
exits no-document 1
says no-document "check-doc-links: $repo holds no Markdown file"

# A directory that is no git repository cannot be checked.
mkdir "$tmp/plain"
check no-repository "$tmp/plain"
exits no-repository 2
mentions no-repository "check-doc-links: git cannot list the files of $tmp/plain:"

echo
echo "test-check-doc-links: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

#!/usr/bin/env python3
"""Checks the links that lead from the repository's documents into the
repository: each must name a file that is there and, with a fragment, an
anchor of that file. It reads every Markdown file (*.md) that git tracks,
and every untracked one that git does not ignore. It never uses the
network.

usage: python3 scripts/check-doc-links.py [<repository>]

<repository> is the checkout to check: this one, unless it is given.

A link is [text](target), an image ![text](target), a link definition
"[label]: target", or <URL>. Its text may wrap over lines. A link in fenced
code or in a code span is an example, and is not read. A target leads into
the repository when it is

  <path>[#<fragment>]
      a path from the directory of the file that holds the link, or from
      the repository's root when it starts with /;
  #<fragment>
      the file that holds the link;
  https://github.com/hirunefu/smock/blob/main/<path>[#<fragment>]
  https://github.com/hirunefu/smock/tree/main/<path>[#<fragment>]
      <path> from the root: the checkout stands for the main branch.
      charts/smock/README.md is packed into the chart, away from the other
      documents, so its links to them are such URLs;
  https://github.com/hirunefu/smock[#<fragment>]
      the root.

<path> must be a file that git tracks or would track, or a directory that
holds one: a link to a file that git ignores is broken, though the file is
there. <fragment> is checked when the link leads to a Markdown file, or to
a directory, where it is looked for in the directory's README.md, which
GitHub shows there. It must be, letter for letter,

  - the anchor that GitHub gives one of the file's headings: the heading's
    text in lower case, without its punctuation, with a hyphen for each
    space, and with -1, -2 and so on after it for the second, the third
    and each later heading of the same text; or
  - the id or the name of an <a> element in the file.

What it does not check:

  - a link that leads elsewhere: to another site, or to another URL of the
    repository, such as an issue, a release, or a file at a tag or on
    another branch;
  - a fragment on a file that is not Markdown, such as a line of a script
    (#L10);
  - a link written as HTML (<a href>), a URL written bare in the text, and
    a [text][label] whose label has no definition.

It reads Markdown by its lines, not as a parser does. It knows the headings
written with #, not those underlined with = or -, so a link to one of
those is reported. It reads an indented code block and an HTML comment as
text, so a link in one is checked.

It prints each broken link as <file>:<line>: <target>: <what is wrong>,
with the line that the target is on, and then a count. It exits with 1 when
a link is broken or the checkout holds no Markdown file, and with 2 when
git cannot list the files or a file cannot be read.

CI runs it on every push (ci.yml). scripts/test-check-doc-links.sh tests
it. It needs git.
"""

import bisect
import os
import posixpath
import re
import subprocess
import sys
import unicodedata
from urllib.parse import unquote

REPOSITORY = "https://github.com/hirunefu/smock"

# A URL of the repository that is checked: a path on the main branch, or
# the repository itself. One with a query is not among them.
INTO_REPOSITORY = re.compile(
    re.escape(REPOSITORY) + r"(?:/(?:blob|tree)/main(?:/(?P<path>[^?#]*))?|/?)(?:#(?P<fragment>.*))?$"
)

# A target with a scheme or a host: a link that leads elsewhere.
ELSEWHERE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:|//")

# A line that may open or close fenced code: the fence, and what follows
# it. A fence in a list item is indented with the item, so any indentation
# counts.
FENCE = re.compile(r"[ \t]*(`{3,}|~{3,})(.*)")

# A code span: as many backticks after its text as before it, and no blank
# line between them.
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(?:(?!\n[ \t]*\n).)+?(?<!`)\1(?!`)", re.DOTALL)

# A heading written with #, and its text. Hashes may close it.
HEADING = re.compile(r" {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")

# What a heading's text is made of, besides plain text: a code span, an
# inline link, whose text may hold code spans and brackets, and an HTML tag.
IN_HEADING = re.compile(
    r"(?<!`)(?P<ticks>`+)(?!`)(?P<code>.+?)(?<!`)(?P=ticks)(?!`)"
    r"|\[(?P<text>(?:[^\]\[`]|`+[^`]*`+|\[[^\]\[]*\])*)\]\([^)]*\)"
    r"|</?[A-Za-z][^>]*>"
)

# An <a> element with an id or a name.
ANCHOR_ELEMENT = re.compile(r"""<a\s[^>]*?\b(?:id|name)=["']([^"']+)["']""", re.IGNORECASE)

# A character of a link's text, which may wrap but not cross a blank line.
TEXT = r"(?:[^\]\[\n]|\n(?![ \t]*\n))"

# A title, which may follow a link's target.
TITLE = r"""(?:"[^"\n]*"|'[^'\n]*')"""

# The three ways to write a link, each with its target: inline, where the
# text may hold brackets and the target parentheses, one deep; as a
# definition, which is alone on its line, and whose label does not start
# with ^, as a footnote's does; and as a URL between < and >.
LINKS = (
    re.compile(
        rf"(?<!\\)\[(?:{TEXT}|\[{TEXT}*\])*\]"
        rf"\(\s*<?(?P<target>(?:[^()\s<>]|\([^()\s]*\))+)>?(?:\s+{TITLE})?\s*\)"
    ),
    re.compile(
        rf"^ {{0,3}}\[(?!\^)[^\]\n]+\]:[ \t]*<?(?P<target>[^\s<>]+)>?(?:[ \t]+{TITLE})?[ \t]*$",
        re.MULTILINE,
    ),
    re.compile(r"<(?P<target>[A-Za-z][A-Za-z0-9+.-]*://[^\s<>]+)>"),
)


def without_fenced_code(text):
    """The lines of a Markdown text, with every line of fenced code empty,
    its fences too, so that each line keeps its number."""
    lines = []
    fence = None
    for line in text.split("\n"):
        match = FENCE.match(line)
        if fence is not None:
            # The closing fence is as long as the opening one, or longer,
            # and nothing follows it.
            if match and match[1].startswith(fence) and not match[2].strip():
                fence = None
            lines.append("")
        elif match and not (match[1][0] == "`" and "`" in match[2]):
            # With a backtick after them, backticks open a code span.
            fence = match[1]
            lines.append("")
        else:
            lines.append(line)
    return lines


def without_code(text):
    """A Markdown text with its fenced code empty and with spaces for its
    code spans, line for line."""
    prose = "\n".join(without_fenced_code(text))
    return CODE_SPAN.sub(lambda span: re.sub(r"[^\n]", " ", span[0]), prose)


def shown(heading):
    """A heading's text as GitHub shows it, as far as its anchor needs: a
    code span's text as written, a link's text, and no HTML tag. Emphasis
    stays as written, which gives the same anchor for * and another for _,
    since an anchor keeps its underscores."""

    def text(part):
        if part["code"] is not None:
            return part["code"]
        if part["text"] is not None:
            return shown(part["text"])
        return ""

    return IN_HEADING.sub(text, heading)


def anchor(heading):
    """The anchor that GitHub gives a heading, before it numbers a repeated
    one: the text in lower case, of which it keeps the letters, the marks,
    the numbers, the hyphens and the connectors such as the underscore, and
    turns each space into a hyphen."""
    kept = []
    for char in shown(heading).lower():
        category = unicodedata.category(char)
        if char in " -" or category[0] in "LMN" or category == "Pc":
            kept.append(char)
    return "".join(kept).replace(" ", "-")


def anchors(text):
    """The anchors of a Markdown text: those of its headings, where the
    second heading of a text gets -1 and the third -2, and the ids and
    names of its <a> elements."""
    found = set()
    repeats = {}
    for line in without_fenced_code(text):
        match = HEADING.match(line)
        if match:
            name = anchor(match[1])
            count = repeats.get(name, 0)
            repeats[name] = count + 1
            found.add(name if count == 0 else f"{name}-{count}")
    found.update(match[1] for match in ANCHOR_ELEMENT.finditer(without_code(text)))
    return found


def links(text):
    """The links of a Markdown text outside its code, in order: for each,
    the line of its target and the target."""
    prose = without_code(text)
    # By its place, since a URL between < and > that is the target of an
    # inline link is found twice.
    targets = {match.start("target"): match["target"] for pattern in LINKS for match in pattern.finditer(prose)}
    line_starts = [0] + [newline.end() for newline in re.finditer("\n", prose)]
    return [(bisect.bisect_right(line_starts, start), target) for start, target in sorted(targets.items())]


def destination(name, target):
    """Where in the repository the link to <target> in the file <name>
    leads: the path from the root, which is "." itself, and the fragment.
    None when it leads elsewhere."""
    match = INTO_REPOSITORY.match(target)
    if match:
        path, fragment = unquote(match["path"] or ""), match["fragment"] or ""
    elif ELSEWHERE.match(target):
        return None
    else:
        path, _, fragment = target.partition("#")
        path = unquote(path)
        if not path:
            path = name
        elif path.startswith("/"):
            path = path.lstrip("/")
        else:
            path = posixpath.join(posixpath.dirname(name), path)
    return posixpath.normpath(path), unquote(fragment)


class Checkout:
    """The files of a checkout that git tracks or would track, with their
    directories, and the anchors of its Markdown files."""

    def __init__(self, root):
        listed = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            check=True,
        ).stdout.decode("utf-8", "surrogateescape")
        self.root = root
        # git still lists a file that was deleted and not yet committed.
        self.files = {name for name in listed.split("\0") if name and os.path.lexists(os.path.join(root, name))}
        self.directories = {"."}
        for name in self.files:
            directory = posixpath.dirname(name)
            while directory and directory not in self.directories:
                self.directories.add(directory)
                directory = posixpath.dirname(directory)
        self.found = {}

    def read(self, name):
        """The text of a file."""
        with open(os.path.join(self.root, name), encoding="utf-8", errors="replace") as file:
            return file.read()

    def anchors(self, name):
        """The anchors of a Markdown file."""
        if name not in self.found:
            self.found[name] = anchors(self.read(name))
        return self.found[name]

    def fault(self, path, fragment):
        """What is wrong with a link that leads to <path> and <fragment>,
        as destination gives them; None when nothing is."""
        if path == ".." or path.startswith("../"):
            return "leads out of the repository"
        if path in self.directories:
            # GitHub shows a directory with its README.md under the files.
            page = posixpath.normpath(posixpath.join(path, "README.md"))
        elif path not in self.files:
            if os.path.lexists(os.path.join(self.root, path)):
                return "no such file in the repository: git ignores the one here"
            return "no such file"
        elif path.endswith(".md"):
            page = path
        else:
            return None
        if fragment and (page not in self.files or fragment not in self.anchors(page)):
            return "no heading with that anchor"
        return None


def plural(count, one, more):
    """<count> <one>, or <count> <more> when count is not 1."""
    return f"{count} {one if count == 1 else more}"


def main(argv):
    if len(argv) > 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = argv[1] if argv[1:] else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        checkout = Checkout(root)
    except subprocess.CalledProcessError as error:
        reason = error.stderr.decode("utf-8", "replace").strip()
        print(f"check-doc-links: git cannot list the files of {root}: {reason}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"check-doc-links: cannot run git: {error}", file=sys.stderr)
        return 2
    documents = sorted(name for name in checkout.files if name.endswith(".md"))
    if not documents:
        print(f"check-doc-links: {root} holds no Markdown file")
        return 1

    checked = broken = 0
    try:
        for name in documents:
            for line, target in links(checkout.read(name)):
                leads_to = destination(name, target)
                if leads_to is None:
                    continue
                checked += 1
                fault = checkout.fault(*leads_to)
                if fault:
                    broken += 1
                    print(f"{name}:{line}: {target}: {fault}")
    except OSError as error:
        print(f"check-doc-links: cannot read a file: {error}", file=sys.stderr)
        return 2
    print(
        f"check-doc-links: {plural(checked, 'link', 'links')} into the repository in "
        f"{plural(len(documents), 'Markdown file', 'Markdown files')}, {broken or 'none'} broken"
    )
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

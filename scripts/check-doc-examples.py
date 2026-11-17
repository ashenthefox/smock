#!/usr/bin/env python3
"""Runs the examples of smock's user documents with a smock binary, so that
an example that stops working fails CI on the push that broke it.

usage: python3 scripts/check-doc-examples.py <smock> [<tree>]

<smock> is the binary to run; CI gives the release binary that its job
builds. <tree> is the checkout whose documents are read: this one, unless
it is given.

The user documents are those that docs/README.md links to before its
section "Contributing to smock": the README and the glossary that its
opening names, and the documents it lists under "Using smock" and
"Operating smock".

A fenced block of a user document is a whole Definition file when its
language is yaml, yml or json, or not given, and its top level is a
mapping whose keys are all top-level fields of a Definition file
(version, mocks, stubs and data). In YAML, the top level is each line
that starts at the block's left edge, the fence's own indentation, but
blank lines, comments and the document markers --- and ...; each must be a
key and a colon. A block whose text starts with { is read as JSON, and
its top level is the members of the outermost object. Every other block,
such as a Stub alone, a request or a command, is a fragment, and is set
aside.

Each whole Definition file is written alone into a definitions directory,
as example.json when it is JSON and example.yaml otherwise, and passes
when `smock check` exits with status 0. What smock check prints, such as a
warning, is shown under the block.

It prints a line for each whole Definition file, each problem, and then
how many whole Definition files it found and how many fenced blocks it set
aside. It exits with 1 when an example fails, and with 2 when it cannot
run smock or a document cannot be read, or is run wrongly.

scripts/test-check-doc-examples.sh tests it, with a fake smock. It needs
Python 3.9 or later.
"""
import os
import posixpath
import re
import subprocess
import sys
import tempfile

USAGE = "usage: python3 scripts/check-doc-examples.py <smock> [<tree>]"

# The index of the documents, and the heading of its first section that
# lists no user document.
INDEX = "docs/README.md"
CONTRIBUTING_HEADING = "## Contributing to smock"

# The top-level fields of a Definition file (schema/v1/definitions.json).
FIELDS = {"version", "mocks", "stubs", "data"}

# The languages of a block that may be a whole Definition file; "" is none.
DEFINITION_LANGUAGES = {"yaml", "yml", "json", ""}

# A line that may open or close fenced code: its indentation, the fence,
# and what follows it. A fence in a list item is indented with the item.
FENCE = re.compile(r"([ \t]*)(`{3,}|~{3,})(.*)")

# An inline link, and its target up to a fragment.
LINK = re.compile(r"\[[^\]]*\]\(\s*<?([^)\s#>]*)")

# A key of a YAML mapping at the start of a line, and the colon after it:
# a quoted scalar, or a plain one, which does not start with an indicator.
YAML_KEY = re.compile(r"""("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s\-?:,\[\]{}#&*!|>'"%@`][^:#]*?)[ \t]*:(?:[ \t]|$)""")

# How long smock check may take on one Definition file, in seconds.
TIMEOUT = 60


class Unreadable(Exception):
    """A file that the check must read cannot be read."""


def read(tree, path):
    """The text of <path> in the tree."""
    try:
        with open(os.path.join(tree, path), encoding="utf-8") as handle:
            return handle.read()
    except OSError as error:
        raise Unreadable(f"cannot read {path}: {error.strerror}") from error


def user_documents(tree):
    """The user documents, as paths from the tree's root, in byte-wise
    order: the Markdown files that the index links to before its section
    for contributors."""
    found = set()
    for line in read(tree, INDEX).split("\n"):
        if line.strip() == CONTRIBUTING_HEADING:
            break
        for target in LINK.findall(line):
            if target.endswith(".md") and "://" not in target:
                found.add(posixpath.normpath(posixpath.join(posixpath.dirname(INDEX), target)))
    return sorted(found)


class Block:
    """A fenced block of a document: the line of its opening fence, its
    language, and its text without the fence's indentation."""

    def __init__(self, line, language, text):
        self.line = line
        self.language = language
        self.text = text


def fenced_blocks(text):
    """The fenced blocks of a Markdown text, in order. A block that is
    never closed runs to the end of the text."""
    blocks = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        match = FENCE.fullmatch(lines[i])
        # With a backtick after them, backticks open a code span.
        if not match or (match[2][0] == "`" and "`" in match[3]):
            i += 1
            continue
        indent, fence, info = match[1], match[2], match[3].strip()
        body = []
        j = i + 1
        while j < len(lines):
            closing = FENCE.fullmatch(lines[j])
            # The closing fence is as long as the opening one, or longer,
            # and nothing follows it.
            if closing and closing[2].startswith(fence) and not closing[3].strip():
                break
            line = lines[j]
            body.append(line[len(indent) :] if line.startswith(indent) else line.lstrip(" \t"))
            j += 1
        language = info.split()[0].lower() if info else ""
        blocks.append(Block(i + 1, language, "\n".join(body)))
        i = j + 1
    return blocks


def json_keys(text):
    """The keys of the outermost object of a JSON text, read without
    parsing it, so that a text JSON does not accept still shows them."""
    keys = []
    depth = 0
    i = 0
    while i < len(text):
        char = text[i]
        if char == '"':
            end = i + 1
            while end < len(text) and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            after = end + 1
            while after < len(text) and text[after] in " \t\r\n":
                after += 1
            if depth == 1 and after < len(text) and text[after] == ":":
                keys.append(text[i + 1 : end])
            i = end + 1
            continue
        if char in "{[":
            depth += 1
        elif char in "}]":
            depth -= 1
        i += 1
    return keys


def yaml_keys(text):
    """The keys of the mapping at the top level of a YAML text, or None
    when its top level is not a mapping."""
    keys = []
    for line in text.split("\n"):
        if not line.strip() or line[0] in " \t#" or line in ("---", "..."):
            continue
        match = YAML_KEY.match(line)
        if not match:
            return None
        key = match[1]
        keys.append(key[1:-1] if key[0] in "\"'" else key)
    return keys


def is_json(block):
    """Whether a block is read as JSON."""
    return block.text.lstrip().startswith("{")


def is_whole_file(block):
    """Whether a block is a whole Definition file, by the rule above."""
    if block.language not in DEFINITION_LANGUAGES:
        return False
    keys = json_keys(block.text.strip()) if is_json(block) else yaml_keys(block.text)
    return bool(keys) and set(keys) <= FIELDS


def indented(text):
    """A text with each of its lines indented, as the check shows output."""
    return "\n".join("    " + line for line in text.rstrip("\n").split("\n"))


def run(command, cwd=None):
    """Runs a command with a plain environment, and gives its exit status
    and all it printed, standard output and standard error together."""
    environment = {"PATH": os.environ.get("PATH", "")}
    if "HOME" in os.environ:
        environment["HOME"] = os.environ["HOME"]
    result = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=TIMEOUT,
    )
    return result.returncode, result.stdout.decode("utf-8", "replace")


def check_definition_files(tree, smock, scratch):
    """Runs smock check on each whole Definition file of the user
    documents. Gives the number of whole files, of those that fail, and of
    the blocks set aside."""
    whole = failing = aside = 0
    for document in user_documents(tree):
        for block in fenced_blocks(read(tree, document)):
            if not is_whole_file(block):
                aside += 1
                continue
            whole += 1
            where = f"{document}:{block.line}"
            directory = os.path.join(scratch, f"example-{whole}")
            os.makedirs(directory)
            name = "example.json" if is_json(block) else "example.yaml"
            with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
                handle.write(block.text + "\n")
            try:
                status, output = run([smock, "check", directory])
            except subprocess.TimeoutExpired:
                status, output = None, ""
            if status == 0:
                print(f"{where}: passes smock check")
            elif status is None:
                failing += 1
                print(f"{where}: smock check takes longer than {TIMEOUT} s")
            else:
                failing += 1
                print(f"{where}: smock check exits with {status}:")
            if output.strip():
                print(indented(output))
    return whole, failing, aside


def plural(count, singular, many):
    return f"{count} {singular if count == 1 else many}"


def main(arguments):
    if len(arguments) not in (1, 2):
        print(USAGE, file=sys.stderr)
        return 2
    smock = os.path.abspath(arguments[0])
    tree = arguments[1] if len(arguments) == 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    if not os.access(smock, os.X_OK):
        print(f"check-doc-examples: cannot run {arguments[0]}", file=sys.stderr)
        return 2
    try:
        with tempfile.TemporaryDirectory() as scratch:
            whole, failing, aside = check_definition_files(tree, smock, scratch)
    except Unreadable as error:
        print(f"check-doc-examples: {error}", file=sys.stderr)
        return 2
    files = plural(whole, "whole Definition file", "whole Definition files")
    blocks = plural(aside, "other fenced block", "other fenced blocks")
    if failing:
        print(f"check-doc-examples: {files}, {failing} of which fails smock check; {blocks} set aside as fragments")
        return 1
    print(f"check-doc-examples: {files} pass smock check; {blocks} set aside as fragments")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

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
as example.json when it is JSON and example.yaml otherwise, with its
context, and passes when `smock check` exits with status 0. What smock
check prints, such as a warning, is shown under the block.

An example's context is what its document leaves out, such as a Mock that
another block declares or a body file whose content it does not show.
scripts/doc-examples/context.txt lists it, one file a line:

  <document> <example> <path> <source>

<document> and <example> name the example: <example> is its number among
the whole Definition files of <document>, counted from 1, as the check
prints it. <path> is where the file goes in the example's definitions
directory, and <source> the file of the tree it is a copy of. A line that
names no example, a path outside the directory or the example's own
file, a source the tree does not hold, or a path the example already
gets is a problem. Blank lines and lines that start with # are skipped.

The Mockoon migration guide, docs/migrating-from-mockoon.md and the
documents in docs/mockoon/, shows smock check and smock render commands,
and what they print. Each block of shell commands (sh, shell or bash) of
the guide that runs smock check or smock render runs as the guide writes
it, with sh -e, in a copy of docs/examples/from-mockoon/, where the guide
says its commands run, with the smock under check first on the PATH. The
blocks run one after another in the same copy. Each must exit with status
0 and print what the block shows: each line that is a comment after the
block's first command, without the # and the space after it. A comment
before the first command, or at the end of a command's line, says what
the commands do. A guide that runs these commands in no block is a
problem.

It prints a line for each whole Definition file, each problem, how many
whole Definition files it found and how many fenced blocks it set aside,
and then whether every example passed or how many problems it found. It
exits with 1 when it found a problem, and with 2 when it cannot run smock
or a file it reads cannot be read, or is run wrongly.

scripts/test-check-doc-examples.sh tests it, with a fake smock. It needs
Python 3.9 or later.
"""
import difflib
import os
import posixpath
import re
import shutil
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

# The context that examples leave out (read_context).
CONTEXT = "scripts/doc-examples/context.txt"

# The Mockoon migration guide, its other documents, and the directory its
# commands run in: "Unless a step says otherwise, the commands run in
# docs/examples/from-mockoon/".
MOCKOON_GUIDE = "docs/migrating-from-mockoon.md"
MOCKOON_DOCUMENTS = "docs/mockoon"
MOCKOON_EXAMPLE = "docs/examples/from-mockoon"

# The languages of a block of shell commands.
SHELL_LANGUAGES = {"sh", "shell", "bash"}

# A command that runs smock check or smock render.
SMOCK_COMMAND = re.compile(r"(?:^|[\s;&|(])smock\s+(?:check|render)\b")

# How long smock check may take on one Definition file, and a block of
# commands to run, in seconds.
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


def run(command, cwd=None, path=None):
    """Runs a command with a plain environment, with <path> first on its
    PATH when it is given, and gives its exit status and all it printed,
    standard output and standard error together."""
    environment = {"PATH": os.environ.get("PATH", "")}
    if path is not None:
        environment["PATH"] = path + os.pathsep + environment["PATH"]
    if "HOME" in os.environ:
        environment["HOME"] = os.environ["HOME"]
    result = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=TIMEOUT,
    )
    return result.returncode, result.stdout.decode("utf-8", "replace")


class Example:
    """A whole Definition file of a user document: its document, the line
    of its opening fence, its number among the document's whole Definition
    files, counted from 1, its block, and its context, the files its
    definitions directory gets, each as (path, source)."""

    def __init__(self, document, number, block):
        self.document = document
        self.number = number
        self.block = block
        self.context = []

    def where(self):
        return f"{self.document}:{self.block.line} (example {self.number})"

    def file_name(self):
        return "example.json" if is_json(self.block) else "example.yaml"


def find_examples(tree, documents):
    """The whole Definition files of the documents, and the number of the
    other fenced blocks, which are set aside."""
    examples = []
    aside = 0
    for document in documents:
        number = 0
        for block in fenced_blocks(read(tree, document)):
            if is_whole_file(block):
                number += 1
                examples.append(Example(document, number, block))
            else:
                aside += 1
    return examples, aside


def inside(path):
    """Whether a relative path stays where it starts, in normal form. An
    absolute path starts with an empty part."""
    return all(part not in ("", ".", "..") for part in path.split("/"))


def read_context(tree, documents, examples, problem):
    """Gives each example the context that the context file lists for it,
    and reports each line of the file that is wrong. A tree without the
    file gives no example any context."""
    try:
        text = read(tree, CONTEXT)
    except Unreadable:
        if os.path.exists(os.path.join(tree, CONTEXT)):
            raise
        return
    by_number = {(example.document, example.number): example for example in examples}
    counts = {}
    for example in examples:
        counts[example.document] = counts.get(example.document, 0) + 1
    given = set()
    for count, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        at = f"{CONTEXT}:{count}"
        fields = line.split()
        if len(fields) != 4 or not re.fullmatch(r"[1-9][0-9]*", fields[1]):
            problem(f"{at}: a line gives <document> <example> <path> <source>, the example a number from 1")
            continue
        document, number, path, source = fields[0], int(fields[1]), fields[2], fields[3]
        if document not in documents:
            problem(f"{at}: {document} is not a user document")
        elif (document, number) not in by_number:
            files = plural(counts.get(document, 0), "whole Definition file", "whole Definition files")
            problem(f"{at}: {document} has no example {number}: it has {files}")
        elif not inside(path):
            problem(f"{at}: {path} is not a path inside the definitions directory")
        elif path in ("example.yaml", "example.json"):
            problem(f"{at}: {path} is the example's own file")
        elif not inside(source) or not os.path.isfile(os.path.join(tree, source)):
            problem(f"{at}: {source} is not a file of the tree")
        elif (document, number, path) in given:
            problem(f"{at}: example {number} of {document} gets {path} twice")
        else:
            given.add((document, number, path))
            by_number[(document, number)].context.append((path, source))


def check_example(tree, smock, scratch, example, problem):
    """Runs smock check on an example, alone in a definitions directory
    with its context."""
    directory = os.path.join(scratch, f"{example.document}-{example.number}")
    os.makedirs(directory)
    with open(os.path.join(directory, example.file_name()), "w", encoding="utf-8") as handle:
        handle.write(example.block.text + "\n")
    for path, source in example.context:
        os.makedirs(os.path.dirname(os.path.join(directory, path)), exist_ok=True)
        shutil.copyfile(os.path.join(tree, source), os.path.join(directory, path))
    with_context = ""
    if example.context:
        with_context = ", with its context: " + ", ".join(path for path, _ in example.context)
    try:
        status, output = run([smock, "check", directory])
    except subprocess.TimeoutExpired:
        problem(f"{example.where()}: smock check takes longer than {TIMEOUT} s{with_context}")
        return
    if status == 0:
        print(f"{example.where()}: passes smock check{with_context}")
    else:
        problem(f"{example.where()}: smock check exits with {status}{with_context}:")
    if output.strip():
        print(indented(output))


def commands(block):
    """The lines of a block of shell commands that are not comments."""
    return [line for line in block.text.split("\n") if line.strip() and not line.strip().startswith("#")]


def shown_output(block):
    """What a block of shell commands shows that its commands print: each
    line that is a comment after its first command, without the # and the
    space after it. A comment before the first command, and one at the end
    of a command's line, says what the commands do."""
    shown = []
    started = False
    for line in block.text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#"):
            if started:
                shown.append(stripped[2:] if stripped.startswith("# ") else stripped[1:])
        elif stripped:
            started = True
    return shown


def run_block(where, block, directory, bin_directory, problem):
    """Runs a block of shell commands in a directory, with sh -e, so that
    the block stops at a command that fails, and with the smock under check
    first on the PATH. It passes when it exits with status 0 and prints
    what the block shows, standard output and standard error together."""
    try:
        status, output = run(["/bin/sh", "-e", "-c", block.text], cwd=directory, path=bin_directory)
    except subprocess.TimeoutExpired:
        problem(f"{where}: takes longer than {TIMEOUT} s")
        return
    if status != 0:
        problem(f"{where}: exits with {status}:")
        if output.strip():
            print(indented(output))
        return
    shown = shown_output(block)
    printed = output.split("\n")
    if printed and printed[-1] == "":
        printed.pop()
    if printed == shown:
        print(f"{where}: prints what the guide shows")
        return
    problem(f"{where}: prints otherwise than the guide shows:")
    print(indented("\n".join(difflib.unified_diff(shown, printed, "the guide", "printed", lineterm=""))))


def check_mockoon_guide(tree, scratch, bin_directory, problem):
    """Runs the blocks of the Mockoon guide that run smock check or smock
    render, one after another, in one copy of the example's directory, and
    gives how many there are. A guide with none is a problem."""
    documents = [MOCKOON_GUIDE]
    if os.path.isdir(os.path.join(tree, MOCKOON_DOCUMENTS)):
        names = sorted(os.listdir(os.path.join(tree, MOCKOON_DOCUMENTS)))
        documents += [f"{MOCKOON_DOCUMENTS}/{name}" for name in names if name.endswith(".md")]
    blocks = []
    for document in documents:
        for block in fenced_blocks(read(tree, document)):
            if block.language in SHELL_LANGUAGES and any(SMOCK_COMMAND.search(line) for line in commands(block)):
                blocks.append((document, block))
    if not blocks:
        problem(
            f"check-doc-examples: the Mockoon guide, {MOCKOON_GUIDE} and {MOCKOON_DOCUMENTS}/*.md,"
            " runs smock check or smock render in no block"
        )
        return 0
    directory = os.path.join(scratch, "mockoon")
    shutil.copytree(os.path.join(tree, MOCKOON_EXAMPLE), directory, symlinks=True)
    for document, block in blocks:
        run_block(f"{document}:{block.line}", block, directory, bin_directory, problem)
    return len(blocks)


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
    problems = []

    def problem(message):
        problems.append(message)
        print(message)

    try:
        documents = user_documents(tree)
        examples, aside = find_examples(tree, documents)
        read_context(tree, documents, examples, problem)
        with tempfile.TemporaryDirectory() as scratch:
            for example in examples:
                check_example(tree, smock, scratch, example, problem)
            # The documents' commands run smock by its name.
            bin_directory = os.path.join(scratch, "bin")
            os.makedirs(bin_directory)
            os.symlink(smock, os.path.join(bin_directory, "smock"))
            guide_blocks = check_mockoon_guide(tree, scratch, bin_directory, problem)
    except Unreadable as error:
        print(f"check-doc-examples: {error}", file=sys.stderr)
        return 2
    files = plural(len(examples), "whole Definition file", "whole Definition files")
    blocks = plural(aside, "other fenced block", "other fenced blocks")
    print(f"check-doc-examples: found {files}, and set aside {blocks} as fragments")
    guide = plural(guide_blocks, "block", "blocks")
    print(f"check-doc-examples: found {guide} of the Mockoon guide that run smock check or smock render")
    if problems:
        print(f"check-doc-examples: {plural(len(problems), 'problem', 'problems')}")
        return 1
    print("check-doc-examples: every example passes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

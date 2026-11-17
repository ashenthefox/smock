"""Operator set v1 of the test review: which alternatives each operator
makes at a position, which of them the pinned set takes, and which sites a
rule skips (CONTRIBUTING.md, "Operator set v1"; ADR 0006).

The site finder (sites.py) reads the parse tree and finds the positions:
a comparison, a condition, an integer literal, a statement, a function's
body. This module says what each position becomes. It holds everything
that decides the meaning of a "zero", so a change to it, the alternative
rule included, is a new version (VERSION), which needs the maintainer's
approval and shows in every record and report.
"""

import re
from typing import NamedTuple

# The version every site, record, summary and report carries.
VERSION = "v1"

# The operators, in the order ADR 0006 lists them. Where two sites make the
# same mutant, the finder keeps the pinned one, and then the one that comes
# first in DEDUPLICATION.
OPERATORS = ("BODY", "ROR", "IFC", "LCR", "NOT", "DEL", "BOOL", "AOR", "INT", "STR")
DEDUPLICATION = ("BODY", "ROR", "LCR", "NOT", "BOOL", "AOR", "INT", "STR", "IFC", "DEL")

# The rules that skip a site, by the reason a skipped site gives.
NO_DEFAULT = "no default"          # BODY: the return type has no default value
FFI = "FFI"                        # BODY: the function is foreign (extern)
OUTSIDE_SCOPE = "outside scope"    # STR: the literal is outside STR's scope
BINDS = "binds a name"             # IFC, LCR: forcing it unbinds a name `is` binds
STRING_OPERAND = "string operand"  # AOR: `+` joins strings, which have no `-`
SKIPS = (NO_DEFAULT, FFI, OUTSIDE_SCOPE, BINDS, STRING_OPERAND)


class Alternative(NamedTuple):
    """One alternative at a position: its replacement text, whether the
    pinned set takes it, and the rule that skips it, if one does."""

    replacement: str
    pinned: bool
    skipped: str | None = None


# ROR: the boundary alternative only. == and != are not swapped, in either set.
ROR = {"<": "<=", "<=": "<", ">": ">=", ">=": ">"}
# LCR, BOOL, AOR (the compound assignments too).
LCR = {"&&": "||", "||": "&&"}
BOOL = {"true": "false", "false": "true"}
AOR = {"+": "-", "-": "+", "*": "/", "/": "*", "+=": "-=", "-=": "+=", "*=": "/=", "/=": "*="}


def ror(text):
    """A comparison's alternatives."""
    return [Alternative(ROR[text], True)] if text in ROR else []


def lcr(text, binds):
    """A logical operator's alternative. `&&` whose operands bind a name with
    `is` is skipped: as `||`, the name is no longer bound where it is used."""
    if text not in LCR:
        return []
    return [Alternative(LCR[text], True, BINDS if binds and text == "&&" else None)]


def bool_literal(text):
    """A boolean literal's alternative."""
    return [Alternative(BOOL[text], True)] if text in BOOL else []


def aor(text, string_operand):
    """An arithmetic operator's alternative, in a compound assignment too.
    `+` on a string literal is skipped: strings have no `-`."""
    if text not in AOR:
        return []
    skipped = STRING_OPERAND if string_operand and text in ("+", "+=") else None
    return [Alternative(AOR[text], True, skipped)]


def not_operator():
    """A prefix `!`, removed."""
    return [Alternative("", True)]


def statement():
    """A statement, deleted."""
    return [Alternative("", True)]


# IFC: the kinds of condition, and the alternative the pinned set takes at
# each: the one under which the code the condition guards never runs.
IFC_PINNED = {"if": "false", "loop": "false", "match guard": "false", "guard": "true"}


def condition(kind, text, binds):
    """A condition's alternatives: forced to the pinned value, then to the
    other. An alternative equal to the condition's own text is no site. A
    condition that binds a name with `is` is skipped: forced, the name is
    no longer bound where the guarded code uses it."""
    pinned = IFC_PINNED[kind]
    other = "true" if pinned == "false" else "false"
    skipped = BINDS if binds else None
    return [Alternative(value, value == pinned, skipped) for value in (pinned, other) if value != text]


# INT: an integer literal as the source writes it: a sign, digits in a base,
# an optional suffix.
INTEGER = re.compile(r"^(-?)(0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*)(UL|U|L|N)?$")
# The range of each suffix's type. An unsuffixed literal is an Int; the
# compiler also takes 0x80000000 to 0xFFFFFFFF as an Int, by their bits.
RANGES = {
    "L": (-(2**63), 2**63 - 1),
    "UL": (0, 2**64 - 1),
    "U": (0, 2**32 - 1),
    "N": (None, None),
}
INT_RANGE = (-(2**31), 2**31 - 1)
INT_BITS_RANGE = (-(2**31), 2**32 - 1)
# Where an unsuffixed literal does not fit an Int, the compiler took it as a
# wider type, from its context: the smallest of these that holds it.
WIDER = ((-(2**63), 2**63 - 1), (0, 2**64 - 1))


def integer_value(text):
    """The value of an integer literal's text, its base prefix and its
    suffix, or None when the text is not an integer literal."""
    match = INTEGER.match(text)
    if not match:
        return None
    sign, digits, suffix = match.group(1), match.group(2).replace("_", ""), match.group(3) or ""
    lowered = digits.lower()
    if lowered.startswith("0x"):
        value, prefix = int(digits[2:], 16), digits[:2]
    elif lowered.startswith("0o"):
        value, prefix = int(digits[2:], 8), digits[:2]
    elif lowered.startswith("0b"):
        value, prefix = int(digits[2:], 2), digits[:2]
    else:
        value, prefix = int(digits, 10), ""
    return (-value if sign else value), prefix, suffix, digits


def literal_range(value, prefix, suffix):
    """The range of the type the literal has: by its suffix, or an Int, or
    the smallest wider type that holds it."""
    if suffix:
        return RANGES[suffix]
    first = INT_BITS_RANGE if prefix else INT_RANGE
    if first[0] <= value <= first[1]:
        return first
    for low, high in WIDER:
        if low <= value <= high:
            return (low, high)
    return (None, None)


def fits(value, bounds):
    """Whether a value lies in a range whose ends may be open (None)."""
    low, high = bounds
    return (low is None or value >= low) and (high is None or value <= high)


def write_integer(value, prefix, suffix, digits):
    """An integer as a literal in the base and with the suffix of the
    original, and with upper-case hexadecimal digits when it had them."""
    magnitude = abs(value)
    base = prefix.lower()
    if base == "0x":
        body = format(magnitude, "x")
        if any(c in "ABCDEF" for c in digits[2:]):
            body = body.upper()
    elif base == "0o":
        body = format(magnitude, "o")
    elif base == "0b":
        body = format(magnitude, "b")
    else:
        body = str(magnitude)
    return f"{'-' if value < 0 else ''}{prefix}{body}{suffix}"


def integer_literal(text, in_comparison_or_index):
    """An integer literal's alternatives: n+1, n-1, and 0 where n is not 0,
    each where it fits the literal's type. In an operand of a comparison or
    an index, the pinned set takes both n+1 and n-1; elsewhere it takes n+1,
    or n-1 where n+1 does not fit."""
    parsed = integer_value(text)
    if parsed is None:
        return []
    value, prefix, suffix, digits = parsed
    bounds = literal_range(value, prefix, suffix)
    candidates = []
    for new in (value + 1, value - 1, 0):
        if new != value and fits(new, bounds) and new not in candidates:
            candidates.append(new)
    if in_comparison_or_index:
        pinned = {v for v in candidates if v in (value + 1, value - 1)}
    else:
        pinned = {value + 1} if value + 1 in candidates else {value - 1}
    return [Alternative(write_integer(v, prefix, suffix, digits), v in pinned) for v in candidates]


# STR's scope: the protocol packages, server, and log's line and envelope
# writers, but not log's reader of request targets. Paths are relative to
# the workspace's root.
STR_SCOPE = ("http1/", "grpc/", "yaml/", "re2/", "xml/", "protobuf/", "server/", "log/")
STR_OUTSIDE = ("log/target.mbt",)


def in_str_scope(path):
    """Whether STR's scope holds a file, by its path from the root."""
    return path.startswith(STR_SCOPE) and path not in STR_OUTSIDE


def string_literal(path, text, first, empty):
    """A string literal's alternatives. `first` is (start, end, character):
    where the source writes the first character of the literal's text,
    outside any interpolation, as offsets into `text`, and the character it
    stands for; when the literal writes no character, start and end are
    where its text starts, and the character is None. `empty` is the empty
    literal of its kind. The pinned set changes the first character to `_`,
    or to `-` when it is `_`, and a literal without one gets `_` there; the
    full set adds the empty literal."""
    skipped = None if in_str_scope(path) else OUTSIDE_SCOPE
    start, end, character = first
    changed = text[:start] + ("-" if character == "_" else "_") + text[end:]
    alternatives = [Alternative(changed, True, skipped)]
    if text != empty:
        alternatives.append(Alternative(empty, False, skipped))
    return alternatives


# BODY: the default value of each return type the source can name. A type
# not here, such as a type parameter or a type of the program's own, has no
# default, and its function's BODY site is skipped.
DEFAULTS = {
    "Unit": "()",
    "Bool": "false",
    "Int": "0", "Int32": "0", "Int16": "0", "UInt16": "0", "Int64": "0", "UInt": "0", "UInt32": "0",
    "UInt64": "0",
    "Byte": "0", "BigInt": "0", "Double": "0", "Float": "0",
    "Char": "'\\u{0}'",
    "String": '""', "StringView": '""',
    "Bytes": 'b""', "BytesView": 'b""',
    "Array": "[]", "FixedArray": "[]", "ArrayView": "[]",
    "Map": "{}",
    "Json": "null",
    "Iter": "Iter::empty()",
}
# The methods of core's traits, whose return type an implementation does
# not have to write.
TRAIT_METHODS = {
    ("Show", "output"): "Unit",
    ("Show", "to_string"): "String",
    ("Eq", "equal"): "Bool",
    ("Eq", "op_equal"): "Bool",
    ("Compare", "compare"): "Int",
    ("Hash", "hash_combine"): "Unit",
    ("Hash", "hash"): "Int",
    ("ToJson", "to_json"): "Json",
}


def default_value(kind, name, arguments):
    """The default value of a type: kind is "name" (with the type's name and
    its type arguments' defaults), "option" or "tuple" (with the elements'
    defaults); None when the type has none. An argument's default is None
    when that argument has none."""
    if kind == "option":
        return "None"
    if kind == "tuple":
        return None if None in arguments else "(" + ", ".join(arguments) + ")"
    if kind != "name":
        return None
    if name == "Option":
        return "None"
    if name == "Result":
        return f"Ok({arguments[0]})" if arguments and arguments[0] is not None else None
    return DEFAULTS.get(name)


def body(default, text, empty):
    """A function body's alternative: replaced by `{ default }`. A body
    that already is the default value, or that is empty where the default
    is (), is no site."""
    if default is None:
        return [Alternative("", True, NO_DEFAULT)]
    inner = text[1:-1].strip()
    if inner == default or (default == "()" and (empty or inner == "")):
        return []
    return [Alternative("{ " + default + " }", True)]


def foreign():
    """A foreign function's BODY site, skipped: its body is not MoonBit."""
    return [Alternative("", True, FFI)]

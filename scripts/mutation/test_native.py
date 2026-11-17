"""Tests of the mutation runner's native verdicts (#307): the site finder's
mark on each site whose definition uses an unchecked array access, through
scripts/mutation/sites.py's command line, on the fixture module
scripts/mutation/fixture and on smock's own source.

#275 ("Backend") and #307 ask for it: verdicts for pure packages are
taken on wasm-gc, but wasm-gc traps on an out-of-bounds unchecked array
access where the native binary reads on without a sign, so the sites
that use one are judged natively as well. In the fixture's package
bounds, dot_after reads a character with unsafe_get, and each mutant of
the pinned set has a known outcome on each backend, which the comment
beside its site gives with its reason.

They need python3, git, moon and moonc (the toolchain of
.moonbit-version), as test_mutation.py does.

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
SITES = HERE / "sites.py"

# The mutants of bounds' pinned set: each one's id, whether the finder
# marks its site as one whose definition uses an unchecked array access,
# and the outcomes that the comment beside its site gives on wasm-gc and
# natively (None where it does not run natively).
BOUNDS = [
    ("bounds/bounds.mbt,dot_after,BODY,{…},{ false },0", True, "killed", "killed"),
    ("bounds/bounds.mbt,dot_after,ROR,>,>=,0", True, "killed", "survived"),
    ("bounds/bounds.mbt,dot_after,LCR,&&,||,0", True, "killed", "killed"),
    ("bounds/bounds.mbt,is_empty_name,BODY,{…},{ false },0", False, "killed", None),
    ("bounds/bounds.mbt,is_empty_name,INT,0,1,0", False, "killed", None),
    ("bounds/bounds.mbt,is_empty_name,INT,0,-1,0", False, "killed", None),
]


def find_sites(root, *paths):
    """What the site finder prints for the paths in the full set, as a
    list of objects: the sites and the skipped sites."""
    result = subprocess.run([sys.executable, str(SITES), "--root", str(root), "--set", "full", *paths],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"sites.py failed ({result.returncode}):\n{result.stderr}")
    return [json.loads(line) for line in result.stdout.splitlines()]


class UncheckedSitesTest(unittest.TestCase):
    def test_a_site_whose_definition_uses_an_unchecked_array_access_is_marked(self):
        # Each site whose enclosing definition uses an unchecked array
        # access is marked, so that its mutant is judged natively as well;
        # any other site carries no mark.
        lines = find_sites(FIXTURE, "bounds")
        self.assertEqual([(s["id"], s.get("unchecked_access", False)) for s in lines],
                         [(i, unchecked) for i, unchecked, _, _ in BOUNDS])
        self.assertEqual({s["unchecked_access"] for s in lines if "unchecked_access" in s}, {True})
        # In smock, each kind of call that reads or writes without a bounds
        # check: unsafe_get (protobuf's is_inside), unsafe_blit (its
        # Output::reserve), unsafe_read_uint64_le (http1's Parser::scan_head)
        # and unsafe_view (log's write_json_escaped). The mark covers every
        # line of such a definition, its skipped sites too.
        lines = find_sites(REPO, "protobuf/reflection.mbt", "protobuf/output.mbt", "http1/parser.mbt",
                           "log/mockoon.mbt", "template/encoding.mbt")
        definitions = {}
        for s in lines:
            definitions.setdefault(s["definition"], set()).add(s.get("unchecked_access", False))
        for name in ("is_inside", "Output::reserve", "Parser::scan_head", "write_json_escaped"):
            self.assertEqual(definitions[name], {True}, name)
        # is_member, beside is_inside, reads no character without a check;
        # template's write_percent_encoded converts with unsafe_to_char, and
        # http1's ascii reinterprets its buffer with
        # unsafe_reinterpret_as_bytes and then slices it with a check:
        # neither reads an array without one.
        for name in ("is_member", "write_percent_encoded", "ascii"):
            self.assertEqual(definitions[name], {False}, name)

"""Tests of the site-count ratchet (scripts/mutation/ratchet.py), through
its command line, on copies of the fixture module scripts/mutation/fixture
in small git histories.

#309 asks for it: each package's site count, per definition and
operator, is committed and must equal what the site finder gives on the
head; and a package's sites may drop only by as many as the base had in
the definitions a change deletes or changes, unless the change records
the drop, with its reason, in the list of approved drops (CONTRIBUTING.md,
"Mutation runner", "The site counts").

The expected counts come from the fixture's comments, which give each
site of calc's pinned set and what the full set adds (test_mutation.py's
CALC and CALC_OTHERS): in_range has BODY, two ROR and LCR; halve_until
BODY, IFC, ROR, DEL, AOR and INT, and the full set adds IFC's other value
and INT's two others; is_blank three BOOL, BODY, two IFC, NOT and two INT,
and the full set adds IFC's two others; is_odd BODY, NOT and four INT,
and the full set adds INT's 0 for the 2.

They need python3, git and moonc (the toolchain of .moonbit-version).

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixture"
RATCHET = HERE / "ratchet.py"
SITES = HERE / "sites.py"

# calc's counts, per definition, in the pinned set and in the full set.
CALC = [
    ("in_range", {"BODY": 1, "ROR": 2, "LCR": 1}, {"BODY": 1, "ROR": 2, "LCR": 1}),
    ("halve_until", {"BODY": 1, "ROR": 1, "IFC": 1, "DEL": 1, "AOR": 1, "INT": 1},
     {"BODY": 1, "ROR": 1, "IFC": 2, "DEL": 1, "AOR": 1, "INT": 3}),
    ("is_blank", {"BODY": 1, "IFC": 2, "NOT": 1, "BOOL": 3, "INT": 2},
     {"BODY": 1, "IFC": 4, "NOT": 1, "BOOL": 3, "INT": 2}),
    ("is_odd", {"BODY": 1, "NOT": 1, "INT": 4}, {"BODY": 1, "NOT": 1, "INT": 5}),
]
GIT = ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]


class History:
    """A copy of the fixture module in a git repository of its own."""

    def __init__(self, tmp):
        self.root = tmp / "module"
        shutil.copytree(FIXTURE, self.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        self.git("init", "-q", "-b", "main")

    def git(self, *args):
        return subprocess.run([*GIT, "-C", str(self.root), *args], capture_output=True, text=True, check=True).stdout

    def ratchet(self, *args, finder=None):
        options = ["--finder", str(finder)] if finder else []
        return subprocess.run([sys.executable, str(RATCHET), "--root", str(self.root), *options, *args],
                              capture_output=True, text=True)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def counts(self, package):
        """The committed counts of a package, as a list of objects."""
        path = self.root / "mutation" / "site-counts" / f"{package}.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()]


class RatchetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test-ratchet-"))
        self.history = History(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_counts_give_each_definitions_sites_per_operator_in_both_sets(self):
        result = self.history.ratchet("write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in (self.history.root / "mutation" / "site-counts").iterdir()),
                         ["calc.jsonl", "forms.jsonl", "log.jsonl", "shapes.jsonl"])
        counts = self.history.counts("calc")
        self.assertEqual([(c["definition"], c["pinned"], c["full"]) for c in counts], CALC)
        self.assertEqual({c["file"] for c in counts}, {"calc/calc.mbt"})
        self.assertEqual([list(c) for c in counts], [["file", "definition", "text", "pinned", "full"]] * 4)

    def test_the_check_passes_when_the_committed_counts_are_the_trees(self):
        self.history.ratchet("write")
        self.history.commit("counts")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("the committed site counts of 4 packages are the tree's", result.stdout)

    def test_the_check_fails_when_a_change_alters_sites_and_not_their_counts(self):
        self.history.ratchet("write")
        self.history.commit("counts")
        calc = self.history.root / "calc" / "calc.mbt"
        calc.write_text(calc.read_text().replace("!(n % 2 == 0)", "!(n % 2 == 0) && n > 0"))
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the committed site counts of calc differ from the site finder's on this tree", result.stderr)
        self.assertIn('-{"file":"calc/calc.mbt","definition":"is_odd"', result.stderr)
        self.assertIn("python3 scripts/mutation/ratchet.py write", result.stderr)
        # So does a package whose counts are not committed at all.
        (self.history.root / "mutation" / "site-counts" / "log.jsonl").unlink()
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the committed site counts of log differ from the site finder's on this tree", result.stderr)


if __name__ == "__main__":
    unittest.main()

"""Tests of the mutation runner's site finder, scripts/mutation/sites.py,
through its command line, on the fixture module scripts/mutation/fixture.
In the fixture's package calc, each site's mutant has a known outcome,
which a comment beside the site gives with its reason; the package shapes
holds one site in each kind of definition, and look-alikes that are not
sites.

The operators and their alternatives are those of #298's acceptance
criteria and of operator set v1 (#275, CONTRIBUTING.md): ROR swaps < and <=,
and > and >=; BOOL swaps true and false; NOT removes a prefix !.

They need python3 and moonc (the toolchain of .moonbit-version).

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
SITES = HERE / "sites.py"

# The sites of calc, from calc/calc.mbt: each one's id, line and column,
# and the outcome that the comment beside it gives.
CALC = [
    ("calc/calc.mbt,in_range,ROR,<=,<,0", 13, 7, "killed"),
    ("calc/calc.mbt,in_range,ROR,<=,<,1", 13, 17, "survived"),
    ("calc/calc.mbt,halve_until,ROR,>,>=,0", 22, 11, "timed out"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,0", 31, 49, "survived"),
    ("calc/calc.mbt,is_blank,NOT,!,,0", 35, 6, "survived"),
    ("calc/calc.mbt,is_blank,BOOL,false,true,0", 41, 14, "killed"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,1", 45, 3, "killed"),
    ("calc/calc.mbt,is_odd,NOT,!,,0", 52, 3, "killed"),
]


def find_sites(root, *paths):
    """What the site finder prints for the paths, as a list of objects."""
    result = subprocess.run([sys.executable, str(SITES), "--root", str(root), *paths],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"sites.py failed ({result.returncode}):\n{result.stderr}")
    return [json.loads(line) for line in result.stdout.splitlines()]


class SitesTest(unittest.TestCase):
    def test_each_site_of_calc_with_its_position(self):
        sites = find_sites(FIXTURE, "calc")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites],
                         [(i, line, column) for i, line, column, _ in CALC])

    def test_a_site_has_the_fields_of_its_id(self):
        site = find_sites(FIXTURE, "calc")[1]
        self.assertEqual(site, {
            "id": "calc/calc.mbt,in_range,ROR,<=,<,1",
            "file": "calc/calc.mbt",
            "definition": "in_range",
            "operator": "ROR",
            "original": "<=",
            "replacement": "<",
            "ordinal": 1,
            "line": 13,
            "column": 17,
            "definition_lines": [8, 14],
        })

    def test_each_kind_of_definition_names_its_sites(self):
        sites = find_sites(FIXTURE, "shapes")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites], [
            ("shapes/shapes.mbt,Span::is_empty,ROR,>,>=,0", 15, 12),
            ("shapes/shapes.mbt,impl Show for Span with output,ROR,<=,<,0", 20, 35),
            ("shapes/shapes.mbt,impl Round with is_round,BOOL,false,true,0", 31, 3),
            ("shapes/shapes.mbt,threshold,NOT,!,,0", 35, 24),
            ("shapes/shapes.mbt,threshold,ROR,>=,>,0", 35, 28),
            ("shapes/shapes.mbt,init,ROR,<,<=,0", 58, 25),
        ])

    def test_tests_generated_files_and_the_test_certificates_have_no_sites(self):
        # In the fixture: calc_test.mbt, calc_wbtest.mbt, the test block of
        # calc.mbt and the generated limits.mbt each hold a comparison.
        self.assertEqual(
            {s["file"] for s in find_sites(FIXTURE, "calc", "calc/calc_test.mbt", "calc/limits.mbt")},
            {"calc/calc.mbt"})
        # In the workspace (#275, Scope): the Unicode data table, the build
        # information, which a build writes, and the test certificates.
        files = {s["file"] for s in find_sites(REPO, "unicode", "buildinfo", "testcerts")}
        self.assertEqual(files - {"unicode/unicode.mbt", "buildinfo/buildinfo.mbt"}, set())
        self.assertIn("unicode/unicode.mbt", files)

    def test_a_file_that_does_not_parse_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "broken.mbt").write_text("///|\nfn broken( -> Int {\n  1 < 2\n}\n")
            result = subprocess.run([sys.executable, str(SITES), "--root", tmp, "broken.mbt"],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("broken.mbt: moonc cannot parse it", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()

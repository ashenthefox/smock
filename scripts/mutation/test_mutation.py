"""Tests of the mutation runner, scripts/mutation/run.py, and of its site
finder, scripts/mutation/sites.py, through their command lines, on the
fixture module scripts/mutation/fixture. In the fixture's package calc,
each site's mutant in the pinned set has a known outcome, which a comment
beside the site gives with its reason, and so does each site of the
package log in both sets; the package shapes holds one site in each kind
of definition, and look-alikes that are not sites; the package forms holds
each form of each operator.

The operators, their alternatives and the pinned rule are those of
operator set v1 (#275, ADR 0006 and CONTRIBUTING.md, "Operator set v1"),
which #299 completes: BODY, ROR, IFC, LCR, NOT, DEL, BOOL, AOR, INT and
STR. The expected sites below are v1's, worked out by hand from those
rules; a change to the rules is a new version, and these tables change
with it. The time limit, 1.25 times the baseline run plus 4 s, is #298's.

In the fixture's package same, each mutant of the pinned set has a known
outcome and a known result of the comparison of the compiler's output,
which compare.py makes before any test runs (#303); a comment beside each
site gives both, with the reasons.

They need python3, git, moon and moonc (the toolchain of .moonbit-version),
and take about half a minute: one mutant of the fixture times out.

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
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
SITES = HERE / "sites.py"
RUN = HERE / "run.py"
VERSION = "v1"

# The sites of calc's pinned set, from calc/calc.mbt: each one's id, line
# and column, and the outcome that the comment beside it gives.
CALC = [
    ("calc/calc.mbt,in_range,BODY,{…},{ false },0", 10, 63, "killed"),
    ("calc/calc.mbt,in_range,ROR,<=,<,0", 17, 7, "killed"),
    ("calc/calc.mbt,in_range,LCR,&&,||,0", 17, 12, "killed"),
    ("calc/calc.mbt,in_range,ROR,<=,<,1", 17, 17, "survived"),
    ("calc/calc.mbt,halve_until,BODY,{…},{ 0 },0", 22, 55, "survived"),
    ("calc/calc.mbt,halve_until,IFC,x > limit,false,0", 29, 9, "killed"),
    ("calc/calc.mbt,halve_until,ROR,>,>=,0", 29, 11, "timed out"),
    ("calc/calc.mbt,halve_until,DEL,x = x / 2,,0", 36, 5, "unviable"),
    ("calc/calc.mbt,halve_until,AOR,/,*,0", 36, 11, "killed"),
    ("calc/calc.mbt,halve_until,INT,2,3,0", 36, 13, "survived"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,0", 44, 49, "survived"),
    ("calc/calc.mbt,is_blank,BODY,{…},{ false },0", 44, 63, "killed"),
    ("calc/calc.mbt,is_blank,IFC,!spaces,false,0", 50, 6, "survived"),
    ("calc/calc.mbt,is_blank,NOT,!,,0", 50, 6, "survived"),
    ("calc/calc.mbt,is_blank,INT,0,1,0", 53, 29, "survived"),
    ("calc/calc.mbt,is_blank,INT,0,-1,0", 53, 29, "survived"),
    ("calc/calc.mbt,is_blank,IFC,c != ' ',false,0", 58, 8, "killed"),
    ("calc/calc.mbt,is_blank,BOOL,false,true,0", 60, 14, "killed"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,1", 64, 3, "killed"),
    ("calc/calc.mbt,is_odd,BODY,{…},{ false },0", 69, 34, "killed"),
    ("calc/calc.mbt,is_odd,NOT,!,,0", 75, 3, "killed"),
    ("calc/calc.mbt,is_odd,INT,2,3,0", 75, 9, "killed"),
    ("calc/calc.mbt,is_odd,INT,2,1,0", 75, 9, "killed"),
    ("calc/calc.mbt,is_odd,INT,0,1,0", 75, 14, "killed"),
    ("calc/calc.mbt,is_odd,INT,0,-1,0", 75, 14, "survived"),
]

# The other alternatives that the full set adds in calc: IFC's other value,
# INT's n-1 and 0 outside a comparison, and 0 in one.
CALC_OTHERS = [
    ("calc/calc.mbt,halve_until,IFC,x > limit,true,0", 29, 9),
    ("calc/calc.mbt,halve_until,INT,2,1,0", 36, 13),
    ("calc/calc.mbt,halve_until,INT,2,0,0", 36, 13),
    ("calc/calc.mbt,is_blank,IFC,!spaces,true,0", 50, 6),
    ("calc/calc.mbt,is_blank,IFC,c != ' ',true,0", 58, 8),
    ("calc/calc.mbt,is_odd,INT,2,0,0", 75, 9),
]

# The sites of log, in the full set: each one's id, whether the pinned set
# takes it, and the outcome that the comment beside it gives.
LOG = [
    ('log/lines.mbt,line,BODY,{…},{ "" },0', True, "killed"),
    ('log/lines.mbt,line,STR,"info: ","_nfo: ",0', True, "killed"),
    ('log/lines.mbt,line,STR,"info: ","",0', False, "killed"),
    ("log/lines.mbt,is_comment,BODY,{…},{ false },0", True, "killed"),
    ('log/lines.mbt,is_comment,STR,"#","_",0', True, "killed"),
    ('log/lines.mbt,is_comment,STR,"#","",0', False, "survived"),
    ('log/lines.mbt,cut_mark,BODY,{…},{ "" },0', True, "killed"),
    ('log/lines.mbt,cut_mark,STR,"~","_",0', True, "survived"),
]

# The mutants of same's pinned set: each one's id, the outcome that the
# comment beside its site gives, and what the comparison of the compiler's
# output found before any test ran (#303).
SAME = [
    ("same/same.mbt,TRACING,BOOL,false,true,0", "killed", "not compared"),
    ("same/same.mbt,total,BODY,{…},{ 0 },0", "killed", "differs"),
    ("same/same.mbt,total,INT,0,1,0", "killed", "differs"),
    # The condition is false already: the mutant shortens its line.
    ("same/same.mbt,total,IFC,TRACING,false,0", "equivalent", "identical"),
    # A call over three lines, deleted: equivalent only because the runner
    # keeps the lines, which a later message names.
    ("same/same.mbt,total,DEL,trace.push(…),,0", "equivalent", "identical"),
    ("same/same.mbt,total,DEL,sum = sum + x,,0", "unviable", None),
    ("same/same.mbt,total,AOR,+,-,0", "killed", "differs"),
    # Its BODY's 0 goes into the caller: the mutant's output has no
    # function of its own for count_a.
    ("same/same.mbt,count_a,BODY,{…},{ 0 },0", "killed", "not compared"),
    ("same/same.mbt,count_a,INT,0,1,0", "killed", "differs"),
    ("same/same.mbt,count_a,IFC,c == 'a',false,0", "killed", "differs"),
    ("same/same.mbt,count_a,DEL,n += 1,,0", "unviable", None),
    ("same/same.mbt,count_a,AOR,+=,-=,0", "killed", "differs"),
    ("same/same.mbt,count_a,INT,1,2,0", "killed", "differs"),
    ("same/same.mbt,count_a_if,BODY,{…},{ 0 },0", "killed", "differs"),
    ("same/same.mbt,count_a_if,IFC,wanted,false,0", "duplicate", "duplicate"),
    ("same/same.mbt,count_a_if,INT,0,1,0", "killed", "differs"),
    ("same/same.mbt,refuse,BODY,{…},{ () },0", "killed", "differs"),
    # An implementation that a public function calls, and one that none
    # does, which the output leaves out.
    ("same/same.mbt,impl Show for Tally with output,BODY,{…},{ () },0", "killed", "differs"),
    ("same/same.mbt,impl Eq for Tally with equal,BODY,{…},{ false },0", "killed", "not compared"),
    ('same/same.mbt,describe,BODY,{…},{ "" },0', "killed", "differs"),
]


def find_sites(root, *paths, chosen=None):
    """What the site finder prints for the paths, as a list of objects:
    the sites and the skipped sites."""
    options = ["--set", chosen] if chosen else []
    result = subprocess.run([sys.executable, str(SITES), "--root", str(root), *options, *paths],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"sites.py failed ({result.returncode}):\n{result.stderr}")
    return [json.loads(line) for line in result.stdout.splitlines()]


def sites_of(lines):
    """The sites among the finder's lines, without the skipped ones."""
    return [s for s in lines if "skipped" not in s]


def table(lines, definitions=None, operator=None):
    """The finder's lines as (id, or the skipped rule with the texts; line;
    whether the pinned set takes it), for some definitions and an
    operator."""
    rows = []
    for s in lines:
        if definitions is not None and s["definition"] not in definitions:
            continue
        if operator is not None and s["operator"] != operator:
            continue
        label = s["id"] if "id" in s else ("skipped", s["skipped"], s["original"], s["replacement"])
        rows.append((label, s["line"], s["pinned"]))
    return rows


class SitesTest(unittest.TestCase):
    def test_each_site_of_calc_with_its_position(self):
        # The pinned set is the default.
        sites = find_sites(FIXTURE, "calc")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites],
                         [(i, line, column) for i, line, column, _ in CALC])
        self.assertEqual(sites, sites_of(sites))

    def test_a_site_has_the_fields_of_its_id(self):
        site = find_sites(FIXTURE, "calc")[3]
        self.assertEqual(site, {
            "id": "calc/calc.mbt,in_range,ROR,<=,<,1",
            "file": "calc/calc.mbt",
            "definition": "in_range",
            "operator": "ROR",
            "original": "<=",
            "replacement": "<",
            "ordinal": 1,
            "line": 17,
            "column": 17,
            "definition_lines": [10, 18],
            "pinned": True,
            "operator_set": VERSION,
        })

    def test_the_full_set_adds_the_other_alternatives_at_each_position(self):
        full = find_sites(FIXTURE, "calc", chosen="full")
        expected = sorted([(i, line, column, True) for i, line, column, _ in CALC]
                          + [(i, line, column, False) for i, line, column in CALC_OTHERS])
        self.assertEqual(sorted((s["id"], s["line"], s["column"], s["pinned"]) for s in full), expected)
        # The pinned set is part of the full set.
        pinned = find_sites(FIXTURE, "calc", chosen="pinned")
        self.assertEqual([s for s in full if s["pinned"]], pinned)

    def test_every_line_names_the_operator_set(self):
        lines = find_sites(FIXTURE, "calc", "forms", "log", "shapes", chosen="full")
        self.assertEqual({s["operator_set"] for s in lines}, {VERSION})

    def test_each_kind_of_definition_names_its_sites(self):
        sites = find_sites(FIXTURE, "shapes")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites
                          if s["operator"] in ("ROR", "BOOL", "NOT")], [
            ("shapes/shapes.mbt,Span::is_empty,ROR,>,>=,0", 15, 12),
            ("shapes/shapes.mbt,impl Show for Span with output,ROR,<=,<,0", 20, 35),
            ("shapes/shapes.mbt,impl Round with is_round,BOOL,false,true,0", 31, 3),
            ("shapes/shapes.mbt,threshold,NOT,!,,0", 35, 24),
            ("shapes/shapes.mbt,threshold,ROR,>=,>,0", 35, 28),
            ("shapes/shapes.mbt,init,ROR,<,<=,0", 58, 25),
        ])
        # BODY: a method, an implementation of a core trait, whose return
        # type, not written, is the trait's, and a trait's default
        # implementation, whose trait is the program's own.
        self.assertEqual(table(sites, operator="BODY"), [
            ("shapes/shapes.mbt,Span::is_empty,BODY,{…},{ false },0", 14, True),
            ("shapes/shapes.mbt,impl Show for Span with output,BODY,{…},{ () },0", 19, True),
            (("skipped", "no default", "{\n  false\n}", ""), 30, True),
            ("shapes/shapes.mbt,look_alikes,BODY,{…},{ 0 },0", 40, True),
        ])

    def test_tests_generated_files_and_the_test_certificates_have_no_sites(self):
        # In the fixture: calc_test.mbt, calc_wbtest.mbt, the test block of
        # calc.mbt and the generated limits.mbt each hold a comparison.
        self.assertEqual(
            {s["file"] for s in find_sites(FIXTURE, "calc", "calc/calc_test.mbt", "calc/limits.mbt", chosen="full")},
            {"calc/calc.mbt"})
        # In the workspace (#275, Scope): the Unicode data table, the build
        # information, which a build writes, and the test certificates.
        files = {s["file"] for s in find_sites(REPO, "unicode", "buildinfo", "testcerts", chosen="full")}
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


class OperatorsTest(unittest.TestCase):
    """Each form of each operator of v1, in the full set, with whether the
    pinned set takes each alternative, from the package forms."""

    @classmethod
    def setUpClass(cls):
        cls.lines = find_sites(FIXTURE, "forms/operators.mbt", chosen="full")

    def test_body_replaces_a_body_with_its_return_types_default(self):
        f = "forms/operators.mbt,"
        self.assertEqual(table(self.lines, operator="BODY"), [
            (f + "body_unit,BODY,{…},{ () },0", 15, True),
            (f + "body_int64,BODY,{…},{ 0 },0", 21, True),
            (f + 'body_string,BODY,{…},{ "" },0', 26, True),
            (f + "body_option,BODY,{…},{ None },0", 31, True),
            (f + "body_array,BODY,{…},{ [] },0", 36, True),
            (f + "body_tuple,BODY,{…},{ (0\\, false\\, '\\\\u{0}') },0", 41, True),
            (f + 'body_result,BODY,{…},{ Ok("") },0', 46, True),
            # No default: a type parameter, a type of the program's own,
            # and a tuple that holds one.
            (("skipped", "no default", "{\n  x\n}", ""), 53, True),
            (("skipped", "no default", "{\n  { x, }\n}", ""), 58, True),
            (("skipped", "no default", "{\n  (x, { x, })\n}", ""), 63, True),
            # body_already and body_empty already are the default: no site.
            (("skipped", "FFI", 'pub extern "js" fn body_foreign(fd : Int32) -> Int32 = "(fd) => fd"', ""), 80, True),
            (f + "impl Eq for Point with equal,BODY,{…},{ false },0", 84, True),
            (f + "conditions,BODY,{…},{ 0 },0", 92, True),
            (f + "logic,BODY,{…},{ false },0", 120, True),
            (f + 'arithmetic,BODY,{…},{ "" },0', 130, True),
            (f + "integers,BODY,{…},{ () },0", 145, True),
            (f + "statements,BODY,{…},{ () },0", 165, True),
            (f + "values,BODY,{…},{ 0 },0", 188, True),
            (f + "only,BODY,{…},{ () },0", 194, True),
            (f + "yes,BODY,{…},{ false },0", 200, True),
            (f + "one,BODY,{…},{ 0 },0", 205, True),
        ])

    def test_ifc_forces_each_kind_of_condition(self):
        f = "forms/operators.mbt,conditions,IFC,"
        self.assertEqual(table(self.lines, ["conditions"], "IFC"), [
            (f + "p.x > 0,false,0", 93, True), (f + "p.x > 0,true,0", 93, False),
            (f + "p.x < -5,false,0", 95, True), (f + "p.x < -5,true,0", 95, False),
            (f + "p.x > 3,false,0", 98, True), (f + "p.x > 3,true,0", 98, False),
            (f + "i < p.x,false,0", 101, True), (f + "i < p.x,true,0", 101, False),
            # A guard statement: its else never runs when it is true.
            (f + "p.x != 7,true,0", 104, True), (f + "p.x != 7,false,0", 104, False),
            (f + "o is Some(_),true,0", 105, True), (f + "o is Some(_),false,0", 105, False),
            # A condition that binds a name is forced to false with `false
            # && (...)`, which keeps the name bound where the body uses it;
            # forced to true, the name would be unbound, so that is skipped.
            (f + "o is Some(v),false && (o is Some(v)),0", 106, True),
            (("skipped", "binds a name", "o is Some(v)", "true"), 106, False),
            # `while true` (109): BOOL's mutant is IFC's false, and true is
            # the condition itself, so IFC has no site there.
            (f + "n > 9,false,0", 113, True), (f + "n > 9,true,0", 113, False),
        ])

    def test_ifc_forces_a_guard_that_binds_a_name_only_to_false(self):
        # The pinned set's true would leave `v` unbound after the guard.
        self.assertEqual(table(self.lines, ["logic"], "IFC"), [
            ("forms/operators.mbt,logic,IFC,o is Some(v) && v > 0,false && (o is Some(v) && v > 0),0", 121, True),
            (("skipped", "binds a name", "o is Some(v) && v > 0", "true"), 121, False),
        ])
        guards = find_sites(FIXTURE, "forms/operators.mbt", chosen="full")
        self.assertEqual(table(guards, ["conditions"], "IFC")[10:12], [
            ("forms/operators.mbt,conditions,IFC,o is Some(_),true,0", 105, True),
            ("forms/operators.mbt,conditions,IFC,o is Some(_),false,0", 105, False),
        ])

    def test_lcr_swaps_and_and_or(self):
        f = "forms/operators.mbt,logic,LCR,"
        self.assertEqual(table(self.lines, ["logic"], "LCR"), [
            (("skipped", "binds a name", "&&", "||"), 121, True),
            (f + "&&,||,0", 124, True),
            (f + "||,&&,0", 124, True),
        ])

    def test_aor_swaps_arithmetic_and_compound_assignments(self):
        f = "forms/operators.mbt,arithmetic,AOR,"
        self.assertEqual(table(self.lines, ["arithmetic"], "AOR"), [
            # `%` is not AOR's.
            (f + "+,-,0", 131, True), (f + "-,+,0", 131, True), (f + "*,/,0", 131, True), (f + "/,*,0", 131, True),
            (f + "+=,-=,0", 132, True), (f + "-=,+=,0", 133, True), (f + "*=,/=,0", 134, True),
            (f + "/=,*=,0", 135, True),
            # To a field, and to an element.
            (f + "+=,-=,1", 136, True), (f + "*=,/=,1", 137, True),
            (("skipped", "string operand", "+", "-"), 138, True),
            (("skipped", "string operand", "+", "-"), 138, True),
        ])

    def test_int_takes_n_plus_one_and_n_minus_one_in_a_comparison_or_an_index(self):
        f = "forms/operators.mbt,integers,INT,"
        self.assertEqual(table(self.lines, ["integers"], "INT"), [
            # A comparison.
            (f + "10,11,0", 146, True), (f + "10,9,0", 146, True), (f + "10,0,0", 146, False),
            # Through arithmetic: n-1 of 1 is 0, one alternative.
            (f + "1,2,0", 147, True), (f + "1,0,0", 147, True),
            (f + "0,1,0", 147, True), (f + "0,-1,0", 147, True),
            # An index, a slice, and the index of a compound assignment.
            (f + "2,3,0", 148, True), (f + "2,1,0", 148, True), (f + "2,0,0", 148, False),
            (f + "1,2,1", 149, True), (f + "1,0,1", 149, True),
            (f + "3,4,0", 150, True), (f + "3,2,0", 150, True), (f + "3,0,0", 150, False),
            # Elsewhere: the value assigned, and a call's argument.
            (f + "4,5,0", 150, True), (f + "4,3,0", 150, False), (f + "4,0,0", 150, False),
            (f + "5,6,0", 151, True), (f + "5,4,0", 151, False), (f + "5,0,0", 151, False),
            # n+1 does not fit an Int, so the pinned set takes n-1.
            (f + "2147483647,2147483646,0", 152, True), (f + "2147483647,0,0", 152, False),
            # n-1 does not fit a UInt.
            (f + "0U,1U,0", 153, True),
            (f + "-1,0,0", 154, True), (f + "-1,-2,0", 154, False),
            # The base, the case of the digits and the suffix are kept.
            (f + "0xFFL,0x100L,0", 155, True), (f + "0xFFL,0xFEL,0", 155, False), (f + "0xFFL,0x0L,0", 155, False),
            (f + "1,2,2", 156, True), (f + "1,0,2", 156, False),
            # The pattern 6 (158) is no site.
        ])

    def test_del_deletes_calls_and_assignments(self):
        f = "forms/operators.mbt,"
        self.assertEqual(table(self.lines, ["statements", "values", "only"], "DEL"), [
            (f + "statements,DEL,n = 1,,0", 167, True),
            (f + "statements,DEL,n += 2,,0", 168, True),
            (f + "statements,DEL,p.x = 3,,0", 169, True),
            (f + "statements,DEL,xs[0] = n,,0", 170, True),
            (f + "statements,DEL,xs[1] -= 5,,0", 171, True),
            (f + "statements,DEL,xs.push(6),,0", 172, True),
            (f + "statements,DEL,ignore(n),,0", 173, True),
            (f + "statements,DEL,n |> ignore,,0", 174, True),
            # The last statement of an if's body without an else, and of a
            # loop's body; not a branch of an if with an else (178).
            (f + "statements,DEL,xs.clear(),,0", 176, True),
            (f + "statements,DEL,ignore(x),,0", 180, True),
            # The last statement of a function's body that returns Unit.
            (f + "statements,DEL,xs.push(m),,0", 182, True),
            # Not the value of values' body (190), nor only's one statement,
            # whose BODY site makes the same mutant.
            (f + "values,DEL,xs.push(8),,0", 189, True),
        ])

    def test_two_sites_that_make_the_same_mutant_are_one(self):
        # BODY's `{ false }` is BOOL's `false`, and BODY's `{ 0 }` is INT's 0.
        self.assertEqual(table(self.lines, ["yes", "one"]), [
            ("forms/operators.mbt,yes,BODY,{…},{ false },0", 200, True),
            ("forms/operators.mbt,one,BODY,{…},{ 0 },0", 205, True),
            ("forms/operators.mbt,one,INT,1,2,0", 206, True),
        ])
        # IFC's false at `while true` is BOOL's.
        self.assertEqual([(s["operator"], s["replacement"]) for s in self.lines if s["line"] == 109],
                         [("BOOL", "false")])


class StringsTest(unittest.TestCase):
    """STR: each form of a string literal, inside STR's scope and outside."""

    def test_str_changes_the_first_character_of_each_form(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "server").mkdir()
            shutil.copy(FIXTURE / "forms" / "strings.mbt", Path(tmp) / "server" / "strings.mbt")
            lines = find_sites(tmp, "server", chosen="full")
        f = "server/strings.mbt,strings,STR,"
        self.assertEqual(table(lines, operator="STR"), [
            (f + '"ab","_b",0', 11, True), (f + '"ab","",0', 11, False),
            (f + '"_b","-b",0', 12, True), (f + '"_b","",0', 12, False),
            (f + '"","_",0', 13, True),
            # An escape is one character, and it stands for one: `\u{5F}` is `_`.
            (f + r'"\\tb","_b",0', 14, True), (f + r'"\\tb","",0', 14, False),
            (f + r'"\\u{5F}b","-b",0', 15, True), (f + r'"\\u{5F}b","",0', 15, False),
            # The first character outside any interpolation, or none.
            (f + r'"\\{x}b","\\{x}_",0', 16, True), (f + r'"\\{x}b","",0', 16, False),
            (f + r'"\\{x}","_\\{x}",0', 17, True), (f + r'"\\{x}","",0', 17, False),
            (f + 'b"ab",b"_b",0', 18, True), (f + 'b"ab",b"",0', 18, False),
            # A character literal (19) is no site; nor is the pattern (31).
            # Over several lines, the id writes the first and the last line.
            (f + '#|ab…#|cd,#|_b…#|cd,0', 21, True), (f + '#|ab…#|cd,"",0', 21, False),
            (f + '#|…#|cd,#|…#|_d,0', 24, True), (f + '#|…#|cd,"",0', 24, False),
            (f + r'$|\\{x}ab,$|\\{x}_b,0', 27, True), (f + r'$|\\{x}ab,"",0', 27, False),
            # A map literal's key.
            (f + '"k","_",0', 29, True), (f + '"k","",0', 29, False),
            # BODY's `{ "" }` is the empty literal's mutant.
            ('server/strings.mbt,name,STR,"ab","_b",0', 40, True),
        ])
        self.assertEqual(
            [s["replacement"] for s in lines if s["line"] == 21 and s["pinned"] and s["operator"] == "STR"],
            ["#|_b\n    #|cd"])

    def test_outside_strs_scope_each_string_is_a_skipped_site(self):
        inside = {(s["line"], s["original"], s["replacement"], s["pinned"])
                  for s in find_sites(FIXTURE, "forms/strings.mbt", chosen="full") if s["operator"] == "STR"}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "server").mkdir()
            shutil.copy(FIXTURE / "forms" / "strings.mbt", Path(tmp) / "server" / "strings.mbt")
            copied = [s for s in find_sites(tmp, "server", chosen="full") if s["operator"] == "STR"]
        self.assertEqual(inside, {(s["line"], s["original"], s["replacement"], s["pinned"]) for s in copied})
        outside = [s for s in find_sites(FIXTURE, "forms/strings.mbt", chosen="full") if s["operator"] == "STR"]
        self.assertEqual({s.get("skipped") for s in outside}, {"outside scope"})

    def test_strs_scope_holds_the_protocol_packages_server_and_logs_writers(self):
        # In the fixture: log/target.mbt, as smock's reader of request
        # targets, is outside STR's scope; the rest of log is inside.
        lines = find_sites(FIXTURE, "log", chosen="full")
        self.assertEqual({(s["file"], s.get("skipped")) for s in lines if s["operator"] == "STR"},
                         {("log/lines.mbt", None), ("log/target.mbt", "outside scope")})
        self.assertEqual(table(lines), [
            ('log/lines.mbt,line,BODY,{…},{ "" },0', 9, True),
            ('log/lines.mbt,line,STR,"info: ","_nfo: ",0', 14, True),
            ('log/lines.mbt,line,STR,"info: ","",0', 14, False),
            (("skipped", "string operand", "+", "-"), 14, True),
            ("log/lines.mbt,is_comment,BODY,{…},{ false },0", 19, True),
            ('log/lines.mbt,is_comment,STR,"#","_",0', 24, True),
            ('log/lines.mbt,is_comment,STR,"#","",0', 24, False),
            ('log/lines.mbt,cut_mark,BODY,{…},{ "" },0', 29, True),
            ('log/lines.mbt,cut_mark,STR,"~","_",0', 34, True),
            (("skipped", "outside scope", '"/"', '"_"'), 7, True),
            (("skipped", "outside scope", '"/"', '""'), 7, False),
        ])
        # In the workspace: log's line and envelope writers are inside, its
        # reader of request targets is outside (its strings are all in doc
        # comments today, so it has no STR site at all), and so is usage.
        repo = find_sites(REPO, "log", "usage", chosen="full")
        scoped = {}
        for s in repo:
            if s["operator"] == "STR":
                scoped.setdefault(s["file"], set()).add(s.get("skipped"))
        self.assertNotIn(None, scoped.get("log/target.mbt", set()))
        for file in ("log/log.mbt", "log/envelope.mbt", "log/mockoon.mbt"):
            self.assertEqual(scoped.get(file), {None}, file)
        self.assertEqual(scoped.get("usage/usage.mbt"), {"outside scope"})


def logging_moon(directory, fail_build_when=None):
    """A moon that logs each of its command lines and runs the real one."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / "moon"
    log = directory / "moon.log"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


class RunnerTest(unittest.TestCase):
    """One run of calc's pinned set, the default, which the tests read, and
    runs of one mutant alone, in the same work directory."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "all"
        cls.result = cls.run_runner(cls.out, "calc")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_runner(cls, out, *args):
        return subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(out),
             "--moon", str(cls.moon), *args],
            capture_output=True, text=True)

    def test_each_mutant_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["outcome"]) for r in self.records],
                         [(i, outcome) for i, _, _, outcome in CALC])

    def test_a_record_names_the_tests_that_killed_its_mutant(self):
        killed = {r["id"]: [t["name"] for t in r["killing_tests"]] for r in self.records}
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,0"], ["a number at the low end is in range"])
        self.assertEqual(killed["calc/calc.mbt,is_odd,NOT,!,,0"], ["3 is odd"])
        self.assertEqual(killed["calc/calc.mbt,in_range,LCR,&&,||,0"], ["a number below the range is not in it"])
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,1"], [])

    def test_a_record_gives_the_backend_the_timings_the_set_and_the_operator_set(self):
        for record in self.records:
            self.assertEqual(record["backend"], "wasm-gc")
            self.assertEqual(record["package"], "mutation/fixture/calc")
            self.assertEqual((record["operator_set"], record["set"], record["pinned"]), (VERSION, "pinned", True))
            timings = record["timings"]
            self.assertGreater(timings["build_s"], 0)
            # An unviable mutant never runs.
            if record["outcome"] == "unviable":
                self.assertEqual(timings["run_s"], 0)
            else:
                self.assertGreater(timings["run_s"], 0)
        summary = json.loads((self.out / "summary.json").read_text())["packages"][0]
        limit = 1.25 * summary["baseline"]["run_s"] + 4
        timed_out = next(r for r in self.records if r["outcome"] == "timed out")
        self.assertAlmostEqual(timed_out["timings"]["limit_s"], limit, places=2)
        self.assertGreaterEqual(timed_out["timings"]["run_s"], limit)

    def test_a_mutant_that_does_not_compile_is_unviable(self):
        # DEL of `x = x / 2` leaves a `let mut` that is never changed, which
        # the compiler refuses.
        record = next(r for r in self.records if r["id"] == "calc/calc.mbt,halve_until,DEL,x = x / 2,,0")
        self.assertEqual(record["outcome"], "unviable")
        self.assertIn("never used", record["message"])

    def test_the_summary_counts_each_outcome_of_the_package(self):
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertEqual((summary["operator_set"], summary["set"]), (VERSION, "pinned"))
        self.assertEqual(len(summary["packages"]), 1)
        package = summary["packages"][0]
        self.assertEqual(package["package"], "mutation/fixture/calc")
        self.assertEqual(package["backend"], "wasm-gc")
        self.assertEqual(
            {k: package[k] for k in ("sites", "positions", "mutants", "killed", "timed_out", "survived", "unviable")},
            {"sites": 25, "positions": 22, "mutants": 25, "killed": 14, "timed_out": 1, "survived": 9,
             "unviable": 1})
        self.assertEqual(package["baseline"]["tests"], 7)
        # Both sets' counts; calc has no skipped site.
        self.assertEqual(package["sets"], {
            "pinned": {"sites": 25, "positions": 22, "skipped": {}},
            "full": {"sites": 31, "positions": 22, "skipped": {}},
        })

    def test_the_report_shows_each_survivor_with_its_definition(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("Operator set v1, the pinned set.", report)
        self.assertIn("| pinned | 25 | 22 |\n| full | 31 | 22 |", report)
        self.assertIn("calc/calc.mbt,is_blank,NOT,!,,0", report)
        self.assertIn("calc/calc.mbt,is_blank,BOOL,true,false,0", report)
        self.assertIn(
            "@@ -10,9 +10,9 @@ in_range\n"
            " pub fn in_range(n : Int32, low : Int32, high : Int32) -> Bool {\n",
            report)
        self.assertIn("-  low <= n && n <= high\n+  low <= n && n < high\n }\n", report)
        # The time-out is listed apart, and no killed mutant is shown.
        self.assertIn("calc/calc.mbt,halve_until,ROR,>,>=,0", report)
        self.assertNotIn("calc/calc.mbt,is_odd,NOT,!,,0", report)
        # The run prints the report.
        self.assertIn("-  low <= n && n <= high\n+  low <= n && n < high\n", self.result.stdout)

    def test_the_runner_never_passes_u(self):
        # in_range's first mutant is killed by a snapshot alone, which -u
        # would rewrite: it would then survive.
        lines = self.log.read_text().splitlines()
        self.assertTrue(lines)
        for line in lines:
            self.assertNotIn("--update", line.split())
            self.assertNotIn("-u", line.split())
        self.assertEqual((self.work / "tree-0" / "calc" / "calc_test.mbt").read_text(),
                         (FIXTURE / "calc" / "calc_test.mbt").read_text())

    def test_one_mutant_runs_alone_by_its_id(self):
        # Among two packages: shapes holds none of the ids, so it is not run.
        out = self.tmp / "one"
        result = self.run_runner(out, "--mutant", "calc/calc.mbt,is_odd,NOT,!,,0", "calc", "shapes")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [("calc/calc.mbt,is_odd,NOT,!,,0", "killed")])
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual([(p["package"], p["mutants"]) for p in summary["packages"]], [("mutation/fixture/calc", 1)])

    def test_an_unknown_id_fails(self):
        result = self.run_runner(self.tmp / "unknown", "--mutant", "calc/calc.mbt,is_odd,NOT,!,,9", "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no site of calc in the pinned set has the id calc/calc.mbt,is_odd,NOT,!,,9", result.stderr)

    def test_an_id_of_the_full_set_alone_is_not_in_the_pinned_set(self):
        result = self.run_runner(self.tmp / "other", "--mutant", "calc/calc.mbt,is_odd,INT,2,0,0", "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no site of calc in the pinned set has the id calc/calc.mbt,is_odd,INT,2,0,0", result.stderr)

    def test_a_mutant_that_does_not_build_is_unviable_and_never_runs(self):
        # A finder that gives one site whose replacement does not parse.
        # Were the build's exit status not checked, the tests would run the
        # binary of the last build, the baseline's, and pass.
        site = {"id": "calc/calc.mbt,in_range,ROR,<=,<=<,0", "file": "calc/calc.mbt", "definition": "in_range",
                "operator": "ROR", "original": "<=", "replacement": "<=<", "ordinal": 0,
                "line": 17, "column": 17, "definition_lines": [10, 18], "pinned": True, "operator_set": VERSION}
        finder = self.tmp / "finder"
        finder.write_text(f"#!/bin/sh\necho '{json.dumps(site)}'\n")
        finder.chmod(finder.stat().st_mode | stat.S_IXUSR)
        out = self.tmp / "unviable"
        before = len(self.log.read_text().splitlines())
        result = self.run_runner(out, "--finder", str(finder), "calc")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [(site["id"], "unviable")])
        self.assertIn("Parse error", records[0]["message"])
        summary = json.loads((out / "summary.json").read_text())["packages"][0]
        self.assertEqual((summary["unviable"], summary["killed"], summary["survived"]), (1, 0, 0))
        # The last thing the run did was the failed build.
        self.assertIn("--build-only", self.log.read_text().splitlines()[-1].split())
        self.assertGreater(len(self.log.read_text().splitlines()), before)

    def test_a_finder_line_without_an_operator_set_fails(self):
        site = {"id": "calc/calc.mbt,in_range,ROR,<=,<,1", "file": "calc/calc.mbt", "definition": "in_range",
                "operator": "ROR", "original": "<=", "replacement": "<", "ordinal": 1,
                "line": 17, "column": 17, "definition_lines": [10, 18], "pinned": True}
        finder = self.tmp / "unversioned"
        finder.write_text(f"#!/bin/sh\necho '{json.dumps(site)}'\n")
        finder.chmod(finder.stat().st_mode | stat.S_IXUSR)
        result = self.run_runner(self.tmp / "unversioned-out", "--finder", str(finder), "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("do not name one operator set", result.stderr)


class FullSetTest(unittest.TestCase):
    """One run of log's full set, and a count of forms' sites without a
    run."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-full-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "full"
        cls.result = cls.run_runner(cls.out, "--set", "full", "log")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_runner(cls, out, *args):
        return subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(out),
             "--moon", str(cls.moon), *args],
            capture_output=True, text=True)

    def test_each_mutant_of_the_full_set_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["pinned"], r["outcome"]) for r in self.records], LOG)
        self.assertEqual({(r["set"], r["operator_set"]) for r in self.records}, {("full", VERSION)})

    def test_the_summary_counts_the_pinned_and_the_other_alternatives_apart(self):
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertEqual((summary["operator_set"], summary["set"]), (VERSION, "full"))
        package = summary["packages"][0]
        self.assertEqual({k: package[k] for k in ("sites", "positions", "mutants", "killed", "survived")},
                         {"sites": 8, "positions": 6, "mutants": 8, "killed": 6, "survived": 2})
        self.assertEqual({k: package["pinned"][k] for k in ("mutants", "killed", "survived")},
                         {"mutants": 6, "killed": 5, "survived": 1})
        self.assertEqual({k: package["other"][k] for k in ("mutants", "killed", "survived")},
                         {"mutants": 2, "killed": 1, "survived": 1})
        self.assertEqual(package["skipped"], {"AOR string operand": 1, "STR outside scope": 2})
        self.assertEqual(package["sets"]["pinned"],
                         {"sites": 6, "positions": 6, "skipped": {"AOR string operand": 1, "STR outside scope": 1}})

    def test_the_report_lists_the_survivors_at_the_other_alternatives_apart(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("Operator set v1, the full set.", report)
        self.assertIn("Sites skipped in this set: AOR string operand 1, STR outside scope 2.", report)
        pinned = report.index("### Survivors at the pinned alternatives (1)")
        other = report.index("### Survivors at the other alternatives (1)")
        self.assertLess(pinned, report.index('log/lines.mbt,cut_mark,STR,"~","_",0'), other)
        self.assertGreater(report.index('log/lines.mbt,is_comment,STR,"#","",0'), other)

    def test_a_count_of_sites_runs_no_mutant(self):
        before = self.log.read_text()
        out = self.tmp / "count"
        result = self.run_runner(out, "--sites-only", "forms")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(), before)
        self.assertEqual((out / "mutants.jsonl").read_text(), "")
        package = json.loads((out / "summary.json").read_text())["packages"][0]
        self.assertEqual(package["sets"]["full"]["skipped"], {
            "AOR string operand": 2, "BODY FFI": 1, "BODY no default": 3, "IFC binds a name": 2,
            "LCR binds a name": 1, "STR outside scope": 28})
        self.assertEqual(package["sets"]["pinned"]["skipped"], {
            "AOR string operand": 2, "BODY FFI": 1, "BODY no default": 3,
            "LCR binds a name": 1, "STR outside scope": 15})
        report = (out / "report.md").read_text()
        self.assertIn("## mutation/fixture/forms", report)
        self.assertIn("Sites skipped in this set: AOR string operand 2, BODY FFI 1, BODY no default 3,"
                      " LCR binds a name 1, STR outside scope 15.", report)


class OutputNamesTest(unittest.TestCase):
    """The compiler numbers its locals, labels and closures in the order it
    makes them, and a closure's name holds the line of its definition: the
    comparison replaces every name of the output, and keeps its text."""

    # A closure at line 30, in moonc's WAT, and a SourceLoc that the program
    # holds as text.
    OUTPUT = """(func $_M0FP38mutation7fixture4same5totalC12l30 (param $_M0L1yS3 i32) (result i32)
 (loop $loop:4 (result i32)
  (i32.add (local.get $_M0L1yS3) (call $_M0FP38mutation7fixture4same4next (i32.const 1)))))
(data $moonbit.const_data "s\\00a\\00m\\00e\\00:\\003\\000\\00")"""

    def test_names_that_differ_alone_compare_alike(self):
        import compare
        moved = (self.OUTPUT.replace("C12l30", "C14l31").replace("S3", "S5").replace("$loop:4", "$loop:9"))
        self.assertNotEqual(moved, self.OUTPUT)
        self.assertEqual(compare.digest(moved), compare.digest(self.OUTPUT))

    def test_text_and_the_names_pattern_of_use_still_differ(self):
        import compare
        # The program's own text, here the line of a SourceLoc.
        self.assertNotEqual(compare.digest(self.OUTPUT.replace("\\003\\000", "\\003\\001")),
                            compare.digest(self.OUTPUT))
        # Two functions that were one.
        call = "$_M0FP38mutation7fixture4same4next"
        self.assertNotEqual(compare.digest(self.OUTPUT.replace(call, "$_M0FP38mutation7fixture4same5totalC12l30")),
                            compare.digest(self.OUTPUT))


class CompilerOutputTest(unittest.TestCase):
    """One run of same's pinned set, whose mutants the compiler's output
    judges before any test runs (#303)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-same-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "same"
        cls.result = subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(cls.out),
             "--moon", str(cls.moon), "same"],
            capture_output=True, text=True)
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_mutant_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["outcome"], r.get("compiler_output", {}).get("result")) for r in self.records],
                         SAME)

    def test_an_equivalent_mutant_or_a_duplicate_runs_no_tests(self):
        runs = [line for line in self.log.read_text().splitlines() if "--test-failure-json" in line.split()]
        # The run without a mutant, and each mutant that compiled and was
        # neither equivalent nor a duplicate.
        ran = [i for i, outcome, _ in SAME if outcome not in ("unviable", "equivalent", "duplicate")]
        self.assertEqual(len(runs), 1 + len(ran))
        for record in self.records:
            if record["outcome"] in ("equivalent", "duplicate"):
                self.assertEqual((record["killing_tests"], record["timings"]["run_s"]), ([], 0), record["id"])
                self.assertGreater(record["timings"]["compare_s"], 0)

    def test_a_duplicate_names_the_first_mutant_that_compiled_alike(self):
        duplicate = next(r for r in self.records if r["outcome"] == "duplicate")
        self.assertEqual(duplicate["duplicate_of"], "same/same.mbt,count_a_if,BODY,{…},{ 0 },0")
        # Both compiled alike, and unlike the package without a mutant.
        first = next(r for r in self.records if r["id"] == duplicate["duplicate_of"])
        self.assertEqual(duplicate["compiler_output"]["digest"], first["compiler_output"]["digest"])
        equivalent = next(r for r in self.records if r["outcome"] == "equivalent")
        self.assertNotEqual(first["compiler_output"]["digest"], equivalent["compiler_output"]["digest"])

    def test_a_mutant_the_output_does_not_hold_is_not_compared(self):
        reasons = {r["id"]: r["compiler_output"]["reason"] for r in self.records
                   if r.get("compiler_output", {}).get("result") == "not compared"}
        self.assertEqual(reasons, {
            "same/same.mbt,TRACING,BOOL,false,true,0":
                "the output has no function of its own for TRACING",
            "same/same.mbt,count_a,BODY,{…},{ 0 },0":
                "the mutant's output has no function of its own for count_a",
            "same/same.mbt,impl Eq for Tally with equal,BODY,{…},{ false },0":
                "the output has no function of its own for impl Eq for Tally with equal",
        })

    def test_the_summary_counts_them_apart(self):
        package = json.loads((self.out / "summary.json").read_text())["packages"][0]
        self.assertEqual(
            {k: package[k] for k in ("mutants", "killed", "timed_out", "survived", "unviable", "equivalent",
                                     "duplicate", "not_compared")},
            {"mutants": 20, "killed": 15, "timed_out": 0, "survived": 0, "unviable": 2, "equivalent": 2,
             "duplicate": 1, "not_compared": 3})
        # Neither counts as killed nor as survived.
        self.assertEqual(package["score"], 1.0)

    def test_the_report_counts_and_lists_them(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("By the compiler's output: 2 equivalent and 1 duplicate, which ran no tests;"
                      " 15 mutants compared, 3 not compared.", report)
        self.assertIn("### Equivalent by the compiler's output (2)\n\n"
                      "- `same/same.mbt,total,IFC,TRACING,false,0`\n"
                      "- `same/same.mbt,total,DEL,trace.push(…),,0`\n", report)
        self.assertIn("### Duplicates by the compiler's output (1)\n\n"
                      "- `same/same.mbt,count_a_if,IFC,wanted,false,0`, as"
                      " `same/same.mbt,count_a_if,BODY,{…},{ 0 },0` (killed)\n", report)


if __name__ == "__main__":
    unittest.main()

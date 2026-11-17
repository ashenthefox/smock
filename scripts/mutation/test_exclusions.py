"""Tests of the exclusion list (scripts/mutation/exclusions.py), through
its command line, on small trees in temporary directories: copies of the
coverage report's small source tree (scripts/coverage-tests/tree) and of
the fixture package calc.

The rules come from the ticket of the list (#302), the spec's
"Exclusions" (#275) and ADR 0006, which CONTRIBUTING.md, "Exclusions",
states: an entry names a mutant by its id, or a point by its file,
definition and position in it, and gives a category, a reason and the
reviewer. The categories are EQUIVALENT, ARID, UNREACHABLE, FAULT,
UB-NATIVE and DEFERRED; an entry in another category, or without what its
category needs, fails the check: an EQUIVALENT entry records the
comparison of the compiler's output and the adversarial attempt (the
agent context that made it and the tests it tried, which passed);
UNREACHABLE holds an arm that an invariant guards with an abort, or
carries a written argument; DEFERRED carries an issue number. An entry
goes stale when the text of its definition changes.

They need python3, git and moonc (the toolchain of .moonbit-version):
staleness reads the definitions with the site finder's parser.

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
EXCLUSIONS = HERE / "exclusions.py"
TREE = REPO / "scripts" / "coverage-tests" / "tree"
CALC = HERE / "fixture" / "calc" / "calc.mbt"

# The uncovered point of the small tree's report partly.bisect: the then
# arm's abort of Generator::below, at line 16, column 19, of prng.mbt.
ABORT = "prng/prng.mbt:16:19"
# A mutant of calc that survives its tests: NOT, `!spaces` to `spaces`.
NOT = "calc/calc.mbt,is_blank,NOT,!,,0"


def need_moonc():
    if shutil.which("moonc") is None:
        raise unittest.SkipTest("moonc is not on PATH")


class Tree:
    """A small tree: the coverage report's source tree, and calc's source,
    with an exclusion list at its root."""

    def __init__(self, tmp):
        self.root = tmp / "tree"
        shutil.copytree(TREE, self.root)
        (self.root / "calc").mkdir()
        shutil.copy(CALC, self.root / "calc" / "calc.mbt")

    def run(self, *args):
        return subprocess.run([sys.executable, str(EXCLUSIONS), "--root", str(self.root), *args],
                              capture_output=True, text=True)

    def new(self, what):
        """The stanza that `new` prints for a point or a mutant."""
        result = self.run("new", what)
        if result.returncode != 0:
            raise AssertionError(f"new {what} failed ({result.returncode}):\n{result.stderr}")
        return result.stdout

    def write(self, *stanzas):
        """Writes the exclusion list, of the stanzas given."""
        (self.root / "exclusions.toml").write_text("# A test's list.\n\n" + "\n".join(stanzas))

    def edit(self, path, old, new):
        """Replaces the one occurrence of old in a file of the tree."""
        file = self.root / path
        text = file.read_text()
        if text.count(old) != 1:
            raise AssertionError(f"{path} does not hold {old!r} once")
        file.write_text(text.replace(old, new))


def filled(stanza, **fields):
    """A stanza that `new` printed, with fields set: each `<name> = ""`
    that it holds takes the value given, as TOML, and any other is added."""
    lines = stanza.rstrip("\n").split("\n")
    for name, value in fields.items():
        line = f"{name} = {value}"
        at = next((i for i, l in enumerate(lines) if l.startswith(f"{name} = ")), None)
        if at is None:
            lines.append(line)
        else:
            lines[at] = line
    return "\n".join(lines) + "\n"


class NewTest(unittest.TestCase):
    """`new` prints the stanza of a new entry, with the definition's text
    as it is now, for the author to fill in."""

    def setUp(self):
        need_moonc()
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.tree = Tree(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_point_is_named_by_its_file_definition_and_position_in_it(self):
        stanza = self.tree.new(ABORT)
        # Generator::below starts at line 15, so line 16 is its second.
        self.assertIn('file = "prng/prng.mbt"\n', stanza)
        self.assertIn('definition = "Generator::below"\n', stanza)
        self.assertIn('position = "2:19"\n', stanza)
        self.assertRegex(stanza, r'\ntext = "[0-9a-f]{16}"\n')
        for field in ("category", "reason", "reviewer"):
            self.assertIn(f'\n{field} = ""\n', stanza)

    def test_a_mutant_is_named_by_its_id(self):
        stanza = self.tree.new(NOT)
        self.assertIn('mutant = "calc/calc.mbt,is_blank,NOT,!,,0"\n', stanza)
        self.assertRegex(stanza, r'\ntext = "[0-9a-f]{16}"\n')

    def test_a_place_without_a_definition_fails(self):
        result = self.tree.run("new", "prng/prng.mbt:7:1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("prng/prng.mbt:7:1 lies in no top-level definition", result.stderr)


class CategoriesTest(unittest.TestCase):
    """The check passes an entry of each category with what it needs, and
    fails one without it, saying what is missing."""

    def setUp(self):
        need_moonc()
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.tree = Tree(self.tmp)
        self.point = self.tree.new(ABORT)
        self.mutant = self.tree.new(NOT)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self, *stanzas):
        self.tree.write(*stanzas)
        return self.tree.run("check")

    def passes(self, *stanzas):
        result = self.check(*stanzas)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def fails(self, message, *stanzas):
        result = self.check(*stanzas)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)

    def test_an_entry_of_each_category_with_what_it_needs_passes(self):
        result = self.passes(
            filled(self.point, category='"UNREACHABLE"', reason='"The count is never 0 here."'),
            filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                   compiler_output='"differs"',
                   adversarial='{ context = "an adversarial agent", tests = ["calc/calc_test.mbt: a try"] }'),
            filled(self.tree.new("calc/calc.mbt,is_blank,BOOL,true,false,0"), category='"ARID"',
                   reason='"A default that no test reads."'),
            filled(self.tree.new("calc/calc.mbt,is_blank,INT,0,1,0"), category='"FAULT"',
                   reason='"Needs a file-system failure."'),
            filled(self.tree.new("calc/calc.mbt,is_odd,INT,0,-1,0"), category='"UB-NATIVE"',
                   reason='"An unchecked access out of bounds."'),
            filled(self.tree.new("calc/calc.mbt,in_range,ROR,<=,<,1"), category='"DEFERRED"',
                   reason='"A test at the high end."', issue="123"),
            filled(self.tree.new("calc/calc.mbt,halve_until,INT,2,3,0"), category='"UNREACHABLE"',
                   reason='"Never divided."', argument='"halve_until is called with a limit of 0 only."'),
        )
        self.assertIn("exclusions: 7 entries, none stale", result.stdout)

    def test_another_category_fails(self):
        self.fails('exclusions.toml: calc/calc.mbt,is_blank,NOT,!,,0: the category should be one of EQUIVALENT,'
                   ' ARID, UNREACHABLE, FAULT, UB-NATIVE and DEFERRED, not "DEAD"',
                   filled(self.mutant, category='"DEAD"', reason='"Never called."'))

    def test_an_entry_without_a_reason_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: it should give a reason",
                   filled(self.mutant, category='"ARID"'))

    def test_an_entry_without_its_reviewer_field_fails(self):
        stanza = filled(self.mutant, category='"ARID"', reason='"A default."').replace('reviewer = ""\n', "")
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: it should have a reviewer, empty until the maintainer"
                   " fills it in", stanza)

    def test_an_equivalent_entry_without_its_record_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: an EQUIVALENT entry should record the comparison of the"
                   ' compiler\'s output (compiler_output = "differs" or "not compared")',
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          adversarial='{ context = "an agent", tests = ["calc/calc_test.mbt: a try"] }'))
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: an EQUIVALENT entry should record the adversarial attempt:"
                   " the agent context that made it and the tests it tried (adversarial = { context, tests })",
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"differs"'))
        self.fails("an EQUIVALENT entry should record the adversarial attempt",
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"differs"', adversarial='{ context = "an agent", tests = [] }'))

    def test_an_equivalent_entry_whose_outputs_are_the_same_fails(self):
        # The comparison marks such a mutant equivalent itself.
        self.fails('compiler_output = "differs" or "not compared"',
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"identical"',
                          adversarial='{ context = "an agent", tests = ["calc/calc_test.mbt: a try"] }'))

    def test_a_deferred_entry_without_its_issue_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: a DEFERRED entry should carry its issue's number (issue = <n>)",
                   filled(self.mutant, category='"DEFERRED"', reason='"Later."'))

    def test_an_unreachable_entry_that_is_no_abort_needs_its_argument(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: an UNREACHABLE entry should be an arm that an invariant"
                   " guards with an abort, or carry its written argument (argument = \"...\")",
                   filled(self.mutant, category='"UNREACHABLE"', reason='"Never false."'))
        # A point that is not an abort: next's first statement.
        self.fails("an UNREACHABLE entry should be an arm that an invariant guards with an abort",
                   filled(self.tree.new("prng/prng.mbt:10:3"), category='"UNREACHABLE"', reason='"Never."'))

    def test_a_point_cannot_be_equivalent_or_undefined_natively(self):
        for category in ("EQUIVALENT", "UB-NATIVE"):
            self.fails(f"prng/prng.mbt,Generator::below,2:19: a point cannot be {category}: only a mutant can",
                       filled(self.point, category=f'"{category}"', reason='"No."', compiler_output='"differs"',
                              adversarial='{ context = "an agent", tests = ["a"] }'))

    def test_an_unknown_field_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: it has a field the list does not know: reviewed_by",
                   filled(self.mutant, category='"ARID"', reason='"A default."', reviewed_by='"someone"'))

    def test_an_entry_that_names_neither_a_mutant_nor_a_point_fails(self):
        self.fails("exclusions.toml: entry 1 should name a mutant (mutant = <id>) or a point (file, definition"
                   " and position)", '[[exclusion]]\ncategory = "ARID"\nreason = "Why."\nreviewer = ""\n')

    def test_two_entries_for_one_mutant_fail(self):
        stanza = filled(self.mutant, category='"ARID"', reason='"A default."')
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: a second entry for it", stanza, stanza)

    def test_a_list_that_is_not_toml_fails(self):
        self.fails("exclusions.toml: not TOML:", "[[exclusion]\n")

    def test_no_list_is_an_empty_list(self):
        result = self.tree.run("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exclusions: 0 entries, none stale", result.stdout)


if __name__ == "__main__":
    unittest.main()

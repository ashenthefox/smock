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
import os
import platform
import re
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
# The machine whose native verdict decides: amd64 (#307: arm64's builds may
# behave otherwise on undefined behaviour, so their verdict is not used),
# as Python names it there.
AMD64 = ("x86_64", "AMD64")
# The machine the tests run on, as Python names it, and whether its native
# verdict decides.
MACHINE = platform.machine()
DECIDES = MACHINE in AMD64
# bounds' tests, as moon names them.
DOT = ("mutation/fixture/bounds", "bounds_test.mbt", "a dot after the first characters")
NO_DOT = ("mutation/fixture/bounds", "bounds_test.mbt", "no dot after the first characters")
ENDS = ("mutation/fixture/bounds", "bounds_test.mbt", "a name that ends after its first characters")

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

# The mutants of host's pinned set, a package that builds only natively:
# each one's id and the outcome that the comment beside its site gives.
HOST = [
    ("host/host.mbt,is_system,BODY,{…},{ false },0", "killed"),
    ("host/host.mbt,is_system,ROR,<,<=,0", "survived"),
    ("host/host.mbt,is_system,INT,1000,1001,0", "survived"),
    ("host/host.mbt,is_system,INT,1000,999,0", "killed"),
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


class DecidingVerdictTest(unittest.TestCase):
    """Which verdict counts, on amd64 and on arm64 (#307: the native verdict
    on amd64 decides; arm64's is not used), for records built by hand,
    since a run shows only the machine it runs on."""

    @staticmethod
    def records():
        # Killed on wasm-gc by the trap alone, and surviving natively; and
        # surviving on wasm-gc, and killed natively.
        trap = {"id": "a", "outcome": "killed", "killing_tests": [{"name": "t"}], "timings": {"run_s": 1.0},
                "importers": [], "confirmation": "confirmed", "backend": "wasm-gc"}
        trap_natively = {"outcome": "survived", "killing_tests": [], "timings": {"run_s": 2.0}, "importers": [],
                         "diff": "the diff", "backend": "native"}
        missed = {"id": "b", "outcome": "survived", "killing_tests": [], "timings": {"run_s": 1.0}, "importers": [],
                  "diff": "the diff", "backend": "wasm-gc"}
        missed_natively = {"outcome": "killed", "killing_tests": [{"name": "u"}], "timings": {"run_s": 2.0},
                           "importers": [], "confirmation": "confirmed", "backend": "native"}
        return (trap, trap_natively), (missed, missed_natively)

    def test_on_amd64_the_native_verdict_decides(self):
        import native

        for machine in AMD64:
            (trap, natively), (missed, missed_natively) = self.records()
            native.combine(trap, natively, machine)
            native.combine(missed, missed_natively, machine)
            # A mutant killed on wasm-gc and surviving natively is a
            # survivor, with its diff; one killed natively alone is killed.
            self.assertEqual((trap["outcome"], trap["backend"], trap["killing_tests"], trap["diff"]),
                             ("survived", "native", [], "the diff"))
            self.assertNotIn("confirmation", trap)
            self.assertEqual((missed["outcome"], missed["backend"], missed["killing_tests"]),
                             ("killed", "native", [{"name": "u"}]))
            self.assertNotIn("diff", missed)
            self.assertEqual(trap["timings"], {"run_s": 2.0})
            # Both verdicts stay in the record.
            self.assertEqual(trap["verdicts"], {
                "wasm-gc": {"outcome": "killed", "killing_tests": [{"name": "t"}], "timings": {"run_s": 1.0},
                            "importers": [], "confirmation": "confirmed"},
                "native": {"outcome": "survived", "killing_tests": [], "timings": {"run_s": 2.0}, "importers": [],
                           "machine": machine}})

    def test_on_arm64_the_native_verdict_is_recorded_and_the_wasm_gc_verdict_counts(self):
        import native

        for machine in ("aarch64", "arm64"):
            (trap, natively), (missed, missed_natively) = self.records()
            native.combine(trap, natively, machine)
            native.combine(missed, missed_natively, machine)
            self.assertEqual((trap["outcome"], trap["backend"], trap["killing_tests"]),
                             ("killed", "wasm-gc", [{"name": "t"}]))
            self.assertNotIn("diff", trap)
            self.assertEqual((missed["outcome"], missed["backend"], missed["diff"]), ("survived", "wasm-gc", "the diff"))
            self.assertEqual((trap["verdicts"]["native"]["outcome"], trap["verdicts"]["native"]["machine"]),
                             ("survived", machine))


def logging_moon(directory):
    """A moon that logs each of its command lines and runs the real one."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / "moon"
    log = directory / "moon.log"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


def names(tests):
    """The tests of a record, as (package, file, name)."""
    return [(t["package"], t["file"], t["name"]) for t in tests]


class NativeTest(unittest.TestCase):
    """One run of the pinned sets of bounds, whose mutants at sites that use
    an unchecked array access run natively as well, and of host, which
    builds only natively, with moon's variables for another C compiler set
    to ones that do not exist."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-native-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.out = cls.tmp / "out"
        # moon reads these three; a native build that took them would fail.
        environment = dict(os.environ, MOON_CC=str(cls.tmp / "no-cc"), MOON_AR=str(cls.tmp / "no-ar"),
                           MOON_CC_WRAPPER=str(cls.tmp / "no-wrapper"))
        cls.result = subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.tmp / "work"), "--out", str(cls.out),
             "--moon", str(cls.moon), "bounds", "host"],
            capture_output=True, text=True, env=environment)
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]
        cls.records = [r for r in records if r["package"] == "mutation/fixture/bounds"]
        cls.host = [r for r in records if r["package"] == "mutation/fixture/host"]
        cls.summary, cls.host_summary = json.loads((cls.out / "summary.json").read_text())["packages"]
        cls.report = (cls.out / "report.md").read_text()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_mutant_has_its_known_outcome_on_each_backend(self):
        # A mutant at a site that uses an unchecked array access gives both
        # verdicts; any other runs on wasm-gc alone.
        found = []
        for record in self.records:
            verdicts = record.get("verdicts", {})
            found.append((record["id"], record.get("unchecked_access", False),
                          verdicts.get("wasm-gc", record)["outcome"], verdicts.get("native", {}).get("outcome")))
        self.assertEqual(found, BOUNDS)

    def test_a_record_names_the_tests_that_killed_it_on_each_backend(self):
        verdicts = {r["id"]: r.get("verdicts") for r in self.records}
        # `||` reads past the end of "a" too: wasm-gc traps there, while the
        # native read finds no dot.
        lcr = verdicts["bounds/bounds.mbt,dot_after,LCR,&&,||,0"]
        self.assertEqual(sorted(names(lcr["wasm-gc"]["killing_tests"])), sorted([NO_DOT, ENDS]))
        self.assertEqual(names(lcr["native"]["killing_tests"]), [NO_DOT])
        ror = verdicts["bounds/bounds.mbt,dot_after,ROR,>,>=,0"]
        self.assertEqual(names(ror["wasm-gc"]["killing_tests"]), [ENDS])
        self.assertEqual(ror["native"]["killing_tests"], [])
        # Each kill is confirmed on its own backend, as #301 asks.
        for record in self.records:
            for verdict in record.get("verdicts", {}).values():
                if verdict["outcome"] == "killed":
                    self.assertEqual(verdict["confirmation"], "confirmed", record["id"])
        self.assertEqual(names(verdicts["bounds/bounds.mbt,dot_after,BODY,{…},{ false },0"]["native"]["killing_tests"]),
                         [DOT])

    def test_the_native_verdict_decides_on_amd64_alone(self):
        # #307: the native verdict on amd64 decides, so a mutant killed on
        # wasm-gc and surviving natively is a survivor there, with its
        # diff; elsewhere the native verdict is recorded and not used.
        for record in self.records:
            if "verdicts" not in record:
                self.assertEqual(record["backend"], "wasm-gc")
                continue
            native = record["verdicts"]["native"]
            self.assertEqual(native["machine"], MACHINE)
            deciding = native if DECIDES else record["verdicts"]["wasm-gc"]
            self.assertEqual((record["backend"], record["outcome"], record["killing_tests"]),
                             ("native" if DECIDES else "wasm-gc", deciding["outcome"], deciding["killing_tests"]))
        ror = next(r for r in self.records if r["id"] == "bounds/bounds.mbt,dot_after,ROR,>,>=,0")
        if DECIDES:
            self.assertIn("-  name.length() > n && name.unsafe_get(n) == '.'\n"
                          "+  name.length() >= n && name.unsafe_get(n) == '.'\n", ror["diff"])
        else:
            self.assertNotIn("diff", ror)

    def test_only_the_mutants_at_marked_sites_run_natively(self):
        native = self.summary["native"]
        self.assertEqual((native["marked"], native["ran"], native["differ"]), (3, 3, 1))
        self.assertEqual(native["outcomes"], {"killed": 2, "timed out": 0, "survived": 1, "unconfirmed": 0})
        self.assertEqual((native["machine"], native["decides"]), (MACHINE, DECIDES))
        # Natively: two runs without a mutant, as on wasm-gc, before the
        # mutants, with their own time limit.
        self.assertEqual(len(native["baseline"]["runs_s"]), 2)
        self.assertAlmostEqual(native["limit_s"], 1.25 * native["baseline"]["run_s"] + 4, places=2)
        self.assertEqual(native["baseline"]["tests"], 4)
        # Of bounds' tests, natively: none passes -u.
        native_runs = [line.split() for line in self.log.read_text().splitlines()
                       if "--target native" in line and "mutation/fixture/bounds" in line.split()]
        self.assertTrue(native_runs)
        for words in native_runs:
            self.assertNotIn("-u", words)
            self.assertNotIn("--update", words)
        # A build of the baseline, of each mutant, and of each kill's two
        # confirming runs: 1 + 3 + 2 x 2.
        self.assertEqual(sum(1 for words in native_runs if "--build-only" in words), 8)

    def test_native_builds_take_no_c_compiler_or_flags_from_the_environment(self):
        # The run had MOON_CC, MOON_AR and MOON_CC_WRAPPER set to files that
        # do not exist, and its native builds still built: the runner unset
        # them, and says so.
        self.assertEqual(self.summary["native"]["unset"], ["MOON_AR", "MOON_CC", "MOON_CC_WRAPPER"])
        self.assertIn("The runner unset MOON_AR, MOON_CC and MOON_CC_WRAPPER", self.report)

    def test_the_report_lists_the_mutants_whose_verdicts_differ(self):
        self.assertIn("- Unchecked array access: 3 mutants at sites whose definition uses one, all of which ran"
                      f" natively on {MACHINE} as well; 1 has another verdict there.", self.report)
        self.assertIn("### Verdicts that differ between wasm-gc and native (1)", self.report)
        self.assertIn("- `bounds/bounds.mbt,dot_after,ROR,>,>=,0`: wasm-gc killed, native survived", self.report)
        if DECIDES:
            self.assertIn("The native verdict decides here.", self.report)
            self.assertIn("### Survivors (1)", self.report)
        else:
            self.assertIn(f"On {MACHINE}, the native verdict is recorded, and the wasm-gc verdict counts:"
                          " only amd64's native verdict decides.", self.report)
            self.assertIn("### Survivors (0)", self.report)

    def test_a_package_that_builds_only_natively_runs_wholly_natively(self):
        # #307: the runner can run a whole native-only package natively,
        # with its own in-process tests, as step 5 does for defdir, watch,
        # openssl and protobuf-conformance.
        self.assertEqual([(r["id"], r["outcome"]) for r in self.host], HOST)
        for record in self.host:
            self.assertEqual(record["backend"], "native")
            self.assertNotIn("verdicts", record)
        summary = self.host_summary
        self.assertEqual(summary["backend"], "native")
        self.assertEqual({k: summary[k] for k in ("mutants", "killed", "survived", "unviable")},
                         {"mutants": 4, "killed": 2, "survived": 2, "unviable": 0})
        self.assertEqual(summary["baseline"]["tests"], 2)
        self.assertEqual(summary["native"]["builds_only_natively"], True)
        # Its self-test ran natively too, and its own tests saw it: natively,
        # the abort stops the test program, so moon names no failed test.
        self.assertEqual((summary["self_test"]["outcome"], summary["self_test"]["failed_tests"]), ("killed", 0))
        self.assertIn("Self-test: `abort(\"mutation self-test\")` at the start of 1 functions, killed: the test"
                      " program stopped before it named a failed test, as an abort stops it natively.", self.report)
        # Every build and run of host's tests is native; moon is asked only
        # whether they build on wasm-gc.
        for line in self.log.read_text().splitlines():
            words = line.split()
            if "mutation/fixture/host" in words and "--dry-run" not in words:
                self.assertEqual(words[words.index("--target") + 1], "native", line)
        self.assertIn("- It builds only natively, so every mutant ran natively on", self.report)
        # The abort wrote no core dump into the worker's tree: native runs
        # dump none.
        dumps = [p for p in (self.tmp / "work").rglob("core*") if p.is_file() and re.fullmatch(r"core(\.\d+)?", p.name)]
        self.assertEqual(dumps, [])
        self.assertIn("#### `host/host.mbt,is_system,ROR,<,<=,0`", self.report)

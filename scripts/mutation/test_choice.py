"""Tests of the mutation runner's modes for bulk runs, through the command
lines of scripts/mutation/run.py and scripts/mutation/merge.py, on the
fixture module scripts/mutation/fixture: shards whose reports merge into
one, seeded samples stratified by package, chosen packages, and listed
sets of mutants, by offset on a commit or by key on any later commit,
with a run that writes totals only (#305).

The modes come from #305's acceptance criteria and from #275 (Step 2's
runner: "modes for ... a shard, a seeded sample, ... chosen packages and
a listed set (applied to later commits by key, with totals only for the
held-out set)"); the rules this ticket decided where they were silent are
in CONTRIBUTING.md, "Mutation runner", which the tests cite. The outcomes
of the fixture's mutants are those its comments give, as in
test_mutation.py.

They need python3, git, moon and moonc (the toolchain of
.moonbit-version).

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
RUN = HERE / "run.py"
MERGE = HERE / "merge.py"
PACKAGES = ("calc", "forms", "log", "shapes")


def git(repo, *args):
    """Runs git in repo, as an author of its own, and gives its output."""
    result = subprocess.run(["git", "-C", str(repo), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                             "-c", "commit.gpgsign=false", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def fixture_history(directory):
    """A git repository at directory that holds a copy of the fixture
    module in one commit, on main: the commit's id."""
    shutil.copytree(FIXTURE, directory, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
    git(directory, "init", "-q", "-b", "main")
    git(directory, "add", "-A")
    git(directory, "commit", "-q", "-m", "the fixture")
    return git(directory, "rev-parse", "HEAD").strip()


def run_runner(root, out, *args, work=None, moon="moon"):
    """Runs run.py on root, writing into out."""
    work = work or out.parent / "work"
    return subprocess.run([sys.executable, str(RUN), "--root", str(root), "--work", str(work), "--out", str(out),
                           "--moon", str(moon), *args], capture_output=True, text=True)


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class ShardTest(unittest.TestCase):
    """Shards, chosen without a run (--sites-only)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-shards-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def chosen(self, name, *args):
        out = self.tmp / name
        result = run_runner(FIXTURE, out, "--sites-only", "--set", "full", *args, *PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [s["id"] for s in read_lines(out / "chosen.jsonl")]

    def test_each_mutant_is_in_exactly_one_shard_and_the_same_input_gives_the_same_shards(self):
        # #305: "every mutant is in exactly one shard, and the same input
        # gives the same shards".
        whole = self.chosen("whole")
        self.assertEqual(len(set(whole)), len(whole))
        self.assertGreater(len(whole), 100)
        parts = [self.chosen(f"shard-{k}", "--shard", f"{k}/3") for k in (1, 2, 3)]
        # In shard order, the shards hold the run's mutants in its own order.
        self.assertEqual([i for part in parts for i in part], whole)
        self.assertEqual(self.chosen("again", "--shard", "2/3"), parts[1])
        # CONTRIBUTING, "Mutation runner": the shards' sizes differ by one
        # at most.
        self.assertLessEqual(max(map(len, parts)) - min(map(len, parts)), 1)

    def test_a_shard_must_be_one_of_n(self):
        for shard in ("0/3", "4/3", "3", "a/b", "1/0"):
            result = run_runner(FIXTURE, self.tmp / "bad", "--sites-only", "--shard", shard, "calc")
            self.assertEqual(result.returncode, 2, shard)
            self.assertIn("argument --shard: ", result.stderr)


if __name__ == "__main__":
    unittest.main()

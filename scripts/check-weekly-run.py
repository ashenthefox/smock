#!/usr/bin/env python3
"""The release's check of the latest weekly mutation run (decision 7, ADR
0006, "What L4 and a release read"; docs/releasing.md): whether a tag's
commit may be released, by the latest weekly run over the pinned set.

usage: python3 scripts/check-weekly-run.py [--repo <dir>] [--repository <owner/repo>] <commit sha>

<commit sha> is the full id of the tag's commit; <dir> is the checkout,
this one unless given; <owner/repo> is GITHUB_REPOSITORY unless given.

The packages at L4 are those that mutation/l4-packages.txt names on the
tag's commit. With none, the check reads nothing and passes, and says so.

It exits with 0 when the tag's commit may be released, and with 2 when
<commit sha> is not the full id of a commit of the checkout.
"""

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent / "mutation"))
import sites as finder  # noqa: E402

L4_LIST = "mutation/l4-packages.txt"
SHA = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
# The bulk mutation runs' workflow, and the name it gives a weekly run.
RUNS = "mutation-runs.yml"
WEEKLY = "Mutation runs: weekly"


class Refused(Exception):
    """Why the commit may not be released, and what to do then."""

    def __init__(self, why, then=None):
        super().__init__(why)
        self.then = then


def start_weekly(repository):
    """What to do when no weekly run that passed covers the commit."""
    return (f"start a weekly run on main once it holds the tag's commit, and run the release workflow again once it"
            f" has passed: gh workflow run {RUNS} -R {repository} --ref main -f mode=weekly")


class Unusable(Exception):
    """What makes the check unable to start: an argument that is not a
    commit's full id."""


def git(repo, *args):
    """Runs git in repo, and gives its output, or None when it fails."""
    result = subprocess.run(["git", "-C", str(repo), "-c", "core.quotepath=off", *args], capture_output=True,
                            text=True, encoding="utf-8", errors="replace")
    return result.stdout if result.returncode == 0 else None


def gh(*args):
    """Runs gh, and gives its output, or None when it fails."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def artifact(repository, run, name, file):
    """The text of a file of a run's artifact, or None when it cannot be
    read."""
    with tempfile.TemporaryDirectory() as directory:
        if gh("run", "download", str(run["id"]), "-R", repository, "-n", name, "--dir", directory) is None:
            return None
        path = Path(directory) / file
        return path.read_text(encoding="utf-8") if path.is_file() else None


def runs_of(repository, query, keep):
    """The runs of a workflow that the Actions API lists for the query and
    keep keeps, latest first."""
    answer = gh("api", f"repos/{repository}/actions/workflows/{query}")
    if answer is None:
        raise Refused(f"gh cannot list the runs of {query.split('/', 1)[0]}")
    try:
        runs = json.loads(answer)["workflow_runs"]
        if not isinstance(runs, list):
            raise ValueError
        kept = [r for r in runs if keep(r)]
        kept.sort(key=lambda r: (r["created_at"], r["id"]), reverse=True)
    except (ValueError, KeyError, TypeError) as problem:
        raise Refused("the Actions API gave an answer that cannot be read") from problem
    return kept


def latest_weekly(repository):
    """The latest weekly run on main that has ended, which must have passed;
    it says when a later one is still running."""
    weekly = runs_of(repository, f"{RUNS}/runs?branch=main&per_page=100",
                     lambda r: r["display_title"] == WEEKLY and r["head_branch"] == "main")
    ended = [r for r in weekly if r["status"] == "completed"]
    if not ended:
        if weekly:
            raise Refused(f"no weekly run over the pinned set on main has ended, and {weekly[0]['html_url']} is still"
                          " running", "run the release workflow again once it has passed")
        raise Refused("no weekly run over the pinned set on main has ended", start_weekly(repository))
    run = ended[0]
    if run["conclusion"] != "success":
        raise Refused(f"the latest weekly run over the pinned set on main failed ({run['conclusion']}):"
                      f" {run['html_url']}", start_weekly(repository))
    if weekly[0] is not run:
        print(f"check-weekly-run: a later weekly run, {weekly[0]['html_url']}, is still running, and does not decide")
    return run


def unexplained(package):
    """A package's unexplained survivors in a weekly run's summary, and how
    many of them are stale-covered, as the run's report counts them: those
    that a DEFERRED entry covers are among the unexplained, and survivors
    that no exclusion list judged are unexplained."""
    found = package.get("exclusions") or {}
    if not found:
        return int(package.get("survived", 0)), 0
    stale = int(found["stale_covered"])
    return int(found["unexplained"]) + stale, stale


def survivors_at_l4(repository, run, at_l4):
    """Refuses unless the run's report is of the pinned set, ran every
    package at L4, and shows no unexplained survivor in any of them."""
    text = artifact(repository, run, "mutation-report", "summary.json")
    try:
        summary = json.loads(text) if text is not None else None
        ran, listed = summary["selection"]["packages"], summary["packages"]
        if not isinstance(ran, list) or not isinstance(listed, list):
            raise TypeError("the packages are not lists")
        packages = {p["directory"]: p for p in listed}
        counts = {d: unexplained(packages.get(d, {})) for d in at_l4}
    except (ValueError, KeyError, TypeError) as problem:
        raise Refused("the report of the latest weekly run over the pinned set on main (the artifact mutation-report,"
                      f" summary.json) cannot be read: {run['html_url']}") from problem
    if summary.get("set") != "pinned":
        raise Refused(f"the report of the latest weekly run over the pinned set on main is of the {summary.get('set')}"
                      f" set, not the pinned set: {run['html_url']}")
    for directory in at_l4:
        if directory not in ran:
            raise Refused(f"the latest weekly run over the pinned set on main did not run {directory}, a package at L4:"
                          f" {run['html_url']}", start_weekly(repository))
    found = [f"{d} {n}" + (f" ({stale} stale-covered)" if stale else "")
             for d, (n, stale) in counts.items() if n]
    if found:
        raise Refused("the latest weekly run over the pinned set on main shows unexplained survivors in a package at"
                      f" L4: {', '.join(found)}: {run['html_url']}",
                      f"its report lists them: gh run download {run['id']} -R {repository} --name mutation-report"
                      " --dir mutation-report")


def l4_packages(repo, sha):
    """The packages at L4 that the list names on the commit, in its order."""
    found = []
    for line in (git(repo, "show", f"{sha}:{L4_LIST}") or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if line and line not in found:
            found.append(line)
    return found


def later_changes(repo, repository, run, sha):
    """The commits of the tag's commit's first-parent history after the
    run's commit, oldest first: main's changes since the run."""
    ran = run["head_sha"]
    if ran == sha:
        return []
    if git(repo, "merge-base", "--is-ancestor", ran, sha) is None:
        raise Refused(f"the latest weekly run over the pinned set on main ran on {ran[:12]}, which the tag's commit"
                      f" does not hold: {run['html_url']}", start_weekly(repository))
    listed = (git(repo, "rev-list", "--first-parent", f"{ran}..{sha}") or "").split()
    if not listed or parents(repo, listed[-1])[:1] != [ran]:
        raise Refused(f"the latest weekly run over the pinned set on main ran on {ran[:12]}, which is not on the"
                      f" first-parent history of the tag's commit, as main's commits are: {run['html_url']}",
                      start_weekly(repository))
    return listed[::-1]


def parents(repo, commit):
    """The commit's parents, the first first."""
    return (git(repo, "rev-list", "--parents", "-n", "1", commit) or "").split()[1:]


def subject(repo, commit):
    """The commit's subject."""
    return (git(repo, "log", "-1", "--format=%s", commit) or "").strip()


def is_source(repo, file, commits):
    """Whether a .mbt file is non-test source on any of the commits that
    have it: not a test file, and not a generated one (the site finder's
    rules)."""
    if not file.endswith(".mbt") or finder.is_test_file(PurePosixPath(file)):
        return False
    texts = [git(repo, "show", f"{c}:{file}") for c in commits]
    return any(t is not None and not finder.is_generated(t) for t in texts)


def source_touched(repo, change, at_l4):
    """The packages at L4 whose non-test source a commit adds, changes or
    deletes against its first parent."""
    before = parents(repo, change)[0]
    names = git(repo, "diff", "--no-renames", "--name-only", before, change)
    if names is None:
        raise Refused(f"git cannot tell what {change[:12]} changes")
    touched = {posixpath.dirname(f) for f in names.splitlines()
               if posixpath.dirname(f) in at_l4 and is_source(repo, f, (before, change))}
    return [d for d in at_l4 if d in touched]


def covered(repo, repository, run, change, at_l4):
    """How a change to main after the run is covered, or a refusal."""
    touched = source_touched(repo, change, at_l4)
    if not touched:
        return "it touches no non-test source of a package at L4"
    what = (f"{change[:12]} ({subject(repo, change)}), a change to main after the latest weekly run over the pinned"
            f" set ({run['html_url']}), changes non-test source of {', '.join(touched)}, a package at L4, and")
    raise Refused(f"{what} no run of the branch checks is on {change[:12]}, as none is on a change pushed straight to"
                  " main", start_weekly(repository))


def check(repo, sha, repository):
    """Prints whether the commit may be released, and why; whether it may."""
    named = sha[:12]
    at_l4 = l4_packages(repo, sha)
    if not at_l4:
        print(f"check-weekly-run: no package is at L4 on {named} ({L4_LIST} names none), so the release reads no"
              " weekly run and waits for none")
        return True
    try:
        run = latest_weekly(repository)
        survivors_at_l4(repository, run, at_l4)
        changes = later_changes(repo, repository, run, sha)
        lines = [f"{c[:12]} {subject(repo, c)}: {covered(repo, repository, run, c, at_l4)}" for c in changes]
        where = "the tag's commit" if not changes else f"{run['head_sha'][:12]}, an ancestor of the tag's commit"
        print(f"check-weekly-run: {named} may be released: the latest weekly run over the pinned set, on {where},"
              f" shows no unexplained survivor in the packages at L4 ({', '.join(at_l4)}): {run['html_url']}")
        if changes:
            count = "the one change" if len(changes) == 1 else f"each of the {len(changes)} changes"
            print(f"check-weekly-run: {count} to main after it is covered:")
            for line in lines:
                print(f"check-weekly-run:   {line}")
        return True
    except Refused as why:
        print(f"check-weekly-run: {named} may not be released: {why}", file=sys.stderr)
        if why.then:
            print(f"check-weekly-run: {why.then}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--repo", default=".", help="the checkout")
    parser.add_argument("--repository", help="owner/repo on GitHub (GITHUB_REPOSITORY unless given)")
    parser.add_argument("commit", help="the full id of the tag's commit")
    args = parser.parse_args()
    repo = Path(args.repo)
    try:
        if not SHA.fullmatch(args.commit):
            raise Unusable(f"'{args.commit}' is not a commit's full SHA in lower case")
        if (git(repo, "rev-parse", "--verify", "--quiet", f"{args.commit}^{{commit}}") or "").strip() != args.commit:
            raise Unusable(f"{args.commit} is not a commit of {repo}")
    except Unusable as error:
        print(f"check-weekly-run: {error}", file=sys.stderr)
        return 2
    repository = args.repository or os.environ.get("GITHUB_REPOSITORY", "")
    return 0 if check(repo, args.commit, repository) else 1


if __name__ == "__main__":
    sys.exit(main())

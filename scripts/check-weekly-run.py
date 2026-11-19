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
import re
import subprocess
import sys
import tempfile
from pathlib import Path

L4_LIST = "mutation/l4-packages.txt"
SHA = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
# The bulk mutation runs' workflow, and the name it gives a weekly run.
RUNS = "mutation-runs.yml"
WEEKLY = "Mutation runs: weekly"
EVENTS = ("schedule", "workflow_dispatch")


class Refused(Exception):
    """Why the commit may not be released."""


class Unusable(Exception):
    """What makes the check unable to start: an argument that is not a
    commit's full id."""


def git(repo, *args):
    """Runs git in repo, and gives its output, or None when it fails."""
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
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
    """The latest weekly run on main that has ended."""
    weekly = runs_of(repository, f"{RUNS}/runs?branch=main&per_page=100",
                     lambda r: r["display_title"] == WEEKLY and r["head_branch"] == "main" and r["event"] in EVENTS)
    ended = [r for r in weekly if r["status"] == "completed"]
    run = ended[0]
    if run["conclusion"] != "success":
        raise Refused(f"the latest weekly run failed ({run['conclusion']}): {run['html_url']}")
    return run


def unexplained(package):
    """A package's unexplained survivors in a weekly run's summary, those
    stale-covered included, as the run's report counts them."""
    found = package.get("exclusions") or {}
    if not found:
        return package.get("survived", 0)
    return found.get("unexplained", 0) + found.get("stale_covered", 0)


def survivors_at_l4(repository, run, at_l4):
    """Each package at L4 with its unexplained survivors in the run's
    report, for those that have some."""
    text = artifact(repository, run, "mutation-report", "summary.json")
    summary = json.loads(text)
    packages = {p["directory"]: p for p in summary["packages"]}
    return [(d, unexplained(packages[d])) for d in at_l4 if unexplained(packages.get(d, {})) > 0]


def l4_packages(repo, sha):
    """The packages at L4 that the list names on the commit, in its order."""
    found = []
    for line in (git(repo, "show", f"{sha}:{L4_LIST}") or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if line and line not in found:
            found.append(line)
    return found


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
        if survivors_at_l4(repository, run, at_l4):
            raise Refused("survivors")
        if run["head_sha"] != sha:
            raise Refused("not on the tag's commit")
        print(f"check-weekly-run: {named} may be released: the latest weekly run over the pinned set, on the tag's"
              f" commit, shows no unexplained survivor in the packages at L4 ({', '.join(at_l4)}): {run['html_url']}")
        return True
    except Refused as why:
        print(f"check-weekly-run: {named} may not be released: {why}", file=sys.stderr)
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

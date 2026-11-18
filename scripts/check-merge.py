#!/usr/bin/env python3
"""The merge check: whether a branch may be merged into main, by the
report of the branch checks on its head (CONTRIBUTING.md, "The
changed-lines job"). The maintainer runs it before the merge, as the
checklist in docs/merging-into-main.md says, as the release checks that
CI passed on a tag's commit (scripts/check-ci-passed.sh).

usage: python3 scripts/check-merge.py [--repo <dir>] [--base <ref>]
                                      [--repository <owner/repo>] <branch>

<dir> is the checkout, this one unless given; <branch> is the branch to
merge, a ref of it, whose commit is its head; <base> is main (origin/main
where the checkout has no main), unless given; <owner/repo> is
GITHUB_REPOSITORY, or the repository gh names for the checkout.

It asks GitHub (with gh) for the runs of the branch checks
(.github/workflows/branch-checks.yml) on the head, on a push or started
by hand, and reads the report of the mutants on the changed lines that a
run kept (the artifact changed-lines, report.json, which
scripts/changed-lines.py writes). The run that decides is the latest that
passed and whose report covered the whole diff; a diff too large for a
push's shards is covered by a run started by hand. It refuses the merge,
and says why with the run's link, when

  - no run of the branch checks is on the head;
  - none passed: the latest is still running, or failed;
  - none covered the whole diff, and the latest that passed compared the
    head with another base than main, or did not cover it;
  - the deciding run compared the head with another base than main, or
    from another merge base than the head's with <base> now (main took
    commits of the branch, or the branch took main's, since the run);
  - its report is of another commit, or it or the weakening report
    cannot be read;
  - its report shows an unexplained survivor on the changed lines of a
    package at L4: one that mutation/l4-packages.txt names on <base> or
    on the head, by its directory.

It prints the unexplained survivors in other packages, which are reported
only, and the stale-covered survivors, each with its stale entry's id,
which do not block either: they are re-triaged in a batch. Accepted
survivors are not printed. Then it prints the branch's weakening report,
which the same run kept (the artifact weakening-report), for the
maintainer to read and acknowledge before the merge.

It exits with 0 when the branch may be merged, and with 1 when it may
not, or when gh fails or its answer cannot be read, since a merge must
not go ahead on doubt. It exits with 2 when <branch> is not a commit.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

WORKFLOW = "branch-checks.yml"
EVENTS = ("push", "workflow_dispatch")
L4_LIST = "mutation/l4-packages.txt"
BASES = ("main", "origin/main")


class Refused(Exception):
    """Why the branch may not be merged."""


class Unusable(Exception):
    """What makes the check unable to start: a branch that is not a
    commit."""


def git(repo, *args):
    """Runs git in repo, and gives its output, or None when it fails."""
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def commit(repo, ref):
    """The full id of the commit that ref names."""
    found = git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if not found:
        raise Unusable(f"{ref} is not a commit of {repo}")
    return found.strip()


def base_commit(repo, base):
    """The base as named (the first of BASES that git knows when none is
    given), and its commit."""
    for name in (base,) if base else BASES:
        found = git(repo, "rev-parse", "--verify", "--quiet", f"{name}^{{commit}}")
        if found:
            return name, found.strip()
    raise Unusable(f"git knows no {base or ' or '.join(BASES)} in {repo}")


def l4_packages(repo, *refs):
    """The packages at L4 that the list names on any of refs."""
    found = set()
    for ref in refs:
        text = git(repo, "show", f"{ref}:{L4_LIST}") or ""
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                found.add(line)
    return found


def gh(*args):
    """Runs gh, and gives its output, or None when it fails."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def runs_on(repository, sha):
    """The runs of the branch checks on the commit, on a push or started by
    hand, latest first."""
    answer = gh("api", f"repos/{repository}/actions/workflows/{WORKFLOW}/runs?head_sha={sha}&per_page=100")
    if answer is None:
        raise Refused("gh cannot list the runs of the branch checks")
    try:
        runs = json.loads(answer)["workflow_runs"]
        if not isinstance(runs, list):
            raise ValueError
        mine = [r for r in runs if r["head_sha"] == sha and r["event"] in EVENTS]
        mine.sort(key=lambda r: (r["created_at"], r["id"]), reverse=True)
    except (ValueError, KeyError, TypeError) as problem:
        raise Refused("the Actions API gave an answer that cannot be read") from problem
    return mine


def artifact(repository, run, name, file):
    """The text of a file of a run's artifact, or None when it cannot be
    read."""
    with tempfile.TemporaryDirectory() as directory:
        if gh("run", "download", str(run["id"]), "-R", repository, "-n", name, "--dir", directory) is None:
            return None
        path = Path(directory) / file
        return path.read_text(encoding="utf-8") if path.is_file() else None


def report_of(repository, run, sha):
    """The report of the mutants on the changed lines that a run kept."""
    text = artifact(repository, run, "changed-lines", "report.json")
    try:
        found = json.loads(text) if text is not None else None
    except ValueError:
        found = None
    if not isinstance(found, dict) or not isinstance(found.get("survivors"), list):
        raise Refused(f"the report of the branch checks on its head cannot be read: {run['html_url']}")
    if found.get("head") != sha:
        raise Refused(f"the report of the branch checks on its head is of another commit,"
                      f" {str(found.get('head'))[:12]}: {run['html_url']}")
    return found


def on_main(found):
    """Whether a report compared the head with main."""
    return found.get("base") in BASES


def deciding(repository, runs, sha, branch):
    """The run that decides, and its report: the latest that passed and
    covered the whole diff against main."""
    if not runs:
        raise Refused("no run of the branch checks on its head. Push the branch, and run this again once its"
                      " branch checks have passed")
    passed = [r for r in runs if r["status"] == "completed" and r["conclusion"] == "success"]
    if not passed:
        latest = runs[0]
        if latest["status"] != "completed":
            raise Refused(f"the branch checks on its head are still running: {latest['html_url']}")
        raise Refused(f"the branch checks on its head failed ({latest['conclusion']}): {latest['html_url']}")
    reports = []
    for run in passed:
        found = report_of(repository, run, sha)
        if found.get("covered") is True and on_main(found):
            return run, found
        reports.append((run, found))
    run, found = reports[0]
    if not on_main(found):
        raise Refused(f"the branch checks on its head compared it with {found.get('base')}, not main:"
                      f" {run['html_url']}")
    raise Refused(f"the branch checks on its head did not cover the whole diff ({found.get('mutants')} mutants on"
                  f" its changed lines): {run['html_url']}. Start them by hand on the branch, and run this again"
                  f" once that run has passed: gh workflow run {WORKFLOW} --ref {branch}")


def listed(survivors):
    """The lines that list survivors, each with its package."""
    return [f"  {s['id']} ({s['directory']})" for s in survivors]


def check(repo, branch, base, repository):
    """Prints why the branch may or may not be merged, and the weakening
    report; whether it may."""
    sha = commit(repo, branch)
    base_name, base_sha = base_commit(repo, base)
    named = f"{branch} ({sha[:12]})"
    try:
        run, found = deciding(repository, runs_on(repository, sha), sha, branch)
        merge_base = (git(repo, "merge-base", sha, base_sha) or "").strip()
        if found.get("merge_base") != merge_base:
            raise Refused(f"the branch checks on its head took the merge base {str(found.get('merge_base'))[:12]},"
                          f" not the branch's merge base with main, {merge_base[:12]}: {run['html_url']}. Start them"
                          f" by hand on the branch, and run this again once that run has passed:"
                          f" gh workflow run {WORKFLOW} --ref {branch}")
        weakening = artifact(repository, run, "weakening-report", "weakening-report.md")
        if weakening is None:
            raise Refused(f"the weakening report of the branch checks on its head cannot be read: {run['html_url']}")
        at_l4 = l4_packages(repo, base_sha, sha)
        unexplained = [s for s in found["survivors"] if s.get("status") == "unexplained"]
        blocking = [s for s in unexplained if s.get("directory") in at_l4]
        reported = [s for s in unexplained if s.get("directory") not in at_l4]
        stale = [s for s in found["survivors"] if s.get("status") == "stale-covered"]
        if reported:
            print(f"check-merge: {plural(len(reported), 'unexplained survivor')} on the changed lines of a package"
                  f" not at L4, reported only: " + ", ".join(f"{s['id']} ({s['directory']})" for s in reported))
        if stale:
            print(f"check-merge: {plural(len(stale), 'stale-covered survivor')} on the changed lines, to re-triage"
                  " in a batch:")
            for s in stale:
                print(f"check-merge:   {s['id']} ({s['directory']}), its stale entry {s.get('entry')}")
        if blocking:
            print(f"check-merge: {named} may not be merged into main: the report of the branch checks on its head"
                  f" shows {plural(len(blocking), 'unexplained survivor')} on the changed lines of a package at L4:"
                  f" {run['html_url']}", file=sys.stderr)
            for line in listed(blocking):
                print(f"check-merge: {line}", file=sys.stderr)
        else:
            print(f"check-merge: {named} may be merged into main, by the branch checks on its head:"
                  f" {run['html_url']}")
        print("check-merge: the branch's weakening report, for the maintainer to read and acknowledge before the"
              " merge:")
        print()
        print(weakening.rstrip("\n"))
        return not blocking
    except Refused as why:
        print(f"check-merge: {named} may not be merged into main: {why}", file=sys.stderr)
        return False


def plural(count, noun):
    """count and noun, in the plural unless count is 1."""
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--repo", default=".", help="the checkout")
    parser.add_argument("--base", help="the branch to merge into (main, or origin/main, unless given)")
    parser.add_argument("--repository", help="owner/repo on GitHub (GITHUB_REPOSITORY, or gh's, unless given)")
    parser.add_argument("branch", help="the branch to merge")
    args = parser.parse_args()
    repository = args.repository or os.environ.get("GITHUB_REPOSITORY")
    try:
        if not repository:
            repository = (gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner") or "").strip()
            if not repository:
                raise Unusable("cannot tell the repository on GitHub: give --repository <owner/repo>")
        return 0 if check(Path(args.repo), args.branch, args.base, repository) else 1
    except Unusable as error:
        print(f"check-merge: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

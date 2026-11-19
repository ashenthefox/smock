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
import re
import subprocess
import sys
from pathlib import Path

L4_LIST = "mutation/l4-packages.txt"
SHA = re.compile(r"[0-9a-f]{40}")


class Unusable(Exception):
    """What makes the check unable to start: an argument that is not a
    commit's full id."""


def git(repo, *args):
    """Runs git in repo, and gives its output, or None when it fails."""
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def l4_packages(repo, sha):
    """The packages at L4 that the list names on the commit, in its order."""
    found = []
    for line in (git(repo, "show", f"{sha}:{L4_LIST}") or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if line and line not in found:
            found.append(line)
    return found


def check(repo, sha):
    """Prints whether the commit may be released, and why; whether it may."""
    named = sha[:12]
    at_l4 = l4_packages(repo, sha)
    if not at_l4:
        print(f"check-weekly-run: no package is at L4 on {named} ({L4_LIST} names none), so the release reads no"
              " weekly run and waits for none")
        return True
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
    return 0 if check(repo, args.commit) else 1


if __name__ == "__main__":
    sys.exit(main())

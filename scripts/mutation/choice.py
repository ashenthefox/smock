"""Chooses which mutants a run of the mutation runner makes, beyond its set
and the ids of --mutant (CONTRIBUTING.md, "Mutation runner"): shard k of
n of them. scripts/mutation/run.py calls it; it runs nothing itself.

The run's order is the order of the packages given, then the finder's
order within each package. A choice keeps that order, so that the shards
of a run, read in shard order, hold its mutants in its own order.
"""

import argparse
import re

SHARD = re.compile(r"^(\d+)/(\d+)$")


class ChoiceError(Exception):
    """What stops a choice: an input that names no mutant it can make."""


def shard_spec(text):
    """The k and n of a shard written "k/n", for argparse."""
    match = SHARD.match(text)
    if not match:
        raise argparse.ArgumentTypeError(f"{text!r} is not k/n, such as 2/3")
    index, count = int(match.group(1)), int(match.group(2))
    if count < 1 or not 1 <= index <= count:
        raise argparse.ArgumentTypeError(f"{text!r}: k must be from 1 to n, and n at least 1")
    return index, count


def shard(chosen, directories, index, count):
    """Shard index of count of the chosen mutants of each package: the
    index-th of count runs of the run's order, whose lengths differ by one
    at most. Each mutant is in exactly one shard, and the same mutants give
    the same shards."""
    order = [(d, s) for d in directories for s in chosen[d]]
    start, end = (index - 1) * len(order) // count, index * len(order) // count
    mine = {d: [] for d in directories}
    for directory, site in order[start:end]:
        mine[directory].append(site)
    return mine


def running(directories, chosen, mine, selected, shard_index):
    """The packages a run builds and tests, given the chosen mutants of
    each package and the shard's own (the same without shards). Without a
    selection that can leave a package with no mutant (ids, a list, a
    sample, changed lines), every package runs, as it always has: one that
    has no mutant at all runs in the first shard. Otherwise only the
    packages that hold one of the shard's mutants run."""
    first = shard_index is None or shard_index == 1
    return {d for d in directories if mine[d] or (not selected and first and not chosen[d])}

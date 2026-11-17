"""Chooses which mutants a run of the mutation runner makes, beyond its set
and the ids of --mutant (CONTRIBUTING.md, "Mutation runner"): a seeded
sample of them, stratified by package, and shard k of n of them.
scripts/mutation/run.py calls it; it runs nothing itself.

The run's order is the order of the packages given, then the finder's
order within each package. A choice keeps that order, so that the shards
of a run, read in shard order, hold its mutants in its own order.
"""

import argparse
import hashlib
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


def sample(chosen, directories, size, seed):
    """A sample of size of the chosen mutants, stratified by package: each
    package's share of it is its share of the mutants, rounded down, and
    the mutants left over go to the packages whose shares lost the most in
    rounding (the first package given wins a tie). Within a package, the
    mutants taken are those whose ids, with the seed, have the smallest
    SHA-256 hashes, so that the same seed and the same mutants give the
    same sample, whatever the version of Python."""
    total = sum(len(chosen[d]) for d in directories)
    if size >= total:
        return {d: list(chosen[d]) for d in directories}
    quotas = {d: size * len(chosen[d]) // total for d in directories}
    lost = sorted(directories, key=lambda d: (-(size * len(chosen[d]) % total), directories.index(d)))
    for directory in lost[: size - sum(quotas.values())]:
        quotas[directory] += 1
    taken = {}
    for directory in directories:
        ranked = sorted(range(len(chosen[directory])),
                        key=lambda i: (hashlib.sha256(f"{seed}\n{chosen[directory][i]['id']}".encode()).hexdigest(), i))
        keep = set(ranked[: quotas[directory]])
        taken[directory] = [s for i, s in enumerate(chosen[directory]) if i in keep]
    return taken


def running(directories, chosen, mine, selected, shard_index):
    """The packages a run builds and tests, given the chosen mutants of
    each package and the shard's own (the same without shards). Without a
    selection that can leave a package with no mutant (ids, a list, a
    sample, changed lines), every package runs, as it always has: one that
    has no mutant at all runs in the first shard. Otherwise only the
    packages that hold one of the shard's mutants run."""
    first = shard_index is None or shard_index == 1
    return {d for d in directories if mine[d] or (not selected and first and not chosen[d])}

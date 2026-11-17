#!/usr/bin/env python3
"""The mutation runner's canary (CONTRIBUTING.md, "Mutation runner", "The
canary"): a check that the runner still sees what it saw, with known
answers. The throw-away prototype of #275 sampled 250 mutants at d953f320
and recorded each one's verdict, with the package's own tests and, for its
survivors, its importers' tests. mutation/canary/mutants.jsonl holds them.
The canary replays them as a listed set (run.py --list) on the commit they
were sampled from, with the toolchain pinned there, and compares each
verdict with the recorded one. mutation/canary/explained.toml holds the
differences that were explained and that the maintainer accepted; any
other difference fails the replay.

usage: python3 scripts/mutation/canary.py sites [--finder <command>]
       python3 scripts/mutation/canary.py install [--work <dir>]
       python3 scripts/mutation/canary.py run [--work <dir>] [--out <dir>]
           [--shard <k>/<n>] [--mutant <name>]... [--moon <moon>]
           [--finder <command>]
       python3 scripts/mutation/canary.py compare [--mutant <name>]... <out>

Each takes --repo <dir>, the git repository whose history holds the
commit (the one that holds this script unless given), and --data and
--explained, the canary's files (those of mutation/canary/ unless given).

  sites    checks the data against the commit: each mutant's original
           text is at its offset there, and the site finder (sites.py, or
           --finder), run on the commit's files, still makes the mutants
           within operator set v1. Each such mutant names the v1 site that
           makes it ("v1", its id), and the finder must still give a site
           with that id that holds the mutant's place. Each other mutant
           names the rule of v1 that leaves it out ("outside"), and no site
           of the finder may make it. A narrowed or a widened finder fails
           here. It runs no mutant and no moon.
  install  checks the commit out into <work>/source and runs the commit's
           own scripts/install-moonbit.sh there, which installs the
           toolchain that the commit pins (.moonbit-version) into
           $MOON_HOME, or ~/.moon, replacing the one there.
  run      checks the commit out into <work>/source, unless it is there
           already, and stops unless the toolchain on PATH (moonc -v) is
           the one the commit pins. It checks the sites as above, then runs
           the mutants with scripts/mutation/run.py --list on the commit's
           source, in <work>/runner, with the package's own tests and its
           importers' tests, kill confirmation and the comparison of the
           compiler's output. It then compares the verdicts (as compare
           does), unless --shard runs one shard: the shards' outputs are
           merged with scripts/mutation/merge.py and compared then.
           --mutant runs only the named mutants, as on a laptop, where only
           a few may run.
  compare  compares the verdicts of a replay's output (<out>/mutants.jsonl)
           with the recorded ones and the explained differences, and
           writes canary.md and canary.json into <out>. With --mutant, it
           compares only those mutants.

A verdict is compared as killed, survived, unviable or unconfirmed. A
confirmed time-out counts as killed, as it does in the runner's score. A
mutant that the comparison of the compiler's output marks equivalent
matches a recorded survivor, and a duplicate takes the verdict of the
mutant it compiles as. An unconfirmed mutant matches nothing.

<work> is <repo>/_build/canary unless it is given, and <out> is
<work>/out. It exits with 0 when every verdict matches or is an explained
difference and the sites check out, with 1 when they do not or the replay
stops, and with 2 when its input is wrong.
"""

import argparse
import json
import posixpath
import shlex
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

import sites as finder

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DATA = REPO / "mutation" / "canary" / "mutants.jsonl"
EXPLAINED = REPO / "mutation" / "canary" / "explained.toml"
RUN = HERE / "run.py"

# The fields of a mutant of the canary: the fields of a mutant by offset in
# a listed set, then its name, its recorded verdict and the packages whose
# tests gave it.
FIELDS = {"name": str, "file": str, "offset": int, "original": str, "replacement": str, "operator": str,
          "commit": str, "verdict": str, "tests": list}
# The fields that run.py --list reads from a mutant by offset, and the name,
# which its records keep, so that a record names its mutant of the canary.
LISTED = ("name", "file", "offset", "original", "replacement", "commit", "operator")
VERDICTS = ("killed", "timed out", "survived", "unviable")
# The verdict that each outcome counts as.
VERDICT_OF = {"killed": "killed", "timed out": "killed", "survived": "survived", "equivalent": "survived",
              "unviable": "unviable", "unconfirmed": "unconfirmed"}
REPLAYED = ("killed", "survived", "unviable", "unconfirmed")
CATEGORIES = ("flaky test", "time limit", "site finder", "importers' tests")
EXPLANATION = {"mutant": str, "recorded": str, "replayed": str, "category": str, "reason": str, "accepted": str}
# What a replay that stops says, besides the runner's own reason.
MOVING = ("canary: the replay stopped. If the commit no longer builds, or its toolchain can no longer be"
          " installed, the canary moves to a new commit with new recorded verdicts, with the maintainer's"
          " approval (CONTRIBUTING.md, \"The canary\").")


class CanaryError(Exception):
    """What stops the canary before it compares: input that is wrong."""


def read_data(path):
    """The canary's mutants, in their order, after checking their fields:
    each has a name of its own, a verdict, and either the id of the v1 site
    that makes it or the rule of v1 that leaves it out, and all are on one
    commit."""
    entries = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        where = f"{path}:{number}"
        try:
            entry = json.loads(line)
        except ValueError:
            entry = None
        if not isinstance(entry, dict):
            raise CanaryError(f"{where}: a line is a JSON object")
        for field, kind in FIELDS.items():
            value = entry.get(field)
            if not isinstance(value, kind) or isinstance(value, bool) or kind is int and value < 0:
                raise CanaryError(f"{where}: a mutant has a \"{field}\" ({kind.__name__})")
        if entry["verdict"] not in VERDICTS:
            raise CanaryError(f"{where}: the verdict {entry['verdict']!r} is not one of {', '.join(VERDICTS)}")
        if not all(isinstance(t, str) for t in entry["tests"]):
            raise CanaryError(f"{where}: \"tests\" lists packages by name")
        if sum(isinstance(entry.get(f), str) and bool(entry[f]) for f in ("v1", "outside")) != 1:
            raise CanaryError(f"{where}: a mutant has either \"v1\", its site's id, or \"outside\", the rule")
        entries.append(entry)
    names = [e["name"] for e in entries]
    if len(set(names)) != len(names):
        raise CanaryError(f"{path}: two mutants have the same name")
    if not entries or len({e["commit"] for e in entries}) != 1:
        raise CanaryError(f"{path}: the mutants are on one commit")
    return entries


def read_explained(path, entries):
    """The explained differences, by mutant and replayed verdict, after
    checking that each names a mutant of the canary, its recorded verdict,
    another verdict, a category, a reason and where it was accepted."""
    try:
        with open(path, "rb") as f:
            table = tomllib.load(f)
    except (OSError, ValueError) as problem:
        raise CanaryError(f"cannot read {path}: {problem}") from problem
    if set(table) - {"difference"}:
        raise CanaryError(f"{path}: only [[difference]] tables belong here")
    recorded = {e["name"]: e["verdict"] for e in entries}
    explained = {}
    for number, item in enumerate(table.get("difference", []), 1):
        where = f"{path}: difference {number}"
        for field, kind in EXPLANATION.items():
            if not isinstance(item.get(field), kind) or not item[field].strip():
                raise CanaryError(f"{where} has no \"{field}\"")
        if set(item) - set(EXPLANATION):
            raise CanaryError(f"{where}: unknown fields {sorted(set(item) - set(EXPLANATION))}")
        name = item["mutant"]
        if name not in recorded:
            raise CanaryError(f"{where}: {name!r} names no mutant of the canary")
        if item["recorded"] != recorded[name]:
            raise CanaryError(f"{where}: {item['recorded']!r} is not the recorded verdict of {name},"
                              f" {recorded[name]!r}")
        if item["replayed"] not in REPLAYED:
            raise CanaryError(f"{where}: replayed is one of {', '.join(REPLAYED)}")
        if item["replayed"] == VERDICT_OF[recorded[name]]:
            raise CanaryError(f"{where}: {name} replayed as {item['replayed']} is no difference")
        if item["category"] not in CATEGORIES:
            raise CanaryError(f"{where}: the category is one of {', '.join(CATEGORIES)}")
        if (name, item["replayed"]) in explained:
            raise CanaryError(f"{where}: {name} replayed as {item['replayed']} is explained twice")
        explained[(name, item["replayed"])] = item
    return explained


def git(repo, *args):
    """The output of a git command in repo, as bytes."""
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    if result.returncode != 0:
        raise CanaryError(f"git {' '.join(args)}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def directories(entries):
    """The package directories of the mutants' files, in the data's order."""
    found = []
    for entry in entries:
        directory = posixpath.dirname(entry["file"])
        if directory not in found:
            found.append(directory)
    return found


def export(repo, commit, packages, into):
    """Writes the .mbt files of the package directories, as the commit holds
    them, into a directory: what the site finder reads of a package."""
    for directory in packages:
        names = git(repo, "ls-tree", "--name-only", commit, "--", f"{directory}/").decode("utf-8").splitlines()
        for name in names:
            if name.endswith(".mbt"):
                path = into / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(git(repo, "show", f"{commit}:./{name}"))


def text_problems(entries, root):
    """Where a mutant's original text is not at its offset in the file under
    root, which holds the commit's files."""
    problems = []
    for entry in entries:
        path = root / entry["file"]
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        if text[entry["offset"] : entry["offset"] + len(entry["original"])] != entry["original"]:
            problems.append(f"{entry['name']}: {entry['file']} does not hold {json.dumps(entry['original'])}"
                            f" at offset {entry['offset']} on {entry['commit']}")
    return problems


def finder_sites(command, root, packages):
    """The sites of the full set that the site finder makes in the package
    directories under root; the sites that a rule skipped are left out."""
    result = subprocess.run([*command, "--root", str(root), "--set", "full", *packages], capture_output=True,
                            text=True)
    if result.returncode != 0:
        raise CanaryError(f"the site finder failed on {root}:\n{result.stderr}")
    return [s for s in map(json.loads, result.stdout.splitlines()) if "id" in s]


def trimmed(source, start, end):
    """A span of a file without the white space at its edges."""
    while start < end and source.text[start].isspace():
        start += 1
    while end > start and source.text[end - 1].isspace():
        end -= 1
    return start, end


def site_problems(entries, root, found):
    """Where the site finder's sites (found) disagree with what the data
    records: a mutant within operator set v1 whose site the finder no
    longer makes, or makes elsewhere, and a mutant recorded outside v1 that
    a site makes."""
    by_id = {s["id"]: s for s in found}
    sources, effects = {}, {}
    for entry in entries:
        file = entry["file"]
        if file not in sources:
            sources[file] = finder.SourceFile(Path(file), (root / file).read_text(encoding="utf-8"))
            effects[file] = {}
            for site in found:
                if site["file"] == file:
                    start = sources[file].offset(site["line"], site["column"])
                    made = finder.effect(sources[file], start, start + len(site["original"]), site["replacement"])
                    effects[file].setdefault(made, site["id"])
    problems = []
    for entry in entries:
        source = sources[entry["file"]]
        start, end = entry["offset"], entry["offset"] + len(entry["original"])
        if "v1" in entry:
            site = by_id.get(entry["v1"])
            if site is None:
                problems.append(f"{entry['name']}: the site finder makes no site {entry['v1']}")
                continue
            # The site holds the mutant's place: a site of v1 that makes the
            # same mutant as a change written another way (CONTRIBUTING, "The
            # canary") holds the change's text, without its edges' white space.
            first = source.offset(site["line"], site["column"])
            low, high = trimmed(source, start, end)
            if site["file"] != entry["file"] or not first <= low <= high <= first + len(site["original"]):
                problems.append(f"{entry['name']}: the site {entry['v1']} is not at its place,"
                                f" {entry['file']} offset {entry['offset']}")
        else:
            made = effects[entry["file"]].get(finder.effect(source, start, end, entry["replacement"]))
            if made is not None:
                problems.append(f"{entry['name']}: the site {made} makes it, though it is recorded outside"
                                f" operator set v1 ({entry['outside']})")
    return problems


def check_sites(entries, root, command):
    """The problems of the data on the commit's files under root: texts not
    at their offsets, and sites that disagree with the data."""
    problems = text_problems(entries, root)
    if problems:
        return problems
    return site_problems(entries, root, finder_sites(command, root, directories(entries)))


def sites_line(entries, problems):
    """What the check of the sites prints."""
    within = sum("v1" in e for e in entries)
    if problems:
        return "\n".join(["sites: the canary's data disagrees with its commit or the site finder:"]
                         + [f"- {p}" for p in problems])
    return (f"sites: {len(entries)} mutants on {entries[0]['commit'][:8]}: {within} within operator set v1, each"
            f" made by the site it names, and {len(entries) - within} outside it, made by no site.")


def replayed_verdicts(records, by_id):
    """Each record's verdict: a duplicate takes the verdict of the mutant
    it compiles as."""
    verdicts = []
    for record in records:
        outcome = record["outcome"]
        if outcome == "duplicate":
            first = by_id.get(record.get("duplicate_of"))
            outcome = first["outcome"] if first is not None else "duplicate of a mutant not replayed"
        verdicts.append(VERDICT_OF.get(outcome, outcome))
    return verdicts


def compare(entries, explained, records, names=None):
    """Compares the replay's records with the recorded verdicts of the
    mutants named (all, unless names are given): the summary that
    canary.json holds."""
    by_name = {e["name"]: e for e in entries}
    mine = {}
    for record in records:
        name = (record.get("listed") or {}).get("name")
        if name not in by_name:
            raise CanaryError(f"the record of {record.get('id')} names no mutant of the canary")
        mine[name] = record
    by_id = {r["id"]: r for r in records}
    verdict = dict(zip(mine, replayed_verdicts(list(mine.values()), by_id)))
    chosen = [e for e in entries if names is None or e["name"] in names]
    matched, unexplained, found = 0, [], []
    for entry in chosen:
        name = entry["name"]
        record = mine.get(name)
        replayed = verdict.get(name, "not replayed")
        if replayed == VERDICT_OF[entry["verdict"]]:
            matched += 1
            continue
        row = {"mutant": name, "file": entry["file"], "line": record["line"] if record else None,
               "operator": entry["operator"], "recorded": entry["verdict"], "replayed": replayed,
               "outcome": record["outcome"] if record else None,
               "killing_tests": [t.get("name") for t in record.get("killing_tests", [])] if record else []}
        reason = explained.get((name, replayed))
        if reason is None:
            unexplained.append(row)
        else:
            found.append(dict(row, category=reason["category"], reason=reason["reason"],
                              accepted=reason["accepted"]))
    seen = {(d["mutant"], d["replayed"]) for d in found}
    chosen_names = {e["name"] for e in chosen}
    not_seen = [dict(item) for key, item in explained.items() if key not in seen and key[0] in chosen_names]
    return {"commit": entries[0]["commit"], "mutants": len(chosen), "matched": matched,
            "explained": found, "unexplained": unexplained, "not_seen": not_seen}


def report(summary):
    """The canary's report, in Markdown."""
    out = ["# Mutation canary", "",
           f"{summary['mutants']} mutants of the canary, replayed on {summary['commit'][:8]}: {summary['matched']}"
           f" gave the recorded verdict, {len(summary['explained'])} an explained difference, and"
           f" {len(summary['unexplained'])} an unexplained one.", ""]
    if not summary["unexplained"]:
        out += ["Every verdict is the recorded one, or an explained difference.", ""]
    else:
        out += [f"## Unexplained differences ({len(summary['unexplained'])})", "",
                "Each fails the replay until it is explained on #275 and the maintainer accepts it"
                " (mutation/canary/explained.toml).", "",
                "| mutant | where | recorded | replayed | outcome | tests that failed |", "|---|---|---|---|---|---|"]
        for row in summary["unexplained"]:
            where = f"{row['file']}:{row['line']}" if row["line"] else row["file"]
            out += [f"| `{row['mutant']}` | {where} | {row['recorded']} | {row['replayed']} |"
                    f" {row['outcome'] or 'none'} | {', '.join(row['killing_tests']) or 'none'} |"]
        out += [""]
    if summary["explained"]:
        out += [f"## Explained differences ({len(summary['explained'])})", "",
                "| mutant | recorded | replayed | category | reason | accepted |", "|---|---|---|---|---|---|"]
        out += [f"| `{d['mutant']}` | {d['recorded']} | {d['replayed']} | {d['category']} | {d['reason']} |"
                f" {d['accepted']} |" for d in summary["explained"]]
        out += [""]
    if summary["not_seen"]:
        out += [f"## Explained differences that this replay did not give ({len(summary['not_seen'])})", ""]
        out += [f"- `{d['mutant']}`, {d['recorded']} replayed as {d['replayed']} ({d['category']})"
                for d in summary["not_seen"]]
        out += [""]
    return "\n".join(out)


def compare_output(entries, explained, out, names):
    """Compares a replay's output directory and writes canary.md and
    canary.json there: whether every verdict matched or was explained."""
    path = out / "mutants.jsonl"
    try:
        records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, ValueError) as problem:
        raise CanaryError(f"cannot read the replay's records {path}: {problem}") from problem
    summary = compare(entries, explained, records, names)
    (out / "canary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    text = report(summary)
    (out / "canary.md").write_text(text, encoding="utf-8")
    print(text)
    return not summary["unexplained"]


def chosen_names(entries, names):
    """The names given, after checking that each is a mutant's of the
    canary, or None for all."""
    if not names:
        return None
    known = {e["name"] for e in entries}
    unknown = [n for n in names if n not in known]
    if unknown:
        raise CanaryError(f"no mutant of the canary is named {', '.join(unknown)}")
    return set(names)


def checkout(repo, commit, path):
    """Checks the commit out at path, as a worktree of repo without a
    branch, unless a clean checkout of it is there already: the path."""
    path = Path(path).resolve()
    if path.exists():
        top = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel", "HEAD"], capture_output=True,
                             text=True)
        lines = top.stdout.split()
        if top.returncode != 0 or len(lines) != 2 or Path(lines[0]).resolve() != path:
            raise CanaryError(f"{path} is in the way of the canary's checkout: remove it")
        if lines[1] == commit and not git(path, "status", "--porcelain").strip():
            return path
        git(repo, "worktree", "remove", "--force", str(path))
    git(repo, "worktree", "prune")
    path.parent.mkdir(parents=True, exist_ok=True)
    git(repo, "worktree", "add", "--detach", str(path), commit)
    return path


def toolchain_problem(repo, commit):
    """Why the toolchain on PATH is not the one the commit pins in
    .moonbit-version, or None when it is."""
    pinned = git(repo, "show", f"{commit}:./.moonbit-version").decode("utf-8").strip()
    try:
        result = subprocess.run(["moonc", "-v"], capture_output=True, text=True)
        words = result.stdout.split()
        installed = words[0].removeprefix("v") if result.returncode == 0 and words else None
    except OSError:
        installed = None
    if installed == pinned:
        return None
    return (f"{commit} pins MoonBit {pinned}, but moonc on PATH is {installed or 'missing'}: install it with"
            " `python3 scripts/mutation/canary.py install`, which replaces the toolchain in $MOON_HOME"
            " (on a laptop, use a machine of its own or wait until the pin is the same)")


def install(repo, commit, work):
    """Checks the commit out into <work>/source and runs its own
    scripts/install-moonbit.sh there, to install the toolchain it pins:
    the script's exit status."""
    source = checkout(repo, commit, work / "source")
    script = source / "scripts" / "install-moonbit.sh"
    if not script.is_file():
        raise CanaryError(f"{commit} has no scripts/install-moonbit.sh to install its toolchain with")
    return subprocess.run(["sh", str(script), "pinned"], cwd=source).returncode


def replay(args, entries, explained, names, command):
    """The run command: checks the commit out, checks the toolchain and the
    sites, runs the chosen mutants as a listed set with run.py, and
    compares their verdicts unless it ran one shard. Whether all went
    well."""
    work = Path(args.work).resolve() if args.work else Path(args.repo).resolve() / "_build" / "canary"
    out = Path(args.out).resolve() if args.out else work / "out"
    commit = entries[0]["commit"]
    source = checkout(args.repo, commit, work / "source")
    problem = toolchain_problem(args.repo, commit)
    if problem is not None:
        print(f"canary: {problem}", file=sys.stderr)
        return False
    problems = check_sites(entries, source, command)
    print(sites_line(entries, problems), flush=True)
    listing = work / "list.jsonl"
    with open(listing, "w", encoding="utf-8") as f:
        for entry in entries:
            if names is None or entry["name"] in names:
                f.write(json.dumps({k: entry[k] for k in LISTED}, ensure_ascii=False) + "\n")
    runner = [sys.executable, str(RUN), "--root", str(source), "--work", str(work / "runner"), "--out", str(out),
              "--list", str(listing), "--moon", args.moon]
    runner += ["--finder", args.finder] if args.finder else []
    runner += ["--shard", args.shard] if args.shard else []
    if subprocess.run(runner).returncode != 0:
        print(MOVING, file=sys.stderr)
        return False
    if args.shard:
        return not problems
    ok = compare_output(entries, explained, out, names)
    if problems:
        print(sites_line(entries, problems))
    return ok and not problems


def main():
    parser = argparse.ArgumentParser(description="Replay the mutation runner's canary and compare its verdicts.")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("sites", "install", "run", "compare"):
        command = commands.add_parser(name)
        command.add_argument("--repo", default=str(REPO), help="the git repository whose history holds the commit")
        command.add_argument("--data", default=str(DATA), help="the canary's mutants")
        command.add_argument("--explained", default=str(EXPLAINED), help="the explained differences")
        if name in ("install", "run"):
            command.add_argument("--work", help="the canary's directory (default <repo>/_build/canary)")
        if name in ("sites", "run"):
            command.add_argument("--finder", help="the site finder's command (default: sites.py)")
        if name in ("run", "compare"):
            command.add_argument("--mutant", action="append", help="only the mutant with this name")
        if name == "run":
            command.add_argument("--out", help="where the replay's output goes (default <work>/out)")
            command.add_argument("--shard", help="run only shard K/N of the mutants, and compare nothing")
            command.add_argument("--moon", default="moon", help="the moon command")
        if name == "compare":
            command.add_argument("out", help="the replay's output directory")
    args = parser.parse_args()
    try:
        entries = read_data(args.data)
        explained = read_explained(args.explained, entries)
        names = chosen_names(entries, getattr(args, "mutant", None))
        command = shlex.split(args.finder) if getattr(args, "finder", None) else [sys.executable,
                                                                                  str(HERE / "sites.py")]
        if args.command == "sites":
            with tempfile.TemporaryDirectory(prefix="canary-sites-") as tmp:
                export(args.repo, entries[0]["commit"], directories(entries), Path(tmp))
                problems = check_sites(entries, Path(tmp), command)
            print(sites_line(entries, problems))
            sys.exit(1 if problems else 0)
        if args.command == "install":
            work = Path(args.work).resolve() if args.work else Path(args.repo).resolve() / "_build" / "canary"
            sys.exit(1 if install(args.repo, entries[0]["commit"], work) else 0)
        if args.command == "run":
            sys.exit(0 if replay(args, entries, explained, names, command) else 1)
        if args.command == "compare":
            ok = compare_output(entries, explained, Path(args.out), names)
            sys.exit(0 if ok else 1)
    except CanaryError as error:
        print(f"canary: {error}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()

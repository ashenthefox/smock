#!/usr/bin/env python3
"""Coverage from the e2e tests, merged with the in-process tests' (#342;
CONTRIBUTING.md, "Coverage from the e2e tests"): which points of each
package the in-process tests reach, which the e2e tests reach in the
binary, and which no test reaches. scripts/coverage-e2e.sh runs both
suites and then this report.

usage: python3 scripts/coverage-e2e.py report --in-process <report> --e2e <report> --out <dir>
           [--root <dir>] [--trees <dir>] [--moonc <moonc>]
           [--tests <file> --tests-status <n>] [--times <file>]
       python3 scripts/coverage-e2e.py triage --report <dir> --out <dir> [--max <n>]
           [--bodies <dir>] [--run-url <url>]

report  reads two bisect reports of moon_cove, the toolchain's coverage
        reader, made of the same trace sources (scripts/coverage-report.py
        reads the format): the in-process tests' (scripts/coverage.sh) and
        the e2e tests', of the counters that the smock processes of the
        e2e tests dumped. A point is reached when its count is above 0 in
        either. Their paths are relative to <root>, the current directory
        unless given. --tests is what moon printed of the e2e run, and
        --tests-status how it exited: the report starts with how many tests
        ran and names those that failed. It reports only: a failed test
        fails nothing, and the report says that the e2e tests' report may
        then lack points. --times gives the time of each step of the run,
        a line each, its seconds, a tab and what it is. It writes into
        <out>, and prints report.md:

          report.md         per package, the points reached in-process, by
                            e2e and by either, and those that no test
                            reaches; the rule that decides which positions
                            e2e covers, and how many it covers in server and
                            cmd/smock (POSITION_PACKAGES); and the points
                            that no test reaches in LISTED, by file and
                            definition;
          unreached.json    those points, for the triage;
          either.bisect     the two reports merged, each point's counts
                            added up;
          covered-by-e2e.jsonl, not-covered-by-e2e.jsonl
                            the pinned set's mutants of server and cmd/smock
                            at the positions e2e covers, and at the others,
                            as lists of mutants by key, which the mutation
                            runner reads (run.py --list); each line also
                            gives the mutant's id, line and column, and the
                            body and the point that decided its position.

        The positions are the site finder's (scripts/mutation/sites.py),
        on the compiler's parse tree of each file: moonc writes it, or
        <trees>/<path>.ast when --trees is given, as the tests give it.
        RULE says when e2e covers a position.

triage  cuts the points that no test reaches in server and cmd/smock, in
        unreached.json of a report's output (<report>), those that a
        DEFERRED entry covers included, into triage tickets for their
        closing ticket (CLOSING) when there are more than --max of them
        (about 40, TRIAGE_MAX): at most --max each, a source file that holds
        fewer never split, a larger one cut into equal parts. It writes into
        <out> a body for each ticket, tickets.json (each ticket's title,
        label, points, blockers and the ticket it blocks) and tickets.md;
        each body carries the closing ticket's triage criteria for its
        points, from <bodies>/<number>.md when it is given.

It exits with 2, saying why, when it cannot read a report, when the two
reports do not hold the same points, which were then made of other trace
sources, or when a file does not parse.
"""

import argparse
import bisect
import importlib.util
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "mutation"))
import bulk  # noqa: E402 (the bulk runs' cut of triage tickets)
import sites as finder  # noqa: E402 (the site finder, beside the runner)

# The packages whose positions the report decides: those that only the
# binary runs, which the run at operator level mutates through e2e (#346).
POSITION_PACKAGES = ("server", "cmd/smock")
# The packages whose points that no test reaches the report lists: those
# that only the binary runs, and the small native-only packages that e2e
# reaches too (#347).
LISTED = ("server", "cmd/smock", "defdir", "watch", "openssl")
# The closing ticket of the triage of what no test reaches in server and
# cmd/smock, what its triage tickets wait for (this ticket and the two
# that moved server's parsers out, #318 and #319), and the starts of its
# criteria that they carry: all but the one that checks the result after
# the triage.
CLOSING = 343
BLOCKERS = (342, 318, 319)
TRIAGE_CRITERIA = ("Every point", "**Dead code**", "**Missing tests**", "**Exclusions**",
                   "**Points no dump can show.**", "Request path")
# How many points a triage ticket holds at most (#342: "about 40").
TRIAGE_MAX = 40
# The bodies whose point decides a position, as #342 names them, and how
# the report names one.
KINDS = {"function": "a function", "then": "a then", "else": "an else", "arm": "a match arm"}
# When e2e covers a position, as the report states it: #342's rule, then
# what it means where the ticket is silent.
RULE = (
    "A position counts as covered by e2e when the point that starts the innermost function, then, else or"
    " match-arm body around it has a count above zero in the e2e tests' report.",
    "A function is a top-level"
    " function or method, `fn main` or `fn init`, a closure or a local function, and its parameters' default"
    " values are in it; an else is an if's or a guard's; a match arm is an arm of a match, a loop, a catch or a"
    " noraise. The point that starts a body is the first between what comes before the body (a function's"
    " parameters, an if's condition, the then, a guard's condition, an arm's pattern or guard) and the body's"
    " end. A loop's body is none of these, so a position in it counts as the body around the loop, and so"
    " does a position in a body that the compiler started with no point. A position in no such body, in a"
    " top-level value or a constant, counts as covered when a point of its package has a count above zero in"
    " the e2e tests' report: the program initialises its values when it starts."
)


def load(name, path):
    """A script beside this one, as a module."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage_report = load("coverage_report", HERE / "coverage-report.py")
ReportError = coverage_report.ReportError


def same_points(in_process, e2e):
    """Checks that two bisect reports hold the same points: the same files,
    each with the same offsets."""
    mine = {name: sorted(offset for offset, _ in points) for name, points in in_process}
    theirs = {name: sorted(offset for offset, _ in points) for name, points in e2e}
    for name in sorted(set(mine) | set(theirs)):
        if name not in mine or name not in theirs:
            raise ReportError(f"the two reports do not hold the same points: {name} is in one only")
        if mine[name] != theirs[name]:
            raise ReportError(f"the two reports do not hold the same points: {name} differs")


def counts(report):
    """Each point's count in a report, by file and offset."""
    found = {}
    for name, points in report:
        mine = found.setdefault(name, {})
        for offset, count in points:
            mine[offset] = mine.get(offset, 0) + count
    return found


def write_bisect(path, files):
    """Writes a bisect report of format 4: for each file, its path, the
    offsets of its points and their counts."""
    words = ["BISECT-COVERAGE-4", str(len(files))]
    for name, points in files:
        words += [str(len(name.encode("utf-8"))), name, str(len(points))]
        words += [str(offset) for offset, _ in points]
        words += [str(len(points))] + [str(count) for _, count in points]
    Path(path).write_text(" ".join(words) + "\n", encoding="utf-8")


def percent(part, whole):
    """part of whole, as a percentage with one decimal."""
    return f"{100 * part / whole:.1f}%" if whole else "-"


def package_of(name):
    """The package of a file: its directory."""
    return str(Path(name).parent)


def table(in_process, e2e, either):
    """The table of the packages: their points, those reached in-process, by
    e2e and by either, and those no test reaches, after the exclusion
    list."""
    rows = {}
    for name, points in in_process.items():
        row = rows.setdefault(package_of(name), {"points": 0, "in-process": 0, "e2e": 0, "either": 0})
        for offset, count in points.items():
            other = e2e[name][offset]
            row["points"] += 1
            row["in-process"] += count > 0
            row["e2e"] += other > 0
            row["either"] += count > 0 or other > 0
    lines = ["| package | points | in-process | e2e | either | unreached |", "|---|---:|---:|---:|---:|---:|"]
    total = {"points": 0, "in-process": 0, "e2e": 0, "either": 0, "unreached": 0}
    for package in sorted(rows):
        row = rows[package]
        row["unreached"] = len(either[package].uncovered)
        for key in total:
            total[key] += row[key]
    for package, row in sorted(rows.items()) + [("all", total)]:
        cells = [f"{row[key]} ({percent(row[key], row['points'])})" for key in ("in-process", "e2e", "either")]
        lines.append(f"| {package} | {row['points']} | {' | '.join(cells)} | {row['unreached']} |")
    return lines


class Body(NamedTuple):
    """A body whose point decides the positions in it: its kind (KINDS);
    where its positions start, where its point is looked for and where it
    ends, as offsets in characters; and where its own text starts, which
    names it."""

    kind: str
    start: int
    point_from: int
    end: int
    first: int


def extent(item, node):
    """The first and the last position of a node of the parse tree: those of
    the locations anywhere in it, or None."""
    found = [span for current in finder.walk(node) for atom in current if (span := item.loc(atom))]
    if not found:
        return None
    return min(span[0] for span in found), max(span[1] for span in found)


def arms(node):
    """The arms of a match, a loop or a try (its catch's and its noraise's):
    each a list of its pattern, its guard if it has one, and its body."""
    lists = [node[2]] if len(node) > 2 else []
    if finder.head_of(node) == "Pexpr_try" and len(node) > 4 and isinstance(node[4], list) and node[4]:
        lists.append(node[4][0])
    for cases in lists:
        for case in cases if isinstance(cases, list) else []:
            if isinstance(case, list) and len(case) >= 2 and isinstance(case[-1], list):
                yield case


def bodies(source, item):
    """The bodies of a top-level definition, as Bodies."""
    found = []

    def add(kind, start, point_from, end, node):
        span = extent(item, node)
        if None not in (start, point_from, end) and span:
            found.append(Body(kind, source.offset(*start), source.offset(*point_from), source.offset(*end),
                              source.offset(*span[0])))

    parts = item.function()
    span = item.own_span()
    if parts is not None and finder.head_of(parts[0]) == "Decl_body" and span:
        ends = [item.loc(atom)[1] for node in finder.walk(parts[2]) for atom in node if item.loc(atom)]
        add("function", span[0], max(ends), span[1], parts[0])
    elif item.node[0] == "Ptop_expr" and span:
        add("function", span[0], span[0], span[1], item.node)
    for node in finder.walk(item.node):
        head = finder.head_of(node)
        if head is None and all(finder.child(node, key) for key in ("params_loc_", "body", "loc_")):
            params, whole = item.loc(finder.child(node, "params_loc_")[1]), item.loc(finder.child(node, "loc_")[1])
            if params and whole:
                add("function", whole[0], params[1], whole[1], finder.child(node, "body")[1])
        elif head == "Pexpr_if" and len(node) >= 5:
            condition, then = extent(item, node[1]), extent(item, node[2])
            if condition and then:
                add("then", condition[1], condition[1], then[1], node[2])
                if node[3] and (otherwise := extent(item, node[3][0])):
                    add("else", then[1], then[1], otherwise[1], node[3][0])
        elif head == "Pexpr_guard" and len(node) >= 4 and node[2]:
            condition, otherwise = extent(item, node[1]), extent(item, node[2][0])
            if condition and otherwise:
                add("else", condition[1], condition[1], otherwise[1], node[2][0])
        elif head in ("Pexpr_match", "Pexpr_loop", "Pexpr_try"):
            for case in arms(node):
                guards = [element for element in case if finder.head_of(element) == "guard"]
                before, body = extent(item, guards[0] if guards else case[0]), extent(item, case[-1])
                if before and body:
                    add("arm", before[1], before[1], body[1], case[-1])
    return found


def character_offsets(data, points):
    """A file's points, from their offsets in bytes to their offsets in
    characters, as the parse tree counts them: (offset, count), sorted."""
    found, at, characters = [], 0, 0
    for offset, count in sorted(points.items()):
        characters += len(data[at:offset].decode("utf-8"))
        at = offset
        found.append((characters, count))
    return found


def position(source, offset):
    """An offset, as the report names a position: <file>:<line>:<column>."""
    line, column = source.position(offset)
    return f"{source.path.as_posix()}:{line}:{column}"


def tree_of(args, workdir, index, path, text):
    """The compiler's parse tree of a file: from --trees, or from moonc."""
    if args.trees:
        return (Path(args.trees) / f"{path.as_posix()}.ast").read_text(encoding="utf-8")
    return finder.dump(args.moonc, "wasm-gc", workdir, index, path, text)


def decide(args, root, e2e):
    """The pinned set's mutants of POSITION_PACKAGES, each with whether e2e
    covers its position by RULE, and the body and point that decided it;
    and the bodies that the compiler started with no point."""
    decided, pointless = [], []
    reached = {}
    for name, points in e2e.items():
        package = package_of(name)
        reached[package] = reached.get(package, False) or any(count > 0 for count in points.values())
    with tempfile.TemporaryDirectory(prefix="smock-coverage-e2e-") as tmp:
        index = 0
        for package in POSITION_PACKAGES:
            if not (root / package).is_dir():
                continue
            for path in finder.source_files(root, [package]):
                text = (root / path).read_text(encoding="utf-8")
                if finder.is_generated(text):
                    continue
                index += 1
                source = finder.SourceFile(path, text)
                tree = tree_of(args, Path(tmp), index, path, text)
                points = character_offsets((root / path).read_bytes(), e2e.get(path.as_posix(), {}))
                offsets = [offset for offset, _ in points]
                found = []
                for entry in finder.parse_tree(tree):
                    item = finder.Item(source, entry[1], entry[2])
                    if not item.is_test():
                        found += [(item.name(), body) for body in bodies(source, item)]
                started = {}
                for name, body in found:
                    at = bisect.bisect_left(offsets, body.point_from)
                    if at < len(offsets) and offsets[at] < body.end:
                        same = [count for offset, count in points if offset == offsets[at]]
                        started[body] = (offsets[at], max(same))
                    else:
                        pointless.append((position(source, body.first), body.kind, name))
                for site in finder.file_sites(source, tree):
                    if not site.get("pinned") or "skipped" in site:
                        continue
                    offset = source.offset(site["line"], site["column"])
                    around = [body for body in started if body.start <= offset < body.end]
                    if around:
                        body = max(around, key=lambda b: (b.start, -b.end))
                        point, count = started[body]
                        site = dict(site, body=body.kind, point=position(source, point), covered=count > 0)
                    else:
                        site = dict(site, body="top-level value", point=None, covered=reached.get(package, False))
                    decided.append((package, site))
    return decided, pointless


# The fields of a mutant by key, in a list the runner reads (choice.py).
KEY = ("file", "definition", "operator", "original", "replacement", "ordinal")


def write_list(path, sites):
    """Writes the sites as a list of mutants by key, one JSON object a line,
    with their id, line, column, body and point."""
    lines = [json.dumps({**{key: site[key] for key in KEY}, "id": site["id"], "line": site["line"],
                         "column": site["column"], "body": site["body"], "point": site["point"]},
                        ensure_ascii=False) for site in sites]
    Path(path).write_text("".join(line + "\n" for line in lines), encoding="utf-8")


def positions_section(decided, pointless):
    """The report's lines on the positions e2e covers."""
    lines = ["## The positions e2e covers", "", RULE[0], "", RULE[1], "",
             "| package | positions | covered by e2e | not covered | mutants of the pinned set at covered positions |",
             "|---|---:|---:|---:|---:|"]
    for package in POSITION_PACKAGES:
        mine = [site for name, site in decided if name == package]
        if not mine:
            continue
        places = {(s["file"], s["operator"], s["line"], s["column"]): s["covered"] for s in mine}
        covered = sum(1 for value in places.values() if value)
        lines.append(f"| {package} | {len(places)} | {covered} | {len(places) - covered}"
                     f" | {sum(1 for s in mine if s['covered'])} |")
    lines += ["", "The pinned set's mutants at the positions e2e covers are in `covered-by-e2e.jsonl`, and those"
              " at the others in `not-covered-by-e2e.jsonl`: lists of mutants by key, which the mutation runner"
              " reads (`run.py --list`).", ""]
    if pointless:
        lines += [f"Bodies that the compiler started with no point ({len(pointless)}), which count as none:", ""]
        lines += [f"- `{place}`, {KINDS[kind]} in `{name}`" for place, kind, name in pointless]
    else:
        lines += ["Every body of these kinds starts with a point."]
    return lines + [""]


def point_of(file, line, column, definition, **more):
    """A point, as unreached.json gives it."""
    return {"point": f"{file}:{line}:{column}", "file": file, "line": line, "column": column,
            "definition": definition, **more}


def unreached(either):
    """The points that no test reaches in LISTED, and those the exclusion
    list accepts, per package, as unreached.json gives them."""
    found = {}
    for name in LISTED:
        package = either.get(name)
        if package is None:
            continue
        found[name] = {
            "points": package.points,
            "unreached": [point_of(*place, deferred=package.deferred.get(place[:3]))
                          for place in package.uncovered],
            "accepted": [point_of(*place[:4], category=place[4]) for place in package.accepted],
        }
    return found


def unreached_section(found, exclusions):
    """The report's lines on the points that no test reaches."""
    lines = ["## The points no test reaches", "",
             f"In {', '.join(LISTED[:-1])} and {LISTED[-1]}, by file and definition: the points whose count is 0 in"
             " both reports. A point that a DEFERRED entry of the exclusion list covers is listed with its issue,"
             " since it is not resolved yet; the points that the list's other entries accept are listed apart.", ""]
    for name, package in found.items():
        mine = package["unreached"]
        if mine:
            lines += [f"### {name}: {len(mine)} of {package['points']} points unreached", ""]
            lines += [f"- `{p['point']}` in `{p['definition']}`"
                      + (f" (DEFERRED to #{p['deferred']})" if p["deferred"] is not None else "") for p in mine]
        else:
            lines += [f"### {name}: every point reached"]
        lines += [""]
        accepted = package["accepted"]
        if accepted:
            lines += [f"### {name}: {len(accepted)} point{'' if len(accepted) == 1 else 's'} accepted by the"
                      " exclusion list", ""]
            lines += [f"- `{p['point']}` in `{p['definition']}`, {p['category']}" for p in accepted] + [""]
    if exclusions is not None and exclusions.stale:
        lines += ["Stale entries of the exclusion list, which accept nothing: "
                  + ", ".join(entry.key for entry in exclusions.stale), ""]
    return lines


# moon's lines of a failed test and of the summary of a run.
FAILED = re.compile(r'^\[[^\]]*\] test (\S+:\d+) \("(.*)"\) failed')
SUMMARY = re.compile(r"^Total tests: (\d+), passed: (\d+), failed: (\d+)\.$")


def tests_section(path, status):
    """The report's lines on the e2e run: how many tests ran, and those
    that failed."""
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    summary = [match for line in lines if (match := SUMMARY.match(line.strip()))]
    if not summary:
        return [f"**moon printed no summary of the e2e tests, and exited with {status}**, so the e2e tests' report"
                " may lack the points they reach.", ""]
    total, passed, failed = (int(n) for n in summary[-1].groups())
    out = [f"The e2e tests ran {total} tests with the instrumented binary: {passed} passed, {failed} failed.", ""]
    if failed:
        out += [f"**{failed} of the {total} e2e tests failed**, so the e2e tests' report may lack points they would"
                " have reached after they failed. The report reports only, and fails nothing for it:", ""]
        out += [f"- `{match.group(1)}` {match.group(2)}" for line in lines if (match := FAILED.match(line))]
        out += [""]
    return out


def times_section(path):
    """The report's lines on the time each step of the run took."""
    rows = [line.split("\t", 1) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]
    out = ["| step | time |", "|---|---:|"]
    out += [f"| {what} | {bulk.duration(int(seconds))} |" for seconds, what in rows]
    out += [f"| all | {bulk.duration(sum(int(seconds) for seconds, _ in rows))} |", ""]
    return out


def read(path):
    """The files of a bisect report, or the error naming the report."""
    try:
        return coverage_report.read_report(path)
    except ReportError as error:
        raise ReportError(f"{path}: {error}") from None


def report(args):
    """Writes the report into args.out; returns it."""
    root = Path(args.root)
    in_process, e2e = read(args.in_process), read(args.e2e)
    same_points(in_process, e2e)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    in_counts, e2e_counts = counts(in_process), counts(e2e)
    merged = [(name, [(offset, count + e2e_counts[name][offset]) for offset, count in points])
              for name, points in in_process]
    write_bisect(out / "either.bisect", merged)
    exclusions = coverage_report.read_exclusions(root)
    either = coverage_report.read_packages(out / "either.bisect", root, exclusions)
    decided, pointless = decide(args, root, e2e_counts)
    write_list(out / "covered-by-e2e.jsonl", [site for _, site in decided if site["covered"]])
    write_list(out / "not-covered-by-e2e.jsonl", [site for _, site in decided if not site["covered"]])
    found = unreached(either)
    (out / "unreached.json").write_text(json.dumps({"packages": found}, indent=2, ensure_ascii=False) + "\n",
                                        encoding="utf-8")
    lines = ["# Coverage from the e2e tests", ""]
    if args.tests:
        lines += tests_section(args.tests, args.tests_status)
    if args.times:
        lines += times_section(args.times)
    lines += ["Per package, the points that the in-process tests reach, those that the e2e tests reach in the binary,"
              " and those that either reaches; unreached counts the points that neither reaches, after the exclusion"
              " list. The e2e tests' own process counts for nothing: the e2e package is built without coverage, so"
              " only the counters of the smock processes it starts are read.", "",
              *table(in_counts, e2e_counts, either), "",
             *positions_section(decided, pointless), *unreached_section(found, exclusions)]
    text = "\n".join(lines)
    (out / "report.md").write_text(text, encoding="utf-8")
    return text


def closing_criteria(bodies):
    """The criteria of the closing ticket that its triage tickets carry,
    from its body in bodies; None without it."""
    path = Path(bodies) / f"{CLOSING}.md" if bodies else None
    if path is None or not path.is_file():
        return None
    return [line for line in path.read_text(encoding="utf-8").splitlines()
            if line.startswith(tuple(f"- [ ] {start}" for start in TRIAGE_CRITERIA))]


def triage_body(ticket, part, criteria, run_url):
    """The body of a triage ticket."""
    files = list(dict.fromkeys(p["file"] for p in ticket))
    count = len(ticket)
    points = f"{count} point{'s' if count != 1 else ''}"
    run = f"[the e2e coverage report]({run_url})" if run_url else "the e2e coverage report"
    lines = ["## Parent", "", f"#{CLOSING}", "", "## What to build", "",
             f"Part {part} of the triage of what no test reaches in server and cmd/smock for #{CLOSING}, in step 5"
             f" of #275: the {points} of {run} that no test reaches, in {', '.join(files)}. A point that a DEFERRED"
             " entry of the exclusion list covers counts as unreached.", "", "## Points", ""]
    lines += [f"- `{p['point']}` in `{p['definition']}`"
              + (f" (DEFERRED to #{p['deferred']})" if p.get("deferred") is not None else "") for p in ticket]
    lines += ["", "## Acceptance criteria", "", f"For the {points} above only.", ""]
    if criteria is None:
        lines += [f"- [ ] #{CLOSING}'s criteria on each point's class, dead code, missing tests, exclusions, the"
                  f" points no dump can show and the request path, as #{CLOSING} states them."]
    else:
        lines += criteria
    lines += ["", "## Blocked by", "", *[f"- #{n}" for n in BLOCKERS], "", "## Blocks", "", f"- #{CLOSING}"]
    return "\n".join(lines) + "\n"


def named(files):
    """Files, as a ticket's title names them: one, two, or the first and the
    last with their count, since a title holds at most 256 characters."""
    if len(files) <= 2:
        return " and ".join(files)
    return f"{files[0]} to {files[-1]}, {len(files)} files"


def triage(args):
    """Writes the triage tickets; returns the summary."""
    found = json.loads((Path(args.report) / "unreached.json").read_text(encoding="utf-8"))["packages"]
    points = [p for package in POSITION_PACKAGES for p in found.get(package, {}).get("unreached", [])]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tickets = []
    packages = ", ".join(POSITION_PACKAGES)
    if len(points) <= args.max:
        row = f"| #{CLOSING} | {packages} | {len(points)} | none: triaged in #{CLOSING} |"
    else:
        cuts = bulk.cut(points, args.max)
        row = f"| #{CLOSING} | {packages} | {len(points)} | {len(cuts)} |"
        criteria = closing_criteria(args.bodies)
        for part, ticket in enumerate(cuts, 1):
            files = list(dict.fromkeys(p["file"] for p in ticket))
            name = f"{CLOSING}-{part}.md"
            (out / name).write_text(triage_body(ticket, f"{part} of {len(cuts)}", criteria, args.run_url),
                                    encoding="utf-8")
            tickets.append({"closing": CLOSING, "packages": list(dict.fromkeys(package_of(f) for f in files)),
                            "files": files, "points": [p["point"] for p in ticket],
                            "title": f"Triage the points no test reaches in {named(files)} ({part} of {len(cuts)})",
                            "labels": ["ready-for-agent"], "blocked_by": list(BLOCKERS), "blocks": CLOSING,
                            "body": name})
    (out / "tickets.json").write_text(json.dumps(tickets, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = "\n".join(["# The triage tickets of what no test reaches in server and cmd/smock", "",
                         f"At most {args.max} points a ticket, a source file that holds fewer never split.", "",
                         "| closing ticket | packages | unreached points | triage tickets |", "|---|---|---:|---|",
                         row]) + "\n"
    (out / "tickets.md").write_text(summary, encoding="utf-8")
    return summary


def positive(text):
    """A whole number above 0, for argparse."""
    if not text.isdigit() or int(text) < 1:
        raise argparse.ArgumentTypeError(f"{text!r} is not a whole number above 0")
    return int(text)


def main():
    parser = argparse.ArgumentParser(description="Report coverage from the e2e tests beside the in-process tests'.")
    steps = parser.add_subparsers(dest="step", required=True)
    reporting = steps.add_parser("report", help="report the points reached in-process, by e2e and by either")
    reporting.add_argument("--in-process", required=True, help="the in-process tests' bisect report")
    reporting.add_argument("--e2e", required=True, help="the e2e tests' bisect report")
    reporting.add_argument("--out", required=True, help="where the report goes")
    reporting.add_argument("--root", default=".", help="the directory the reports' paths are relative to")
    reporting.add_argument("--trees", help="the compiler's parse trees of the sources, as <path>.ast")
    reporting.add_argument("--moonc", default="moonc", help="the compiler, which writes the parse trees")
    reporting.add_argument("--tests", help="what moon printed of the e2e run")
    reporting.add_argument("--tests-status", type=int, default=0, help="how moon exited from the e2e run")
    reporting.add_argument("--times", help="the time of each step of the run: seconds, a tab, what it is")
    triaging = steps.add_parser("triage", help="cut the points no test reaches into triage tickets")
    triaging.add_argument("--report", required=True, help="the report's output, which holds unreached.json")
    triaging.add_argument("--out", required=True, help="where the tickets go")
    triaging.add_argument("--max", type=positive, default=TRIAGE_MAX, help="the most points a ticket holds")
    triaging.add_argument("--bodies", help="the closing ticket's body, as <number>.md")
    triaging.add_argument("--run-url", help="the link of the run that made the report")
    args = parser.parse_args()
    try:
        print(report(args) if args.step == "report" else triage(args))
    except (ReportError, finder.FinderError) as error:
        print(f"coverage-e2e: {error}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()

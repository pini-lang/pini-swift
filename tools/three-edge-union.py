#!/usr/bin/env python3
"""Run the three channel-pair edges in one command (criteria-gap ledger, CG-03).

Why this exists
---------------
The three channels (the frozen reference `interp-ast`, the HIR executor, and the
LLVM pipeline) form three pairs, and no single instrument covers all three:

    ast <-> hir    HIRExecutorTests.testCorpusFixturesAgreeWithTheInterpreter
    ast <-> llvm   HIRDifferentialTests
    hir <-> llvm   tools/hir-parity-probe.py

Each edge alone is incomplete and the union is only complete when all three run,
so "is this face covered" used to depend on a human remembering to run both
places. This tool is that union as one rerunnable judgement.

What it will not do
-------------------
Report an unmeasured edge as green. A skip is not a pass: when the LLVM
environment is unconfigured the gate turns the LLVM-gated tests into `XCTSkip`,
and a summary line reading "0 failures" over a suite that never ran is the
"shape-legal false green" this project has already paid for twice. Skips are
counted, printed as their own state, and make the exit code non-zero.

Exit codes: 0 = every edge measured and green · 1 = an edge failed ·
            2 = an edge was not measured (skips, or a tool missing)

Usage: python3 tools/three-edge-union.py [--probe-out PATH] [--skip-probe]
"""

import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")
BLOCKERS = re.compile(r"FLIP BLOCKERS\s+(\d+)")

EDGES = [
    ("ast <-> hir ", "swift test", "HIRExecutorTests/testCorpusFixturesAgreeWithTheInterpreter"),
    ("ast <-> llvm", "swift test", "HIRDifferentialTests"),
    ("hir <-> llvm", "probe", None),
]

GREEN, RED, UNMEASURED = "MEASURED-GREEN", "MEASURED-RED", "UNMEASURED"


def run(args, **kw):
    proc = subprocess.run(args, cwd=REPO, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, **kw)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def read_swift_test(filter_expr):
    """Returns (state, reading). A skip outranks a pass: see the module docstring."""
    rc, out = run(["swift", "test", "--filter", filter_expr])
    # XCTest prints one `Executed ...` summary per nesting level (suite, bundle,
    # "Selected tests"). Summing them multiplies the count by the nesting depth —
    # measured: 89 tests read as 267. The last one is the outermost total.
    executed = EXECUTED.findall(out)
    skipped = len(re.findall(r"\bskipped\b", out))
    ran, failures = (int(executed[-1][0]), int(executed[-1][1])) if executed else (0, 0)
    if rc != 0 or failures:
        return RED, "%d run / %d failed / %d skipped" % (ran, failures, skipped)
    if skipped:
        return UNMEASURED, "%d run / 0 failed / %d SKIPPED (gate closed?)" % (ran, skipped)
    if ran == 0:
        return UNMEASURED, "0 run (filter matched nothing?)"
    return GREEN, "%d run / 0 failed / 0 skipped" % ran


def read_probe(out_path):
    rc, out = run([sys.executable, "tools/hir-parity-probe.py", "--out", out_path])
    m = BLOCKERS.search(out)
    if rc != 0:
        return RED, "probe exited %d" % rc
    if not m:
        return UNMEASURED, "no FLIP BLOCKERS line in the probe summary"
    blockers = int(m.group(1))
    fixtures = re.search(r"sweeping (\d+) fixtures", out)
    count = fixtures.group(1) if fixtures else "?"
    if blockers:
        return RED, "%s fixtures / FLIP BLOCKERS %d" % (count, blockers)
    return GREEN, "%s fixtures / FLIP BLOCKERS 0" % count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe-out", default="/tmp/three-edge-probe.tsv")
    ap.add_argument("--skip-probe", action="store_true",
                    help="the probe is the slow edge; skipping it reports it UNMEASURED")
    args = ap.parse_args()

    print("three-edge union: the channel pairs no single instrument covers")
    print("=" * 72)
    states = []
    for name, kind, arg in EDGES:
        if kind == "probe":
            if args.skip_probe:
                state, reading = UNMEASURED, "--skip-probe"
            else:
                state, reading = read_probe(args.probe_out)
            where = "tools/hir-parity-probe.py"
        else:
            state, reading = read_swift_test(arg)
            where = "swift test --filter %s" % arg
        states.append(state)
        print("%s  %-14s  %-28s  %s" % (name, state, reading, where))

    print("=" * 72)
    if RED in states:
        print("VERDICT: an edge is red — the union does not hold.")
        return 1
    if UNMEASURED in states:
        print("VERDICT: an edge was NOT measured — this is not a green, it is a gap.")
        return 2
    print("VERDICT: all three edges measured and green.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

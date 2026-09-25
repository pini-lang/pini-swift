#!/usr/bin/env python3
"""LOST MOST OF ITS OBJECT IN G-6c (2026-09-18) — read this before running it.

Why this exists, and what is left of it
---------------------------------------
This ran the channel-pair edges in one command, because no single instrument
covered all of them (criteria-gap ledger, CG-03):

    ast <-> ir    IRExecutorTests.testCorpusFixturesAgreeWithTheInterpreter
    ast <-> llvm   IRDifferentialTests
    ir <-> llvm   tools/ir-parity-probe.py
    pkg ast<->ir  every host module with a pini.toml, both engines

Every edge above names the AST walk, and G-6c deleted it. The pairs that
compared *against* the walk (ast<->ir, ast<->llvm) and the package line that
ran both engines over a manifest now have no second side. What survives is
ir<->llvm, and that one is already covered by tools/ir-parity-probe.py, which
is the instrument the batch that removed the walk reworked for it.

⇒ This file is left in place, unreworked, as the record of an instrument whose
object went away, and the ledger entry that commissioned it is re-adjudicated in
docs/ir-criteria-gap-ledger.md rather than left dangling. Deleting it instead
would have left that entry pointing at nothing -- the failure the ledger was
created to avoid. Running it today measures nothing meaningful: the remaining
edge duplicates the probe.

The package line is not one of the channel pairs: it is the only judgement a
module member ever gets. A member file has no `main`, so the single-file
channels refuse it, and `pini run-llvm` takes no directory -- measured, and its
exit status is discarded on top of that -- so the IR-versus-LLVM edge cannot
reach a member either. Until this line existed those files were covered by
nothing, and the probe recorded that only as an exclusion slot.

Each edge alone is incomplete and the union is only complete when all of them
run,
so "is this face covered" used to depend on a human remembering to run both
places. This tool is that union as one rerunnable judgement.

What it will not do
-------------------
Report an unmeasured edge as green. A skip is not a pass: when the LLVM
environment is unconfigured the gate turns the LLVM-gated tests into a skip
(XCTest `XCTSkip`; under Swift Testing, a counted known issue), and a summary
line reading "0 failures" over a suite that never ran is the "shape-legal false
green" this project has already paid for twice. Skips are counted, printed as
their own state, and make the exit code non-zero.

⚠️ 测试框架 2026-09-19 起迁到 Swift Testing：本器械的 `swift test` 两处解析已同时认
两个框架的套件行 / 失败行 / 汇总行。但**这两条边的对象在 G-6c 与测试树清空后已不存在**
（`IRExecutorTests` / `IRDifferentialTests` 均已删），所以它们今天读作「0 run」⇒
UNMEASURED。这是既存状态，不是本次迁移造成的 —— 要复活得先给这两条边重新指定对象。

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
# Swift Testing 的汇总行与 XCTest 完全不同，且**不产出** `Executed ...`：
#   Test run with 32 tests in 2 suites passed after 0.83 seconds.
#   Test run with 4 tests in 1 suite failed after 0.42 seconds with 3 issues.
#   Test run with 4 tests in 1 suite passed after 0.01 seconds with 1 known issue.
# 只认 XCTest 会把 Swift Testing 的套件读成「0 run」，而那是未测、不是通过。
SWIFT_TESTING_SUMMARY = re.compile(
    r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)"
    r"(?: after [\d.]+ seconds)?(?: with (\d+) (?:known )?issues?)?")
BLOCKERS = re.compile(r"FLIP BLOCKERS\s+(\d+)")

EDGES = [
    ("ast <-> ir ", "swift test", "IRExecutorTests/testCorpusFixturesAgreeWithTheInterpreter"),
    ("ast <-> llvm", "swift test", "IRDifferentialTests"),
    ("ir <-> llvm", "probe", None),
    ("pkg ast<->ir", "package", None),
]

GREEN, RED, UNMEASURED = "MEASURED-GREEN", "MEASURED-RED", "UNMEASURED"

BIN = os.environ.get("PINI_SWEEP_BIN",
                     "/tmp/pini-build/arm64-apple-macosx/debug/pini")
MODULE_TIMEOUT = 120


def run(args, **kw):
    proc = subprocess.run(args, cwd=REPO, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, **kw)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def host_modules():
    """Module roots: directories carrying a `pini.toml`, nested repos excluded.

    The exclusion is structural, not a name list: a module living inside another
    repository (one that owns a `.git` above it) belongs to that repository's
    authority, and this tool judges the host repo. The selfhost tree under
    examples/ is the case this exists for.
    """
    roots = []
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in (".build", ".git", "node_modules", "deps")]
        if "pini.toml" not in filenames:
            continue
        rel = os.path.relpath(dirpath, REPO)
        nested = False
        walk = dirpath
        while os.path.abspath(walk) != os.path.abspath(REPO):
            if os.path.isdir(os.path.join(walk, ".git")):
                nested = True
                break
            walk = os.path.dirname(walk)
        if not nested:
            roots.append(rel)
    return sorted(roots)


def run_package_module(root, engine):
    env = dict(os.environ)
    env.pop("PINI_INTERP_ENGINE", None)
    env["PINI_INTERP_ENGINE"] = engine
    try:
        proc = subprocess.run([BIN, "run", root], cwd=REPO, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=MODULE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return 124, b"", b"TIMEOUT after %ds" % MODULE_TIMEOUT
    return proc.returncode, proc.stdout, proc.stderr


def first_line(raw):
    text = raw.decode("utf-8", "replace").strip()
    return (text.splitlines() or [""])[0][:60]


def read_package_channel():
    """The package path, both engines, compared.

    It judges the module's *entry path*, not every file in the module: a member
    the entry never reaches is still unjudged, and the reading names the module
    rather than claiming a file count.

    Three outcomes, kept apart on purpose:

    agreed    both arms exited 0 with identical stdout -- a judgement.
    refused   both arms refused -- no judgement at all, so it outranks "agreed"
              the way a skip outranks a pass. The two refusal texts are printed
              side by side, because that is where an engine asymmetry hides
              when both arms happen to agree on the exit code.
    diverged  one arm ran and the other refused, or the outputs differ. Which
              module runs at all then depends on which engine is selected --
              the user-visible asymmetry this whole line exists to produce, and
              the one that turns the union red.
    """
    modules = host_modules()
    if not modules:
        return UNMEASURED, "no host module found"
    if not os.access(BIN, os.X_OK):
        return UNMEASURED, "pini binary missing at %s" % BIN
    agreed, diverged, refused = [], [], []
    for root in modules:
        ast = run_package_module(root, "ast")
        ir = run_package_module(root, "ir")
        if ast[0] != 0 and ir[0] != 0:
            refused.append("%s [ast %s / ir %s]" % (root, first_line(ast[2]),
                                                     first_line(ir[2])))
        elif ast[0] == ir[0] and ast[1] == ir[1]:
            agreed.append(root)
        else:
            reason = first_line(ir[2]) or "stdout differs"
            diverged.append("%s [ast rc=%s / ir rc=%s: %s]" % (
                root, ast[0], ir[0], reason))
    reading = "%d module(s): %d agreed / %d diverged / %d refused by both arms" % (
        len(modules), len(agreed), len(diverged), len(refused))
    if diverged:
        return RED, reading + " -- " + "; ".join(diverged + refused)
    if refused:
        return UNMEASURED, reading + " -- not judged: " + "; ".join(refused)
    return GREEN, reading



def read_swift_test(filter_expr):
    """Returns (state, reading). A skip outranks a pass: see the module docstring.

    两个框架都读，判别靠汇总行的形状而不是调用参数 —— Swift Testing 的套件由同一条
    `swift test --filter` 驱动，输出里却一个 XCTest 汇总行都没有。
    """
    rc, out = run(["swift", "test", "--filter", filter_expr])
    # XCTest prints one `Executed ...` summary per nesting level (suite, bundle,
    # "Selected tests"). Summing them multiplies the count by the nesting depth --
    # measured: 89 tests read as 267. The last one is the outermost total.
    executed = EXECUTED.findall(out)
    swift_testing = SWIFT_TESTING_SUMMARY.findall(out)
    if swift_testing:
        ran, _, verdict, issues = swift_testing[-1]
        ran = int(ran)
        failures = 0 if verdict == "passed" else int(issues or 1)
        skipped = int(issues or 0) if verdict == "passed" else 0
    elif executed:
        ran, failures = int(executed[-1][0]), int(executed[-1][1])
        skipped = len(re.findall(r"\bskipped\b", out))
    else:
        ran, failures, skipped = 0, 0, 0
    if rc != 0 or failures:
        return RED, "%d run / %d failed / %d skipped" % (ran, failures, skipped)
    if skipped:
        return UNMEASURED, "%d run / 0 failed / %d SKIPPED (gate closed?)" % (ran, skipped)
    if ran == 0:
        return UNMEASURED, "0 run (filter matched nothing?)"
    return GREEN, "%d run / 0 failed / 0 skipped" % ran


def read_probe(out_path):
    rc, out = run([sys.executable, "tools/ir-parity-probe.py", "--out", out_path])
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
            where = "tools/ir-parity-probe.py"
        elif kind == "package":
            state, reading = read_package_channel()
            where = "pini run <module> (both engines, host modules only)"
        else:
            state, reading = read_swift_test(arg)
            where = "swift test --filter %s" % arg
        states.append(state)
        print("%s  %-14s  %-34s  %s" % (name, state, reading, where))

    print("=" * 72)
    if RED in states:
        print("VERDICT: an edge is red — the union does not hold.")
        return 1
    if UNMEASURED in states:
        print("VERDICT: an edge was NOT measured — this is not a green, it is a gap.")
        return 2
    print("VERDICT: every edge measured and green.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

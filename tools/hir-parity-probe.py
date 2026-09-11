#!/usr/bin/env python3
"""HIR execution-parity probe — the judgement upgrade over m6-triage-probe.sh.

WHY THIS EXISTS
---------------
`tools/m6-triage-probe.sh` decides "true flip blocker" by asking whether
`emit` *succeeds* — i.e. whether an IR text file can be produced. It never
runs the IR. That judge is blind to an entire class of gap: the IR is emitted
fine but *executes differently* (missing defer lowering, wrong len(string),
aggregate prints rejected at emit time, ...). Measured 2026-09-11: the
emit-only judge called all of them PASS.

This probe changes the unit of judgement from "can we emit it" to "does it
run, and does it behave the same". Three channels per fixture:

    interpreter  `pini run <file>`                         (reference semantics)
    legacy       `pini run-llvm <file>`                    (implementation today)
    hir          `PINI_HIR_PIPELINE=1 pini run-llvm <file>` (implementation after flip)

All three typecheck first, which is what the CLI does, so a front-end reject
fails all three and is correctly classified as "not a backend gap".

ISOLATION
---------
Every fixture runs from a scratch copy, never in place. Pini resolves relative
I/O against the SOURCE FILE's directory rather than the cwd, so a fixture that
writes a file (or carries an unreplaced harness placeholder such as a path
token) would otherwise litter the real fixture directory with its output. The
copy keeps the fixture's sibling .pini files next to it, so same-directory
multi-file fixtures still resolve.

VERDICTS
--------
    OK                 all three agree
    OK_HARNESS         stdout agrees AND both channels report the same stderr
                       shape (both silent or both loud), but the standalone
                       channel is not the real harness — the test substitutes
                       paths or supplies a program base
    PACKAGE_MEMBER     the file sits inside a module (pini.toml above it) and
                       cannot be run standalone; needs the package channel —
                       never a flip blocker, excluded from the count
    FRONTEND_FAIL      legacy rejects it too (parse/check/emit) — not a gap
    GAP_EXEC           legacy runs, HIR does not (emit reject or lli reject)
    GAP_IR             legacy runs, HIR emits but lli refuses the IR
                       (note: `run-llvm` ignores lli's exit status, so an
                       invalid IR looks like a successful empty run)
    GAP_BEHAVIOR       both run, output differs AND legacy matches the
                       interpreter — the HIR output is the odd one out
    CHANGE_F64         both run, output differs, HIR matches the interpreter,
                       and the divergence is the print(F64) format — LR-8
                       adjudicated shortest round-trip, so the flip *fixes*
                       this; the test expectation is what must change
    CHANGE_OTHER       HIR matches the interpreter but not for the F64 reason
                       (needs a look; still not an implementation gap)
    GAP_UNKNOWN        both run, output differs, neither matches the
                       interpreter — needs manual triage
    HARNESS_DEPENDENT  legacy does not run cleanly standalone, so the
                       standalone channel cannot judge the fixture

BLOCKERS for the flip = GAP_EXEC + GAP_IR + GAP_BEHAVIOR + GAP_UNKNOWN.
CHANGE_* are expectation updates, not implementation work.

STDERR IS PART OF THE JUDGEMENT
-------------------------------
Equal stdout is NOT on its own parity. A channel that prints nothing because
it crashed into a rejected module and a channel that prints nothing because
the program produced no output look identical on stdout, so an early version
of this probe called the first one OK_HARNESS and hid real gaps (measured:
a nested-COW fixture whose HIR module lli refuses, sitting in OK_HARNESS).
The parity test therefore requires the same stderr *shape* as well as equal
stdout, and anything that falls through is classified by the ordered rules
below — a lone HIR-side stderr reaches GAP_IR, not OK.

Usage:  python3 tools/hir-parity-probe.py [--root DIR]... [--filter SUBSTR]
Output: /tmp/hir-parity-sweep.tsv  (+ summary on stdout)
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get(
    "PINI_SWEEP_BIN", "/tmp/pini-build/arm64-apple-macosx/debug/pini"
)
# Resolve lli through the toolchain path as well as PATH, so the probe does
# not depend on the caller having sourced a shell profile.
LLVM_BIN = "/opt/homebrew/opt/llvm/bin"
OUT = "/tmp/hir-parity-sweep.tsv"
RUN_TIMEOUT = 10

DEFAULT_ROOTS = [
    "Tests/PiniTests/CodeGen/IRExecutionTests",
    "Tests/PiniTests/RuntimeBackendTests",
    "Tests/PiniTests/OptionalTests",
    "Tests/PiniTests/CodeGen/IRPrintGoldenTests",
    "Tests/PiniTests/CodeGen/IRGeneratorTests",
    "Tests/PiniTests/CodeGen/HIRTests",
    "examples",
]

F64_SIX = re.compile(r"\d+\.\d{6}")

# Scratch root for isolated runs; created on first use, removed at the end.
_scratch_root = [None]


def run(argv, env_extra=None, cwd=None):
    env = dict(os.environ)
    env.setdefault("PINI_LLVM_BIN", LLVM_BIN)
    if env_extra:
        env.update(env_extra)
    # Own process group: `pini run-llvm` spawns lli as a child, and a plain
    # subprocess timeout kills only the direct child — lli would survive and
    # spin forever (observed: a continue-before-increment fixture loops on
    # purpose, one leaked lli per sweep). Killing the group takes both down.
    proc = subprocess.Popen(
        argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        out, err = proc.communicate(timeout=RUN_TIMEOUT)
        return (proc.returncode,
                out.decode("utf-8", "replace"),
                err.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 124, "", "TIMEOUT after %ss" % RUN_TIMEOUT


def first_line(text):
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:150]
    return ""


def scratch_copy(rel):
    """Copy the fixture and its sibling .pini files into a scratch slot.

    Returns (slot_dir, path_to_run). The siblings travel along so that
    fixtures resolving a same-directory companion still work; anything
    reaching outside the directory is a package member and is classified
    as such from its original location.
    """
    if _scratch_root[0] is None:
        _scratch_root[0] = tempfile.mkdtemp(prefix="pini-parity-")
    src = os.path.join(REPO, rel)
    slot = tempfile.mkdtemp(dir=_scratch_root[0])
    srcdir = os.path.dirname(src)
    for name in sorted(os.listdir(srcdir)):
        if name.endswith(".pini"):
            shutil.copy(os.path.join(srcdir, name), os.path.join(slot, name))
    return slot, os.path.join(slot, os.path.basename(rel))


def in_module(rel):
    """True when a pini.toml sits at or above the file's directory."""
    d = os.path.dirname(os.path.join(REPO, rel))
    root = os.path.abspath(REPO)
    while os.path.abspath(d).startswith(root):
        if os.path.isfile(os.path.join(d, "pini.toml")):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return False


def collect(roots, needle=None):
    files = []
    for root in roots:
        base = os.path.join(REPO, root)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.endswith(".pini"):
                    rel = os.path.relpath(os.path.join(dirpath, name), REPO)
                    if needle and needle not in rel:
                        continue
                    files.append((root, rel))
    return files


def classify(rel, l_rc, l_out, l_err, h_rc, h_out, h_err,
             i_rc, i_out):
    # 1. A file inside a module cannot run standalone at all.
    if in_module(rel):
        return "PACKAGE_MEMBER", ""
    # 2. Legacy rejects it too -> not a backend gap.
    if l_rc != 0:
        return "FRONTEND_FAIL", first_line(l_err)
    # 3. Equal stdout is parity only when the two channels are equally loud.
    #    A silent-stdout crash on one side and a silent-stdout success on the
    #    other compare equal on stdout alone, which would file a genuinely
    #    rejected module as OK_HARNESS — the stderr shape breaks the tie, and
    #    anything failing this test falls through to be classified below.
    if l_out == h_out and bool(l_err.strip()) == bool(h_err.strip()):
        if l_err.strip():
            # parity, but the standalone channel is not the real harness
            # (the test substitutes paths / supplies a program base).
            return "OK_HARNESS", first_line(h_err or l_err)
        return "OK", ""
    # 4. Legacy ran, HIR could not.
    if h_rc != 0:
        return "GAP_EXEC", first_line(h_err)
    # 5. Legacy did not run cleanly either -> the standalone channel cannot
    #    judge this fixture; excluding it is honest, not lenient.
    if l_err.strip():
        return "HARNESS_DEPENDENT", first_line(l_err)
    # 6. HIR emitted IR that lli refused. (`run-llvm` ignores lli's exit
    #    status, so this looks like a clean run with missing output.)
    if h_err.strip():
        return "GAP_IR", first_line(h_err)
    if h_out == i_out:
        if F64_SIX.search(l_out) and not F64_SIX.search(h_out):
            return "CHANGE_F64", ""
        return "CHANGE_OTHER", ""
    if l_out == i_out:
        return "GAP_BEHAVIOR", ""
    return "GAP_UNKNOWN", ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", action="append", default=None)
    ap.add_argument("--filter", default=None,
                    help="only fixtures whose repo-relative path contains this")
    args = ap.parse_args()
    roots = args.root or DEFAULT_ROOTS

    if not os.access(BIN, os.X_OK):
        print("pini binary missing at %s\n  swift build --disable-sandbox "
              "--scratch-path /tmp/pini-build --product pini" % BIN, file=sys.stderr)
        return 1

    fixtures = collect(roots, args.filter)
    print("sweeping %d fixtures over %d roots" % (len(fixtures), len(roots)))

    rows = []
    t0 = time.time()
    try:
        for n, (root, rel) in enumerate(fixtures, 1):
            cwd, run_path = scratch_copy(rel)
            i_rc, i_out, _ = run([BIN, "run", run_path], cwd=cwd)
            l_rc, l_out, l_err = run([BIN, "run-llvm", run_path], cwd=cwd)
            h_rc, h_out, h_err = run([BIN, "run-llvm", run_path],
                                     env_extra={"PINI_HIR_PIPELINE": "1"},
                                     cwd=cwd)
            verdict, note = classify(rel, l_rc, l_out, l_err, h_rc, h_out,
                                     h_err, i_rc, i_out)
            rows.append({
                "verdict": verdict, "note": note, "root": root, "fixture": rel,
                "l_rc": l_rc, "h_rc": h_rc, "i_rc": i_rc,
                "l_len": len(l_out), "h_len": len(h_out), "i_len": len(i_out),
                "l_out": l_out, "h_out": h_out, "i_out": i_out,
            })
            if n % 50 == 0 or n == len(fixtures):
                print("  %d/%d  (%.0fs)" % (n, len(fixtures), time.time() - t0),
                      flush=True)
    finally:
        if _scratch_root[0] and os.path.isdir(_scratch_root[0]):
            shutil.rmtree(_scratch_root[0], ignore_errors=True)

    cols = ["verdict", "root", "fixture", "l_rc", "h_rc", "i_rc",
            "l_len", "h_len", "i_len", "note"]
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\t".join(cols) + "\n")
        for r in rows:
            fh.write("\t".join(str(r[c]) for c in cols) + "\n")

    order = ["OK", "OK_HARNESS", "PACKAGE_MEMBER", "FRONTEND_FAIL",
             "HARNESS_DEPENDENT", "GAP_EXEC", "GAP_IR", "GAP_BEHAVIOR",
             "GAP_UNKNOWN", "CHANGE_F64", "CHANGE_OTHER"]
    print("\n=== summary ===")
    for v in order:
        n = sum(1 for r in rows if r["verdict"] == v)
        if n:
            print("  %-15s %d" % (v, n))
    blockers = [r for r in rows if r["verdict"].startswith(("GAP_",))
                and r["verdict"] != "GAP_UNKNOWN"]
    unknown = [r for r in rows if r["verdict"] == "GAP_UNKNOWN"]
    print("  %-15s %d" % ("FLIP BLOCKERS", len(blockers) + len(unknown)))

    for label, group in [("blockers", blockers + unknown),
                         ("behaviour changes", [r for r in rows
                                                if r["verdict"].startswith("CHANGE_")])]:
        print("\n=== %s ===" % label)
        for r in group:
            print("  %-14s %s" % (r["verdict"], r["fixture"]))
            if r["note"]:
                print("        %s" % r["note"])
            elif r["verdict"].startswith("GAP_"):
                print("        legacy=%r  hir=%r" % (r["l_out"][:60], r["h_out"][:60]))
    print("\ndetail -> %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())

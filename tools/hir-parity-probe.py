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
    hir          `pini run-llvm <file>` (same pipeline as legacy after the flip)

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
    TIMEOUT_ALL        all three channels hit the wall clock — the fixture
                       loops by design (a `continue` before the loop's
                       increment, say); a property of the program, not a gap
    TIMEOUT_INTERP     only the interpreter hit the wall clock — the reference
                       semantics itself does not terminate, so there is nothing
                       to compare; excluded
    TIMEOUT_LEGACY     legacy hangs but HIR terminates — a legacy defect, not
                       something the flip introduces
    GAP_HANG           legacy terminated, HIR did not — the flip would turn a
                       terminating program into a hang; an emit-only judge can
                       never see this, and stdout gives no warning

BLOCKERS for the flip = GAP_EXEC + GAP_IR + GAP_BEHAVIOR + GAP_HANG
                        + GAP_UNKNOWN.
CHANGE_* are expectation updates, not implementation work. TIMEOUT_* (other
than GAP_HANG) describe the fixture, not the implementation.

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

PROCESS CONTAINMENT
-------------------
`pini run-llvm` writes `/tmp/pini_<uuid>.ll` and then blocks in
`Process.waitUntilExit`, so a fixture that loops by design produces a
two-level tree: probe -> pini -> lli. Killing only the probe's direct child
is not enough, and two failure modes were measured on 2026-09-11:

  * a SIGKILLed `pini` never runs the `defer` that removes the temp .ll, so
    the file is left behind — one pair of files per hang (same source, legacy
    and HIR emitter, so two distinct md5s), about 30 s apart;
  * an `lli` that outlives the group kill still holds the inherited
    stdout/stderr pipe, so an *unbounded* post-kill `communicate()` blocks
    forever. That deadlock is silent: the sweep simply stops — no timeout
    verdict, no error, one spinning `lli` — and six such hangs from an earlier
    sweep were only found by fingerprinting the stray .ll files afterwards.
    Worse, those hangs were filed as FRONTEND_FAIL because a hung channel
    reports rc 124, so they were invisible in the verdict table too.

A timeout therefore does three things: kill the process group, drain the pipes
with a BOUNDED wait (never unbounded), and reap every `lli` that appeared
during the sweep by reading the process table for argv carrying
`/tmp/pini_*.ll` — survivors are killed and their stray .ll removed, and the
count is reported. Stray .ll files created during the run are cleaned at exit.

The process table is read through `pgrep -fl`, NOT through `/bin/ps`: the
sandbox this tool runs under refuses to execute `ps` (measured 2026-09-11 —
"Operation not permitted" from both bash and python), so a reaper built on it
silently becomes a no-op and the leak looks fixed while nothing was killed.
When even `pgrep` is unavailable the sweep says containment is unavailable and
reports the stray .ll files instead of claiming success.

Usage:  python3 tools/hir-parity-probe.py [--root DIR]... [--filter SUBSTR]
                                        [--timeout SECONDS]
Output: /tmp/hir-parity-sweep.tsv  (+ summary on stdout)
"""

import argparse
import glob
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
# Second, bounded wait after the group kill. Only a pipe still held open by a
# surviving grandchild can keep the drain from finishing.
DRAIN_TIMEOUT = 5
# Where `pini run-llvm` puts the temp module; the token identifies an lli that
# belongs to us rather than one a human started.
LLI_IR_PREFIX = "/tmp/pini_"

DEFAULT_ROOTS = [
    "Tests/PiniTests/CodeGen/IRExecutionTests",
    "Tests/PiniTests/RuntimeBackendTests",
    "Tests/PiniTests/OptionalTests",
    "Tests/PiniTests/CodeGen/IRPrintGoldenTests",
    "Tests/PiniTests/CodeGen/HIRTests",
    "examples",
]

F64_SIX = re.compile(r"\d+\.\d{6}")

# Scratch root for isolated runs; created on first use, removed at the end.
_scratch_root = [None]
# lli processes alive when the sweep started; anything newer is ours to reap.
_lli_baseline = set()
# Stray .ll files present before the sweep; anything newer is our litter.
_stray_baseline = set()
# Every .ll removed by a reaper, including the per-timeout ones. The final
# pass usually finds nothing left, so reporting only its result would print
# "0 killed" for a sweep that killed several — a number that contradicts the
# clean /tmp next to it.
_reaped = []


def strays():
    return set(glob.glob(LLI_IR_PREFIX + "*.ll"))


def lli_argv_rows():
    """[(pid, argv)] for live lli processes, or None when we cannot look.

    `/bin/ps` is unusable here: the sandbox denies executing it, so a reaper
    built on `ps` would silently become a no-op — the false green this tool
    exists to delete. `pgrep -fl` is permitted and prints the full command
    line, so `None` means "containment unavailable" and is reported as such.
    """
    try:
        res = subprocess.run(["pgrep", "-fl", "lli"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    rows = []
    for line in res.stdout.decode("utf-8", "replace").splitlines():
        pid_text, _, cmd = line.strip().partition(" ")
        parts = cmd.split()
        # `pgrep -f` also matches any shell whose text mentions lli, so the
        # program name — not the pattern — decides membership.
        if not parts or not os.path.basename(parts[0]).startswith("lli"):
            continue
        try:
            rows.append((int(pid_text), parts))
        except ValueError:
            continue
    return rows


def live_lli_pids():
    """{pid: temp .ll} for the lli processes pini started; {} if unavailable."""
    found = {}
    for pid, parts in lli_argv_rows() or []:
        for token in parts:
            if token.startswith(LLI_IR_PREFIX) and token.endswith(".ll"):
                found[pid] = token
                break
    return found


def kill_pid(pid, ir):
    """SIGKILL by pid, falling back to pkill by unique argv when refused."""
    try:
        os.kill(pid, signal.SIGKILL)
        return True
    except ProcessLookupError:
        return True
    except PermissionError:
        try:
            subprocess.run(["pkill", "-9", "-f", ir], timeout=15,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except (OSError, subprocess.SubprocessError):
            return False


def reap_orphans(baseline):
    """Kill lli processes newer than `baseline` and delete their .ll files.

    Called after every timeout and once at exit. Membership is decided by the
    `/tmp/pini_*.ll` token in argv, so an unrelated lli can never be touched.
    Returns the list of removed .ll files, or None when the process table
    cannot be read at all.
    """
    rows = lli_argv_rows()
    if rows is None:
        return None
    killed = []
    for pid, parts in rows:
        if pid in baseline:
            continue
        ir = next((t for t in parts
                   if t.startswith(LLI_IR_PREFIX) and t.endswith(".ll")), None)
        if ir is None or not kill_pid(pid, ir):
            continue
        killed.append(ir)
    for ir in killed:
        try:
            os.remove(ir)
        except OSError:
            pass
    _reaped.extend(killed)
    return killed


def clean_new_strays():
    """Remove temp .ll files this sweep created and nobody owns any more."""
    if lli_argv_rows() is None:
        # Cannot tell which file a live lli is still reading; leave them be.
        return []
    alive = set(live_lli_pids().values())
    removed = []
    for path in strays() - _stray_baseline - alive:
        try:
            os.remove(path)
            removed.append(path)
        except OSError:
            pass
    return removed


def drain(proc):
    """Close the pipes and reap the child without ever blocking forever."""
    for stream in (proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
    try:
        proc.kill()
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=DRAIN_TIMEOUT)
    except subprocess.TimeoutExpired:
        pass


def run(argv, env_extra=None, cwd=None):
    env = dict(os.environ)
    env.setdefault("PINI_LLVM_BIN", LLVM_BIN)
    if env_extra:
        env.update(env_extra)
    # Own process group: `pini run-llvm` spawns lli as a child, so a plain
    # subprocess timeout would kill only the direct child. The group kill is a
    # first attempt, NOT a guarantee — measured 2026-09-11: pini dies and lli
    # survives in a group of its own (Foundation's Process gives the child
    # one), still holding the inherited pipe. The reaper is what contains it.
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
        except (ProcessLookupError, PermissionError):
            pass
        # BOUNDED drain. The group kill is not guaranteed to reach lli, and a
        # surviving lli holds the inherited pipe open, so the unbounded
        # communicate() this replaces deadlocked the whole sweep with no
        # diagnostic at all.
        try:
            proc.communicate(timeout=DRAIN_TIMEOUT)
        except subprocess.TimeoutExpired:
            drain(proc)
        reap_orphans(_lli_baseline)
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
    # 2. Wall-clock verdicts come FIRST, ahead of the front-end rule. A hung
    #    channel reports rc 124, which the front-end rule would file as
    #    FRONTEND_FAIL and drop out of the blocker count entirely — measured:
    #    six hangs from an earlier sweep hid in that bucket and were only
    #    found by fingerprinting the stray .ll files they left behind.
    if h_rc == 124 and l_rc != 124:
        return "GAP_HANG", "legacy terminated in time, HIR did not"
    if l_rc == 124 and h_rc == 124:
        return "TIMEOUT_ALL", "loops by design; all three channels hit the wall clock"
    if l_rc == 124:
        return "TIMEOUT_LEGACY", "legacy hangs, HIR terminates"
    if i_rc == 124:
        return "TIMEOUT_INTERP", "interpreter does not terminate; nothing to compare"
    # 3. Legacy rejects it too -> not a backend gap.
    if l_rc != 0:
        return "FRONTEND_FAIL", first_line(l_err)
    # 4. Equal stdout is parity only when the two channels are equally loud.
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
    # 5. Legacy ran, HIR could not.
    if h_rc != 0:
        return "GAP_EXEC", first_line(h_err)
    # 6. Legacy did not run cleanly either -> the standalone channel cannot
    #    judge this fixture; excluding it is honest, not lenient.
    if l_err.strip():
        return "HARNESS_DEPENDENT", first_line(l_err)
    # 7. HIR emitted IR that lli refused. (`run-llvm` ignores lli's exit
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
    global RUN_TIMEOUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", action="append", default=None)
    ap.add_argument("--filter", default=None,
                    help="only fixtures whose repo-relative path contains this")
    ap.add_argument("--timeout", type=int, default=RUN_TIMEOUT,
                    help="per-channel wall clock, seconds (default %d)" % RUN_TIMEOUT)
    args = ap.parse_args()
    roots = args.root or DEFAULT_ROOTS
    RUN_TIMEOUT = args.timeout

    if not os.access(BIN, os.X_OK):
        print("pini binary missing at %s\n  swift build --disable-sandbox "
              "--scratch-path /tmp/pini-build --product pini" % BIN, file=sys.stderr)
        return 1

    _lli_baseline.update(live_lli_pids())
    _stray_baseline.update(strays())
    if _lli_baseline:
        print("note: %d lli process(es) already running before the sweep; "
              "left untouched" % len(_lli_baseline))

    fixtures = collect(roots, args.filter)
    print("sweeping %d fixtures over %d roots" % (len(fixtures), len(roots)))

    rows = []
    t0 = time.time()
    try:
        for n, (root, rel) in enumerate(fixtures, 1):
            cwd, run_path = scratch_copy(rel)
            i_rc, i_out, _ = run([BIN, "run", run_path], cwd=cwd)
            l_rc, l_out, l_err = run([BIN, "run-llvm", run_path], cwd=cwd)
            h_rc, h_out, h_err = run([BIN, "run-llvm", run_path], cwd=cwd)
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
        leaks = reap_orphans(_lli_baseline)
        removed = clean_new_strays()
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
             "GAP_UNKNOWN", "GAP_HANG", "TIMEOUT_ALL", "TIMEOUT_INTERP",
             "TIMEOUT_LEGACY", "CHANGE_F64", "CHANGE_OTHER"]
    print("\n=== summary ===")
    for v in order:
        n = sum(1 for r in rows if r["verdict"] == v)
        if n:
            print("  %-15s %d" % (v, n))
    blockers = [r for r in rows if r["verdict"] in
                ("GAP_EXEC", "GAP_IR", "GAP_BEHAVIOR", "GAP_HANG")]
    unknown = [r for r in rows if r["verdict"] == "GAP_UNKNOWN"]
    print("  %-15s %d" % ("FLIP BLOCKERS", len(blockers) + len(unknown)))
    left = []
    if leaks is None:
        print("  %-15s containment UNAVAILABLE (pgrep not callable); "
              "%d stray .ll removed" % ("process leaks", len(removed)))
    else:
        print("  %-15s %d lli killed in total, %d of them at exit; "
              "%d stray .ll removed"
              % ("process leaks", len(_reaped), len(leaks), len(removed)))
        left = sorted(live_lli_pids())
        if left:
            print("  %-15s STILL ALIVE: %s"
                  % ("process leaks", ", ".join(str(p) for p in left)))

    for label, group in [("blockers", blockers + unknown),
                         ("behaviour changes", [r for r in rows
                                                if r["verdict"].startswith("CHANGE_")]),
                         ("non-terminating fixtures", [r for r in rows
                                                       if r["verdict"].startswith("TIMEOUT_")])]:
        print("\n=== %s ===" % label)
        for r in group:
            print("  %-14s %s" % (r["verdict"], r["fixture"]))
            if r["note"]:
                print("        %s" % r["note"])
            elif r["verdict"].startswith("GAP_"):
                print("        legacy=%r  hir=%r" % (r["l_out"][:60], r["h_out"][:60]))
    print("\ndetail -> %s" % OUT)
    # A surviving lli is a tool failure, not a fixture verdict: exit non-zero
    # so a sweep can never be read as clean while a process is still spinning.
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())

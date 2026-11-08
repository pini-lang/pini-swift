#!/usr/bin/env python3
"""IR execution-parity probe — the judgement upgrade over an emit-only triage probe.

WHY THIS EXISTS
---------------
An earlier triage probe decided "true flip blocker" by asking whether
`emit` *succeeds* — i.e. whether an IR text file can be produced. It never
runs the IR. That judge is blind to an entire class of gap: the IR is emitted
fine but *executes differently* (missing defer lowering, wrong len(string),
aggregate prints rejected at emit time, ...). Measured 2026-09-11: the
emit-only judge called all of them PASS.

This probe changes the unit of judgement from "can we emit it" to "does it
run, and does it behave the same". Two execution channels per fixture:

    interp-ir   `pini run <file>`        the IR execution engine
    llvm-ir     `pini run-llvm <file>`   IR -> LLVM

They are separate implementations of the same semantics — one walks the IR
tree, the other lowers it to LLVM IR and runs that — so the cross-check compares
two engines rather than one pipeline with itself.

TWO CHANNELS, NOT ONE, AND NOT THREE (G-6c, 2026-09-18)

Until that batch there was a tird channel: `interp-ast`, the AST walk, held as
a *frozen reference* — a second interpreter whose agreement was the standard.
G-6c deleted the walk, so both the channel and the thing it was a reference to
are gone, and with one implementation left there would be nothing to compare.
What remains is IR-executor against LLVM, which is a real comparison; what is
lost is the tird opinion, and the two fixtures where the reference had been the
odd one out are recorded in the batch that removed it rather than carried as a
permanent exception table.

A DIAGNOSTIC-ORIGIN INSTRUMENT, WHICH IS NOT A CHANNEL

`pini check <file>` is run as well, but it is not a tird opinion about
behaviour: it executes nothing. It answers one question the two execution
channels cannot — *where did this diagnostic come from*. The reference arm used
to answer it incidentally (a warning the reference printed too must have come
from the shared front end), and two slots below depend on that answer. `check`
answers it directly, by running the front end and nothing else, and the
classification requires it to report the *same* diagnostic code, not merely to
be loud: a front end that complains about something else is not corroboration.

Both execution channels typecheck first, which is what the CLI does, so a
front-end reject fails both and is correctly classified as "not a backend gap".

ISOLATION
---------
Every fixture runs from a scratch copy, never in place. Pini resolves relative
I/O against the SOURCE FILE's directory rather than the cwd, so a fixture that
writes a file (or carries an unreplaced harness placeholder such as a path
token) would otherwise litter the real fixture directory with its output. The
copy keeps the fixture's sibling .pini files next to it, so same-directory
multi-file fixtures still resolve.

WHICH BINARY
------------
The CLI under test is located by asking SwiftPM (`swift build --show-bin-path`,
with `--scratch-path` when the caller passes one) rather than by naming a
layout. It used to be a literal path, and a literal path into a build layout is
a fact with an expiry date: once the layout changed, the probe either refused to
start -- or, the worse of the two, swept a binary that still happened to sit
there from an earlier build, reporting a whole table of numbers about code that
no longer existed. `PINI_SWEEP_BIN` overrides the lookup; that is what a
frozen-artifact flow wants, and it stays.

VERDICTS
--------
    OK                 the two arms agree — stdout byte-equal and both silent
                       on stderr
    OK_HARNESS         stdout agrees across both arms AND both arms write to
                       stderr without failing, but the standalone channel is
                       not the real harness — the test substitutes paths or
                       supplies a program base
    PACKAGE_MEMBER     the file sits inside a module (pini.toml above it) and
                       cannot be run standalone; needs the package channel —
                       never a flip blocker, excluded from the count
    FRONTEND_FAIL      the LLVM arm rejects it too (parse/check/emit) — not a gap
    IR_ENGINE_TODO    interp-ir names a node it has not implemented yet. The
                       open nodes are the P2 work list, NOT a defect: every
                       sweep would otherwise carry the same count in the
                       blocker column until P2 finishes, and a number that
                       never moves stops being read. Reported separately and
                       aggregated by node
    GAP_EXEC           interp-ir exits non-zero while llvm-ir does not, and
                       not because of an unimplemented node. As of 2026-09-15 this
                       test runs BEFORE the parity test, so it also absorbs a run
                       whose stdout matched but whose IR arm still exited
                       non-zero. As of 2026-09-16 (P4-0) the shape where BOTH
                       interpreter arms fail while the LLVM arm reports its
                       failure on stderr is no longer counted here — it has its
                       own non-blocking slot below
    CHANNEL_LIMIT      interp-ir stops at a call shape it declines by design and
                       names the code for it (E5-019 variadic, E5-020 string
                       handle) while llvm-ir runs the same fixture. NOT a
                       blocker: the two engines do not disagree about the
                       program — one of them documents a boundary and names the
                       channel that works. Keyed on the code on the `Error:` line,
                       not the first code in the text, because these fixtures
                       warn before they stop
    GAP_IR_ENGINE     interp-ir writes to stderr without failing, and the
                       diagnostic is NOT the shared front end's. Narrowed to
                       that residual by the slot below; it stays a rule (not a
                       dead slot) because an engine that warns where the front
                       end does not is a real gap class. Reachable but, on this
                       corpus, unexercised — recorded rather than glossed: a
                       rule nothing reaches has no demonstrated discriminating
                       power yet
    WARN_CHANNEL_ASYMMETRY
                       interp-ir writes a diagnostic with a zero exit status
                       while the LLVM arm is silent, AND `pini check` reports
                       the same diagnostic code. NOT an IR engine failure: the
                       warning is the shared front end's, one execution path
                       prints it and the other does not. Measured 2026-09-18:
                       20/20 of these fixtures carry E7-001 on every
                       front-end-touching path and 0/20 on the LLVM arm. That
                       asymmetry is the diagnostic-channel defect in
                       docs/issue-diagnostic-channel-parity-2026-09-12.md;
                       reported with its count so that leaving it out of the
                       blocker total is a decision the reader can see
    WARN_LLVM_RC_UNPROPAGATED
                       interp-ir exits non-zero AND the LLVM arm reports a
                       failure on stderr while returning rc 0, because
                       `run-llvm` does not propagate lli's exit status. NOT a
                       blocker: the program fails, both execution paths say so,
                       and the only signal that differs is one the harness
                       discards. Demoted here on 2026-09-16 (P4-0) from
                       GAP_EXEC, where it had been carried as an acknowledged
                       over-count.
                       WEAKENED BY G-6c, STATED RATHER THAN HIDDEN: the rule
                       used to require a failing *reference* arm as well, so the
                       claim was "every implementation agrees this program
                       fails". With the reference gone the surviving
                       corroboration is the LLVM arm's own stderr. That is
                       enough to establish the program fails — the harness
                       defect it names is unchanged and separately filed — but
                       it is one witness where there used to be two
    GAP_BEHAVIOR       both arms run to completion and their stdout differs —
                       an execution divergence between the two implementations.
                       G-6c re-formed this slot: it used to mean "interp-ir is
                       the odd one out against the reference", which cannot be
                       asked any more. It is now the plain two-arm form, which
                       is also what the retired CHANGE_* slots were splitting
                       ("which of the three is wrong") — that question was
                       reference-relative, so it went with the reference
    GAP_UNKNOWN        neither of the ordered rules above fits — manual triage.
                       With every slot now two-arm or front-end-relative, this
                       should be unreachable; it is kept so that an unforeseen
                       shape lands in a named bucket instead of a crash
    HARNESS_DEPENDENT  the LLVM arm does not run cleanly standalone, so the
                       standalone channel cannot judge the fixture
    TIMEOUT_ALL        all three channels hit the wall clock — the fixture
                       loops by design (a `continue` before the loop's
                       increment, say); a property of the program, not a gap
    TIMEOUT_AST        RETIRED (G-6c): it described a reference arm that no
                       longer exists
    TIMEOUT_LLVM       the LLVM arm hangs but interp-ir terminates — an LLVM
                       arm defect, not something the flip introduces
    GAP_HANG           llvm-ir terminated, interp-ir did not — the flip would
                       turn a terminating program into a hang; an emit-only
                       judge can never see this, and stdout gives no warning

BLOCKERS = GAP_EXEC + GAP_IR_ENGINE + GAP_BEHAVIOR + GAP_HANG + GAP_UNKNOWN.
IR_ENGINE_TODO is deliberately NOT among them: it measures how much of the IR
engine P2 has left to build, which is a different question. Merging the two is
the P3 judging-upgrade grid's job.
CHANNEL_LIMIT is not a blocker either, and for a reason that would survive a
stricter reading of the flip: the fixture already runs on the channel the flip
keeps. Carrying it as GAP_EXEC asked the reader to re-derive that from a
diagnostic code every time the gate went red.
TIMEOUT_* (other than GAP_HANG) describe the fixture, not the implementation.
WARN_CHANNEL_ASYMMETRY is likewise not a blocker, and for a stronger reason
than "it looks benign": the flip does not move it at all. It is printed with
its count so that leaving it out of the total is a decision the reader can see
rather than a disappearance.

TIE-BREAK ORDER (2026-09-15, P3-G1)
-----------------------------------
The GAP_EXEC test (`h_rc != 0`) used to sit AFTER the parity test, so a run
whose stdout matched while the IR arm exited non-zero was filed OK_HARNESS —
"equal" on two empty stdout strings. It now runs first.

Both orderings were measured on the full 319-fixture corpus before choosing,
together with the two other changes of the same grid (a_out in the parity test,
and the two new slots).  注意  `a_out` and the comparison it participated in were
removed in G-6c along with the reference arm; what follows is the measurement as
it was taken, kept for the record.

    shipped rules                     FLIP BLOCKERS 27 = GAP_IR_ENGINE 20
                                                      + GAP_EXEC 7
    as of 2026-09-15                  FLIP BLOCKERS 11 = GAP_EXEC 11
                                      non-blocking: WARN_CHANNEL_ASYMMETRY 20,
                                                    CHANGE_REFERENCE 2

Of the 11 blockers, 7 are the real E5-006 failures the two filed tickets cover
and 4 are the acknowledged over-count described under GAP_EXEC. Under the old
order those 4 read as parity — the vacuous comparison above. The trade is taken
deliberately: what the strict order buys is that "the IR arm failed" can never
again be reported as parity merely because both sides were silent on stdout.

STDERR IS PART OF THE JUDGEMENT
-------------------------------
Equal stdout is NOT on its own parity. A channel that prints nothing because
it crashed into a rejected module and a channel that prints nothing because
the program produced no output look identical on stdout, so an early version
of this probe called the first one OK_HARNESS and hid real gaps (measured:
a nested-COW fixture whose IR module lli refuses, sitting in OK_HARNESS).
The parity test therefore requires the same stderr *shape* as well as equal
stdout, and anything that falls through is classified by the ordered rules
below — a lone interp-ir stderr reaches GAP_IR_ENGINE, not OK.

STDOUT IS NOT A JUDGE, WHERE THE SCHEDULER WRITES IT
----------------------------------------------------
One fixture prints from two workers, so the order of its lines belongs to the
scheduler and not to the program: byte equality between the arms is then a coin
flip, and a baseline entry for it flips the gate at random. A print is one
uninterrupted run of writes now, so the lines themselves are whole — the only
freedom left is their order. Fixtures named in NONDETERMINISTIC_STDOUT are
therefore compared as a multiset of lines, which still fails on a missing, extra
or altered line. The list is deliberately short: each name is an admission that
this fixture cannot judge ordering, not a way to quiet a divergence.

PROCESS CONTAINMENT
-------------------
`pini run-llvm` writes `/tmp/pini_<uuid>.ll` and then blocks in
`Process.waitUntilExit`, so a fixture that loops by design produces a
two-level tree: probe -> pini -> lli. The interp-ir channel spawns no child,
so its timeouts need only the group kill and leave the lli reaper nothing to
collect. Killing only the probe's direct child
is not enough, and two failure modes were measured on 2026-09-11:

  * a SIGKILLed `pini` never runs the `defer` that removes the temp .ll, so
    the file is left behind — one pair of files per hang (same source, legacy
    and IR emitter, so two distinct md5s), about 30 s apart;
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

Usage:  python3 tools/ir-parity-probe.py [--root DIR]... [--filter SUBSTR]
                                        [--timeout SECONDS] [--out FILE]
Output: /tmp/ir-parity-sweep.tsv by default; --out redirects it.
        (A fixed destination made a mutation sweep overwrite the frozen
        baseline silently -- measured 2026-09-15. Callers that run a
        mutation must now point --out somewhere of their own.)
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
# Filled in by `main` from `resolve_bin`. A product path is the toolchain's
# answer to a question, so the toolchain is who gets asked -- see WHICH BINARY.
BIN_ENV = "PINI_SWEEP_BIN"
BIN = ""
# Resolve lli through the toolchain path as well as PATH, so the probe does
# not depend on the caller having sourced a shell profile.
LLVM_BIN = "/opt/homebrew/opt/llvm/bin"
OUT = "/tmp/ir-parity-sweep.tsv"
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
    "Tests/PiniTests/CodeGen/IRTests",
    "examples",
]

# 行序由调度决定、逐字节比对不成立的 fixture：按行多重集比较，不按序列。
# 行内不再交错（打印整行加锁），故这里只需放过排列，行内容与行数仍判。
NONDETERMINISTIC_STDOUT = {"examples/concurrency.pini": "行序由调度决定（A/B 交错）"}

F64_SIX = re.compile(r"\d+\.\d{6}")
# The IR execution engine names the node it cannot run yet; that message is the
# whole judgement for IR_ENGINE_TODO (see classify).
DIAG_CODE = re.compile(r"\[([A-Z]\d-\d+)\]")
IR_TODO = re.compile(
    r"node '([A-Za-z_][A-Za-z0-9_]*)' is dispatched but not implemented yet")
# 解释器按设计拒绝的调用形态：码由它自己给出，同一 fixture 在 run-llvm 上通过。
# 标的是通道能力边界（c-interop-design 已登记），不是引擎跑错，故不计 blocker。
DECLARED_LIMITS = {
    "E5-019": "变参调用要 C 变参 ABI，解释器只转发固定签名",
    "E5-020": "字符串句柄由运行时段持有，pini 进程里没有这些符号",
}
# 基线条目的处置。两个词回答的不是「要不要拦」，而是「这条差异该谁改」：
# declared = 语言按文档如此，两通道本就不该相同；debt = 实现欠着，登记只为让门禁能跑。
# 只写 fixture 与 verdict 时，读者分不清这两种，门禁上它们长得一样。
DISPOSITIONS = ("declared", "debt")
# 这次运行为什么停下，看 `Error:` 行 —— 它前面可能已经排着若干警告码。
ERROR_CODE = re.compile(r"^Error: .*?\[([A-Z]\d-\d+)\]", re.MULTILINE)

# Scratch root for isolated runs; created on first use, removed at the end.
_scratch_root = [None]
# lli processes alive when the sweep started; anything newer is ours to reap.
_lli_baseline = set()
# Stray .ll files present before the sweep; anything newer is our litter.
_stray_baseline = set()
# Every .ll removed by a reaper, including the per-timeout ones. Reporting only
# the final pass would print "0 killed" for a sweep that killed several.
_reaped = []


def _show_bin_path(scratch_path):
    """SwiftPM's answer to "where is the product", or "" if it cannot say."""
    cmd = ["swift", "build", "--disable-sandbox", "--show-bin-path"]
    if scratch_path:
        cmd += ["--scratch-path", scratch_path]
    try:
        out = subprocess.run(cmd, cwd=REPO, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=180).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = out.decode("utf-8", "replace").strip().splitlines()
    return lines[-1] if lines else ""


def resolve_bin(scratch_path=None):
    """The CLI to sweep: the override when set, else whatever was built."""
    override = os.environ.get(BIN_ENV)
    if override:
        return override
    bin_dir = _show_bin_path(scratch_path)
    return os.path.join(bin_dir, "pini") if bin_dir else ""


def build_hint(scratch_path=None):
    """The one command that lands a CLI exactly where `resolve_bin` reads."""
    cmd = "swift build --disable-sandbox --product pini"
    if scratch_path:
        cmd += " --scratch-path " + scratch_path
    return cmd


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
    # No engine is selected here: there is only one engine to label, so a caller's
    # shell cannot relabel a channel.
    if env_extra:
        env.update(env_extra)
    # Own process group: `pini run-llvm` spawns lli as a child, so a plain timeout
    # kills only the direct child. The group kill is a first attempt, not a guarantee —
    # a surviving lli still holds the inherited pipe; the reaper contains it.
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
        # BOUNDED drain: the group kill may leave lli holding the inherited pipe open,
        # so an unbounded `communicate()` would deadlock the whole sweep without a diagnostic.
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
    missing = []
    for root in roots:
        base = os.path.join(REPO, root)
        if not os.path.isdir(base):
            # Do not return in silence: a missing root must be reported. The corpus a parity
            # verdict rests on is part of the verdict — green over one root is not green over six.
            missing.append(root)
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.endswith(".pini"):
                    rel = os.path.relpath(os.path.join(dirpath, name), REPO)
                    if needle and needle not in rel:
                        continue
                    files.append((root, rel))
    if missing:
        print(
            "coverage: %d of %d roots missing -- %s"
            % (len(missing), len(roots), ", ".join(missing)),
            file=sys.stderr,
        )
        print("coverage: %d .pini collected" % len(files), file=sys.stderr)
    return files


def diag_code(text):
    """The first diagnostic code in `text`, or "" — the unit of corroboration.

    Used to ask whether two paths are reporting the *same* diagnostic rather
    than merely both being unhappy: a front end complaining about something
    else is not evidence about where this diagnostic came from.
    """
    m = DIAG_CODE.search(text)
    return m.group(1) if m else ""


def failing_code(text):
    """The code on the `Error:` line, or "" if the run did not name one.

    `diag_code` answers "which code appears first", and on a fixture that warns
    before it fails that is a warning code. The declared-limit rule needs the
    other question: what stopped the run.
    """
    m = ERROR_CODE.search(text)
    return m.group(1) if m else ""


def same_stdout(rel, l_out, h_out):
    """Whether the two arms printed the same stdout, in the sense this fixture allows.

    Byte equality is the default. A fixture in NONDETERMINISTIC_STDOUT prints from
    more than one worker, so the order of its lines belongs to the scheduler rather
    than to the program. Comparing the line multiset drops that one freedom and
    keeps the rest: a missing, extra or altered line still fails.
    """
    if rel in NONDETERMINISTIC_STDOUT:
        return sorted(l_out.splitlines()) == sorted(h_out.splitlines())
    return l_out == h_out


def classify(rel, l_rc, l_out, l_err, h_rc, h_out, h_err, c_rc, c_err):
    """Verdict for one fixture across the two execution channels.

    `l` = llvm-ir (`run-llvm`, the arm that lowers to IR), `h` = interp-ir (the
    IR execution engine). They are separate implementations, which is what makes
    the comparison between them worth making.

    `c` = the front end (`check`), which executes nothing. It is an instrument,
    not a tird channel: it only ever answers "did the shared front end produce
    this diagnostic". It is consulted in one slot, where the alternative would be
    to guess the origin of a warning from the fact that one arm printed it.

    Until G-6c there was a tird execution channel, the AST walk, held as a
    frozen reference. Its removal is why the parity tests below are between two
    arms and why the reference-relative slots are gone; the docstring's VERDICTS
    section records what replaced what.
    """
    # 1. A file inside a module cannot run standalone at all.
    if in_module(rel):
        return "PACKAGE_MEMBER", ""
    # 2. Wall-clock verdicts come first: a hung channel reports rc 124, which the
    # front-end rule would file as FRONTEND_FAIL and drop out of the blocker count.
    if h_rc == 124 and l_rc != 124:
        return "GAP_HANG", "llvm-ir terminated in time, interp-ir did not"
    if l_rc == 124 and h_rc == 124:
        return "TIMEOUT_ALL", "loops by design; both channels hit the wall clock"
    if l_rc == 124:
        return "TIMEOUT_LLVM", "llvm-ir hangs, interp-ir terminates"
    # 3. The LLVM arm rejects it -> not a backend gap. Both arms typecheck, so
    #    this is the front end and the emitter agreeing to refuse.
    if l_rc != 0:
        return "FRONTEND_FAIL", first_line(l_err)
    # 4. interp-ir names a node the engine has not built yet: that is the work list,
    # not a defect. Checked before the parity rule, which would otherwise file such a
    # run as parity when both arms are equally loud for unrelated reasons.
    m = IR_TODO.search(h_err)
    if m:
        return "IR_ENGINE_TODO", "interp-ir: node '%s' not implemented" % m.group(1)
    # 5. The IR arm failed, whatever stdout says — checked before the parity rule:
    # equal stdout on two failed arms is not evidence of parity.
    if h_rc != 0:
        # 5a. Both arms report a failure on stderr, so the LLVM arm's rc 0 is the harness
        # discarding lli's exit status, not a success. The condition that matters:
        # a fixture that only fails on the IR arm still reaches GAP_EXEC below.
        if l_err.strip():
            return "WARN_LLVM_RC_UNPROPAGATED", first_line(h_err)
        # 5b. The interpreter stops at a call shape it declines by design while the
        # LLVM arm ran the fixture. Keyed on the code that stopped the run, so a
        # warning printed earlier cannot stand in for the failure.
        code = failing_code(h_err)
        if code in DECLARED_LIMITS:
            return "CHANNEL_LIMIT", "%s：%s" % (code, DECLARED_LIMITS[code])
        return "GAP_EXEC", first_line(h_err)
    # 6. Parity across BOTH channels. The stderr shape is part of it because a
    #    silent-stdout crash on one side and a silent-stdout success on the other
    #    look identical on stdout alone.
    if same_stdout(rel, l_out, h_out) and bool(l_err.strip()) == bool(h_err.strip()):
        if l_err.strip():
            # parity, but the standalone channel is not the real harness
            # (the test substitutes paths / supplies a program base).
            return "OK_HARNESS", first_line(h_err or l_err)
        return "OK", ""
    # 7. The LLVM arm did not run cleanly either -> the standalone channel
    #    cannot judge this fixture; excluding it is honest, not lenient.
    if l_err.strip():
        return "HARNESS_DEPENDENT", first_line(l_err)
    # 8. Diagnostic-channel asymmetry: equal stdout means the stderr shapes differed.
    # `check` answers whether that warning belongs to the shared front end; the same
    # code means front end (not a gap), different or absent falls through to rule 9.
    if h_err.strip() and same_stdout(rel, l_out, h_out) and diag_code(c_err) and \
            diag_code(c_err) == diag_code(h_err):
        return "WARN_CHANNEL_ASYMMETRY", first_line(h_err)
    # 9. The IR arm is loud and the front end does not corroborate it.
    if h_err.strip():
        return "GAP_IR_ENGINE", first_line(h_err)
    # 10. Both arms ran to completion and their stdout differs: a real execution
    #     divergence between the two implementations. This is the two-arm form of
    #     what the retired GAP_BEHAVIOR / CHANGE_* slots split between them.
    if l_out != h_out:
        return "GAP_BEHAVIOR", ""
    return "GAP_UNKNOWN", ""


def compare_with(path, open_gaps):
    """基线与本次读数对撞：新缺口红，转绿的旧条目也红（棘轮只许缩小）。

    每条登记必须写清处置与理由。四列格式是这一版的判据：只写「哪个 fixture、
    什么判定」时，读者无从区分「文档规定两通道就该不同」与「实现欠着没修」，
    而这两件事在门禁上长得完全一样。

    返回 ({(fixture, verdict): 处置}, 问题行)。问题行非空即判失败。
    """
    known, problems = {}, []
    if not os.path.isfile(path):
        return known, ["基线缺失：%s（新增 --baseline 时先落一份）" % path]
    with open(path, encoding="utf-8-sig") as handle:
        for number, line in enumerate(handle, 1):
            body = line.rstrip("\n")
            if not body.strip() or body.lstrip().startswith("#"):
                continue
            cells = body.split("\t")
            if len(cells) != 4:
                problems.append(
                    "基线第 %d 行不是四列（fixture / verdict / 处置 / 理由）：%r"
                    % (number, body))
                continue
            fixture, verdict, disposition, reason = (cell.strip() for cell in cells)
            if disposition not in DISPOSITIONS:
                problems.append(
                    "基线第 %d 行的处置不认识：%r（只能写 %s）"
                    % (number, disposition, " / ".join(DISPOSITIONS)))
            if not reason:
                problems.append(
                    "基线第 %d 行没有理由：登记差异要写清是文档规定还是实现待修"
                    % number)
            if (fixture, verdict) in known:
                problems.append(
                    "基线第 %d 行重复登记：%s / %s" % (number, fixture, verdict))
            known[(fixture, verdict)] = disposition
    seen = {(r["fixture"], r["verdict"]) for r in open_gaps}
    for fixture, verdict in sorted(seen - set(known)):
        problems.append("新增缺口 %-14s %s" % (verdict, fixture))
    for fixture, verdict in sorted(set(known) - seen):
        problems.append("基线已过期（该条转绿或消失，删掉它）%-14s %s" % (verdict, fixture))
    return known, problems


def baseline_self_test():
    """四列基线的阳性与阴性对照：合法条目通过，缺列 / 错处置 / 空理由各判红。

    与 classify 的自检分开：这一组不打任何子进程，读的是一份临时基线。
    """
    bad = []

    def gap(fixture):
        return {"fixture": fixture, "verdict": "GAP_BEHAVIOR"}

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "baseline.tsv")

        def probe(name, body, open_gaps, want):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            known, problems = compare_with(path, open_gaps)
            joined = " | ".join(problems)
            if want is None:
                if problems:
                    bad.append("%s：应通过，实际 %s" % (name, joined))
            elif want not in joined:
                bad.append("%s：应报 %r，实际 %r" % (name, want, joined))
            return known

        row = "examples/a.pini\tGAP_BEHAVIOR\tdebt\t解释器待修\n"
        known = probe("合法四列", "# 头\n" + row, [gap("examples/a.pini")], None)
        if known.get(("examples/a.pini", "GAP_BEHAVIOR")) != "debt":
            bad.append("合法四列：处置没读出来")
        probe("缺理由", "examples/a.pini\tGAP_BEHAVIOR\tdebt\t\n",
              [gap("examples/a.pini")], "没有理由")
        probe("错处置", "examples/a.pini\tGAP_BEHAVIOR\tsomeday\t待修\n",
              [gap("examples/a.pini")], "处置不认识")
        probe("三列", "examples/a.pini\tGAP_BEHAVIOR\tdebt\n",
              [gap("examples/a.pini")], "不是四列")
        probe("新增缺口", "", [gap("examples/a.pini")], "新增缺口")
        probe("过期条目", "examples/b.pini\tGAP_BEHAVIOR\tdebt\t待修\n", [], "基线已过期")
    return bad


def self_test():
    """What the declared-limit slot must catch, and what it must not swallow.

    Synthetic classifier inputs only — no binary, no fixture, no lli — so the
    proof costs a moment and can run before a sweep that might never reach the
    shape. The first two cases carry a warning code ahead of the failing one,
    which is how these fixtures actually print.
    """
    shape = "Warning: 语义警告 [E7-007]\nError: Runtime Error [%s]\n"
    cases = [
        ("E5-019", "CHANNEL_LIMIT", "变参调用是已声明的通道边界"),
        ("E5-020", "CHANNEL_LIMIT", "字符串句柄是已声明的通道边界"),
        ("E5-003", "GAP_EXEC", "别的运行时错误仍算缺口"),
    ]
    bad = []
    for code, want, why in cases:
        got, _ = classify("t.pini", 0, "", "", 1, "", shape % code, 0, "")
        if got != want:
            bad.append("%s -> %s（应为 %s：%s）" % (code, got, want, why))
    # LLVM 臂也报错时 5a 先判：这一格不能抢在它前面把双失败读成通道边界。
    got, _ = classify("t.pini", 0, "", "boom", 1, "", shape % "E5-020", 0, "")
    if got != "WARN_LLVM_RC_UNPROPAGATED":
        bad.append("llvm 臂也报错 -> %s（应为 WARN_LLVM_RC_UNPROPAGATED）" % got)
    bad += baseline_self_test()
    for line in bad:
        print("self-test FAIL: %s" % line)
    print("self-test %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main():
    global RUN_TIMEOUT, OUT, BIN
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", action="append", default=None)
    ap.add_argument("--filter", default=None,
                    help="only fixtures whose repo-relative path contains this")
    ap.add_argument("--timeout", type=int, default=RUN_TIMEOUT,
                    help="per-channel wall clock, seconds (default %d)" % RUN_TIMEOUT)
    ap.add_argument("--out", default=OUT,
                    help="per-fixture TSV destination (default %s)" % OUT)
    ap.add_argument("--baseline", default=None,
                    help="known-gap TSV: a blocker not listed fails the sweep, "
                         "and a listed one that turns clean fails it too (shrink-only)")
    ap.add_argument("--scratch-path", default=None,
                    help="where the CLI was built: passed to `swift build "
                         "--show-bin-path` so the probe reads that build, and "
                         "repeated in the hint below when it is missing")
    args = ap.parse_args()
    roots = args.root or DEFAULT_ROOTS
    RUN_TIMEOUT = args.timeout
    OUT = args.out

    BIN = resolve_bin(args.scratch_path)
    if not BIN or not os.access(BIN, os.X_OK):
        print("pini binary missing at %s" % (BIN or "<unresolved>"), file=sys.stderr)
        print("  build it with:  %s" % build_hint(args.scratch_path), file=sys.stderr)
        print("  (that command lands the CLI exactly where this probe reads it; "
              "set %s to point the probe at another build)" % BIN_ENV, file=sys.stderr)
        return 1
    # Named on every run: with the path resolved rather than written down, the
    # first question about any reading is which build produced it.
    print("binary under test: %s" % BIN)

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
            l_rc, l_out, l_err = run([BIN, "run-llvm", run_path], cwd=cwd)
            h_rc, h_out, h_err = run([BIN, "run", run_path], cwd=cwd)
            # The front-end instrument runs nothing; exactly one rule consults it, for the
            # question the two execution channels cannot answer: shared front end or engine.
            c_rc, _c_out, c_err = run([BIN, "check", run_path], cwd=cwd)
            verdict, note = classify(rel, l_rc, l_out, l_err, h_rc, h_out,
                                     h_err, c_rc, c_err)
            rows.append({
                "verdict": verdict, "note": note, "root": root, "fixture": rel,
                "l_rc": l_rc, "h_rc": h_rc, "c_rc": c_rc,
                "l_len": len(l_out), "h_len": len(h_out),
                "l_out": l_out, "h_out": h_out,
                "l_err": l_err, "h_err": h_err, "c_err": c_err,
            })
            if n % 50 == 0 or n == len(fixtures):
                print("  %d/%d  (%.0fs)" % (n, len(fixtures), time.time() - t0),
                      flush=True)
    finally:
        leaks = reap_orphans(_lli_baseline)
        removed = clean_new_strays()
        if _scratch_root[0] and os.path.isdir(_scratch_root[0]):
            shutil.rmtree(_scratch_root[0], ignore_errors=True)

    cols = ["verdict", "root", "fixture", "l_rc", "h_rc", "c_rc",
            "l_len", "h_len", "note"]
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\t".join(cols) + "\n")
        for r in rows:
            fh.write("\t".join(str(r[c]) for c in cols) + "\n")

    order = ["OK", "OK_HARNESS", "PACKAGE_MEMBER", "FRONTEND_FAIL",
             "HARNESS_DEPENDENT", "IR_ENGINE_TODO", "CHANNEL_LIMIT", "GAP_EXEC",
             "GAP_IR_ENGINE", "GAP_BEHAVIOR", "GAP_UNKNOWN", "GAP_HANG",
             "TIMEOUT_ALL", "TIMEOUT_LLVM", "WARN_CHANNEL_ASYMMETRY",
             "WARN_LLVM_RC_UNPROPAGATED"]
    print("\n=== summary ===")
    for v in order:
        n = sum(1 for r in rows if r["verdict"] == v)
        if n:
            print("  %-15s %d" % (v, n))
    # BLOCKERS = "do the two implementations disagree"; IR_ENGINE_TODO answers how much
    # of the engine is left to build, and merging them would make this line unreadable.
    # WARN_* counts are printed with their fixture lists below instead of being summed in.
    blockers = [r for r in rows if r["verdict"] in
                ("GAP_EXEC", "GAP_IR_ENGINE", "GAP_BEHAVIOR", "GAP_HANG")]
    unknown = [r for r in rows if r["verdict"] == "GAP_UNKNOWN"]
    print("  %-15s %d" % ("FLIP BLOCKERS", len(blockers) + len(unknown)))
    # 判据被放宽的 fixture 必须点名，否则读者分不清「没有分歧」与「不比 stdout」。
    unordered = sorted(r["fixture"] for r in rows
                       if r["fixture"] in NONDETERMINISTIC_STDOUT)
    if unordered:
        print("  %-15s %d  %s（行序由调度决定，按行多重集比）"
              % ("unordered", len(unordered), ", ".join(unordered)))
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

    todo = [r for r in rows if r["verdict"] == "IR_ENGINE_TODO"]
    if todo:
        # Aggregated by node rather than listed per fixture: the P2 question is
        # "which nodes are still missing", and the per-fixture rows are already
        # in the TSV for anyone who wants them.
        by_node = {}
        for r in todo:
            node = r["note"].split("'")[1] if "'" in r["note"] else "?"
            by_node.setdefault(node, []).append(r["fixture"])
        print("\n=== IR engine not implemented yet: %d fixture(s), %d node(s) "
              "(P2 work list, not a flip blocker) ===" % (len(todo), len(by_node)))
        for node in sorted(by_node, key=lambda k: (-len(by_node[k]), k)):
            fixtures = by_node[node]
            shown = ", ".join(os.path.basename(f) for f in fixtures[:3])
            if len(fixtures) > 3:
                shown += ", ... (+%d)" % (len(fixtures) - 3)
            print("  %-22s %3d  %s" % (node, len(fixtures), shown))

    asym = [r for r in rows if r["verdict"] == "WARN_CHANNEL_ASYMMETRY"]
    if asym:
        # Its own section, not a blocker line: the flip does not move it, but it must not
        # vanish either. Grouped by error code, so one diagnosis does not read as twenty.
        by_code = {}
        for r in asym:
            code = r["note"].split("[")[-1].split("]")[0] if "[" in r["note"] else "?"
            by_code.setdefault(code, []).append(r["fixture"])
        print("\n=== diagnostic channel asymmetry: %d fixture(s), %d code(s) "
              "(NOT flip blockers — the flip does not move them) ==="
              % (len(asym), len(by_code)))
        for code in sorted(by_code, key=lambda k: (-len(by_code[k]), k)):
            fixtures = by_code[code]
            print("  %-12s %3d  %s" % (code, len(fixtures),
                                       ", ".join(os.path.basename(f)
                                                 for f in fixtures[:3])))
        print("  the warning is the shared front end's -- `pini check` reports "
              "the same code --")
        print("  and only the LLVM arm is silent about it. See")
        print("  docs/issue-diagnostic-channel-parity-2026-09-12.md")

    unpropagated = [r for r in rows
        if r["verdict"] == "WARN_LLVM_RC_UNPROPAGATED"]
    if unpropagated:
        # Its own section for the same reason as the asymmetry slot above:
        # it left the blocker total, so it must not leave the report.
        print("\n=== LLVM arm status not propagated: %d fixture(s) "
              "(NOT flip blockers - the program fails on both engines) ==="
              % len(unpropagated))
        for r in unpropagated:
            print("  %-14s %s" % (r["verdict"], r["fixture"]))
            print("        h_rc=%d  l_rc=%d; llvm stderr=%s  (front end: %s)"
                  % (r["h_rc"], r["l_rc"],
                     "present" if r["l_err"].strip() else "silent",
                     "rc %d" % r["c_rc"]))

    limited = [r for r in rows if r["verdict"] == "CHANNEL_LIMIT"]
    if limited:
        # Same reason as the two slots above: out of the blocker total, still in
        # the report. The code is the interpreter's own, not an inference.
        print("\n=== call shapes the interpreter declines by design: %d fixture(s) "
              "(NOT flip blockers - the LLVM arm runs them) ===" % len(limited))
        for r in limited:
            code, _, why = r["note"].partition("：")
            print("  %-8s %s" % (code, r["fixture"]))
            print("        %s" % why)

    for label, group in [("blockers", blockers + unknown),
                         ("non-terminating fixtures", [r for r in rows
                                                       if r["verdict"].startswith("TIMEOUT_")])]:
        print("\n=== %s ===" % label)
        for r in group:
            print("  %-14s %s" % (r["verdict"], r["fixture"]))
            if r["note"]:
                print("        %s" % r["note"])
            elif r["verdict"].startswith("GAP_"):
                print("        llvm-ir=%r  interp-ir=%r"
                      % (r["l_out"][:60], r["h_out"][:60]))
    print("\ndetail -> %s" % OUT)
    status = 1 if left else 0
    if args.baseline:
        known, problems = compare_with(args.baseline, blockers + unknown)
        status = 1 if problems else status
        counts = {kind: sum(1 for d in known.values() if d == kind)
                  for kind in DISPOSITIONS}
        detail = "，".join("%s %d" % (kind, counts[kind])
                          for kind in DISPOSITIONS if counts[kind])
        print("\n=== baseline: %d known gap(s)%s ==="
              % (len(known), "（%s）" % detail if detail else ""))
        for line in problems:
            print("  " + line)
        if not problems:
            print("  no new gap, no stale entry")
    # A surviving lli is a tool failure, not a fixture verdict: exit non-zero
    # so a sweep can never be read as clean while a process is still spinning.
    return status


if __name__ == "__main__":
    # 自检要先于 main 的取产物步骤：它不执行任何程序，缺二进制也该能跑。
    sys.exit(self_test() if "--self-test" in sys.argv[1:] else main())

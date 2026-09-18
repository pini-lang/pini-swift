#!/usr/bin/env python3
"""Print each channel's result, byte-exact, for one or more .pini files.

The companion to tools/hir-parity-probe.py for single-fixture inspection: the
probe answers "how does the whole corpus classify", this answers "what exactly
did each channel print for this file".

TWO CHANNELS AND AN INSTRUMENT (G-6c, 2026-09-18) — the filename is historical
--------------------------------------------------------------------------
This tool used to print three channels, the first of them `interp-ast`, the AST
walk, held as a frozen reference. G-6c deleted the walk, so that channel and the
thing it referenced are both gone. What is left:

    interp-hir  `pini run <file>`        HIR execution engine
    llvm-hir    `pini run-llvm <file>`   HIR -> LLVM
    frontend    `pini check <file>`      runs nothing; prints the shared front
                                         end's diagnostics, which is how a
                                         warning's origin is established

The name was not changed with the arity: dated batch records and tickets cite
this tool by name, and rewriting those would falsify them. The header says what
it does now; the filename says what it did then.

Usage: python3 tools/three-channel.py <fixture.pini> [more.pini ...]
"""

import os
import shutil
import signal
import subprocess
import sys
import tempfile

BIN = os.environ.get(
    "PINI_SWEEP_BIN", "/tmp/pini-build/arm64-apple-macosx/debug/pini"
)
LLVM_BIN = "/opt/homebrew/opt/llvm/bin"
RUN_TIMEOUT = 10


def run(args, extra_env=None, cwd=None):
    env = dict(os.environ)
    env.setdefault("PINI_LLVM_BIN", LLVM_BIN)
    # Drop any inherited engine: every channel states its engine explicitly, so
    # a value in the caller's shell cannot relabel a channel.
    # No engine is selected per channel any more: G-6c retired the switch with
    # the AST walk, so there is exactly one engine to label.
    if extra_env:
        env.update(extra_env)
    # Own process group so a timeout takes down lli (pini's child) too —
    # a plain kill on pini orphans lli, which then spins forever.
    proc = subprocess.Popen(
        args, env=env, cwd=cwd,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        out, err = proc.communicate(timeout=RUN_TIMEOUT)
        return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 124, "", "TIMEOUT after %ss" % RUN_TIMEOUT


def show(label, rc, out, err):
    print(f"--- {label}: rc={rc}")
    print(f"    stdout={out!r}")
    if err.strip():
        lines = err.strip().splitlines()
        print(f"    stderr[0]={lines[0]!r}  ({len(lines)} line(s))")


def probe(path):
    path = os.path.abspath(path)
    print(f"===== {path}")
    # Copy the fixture into a scratch dir and run the copy: pini resolves
    # relative I/O against the SOURCE FILE's directory, not the cwd, so a
    # fixture carrying an unreplaced harness placeholder (e.g. __PATH__)
    # would otherwise litter the real fixture directory with its output.
    with tempfile.TemporaryDirectory() as scratch:
        copy = os.path.join(scratch, os.path.basename(path))
        shutil.copy(path, copy)
        show("frontend  ", *run([BIN, "check", copy], cwd=scratch))
        show("interp-hir", *run([BIN, "run", copy], cwd=scratch))
        show("llvm-hir  ", *run([BIN, "run-llvm", copy], cwd=scratch))
    print()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        probe(path)


if __name__ == "__main__":
    main()

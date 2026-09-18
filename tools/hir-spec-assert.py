#!/usr/bin/env python3
"""Layer-3 spec assertions: judge each channel against a hand-written .expected.

Where the other two layers compare implementations against each other, this one
compares each implementation against the SPEC. That distinction is the whole
point, and it is also the easiest thing in the world to lose: if an .expected is
ever produced by copying some channel's output, layer 3 silently becomes layer 1
again -- it would then only ever report "the implementation agrees with itself".

So:

  * Check mode (default) is the real job. It never writes anything.
  * Generate mode (--generate --force) exists only to bootstrap a new case, and
    it refuses to write unless every channel already agrees (otherwise it would
    freeze a live divergence into the spec baseline). It also stamps the
    provenance file so a generated expectation can never pass as a hand-written
    one.

CHANNELS: G-6c (2026-09-18) removed the `interp-ast` channel along with the AST
walk it named, leaving the HIR executor and the LLVM pipeline. Generating a case
therefore needs those two to agree, where it used to need three.

What is asserted: standard output byte-for-byte, and the exit code. Standard
error is deliberately NOT asserted -- a batch of known diagnostic-channel
asymmetries lives there, and pulling them in on day one would bury the new
instrument under defects that are already ticketed elsewhere.

Usage:
    python3 tools/hir-spec-assert.py                 # check every case
    python3 tools/hir-spec-assert.py --filter f64    # check a subset
    python3 tools/hir-spec-assert.py --generate --force --filter newCase
"""

import argparse
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

CORPUS = "Tests/PiniTests/SpecAssertionTests"
PROVENANCE = "PROVENANCE.md"

# The channels, defined the same way as tools/three-channel.py. `interp-ast` was
# the third until G-6c deleted the AST walk it named; nothing selects an engine
# here any more, because there is only one.
CHANNELS = [
    ("interp-hir", ["run"], {}),
    ("llvm-hir", ["run-llvm"], None),
]


def run(argv, extra_env, cwd):
    env = dict(os.environ)
    env.setdefault("PINI_LLVM_BIN", LLVM_BIN)
    # Single engine since G-6c; the switch this used to clear is gone.
    if extra_env:
        env.update(extra_env)
    # Own process group so a timeout also reaps lli, which would otherwise
    # survive its parent and spin forever.
    proc = subprocess.Popen(
        argv, env=env, cwd=cwd,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        out, err = proc.communicate(timeout=RUN_TIMEOUT)
        return proc.returncode, out, err
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 124, b"", b"TIMEOUT"


def run_case(path):
    """Return {channel: (rc, stdout_bytes)} for one fixture."""
    results = {}
    with tempfile.TemporaryDirectory() as scratch:
        copy = os.path.join(scratch, os.path.basename(path))
        shutil.copy(path, copy)
        for label, subcommand, extra_env in CHANNELS:
            rc, out, _err = run([BIN] + subcommand + [copy], extra_env, scratch)
            results[label] = (rc, out)
    return results


def cases(needle=None):
    names = sorted(
        f[: -len(".pini")]
        for f in os.listdir(CORPUS)
        if f.endswith(".pini")
    )
    if needle:
        names = [n for n in names if needle in n]
    return names


def check(names):
    failures = 0
    print("%-24s %s" % ("case", "  ".join("%-11s" % c[0] for c in CHANNELS)))
    for name in names:
        expected_path = os.path.join(CORPUS, name + ".expected")
        if not os.path.exists(expected_path):
            print("%-24s MISSING .expected" % name)
            failures += 1
            continue
        with open(expected_path, "rb") as f:
            expected = f.read()
        row = []
        for label, _sub, _env in CHANNELS:
            rc, out = run_case(os.path.join(CORPUS, name + ".pini"))[label]
            if rc != 0:
                row.append("%-11s" % ("rc=%d" % rc))
                failures += 1
            elif out != expected:
                row.append("%-11s" % "DIFF")
                failures += 1
            else:
                row.append("%-11s" % "ok")
        print("%-24s %s" % (name, "  ".join(row)))
    total = len(names) * len(CHANNELS)
    print()
    print("%d assertions over %d cases: %d ok, %d failed"
          % (total, len(names), total - failures, failures))
    return 1 if failures else 0


def generate(names):
    for name in names:
        results = run_case(os.path.join(CORPUS, name + ".pini"))
        distinct = set(v for v in results.values())
        if len(distinct) != 1:
            print("refusing %s: channels disagree, nothing to freeze" % name)
            for label, (rc, out) in results.items():
                print("    %-11s rc=%d %r" % (label, rc, out))
            continue
        rc, out = distinct.pop()
        with open(os.path.join(CORPUS, name + ".expected"), "wb") as f:
            f.write(out)
        stamp_provenance(name, "GENERATED", rc)
        print("generated %s (rc=%d) -- stamped as GENERATED" % (name, rc))
    return 0


def stamp_provenance(name, kind, rc):
    line = "- `%s` — %s" % (name, kind)
    with open(os.path.join(CORPUS, PROVENANCE), "a") as f:
        f.write(line + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", help="only cases whose name contains this")
    ap.add_argument("--generate", action="store_true",
                    help="write .expected from the channels (requires --force)")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    root = os.getcwd()
    if not os.path.isdir(CORPUS):
        sys.exit("run me from the repository root (no %s here)" % CORPUS)

    names = cases(args.filter)
    if not names:
        sys.exit("no cases matched")

    if args.generate:
        if not args.force:
            sys.exit("generate mode needs --force: it can silently turn "
                     "layer 3 back into layer 1")
        print("WARNING: writing expectations from observed output. Anything "
              "written this way is a record of behaviour, not a spec "
              "assertion.\n", file=sys.stderr)
        return generate(names)
    return check(names)


if __name__ == "__main__":
    sys.exit(main())

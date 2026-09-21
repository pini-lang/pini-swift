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

FIXTURES AND EXPECTATIONS LIVE IN TWO ROOTS (2026-09-21). The fixtures stay in
`examples/`, the directory that already owns them, and only the expectations
move to a root of their own. A second copy of a fixture is a second thing to
drift, and this repository has already paid that price for the scheduling
surface. The consequence worth knowing: the guarded set is "every .expected in
the expectation root", NOT "every .pini in the fixture root". Adding an example
does not add it here; adding an expectation does. That is deliberate -- the
other reading would turn the whole example tree into a red ledger overnight.

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
import time

BIN_ENV = "PINI_SWEEP_BIN"
BIN = ""
FIXTURE_ROOT = "examples"
EXPECT_ROOT = "Tests/PiniTests/ContractExpectations"
LLVM_BIN = "/opt/homebrew/opt/llvm/bin"
RUN_TIMEOUT = 10

PROVENANCE = "PROVENANCE.md"

# The channels, defined the same way as tools/three-channel.py. `interp-ast` was
# the third until G-6c deleted the AST walk it named; nothing selects an engine
# here any more, because there is only one.
CHANNELS = [
    ("interp-hir", ["run"], {}),
    ("llvm-hir", ["run-llvm"], None),
]


def _show_bin_path(scratch_path=None):
    """SwiftPM's answer to "where is the product", or "" if it cannot say."""
    cmd = ["swift", "build", "--disable-sandbox", "--show-bin-path"]
    if scratch_path:
        cmd += ["--scratch-path", scratch_path]
    try:
        out = subprocess.run(cmd, cwd=os.getcwd(), stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=180).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = out.decode("utf-8", "replace").strip().splitlines()
    return lines[-1] if lines else ""


def resolve_bin(scratch_path=None):
    """The CLI under test: the override when set, else whatever was built.

    The path is asked for, not written down. A constant here has already gone
    stale once -- it named a directory this machine does not produce -- and a
    stale constant does not fail loudly, it just judges a build that is not the
    one in front of you.
    """
    override = os.environ.get(BIN_ENV)
    if override:
        return override
    where = _show_bin_path(scratch_path)
    return os.path.join(where, "pini") if where else ""


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


def expected_cases(needle=None):
    """The guarded set: every expectation in the expectation root."""
    if not os.path.isdir(EXPECT_ROOT):
        return []
    names = sorted(
        f[: -len(".expected")]
        for f in os.listdir(EXPECT_ROOT)
        if f.endswith(".expected")
    )
    if needle:
        names = [n for n in names if needle in n]
    return names


def fixture_cases(needle=None):
    """Every fixture in the fixture root -- the input side of generate mode."""
    names = sorted(
        f[: -len(".pini")]
        for f in os.listdir(FIXTURE_ROOT)
        if f.endswith(".pini")
    )
    if needle:
        names = [n for n in names if needle in n]
    return names


def check(names):
    failures = 0
    print("%-24s %s" % ("case", "  ".join("%-11s" % c[0] for c in CHANNELS)))
    for name in names:
        expected_path = os.path.join(EXPECT_ROOT, name + ".expected")
        if not os.path.exists(expected_path):
            print("%-24s MISSING .expected" % name)
            failures += 1
            continue
        # The expectation is the registry, so a name that got this far has an
        # expectation by construction -- but the FIXTURE can still be gone, and
        # that is the drift this root split introduces: rename or delete an
        # example and the expectation it left behind would otherwise crash the
        # copy below instead of saying so.
        fixture_path = os.path.join(FIXTURE_ROOT, name + ".pini")
        if not os.path.exists(fixture_path):
            print("%-24s MISSING %s" % (name, fixture_path))
            failures += 1
            continue
        with open(expected_path, "rb") as f:
            expected = f.read()
        # One run per fixture: run_case already drives every channel, so asking
        # it once per channel would run the program twice over.
        results = run_case(fixture_path)
        row = []
        for label, _sub, _env in CHANNELS:
            rc, out = results[label]
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
        results = run_case(os.path.join(FIXTURE_ROOT, name + ".pini"))
        distinct = set(v for v in results.values())
        if len(distinct) != 1:
            print("refusing %s: channels disagree, nothing to freeze" % name)
            for label, (rc, out) in results.items():
                print("    %-11s rc=%d %r" % (label, rc, out))
            continue
        rc, out = distinct.pop()
        with open(os.path.join(EXPECT_ROOT, name + ".expected"), "wb") as f:
            f.write(out)
        stamp_provenance(name, "GENERATED", rc)
        print("generated %s (rc=%d) -- stamped as GENERATED" % (name, rc))
    return 0


def stamp_provenance(name, kind, rc):
    line = "- `%s` — %s" % (name, kind)
    with open(os.path.join(EXPECT_ROOT, PROVENANCE), "a") as f:
        f.write(line + "\n")


def main():
    global BIN
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", help="only cases whose name contains this")
    ap.add_argument("--generate", action="store_true",
                    help="write .expected from the channels (requires --force)")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--scratch-path", default=None,
                    help="where the CLI was built: passed to `swift build "
                         "--show-bin-path` so the check reads that build")
    args = ap.parse_args()

    if not os.path.isdir(FIXTURE_ROOT):
        sys.exit("run me from the repository root (no %s here)" % FIXTURE_ROOT)

    BIN = resolve_bin(args.scratch_path)
    if not BIN or not os.access(BIN, os.X_OK):
        sys.exit("no CLI at %s -- build it, or point %s at one"
                 % (BIN or "<unresolved>", BIN_ENV))
    # Named on every run, with its build time: with the path resolved rather
    # than written down, the first question about any reading is which build
    # produced it. The time is on the same line on purpose -- a resolved path
    # can still name a build from before the change under test, and that shows
    # up here as an old date rather than as a mystery failure.
    built = time.strftime("%Y-%m-%d %H:%M",
                          time.localtime(os.stat(BIN).st_mtime))
    print("binary under test: %s (built %s)" % (BIN, built))

    if args.generate:
        if not args.force:
            sys.exit("generate mode needs --force: it can silently turn "
                     "layer 3 back into layer 1")
        print("WARNING: writing expectations from observed output. Anything "
              "written this way is a record of behaviour, not a spec "
              "assertion.\n", file=sys.stderr)
        os.makedirs(EXPECT_ROOT, exist_ok=True)
        names = fixture_cases(args.filter)
        if not names:
            sys.exit("no fixtures matched")
        return generate(names)

    names = expected_cases(args.filter)
    if not names:
        sys.exit("no expectations in %s matched" % EXPECT_ROOT)
    return check(names)


if __name__ == "__main__":
    sys.exit(main())

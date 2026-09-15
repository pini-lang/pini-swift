#!/usr/bin/env python3
"""Gate changes to the frozen AST-walk surface behind a declaration marker.

Between here and P4, the AST walk is still the default execution engine, but it
is scheduled for deletion. The failure mode this guards against is not "someone
changed it" -- it is "someone changed it without realising they were adding to
something that is going away", leaving no record of why the change existed when
P4 arrives.

So this is a threshold, not a prohibition: any change with a reason is fine, it
just has to say so. See docs/hir-ast-walk-freeze.md.

Usage:
    python3 tools/ast-walk-freeze-check.py
        Report whether the staged change touches the frozen surface. Always
        exits 0 -- informational, for running by hand.

    python3 tools/ast-walk-freeze-check.py --message-file <path>
        Gate mode, used by hooks/commit-msg. Exits 1 when the staged change
        touches the frozen surface and the commit message carries no marker.
"""

import argparse
import subprocess
import sys

# The frozen surface. HIRExecutor is deliberately absent: it is the side being
# migrated TO, not the side being frozen.
FROZEN = [
    "Sources/PiniCore/Interpreter/Interpreter.swift",
    "Sources/PiniCore/Interpreter/SuspendEvaluator.swift",
]

MARKER = "[ast-walk]"


def staged_files():
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only"],
        capture_output=True, text=True, check=True,
    )
    return [line.strip() for line in out.stdout.splitlines() if line.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--message-file",
                    help="commit message file (gate mode; hooks/commit-msg)")
    args = ap.parse_args()

    try:
        staged = staged_files()
    except subprocess.CalledProcessError as exc:
        print("cannot read the staged change: %s" % exc, file=sys.stderr)
        return 0  # never block a commit because plumbing failed

    hits = [f for f in staged if f in FROZEN]
    if not hits:
        return 0

    if not args.message_file:
        print("staged change touches the frozen AST-walk surface:")
        for f in hits:
            print("    %s" % f)
        print('add %s to the commit message and say why. See '
              'docs/hir-ast-walk-freeze.md' % MARKER)
        return 0

    try:
        with open(args.message_file, encoding="utf-8", errors="replace") as f:
            message = f.read()
    except OSError as exc:
        print("cannot read the commit message: %s" % exc, file=sys.stderr)
        return 0

    if MARKER in message:
        return 0

    print("⛔ this change touches the frozen AST-walk surface but carries no "
          "%s marker:" % MARKER, file=sys.stderr)
    for f in hits:
        print("    %s" % f, file=sys.stderr)
    print("""
    The walk is scheduled for deletion at P4. Changes to it are allowed, they
    just have to declare themselves: add %s to the commit message and say what
    changed, why now, and what happens to it at P4 (deleted with the walk /
    moved to HIR / neither).

    See docs/hir-ast-walk-freeze.md -- this is a threshold, not a ban.
""" % MARKER, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

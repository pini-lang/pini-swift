#!/usr/bin/env python3
"""Diff two hir-parity-probe TSVs — the isolation proof for one convergence grid.

A grid's change is "isolated" when the corpus verdicts move only for the
fixtures the grid targets and nothing else. This prints the per-verdict deltas
and the per-fixture verdict changes, flagging blockers resolved and newly
introduced.

Usage: python3 tools/compare-sweeps.py <before.tsv> <after.tsv>
"""

import collections
import sys

BLOCKERS = ("GAP_EXEC", "GAP_IR", "GAP_BEHAVIOR", "GAP_UNKNOWN")


def load(path):
    """Read a sweep TSV: verdict, root, fixture, l_rc, h_rc, i_rc, lens, note."""
    rows = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            rows[parts[2]] = parts[0]
    return rows


def main():
    before = load(sys.argv[1])
    after = load(sys.argv[2])
    print(f"before fixtures={len(before)}  after fixtures={len(after)}")

    counts_before = collections.Counter(before.values())
    counts_after = collections.Counter(after.values())
    print(f"\n{'verdict':<18}{'before':>8}{'after':>8}{'delta':>8}")
    for key in sorted(set(counts_before) | set(counts_after)):
        delta = counts_after[key] - counts_before[key]
        print(f"{key:<18}{counts_before[key]:>8}{counts_after[key]:>8}{delta:>+8}"
              + ("  <<<" if delta else ""))

    total_before = sum(counts_before[k] for k in BLOCKERS)
    total_after = sum(counts_after[k] for k in BLOCKERS)
    print(f"\nTRUE BLOCKERS  before={total_before}  after={total_after}"
          f"  delta={total_after - total_before:+d}")

    changed = [(rel, before[rel], after[rel])
               for rel in sorted(set(before) & set(after))
               if before[rel] != after[rel]]
    print(f"\n=== per-fixture verdict changes ({len(changed)}) ===")
    for rel, old, new in changed:
        mark = ""
        if old in BLOCKERS and new not in BLOCKERS:
            mark = "  [BLOCKER-RESOLVED]"
        elif new in BLOCKERS and old not in BLOCKERS:
            mark = "  [NEW-BLOCKER]"
        print(f"  {old:<16} -> {new:<16} {rel}{mark}")

    only_before = sorted(set(before) - set(after))
    only_after = sorted(set(after) - set(before))
    if only_before:
        print(f"\n=== only in before ({len(only_before)}) ===")
        for rel in only_before:
            print(f"  {before[rel]:<16} {rel}")
    if only_after:
        print(f"\n=== only in after ({len(only_after)}) ===")
        for rel in only_after:
            print(f"  {after[rel]:<16} {rel}")


if __name__ == "__main__":
    main()

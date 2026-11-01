#!/usr/bin/env python3
"""Cross-check the runtime ABI contract against the exported symbol set.

WHY THIS EXISTS
---------------
`docs/spec/runtime-abi.md` claims to be the single authority for the `bk_*`
surface, and its own maintenance clause states the only self-check it has:
"清单数 = 导出数". That equation is worth nothing unless something computes it.
This script computes it.

THREE SIDES
-----------
    contract   the family table in section 2 (names + per-family counts + total)
    exports    `@_cdecl("bk_...")` in PiniRuntime.swift
    arithmetic each family row's count equals the names listed in that row

    contract-without-export   a name in the table that nothing exports
    export-without-contract   an exported name missing from the table
    count-mismatch            a family row's count does not match its names
    total-mismatch            the stated total is not the sum of the rows

The doc records a known measuring trap: `@_cdecl` appears twice in prose without
exporting anything, so counting occurrences gives 99 while the export count is
97. This script counts `@_cdecl("<name>")` only, which is the documented unit.

Usage:
    python3 tools/runtime-abi-check.py [--quiet]
Exit status is 0 when every check passes, 1 otherwise.
"""

import os
import re
import sys

ROOT = os.environ.get(
    "RUNTIME_ABI_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)
CONTRACT = os.path.join(ROOT, "docs/spec/runtime-abi.md")
RUNTIME = os.path.join(ROOT, "Sources/PiniRuntime/PiniRuntime.swift")

ROW = re.compile(r"^\|\s*([^|]+?)\s*\|(.+?)\|\s*\*{0,2}(\d+)\*{0,2}\s*\|\s*$")
NAME = re.compile(r"`(bk_[A-Za-z0-9_]+)`")
EXPORT = re.compile(r'@_cdecl\("(bk_[A-Za-z0-9_]+)"\)')


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def parse_contract():
    text = read(CONTRACT)
    start = text.index("## 2. 符号清单")
    end = text.index("## 3.", start)
    block = text[start:end]

    names, counts, total = set(), [], None
    for line in block.splitlines():
        m = ROW.match(line)
        if not m:
            continue
        family, cells, declared = m.group(1).strip(), m.group(2), m.group(3)
        row_names = NAME.findall(cells)
        if family.startswith("**合计**"):
            total = int(declared)
            continue
        if not row_names:
            continue
        counts.append((family, len(row_names), int(declared)))
        names.update(row_names)
    return names, counts, total


def main():
    quiet = "--quiet" in sys.argv
    names, counts, total = parse_contract()
    exported = set(EXPORT.findall(read(RUNTIME)))

    failures = []
    if total is None:
        failures.append("no total row found in the contract")
    else:
        summed = sum(n for _, n, _ in counts)
        if total != summed:
            failures.append("total row says %d, family rows sum to %d" % (total, summed))
        if total != len(names):
            failures.append("total row says %d, table lists %d names" % (total, len(names)))

    for family, actual, declared in counts:
        if actual != declared:
            failures.append(
                "family %s declares %d but lists %d" % (family, declared, actual)
            )

    missing = sorted(names - exported)
    extra = sorted(exported - names)
    if missing:
        failures.append("contract-without-export: %s" % ", ".join(missing))
    if extra:
        failures.append("export-without-contract: %s" % ", ".join(extra))

    if not quiet:
        print("contract: %d families, %d names, total %s" % (len(counts), len(names), total))
        print("runtime:  %d exported bk_* symbols" % len(exported))
        print()

    for line in failures:
        print("FAIL: %s" % line)
    if failures:
        print("\n%d check(s) failed" % len(failures))
        return 1
    print("runtime abi check: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())

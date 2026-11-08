#!/usr/bin/env python3
"""Cross-check the scalar names behind `*T`: one table, two mapping switches.

WHY THIS EXISTS
---------------
`CPointerTarget.scalarWidths` is the authority for which names may be a pointer
target. Three other places spell those names again:

    import    `FFIType.scalar(named:)`        the C boundary's closed set
    runtime   `RuntimeOps.decodePointer`      the width a load reads
    runtime   `RuntimeOps.encode`             the width a store writes

When one of them gains a name the table never got, the compiler accepts a type
the runtime cannot read; when the table gains one a switch never got, the value
is rejected with "not supported" at run time. Neither shows up in a build, and
the scalar widths are small enough that a test can pass while one side drifts.

Usage:
    python3 tools/scalar-set-check.py [--quiet] [--self-test]
Exit status is 0 when every check passes, 1 otherwise.
"""

import os
import re
import sys

ROOT = os.environ.get(
    "SCALAR_SET_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)
TABLE = os.path.join(ROOT, "Sources/PiniSemantics/Common/CPointerTarget.swift")
IMPORT = os.path.join(ROOT, "Sources/PiniSemantics/Common/FFIType.swift")
RUNTIME = os.path.join(ROOT, "Sources/PiniHost/Runtime/RuntimeOps.swift")

QUOTED = re.compile(r'"([A-Za-z0-9_]+)"')
TABLE_ENTRY = re.compile(r'"([A-Za-z0-9_]+)"\s*:\s*(\d+)')
NAME_CASE = re.compile(r'case\s+((?:"[A-Za-z0-9_]+"\s*,\s*)*"[A-Za-z0-9_]+")\s*:')


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def names_in(block):
    found = set()
    for group in NAME_CASE.findall(block):
        found.update(QUOTED.findall(group))
    return found


def function_body(text, signature):
    """From the signature to the next four-space closing brace.

    These functions hold no nested declaration, so the first such brace ends the
    body. A rename makes `index` raise, and the caller reports it instead of
    silently comparing two empty sets.
    """
    start = text.index(signature)
    end = text.index("\n    }\n", start)
    return text[start:end]


def width_table(text):
    start = text.index("scalarWidths")
    start = text.index("= [", start)
    end = text.index("\n    ]", start)
    return {name: int(width) for name, width in TABLE_ENTRY.findall(text[start:end])}


def check(table, sides):
    failures = []
    if len(table) < 2:
        failures.append("table-parse: 宽度表只解析出 %d 个名字" % len(table))
    for name, width in sorted(table.items()):
        if width <= 0:
            failures.append("bad-width: %s -> %d" % (name, width))
    for side, names in sides.items():
        if not names:
            failures.append("side-empty: %s 没有解析到任何名字（函数改名了？）" % side)
        for name in sorted(set(table) - names):
            failures.append("missing-in-%s: %s" % (side, name))
        for name in sorted(names - set(table)):
            failures.append("extra-in-%s: %s" % (side, name))
    return failures


def self_test():
    ok = True
    good = {"import": {"A", "B"}, "runtime": {"A", "B"}}
    if check({"A": 1, "B": 8}, good):
        print("self-test FAIL: matching sets reported %s" % check({"A": 1, "B": 8}, good)[0])
        ok = False

    got = check({"A": 1, "B": 8}, {"import": {"A"}, "runtime": {"A", "B", "C"}})
    for want in ("missing-in-import", "extra-in-runtime"):
        if not any(line.startswith(want) for line in got):
            print("self-test FAIL: %s was not caught, got %s" % (want, got))
            ok = False
    if not any(line.startswith("bad-width") for line in check({"A": 0}, {"import": {"A"}})):
        print("self-test FAIL: a zero width was not caught")
        ok = False
    if not any(line.startswith("side-empty") for line in check({"A": 1}, {"import": set()})):
        print("self-test FAIL: an unparsed side was not caught")
        ok = False

    sample = 'switch name {\n            case "A", "B": return\n            case .simple:\n'
    if names_in(sample) != {"A", "B"}:
        print("self-test FAIL: case extraction got %s" % sorted(names_in(sample)))
        ok = False

    print("self-test %s" % ("PASS" if ok else "FAIL"))
    return ok


def main():
    quiet = "--quiet" in sys.argv
    if "--self-test" in sys.argv:
        return 0 if self_test() else 1

    failures = []
    try:
        table = width_table(read(TABLE))
        sides = {
            "import": names_in(function_body(read(IMPORT), "private static func scalar")),
            "runtime-decode": names_in(function_body(read(RUNTIME), "static func decodePointer")),
            "runtime-encode": names_in(function_body(read(RUNTIME), "static func encode")),
        }
    except ValueError as error:
        print("标量集合门禁：解析失败（%s）。函数或表改名后，这条判据要跟着改。" % error,
              file=sys.stderr)
        return 2

    failures += check(table, sides)
    if not quiet:
        print("表: %d 个 · 导入面: %d 个 · 运行时解码: %d 个 · 运行时编码: %d 个"
              % (len(table), len(sides["import"]),
                 len(sides["runtime-decode"]), len(sides["runtime-encode"])))
    for line in failures:
        print("FAIL: %s" % line)
    if failures:
        print("\n%d check(s) failed" % len(failures))
        return 1
    print("scalar set check: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())

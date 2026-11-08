#!/usr/bin/env python3
"""Cross-check the two diagnostic tables: same codes, same fields, same placeholders.

WHY THIS EXISTS
---------------
`Diagnostics.zh.toml` and `Diagnostics.en.toml` are read by one lookup. A code
present in one and missing from the other falls back to the raw code at runtime,
and a placeholder present in one but absent from the other renders as literal
braces. Both failures are invisible in the language you happen to be running.

CHECKS
------
    key-missing-en / key-missing-zh   one table has a section the other never got
    field-missing-*                   same code, different field set
    placeholder-mismatch              same code, different `{name}` set
    empty-field                       a field that says nothing
    suspiciously-small                the table did not parse as the real thing

Usage:
    python3 tools/diagnostics-parity-check.py [--quiet] [--self-test]
Exit status is 0 when every check passes, 1 otherwise.
"""

import os
import re
import sys
import tomllib

ROOT = os.environ.get(
    "DIAGNOSTICS_PARITY_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)
TABLES = {
    "zh": os.path.join(ROOT, "Sources/PiniSemantics/Resources/Diagnostics.zh.toml"),
    "en": os.path.join(ROOT, "Sources/PiniSemantics/Resources/Diagnostics.en.toml"),
}
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")
FLOOR = 10


def load(path):
    with open(path, "rb") as handle:
        return tomllib.load(handle)


def compare(zh, en):
    """Same section set, same field set per section, same placeholders per field."""
    failures = []
    for key in sorted(set(zh) - set(en)):
        failures.append("key-missing-en: %s" % key)
    for key in sorted(set(en) - set(zh)):
        failures.append("key-missing-zh: %s" % key)
    for key in sorted(set(zh) & set(en)):
        left, right = zh[key], en[key]
        if not isinstance(left, dict) or not isinstance(right, dict):
            failures.append("not-a-section: %s" % key)
            continue
        for field in sorted(set(left) - set(right)):
            failures.append("field-missing-en: %s.%s" % (key, field))
        for field in sorted(set(right) - set(left)):
            failures.append("field-missing-zh: %s.%s" % (key, field))
        for field in sorted(set(left) & set(right)):
            a, b = left[field], right[field]
            if not isinstance(a, str) or not isinstance(b, str):
                failures.append("not-a-string: %s.%s" % (key, field))
                continue
            if not a.strip() or not b.strip():
                failures.append("empty-field: %s.%s" % (key, field))
            pa = set(PLACEHOLDER.findall(a))
            pb = set(PLACEHOLDER.findall(b))
            if pa != pb:
                failures.append(
                    "placeholder-mismatch: %s.%s zh=%s en=%s"
                    % (key, field, sorted(pa), sorted(pb)))
    return failures


def self_test():
    ok = True
    base = {"E1-001": {"message": "x {a}", "suggestion": "s"},
            "labels": {"lexer": "词法"}}
    twin = {"E1-001": {"message": "x {a}", "suggestion": "s"},
            "labels": {"lexer": "Lexer"}}
    if compare(base, twin):
        print("self-test FAIL: matching tables reported %s" % compare(base, twin)[0])
        ok = False

    cases = [
        ("key-missing-en", {"E1-001": {"message": "x"}, "E1-002": {"message": "y"}}, twin),
        ("field-missing-zh", {"E1-001": {"message": "x"}, "labels": {"lexer": "l"}}, twin),
        ("placeholder-mismatch", {"E1-001": {"message": "x {b}"}, "labels": {"lexer": "l"}}, twin),
        ("empty-field", {"E1-001": {"message": "x {a}", "suggestion": " "}, "labels": {"lexer": "l"}}, twin),
    ]
    for want, left, right in cases:
        got = compare(left, right)
        if not any(line.startswith(want) for line in got):
            print("self-test FAIL: %s was not caught, got %s" % (want, got))
            ok = False

    print("self-test %s" % ("PASS" if ok else "FAIL"))
    return ok


def main():
    quiet = "--quiet" in sys.argv
    if "--self-test" in sys.argv:
        return 0 if self_test() else 1

    if not all(os.path.isfile(path) for path in TABLES.values()):
        missing = [path for path in TABLES.values() if not os.path.isfile(path)]
        print("诊断表一致性门禁：找不到 %s" % ", ".join(missing), file=sys.stderr)
        return 2

    tables = {lang: load(path) for lang, path in TABLES.items()}
    failures = []
    for lang, table in tables.items():
        if len(table) < FLOOR:
            failures.append(
                "suspiciously-small: %s 只解析出 %d 节（下限 %d）" % (lang, len(table), FLOOR))
    failures += compare(tables["zh"], tables["en"])

    if not quiet:
        print("zh: %d 节 · en: %d 节 · 差异 %d 处"
              % (len(tables["zh"]), len(tables["en"]), len(failures)))
    for line in failures:
        print("FAIL: %s" % line)
    if failures:
        print("\n%d check(s) failed" % len(failures))
        return 1
    print("diagnostics parity check: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())

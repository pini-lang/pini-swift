#!/usr/bin/env python3
"""Cross-check the compiler's builtin inventory against the runtime surface and its lowering points.

WHY THIS EXISTS
---------------
`docs/spec/runtime-abi.md` fixes the runtime's exported symbol set and its own self-check
("清单数 = 导出数"). That equation says nothing about the compiler: a symbol can be exported and never
called, or called under a name the runtime does not export. The second failure is invisible in the
source because the call site spells the name once, as a string.

`Sources/PiniBackendLLVM/CodeGen/BuiltinInventory.swift` is the compiler's answer to "what can this backend
emit". This script joins it with the other two sides:

    contract   the family table in runtime-abi.md section 2 (parsed by runtime-abi-check.py)
    runtime    `@_cdecl("bk_...")` in PiniRuntime.swift
    inventory  `BuiltinSpec` entries in BuiltinInventory.swift
    lowering   `bk_*` tokens in CodeGen sources other than the inventory itself

Checks:
    inventory-without-contract   the compiler can emit a symbol the contract never listed
    inventory-without-export     the compiler can emit a symbol nothing exports
    lowering-without-inventory   a CodeGen call site names a symbol absent from the inventory
    inventory-without-lowering   an inventory entry nothing in CodeGen mentions
    family-mismatch              an entry's family differs from the contract row holding it
    lowering-name-unknown        a lowering tag is neither an IR case nor a `<...>` pseudo-site
    zero-site-conflict           a symbol claimed as zero-call-site is in the inventory
    zero-site-missing            a contract symbol is neither in the inventory nor registered as zero-site

The last two make section 4 exhaustive: every contract symbol is either wired or registered.

Usage:
    python3 tools/builtin-inventory-check.py [--quiet] [--self-test]
Exit status is 0 when every check passes, 1 otherwise.
"""

import importlib.util
import os
import re
import sys

ROOT = os.environ.get(
    "BUILTIN_INVENTORY_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)
RUNTIME_ABI_CHECK = os.path.join(ROOT, "tools/runtime-abi-check.py")
CONTRACT = os.path.join(ROOT, "docs/spec/runtime-abi.md")
RUNTIME = os.path.join(ROOT, "Sources/PiniRuntime/PiniRuntime.swift")
INVENTORY = os.path.join(ROOT, "Sources/PiniBackendLLVM/CodeGen/BuiltinInventory.swift")
CODEGEN = os.path.join(ROOT, "Sources/PiniBackendLLVM/CodeGen")
IRNODE = os.path.join(ROOT, "Sources/PiniIR/IR/IRNode.swift")

FAMILY = {
    "array": "数组",
    "dictionary": "字典",
    "set": "集合",
    "handle": "句柄 / COW",
    "lazyRef": "LazyRef",
    "given": "默认实例",
    "pointer": "指针",
    "display": "展示 / 陷阱",
    "runtime": "运行时",
    "character": "字符",
    "string": "字符串面",
    "stringHandle": "字符串句柄",
    "nominal": "闭包 / 结构体胶水",
    "io": "IO / 宿主查询",
    "task": "任务 / 并发",
    "blocking": "阻塞内建",
    "yielding": "让出族",
    "scheduler": "调度驱动面",
    "error": "错误载荷",
}

PSEUDO_SITES = {"cleanup", "retain", "entry", "print", "panic", "closure", "frame", "yield"}

ENTRY = re.compile(r"BuiltinSpec\(\n(.*?)\n        \),", re.S)
SYMBOL = re.compile(r'symbol: "(bk_[a-z0-9_]+)"')
FAMILY_FIELD = re.compile(r"family: \.([A-Za-z]+)")
LOWERINGS = re.compile(r"lowerings: \[(.*?)\]", re.S)
QUOTED = re.compile(r'"([^"]+)"')
TICKED = re.compile(r"`([^`]+)`")
EXPORT = re.compile(r'@_cdecl\("(bk_[A-Za-z0-9_]+)"\)')
TOKEN = re.compile(r"\b(bk_[a-z0-9_]+[a-z0-9])\b")

# `%bk_array` and friends are the opaque handle type names, not callable symbols.
TYPE_NAMES = {"bk_array", "bk_dict", "bk_set", "bk_lazyref", "bk_nominal", "bk_handle", "bk_str", "bk_task"}


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def load_runtime_abi_check():
    spec = importlib.util.spec_from_file_location("runtime_abi_check", RUNTIME_ABI_CHECK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_inventory(text):
    entries = []
    for block in ENTRY.findall(text):
        symbol = SYMBOL.search(block)
        family = FAMILY_FIELD.search(block)
        lowerings = LOWERINGS.search(block)
        if not (symbol and family and lowerings):
            continue
        tags = QUOTED.findall(lowerings.group(1))
        entries.append((symbol.group(1), family.group(1), tags))
    return entries


def code_lines(path):
    """Drop comment-only lines: a symbol named in prose is not a call site."""
    for line in read(path).splitlines():
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            continue
        yield line


def lowering_mentions():
    mentioned = set()
    for name in sorted(os.listdir(CODEGEN)):
        if not name.endswith(".swift") or name == os.path.basename(INVENTORY):
            continue
        for line in code_lines(os.path.join(CODEGEN, name)):
            mentioned.update(TOKEN.findall(line))
    return mentioned - TYPE_NAMES


def ir_case_names():
    text = read(IRNODE)
    names = set()
    for header in ("public indirect enum IRStmt", "public indirect enum IRExpr"):
        start = text.index(header)
        depth, i = 0, start
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = text[start:i]
        names.update(re.findall(r"^\s+case ([a-zA-Z]+)", block, re.M))
    return names


def parse_zero_sites(contract_text, contract_names):
    start = contract_text.index("## 4.")
    end = contract_text.index("## 5.", start)
    registered = set()
    for line in contract_text[start:end].splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 3 or not cells[1].isdigit():
            continue
        for token in TICKED.findall(cells[0]):
            if token.endswith("*"):
                registered.update(n for n in contract_names if n.startswith(token[:-1]))
            else:
                registered.add(token)
    return registered


def check(contract_names, exports, entries, mentions, cases, zero_sites):
    failures = []
    inventory = {symbol: (family, tags) for symbol, family, tags in entries}
    if len(inventory) != len(entries):
        failures.append("inventory lists the same symbol twice")

    for symbol, family, tags in entries:
        if symbol not in contract_names:
            failures.append("inventory-without-contract: %s" % symbol)
        if symbol not in exports:
            failures.append("inventory-without-export: %s" % symbol)
        if symbol not in mentions:
            failures.append("inventory-without-lowering: %s" % symbol)
        expected = FAMILY.get(family)
        if expected is None:
            failures.append("family-unknown: %s uses .%s" % (symbol, family))
        elif expected != contract_names.get(symbol):
            failures.append(
                "family-mismatch: %s says .%s, contract says %s"
                % (symbol, family, contract_names.get(symbol, "<absent>"))
            )
        for tag in tags:
            if tag.startswith("<") and tag.endswith(">"):
                if tag[1:-1] not in PSEUDO_SITES:
                    failures.append("lowering-name-unknown: %s -> %s" % (symbol, tag))
            elif tag not in cases:
                failures.append("lowering-name-unknown: %s -> %s (no IR case)" % (symbol, tag))

    for symbol in sorted(mentions - set(inventory)):
        failures.append("lowering-without-inventory: %s" % symbol)
    for symbol in sorted(set(inventory) & zero_sites):
        failures.append("zero-site-conflict: %s is wired and also registered as zero-call-site" % symbol)

    unaccounted = contract_names.keys() - set(inventory) - zero_sites
    for symbol in sorted(unaccounted):
        failures.append("zero-site-missing: %s is neither wired nor registered" % symbol)
    stale = zero_sites - contract_names.keys()
    for symbol in sorted(stale):
        failures.append("zero-site-stale: %s is registered but not in the contract" % symbol)
    return failures


def self_test():
    """The joins must fire on a planted gap and stay silent on a clean pair."""
    contract = {"bk_a": "数组", "bk_b": "数组"}
    exports = {"bk_a", "bk_b"}
    cases = {"call"}
    ok = True

    clean = [("bk_a", "array", ["call"]), ("bk_b", "array", ["<cleanup>"])]
    failures = check(contract, exports, clean, {"bk_a", "bk_b"}, cases, set())
    if failures:
        print("self-test FAIL: clean inventory reported %s" % failures[0])
        ok = False

    planted = [("bk_a", "array", ["call"]), ("bk_c", "array", ["call"])]
    failures = check(contract, exports, planted, {"bk_a", "bk_c"}, cases, set())
    if not any(f.startswith("inventory-without-contract") for f in failures):
        print("self-test FAIL: an invented symbol was not caught")
        ok = False
    if not any(f.startswith("zero-site-missing") for f in failures):
        print("self-test FAIL: an unregistered contract symbol was not caught")
        ok = False

    print("self-test %s" % ("PASS" if ok else "FAIL"))
    return ok


def main():
    quiet = "--quiet" in sys.argv
    if "--self-test" in sys.argv:
        return 0 if self_test() else 1

    contract_names = {}
    for family, listed in abi_families():
        for symbol in listed:
            contract_names[symbol] = family
    exports = set(EXPORT.findall(read(RUNTIME)))
    entries = parse_inventory(read(INVENTORY))
    mentions = lowering_mentions()
    cases = ir_case_names()
    zero_sites = parse_zero_sites(read(CONTRACT), set(contract_names))

    failures = check(contract_names, exports, entries, mentions, cases, zero_sites)

    if not quiet:
        families = {}
        for _, family, _ in entries:
            families[family] = families.get(family, 0) + 1
        print("contract:  %d symbols" % len(contract_names))
        print("runtime:   %d exported" % len(exports))
        print("inventory: %d entries across %d families" % (len(entries), len(families)))
        print("lowering:  %d symbols mentioned in CodeGen" % len(mentions))
        print("zero-site: %d registered" % len(zero_sites))
        print()

    for line in failures:
        print("FAIL: %s" % line)
    if failures:
        print("\n%d check(s) failed" % len(failures))
        return 1
    print("builtin inventory check: clean")
    return 0


def abi_families():
    """(family label, symbols) pairs, reusing runtime-abi-check's table reader."""
    abi = load_runtime_abi_check()
    text = read(CONTRACT)
    start = text.index("## 2. 符号清单")
    end = text.index("## 3.", start)
    for line in text[start:end].splitlines():
        m = abi.ROW.match(line)
        if not m or m.group(1).startswith("**合计**"):
            continue
        symbols = abi.NAME.findall(m.group(2))
        if symbols:
            yield m.group(1).strip(), symbols


if __name__ == "__main__":
    sys.exit(main())

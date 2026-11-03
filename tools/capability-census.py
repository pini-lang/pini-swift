#!/usr/bin/env python3
"""能力普查：量出每条通道实际接受哪些节点，供三态矩阵取数。

矩阵原先只镜像声明（`pini backends --tsv` 本身就是 `BackendCapabilities`），
只能发现「改了声明忘更表」，发现不了「声明说支持、实现却拒绝」。

本脚本把两份既有事实相除：分母取契约第 2、3 节的节点表（谁属于哪一族由小节决定），
分子取后端源码里「`case …:` 体以 `throw` 开头」的整节点拒绝。两者之差即实际接受数。

计量单位是**节点种类**。`binary` 拒位运算、`unary` 拒取反这类操作数形态的限制不计入，
它们不改变族档位，只在 reason 里由后端自己写明。

USAGE
    python3 tools/capability-census.py             # TSV：backend family total refused accepted level
    python3 tools/capability-census.py --check     # 校验拒绝所标的族等于该节点所在小节

EXIT
    0 正常 · 1 `--check` 有不一致 · 2 无法测量（缺契约表、或节点没有 case 标号）
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT = os.path.join(ROOT, "docs/spec/ir-contract.md")

SOURCES = {
    "llvm": ["Sources/PiniBackendLLVM/CodeGen/IREmitter.swift"],
    "json": ["Sources/PiniBackends/JSONBackend.swift"],
    "embedded_min": ["Sources/PiniBackendEmbedded/EmbeddedMinBackend.swift"],
}

SECTION_FAMILY = {
    "2.1": "scalars",
    "2.2": "variablesAndOperators",
    "2.3": "calls",
    "2.4": "resultAndOptional",
    "2.5": "collections",
    "2.6": "nominals",
    "2.7": "pointers",
    "2.8": "fileIO",
    "2.9": "catchableIO",
    "2.10": "strings",
    "2.11": "lazyRef",
    "2.12": "concurrency",
    "2.13": "givenInstances",
    # 2.14 符号地址：符号是给调用准备的地址，拒绝时的族标注也一直写 calls。
    "2.14": "calls",
}
# 契约按「符号」把小节合并，族却按产物分：§2.14 一节两族，按节点拆开。
# 取函数地址归 calls（它是给调用准备的地址），取数据符号地址归 pointers（产物就是 `*T`）。
NODE_FAMILY = {"foreignDataAddress": "pointers"}
FAMILY_ORDER = ["controlFlow"] + list(SECTION_FAMILY.values())
ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*`([A-Za-z_][A-Za-z0-9_]*)", re.M)
HEAD = re.compile(r"^### (2\.\d+)\s+", re.M)


def read(relative):
    with open(os.path.join(ROOT, relative), encoding="utf-8") as handle:
        return handle.read()


def contract_nodes():
    """family -> [(node, section)]，直接读契约的节点表。"""
    text = read("docs/spec/ir-contract.md")
    expr = text[text.index("## 2. 表达式节点"):text.index("## 3. 语句节点")]
    stmt = text[text.index("## 3. 语句节点"):text.index("## 4. 待办")]
    out = {family: [] for family in FAMILY_ORDER}
    marks = list(HEAD.finditer(expr))
    for index, mark in enumerate(marks):
        start = mark.start()
        end = marks[index + 1].start() if index + 1 < len(marks) else len(expr)
        family = SECTION_FAMILY[mark.group(1)]
        for _, node in ROW.findall(expr[start:end]):
            out[NODE_FAMILY.get(node, family)].append((node, mark.group(1)))
    for _, node in ROW.findall(stmt):
        out["controlFlow"].append((node, "3"))
    total = sum(len(nodes) for nodes in out.values())
    if total == 0:
        raise SystemExit("能力普查：契约里没读到节点表（docs/spec/ir-contract.md 变了？）")
    return out


def case_groups(text):
    """[(labels, body, line)]：每条 `case …:` 的标号与体。

    Swift 只在逗号处折行，故续行判据是上一行以 `,` 结尾，不能用「没遇到冒号」。
    """
    lines = text.split("\n")
    groups = []
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        if not stripped.startswith("case ") or stripped.startswith("case let"):
            index += 1
            continue
        head = stripped
        first = index
        while head.endswith(",") and index + 1 < len(lines):
            index += 1
            head = head + " " + lines[index].strip()
        body = []
        probe = index + 1
        while probe < len(lines) and not lines[probe].strip().startswith(("case ", "default:")):
            body.append(lines[probe])
            probe += 1
        groups.append((re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)", head), "\n".join(body), first + 1))
        index += 1
    return groups


def refusals(backend, known):
    """{node: (family, line)}，只收整节点拒绝：`throw` 是 case 体的第一句。"""
    found = {}
    for relative in SOURCES[backend]:
        for labels, body, line in case_groups(read(relative)):
            if "throw" not in body:
                continue
            head = body[:body.index("throw")]
            if re.search(r"\b(guard|if)\b", head):
                continue
            family = re.search(r"(?:unsupported\([^,]*,\s*|family:\s*)\.([A-Za-z]+)", body)
            for label in labels:
                if label in known:
                    found[label] = (family.group(1) if family else None, line)
    return found


def coverage(backend, known):
    """有 case 标号的节点集：没有标号说明这条通道根本没分派到它，档位不可测。"""
    seen = set()
    for relative in SOURCES[backend]:
        for labels, _, _ in case_groups(read(relative)):
            seen.update(label for label in labels if label in known)
    return seen


def measure(contract, known):
    rows = []
    for backend in SOURCES:
        refused = refusals(backend, known)
        seen = coverage(backend, known)
        missing = sorted(known - seen)
        if missing:
            raise SystemExit(f"能力普查：{backend} 有 {len(missing)} 个节点没有 case 标号，"
                             f"档位不可测 —— {', '.join(missing[:6])}")
        for family in FAMILY_ORDER:
            nodes = contract[family]
            hit = [node for node, _ in nodes if node in refused]
            accepted = len(nodes) - len(hit)
            level = "none" if accepted == 0 else ("full" if not hit else "partial")
            rows.append((backend, family, len(nodes), len(hit), accepted, level))
    return rows


def check_tags(contract, known):
    home = dict(SECTION_FAMILY, **{"3": "controlFlow"})
    section = {node: sec for nodes in contract.values() for node, sec in nodes}
    bad = []
    for backend in SOURCES:
        for node, (family, line) in sorted(refusals(backend, known).items()):
            if NODE_FAMILY.get(node, home.get(section[node])) != family:
                bad.append((backend, node, section[node], family, line))
    for backend, node, sec, family, line in bad:
        print(f"{backend}:{line} {node} 属 §{sec}（{home.get(sec)}），标了 {family}", file=sys.stderr)
    if bad:
        print(f"能力普查：{len(bad)} 处族标注与契约小节不符", file=sys.stderr)
        return 1
    print("能力普查：拒绝的族标注与契约小节一致", file=sys.stderr)
    return 0


def main():
    contract = contract_nodes()
    known = {node for nodes in contract.values() for node, _ in nodes}
    if "--check" in sys.argv[1:]:
        return check_tags(contract, known)
    rows = measure(contract, known)
    print("backend\tfamily\ttotal\trefused\taccepted\tlevel")
    for row in rows:
        print("\t".join(str(field) for field in row))
    return 0


if __name__ == "__main__":
    sys.exit(main())

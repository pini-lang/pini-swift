#!/usr/bin/env python3
"""按 docs/spec/ir-contract.md 生成 ir 包的契约节点清单。

清单表是「有节点无契约、有契约无实现」双向检查的自举侧依据：
自举不解析 Markdown，只读这张表，表与节点枚举对不上即红。

族映射与 tools/capability-census.py 同源：节到族一张表，再按节点拆两处
（取函数地址归 calls，取数据符号地址归 pointers）。

用法：
  python3 bootstrap/tools/gen-ir-contract-table.py          生成并写入
  python3 bootstrap/tools/gen-ir-contract-table.py --check  只校验既有产物
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONTRACT = os.path.join(ROOT, "docs/spec/ir-contract.md")
OUTPUT = os.path.join(ROOT, "bootstrap/packages/ir/src/_internal/contract_table.pini")

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
    # 2.15 逻辑短路：与二元运算同族 —— 拒绝它说的是「运算符没实现」。
    "2.15": "variablesAndOperators",
    # 2.16 带标签值的读：读的是枚举 / 可选 / 结果三族的判别式与载荷，拒绝时的族标注也写这个族。
    "2.16": "resultAndOptional",
}

NODE_FAMILY = {"foreignDataAddress": "pointers"}

FAMILY_ORDER = [
    "controlFlow",
    "scalars",
    "variablesAndOperators",
    "calls",
    "resultAndOptional",
    "collections",
    "nominals",
    "pointers",
    "fileIO",
    "catchableIO",
    "strings",
    "lazyRef",
    "concurrency",
    "givenInstances",
]

ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*`([A-Za-z_][A-Za-z0-9_]*)", re.M)
HEAD = re.compile(r"^### (2\.\d+)\s+", re.M)

EXPR_BASE = 1
STMT_BASE = 101


def read_contract():
    used = set(SECTION_FAMILY.values()) | {"controlFlow"}
    if used != set(FAMILY_ORDER):
        raise SystemExit("族映射与族表的集合不一致：%s" % sorted(used ^ set(FAMILY_ORDER)))
    with open(CONTRACT, encoding="utf-8") as handle:
        text = handle.read()
    expr = text[text.index("## 2. 表达式节点"):text.index("## 3. 语句节点")]
    stmt = text[text.index("## 3. 语句节点"):text.index("## 4. 待办")]

    rows = []
    marks = list(HEAD.finditer(expr))
    for index, mark in enumerate(marks):
        start = mark.start()
        end = marks[index + 1].start() if index + 1 < len(marks) else len(expr)
        section = mark.group(1)
        family = SECTION_FAMILY[section]
        for number, name in ROW.findall(expr[start:end]):
            rows.append(
                {
                    "tag": EXPR_BASE + int(number) - 1,
                    "number": int(number),
                    "name": name,
                    "family": NODE_FAMILY.get(name, family),
                    "section": section,
                    "segment": "expr",
                }
            )
    for number, name in ROW.findall(stmt):
        rows.append(
            {
                "tag": STMT_BASE + int(number) - 1,
                "number": int(number),
                "name": name,
                "family": "controlFlow",
                "section": "3",
                "segment": "stmt",
            }
        )
    if not rows:
        raise SystemExit("契约里没读到节点表，docs/spec/ir-contract.md 变了？")
    return rows


def render(rows):
    expr_rows = [row for row in rows if row["segment"] == "expr"]
    stmt_rows = [row for row in rows if row["segment"] == "stmt"]
    numbers = [row["number"] for row in rows if row["segment"] == "expr"]
    if numbers != list(range(1, len(numbers) + 1)):
        raise SystemExit("表达式节点编号不是 1..N 的连续段：%s" % numbers)
    numbers = [row["number"] for row in rows if row["segment"] == "stmt"]
    if numbers != list(range(1, len(numbers) + 1)):
        raise SystemExit("语句节点编号不是 1..N 的连续段：%s" % numbers)

    lines = []
    lines.append("; 由 bootstrap/tools/gen-ir-contract-table.py 生成，勿手改。")
    lines.append("; 源自 IR 节点契约的节点表；族映射与能力普查工具同源。")
    lines.append("; 类别码：表达式段自 %d 起，语句段自 %d 起，与契约条目号一一对应。" % (EXPR_BASE, STMT_BASE))
    lines.append("")
    lines.append("; 契约条目：类别码、节点名、族码与契约小节。")
    lines.append("(IrContractEntry)")
    lines.append("tag: I32 = 0")
    lines.append('name: String = ""')
    lines.append("family: I32 = 0")
    lines.append('section: String = ""')
    lines.append("")
    lines.append("; 契约清单：条目按类别码升序；两段计数供双向检查用。")
    lines.append("(IrContractTable)")
    lines.append("entries: Array<IrContractEntry> = []")
    lines.append("")
    lines.append("; 族名表：下标即族码，与 backend-kit 的能力族同序。")
    lines.append("contractFamilyNames|func() -> (Array<String>,):")
    lines.append("    var out: Array<String> = []")
    for family in FAMILY_ORDER:
        lines.append('    out = out.append("%s")' % family)
    lines.append("    return out")
    lines.append("")
    lines.append("; 族码：名字未登记答 -1。")
    lines.append("contractFamilyId|func(name: String,) -> (I32,):")
    lines.append("    let names = contractFamilyNames()")
    lines.append("    var i = 0")
    lines.append("    while i < len(names):")
    lines.append("        if names[i] == name:")
    lines.append("            return i")
    lines.append("        i = i + 1")
    lines.append("    return -1")
    lines.append("")
    lines.append("; 造一条：字段直填，不做校验。")
    lines.append("makeContractEntry|func(tag: I32, name: String, family: I32, section: String,) -> (IrContractEntry,):")
    lines.append("    var out = IrContractEntry()")
    lines.append("    out.tag = tag")
    lines.append("    out.name = name")
    lines.append("    out.family = family")
    lines.append("    out.section = section")
    lines.append("    return out")
    lines.append("")
    lines.append("; 清单：逐条按类别码升序；两次调用得到同一串条目。")
    lines.append("contractTable|func() -> (IrContractTable,):")
    lines.append("    var out = IrContractTable()")
    for row in rows:
        lines.append("    out.entries = out.entries.append(makeContractEntry(tag = %d, name = \"%s\", family = %d, section = \"%s\"))" % (row["tag"], row["name"], FAMILY_ORDER.index(row["family"]), row["section"]))
    lines.append("    return out")
    lines.append("")
    lines.append("; 条目数：下标合法区间是 0 到 count - 1。")
    lines.append("contractCount|func(table: IrContractTable,) -> (I32,):")
    lines.append("    return len(table.entries)")
    lines.append("")
    lines.append("; 表达式条目数。")
    lines.append("contractExprCount|func(table: IrContractTable,) -> (I32,):")
    lines.append("    var total = 0")
    lines.append("    var i = 0")
    lines.append("    while i < len(table.entries):")
    lines.append("        if table.entries[i].tag < 100:")
    lines.append("            total = total + 1")
    lines.append("        i = i + 1")
    lines.append("    return total")
    lines.append("")
    lines.append("; 语句条目数。")
    lines.append("contractStmtCount|func(table: IrContractTable,) -> (I32,):")
    lines.append("    return len(table.entries) - contractExprCount(table = table)")
    lines.append("")
    lines.append("; 按类别码取条目：未命中答空条目。")
    lines.append("contractAt|func(table: IrContractTable, tag: I32,) -> (IrContractEntry,):")
    lines.append("    var i = 0")
    lines.append("    while i < len(table.entries):")
    lines.append("        if table.entries[i].tag == tag:")
    lines.append("            return table.entries[i]")
    lines.append("        i = i + 1")
    lines.append("    return IrContractEntry()")
    lines.append("")
    lines.append("; 按名字取类别码：未命中答 -1；名字是 ASCII，逐字节比即可。")
    lines.append("contractTagOf|func(table: IrContractTable, name: String,) -> (I32,):")
    lines.append("    var i = 0")
    lines.append("    while i < len(table.entries):")
    lines.append("        if table.entries[i].name == name:")
    lines.append("            return table.entries[i].tag")
    lines.append("        i = i + 1")
    lines.append("    return -1")
    lines.append("")
    lines.append("; 表达式段条数（常量，供节点枚举对照）。")
    lines.append("contractExprTotal|func() -> (I32,):")
    lines.append("    return %d" % len(expr_rows))
    lines.append("")
    lines.append("; 语句段条数。")
    lines.append("contractStmtTotal|func() -> (I32,):")
    lines.append("    return %d" % len(stmt_rows))
    lines.append("")
    return "\n".join(lines)


def main():
    rows = read_contract()
    text = render(rows)
    if "--check" in sys.argv[1:]:
        if not os.path.exists(OUTPUT):
            raise SystemExit("清单表不存在，先运行生成")
        with open(OUTPUT, encoding="utf-8") as handle:
            current = handle.read()
        if current != text:
            raise SystemExit("清单表与契约不一致，重新生成")
        print("清单表一致：%d 条" % len(rows))
        return
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("写入 %s：%d 条" % (os.path.relpath(OUTPUT, ROOT), len(rows)))


if __name__ == "__main__":
    main()

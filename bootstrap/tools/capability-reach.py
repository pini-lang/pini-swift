#!/usr/bin/env python3
"""能力可达普查：自举侧每条契约节点是否「降载可达 / 发射接通 / 族已声明」。

WHY THIS EXISTS
---------------
`能力族增量扩面` 曾把「族未声明」当成用户能撞上的缺口，实测相反：未接的十五条节点
在降载面一条也产不出来，用户程序撞到的是「外部调用 xxx」。「族声明」「发射分支」
「降载产出」是三件事，只有分开计量，才谈得上按族扩面。

WHAT IT MEASURES
    lowering   `bootstrap/packages/ir/src/api` 里 `irExprTag(.irX)` / `irStmtTag(.irX)` 的产出点
    emitting   `backend-llvm/src/_internal/bodies.pini` 里的 `node.kind == <类别码>` 分派
    declared   `backend-llvm/src/api/emit.pini` 的 `llvmFamilies()` 族码表

`--check` 只判两条：接通即声明、声明即至少接一条。族已声明而个别节点未接是
正常状态 —— 缺口文案正是「类别码 N 未接」，与「族未声明」分列。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BOOT = ROOT / "bootstrap" / "packages"
CONTRACT = BOOT / "ir" / "src" / "_internal" / "contract_table.pini"
IR_API = BOOT / "ir" / "src" / "api"
BODIES = BOOT / "backend-llvm" / "src" / "_internal" / "bodies.pini"
EMIT = BOOT / "backend-llvm" / "src" / "api" / "emit.pini"

ENTRY_RE = re.compile(
    r'makeContractEntry\(tag = (\d+), name = "([^"]+)", family = (\d+)'
)
FAMILY_RE = re.compile(r'out = out\.append\("([A-Za-z]+)"\)')
PRODUCE_RE = re.compile(r"ir(?:Expr|Stmt)Tag\(\.(ir[A-Z]\w+)\)")


def contract_entries():
    text = CONTRACT.read_text(encoding="utf-8")
    return [(int(tag), name, int(fam)) for tag, name, fam in ENTRY_RE.findall(text)]


def family_names():
    text = CONTRACT.read_text(encoding="utf-8")
    block = text.split("contractFamilyNames|func", 1)[1].split("return out", 1)[0]
    return FAMILY_RE.findall(block)


def produced_kinds():
    names = set()
    for path in sorted(IR_API.glob("*.pini")):
        if path.name in ("share.pini", "node.pini", "validate.pini"):
            continue
        for hit in PRODUCE_RE.findall(path.read_text(encoding="utf-8")):
            names.add(hit[2:].lower())
    return names


def emitted_tags():
    text = BODIES.read_text(encoding="utf-8")
    return {int(tag) for tag in re.findall(r"node\.kind == (\d+)", text)}


def declared_families():
    text = EMIT.read_text(encoding="utf-8")
    block = text.split("llvmFamilies|func", 1)[1].split("]", 1)[0]
    return {int(code) for code in re.findall(r"\d+", block.split("[", 1)[1])}


def main() -> int:
    entries = contract_entries()
    families = family_names()
    made = produced_kinds()
    emitted = emitted_tags()
    declared = declared_families()

    rows = []
    for tag, name, family in entries:
        lower = name.lower() in made
        emit = tag in emitted
        rows.append((name, tag, families[family] if family < len(families) else "?", lower, emit, family in declared))

    if "--check" in sys.argv:
        bad = 0
        for name, tag, family, lower, emit, dec in rows:
            if emit and not dec:
                print(f" 行不通  {name} 已发射但族 {family} 未声明", file=sys.stderr)
                bad += 1
        for code, family in enumerate(families):
            mine = [r for r in rows if r[2] == family]
            if code in declared and not any(r[4] for r in mine):
                print(f" 行不通  族 {family} 已声明却一个节点也没接", file=sys.stderr)
                bad += 1
        if bad:
            return 1
        print("能力可达自检通过：接通即声明，声明即至少接一条")
        return 0

    print("node\ttag\tfamily\tlowered\temitted\tdeclared")
    for name, tag, family, lower, emit, dec in sorted(rows, key=lambda r: r[1]):
        print(f"{name}\t{tag}\t{family}\t{int(lower)}\t{int(emit)}\t{int(dec)}")

    print()
    print("family\ttotal\tlowered\temitted\tdeclared")
    for code, family in enumerate(families):
        mine = [r for r in rows if r[5] is not None and r[2] == family]
        total = len(mine)
        if total == 0:
            continue
        print(
            f"{family}\t{total}\t{sum(1 for r in mine if r[3])}"
            f"\t{sum(1 for r in mine if r[4])}\t{int(code in declared)}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

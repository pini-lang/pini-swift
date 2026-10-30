#!/usr/bin/env python3
"""给 struct 或 enum 补上 Sendable 遵循 —— Swift 6 迁移的机械步骤。

WHY THIS EXISTS
---------------
Swift 6 的严格并发检查要求跨隔离域传递的值是 Sendable。逐个人工补注解既慢又会漏，
而这一批改动是纯机械的：声明处加一个协议名，语义由编译器随后校验。

本工具只做「加」这一件事，不判断该不该加。加上去之后编译不过的地方，正说明那个结构
真的不安全（字段里有类、闭包或指针）—— 那些点必须人来定夺，工具不替人决定。

用法：
    python3 tools/add-sendable.py Tests            # 就地改写
    python3 tools/add-sendable.py Tests --dry-run  # 只报不写
    python3 tools/add-sendable.py Tests --check    # 有未加注的即以 1 退出
    python3 tools/add-sendable.py Sources --enums  # 改注 enum（含 indirect enum）
"""

import argparse
import pathlib
import re
import sys

# 声明头：可选的访问级、关键字、名字、可选泛型参数、可选继承子句，直到 `{`。
# 继承子句里可能有 `where`，插入点必须在它之前，故单独捕获。
# 访问级必须捕获后原样写回：丢了就是静默降可见性，编译照过的改动。
ACCESS = r"(?P<access>(?:(?:public|internal|fileprivate|private|package)\s+)?)"

DECL = re.compile(
    r"(?m)^(?P<indent>[ \t]*)"
    + ACCESS
    + r"struct\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*(?P<generic><[^{}]*?>)?"
    r"(?P<clause>[^{}]*?)"
    r"\{"
)

# enum 版：多一个可选的 `indirect`。两版分开写，免得 struct 路径被间接地放宽。
ENUM_DECL = re.compile(
    r"(?m)^(?P<indent>[ \t]*)"
    + ACCESS
    + r"(?P<indirect>indirect\s+)?enum\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*(?P<generic><[^{}]*?>)?"
    r"(?P<clause>[^{}]*?)"
    r"\{"
)

SENDABLE_WORD = re.compile(r"\bSendable\b")


def comment_line_flags(text: str) -> list[bool]:
    """逐行标出「本行起点位于注释内」，供跳过注释里的 struct 字样。"""
    flags = []
    in_block = False
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip()
        flags.append(in_block or stripped.startswith("//"))
        # 本行的块注释状态推进
        i = 0
        while i < len(line):
            if in_block:
                end = line.find("*/", i)
                if end == -1:
                    break
                in_block = False
                i = end + 2
            else:
                start = line.find("/*", i)
                line_comment = line.find("//", i)
                if start == -1 or (line_comment != -1 and line_comment < start):
                    break
                in_block = True
                i = start + 2
    return flags


def add_to_clause(clause: str) -> str | None:
    """返回重建后的继承子句；跨行的声明返回 None（由人工处理，不重排格式）。"""
    if "\n" in clause:
        return None
    body = clause.strip()
    if body in ("", ":"):
        return ": Sendable "
    if " where " in body:
        head, _, tail = body.partition(" where ")
        return head.rstrip().rstrip(",") + ", Sendable where " + tail.strip() + " "
    return body + ", Sendable "


def process(path: pathlib.Path, dry_run: bool, enums: bool) -> tuple[int, int, list[str]]:
    text = path.read_text(encoding="utf-8")
    flags = comment_line_flags(text)
    line_starts = [0]
    for line in text.splitlines(keepends=True):
        line_starts.append(line_starts[-1] + len(line))

    def line_of(offset: int) -> int:
        lo, hi = 0, len(line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo

    pattern = ENUM_DECL if enums else DECL
    kind_word = "enum" if enums else "struct"

    edits: list[tuple[int, int, str]] = []
    seen = 0
    already = 0
    reported: list[str] = []

    for m in pattern.finditer(text):
        if flags[line_of(m.start())]:
            continue
        seen += 1
        clause = m.group("clause")
        if SENDABLE_WORD.search(clause):
            already += 1
            continue
        new_clause = add_to_clause(clause)
        name = m.group("name")
        if new_clause is None:
            reported.append(
                f"{path}:{line_of(m.start()) + 1}: {kind_word} {name}（跨行声明，需人工加注）"
            )
            continue
        indirect = (m.group("indirect") or "") if enums else ""
        header = (
            f"{m.group('indent')}{m.group('access')}{indirect}{kind_word} {name}"
            f"{m.group('generic') or ''}{new_clause}{{"
        )
        edits.append((m.start(), m.end(), header))
        reported.append(f"{path}:{line_of(m.start()) + 1}: {kind_word} {name}")

    if edits and not dry_run:
        out = []
        cursor = 0
        for start, end, replacement in edits:
            out.append(text[cursor:start])
            out.append(replacement)
            cursor = end
        out.append(text[cursor:])
        path.write_text("".join(out), encoding="utf-8")

    return seen, already, reported


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", default=["Tests"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--enums", action="store_true", help="改注 enum（含 indirect enum）")
    args = parser.parse_args()

    targets: list[pathlib.Path] = []
    for raw in args.paths:
        p = pathlib.Path(raw)
        targets.extend(sorted(p.rglob("*.swift")) if p.is_dir() else [p])

    total_decls = total_already = 0
    changes: list[str] = []
    for path in targets:
        seen, already, reported = process(path, args.dry_run or args.check, args.enums)
        total_decls += seen
        total_already += already
        changes.extend(reported)

    kind = "enum" if args.enums else "struct"
    print(f"扫描 {len(targets)} 个文件 · {kind} 声明 {total_decls} 处 · 已遵循 {total_already} 处")
    for line in changes:
        print("  + " + line)
    print(f"待加注 {len(changes)} 处（{args.paths}）")

    if args.check:
        return 1 if changes else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

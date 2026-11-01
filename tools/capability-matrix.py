#!/usr/bin/env python3
"""Backend capability matrix — three states per family, kept in step with the code.

WHY THIS EXISTS
---------------
The matrix used to be prose in the plan and a hand-run sweep TSV. Both drifted the
moment a backend learned a family: the table said one thing, `BackendCapabilities`
said another, and nothing went red.

It now merges two sources that cannot lie about each other's half:

  * `pini backends --tsv` — what each channel *declares* (yes / no);
  * `tools/capability-census.py` — what each channel *accepts*, measured from the
    contract's node table and the backend's own `throw` sites.

A family declared `yes` but measured `none` (or the reverse) is a contradiction and
fails before the file is even read: that is the gap the old table could not see.

CELLS
    full          every node of the family is accepted
    partial a/b   a of b nodes accepted (the numerator is never typed by hand)
    none          no node of the family is accepted

The unit is the node kind. Operand-shaped limits (`binary` refusing bitwise ops)
do not move a family's state; the backend states them in its own reason strings.

USAGE
    python3 tools/capability-matrix.py              # check (default)
    python3 tools/capability-matrix.py --update     # rewrite the file
    PINI_BIN=/path/to/pini python3 tools/...        # non-default binary

EXIT
    0 clean · 1 drift or contradiction · 2 cannot run (no binary, bad census)
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MATRIX = os.path.join(ROOT, "docs/spec/capability-matrix.tsv")
CENSUS = os.path.join(ROOT, "tools/capability-census.py")
DEFAULT_BIN = os.path.join(ROOT, ".build/debug/pini")
PREAMBLE = [
    "# 三态：full = 本族节点全接；partial a/b = 接 a 个 / 共 b 个；none = 全拒。",
    "# 计量单位是节点种类；操作数形态的限制不计入，由后端写在自己的拒绝原因里。",
]


def binary():
    path = os.environ.get("PINI_BIN") or DEFAULT_BIN
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        print(f"能力矩阵：找不到可执行的 pini（{path}）。先 swift build，或设 PINI_BIN。", file=sys.stderr)
        sys.exit(2)
    return path


def declaration(path):
    """['family', 'llvm', …] + {(family, backend): 'yes'|'no'} from the CLI."""
    result = subprocess.run(
        [path, "backends", "--tsv"], cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print("能力矩阵：`pini backends --tsv` 失败，CLI 可能还没接这条命令。", file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)
        sys.exit(2)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    header = lines[0].split("\t")
    if header[0] != "family" or len(header) < 2:
        print(f"能力矩阵：表头不合约定：{lines[0]!r}", file=sys.stderr)
        sys.exit(2)
    for line in lines:
        if len(line.split("\t")) != len(header):
            print(f"能力矩阵：这一行列数不对：{line!r}", file=sys.stderr)
            sys.exit(2)
    rows = {line.split("\t")[0]: line.split("\t")[1:] for line in lines[1:]}
    return header, rows


def census():
    """{(backend, family): (accepted, total, level)} measured from source."""
    result = subprocess.run(
        [sys.executable, CENSUS], cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print("能力矩阵：普查取数失败。", file=sys.stderr)
        print((result.stderr or result.stdout).strip(), file=sys.stderr)
        sys.exit(2)
    measured = {}
    for index, line in enumerate(result.stdout.splitlines()):
        if index == 0:
            continue
        backend, family, total, _, accepted, level = line.split("\t")
        measured[(backend, family)] = (int(accepted), int(total), level)
    if not measured:
        print("能力矩阵：普查没有输出任何行。", file=sys.stderr)
        sys.exit(2)
    return measured


def cell(accepted, total, level):
    if level == "full":
        return "full"
    if level == "none":
        return "none"
    return f"partial {accepted}/{total}"


def contradictions(header, rows, measured):
    """声明与实测必须同向：yes 不能全族被拒，no 不能有节点被接受。"""
    problems = []
    for family in rows:
        if family == "output":
            continue
        for index, backend in enumerate(header[1:], start=1):
            flag = rows[family][index - 1]
            accepted, total, level = measured[(backend, family)]
            if flag == "yes" and level == "none":
                problems.append(f"{backend}/{family}：声明支持，实测 {total} 个节点全被拒")
            elif flag == "no" and level != "none":
                problems.append(f"{backend}/{family}：声明不支持，实测接受 {accepted}/{total}")
    return problems


def render(header, rows, measured):
    lines = list(PREAMBLE)
    lines.append("\t".join(header))
    for family in rows:
        if family == "output":
            lines.append("\t".join(["output"] + rows["output"]))
            continue
        cells = [family]
        for backend in header[1:]:
            cells.append(cell(*measured[(backend, family)]))
        lines.append("\t".join(cells))
    return "\n".join(lines) + "\n"


def self_test():
    """阳性对照：三态渲染与矛盾判定。干净仓库里这两条分支都不会被触发。"""
    problems = []

    def expect(label, condition):
        if not condition:
            problems.append(label)

    expect("full 渲染", cell(4, 4, "full") == "full")
    expect("none 渲染", cell(0, 8, "none") == "none")
    expect("partial 渲染带分式", cell(4, 7, "partial") == "partial 4/7")
    header = ["family", "llvm"]
    expect("声明 yes 而全拒未报矛盾",
           len(contradictions(header, {"calls": ["yes"]}, {("llvm", "calls"): (0, 7, "none")})) == 1)
    expect("声明 no 而有接受未报矛盾",
           len(contradictions(header, {"calls": ["no"]}, {("llvm", "calls"): (7, 7, "full")})) == 1)
    expect("声明 yes 且 partial 误报矛盾",
           contradictions(header, {"calls": ["yes"]}, {("llvm", "calls"): (4, 7, "partial")}) == [])
    for label in problems:
        print(f"  FAIL {label}", file=sys.stderr)
    print("能力矩阵自证通过" if not problems else f"能力矩阵自证失败 {len(problems)} 项", file=sys.stderr)
    return 0 if not problems else 1


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()
    update = "--update" in sys.argv[1:]
    header, rows = declaration(binary())
    measured = census()
    missing = [(backend, family) for family in rows if family != "output"
               for backend in header[1:] if (backend, family) not in measured]
    if missing:
        print(f"能力矩阵：普查缺 {missing[0][0]}/{missing[0][1]} 这一格。", file=sys.stderr)
        return 2
    problems = contradictions(header, rows, measured)
    if problems:
        print("能力矩阵：声明与实测相反，先对齐再谈这张表 ——", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        return 1
    rendered = render(header, rows, measured)
    if update:
        with open(MATRIX, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        print(f"能力矩阵已更新：{os.path.relpath(MATRIX, ROOT)}")
        return 0
    if not os.path.isfile(MATRIX):
        print(f"能力矩阵缺失：{os.path.relpath(MATRIX, ROOT)}。跑 --update 生成。", file=sys.stderr)
        return 1
    with open(MATRIX, encoding="utf-8") as handle:
        checked_in = handle.read()
    if checked_in.rstrip("\n") == rendered.rstrip("\n"):
        families = len([f for f in rows if f != "output"])
        channels = len(header) - 1
        print(f"能力矩阵一致：{families} 个族 / {channels} 条通道（三态，实测取数）")
        return 0
    print("能力矩阵与代码不符 —— 改了能力声明或拒绝面就要重生成这张表：", file=sys.stderr)
    print("    python3 tools/capability-matrix.py --update", file=sys.stderr)
    old = [line for line in checked_in.splitlines() if not line.startswith("#")]
    new = [line for line in rendered.splitlines() if not line.startswith("#")]
    if old == new:
        print("  （内容行一致，只有文件头注释不同）", file=sys.stderr)
        return 1
    for index in range(max(len(old), len(new))):
        a = old[index] if index < len(old) else "<缺行>"
        b = new[index] if index < len(new) else "<多行>"
        if a != b:
            print(f"  - {a}", file=sys.stderr)
            print(f"  + {b}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

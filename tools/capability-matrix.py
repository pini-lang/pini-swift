#!/usr/bin/env python3
"""Backend capability matrix — the live table, kept in step with the code.

WHY THIS EXISTS
---------------
The matrix used to be prose in the plan and a hand-run sweep TSV. Both drifted the
moment a backend learned a family: the table said one thing, `BackendCapabilities`
said another, and nothing went red. A table that is *typed in* is a claim nobody
verifies.

This script makes the CLI the single source: `pini backends --tsv` prints each
registered channel's own declaration, and the checked-in file is compared against
it. Changing a capability without updating the file fails CI; the failure message
says how to regenerate it.

USAGE
    python3 tools/capability-matrix.py              # check (default)
    python3 tools/capability-matrix.py --update     # rewrite the file
    PINI_BIN=/path/to/pini python3 tools/...        # non-default binary

EXIT
    0 clean · 1 drift · 2 cannot run (no binary, CLI missing the command)
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MATRIX = os.path.join(ROOT, "docs/spec/capability-matrix.tsv")
DEFAULT_BIN = os.path.join(ROOT, ".build/debug/pini")


def binary():
    path = os.environ.get("PINI_BIN") or DEFAULT_BIN
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        print(f"能力矩阵：找不到可执行的 pini（{path}）。先 swift build，或设 PINI_BIN。", file=sys.stderr)
        sys.exit(2)
    return path


def render(path):
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
    # 每行的列数必须与表头一致：少一列就说明某个通道没表态，而不是「默认不支持」。
    for line in lines:
        if len(line.split("\t")) != len(header):
            print(f"能力矩阵：这一行列数不对：{line!r}", file=sys.stderr)
            sys.exit(2)
    return "\n".join(lines) + "\n"


def main():
    update = "--update" in sys.argv[1:]
    rendered = render(binary())
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
        families = len(rendered.strip().splitlines()) - 2
        channels = len(rendered.splitlines()[0].split("\t")) - 1
        print(f"能力矩阵一致：{families} 个族 / {channels} 条通道")
        return 0
    print("能力矩阵与代码不符 —— 改了能力声明就要重生成这张表：", file=sys.stderr)
    print("    python3 tools/capability-matrix.py --update", file=sys.stderr)
    old = checked_in.splitlines()
    new = rendered.splitlines()
    for index in range(max(len(old), len(new))):
        a = old[index] if index < len(old) else "<缺行>"
        b = new[index] if index < len(new) else "<多行>"
        if a != b:
            print(f"  - {a}", file=sys.stderr)
            print(f"  + {b}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

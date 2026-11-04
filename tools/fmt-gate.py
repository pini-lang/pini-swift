#!/usr/bin/env python3
"""格式门禁：仓库内可解析的 .pini 必须已是规范形。

扫描 examples / Tests / bench。豁免逐行登记在 tools/fmt-exempt.tsv，分两类：
`unparseable` 是解析拒绝态夹具，没有规范形可打印；`variant` 是以非规范写法为被测对象的
语法标本，格式化会删掉被测量的写法。两类都显式列出而不是静默跳过，且都受检——
文件不存在、或豁免条件不再成立，都算过期，门禁失败。

退出码 0 通过，1 有文件不合规或豁免过期，2 环境不满足（缺产物、产物早于源码）。
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN_ROOTS = ("examples", "Tests", "bench")
EXEMPT = os.path.join(ROOT, "tools/fmt-exempt.tsv")
DEFAULT_BIN = os.path.join(ROOT, ".build/debug/pini")
KINDS = {"unparseable", "variant"}


def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def indent(lines):
    return "\n".join("    " + line for line in lines)


def binary():
    """可执行产物，且不早于源码：旧产物会把新打印器的判据读成绿。"""
    path = os.environ.get("PINI_BIN") or DEFAULT_BIN
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        fail(f"格式门禁：找不到可执行的 pini（{path}）。先 swift build，或设 PINI_BIN。", 2)
    newest_source = os.path.getmtime(os.path.join(ROOT, "Package.swift"))
    for base, _, files in os.walk(os.path.join(ROOT, "Sources")):
        for name in files:
            if name.endswith(".swift"):
                newest_source = max(newest_source, os.path.getmtime(os.path.join(base, name)))
    if newest_source > os.path.getmtime(path):
        fail("格式门禁：二进制早于源码，读数不算数。先 swift build，再跑本门禁。", 2)
    return path


def collect():
    """三个扫描根下的全部 .pini，仓库相对路径，排序后返回。"""
    files = []
    for root in SCAN_ROOTS:
        base = os.path.join(ROOT, root)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != ".build")
            for name in sorted(filenames):
                if name.endswith(".pini"):
                    files.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
    return sorted(files)


def read_exempt():
    """豁免表：每行「路径<TAB>类别<TAB>原因」；空行与 # 开头的行不算条目。"""
    entries = []
    with open(EXEMPT, encoding="utf-8-sig") as handle:
        for number, line in enumerate(handle, 1):
            text = line.rstrip("\n")
            if not text.strip() or text.lstrip().startswith("#"):
                continue
            parts = [part.strip() for part in text.split("\t")]
            if len(parts) != 3 or not all(parts):
                fail(f"格式门禁：{EXEMPT}:{number} 不是「路径<TAB>类别<TAB>原因」三列：{text!r}")
            if parts[1] not in KINDS:
                fail(f"格式门禁：{EXEMPT}:{number} 的类别须是 {sorted(KINDS)}：{parts[1]!r}")
            entries.append((parts[0], parts[1], parts[2]))
    return entries


def check(path, cli):
    """单文件的 fmt --check 结果：(退出码, 是否列出为待格式化)。"""
    result = subprocess.run(
        [cli, "fmt", "--check", path], cwd=ROOT, capture_output=True, text=True)
    return result.returncode, bool(result.stdout.strip())


def main():
    cli = binary()
    files = collect()
    if not files:
        fail("格式门禁：扫描根下没有 .pini，判据没生效，按失败处理。")

    exempt = read_exempt()
    present = set(files)
    problems = []
    for path, kind, _ in exempt:
        if path not in present:
            problems.append(f"豁免指向不存在或不在扫描范围内的文件：{path}")
            continue
        status, dirty = check(path, cli)
        if kind == "unparseable" and not (status != 0 and not dirty):
            problems.append(f"豁免已失效（该文件能解析，应当格式化）：{path}")
        if kind == "variant" and not (status != 0 and dirty):
            problems.append(f"豁免已失效（该文件已是规范形，不再是被测写法）：{path}")
    if problems:
        fail("格式门禁：豁免表有问题，先修 tools/fmt-exempt.tsv\n" + indent(problems))

    exempt_paths = {path for path, _, _ in exempt}
    checked = [path for path in files if path not in exempt_paths]
    result = subprocess.run(
        [cli, "fmt", "--check", *checked], cwd=ROOT, capture_output=True, text=True)
    dirty = [line for line in result.stdout.splitlines() if line.strip()]
    parse_errors = result.stderr.strip()

    if parse_errors or dirty:
        print(f"格式门禁：{len(files)} 个 .pini · 豁免 {len(exempt)}")
        if parse_errors:
            print("  以下文件解析失败。解析失败不等于通过，也不许加进豁免表：")
            print(indent(parse_errors.splitlines()))
        if dirty:
            print(f"  {len(dirty)} 个不是规范形：")
            print(indent(dirty))
            print("  跑 `pini fmt -w <路径>` 修正；只有拒绝态夹具与语法标本才配进豁免表。")
        sys.exit(1)

    if result.returncode != 0:
        fail(f"格式门禁：pini fmt 异常退出（{result.returncode}），未给出可读原因。")

    print(f"格式门禁：{len(checked)} 个 .pini 已是规范形 · 豁免 {len(exempt)}（拒绝态与语法标本）")


if __name__ == "__main__":
    main()

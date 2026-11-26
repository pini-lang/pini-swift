#!/usr/bin/env python3
"""测试分片门禁：每个带 `[[test]]` 的成员包恰好落在一片上，片与整片工作区同源。

WHY THIS EXISTS
---------------
测试按包分片跑之后，覆盖率不再由「一条命令跑完整片工作区」保证，而是由分片表保证。
表里漏一个包，那包的用例从此无人执行，报告仍然全绿；同一包写进两片，用例跑两遍，
墙钟白花。两种错都不会让构建失败，只有对账能发现。

对账基准是 `bootstrap/pini.toml` 的 members：包名取各成员 `[package]` 的 name，
与目录名不必相同（目录 `module-loader` 的包名是 `module_loader`）。
"""
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "bootstrap" / "pini.toml"
SHARDS = ROOT / "bootstrap" / "tools" / "test-shards.tsv"


def members(path):
    """成员表：[(目录, 包名, 是否声明 [[test]])]，按清单书写顺序。"""
    text = path.read_text(encoding="utf-8")
    match = re.search(r"members\s*=\s*\[(.*?)\]", text, re.S)
    if not match:
        raise ValueError("工作区清单里没有 members 表：%s" % path)
    table = []
    for rel in re.findall(r'"([^"]+)"', match.group(1)):
        manifest = path.parent / rel / "pini.toml"
        if not manifest.is_file():
            raise ValueError("成员目录里没有 pini.toml：%s" % rel)
        body = manifest.read_text(encoding="utf-8")
        named = re.search(r'\[package\][^[]*?\bname\s*=\s*"([^"]+)"', body, re.S)
        table.append((rel, named.group(1) if named else None, "[[test]]" in body))
    return table


def rows(path):
    """分片表：[(分片, 包, 说明)]，空行与 # 开头的行不算条目。"""
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError("分片表带 UTF-8 BOM：shell 按列切会把 BOM 算进第一列，首行成了片名")
    out = []
    for number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        text = line.rstrip()
        if not text.strip() or text.lstrip().startswith("#"):
            continue
        parts = [part.strip() for part in text.split("\t")]
        if len(parts) != 3 or not all(parts):
            raise ValueError(
                "%s:%d 不是「分片<TAB>包<TAB>说明」三列：%r" % (path.name, number, text))
        out.append(tuple(parts))
    return out


def verify(members_table, shard_rows):
    """对账：返回 (问题清单, 包名→有无测试, 包名→分片)。"""
    problems = []
    known = {}
    for rel, name, has_tests in members_table:
        if name is None:
            problems.append("成员 %s 读不出 [package] name" % rel)
            continue
        known[name] = has_tests
    seen = {}
    for shard, package, _ in shard_rows:
        if package not in known:
            problems.append("分片 %s 指向的包 %s 不是工作区成员" % (shard, package))
            continue
        if not known[package]:
            problems.append("分片 %s 指向的包 %s 没有 [[test]] target" % (shard, package))
        if package in seen:
            problems.append("包 %s 同时落在分片 %s 与 %s" % (package, seen[package], shard))
            continue
        seen[package] = shard
    for name in sorted(name for name, has in known.items() if has):
        if name not in seen:
            problems.append("包 %s 没有分片，它的用例不会被执行" % name)
    return problems, known, seen


def self_test():
    """两条判据都要开火：漏包与重包各造一次，再对一次齐。"""
    with_tests = [("packages/a", "a", True)]
    cases = [
        ("漏包", [("packages/a", "a", True), ("packages/b", "b", True)],
         [("甲", "a", "x")], 1),
        ("重包", with_tests, [("甲", "a", "x"), ("乙", "a", "y")], 1),
        ("指向无测试的包", [("packages/a", "a", True), ("packages/b", "b", False)],
         [("甲", "a", "x"), ("乙", "b", "y")], 1),
        ("对齐", with_tests, [("甲", "a", "x")], 0),
    ]
    for label, table, shard_rows, want in cases:
        problems, _, _ = verify(table, shard_rows)
        got = 1 if problems else 0
        if got != want:
            print("self-test FAIL：%s 期望 %d，实得 %d" % (label, want, got))
            return 1
    # BOM 是真实踩过的坑：带 BOM 的表被 shell 读成「首行即片名」，多出一片跑完整套。
    with tempfile.TemporaryDirectory() as tmp:
        spoiled = Path(tmp) / "shards.tsv"
        spoiled.write_bytes(b"\xef\xbb\xbf" + "# 注释\n".encode("utf-8"))
        try:
            rows(spoiled)
        except ValueError:
            pass
        else:
            print("self-test FAIL：带 BOM 的分片表没被拒")
            return 1
    print("self-test PASS")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    try:
        table = members(WORKSPACE)
        shard_rows = rows(SHARDS)
    except (OSError, ValueError) as error:
        print("分片门禁：%s" % error, file=sys.stderr)
        return 2
    problems, known, seen = verify(table, shard_rows)
    if not problems:
        shards = sorted({shard for shard, _, _ in shard_rows})
        print("测试分片：%d 片 · %d 个测试包 / 工作区 %d 个成员"
              % (len(shards), len(seen), len(known)))
    for line in problems:
        print("FAIL: %s" % line)
    if problems:
        print("\n%d 处分片问题" % len(problems))
        return 1
    print("test shard check: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

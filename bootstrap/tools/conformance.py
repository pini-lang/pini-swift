#!/usr/bin/env python3
"""验收语料门禁：逐例驱动宿主与自举两条通道，按规范期望比对，差异由基线棘轮记账。

期望写在每例的 case.toml 里，来源是规范而不是任何一侧的输出；基线只记「某一侧当前
还不同意规范」的现状，条目只许缩小 —— 某条转为一致时这一步会红，提示删掉它。
用法：python3 bootstrap/tools/conformance.py [--list] [--filter 文本] [--update-baseline]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
CASES = ROOT / "bootstrap" / "tests" / "conformance" / "cases"
BASELINE = ROOT / "bootstrap" / "tests" / "conformance" / "divergence-baseline.tsv"
WORK = ROOT / "bootstrap" / ".build" / "tests" / "conformance"

CATEGORIES = {
    "legal", "illegal", "unicode", "path", "diagnostics",
    "package", "cinterop", "determinism",
}
KINDS = {"error", "pass", "reject", "stable"}
REQUIRED = ("name", "category", "kind", "spec")
TIMEOUT = 180


class CorpusError(Exception):
    """语料自身写错：缺字段、类别未知、重名。"""


def fail(message):
    print(f" 行不通  [语料] {message}", file=sys.stderr)


def load_cases():
    if not CASES.is_dir():
        raise CorpusError(f"缺语料目录 {CASES}")
    cases = []
    seen = {}
    for entry in sorted(CASES.iterdir()):
        if not entry.is_dir():
            continue
        manifest = entry / "case.toml"
        if not manifest.is_file():
            raise CorpusError(f"{entry.name} 缺 case.toml")
        with manifest.open("rb") as handle:
            document = tomllib.load(handle)
        table = document.get("case")
        if not isinstance(table, dict):
            raise CorpusError(f"{entry.name} 缺 [case] 表")
        for key in REQUIRED:
            if not table.get(key):
                raise CorpusError(f"{entry.name} 缺字段 {key}")
        if table["category"] not in CATEGORIES:
            raise CorpusError(f"{entry.name} 类别未知：{table['category']}")
        if table["kind"] not in KINDS:
            raise CorpusError(f"{entry.name} 类型未知：{table['kind']}")
        if table["kind"] == "error" and ("code" not in table or "line" not in table or "col" not in table):
            raise CorpusError(f"{entry.name} 反例必须给 code / line / col")
        if table["kind"] == "stable" and table.get("probe", "check") not in ("check", "test"):
            raise CorpusError(f"{entry.name} probe 只能是 check 或 test")
        if table["name"] in seen:
            raise CorpusError(f"{entry.name} 与 {seen[table['name']]} 同名：{table['name']}")
        seen[table["name"]] = entry.name
        table["slug"] = entry.name
        table["dir"] = entry
        cases.append(table)
    return cases


def host_binary():
    path = Path(os.environ.get("PINI_HOST_BIN") or (ROOT / ".build" / "release" / "pini"))
    if not path.is_file() or not os.access(path, os.X_OK):
        fail(f"缺宿主可执行文件 {path}；先 swift build")
        sys.exit(2)
    return path


def bootstrap_binary():
    path = Path(
        os.environ.get("PINI_BOOTSTRAP_BIN")
        or (ROOT / "bootstrap" / ".build" / "release" / "bin" / "pini-bootstrap")
    )
    if not path.is_file() or not os.access(path, os.X_OK):
        fail(f"缺自举产物 {path}；先 bash bootstrap/tools/build.sh")
        sys.exit(2)
    return path


def prepare(case):
    dest = WORK / case["slug"]
    if dest.exists():
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(case["dir"], dest)
    return dest


def run(command, cwd, env=None):
    merged = dict(os.environ)
    if env:
        merged.update(env)
    try:
        done = subprocess.run(
            command, cwd=str(cwd), env=merged, capture_output=True, text=True, timeout=TIMEOUT
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"超过 {TIMEOUT} 秒"
    return done.returncode, done.stdout, done.stderr


def normalize_rows(stdout, root):
    """取结构化诊断行；路径按用例根归一，两侧才可比。"""
    rows = []
    prefix = str(root) + "/"
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 7:
            continue
        path = parts[0].replace(prefix, "")
        if path.startswith("./"):
            path = path[2:]
        rows.append((path, int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]), parts[5], parts[6]))
    return rows


def first_row(rows):
    return rows[0] if rows else None


def describe(row):
    if row is None:
        return "无诊断"
    return f"{row[6]}@{row[1]}:{row[2]}"


def compare_error(case, root, host, boot):
    """反例：两条通道各取首条诊断，与规范期望比。"""
    deviations = {}
    host_entry = case.get("host", "check")
    host_path = root if host_entry == "build" else root / "pkg"
    code, out, err = run([str(host), host_entry, str(host_path), "--diagnostics-tsv"], root)
    host_row = first_row(normalize_rows(out, root))
    expected = (case["code"], int(case["line"]), int(case["col"]))
    if host_row is None:
        deviations["host"] = f"exit={code}|无诊断"
    elif (host_row[6], host_row[1], host_row[2]) != expected:
        deviations["host"] = f"{host_row[6]}\t{host_row[1]}\t{host_row[2]}"

    code, out, err = run([str(boot), "check", str(root), "--diagnostics-tsv"], root)
    boot_row = first_row(normalize_rows(out, root))
    if boot_row is None:
        deviations["bootstrap"] = f"exit={code}|无诊断"
    elif (boot_row[6], boot_row[1], boot_row[2]) != expected:
        deviations["bootstrap"] = f"{boot_row[6]}\t{boot_row[1]}\t{boot_row[2]}"
    return deviations, f"期望 {expected[0]}@{expected[1]}:{expected[2]}"


def stage_of(output, err):
    """失败摘要取阶段名，不取整行：整行带路径会随工作目录变，基线才对得上。"""
    lines = (output.strip().splitlines() or err.strip().splitlines() or ["无输出"])
    tail = lines[-1]
    if "[测试]" in tail:
        return tail.split("[测试]")[-1].strip().split("；")[0]
    return tail


def compare_pass(case, root, host, boot):
    """正例：两条通道各跑测试，必须全过。"""
    deviations = {}
    code, out, err = run([str(host), "test", str(root)], root)
    if code != 0:
        deviations["host"] = f"exit={code}|{stage_of(out, err)}"

    env = {"PINI_BOOTSTRAP_BIN": str(boot)}
    code, out, err = run(["bash", str(ROOT / "bootstrap" / "tools" / "test.sh"), str(root)], root, env)
    if code != 0:
        deviations["bootstrap"] = f"exit={code}|{stage_of(out, err)}"
    return deviations, "两条通道测试全过"


TIMING = re.compile(r"（[0-9.]+ 秒）")


def mask_timing(result):
    """报告末尾的耗时是读数，不是内容；比对前抹掉，否则同一输入必然不同。"""
    code, out, err = result
    return code, TIMING.sub("（用时）", out), TIMING.sub("（用时）", err)


def compare_stable(case, root, host, boot):
    """确定性：同一通道连跑两次，输出逐字节相同（耗时读数除外）。"""
    probe = case.get("probe", "check")
    deviations = {}
    if probe == "check":
        commands = {"host": [str(host), "check", str(root / "pkg")], "bootstrap": [str(boot), "check", str(root)]}
    else:
        commands = {"host": [str(host), "test", str(root)], "bootstrap": ["bash", str(ROOT / "bootstrap" / "tools" / "test.sh"), str(root)]}
    for channel, command in commands.items():
        env = {"PINI_BOOTSTRAP_BIN": str(boot)} if channel == "bootstrap" else None
        one = mask_timing(run(command, root, env))
        two = mask_timing(run(command, root, env))
        if one != two:
            deviations[channel] = "两次输出不同"
    return deviations, "同一输入两次输出相同"


def compare_reject(case, root, host, boot):
    """拒绝类：两条通道都必须非零退出；不钉码与位置（清单与依赖图错误各有专用措辞）。"""
    deviations = {}
    host_entry = case.get("host", "check")
    host_path = root if host_entry == "build" else root / "pkg"
    code, out, err = run([str(host), host_entry, str(host_path)], root)
    if code == 0:
        deviations["host"] = "exit=0"
    code, out, err = run([str(boot), "check", str(root)], root)
    if code == 0:
        deviations["bootstrap"] = "exit=0"
    return deviations, "两条通道都必须拒绝"


COMPARERS = {"error": compare_error, "pass": compare_pass, "reject": compare_reject, "stable": compare_stable}


def load_baseline():
    if not BASELINE.is_file():
        return {}
    entries = {}
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        entries[(parts[0], parts[1])] = parts[2]
    return entries


def write_baseline(entries):
    lines = [
        "# 跨通道差异基线：用例 slug、通道、实测值。只许缩小；某条转为一致时门禁会红，提示删掉它。",
        "# 值是制表符分隔的「码 行 列」或「exit=码|末行摘要」；新差异必须先把原因写进计划件再登记。",
    ]
    for (slug, channel), value in sorted(entries.items()):
        lines.append(f"{slug}\t{channel}\t{value}")
    BASELINE.parent.mkdir(parents=True, exist_ok=True)
    BASELINE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="验收语料门禁")
    parser.add_argument("--list", action="store_true", help="只列用例")
    parser.add_argument("--filter", default="", help="按用例名或 slug 过滤")
    parser.add_argument("--update-baseline", action="store_true", help="把当前差异写回基线")
    parser.add_argument("--verbose", action="store_true", help="逐例打印")
    options = parser.parse_args()

    try:
        cases = load_cases()
    except CorpusError as error:
        fail(str(error))
        return 2

    if options.filter:
        cases = [c for c in cases if options.filter in c["name"] or options.filter in c["slug"]]
    if not cases:
        fail("筛选零命中")
        return 2
    if options.list:
        for case in cases:
            print(f"{case['slug']}\t{case['category']}\t{case['kind']}\t{case['name']}")
        return 0

    host = host_binary()
    boot = bootstrap_binary()
    baseline = load_baseline()
    fresh = {}
    used = set()
    failures = []
    passed = 0

    for case in cases:
        root = prepare(case)
        deviations, expectation = COMPARERS[case["kind"]](case, root, host, boot)
        case_failed = False
        for channel, actual in deviations.items():
            key = (case["slug"], channel)
            if key in baseline:
                used.add(key)
                if baseline[key] != actual:
                    failures.append(f"{case['slug']} / {channel}：基线与实测不符（基线 {baseline[key]}，实测 {actual}）")
                    case_failed = True
            else:
                fresh[key] = actual
                failures.append(f"{case['slug']} / {channel}：{expectation}，实得 {actual}")
                case_failed = True
        if not case_failed:
            passed += 1
        if options.verbose or case_failed:
            print(f"{'✗' if case_failed else '·'} {case['slug']} [{case['category']}/{case['kind']}] {case['name']}")

    if options.update_baseline:
        merged = dict(baseline)
        merged.update(fresh)
        write_baseline(merged)
        print(f"基线已更新：{len(merged)} 条（本次新增 {len(fresh)} 条）")
        return 0

    stale = [key for key in baseline if key not in used and not options.filter]
    for slug, channel in sorted(stale):
        failures.append(f"{slug} / {channel}：基线条目已不再出现（已一致或已改名），删掉这一行")

    total = len(cases)
    print(f"语料 {total} 例：通过 {passed}，失败 {total - passed}；基线 {len(baseline)} 条，本次命中 {len(used)} 条")
    if failures:
        for line in failures:
            print(f"  ✗ {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

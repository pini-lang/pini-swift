#!/usr/bin/env python3
"""The example gate: check / run / run-llvm / golden over examples/.

Known failures live in examples/gate-baseline.tsv. A listed failure is counted
as known, never as pass; a listed entry that turns green fails the gate, so the
baseline can only shrink. An unlisted failure is a regression.

The golden leg compares `run` stdout against examples/golden/<example>.out
byte for byte. Examples that cannot be compared that way are listed with a
reason in examples/golden/EXEMPT.tsv; everything else must carry a golden file.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLES = os.path.join(ROOT, "examples")
BASELINE = os.path.join(EXAMPLES, "gate-baseline.tsv")
GOLDEN = os.path.join(EXAMPLES, "golden")
EXEMPT = os.path.join(GOLDEN, "EXEMPT.tsv")
LEGS = ("check", "run", "run-llvm", "golden")
DEFAULT_BIN = os.path.join(ROOT, ".build/debug/pini")
TIMEOUT = 60


def binary():
    path = os.environ.get("PINI_BIN") or DEFAULT_BIN
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        print(f"示例门禁：找不到可执行的 pini（{path}）。先 swift build，或设 PINI_BIN。", file=sys.stderr)
        sys.exit(2)
    return path


def llvm_bin_directory():
    """The LLVM bin directory the CLI would itself pick, so the gate and the child agree.

    Mirrors Sources/PiniBackendLLVM/CodeGen/LLVMToolchain.swift: env var, llvm-config,
    PATH, then the two Homebrew prefixes. Resolving twice by different rules would let
    the gate report a skip while `pini run-llvm` works, or run a leg the CLI cannot.
    """
    candidates = []
    explicit = os.environ.get("PINI_LLVM_BIN", "")
    if explicit:
        candidates.append(explicit)
    try:
        found = subprocess.run(
            ["llvm-config", "--bindir"], capture_output=True, text=True, timeout=10)
        if found.returncode == 0 and found.stdout.strip():
            candidates.append(found.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    candidates += [entry for entry in os.environ.get("PATH", "").split(os.pathsep) if entry]
    candidates += ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]
    for directory in candidates:
        if os.access(os.path.join(directory, "lli"), os.X_OK):
            return directory
    return None


def entries():
    """Top-level .pini files plus directories carrying a pini.toml."""
    found = []
    for name in sorted(os.listdir(EXAMPLES)):
        path = os.path.join(EXAMPLES, name)
        if name.endswith(".pini") and os.path.isfile(path):
            found.append((name, name, False))
        elif os.path.isdir(path) and os.path.isfile(os.path.join(path, "pini.toml")):
            found.append((name, name, True))
    return found


def load_baseline(labels, packages):
    """Return {(entry, leg): reason}; refuse entries or legs the gate never runs."""
    if not os.path.isfile(BASELINE):
        print(f"示例门禁：基线缺失（{os.path.relpath(BASELINE, ROOT)}）。", file=sys.stderr)
        sys.exit(2)
    known, problems = {}, []
    with open(BASELINE, encoding="utf-8-sig") as handle:
        for number, line in enumerate(handle, 1):
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            parts = text.split("\t")
            if len(parts) != 3:
                problems.append(f"第 {number} 行不是三列：{line.rstrip()!r}")
                continue
            entry, leg, reason = parts
            if entry not in labels:
                problems.append(f"第 {number} 行的条目不存在：{entry}")
            if leg not in LEGS:
                problems.append(f"第 {number} 行的腿不认识：{leg}")
            if entry in packages and leg != "check":
                problems.append(f"第 {number} 行：包只跑 check，不跑 {leg}")
            if (entry, leg) in known:
                problems.append(f"第 {number} 行重复登记：{entry} / {leg}")
            known[(entry, leg)] = reason
    if problems:
        print("示例门禁：基线不合法 ——", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        sys.exit(2)
    return known


def execute(argv, cwd, env):
    try:
        result = subprocess.run(
            argv, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=TIMEOUT, env=env)
        detail = (result.stderr or result.stdout).strip().splitlines()
        return result.returncode == 0, detail[0] if detail else "", result.stdout
    except subprocess.TimeoutExpired:
        return False, f"超时（>{TIMEOUT}s）", ""


def load_golden():
    """{label: path} for every golden file; a name without an example is caught in main."""
    if not os.path.isdir(GOLDEN):
        return {}
    return {name[:-4]: os.path.join(GOLDEN, name)
            for name in sorted(os.listdir(GOLDEN)) if name.endswith(".out")}


def load_exempt(labels):
    """{label: reason}; every line must name an existing example."""
    if not os.path.isfile(EXEMPT):
        return {}
    exempt, problems = {}, []
    with open(EXEMPT, encoding="utf-8-sig") as handle:
        for number, line in enumerate(handle, 1):
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            parts = text.split("\t")
            if len(parts) != 2:
                problems.append(f"第 {number} 行不是两列：{line.rstrip()!r}")
                continue
            label, reason = parts
            if label not in labels:
                problems.append(f"第 {number} 行的条目不存在：{label}")
            if label in exempt:
                problems.append(f"第 {number} 行重复登记：{label}")
            exempt[label] = reason
    if problems:
        print("示例门禁：豁免表不合法 ——", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        sys.exit(2)
    return exempt


def first_diff(expected, actual):
    """Point at the first differing line; fall back to a trailing-newline note."""
    want, got = expected.splitlines(), actual.splitlines()
    for index in range(max(len(want), len(got))):
        expected_line = want[index] if index < len(want) else "<期望文件结束>"
        actual_line = got[index] if index < len(got) else "<输出结束>"
        if expected_line != actual_line:
            return f"第 {index + 1} 行：期望 {expected_line!r}，实际 {actual_line!r}"
    return "行内容一致，但末尾换行不同"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--legs", default=",".join(LEGS),
                        help="逗号分隔：check,run,run-llvm,golden")
    parser.add_argument("--quiet", action="store_true", help="只打印失败与读数")
    args = parser.parse_args()
    legs = [leg.strip() for leg in args.legs.split(",") if leg.strip()]
    for leg in legs:
        if leg not in LEGS:
            print(f"示例门禁：不认识的腿 {leg}", file=sys.stderr)
            return 2

    path = binary()
    llvm = llvm_bin_directory()
    child_env = dict(os.environ)
    if llvm:
        child_env["PINI_LLVM_BIN"] = llvm
    found = entries()
    labels = {label for label, _, _ in found}
    packages = {label for label, _, is_package in found if is_package}
    known = load_baseline(labels, packages)
    golden = load_golden()
    exempt = load_exempt(labels)

    config = []
    for label in golden:
        if label not in labels:
            config.append(f"golden 文件没有对应示例：{label}.out")
        elif label in packages:
            config.append(f"包只跑 check，不该有 golden：{label}")
        elif label in exempt:
            config.append(f"同时有 golden 与豁免：{label}")
    config += [f"没有 golden 也不在豁免表：{label}"
               for label, _, is_package in found
               if not is_package and label not in golden and label not in exempt]
    if config:
        print("示例门禁：黄金输出配置不合法 ——", file=sys.stderr)
        for problem in config:
            print("  " + problem, file=sys.stderr)
        return 2

    scratch = tempfile.mkdtemp(prefix="pini-examples-gate-")
    try:
        shutil.copytree(EXAMPLES, os.path.join(scratch, "examples"), symlinks=True)
        if not args.quiet:
            print(f"示例门禁：{sum(1 for _, _, p in found if not p)} 个文件 + "
                  f"{sum(1 for _, _, p in found if p)} 个包")
        regression, stale = [], []
        for leg in legs:
            if leg == "run-llvm" and llvm is None:
                reason = "找不到 lli：环境变量 / llvm-config / PATH / Homebrew 前缀都没有"
                if os.environ.get("PINI_REQUIRE_TOOLCHAIN") == "1":
                    print(f"示例门禁：PINI_REQUIRE_TOOLCHAIN=1，{reason}", file=sys.stderr)
                    return 2
                print(f"  {leg:<10} 跳过（{reason}）")
                continue
            if leg == "golden":
                passed, diffs = 0, []
                for label, golden_path in golden.items():
                    ok, detail, out = execute([path, "run", f"examples/{label}"], scratch, child_env)
                    if not ok:
                        diffs.append((label, f"运行失败：{detail}"))
                        continue
                    with open(golden_path, encoding="utf-8") as handle:
                        expected = handle.read()
                    if out == expected:
                        passed += 1
                    else:
                        diffs.append((label, first_diff(expected, out)))
                print(f"  {leg:<10} 通过 {passed} · 豁免 {len(exempt)} · 差异 {len(diffs)}")
                if not args.quiet:
                    for label, detail in diffs:
                        print(f"    FAIL  {label:<40} {detail}")
                if diffs:
                    print(f"示例门禁：黄金输出差异 {len(diffs)}", file=sys.stderr)
                    return 1
                continue
            passed = 0
            failures = {}
            for label, _, is_package in found:
                if is_package and leg != "check":
                    continue
                ok, detail, _ = execute([path, leg, f"examples/{label}"], scratch, child_env)
                if ok:
                    passed += 1
                    if (label, leg) in known:
                        stale.append((label, leg))
                else:
                    failures[label] = detail
                    if (label, leg) not in known:
                        regression.append((label, leg, detail))
            known_count = sum(
                1 for (label, kleg) in known if kleg == leg and label in failures)
            print(f"  {leg:<10} 通过 {passed} · 已知失败 {known_count} · 回归 "
                  f"{sum(1 for r in regression if r[1] == leg)}")
            if not args.quiet:
                for label, detail in failures.items():
                    marker = "KNOWN" if (label, leg) in known else "FAIL "
                    reason = known.get((label, leg), detail)
                    print(f"    {marker} {label:<40} {reason}")

        for label, leg in stale:
            print(f"STALE  {label} / {leg} 已变绿 —— 从基线删掉这一行，让判据接手。", file=sys.stderr)
        for label, leg, detail in regression:
            print(f"FAIL   {label} / {leg} 未登记为已知失败：{detail}", file=sys.stderr)

        if regression or stale:
            print(f"示例门禁：回归 {len(regression)} · 基线过期 {len(stale)}", file=sys.stderr)
            return 1
        print("示例门禁：无回归")
        return 0
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

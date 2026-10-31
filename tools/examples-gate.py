#!/usr/bin/env python3
"""The example gate: check / run / run-llvm over examples/.

Known failures live in examples/gate-baseline.tsv. A listed failure is counted
as known, never as pass; a listed entry that turns green fails the gate, so the
baseline can only shrink. An unlisted failure is a regression.
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
LEGS = ("check", "run", "run-llvm")
DEFAULT_BIN = os.path.join(ROOT, ".build/debug/pini")
TIMEOUT = 60


def binary():
    path = os.environ.get("PINI_BIN") or DEFAULT_BIN
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        print(f"示例门禁：找不到可执行的 pini（{path}）。先 swift build，或设 PINI_BIN。", file=sys.stderr)
        sys.exit(2)
    return path


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


def execute(argv, cwd):
    try:
        result = subprocess.run(
            argv, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=TIMEOUT)
        detail = (result.stderr or result.stdout).strip().splitlines()
        return result.returncode == 0, detail[0] if detail else ""
    except subprocess.TimeoutExpired:
        return False, f"超时（>{TIMEOUT}s）"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--legs", default=",".join(LEGS), help="逗号分隔：check,run,run-llvm")
    parser.add_argument("--quiet", action="store_true", help="只打印失败与读数")
    args = parser.parse_args()
    legs = [leg.strip() for leg in args.legs.split(",") if leg.strip()]
    for leg in legs:
        if leg not in LEGS:
            print(f"示例门禁：不认识的腿 {leg}", file=sys.stderr)
            return 2

    path = binary()
    found = entries()
    labels = {label for label, _, _ in found}
    packages = {label for label, _, is_package in found if is_package}
    known = load_baseline(labels, packages)

    scratch = tempfile.mkdtemp(prefix="pini-examples-gate-")
    try:
        shutil.copytree(EXAMPLES, os.path.join(scratch, "examples"), symlinks=True)
        if not args.quiet:
            print(f"示例门禁：{sum(1 for _, _, p in found if not p)} 个文件 + "
                  f"{sum(1 for _, _, p in found if p)} 个包")
        regression, stale = [], []
        for leg in legs:
            if leg == "run-llvm" and not os.environ.get("PINI_LLVM_BIN"):
                print(f"  {leg:<10} 跳过（未配置 PINI_LLVM_BIN）")
                continue
            passed = 0
            failures = {}
            for label, _, is_package in found:
                if is_package and leg != "check":
                    continue
                ok, detail = execute([path, leg, f"examples/{label}"], scratch)
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

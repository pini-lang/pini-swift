#!/usr/bin/env python3
"""Check that a backend does not decide ownership on its own.

WHY THIS EXISTS
---------------
`docs/spec/ir-contract.md` section 5 says ownership actions are inserted upstream
and a backend only translates them. That claim is worth something only if the day
it stops being true is visible. This is the warning-level half: it names the
functions in the emitter that decide *when* to retain or release, so the list can
be watched down to zero while the ownership pass lands.

WARNING LEVEL, ON PURPOSE
-------------------------
The pass does not exist yet, so every run finds something. The script exits 0
unless --strict is passed; wiring it into CI now buys a starting reading rather
than a red build. A check that blocks on its first day gets switched off on its
second.

WHAT IS NOT CHECKED
-------------------
Translation is allowed: calling a release symbol because the IR said so is the
backend's job, and those helpers stay. Only the decision family is listed -- the
functions that choose the moment. A rename could dodge this script; that is why
the list is named in the contract's vocabulary, not by code shape.

Usage:
    python3 tools/backend-duty-check.py
    python3 tools/backend-duty-check.py --strict     # exit 1 on findings
    python3 tools/backend-duty-check.py --self-test  # prove it can fire
"""

import os
import re
import sys

ROOT = os.environ.get(
    "BACKEND_DUTY_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)

EMITTER = "Sources/PiniCore/CodeGen/IREmitter.swift"

# 决策族：它们回答「此刻要不要 retain / release」。归位之后这些判断属于中端，
# 后端只剩翻译。名字取自契约第 5 节的口径，不按代码形状匹。
DECISION_SITES = [
    "pendingReleases",
    "emitReleases",
    "emitReassignRelease",
    "emitFieldReassignRelease",
    "emitRetainIfAliased",
    "releaseOwnedString",
    "releaseOwnedTemporary",
    "releaseCallArguments",
    "retainIfOwningContainer",
    "ensureReleaseFunction",
    "registerReleasedHandle",
]


def scan(text, symbols):
    """Return {symbol: hits} for symbols present at least once."""
    found = {}
    for sym in symbols:
        n = len(re.findall(r"\b%s\b" % re.escape(sym), text))
        if n:
            found[sym] = n
    return found


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def self_test():
    """The detector must fire on a planted hit and stay silent on a translation."""
    planted = "private var pendingReleases: [[ReleasedHandle]] = []\n"
    translation = "private func releaseSymbol(for type: IRType) -> String? {}\n"
    ok = True
    if scan(planted, DECISION_SITES).get("pendingReleases") != 1:
        print("self-test FAIL: 植入的决策族符号未被识别")
        ok = False
    if scan(translation, DECISION_SITES):
        print("self-test FAIL: 翻译族符号被误判为决策")
        ok = False
    print("self-test %s" % ("PASS" if ok else "FAIL"))
    return ok


def main():
    if "--self-test" in sys.argv:
        return 0 if self_test() else 1

    path = os.path.join(ROOT, EMITTER)
    if not os.path.exists(path):
        print("backend duty check: 找不到 %s，判为不通过" % EMITTER)
        return 1

    found = scan(read(path), DECISION_SITES)
    total = sum(found.values())

    print("后端义务检查（警告级）· 所有权归位")
    print("  文件: %s" % EMITTER)
    print("  决策族符号: %d 个，共 %d 处" % (len(found), total))
    for sym in DECISION_SITES:
        if sym in found:
            print("    %-26s %d" % (sym, found[sym]))

    if total:
        print()
        print("  这些点在「所有权归位」落地后应归零。现在只报，不拦。")
        if "--strict" in sys.argv:
            return 1
    else:
        print("  未发现决策族符号：后端只翻译，不决定。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

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

EMITTER = "Sources/PiniBackendLLVM/CodeGen/IREmitter.swift"

# 决策族：回答「这个值归谁、此刻要不要 retain / release」。这些判断已全部归位到中端的
# `IROwnership`（类型分类 · 求值效果 · 接收动作），发射器只翻译注解。列表留空是这个分片的
# 验收目标本身 —— 再有名字进来，说明判断又长回了后端。
DECISION_SITES = []

# 已归位：这些名字必须为 0。作用域与覆盖一族搬进存储点注解，别名与临时一族搬进求值效果表 ——
# 两组都以「发射器不再自己回答」收口。任何一处回来都算回归。
RETIRED_SITES = [
    "pendingReleases",
    "emitReleases",
    "emitReassignRelease",
    "emitFieldReassignRelease",
    "registerReleasedHandle",
    "emitRetainIfAliased",
    "retainIfOwningContainer",
]

# 翻译点：把中端的判定译成一次调用，不判断「要不要」。只报读数、不设上限 ——
# 上限会逼着人删注释或改名，而判据是「判断住在哪一层」，不是「这层有几个调用」。
TRANSLATION_SITES = [
    "releaseOwnedString",
    "releaseOwnedTemporary",
    "releaseCallArguments",
    "releaseOperand",
    "ensureReleaseFunction",
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
    """The detector must fire on a planted retired symbol and stay silent on a translation."""
    planted = "private func emitRetainIfAliased() {}\n"
    translation = "private func releaseSymbol(for type: IRType) -> String? {}\n"
    ok = True
    if scan(planted, RETIRED_SITES).get("emitRetainIfAliased") != 1:
        print("self-test FAIL: 植入的已归位符号未被识别")
        ok = False
    if scan(translation, RETIRED_SITES + DECISION_SITES):
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

    text = read(path)
    found = scan(text, DECISION_SITES)
    total = sum(found.values())
    retired = scan(text, RETIRED_SITES)
    translation = scan(text, TRANSLATION_SITES)

    print("后端义务检查（警告级）· 所有权归位")
    print("  文件: %s" % EMITTER)
    print("  决策族符号: %d 个，共 %d 处" % (len(found), total))
    for sym in DECISION_SITES:
        if sym in found:
            print("    %-26s %d" % (sym, found[sym]))
    if retired:
        print("  已归位符号又出现: %s" % ", ".join(sorted(retired)))
    if translation:
        print("  翻译点（只报读数）: %s" % ", ".join(
            "%s %d" % (sym, translation[sym]) for sym in TRANSLATION_SITES if sym in translation))

    if total or retired:
        print()
        print("  决策族与已归位符号都必须为 0。现在只报，不拦。")
        if "--strict" in sys.argv:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

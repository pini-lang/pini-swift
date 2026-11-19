#!/usr/bin/env bash
# bootstrap/tools/test-gate.sh — 自举测试入口的自检：失败夹具必须红，筛选与跳过必须绿。
# 判据同时看退出码与报告行；只跑完不报错不算通过，红绿两侧都要有证据。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

pini="$root/bootstrap/.build/debug/bin/pini-bootstrap"
clang_bin="$(command -v clang || true)"
if [ ! -x "$pini" ] || [ -z "$clang_bin" ]; then
    echo " 行不通  [测试自检] 缺 pini-bootstrap 或 clang" >&2
    exit 1
fi

fixture="$root/bootstrap/fixtures/test-basic"
work="$root/bootstrap/.build/debug/tests/gate"
mkdir -p "$work" || exit 1

# 跑一轮：发射、链接、运行；报告走标准输出，诊断走标准错误，退出码即测试结果。
run_case() {
    local name="$1"
    shift
    local ll="$work/$name.ll"
    local bin="$work/$name"
    if ! "$pini" test "$fixture" "$@" > "$ll"; then
        echo " 行不通  [测试自检] $name 发射失败" >&2
        return 2
    fi
    if ! "$clang_bin" -o "$bin" "$ll" -L"$root/.build/debug" -lPiniRuntime \
        -Wl,-rpath,"$root/.build/debug" >/dev/null 2>&1; then
        echo " 行不通  [测试自检] $name 链接失败" >&2
        return 2
    fi
    ( cd "$fixture" && "$bin" )
}

fail=0

report="$(run_case all)"
code=$?
if [ "$code" -ne 1 ]; then
    echo " 行不通  [测试自检] 失败夹具应退出 1，实得 $code" >&2
    fail=1
fi
case "$report" in
*"✗ 中条失败: 故意失败"*) ;;
*)
    echo " 行不通  [测试自检] 报告缺失败行：$report" >&2
    fail=1
    ;;
esac
case "$report" in
*"结果: 3 通过, 1 失败"*) ;;
*)
    echo " 行不通  [测试自检] 汇总应为 3 通过 1 失败：$report" >&2
    fail=1
    ;;
esac

report="$(run_case filtered --filter 首条通过)"
code=$?
if [ "$code" -ne 0 ]; then
    echo " 行不通  [测试自检] 筛选单条应退出 0，实得 $code" >&2
    fail=1
fi
case "$report" in
*"结果: 1 通过, 0 失败"*) ;;
*)
    echo " 行不通  [测试自检] 筛选单条应只跑一条：$report" >&2
    fail=1
    ;;
esac

report="$(run_case skipped --skip 中条失败)"
code=$?
if [ "$code" -ne 0 ]; then
    echo " 行不通  [测试自检] 跳过后应退出 0，实得 $code" >&2
    fail=1
fi
case "$report" in
*"结果: 3 通过, 0 失败"*) ;;
*)
    echo " 行不通  [测试自检] 跳过后应三条全过：$report" >&2
    fail=1
    ;;
esac

"$pini" test "$fixture" --filter 不存在 > /dev/null 2>&1
code=$?
if [ "$code" -eq 0 ]; then
    echo " 行不通  [测试自检] 筛选零命中应非零退出" >&2
    fail=1
fi

"$pini" test "$fixture" --skip 不存在 > /dev/null 2>&1
code=$?
if [ "$code" -eq 0 ]; then
    echo " 行不通  [测试自检] 跳过零命中应非零退出" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "测试自检通过：失败夹具红，筛选与跳过绿，零命中非零退出"
exit 0

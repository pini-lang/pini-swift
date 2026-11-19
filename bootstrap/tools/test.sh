#!/usr/bin/env bash
# bootstrap/tools/test.sh — 自举测试入口：清单与选择由驱动做，落盘、链接与运行归本脚本。
# 位置参数：工作区根（缺省 bootstrap），其后参数原样交给驱动（--filter/--skip）。
# 退出码是唯一判据：清单错、发射错、链接错与测试失败都非零，不吞。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

workspace="${1:-$root/bootstrap}"
if [ "$#" -gt 0 ]; then
    shift
fi

pini="${PINI_BOOTSTRAP_BIN:-$root/bootstrap/.build/debug/bin/pini-bootstrap}"
if [ ! -x "$pini" ]; then
    echo " 行不通  [测试] 缺 $pini；先 bash bootstrap/tools/build.sh" >&2
    exit 1
fi

clang_bin="$(command -v clang || true)"
if [ -z "$clang_bin" ]; then
    echo " 行不通  [测试] 未找到 clang —— 链接无法执行，不等于通过" >&2
    exit 1
fi

out="$root/bootstrap/.build/debug/tests"
if ! mkdir -p "$out"; then
    echo " 行不通  [测试] 无法创建 $out" >&2
    exit 1
fi
ll="$out/workspace.ll"
bin="$out/workspace-tests"

# 工作目录切到工作区根：测试体里的相对路径与宿主通道同基准。
cd "$workspace" || exit 1
if ! "$pini" test "$workspace" "$@" > "$ll"; then
    echo " 行不通  [测试] 清单或发射失败；原因见上一行标准错误" >&2
    exit 1
fi

runtime_dir="$root/.build/debug"
link_args=(-o "$bin" "$ll")
if [ -f "$runtime_dir/libPiniRuntime.dylib" ] || [ -f "$runtime_dir/libPiniRuntime.so" ]; then
    link_args=(-L"$runtime_dir" -lPiniRuntime -Wl,-rpath,"$runtime_dir" "${link_args[@]}")
fi
if ! "$clang_bin" "${link_args[@]}"; then
    echo " 行不通  [测试] 链接失败；LLVM 文本留在 $ll" >&2
    exit 1
fi

"$bin"
exit $?

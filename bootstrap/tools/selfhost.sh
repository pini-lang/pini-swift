#!/usr/bin/env bash
# bootstrap/tools/selfhost.sh — 自洽协议：首代 -> 次代 -> 三代，两代各跑同一份验收语料。
# 判据两条：两代语料报告逐字节相同；次代再发射整图，文本与首代逐字节相同（不动点）。
# 这是一次十分钟级的交付判据，不进合并流水线；CI 只跑语料子集与自检。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1
. "$root/bootstrap/tools/runtime-lib.sh"

gen1="${PINI_BOOTSTRAP_BIN:-$root/bootstrap/.build/debug/bin/pini-bootstrap}"
if [ ! -x "$gen1" ]; then
    echo " 行不通  [自洽] 缺首代产物 $gen1；先 bash bootstrap/tools/build.sh" >&2
    exit 1
fi

clang_bin="$(command -v clang || true)"
if [ -z "$clang_bin" ]; then
    echo " 行不通  [自洽] 未找到 clang —— 链接无法执行，不等于通过" >&2
    exit 1
fi

work="$root/bootstrap/.build/tests/selfhost"
if ! mkdir -p "$work"; then
    echo " 行不通  [自洽] 无法创建 $work" >&2
    exit 1
fi

runtime="$(pini_runtime_lib "$root")" || exit 1
runtime_dir="$(dirname "$runtime")"
link_args=(-o "$work/gen2" "$work/gen2.ll" -L"$runtime_dir" -lPiniRuntime -Wl,-rpath,"$runtime_dir")

# 首代发射整图；先两行读数，其后才是 LLVM 文本。
if ! "$gen1" emit "$root/bootstrap" > "$work/gen2.txt"; then
    echo " 行不通  [自洽] 首代发射整图失败" >&2
    exit 1
fi
tail -n +3 "$work/gen2.txt" > "$work/gen2.ll"
if [ ! -s "$work/gen2.ll" ]; then
    echo " 行不通  [自洽] 首代发射文本为空" >&2
    exit 1
fi

if ! "$clang_bin" "${link_args[@]}"; then
    echo " 行不通  [自洽] 次代链接失败；LLVM 文本留在 $work/gen2.ll" >&2
    exit 1
fi

# 次代能否启动不单跑冒烟：下面两段都用它执行，启动失败即在那两步报错。

# 两代各跑同一份语料，报告逐字节比对。
if ! PINI_BOOTSTRAP_BIN="$gen1" python3 bootstrap/tools/conformance.py > "$work/report1.txt" 2>&1; then
    echo " 行不通  [自洽] 首代跑语料失败；报告见 $work/report1.txt" >&2
    exit 1
fi
if ! PINI_BOOTSTRAP_BIN="$work/gen2" python3 bootstrap/tools/conformance.py > "$work/report2.txt" 2>&1; then
    echo " 行不通  [自洽] 次代跑语料失败；报告见 $work/report2.txt" >&2
    exit 1
fi
if ! cmp -s "$work/report1.txt" "$work/report2.txt"; then
    echo " 行不通  [自洽] 两代语料报告不同；差异见 $work/report1.txt 与 $work/report2.txt" >&2
    exit 1
fi

# 不动点：次代再发射同一工作区，文本与首代逐字节相同。
if ! "$work/gen2" emit "$root/bootstrap" > "$work/gen3.txt"; then
    echo " 行不通  [自洽] 次代发射整图失败" >&2
    exit 1
fi
if ! cmp -s "$work/gen2.txt" "$work/gen3.txt"; then
    echo " 行不通  [自洽] 两代发射文本不同；差异见 $work/gen2.txt 与 $work/gen3.txt" >&2
    exit 1
fi

printf '自洽通过：两代语料报告相同 · 两代发射文本相同（%s 字节）\n' "$(wc -c < "$work/gen2.txt" | tr -d ' ')"
exit 0

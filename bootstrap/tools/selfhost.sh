#!/usr/bin/env bash
# bootstrap/tools/selfhost.sh — 自洽协议：首代 -> 次代 -> 三代，次代执行同一套门禁与语料。
# 判据：两代门禁与语料报告逐字节相同、计划文本相同；次代再发射整图，文本相同（不动点）。
# 这是一次十分钟级的交付判据，不进合并流水线；CI 只跑语料子集与自检。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1
. "$root/bootstrap/tools/runtime-lib.sh"

gen1="${PINI_BOOTSTRAP_BIN:-$root/bootstrap/.build/release/bin/pini-bootstrap}"
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
if ! "$gen1" emit "$root/bootstrap" --no-stdlib > "$work/gen2.txt"; then
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

# 次代能否启动不单跑冒烟：下面各段都用它执行，启动失败即在那一段报错。

# 门禁接线：两代各跑同一套自检，报告逐字节比；生成模块夹具与三类定向诊断由次代执行。
if ! PINI_BOOTSTRAP_BIN="$gen1" bash "$root/bootstrap/tools/test-gate.sh" > "$work/gate1.txt" 2>&1; then
    echo " 行不通  [自洽] 首代跑门禁自检失败；报告见 $work/gate1.txt" >&2
    exit 1
fi
if ! PINI_BOOTSTRAP_BIN="$work/gen2" bash "$root/bootstrap/tools/test-gate.sh" > "$work/gate2.txt" 2>&1; then
    echo " 行不通  [自洽] 次代跑门禁自检失败；报告见 $work/gate2.txt" >&2
    exit 1
fi
if ! cmp -s "$work/gate1.txt" "$work/gate2.txt"; then
    echo " 行不通  [自洽] 两代门禁报告不同；差异见 $work/gate1.txt 与 $work/gate2.txt" >&2
    exit 1
fi

# 计划文本：同一构建脚本夹具两代各出一份，逐字节相同才算计划口径未分叉。
script_fixture="$root/bootstrap/fixtures/build-script"
if ! "$gen1" plan "$script_fixture" > "$work/plan1.txt" 2>&1; then
    echo " 行不通  [自洽] 首代出不了构建计划；报告见 $work/plan1.txt" >&2
    exit 1
fi
if ! "$work/gen2" plan "$script_fixture" > "$work/plan2.txt" 2>&1; then
    echo " 行不通  [自洽] 次代出不了构建计划；报告见 $work/plan2.txt" >&2
    exit 1
fi
if ! cmp -s "$work/plan1.txt" "$work/plan2.txt"; then
    echo " 行不通  [自洽] 两代计划文本不同；差异见 $work/plan1.txt 与 $work/plan2.txt" >&2
    exit 1
fi

# 自产 build 不靠宿主：净化 PATH 后仍退出 0，且构建不在源码树留新文件。
clean_path="/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$clean_path" command -v pini > /dev/null 2>&1; then
    echo " 行不通  [自洽] 净化 PATH 后仍可见宿主 pini" >&2
    exit 1
fi
git status --porcelain > "$work/status-before.txt"
if ! PATH="$clean_path" "$work/gen2" build "$root/bootstrap" --no-stdlib > "$work/build2.txt" 2>&1; then
    echo " 行不通  [自洽] 次代 build 失败；报告见 $work/build2.txt" >&2
    exit 1
fi
git status --porcelain > "$work/status-after.txt"
if ! cmp -s "$work/status-before.txt" "$work/status-after.txt"; then
    echo " 行不通  [自洽] 次代构建改动了源码树；差异见 $work/status-after.txt" >&2
    exit 1
fi

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
if ! "$work/gen2" emit "$root/bootstrap" --no-stdlib > "$work/gen3.txt"; then
    echo " 行不通  [自洽] 次代发射整图失败" >&2
    exit 1
fi
if ! cmp -s "$work/gen2.txt" "$work/gen3.txt"; then
    echo " 行不通  [自洽] 两代发射文本不同；差异见 $work/gen2.txt 与 $work/gen3.txt" >&2
    exit 1
fi

printf '自洽通过：两代门禁与语料报告相同 · 计划文本相同 · 发射文本相同（%s 字节）\n' "$(wc -c < "$work/gen2.txt" | tr -d ' ')"
exit 0

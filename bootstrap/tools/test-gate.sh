#!/usr/bin/env bash
# bootstrap/tools/test-gate.sh — 自举测试入口的自检：失败夹具必须红，筛选与跳过必须绿。
# 判据同时看退出码与报告行；只跑完不报错不算通过，红绿两侧都要有证据。
# 入口默认首代产物；自洽链经 PINI_BOOTSTRAP_BIN 换成次代，同一套判据因此由自产产物执行。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1
. "$root/bootstrap/tools/runtime-lib.sh"

runtime="$(pini_runtime_lib "$root")" || exit 1
runtime_dir="$(dirname "$runtime")"

# 能力可达：接通即声明、声明即至少接一条；源扫描，不依赖二进制。
if ! python3 "$root/bootstrap/tools/capability-reach.py" --check > /dev/null; then
    echo " 行不通  [测试自检] 能力可达自检未通过" >&2
    exit 1
fi

pini="${PINI_BOOTSTRAP_BIN:-$root/bootstrap/.build/debug/bin/pini-bootstrap}"
clang_bin="$(command -v clang || true)"
if [ ! -x "$pini" ] || [ -z "$clang_bin" ]; then
    echo " 行不通  [测试自检] 缺 $pini 或 clang" >&2
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
    if ! "$clang_bin" -o "$bin" "$ll" -L"$runtime_dir" -lPiniRuntime \
        -Wl,-rpath,"$runtime_dir" >/dev/null 2>&1; then
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

# 分段降载：stage 1 只到装载，读数应止于 stage-load；默认路径仍一路到降载与校验。
stage_out="$("$pini" lower "$fixture" --stage=1 2>/dev/null)"
case "$stage_out" in
*"stage-load"*) ;;
*)
    echo " 行不通  [测试自检] 分段降载缺 stage-load 读数" >&2
    fail=1
    ;;
esac
case "$stage_out" in
*"stage-lower"* | *"lower-ok"*)
    echo " 行不通  [测试自检] stage 1 不应继续降载" >&2
    fail=1
    ;;
esac
full_out="$("$pini" lower "$fixture" 2>/dev/null)"
case "$full_out" in
*"validate-ok"*) ;;
*)
    echo " 行不通  [测试自检] 默认降载应跑到校验" >&2
    fail=1
    ;;
esac

# 外部声明：模块表出 declare，调用点直呼 C 名字；链接执行读数与手算一致。
extern_fixture="$root/bootstrap/fixtures/llvm-extern"
extern_raw="$work/extern-raw.ll"
extern_ll="$work/extern.ll"
if ! "$pini" emit "$extern_fixture" > "$extern_raw" 2>/dev/null; then
    echo " 行不通  [测试自检] 外部声明夹具发射失败" >&2
    fail=1
fi
tail -n +3 "$extern_raw" > "$extern_ll"
if ! grep -q "declare i32 @abs(i32)" "$extern_ll"; then
    echo " 行不通  [测试自检] 外部声明未出 declare" >&2
    fail=1
fi
if ! "$clang_bin" -o "$work/extern-bin" "$extern_ll" -L"$runtime_dir" -lPiniRuntime \
    -Wl,-rpath,"$runtime_dir" >/dev/null 2>&1; then
    echo " 行不通  [测试自检] 外部声明夹具链接失败" >&2
    fail=1
fi
if [ -x "$work/extern-bin" ]; then
    "$work/extern-bin"
    if [ "$?" -ne 5 ]; then
        echo " 行不通  [测试自检] 外部声明夹具读数应为 5" >&2
        fail=1
    fi
fi

# 构建脚本：给定块读成翻译步，产物路径落在包内 generated，非给定块按错误报。
script_fixture="$root/bootstrap/fixtures/build-script"
script_plan="$work/build-script-plan.txt"
if ! "$pini" plan "$script_fixture" > "$script_plan" 2>&1; then
    echo " 行不通  [测试自检] 构建脚本夹具出不了计划" >&2
    fail=1
fi
if ! grep -q "step cstr header=include/cstr.h include=include defs=_GNU_SOURCE" "$script_plan"; then
    echo " 行不通  [测试自检] 计划缺 cstr 步骤行" >&2
    fail=1
fi
if ! grep -q "/generated/mathf.pini" "$script_plan"; then
    echo " 行不通  [测试自检] 步骤产物未落在包内 generated" >&2
    fail=1
fi
if grep -q "^error" "$script_plan"; then
    echo " 行不通  [测试自检] 计划不应带错误：$(cat "$script_plan")" >&2
    fail=1
fi

# 生成模块：计划登记且产物在 .build 下才并入；缺计划、缺产物、脚本改动各报一条指向 build 的诊断。
gen_fixture="$work/generated-load"
rm -rf "$gen_fixture"
cp -R "$root/bootstrap/fixtures/generated-load" "$gen_fixture"
gen_plan="$gen_fixture/.build/debug/plan.toml"
gen_out="$gen_fixture/.build/debug/packages/gendemo/generated/cstr.pini"
mkdir -p "$gen_fixture/.build/debug/packages/gendemo/generated"
"$pini" build "$gen_fixture" > /dev/null 2>&1
if [ ! -f "$gen_plan" ]; then
    echo " 行不通  [测试自检] 生成模块夹具没落计划" >&2
    fail=1
fi
cat > "$gen_out" <<'EOF'
[cstr|foreign]
pini_double: (I32,) -> (I32,)
EOF
gen_report="$("$pini" check "$gen_fixture" 2>&1)"
case "$gen_report" in
*"workspace-ok"*) ;;
*)
    echo " 行不通  [测试自检] 生成模块未并入，检查未通过：$gen_report" >&2
    fail=1
    ;;
esac
mv "$gen_plan" "$work/generated-plan.bak"
gen_report="$("$pini" check "$gen_fixture" 2>&1)"
case "$gen_report" in
*"构建计划不存在"*) ;;
*)
    echo " 行不通  [测试自检] 缺计划未报定向诊断：$gen_report" >&2
    fail=1
    ;;
esac
mv "$work/generated-plan.bak" "$gen_plan"
mv "$gen_out" "$work/generated-out.bak"
gen_report="$("$pini" check "$gen_fixture" 2>&1)"
case "$gen_report" in
*"生成模块不存在"*) ;;
*)
    echo " 行不通  [测试自检] 缺产物未报定向诊断：$gen_report" >&2
    fail=1
    ;;
esac
mv "$work/generated-out.bak" "$gen_out"
printf '\n; 改一行\n' >> "$gen_fixture/pkg/build.pini"
gen_report="$("$pini" check "$gen_fixture" 2>&1)"
case "$gen_report" in
*"构建计划与脚本不一致"*) ;;
*)
    echo " 行不通  [测试自检] 脚本改动未报计划过期：$gen_report" >&2
    fail=1
    ;;
esac

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "测试自检通过：失败夹具红，筛选与跳过绿，零命中非零退出，分段读数止于所指阶段，构建脚本出计划，生成模块按计划并入"
exit 0

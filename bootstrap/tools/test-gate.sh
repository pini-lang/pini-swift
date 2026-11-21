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

# 差异普查：命令、通道、诊断三张静态表必须与盘上一致；程序表要跑全部示例，不在此列。
if ! python3 "$root/bootstrap/tools/parity.py" --check > /dev/null; then
    echo " 行不通  [测试自检] 差异普查表已过期，重跑 bootstrap/tools/parity.py" >&2
    exit 1
fi

# 命令行对照：同一批用例两侧各跑一遍，按侧比期望并核对读数表；缺命令只登记不判红。
if ! python3 "$root/bootstrap/tools/cli-parity.py" > /dev/null; then
    echo " 行不通  [测试自检] 命令行对照夹具未通过" >&2
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

# 浮点字面量：常量按位模式出十六进制，四则与打印读数与宿主逐行相同。
float_fixture="$root/bootstrap/fixtures/llvm-float"
float_raw="$work/float-raw.ll"
float_ll="$work/float.ll"
if ! "$pini" emit "$float_fixture" > "$float_raw" 2>/dev/null; then
    echo " 行不通  [测试自检] 浮点夹具发射失败" >&2
    fail=1
fi
tail -n +3 "$float_raw" > "$float_ll"
if ! grep -q "double 0x" "$float_ll"; then
    echo " 行不通  [测试自检] 浮点常量未按位模式发射" >&2
    fail=1
fi
if ! "$clang_bin" -o "$work/float-bin" "$float_ll" -L"$runtime_dir" -lPiniRuntime \
    -Wl,-rpath,"$runtime_dir" >/dev/null 2>&1; then
    echo " 行不通  [测试自检] 浮点夹具链接失败" >&2
    fail=1
fi
if [ -x "$work/float-bin" ]; then
    float_report="$("$work/float-bin")"
    float_expected="18.75
3.75
0.30000000000000004
1e-05"
    if [ "$float_report" != "$float_expected" ]; then
        echo " 行不通  [测试自检] 浮点读数不符：$float_report" >&2
        fail=1
    fi
fi

# 接口缓存：记录落 .build 后，未变不重写、公开面变化报 E3-021、仅内部改动不失效。
iface_expect() {
    local label="$1"
    local want="$2"
    local got="$3"
    case "$got" in
    *"$want"*) ;;
    *)
        echo " 行不通  [测试自检] ${label}：${got}" >&2
        fail=1
        ;;
    esac
}
iface_fixture="$work/interfaces-cache"
rm -rf "$iface_fixture"
cp -R "$root/bootstrap/fixtures/interfaces-cache" "$iface_fixture"
mkdir -p "$iface_fixture/.build/debug/packages/app" "$iface_fixture/.build/debug/packages/support"
iface_expect "首次接口缓存应两份新写" "interfaces-ok 2 2 0" "$("$pini" interfaces "$iface_fixture" --no-stdlib 2>&1)"
iface_expect "接口未变不应重写" "interfaces-ok 2 0 2" "$("$pini" interfaces "$iface_fixture" --no-stdlib 2>&1)"
if [ ! -f "$iface_fixture/.build/debug/interfaces.toml" ]; then
    echo " 行不通  [测试自检] 接口记录未落盘" >&2
    fail=1
fi
iface_expect "记录一致时检查应通过" "workspace-ok" "$("$pini" check "$iface_fixture" --no-stdlib 2>&1)"
cp "$iface_fixture/support/src/api.pini" "$work/iface-support.bak"
cat > "$iface_fixture/support/src/api.pini" <<EOF
; 支持包：返回值改成 I64，公开接口变化。
公开|func(x: I32,) -> (I64,):
    return (x + 1) as I64
EOF
iface_expect "公开接口变化应报 E3-021" "E3-021" "$("$pini" check "$iface_fixture" --no-stdlib 2>&1)"
iface_expect "记录更新应只重算两份" "interfaces-ok 2 2 0" "$("$pini" interfaces "$iface_fixture" --no-stdlib 2>&1)"
iface_expect "记录追上源码后检查应通过" "workspace-ok" "$("$pini" check "$iface_fixture" --no-stdlib 2>&1)"
cp "$work/iface-support.bak" "$iface_fixture/support/src/api.pini"
iface_expect "还原源码后记录应再变一次" "interfaces-ok 2 2 0" "$("$pini" interfaces "$iface_fixture" --no-stdlib 2>&1)"
iface_expect "还原后检查应通过" "workspace-ok" "$("$pini" check "$iface_fixture" --no-stdlib 2>&1)"
mkdir -p "$iface_fixture/support/src/_internal"
cat > "$iface_fixture/support/src/_internal/helper.pini" <<EOF
; 内部文件：不进公开接口。
辅助|func(x: I32,) -> (I32,):
    return x + 2
EOF
iface_expect "仅内部改动应只重算自身" "interfaces-ok 2 1 1" "$("$pini" interfaces "$iface_fixture" --no-stdlib 2>&1)"
iface_expect "内部改动后检查应通过" "workspace-ok" "$("$pini" check "$iface_fixture" --no-stdlib 2>&1)"

# 逐包产物：接口记录在前后按包发射；每包只含本包定义，其余出声明，合并链接不冲突。
pkg_expect() {
    local label="$1"
    local want="$2"
    local got="$3"
    case "$got" in
    *"$want"*) ;;
    *)
        echo " 行不通  [测试自检] ${label}：${got}" >&2
        fail=1
        ;;
    esac
}
pkg_fixture="$work/packages-ir"
pkg_dir="$pkg_fixture/.build/debug/packages"
rm -rf "$pkg_fixture"
cp -R "$root/bootstrap/fixtures/packages-ir" "$pkg_fixture"
mkdir -p "$pkg_dir/app" "$pkg_dir/cli" "$pkg_dir/support"
pkg_expect "接口记录应三份新写" "interfaces-ok 3 3 0" "$("$pini" interfaces "$pkg_fixture" --no-stdlib 2>&1)"
pkg_expect "逐包发射应写三份" "emit-packages-ok 3 3 0 " "$("$pini" emit "$pkg_fixture" --packages --no-stdlib 2>&1)"
for pkg_name in app cli support; do
    if [ ! -f "$pkg_dir/$pkg_name/$pkg_name.ll" ]; then
        echo " 行不通  [测试自检] 缺 $pkg_name 的逐包产物" >&2
        fail=1
    fi
done
if ! grep -q '^define i32 @_u5957_u7528' "$pkg_dir/app/app.ll"; then
    echo " 行不通  [测试自检] 应用包应为套用出定义" >&2
    fail=1
fi
if ! grep -q '^declare i32 @_u516C_u5F00' "$pkg_dir/app/app.ll"; then
    echo " 行不通  [测试自检] 应用包应为公开出声明" >&2
    fail=1
fi
if ! grep -q '^define i32 @_u516C_u5F00' "$pkg_dir/support/support.ll"; then
    echo " 行不通  [测试自检] 支持包应为公开出定义" >&2
    fail=1
fi
if grep -q '^define i32 @_u5957_u7528' "$pkg_dir/support/support.ll"; then
    echo " 行不通  [测试自检] 支持包不应重复定义套用" >&2
    fail=1
fi
if ! grep -q '^define i32 @main' "$pkg_dir/cli/cli.ll"; then
    echo " 行不通  [测试自检] 入口包应定义 main" >&2
    fail=1
fi
if ! grep -q 'package = "app"' "$pkg_fixture/.build/debug/artifacts.toml"; then
    echo " 行不通  [测试自检] 产物记录应含应用包" >&2
    fail=1
fi
mkdir -p "$work/pkg-ll-first"
for pkg_name in app cli support; do
    cp "$pkg_dir/$pkg_name/$pkg_name.ll" "$work/pkg-ll-first/$pkg_name.ll"
done
pkg_expect "二次发射应全部复用" "emit-packages-ok 3 0 3 " "$("$pini" emit "$pkg_fixture" --packages --no-stdlib 2>&1)"
for pkg_name in app cli support; do
    if ! cmp -s "$work/pkg-ll-first/$pkg_name.ll" "$pkg_dir/$pkg_name/$pkg_name.ll"; then
        echo " 行不通  [测试自检] 二次发射应逐字节相同：$pkg_name" >&2
        fail=1
    fi
done
pkg_objects=""
pkg_objs_ok=1
for pkg_name in app cli support; do
    if ! "$clang_bin" -c "$pkg_dir/$pkg_name/$pkg_name.ll" -o "$work/pkg-$pkg_name.o" >/dev/null 2>&1; then
        echo " 行不通  [测试自检] 逐包产物应能单独编译：$pkg_name" >&2
        fail=1
        pkg_objs_ok=0
    fi
    pkg_objects="$pkg_objects $work/pkg-$pkg_name.o"
done
if [ "$pkg_objs_ok" -eq 1 ]; then
    if ! "$clang_bin" -o "$work/pkg-bin" $pkg_objects -L"$runtime_dir" -lPiniRuntime -Wl,-rpath,"$runtime_dir" >/dev/null 2>&1; then
        echo " 行不通  [测试自检] 逐包产物合并链接失败" >&2
        fail=1
    else
        "$work/pkg-bin"
        pkg_rc=$?
        if [ "$pkg_rc" -ne 1 ]; then
            echo " 行不通  [测试自检] 合并后可执行应返回 1，实得 $pkg_rc" >&2
            fail=1
        fi
    fi
fi
# 缓存：按拓扑序比源码与依赖摘要；实现改动只重发本包，公开面改动沿依赖传播一层。
cp "$pkg_fixture/support/src/api.pini" "$work/pkg-support.bak"
cat > "$pkg_fixture/support/src/api.pini" <<EOF
; 支持包：实现加一改成加二，公开面不变。
公开|func(x: I32,) -> (I32,):
    return x + 2
EOF
pkg_expect "实现改动应只重算支持包" "interfaces-ok 3 1 2" "$("$pini" interfaces "$pkg_fixture" --no-stdlib 2>&1)"
pkg_expect "实现改动应只重发支持包" "emit-packages-ok 3 1 2 " "$("$pini" emit "$pkg_fixture" --packages --no-stdlib 2>&1)"
cat > "$pkg_fixture/support/src/api.pini" <<EOF
; 支持包：返回值改成 I64，公开接口变化。
公开|func(x: I32,) -> (I64,):
    return (x + 1) as I64
EOF
pkg_expect "公开面变化应报 E3-021" "E3-021" "$("$pini" check "$pkg_fixture" --no-stdlib 2>&1)"
pkg_expect "公开面变化应只波及直接下游" "interfaces-ok 3 2 1" "$("$pini" interfaces "$pkg_fixture" --no-stdlib 2>&1)"
pkg_expect "公开面变化应重发下游一层" "emit-packages-ok 3 2 1 " "$("$pini" emit "$pkg_fixture" --packages --no-stdlib 2>&1)"
cp "$work/pkg-support.bak" "$pkg_fixture/support/src/api.pini"
pkg_expect "还原后应再波及直接下游" "interfaces-ok 3 2 1" "$("$pini" interfaces "$pkg_fixture" --no-stdlib 2>&1)"
pkg_expect "还原后应再重发下游一层" "emit-packages-ok 3 2 1 " "$("$pini" emit "$pkg_fixture" --packages --no-stdlib 2>&1)"
mkdir -p "$pkg_fixture/support/src/_internal"
cat > "$pkg_fixture/support/src/_internal/helper.pini" <<EOF
; 内部文件：不进公开接口，也不该让下游重发。
辅助|func(x: I32,) -> (I32,):
    return x + 3
EOF
pkg_expect "内部改动应只重算支持包" "interfaces-ok 3 1 2" "$("$pini" interfaces "$pkg_fixture" --no-stdlib 2>&1)"
pkg_expect "内部改动应只重发支持包" "emit-packages-ok 3 1 2 " "$("$pini" emit "$pkg_fixture" --packages --no-stdlib 2>&1)"
pkg_expect "逐包记录后检查应通过" "workspace-ok" "$("$pini" check "$pkg_fixture" --no-stdlib 2>&1)"

# 分波与共享缓存：分波出依赖深度，单包发射只换本包记录，缓存按输入指纹跨构建复用。
wave_expect() {
    local label="$1"
    local want="$2"
    local got="$3"
    case "$got" in
        *"$want"*) : ;;
        *)
            echo " 行不通  [测试自检] $label ：$got" >&2
            fail=1
            ;;
    esac
}

cache_dir="$work/packages-cache"
rm -rf "$cache_dir"
wave_expect "分波应出第一波" "wave 0 support" "$("$pini" plan "$pkg_fixture" --waves 2>&1)"
wave_expect "第二波应是应用包" "wave 1 app" "$("$pini" plan "$pkg_fixture" --waves 2>&1)"
wave_expect "第三波应是命令行包" "wave 2 cli" "$("$pini" plan "$pkg_fixture" --waves 2>&1)"
printf '%s\n' "; 缓存探针追加一行" >> "$pkg_fixture/app/src/api.pini"
wave_expect "单包发射只换本包" "emit-packages-ok 1 1 0 " "$("$pini" emit "$pkg_fixture" --packages --package=app --no-stdlib 2>&1)"
if [ "$(grep -c 'package = ' "$pkg_fixture/.build/debug/artifacts.toml")" != "3" ]; then
    echo " 行不通  [测试自检] 单包发射不该丢其余包记录" >&2
    fail=1
fi
rm -f "$pkg_fixture/.build/debug/packages/app/app.ll"
missing_cache="$("$pini" emit "$pkg_fixture" --packages --package=app --no-stdlib --cache-dir="$cache_dir" 2>&1)"
wave_expect "缓存目录缺失应定向报" "emit-packages-cache-missing" "$missing_cache"
cache_home="$(echo "$missing_cache" | grep -o "$cache_dir/[0-9a-f]*" | head -1)"
if [ -z "$cache_home" ]; then
    echo " 行不通  [测试自检] 缓存诊断未给出目录" >&2
    fail=1
else
    mkdir -p "$cache_home"
    wave_expect "缓存未命中应发射一份" "emit-packages-ok 1 1 0 " "$("$pini" emit "$pkg_fixture" --packages --package=app --no-stdlib --cache-dir="$cache_dir" 2>&1)"
    if [ ! -f "$cache_home/app.ll" ]; then
        echo " 行不通  [测试自检] 缓存未落盘" >&2
        fail=1
    fi
    rm -f "$pkg_fixture/.build/debug/packages/app/app.ll"
    wave_expect "删产物后应从缓存恢复" "emit-packages-ok 1 0 0 " "$("$pini" emit "$pkg_fixture" --packages --package=app --no-stdlib --cache-dir="$cache_dir" 2>&1)"
    if ! cmp -s "$pkg_fixture/.build/debug/packages/app/app.ll" "$cache_home/app.ll"; then
        echo " 行不通  [测试自检] 缓存恢复内容应与缓存逐字节相同" >&2
        fail=1
    fi
fi
if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "测试自检通过：失败夹具红，筛选与跳过绿，零命中非零退出，分段读数止于所指阶段，构建脚本出计划，生成模块按计划并入，浮点常量走位模式，接口缓存按记录判失效，逐包产物按包发射且合并可链接，缓存按拓扑与内容判复用，分波按依赖深度，共享缓存按指纹复用，命令对照按签名锁定"
exit 0

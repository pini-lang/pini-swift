#!/usr/bin/env bash
# stdlib-c-oracle.sh — 标准库独立性对照：把 18 个字符串成员换成外部 C 内核，其余装配不动。
# 判据两段：语料报告两侧逐字节相同（必须绿）；读数按一致区与分叉区统计（只报数）。
# 顶替片段并入入口文件；动态库按 @rpath 安装名构建，裸名会让链接通道在 dyld 处失败。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

pini="${PINI_BIN:-$root/.build/release/pini}"
cc_bin="${CC:-cc}"
keep=0
[ "${1:-}" = "--keep" ] && keep=1 # 保留两侧树，便于复查

fail() {
    echo " 行不通  [标准库对照] $1" >&2
    exit 1
}

[ -x "$pini" ] || fail "缺可执行的 pini（$pini）；先 swift build -c release --disable-sandbox"
command -v "$cc_bin" > /dev/null 2>&1 || fail "缺 C 编译器（$cc_bin）"

case "$(uname -s)" in
    Darwin) ext="dylib"; install_flag="-install_name @rpath/libpinistd.dylib" ;;
    *) ext="so"; install_flag="" ;;
esac

tmphint="${TMPDIR:-/tmp}"
work="$(mktemp -d "${tmphint%/}/pini-stdlib-c.XXXXXX")" || fail "建不了临时目录"
cleanup() {
    if [ "$keep" -eq 1 ]; then
        echo "保留工作目录：$work"
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT

mkdir -p "$work/lib" || fail "建不了 $work/lib"
# shellcheck disable=SC2086
"$cc_bin" -std=c11 -shared -fPIC $install_flag \
    -o "$work/lib/libpinistd.$ext" bootstrap/fixtures/stdlib-c/pini_std.c \
    || fail "C 内核编译失败"

case_pkg="bootstrap/tests/conformance/cases/stdlib-core/pkg"
[ -d "$case_pkg" ] || fail "缺语料包 $case_pkg"

for side in base cand; do
    cp -R "$case_pkg" "$work/$side" || fail "复制语料包失败"
    cp bootstrap/fixtures/stdlib-c/probe.pini "$work/$side/src/" || fail "放入对照程序失败"
done

# 候选侧只多两样：顶替文件并入入口，清单加 [ffi]；测试文件与语料一字未动。
cat bootstrap/fixtures/stdlib-c/cstd.pini >> "$work/cand/src/api.pini" || fail "并入顶替文件失败"
cat >> "$work/cand/pini.toml" <<'TOML'

[ffi]
abi = "C"
search_paths = ["../lib"]
libs = ["pinistd"]
TOML

normalize() {
    sed -E 's/范围 [^）]*/范围 <工作区>/' "$1"
}

# 甲段：同一份十八成员语料，两套装配的报告必须逐字节相同。
for side in base cand; do
    "$pini" test "$work/$side" > "$work/$side.test.out" 2> "$work/$side.test.err" \
        || fail "解释器通道测试失败（${side}）：$(head -3 "$work/$side.test.err")"
    "$pini" test-llvm "$work/$side" > "$work/$side.test-llvm.out" 2> "$work/$side.test-llvm.err" \
        || fail "LLVM 通道测试失败（${side}）：$(head -3 "$work/$side.test-llvm.err")"
done

if ! diff <(normalize "$work/base.test.out") <(normalize "$work/cand.test.out") > "$work/test.diff"; then
    sed -n '1,20p' "$work/test.diff" >&2
    fail "解释器通道的报告两侧不同（见上）"
fi
if ! diff <(normalize "$work/base.test-llvm.out") <(normalize "$work/cand.test-llvm.out") > "$work/test-llvm.diff"; then
    sed -n '1,20p' "$work/test-llvm.diff" >&2
    fail "LLVM 通道的报告两侧不同（见上）"
fi

# 生效证据：候选侧发射文本必须引用 C 符号，基线侧一处都不该有。
"$pini" emit "$work/cand/src/probe.pini" -o "$work/cand.ll" > /dev/null 2>&1 \
    || fail "候选侧发射失败"
"$pini" emit "$work/base/src/probe.pini" -o "$work/base.ll" > /dev/null 2>&1 \
    || fail "基线侧发射失败"
cand_calls="$(grep -c '@ps_' "$work/cand.ll")"
base_calls="$(grep -c '@ps_' "$work/base.ll")"
[ "$cand_calls" -gt 0 ] || fail "候选侧发射文本里没有 C 符号，顶替未生效"
[ "$base_calls" -eq 0 ] || fail "基线侧发射文本里出现 C 符号，两侧装配未隔离"

# 乙段：同一份读数程序两侧各跑一遍，按分段统计。
for side in base cand; do
    "$pini" run "$work/$side" > "$work/$side.run.out" 2> "$work/$side.run.err" \
        || fail "读数程序运行失败（${side}）：$(head -3 "$work/$side.run.err")"
done

split_section() {
    awk -v want="$2" '/^== /{on = ($0 == want); next} on' "$1"
}
split_section "$work/base.run.out" "== 一致区 ==" > "$work/base.same"
split_section "$work/cand.run.out" "== 一致区 ==" > "$work/cand.same"
split_section "$work/base.run.out" "== 分叉区 ==" > "$work/base.split"
split_section "$work/cand.run.out" "== 分叉区 ==" > "$work/cand.split"

if ! diff -u "$work/base.same" "$work/cand.same" > "$work/same.diff"; then
    sed -n '1,20p' "$work/same.diff" >&2
    fail "一致区出现分叉：ASCII 与中日韩口径本应一致"
fi
printf '一致区：%s 行全部相同\n' "$(wc -l < "$work/base.same" | tr -d ' ')"

awk 'NR == FNR {left[FNR] = $0; next} {print left[FNR] "\t" $0}' "$work/base.split" "$work/cand.split" > "$work/split.tsv"
same_total="$(awk -F'\t' '$1 == $2' "$work/split.tsv" | wc -l | tr -d ' ')"
diff_total="$(awk -F'\t' '$1 != $2' "$work/split.tsv" | wc -l | tr -d ' ')"
awk -F'\t' '$1 != $2 {split($1, p, "="); split(p[1], q, "|"); printf "  分叉 %s\n    基线 %s\n    候选 %s\n", q[1], $1, $2}' "$work/split.tsv"

printf '分叉区：%s 行相同、%s 行分叉（字素与码位的口径差，非缺陷）\n' "$same_total" "$diff_total"
printf '语料：两通道两侧报告逐字节相同；C 符号引用 %s 处，基线 %s 处\n' "$cand_calls" "$base_calls"
exit 0

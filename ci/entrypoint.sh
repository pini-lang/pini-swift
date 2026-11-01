#!/usr/bin/env bash
# Linux CI 流水线：门禁 → 构建 → 测试。
# 顺序不可调换：门禁是最便宜的一批判据，先红先停，避免为一次拼写错误付一次全量构建。
# 任何一步非零即整体非零，不吞退出码。
set -euo pipefail

cd "$(dirname "$0")/.."

step() {
    printf '\n=== %s ===\n' "$1"
    SECONDS=0
}

step "环境"
# 不以 root 跑：只读文件的权限判据在 root 下恒真，那一条会从「判据」退化成「空判」。
# 容器默认用户是 root，故由调用方用 `--user` 指定，此处只做兜底断言。
if [ "$(id -u)" -eq 0 ]; then
    echo "不应以 root 运行：权限类判据会失效。请用 --user \$(id -u):\$(id -g) 并设 HOME=/tmp。" >&2
    exit 1
fi
swift --version
printf 'clang: %s\n' "$(command -v clang || echo 缺失)"
printf 'lli:   %s\n' "$(command -v lli || echo 缺失)"
printf 'python3: %s\n' "$(python3 --version 2>&1)"

# 工具链自检：Package.swift 声明的最低工具链必须被满足。
# 不满足时给出「声明值 vs 实际值」两个数，而不是让 SwiftPM 抛一句解析失败。
declared="$(sed -n 's#.*swift-tools-version:\([0-9][0-9.]*\).*#\1#p' Package.swift | head -1)"
actual="$(swift --version | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
printf 'tools-version 声明: %s · 实际 Swift: %s\n' "${declared:-未知}" "${actual:-未知}"
if [ -z "$declared" ] || [ -z "$actual" ]; then
    echo "工具链自检无法读数，判为不通过" >&2
    exit 1
fi
if [ "$(printf '%s\n%s\n' "$declared" "$actual" | sort -V | head -1)" != "$declared" ]; then
    echo "工具链过旧：包声明 $declared，镜像是 $actual。换镜像，不要改包声明。" >&2
    exit 1
fi

# 缺工具链即失败：跳过在本地可以容忍，在 CI 不行 —— 否则「全绿」与「这批根本没跑」在读数上
# 长得一样。示例门禁与测试读同一位：前者缺 lli 时拒跑，后者缺产物时记失败。
export PINI_REQUIRE_TOOLCHAIN=1

step "注释门禁"
bash hooks/comment-lint.sh

step "文档链接门禁"
bash tools/check-doc-links.sh

step "IR 契约门禁"
python3 tools/ir-contract-check.py

step "运行时 ABI 门禁"
python3 tools/runtime-abi-check.py

step "内建清单门禁"
# 三方对照：运行时 ABI 契约 · 编译器清单 · CodeGen 的降级点。任一处不等即失败。
python3 tools/builtin-inventory-check.py

step "后端义务门禁（警告级）"
# 只报不拦：决策族归零之后，这个脚本用来盯「旧的判断有没有长回来」。
# 读数稳定一段再转硬拦截，好过在门禁上先红一次。
python3 tools/backend-duty-check.py

step "能力普查门禁"
# 拒绝所标的族必须等于该节点在契约里的小节：标错就把读者送到不含该节点的那一节。
python3 tools/capability-census.py --check

step "构建"
swift build --disable-sandbox

step "能力矩阵门禁"
# 表由各通道自报（pini backends），检出件与之逐行比对：改了能力声明不改表即红。
PINI_BIN="$PWD/.build/debug/pini" python3 tools/capability-matrix.py

step "示例门禁"
# 三腿：check / run / run-llvm。已知失败在 examples/gate-baseline.tsv，只许缩小。
PINI_BIN="$PWD/.build/debug/pini" python3 tools/examples-gate.py

step "差分探针门禁"
# 两通道对照：同一份语料在解释器与 LLVM 上必须读出同一串输出。已知缺口在
# tools/ir-parity-baseline.tsv，只许缩小 —— 某行转绿时这一步会红，提示删掉它。
# 镜像没有 lli 时明确跳过并说出原因：跳过不等于通过，故这一行必须打出来。
if [ -n "${PINI_LLVM_BIN:-}" ] || command -v lli >/dev/null 2>&1; then
    PINI_SWEEP_BIN="$PWD/.build/debug/pini" python3 tools/ir-parity-probe.py \
        --root examples --baseline tools/ir-parity-baseline.tsv
else
    echo "  跳过：镜像里没有 lli（未设 PINI_LLVM_BIN，PATH 里也没有）"
fi

step "测试"
# 测试里的命令行与 LLVM 判据从 `PiniTestEnvironment` 取产物（环境变量优先，仓根兜底）。
# 这里指向本次构建产物；「缺工具链即失败」已在文件开头打开。
export PINI_CLI_BIN="$PWD/.build/debug/pini"
swift test --disable-sandbox

printf '\n=== 全绿 ===\n'

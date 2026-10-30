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

step "注释门禁"
bash hooks/comment-lint.sh

step "文档链接门禁"
bash tools/check-doc-links.sh

step "IR 契约门禁"
python3 tools/ir-contract-check.py

step "运行时 ABI 门禁"
python3 tools/runtime-abi-check.py

step "后端义务门禁（警告级）"
# 只报不拦：所有权 pass 尚未落地，此刻必然有命中。接在这里是为了让推送即得读数，
# 归位后同一脚本应报零 —— 转硬拦截是那一步的事，不是今天。
python3 tools/backend-duty-check.py

step "构建"
swift build --disable-sandbox

step "测试"
swift test --disable-sandbox

printf '\n=== 全绿 ===\n'

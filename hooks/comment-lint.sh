#!/usr/bin/env bash
# hooks/comment-lint.sh — 注释门禁入口（预提交与 CI 共用）：探测 python3 后转交 tools/check-comment-lint.py，
# 缺解释器时响亮失败，不判过。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

py=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        py="$candidate"
        break
    fi
done
if [ -z "$py" ]; then
    echo "⛔ [注释门禁] 未找到 python3 —— 判据无法执行，不等于通过" >&2
    exit 1
fi

exec "$py" "$root/tools/check-comment-lint.py" "$@"

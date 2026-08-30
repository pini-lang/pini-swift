#!/usr/bin/env bash
# tools/check-doc-links.sh -- 校验文档内引用的文件路径真实存在（ADR-024 挂账 8）
#
# 动机：ADR-018 M1 只要求「逻辑引用」却不提供任何校验手段，跨仓引用腐烂不可检测，
#       是 pini-meta 失效的直接原因。本脚本补上这个结构性缺失的能力。
#
# 范围：docs/ 与仓库根的 *.md（跳过 examples/ —— selfhost 是嵌套独立仓，有自己的校验职责）
# 规则：抽取反引号包裹的、以 .md / .toml 结尾的路径 token；
#       依次按「文档所在目录」「仓库根」解析；都不存在时，若其 basename
#       在本仓 git 跟踪文件中存在 → 判「路径过时」（可操作，报错）；
#       否则视为外部示例 / 历史提及 / 跨项目引用（不报）。
# 退出码：发现路径过时引用 → 1（供 pre-commit / CI 门禁使用）
# 兼容：macOS 自带 bash 3.2（无 mapfile），全部使用 POSIX 级写法。

set -u
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 1

fail=0
checked=0
stale=0

# 仓内被跟踪文件的 basename 索引（「路径过时」判据）
basenames="$(git ls-files | awk -F/ '{print $NF}' | sort -u)"

cand="$( { find docs -name '*.md' -not -path '*/.build/*' 2>/dev/null; ls ./*.md 2>/dev/null; } | sort -u )"

for f in $cand; do
  [ -f "$f" ] || continue
  dir="$(dirname "$f")"
  # 反引号内的 .md/.toml 路径（排除含空格与 URL）
  refs="$(grep -oE '\`[^ \`[:space:]]+\.(md|toml)\`' "$f" 2>/dev/null | tr -d '\`' | sort -u)"
  for ref in $refs; do
    [ -n "$ref" ] || continue
    case "$ref" in
      pini.toml|*"<"*) continue ;;  # 概念名（语言清单文件名，见 project-spec §1）/ 占位符（deps/<name>/…），非路径引用
    esac
    checked=$((checked + 1))
    if [ -e "$dir/$ref" ] || [ -e "$root/$ref" ]; then
      continue
    fi
    base="${ref##*/}"
    if printf '%s\n' "$basenames" | grep -qxF "$base"; then
      echo "❌ 路径过时: $f -> \`$ref\`（目标在本仓：$(git ls-files "*$base" | head -1)）"
      stale=$((stale + 1))
      fail=1
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  echo "✅ 文档链接校验通过（检查 $checked 个引用）"
else
  echo "⛔ 文档链接校验失败（过时 $stale 处）" >&2
fi
exit "$fail"

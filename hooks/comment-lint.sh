#!/usr/bin/env bash
# hooks/comment-lint.sh — Pini 注释风格门禁（pini-comment-style-guide.md §7）
#
# 规则：
#   L1 行号禁止      注释内出现 `file.swift:NN` / `file.pini:NN` 式行号
#   L2 跨文件章节号  注释内出现 `spec/roadmap/草稿 §N` 式章节号
#   L3 文档名快照    注释内出现 `docs/*.md` 式文件名
#   L4 版本号叙事    注释内出现 `v0.NN` 式版本号
#   L5 裸待办        TODO/FIXME/HACK/XXX 未跟 issue-/ADR- 追踪 ID
#   L6 ID 可兑付     注释引用的 ADR-NNN 必须在 docs/adr-index.md 登记表可兑付
#
# 用法：hooks/comment-lint.sh [path...]   # 默认扫描 Sources Tests examples bench
# 依赖：ripgrep（无则回退 GNU/BSD grep -E）
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

if [ "$#" -eq 0 ]; then
  paths=(Sources Tests examples bench)
else
  paths=("$@")
fi
targets=()
for p in "${paths[@]}"; do
  [ -d "$p" ] && targets+=("$p")
done
if [ "${#targets[@]}" -eq 0 ]; then
  echo "⚠️  comment-lint: 无可扫描目录，跳过"
  exit 0
fi

# ADR-024 D2：.gitignore 锚定的嵌套独立仓（examples/selfhost）不属本仓扫描范围。
# 实测：rg 对嵌套 .git 边界内的文件不套用父仓 ignore 规则；grep 从不尊重 ignore。
# 显式排除（rg 用锚定全路径 glob，grep 用末段目录名），双后端行为一致。
excl_rg=()
excl_grep=()
if [ -f .gitignore ]; then
  while IFS= read -r line; do
    case "$line" in
      /*)
        d="${line%/}"
        excl_rg+=("--glob=!$d/**")
        excl_grep+=("--exclude-dir=${d##*/}")
        ;;
    esac
  done < <(grep -vE '^[[:space:]]*(#|$)' .gitignore 2>/dev/null)
fi

has_rg=0
command -v rg >/dev/null 2>&1 && has_rg=1

scan() { # $1=pattern，输出命中行
  local pat="$1"
  if [ "$has_rg" -eq 1 ]; then
    rg -n --glob '*.swift' --glob '*.pini' ${excl_rg[@]+"${excl_rg[@]}"} "$pat" "${targets[@]}" 2>/dev/null
  else
    grep -rEn --include='*.swift' --include='*.pini' ${excl_grep[@]+"${excl_grep[@]}"} "$pat" "${targets[@]}" 2>/dev/null
  fi
}

scan_o() { # $1=pattern，仅输出匹配片段（L6 用，无文件名前缀）
  local pat="$1"
  if [ "$has_rg" -eq 1 ]; then
    rg -o --no-filename --glob '*.swift' --glob '*.pini' ${excl_rg[@]+"${excl_rg[@]}"} "$pat" "${targets[@]}" 2>/dev/null
  else
    grep -rEoh --include='*.swift' --include='*.pini' ${excl_grep[@]+"${excl_grep[@]}"} "$pat" "${targets[@]}" 2>/dev/null
  fi
}

fail=0

check() { # $1=规则名 $2=pattern
  local name="$1" pat="$2" out n
  out="$(scan "$pat")"
  n=0
  [ -n "$out" ] && n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  if [ "$n" -gt 0 ]; then
    echo "❌ [$name] 命中 ${n} 处："
    echo "$out"
    fail=1
  else
    echo "✅ [$name] 通过"
  fi
}

check "L1 行号禁止"     '(//|///|;|#).*\.(swift|pini)?:[0-9]+'
check "L2 跨文件章节号" '^[[:space:]]*(//|///|;|#).*(spec|roadmap|草稿) §[0-9A-Z]'
check "L3 文档名快照"   '^[[:space:]]*(//|///|;|#).*[A-Za-z0-9_-]+\.md'
check "L4 版本号叙事"   '^[[:space:]]*(//|///|;|#).*v0\.[0-9]+'
check "L5 裸待办"       '(TODO|FIXME|HACK|XXX)'

# L6 ADR ID 兑付：登记表来自 docs/spec/adr/adr-index.md 首列（大小写不敏感匹配，堵小写盲区）
# ADR-024：登记表随语言级资产迁入 docs/spec/adr/；路径须与之一致，否则 L6 静默失效。
index_file="docs/spec/adr/adr-index.md"
registered="$(sed -nE 's/^\| (ADR-[0-9]+) \|.*/\1/p' "$index_file" 2>/dev/null | sort -u)"
if [ -z "$registered" ]; then
  echo "⚠️  [L6] 无法读取 ADR 登记表（$index_file），跳过"
else
  bad="$(scan_o '[Aa][Dd][Rr]-[0-9]+' | tr '[:lower:]' '[:upper:]' | sort -u | grep -vxF -f <(printf '%s\n' "$registered") || true)"
  if [ -n "$bad" ]; then
    echo "❌ [L6] 悬空 ADR ID（登记表不可兑付）："
    echo "$bad"
    fail=1
  else
    echo "✅ [L6] ADR ID 全部可兑付"
  fi
  lowercase="$(scan_o 'adr-[0-9]+' | sort -u)"
  if [ -n "$lowercase" ]; then
    echo "❌ [L6] 小写 adr- ID 引用（应统一为 ADR- 大写）："
    echo "$lowercase"
    fail=1
  fi
fi

if [ "$fail" -eq 1 ]; then
  echo "⛔ comment-lint 未通过：请按 pini-comment-style-guide.md §2/§3 修正注释（零语义变更）。"
  exit 1
fi
echo "🎉 comment-lint 全绿"
exit 0

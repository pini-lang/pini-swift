#!/usr/bin/env bash
# tools/check-doc-links.sh — 校验文档中反引号包裹的 `.md` / `.toml` 引用是否真实存在。
# 判据：目标在本仓被跟踪却不在所写位置 ⇒ 路径过时；basename 命中 `git log --diff-filter=D` 集合 ⇒ 引用空缺载体。
# 豁免：同一行写明「不在本仓」的引用是墓碑式说明，放行。

set -u
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 1

fail=0
checked=0
stale=0
gone=0

# 仓内被跟踪文件的 basename 索引（「路径过时」判据）
basenames="$(git ls-files | awk -F/ '{print $NF}' | sort -u)"
# diff-filter=D 集合的 basename 索引（「引用空缺载体」判据）
deleted_basenames="$(git log --all --diff-filter=D --name-only --pretty=format: -- docs README.md 2>/dev/null \
  | awk -F/ 'NF {print $NF}' | sort -u)"

cand="$( { find docs -name '*.md' -not -path '*/.build/*' 2>/dev/null; ls ./*.md 2>/dev/null; } | sort -u )"

for f in $cand; do
  [ -f "$f" ] || continue
  dir="$(dirname "$f")"
  # 反引号内的 .md/.toml 路径（排除含空格与 URL）；带行号，供墓碑豁免判行
  refs="$(grep -noE '\`[^ \`[:space:]]+\.(md|toml)\`' "$f" 2>/dev/null | sort -u)"
  for entry in $refs; do
    lineno="${entry%%:*}"
    ref="${entry#*:}"
    ref="${ref//\`/}"
    [ -n "$ref" ] || continue
    case "$ref" in
      pini.toml|*"<"*) continue ;;  # 概念名（语言清单文件名，见 project-spec §1）/ 占位符（deps/<name>/…），非路径引用
    esac
    checked=$((checked + 1))
    if [ -e "$dir/$ref" ] || [ -e "$root/$ref" ]; then
      continue
    fi
    base="${ref##*/}"
    # 仓外路径先判「同级目录里存在吗」：存在即真路径，直接通过。
    # 不能先走 basename 判据——两仓同名文件会被误判成「本仓某处存在」而报假红。
    if [ -e "$(dirname "$root")/$ref" ]; then
      continue
    fi
    if printf '%s\n' "$basenames" | grep -qxF "$base"; then
      echo "❌ 路径过时: $f:$lineno -> \`$ref\`（目标在本仓：$(git ls-files "*$base" | head -1)）"
      stale=$((stale + 1))
      fail=1
      continue
    fi
    if printf '%s\n' "$deleted_basenames" | grep -qxF "$base"; then
      if sed -n "${lineno}p" "$f" | grep -q "不在本仓"; then
        continue
      fi
      echo "⛔ 引用空缺载体: $f:$lineno -> \`$ref\`（该件不在本仓；要么改指向，要么在该行写明「不在本仓」）" >&2
      gone=$((gone + 1))
      fail=1
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  echo "✅ 文档链接校验通过（检查 $checked 个引用）"
else
  echo "⛔ 文档链接校验失败（过时 $stale 处 · 空缺载体 $gone 处）" >&2
fi
exit "$fail"

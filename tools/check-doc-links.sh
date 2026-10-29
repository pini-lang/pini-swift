#!/usr/bin/env bash
# tools/check-doc-links.sh — 校验文档中反引号包裹的 `.md` / `.toml` 引用是否真实存在。
# 解析顺序：文档所在目录 → 仓库根；basename 命中本仓跟踪文件即判「路径过时」（报错），否则视为外部引用。
# 已知盲区：文件名整体写错时落到豁免分支，故它守的是改名与移位，不是笔误。

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
    # 仓外路径先判「同级目录里存在吗」：存在即真路径，直接通过。
    # 不能先走 basename 判据——两仓同名文件会被误判成「本仓某处存在」而报假红。
    if [ -e "$(dirname "$root")/$ref" ]; then
      continue
    fi
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

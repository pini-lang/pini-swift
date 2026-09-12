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
# 依赖：ripgrep 优先（探测顺序：PINI_RG → PATH → 常见安装位置），无则回退 grep -E。
#   ⚠️ 回退路径在「命令被沙箱代理存根接管」的环境里会慢约 80 倍（实测单趟 79 秒 vs 0 秒），
#   本脚本有 7 趟全树扫描 ⇒ 整条门禁从 1 秒膨胀到 ~9 分钟。故探测不只看 PATH。
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

# ripgrep 探测。不能只查 PATH：rg 已安装却不在 PATH 时，脚本会静默回退到 grep，
# 而那在「grep 被沙箱代理存根接管」的环境里慢约 80 倍（每文件一次 IPC）。实测同一棵树、
# 同一模式：rg 0 秒 / 存根 grep 79 秒，7 趟 scan 即 ~9 分钟 vs 1 秒。
# 探测顺序：PINI_RG（显式指定，供 CI 与非常规安装位置）→ PATH → 常见绝对路径。
# 若最终仍无 rg，探测结果为空 ⇒ has_rg=0 ⇒ 回退 grep（功能不变，仅慢）。
rg_bin=""
if [ -n "${PINI_RG:-}" ] && [ -x "${PINI_RG}" ]; then
  rg_bin="$PINI_RG"
elif command -v rg >/dev/null 2>&1; then
  rg_bin="$(command -v rg)"
else
  for cand in /opt/homebrew/bin/rg /usr/local/bin/rg /usr/bin/rg; do
    if [ -x "$cand" ]; then
      rg_bin="$cand"
      break
    fi
  done
fi

has_rg=0
[ -n "$rg_bin" ] && has_rg=1

# 两个后端须**判据等价**（否则换后端就换结论）。差异有二：
#   1. 隐藏目录：rg 默认跳过，grep 无此概念 ⇒ rg 侧补 --hidden 对齐。
#   2. .gitignore：脚本已自行把规则转成 excl_rg/excl_grep 显式排除参数，两侧本就对齐。
# 实测真仓：rg(无 --hidden) / rg(--hidden) / grep 三者命中的 ADR 引用集合完全相同（各 20 条）。
scan() { # $1=pattern，输出命中行
  local pat="$1"
  if [ "$has_rg" -eq 1 ]; then
    "$rg_bin" -n --hidden --glob '*.swift' --glob '*.pini' ${excl_rg[@]+"${excl_rg[@]}"} "$pat" "${targets[@]}" 2>/dev/null
  else
    grep -rEn --include='*.swift' --include='*.pini' ${excl_grep[@]+"${excl_grep[@]}"} "$pat" "${targets[@]}" 2>/dev/null
  fi
}

scan_o() { # $1=pattern，仅输出匹配片段（L6 用，无文件名前缀）
  local pat="$1"
  if [ "$has_rg" -eq 1 ]; then
    "$rg_bin" -o --no-filename --hidden --glob '*.swift' --glob '*.pini' ${excl_rg[@]+"${excl_rg[@]}"} "$pat" "${targets[@]}" 2>/dev/null
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
# ADR-024：登记表随语言级资产迁入 docs/spec/adr/；路径须与之一致。
index_file="docs/spec/adr/adr-index.md"
registered="$(sed -nE 's/^\| (ADR-[0-9]+) \|.*/\1/p' "$index_file" 2>/dev/null | sort -u)"
# 登记表读不到 = 判据**入口**失效，必须报错。此处原是 `⚠️ 跳过`（rc=0）—— 与下面
# 「未扫到任何 ADR 引用」属同一类假绿：该报错的情形被输出成了一次通过。
if [ -z "$registered" ]; then
  echo "❌ [L6] 无法从 $index_file 读到任何已登记 ADR：登记表缺失或格式漂移（不等于「全部可兑付」）"
  fail=1
else
  refs="$(scan_o '[Aa][Dd][Rr]-[0-9]+' | tr '[:lower:]' '[:upper:]' | sort -u)"
  # 扫描未生效必须报出来 —— 「没扫到」与「全都合规」在输出上无法区分，混同即假绿。
  if [ -z "$refs" ]; then
    echo "❌ [L6] 未扫到任何 ADR 引用：扫描未生效（不等于「全部可兑付」）"
    fail=1
  else
    # 兑付判定不用 grep -f 的进程替换：沙箱禁止 /dev/fd ⇒ 该 grep 失败，若再挂 `|| true`
    # 就会被吞成「bad 为空 ⇒ 全部可兑付」。也不用 awk -v 传多行表（BSD awk 报
    # `newline in string`，同样会退化成 bad 为空）。改用纯 bash 比对：无外部命令、
    # 无临时文件、无进程替换 —— 这一层**没有可静默失败的执行体**。
    ok_flat=" $(printf '%s\n' "$registered" | tr '\n' ' ') "
    bad=""
    for id in $refs; do
      case "$ok_flat" in
        *" $id "*) ;;
        *) bad="$bad$id"$'\n' ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "❌ [L6] 悬空 ADR ID（登记表不可兑付）："
      echo "$bad"
      fail=1
    else
      echo "✅ [L6] ADR ID 全部可兑付"
    fi
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

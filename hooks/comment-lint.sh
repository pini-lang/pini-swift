#!/usr/bin/env bash
# hooks/comment-lint.sh — Pini 注释风格门禁（pini-comment-style-guide.md §7）
#
# 规则：
#   L1 行号禁止      注释内出现 `file.swift:NN` / `file.pini:NN` 式行号
#   L2 跨文件章节号  注释内出现 `spec/roadmap/草稿 §N` 式章节号
#   L3 文档名快照    注释内出现 `docs/*.md` 式文件名
#   L4 版本号叙事    注释内出现 `v0.NN` 式版本号
#   L5 裸待办        TODO/FIXME/HACK/XXX 未跟 issue-/ADR- 追踪 ID
#   L6 ID 可兑付     注释引用的 ADR-NNN 必须在 docs/spec/adr/ 有同编号文件（无索引表；编号自 001 起）
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

# 自举入树为独立嵌套仓：.gitignore 锚定的嵌套独立仓（examples/selfhost）不属本仓扫描范围。
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

# ripgrep 探测。不能只查 PATH：「工具装着但 PATH 里看不见」在本仓已有前科 ——
# LLVM 后端重写 约束 6 记载 `command -v lli` 曾两次造出假「门关」结论，并规定
# 「自动化/代理环境的默认 PATH 不得作为依据」。此处同族：rg 装着却不在 PATH ⇒
# 静默回退 grep，而本机 PATH 的 grep 是沙箱代理存根（每文件一次 IPC）⇒ 慢约 80 倍。
# 实测同一棵树、同一模式：rg 0 秒 / 存根 grep 79 秒，7 趟 scan 即 ~9 分钟 vs 1 秒。
# 探测顺序：PINI_RG（显式指定，见 GIT_WORKFLOW §5.2）→ PATH → 绝对路径候选。
# ⚠️ 候选表的**作用域只有一种情形**：macOS Homebrew 装了 rg 但 brew bin 未进 PATH。
# Linux 上经 apt/snap 安装的 rg 必在 PATH（command -v 先命中），候选不会生效 ——
# 它是 macOS 例外通道，不是跨平台兜底。各端实况：CI 的 Ubuntu 容器不装 rg ⇒
# 走 grep 后端，候选路径全不存在 ⇒ 行为与加候选之前一致（不引入新的失败面）。
# 若最终仍无 rg，探测结果为空 ⇒ has_rg=0 ⇒ 回退 grep（判据等价，仅慢）。
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

# 后端选择要**可见**：多端下走的后端不同（CI 无 rg ⇒ grep；macOS+Homebrew ⇒ rg），
# 静默回退会让「哪端实际跑了哪条路径」只能靠推理 —— 出问题时无从判断。判据已比对等价，
# 故这里只提示、不阻断。两后端各有真实执行点：rg 分支 = 本机提交，grep 分支 = CI。
if [ "$has_rg" -eq 0 ]; then
  echo "ℹ️  [后端] 未找到 ripgrep，回退 grep -E（判据等价，仅速度不同；PINI_RG=<path> 可指定）"
fi

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

# L6 ADR ID 兑付：**登记表就是文件本身** —— 兑付判据 = `docs/spec/adr/adr-NNN-*.md` 是否存在于该编号。
# ⚠️ 2026-09-19 编号重置：旧一批（018–043）连同其文件退役，全仓引用已改写为主题词 ⇒ 当前**零引用、
# 零文件**是**合法状态**，故本条不再把「扫不到 ADR」判失败（那正是重置前的形态）。
# 判据三条，缺一即假绿：
#   ① **阳性对照**：合成样本必须被同一抽取式命中 —— 否则「扫不到引用」与「全都合规」不可区分；
#   ② 零引用合法（清除后的常态），有引用才进入兑付；
#   ③ 有引用而**无可兑付文件**（或目录不存在）⇒ 拦。
# 「另设一张索引表」的做法已废止：索引与文件是同一事实的两份副本，而副本必然漂移。
adr_dir="docs/spec/adr"

# ① 阳性对照：与 scan_o 用同一抽取工具，喂一个必然出现的合成样本。
probe_match() {
  if [ "$has_rg" -eq 1 ]; then
    printf 'ADR-777\n' | "$rg_bin" -o '[Aa][Dd][Rr]-[0-9]+' 2>/dev/null
  else
    printf 'ADR-777\n' | grep -Eo '[Aa][Dd][Rr]-[0-9]+' 2>/dev/null
  fi
}

if [ -z "$(probe_match)" ]; then
  echo "❌ [L6] 抽取式失灵（阳性对照未命中合成样本）：不等于「全部可兑付」"
  fail=1
else
  refs="$(scan_o '[Aa][Dd][Rr]-[0-9]+' | tr '[:lower:]' '[:upper:]' | sort -u)"
  if [ -z "$refs" ]; then
    echo "✅ [L6] 无 ADR 引用（编号已重置，当前无在册 ADR）"
  else
    # 兑付集 = 目录下的文件名（大小写不敏感、去零填充差异）
    registered=""
    if [ -d "$adr_dir" ]; then
      registered="$(ls "$adr_dir" 2>/dev/null \
        | sed -nE 's/^[Aa][Dd][Rr]-([0-9]+)-.*$/\1/p' \
        | sed -E 's/^0*([0-9]+)$/\1/' | sort -u)"
    fi
    ok_flat=" $(printf '%s\n' "$registered" | tr '\n' ' ') "
    bad=""
    for id in $refs; do
      n="$(printf '%s' "$id" | sed -E 's/^ADR-0*([0-9]+)$/\1/')"
      case "$ok_flat" in
        *" $n "*) ;;
        *) bad="$bad$id"$'\n' ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "❌ [L6] 悬空 ADR ID（无同编号文件可兑付）："
      echo "$bad"
      echo "     兑付判据 = $adr_dir/adr-<编号>-<slug>.md 存在；目录当前$([ -d "$adr_dir" ] && echo '存在' || echo '不存在')。"
      fail=1
    else
      echo "✅ [L6] ADR ID 全部可兑付（$adr_dir 同编号文件）"
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

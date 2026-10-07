#!/usr/bin/env bash
# tools/check-doc-links.sh -- 校验文档内引用的文件路径真实存在（规范治理归位 挂账 8）
#
# 动机：自举验证契约 M1 只要求「逻辑引用」却不提供任何校验手段，跨仓引用腐烂不可检测，
#       是 pini-meta 失效的直接原因。本脚本补上这个结构性缺失的能力。
#
# 范围：docs/ 与仓库根的 *.md（跳过 examples/ —— selfhost 是嵌套独立仓，有自己的校验职责）
# 规则：抽取反引号包裹的、以 .md / .toml 结尾的路径 token；
#       依次按「文档所在目录」「仓库根」解析；都不存在时，若其 basename
#       在本仓 git 跟踪文件中存在 → 判「路径过时」（可操作，报错）；
#       否则视为外部示例 / 历史提及 / 跨项目引用（不报）。
#
# ⛔⭐ **已知盲区（2026-10-07 实测，⛔ 不许被「本件绿」盖掉）**：**判不出「文件名已不存在」**。
#   判据③ 的左端是「basename ∈ 本仓 git 跟踪文件」⇒ 一旦引用的**文件名整个不存在了**
#   （如把 `docs/CHANGELOG.md` 写成 `docs/CHANGELOG_NOPE.md`），它落进豁免分支 ⇒ **报绿**。
#   ⚠️ 实测证据：在**未改动**的本件上注入该变异，读数仍是「通过（249 个引用）」⇒ 与任何改动无关。
#   ⇒ 后果：**「笔误写错文件名」这类腐烂，本件抓不到**。它能抓的是「文件改名/移位」
#     （basename 还在、路径过时）—— 那才是它的设计目标。
#   ⚠️ 迁仓带来的**新形态**：指向平级自举仓的路径（形如 `pini-bootstrap/src/…`）在本仓根下
#     不存在 ⇒ **一律落豁免** ⇒ 本件**判不出它们是否真的存在**。
#     ⚠️ 曾试补一条「同级目录里存在即通过」的判据 ⇒ **两次变异都无法证伪它会红**
#     ⇒ 按「不能证明活着的判据是摆设」把它撤掉了。
#     ⇒ 那些路径的存在性**目前无机械判据**，靠人核（迁仓时逐条验过）。
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
    # ⚠️⚠️ **仓外优先判定**（2026-10-07 迁仓后必需，实测依据）：
    #   自举仓迁为**平级**（仓外）⇒ 本仓件里指向它的路径（形如 `pini-bootstrap/src/…`）
    #   在本仓根下**不存在**。
    #   ⛔ 而下面的判据③用的是「**basename** ∈ 本仓跟踪文件」⇒ 仓外路径的 basename
    #   常与本仓某个文件**同名**（如两仓都有 `README.md`）⇒ 于是它被**误判**成
    #   「路径过时，该文件在本仓某处」⇒ **假红**（实测：删掉旧副本后立即出现 3 条）。
    # ⇒ 故先判「**同级目录**里存在吗」—— 存在即真路径 ⇒ 通过，⛔ 不进判据③。
    #   ⚠️ 判据左端**不是**「本仓跟踪文件」而是「文件系统实况」⇒ 这一次**可证伪**：
    #   把路径改回已删的旧坐标 ⇒ 同行目录里不存在 ⇒ 落进判据③ ⇒ 报红。
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

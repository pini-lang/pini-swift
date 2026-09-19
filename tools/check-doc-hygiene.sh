#!/usr/bin/env bash
# tools/check-doc-hygiene.sh -- 决策记录正文的卫生门禁（「零文件级引用」）
#
# 动机：注释风格门禁只扫源码（*.swift / *.pini），`docs/**` 一行都不扫 ⇒ 决策记录在
#       「门禁全绿」的掩护下写满会腐烂的引用（实测：首条 ADR 一次留下 9 处 + 文件头述旧况 1 处）。
#       本脚本补上这个结构性缺失的能力 —— 与 check-doc-links.sh 互补：
#       后者判「路径是否存在」，本脚本判「**该不该写路径**」。
#
# 域：`docs/spec/adr/*.md`（**结论件**）。域为什么这么窄，见该目录 README「正文卫生」：
#      按**寿命方向**定域，不按「是不是文档」定域 ——
#      规范 / 参考是**权威源**（互引是职责，登记表里的版本号是**权威数据**）；
#      变更记录的版本叙事**就是它的内容**；提案 / 落地计划是**工作件**，指向过程材料是本职。
#
# 规则（全部只作用于「过滤后正文」，见下）：
#   D1 文档路径    反引号包裹的 .md/.toml 路径（命名模式如 adr-NNN-*.md 天然不命中）
#   D2 跨文件章节号 主题词（规范/契约/计划/指南/手册/台账/参考/记录）直接跟 §N
#   D3 裸节号      §N 不在**本文已声明节**之内（引用 − 声明 差集）
#   D4 版本号叙事   v0.NN
#
# 豁免（**显式豁免，不是漏洞**）：
#   ① 围栏代码块内的行 —— 要么是可执行指令（目标没了会**报错**、看得见），要么是引例；
#   ② 行内含反例记号 ❌ 的行 —— 讲规则必须举反例，否则规则说不清；
#   ③ 命名模式 / 占位符 —— 由 D1 正则天然排除（要求 .md 前是字母数字或 `_` `-`）。
#
# 判据纪律（本仓反复踩过）：
#   * **阳性对照**：合成样本必须被同一抽取式命中 —— 否则「扫不到」与「全都合规」不可区分。
#   * **字节安全**：CI 是 ubuntu 容器、locale 可能是 C 而非 UTF-8 ⇒ 抽取式里**不得出现
#     含多字节字符的字符类**（如 `[^。]{0,12}`）。实测：那种写法在字节语义下按**字节数**限距，
#     同一份文件在本机（UTF-8）与 CI 会得出**不同结论**。故 D2 用「主题词直接跟 §」，
#     多字节只作**字面量**出现（字面量按字节比较，两端一致）。
#   * D2 与 D3 **互补，缺一即漏**（实测：D2 看不见无主题词的裸 §；D3 看不见与本文节号撞号的跨文件引用）。
#
# 退出码：发现违规 → 1（供 pre-commit / CI 门禁使用）
# 兼容：macOS 自带 bash 3.2（无 mapfile）+ BSD awk，全部使用 POSIX 级写法。

set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

# 域 = **结论件**（决策记录） + **规则载体**（注释风格指南）。依据见指南 §10.1。
# ⚠️ 域用**显式清单**而非宽 glob：宽 glob 会把权威源 / 记录件 / 工作件一并卷进来（那些大多合法）。
# ⚠️ 清单里的路径**缺失即报错**：否则某天改名后域会**静默缩小**，「全绿」就成了假绿。
DOMAIN_DIRS=("docs/spec/adr")
DOMAIN_FILES=("docs/spec/pini-comment-style-guide.md")

docs=""
missing=""
for d in "${DOMAIN_DIRS[@]}"; do
  if [ -d "$d" ]; then
    docs="$docs$(ls "$d"/*.md 2>/dev/null | sort)"$'\n'
  else
    missing="$missing$d（目录不存在）"$'\n'
  fi
done
for f in "${DOMAIN_FILES[@]}"; do
  if [ -f "$f" ]; then
    docs="$docs$f"$'\n'
  else
    missing="$missing$f（文件不存在）"$'\n'
  fi
done
docs="$(printf '%s\n' "$docs" | grep . | sort -u)"

if [ -n "$missing" ]; then
  echo "❌ [文档卫生] 域内载具缺失 —— 拒绝在「域被静默缩小」的状态下判过：" >&2
  printf '%s' "$missing" | sed 's/^/     /' >&2
  echo "   若确已改名，请同步更新本脚本的域清单。" >&2
  exit 1
fi

if [ -z "$(printf '%s\n' "$docs" | grep . || true)" ]; then
  echo "✅ [文档卫生] 域内无文档，跳过"
  exit 0
fi

# ── 阳性对照：先证明抽取式活着 ────────────────────────────────────────────
# 「扫不到」与「全都合规」外观完全相同；抽取式失灵必须**响亮地失败**，不能静默判过。
probe='语言规范 §1.3'
if ! printf '%s\n' "$probe" | grep -qE '(规范|契约|计划|指南|手册|台账|参考|记录)[[:space:]]*§([0-9]|[A-MO-Z])'; then
  echo "❌ [文档卫生] 抽取式失灵（阳性对照未命中合成样本）：不等于「全都合规」" >&2
  exit 1
fi
# 第二重阳性对照：占位符必须**不**命中（否则 `§N` 这类写法会满屏误报）
if printf '%s\n' '语言规范 §N' | grep -qE '(规范|契约|计划|指南|手册|台账|参考|记录)[[:space:]]*§([0-9]|[A-MO-Z])'; then
  echo "❌ [文档卫生] 判据失真：占位符 §N 被当成真节号（阴性对照未通过）" >&2
  exit 1
fi

fail=0
checked=0
tmp="$(mktemp)" || exit 1
trap 'rm -f "$tmp"' EXIT

# 过滤后正文：去掉围栏代码块与反例记号行，保留原始行号（`行号:内容`）
# 反射例记号 ❌（U+274C）以**字面量**参与匹配，按字节比较，两端一致。
body() {
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    index($0, "❌") > 0 { next }
    { printf "%d:%s\n", NR, $0 }
  ' "$1"
}

# 声明集：全文标题里的节号（围栏内不会有标题，故不做过滤）
declared() {
  awk 'match($0, /^#+ *[0-9]+(\.[0-9]+)*/) {
         s = substr($0, RSTART, RLENGTH)
         sub(/^#+ */, "", s)
         if (s != "") print s
       }' "$1" | sort -u
}

# 引用集：过滤后正文里的 §N（D3 用）
# ⚠️ §（U+00A7）在 UTF-8 下是 **2 字节**，而 § 之后全是 ASCII ⇒ 跳过 2 字节、长度减 2。
#    这段按字节算，locale 无关（本机 UTF-8 与 CI 的 C locale 结论一致）。
referenced() {
  awk '{ while (match($0, /§[0-9]+(\.[0-9]+)*/)) {
           print substr($0, RSTART + 2, RLENGTH - 2)
           $0 = substr($0, RSTART + RLENGTH)
         } }'
}

report() { # $1=规则 $2=文件 $3=命中行（形状 `<真实行号>:<内容>`）
  local n
  n="$(printf '%s\n' "$3" | grep -c . || true)"
  echo "❌ [$1] $2 —— 命中 $n 处（行号 = 文件真实行号）："
  printf '%s\n' "$3" | cut -c1-160 | sed 's/^/     /'
  fail=1
}

# 统一的命中形态：`<真实行号>:<原文>`。
# ⚠️ grep -n 给的是**过滤后临时文件**的行号（围栏/引例行被剔过，会错位），
#    故当场剥掉，只留 body 写入的**原文行号**。
mk() { grep -nE "$1" "$tmp" | sed 's/^[0-9][0-9]*://'; }

for f in $docs; do
  checked=$((checked + 1))
  body "$f" > "$tmp"

  # ── D1 文档路径：反引号包裹的 .md / .toml ──
  # 要求扩展名前是 [A-Za-z0-9_-] ⇒ `adr-NNN-*.md` / `adr-<slug>.md` 这类命名模式天然不命中。
  hits="$(mk '`[^`]*[A-Za-z0-9_-]\.(md|toml)`' || true)"
  [ -n "$hits" ] && report "D1 文档路径" "$f" "$hits"

  # ── D2 跨文件章节号：主题词直接跟 §N ──
  # 两处必须**显式排除**，否则会误报（都是实测踩出来的）：
  #   ① 「本X §0」这类**本文自引** —— 先把「本+主题词」整段剥掉再匹配；
  #      （剥字面量、按字节比较，故 locale 无关；不能用 `[^本]` 字符类 —— 多字节字符类在 C locale 下失效）
  #   ② `§N` 占位符 —— N 是本仓的「数字占位」约定（与 `adr-NNN-*.md` / `G##` 同族），
  #      故节号位要求**数字或非 N 的大写字母**：`§([0-9]|[A-MO-Z])`。
  hits="$(body "$f" | awk '
    { orig = $0
      line = orig
      sub(/^[0-9]+:/, "", line)
      gsub(/本(规范|契约|计划|指南|手册|台账|参考|记录)/, "", line)
      if (match(line, /(规范|契约|计划|指南|手册|台账|参考|记录)[[:space:]]*§([0-9]|[A-MO-Z])/)) print orig
    }')"
  [ -n "$hits" ] && report "D2 跨文件章节号" "$f" "$hits"

  # ── D3 裸节号：引用 − 声明 差集 ──
  refs="$(referenced < "$tmp" | sort -u)"
  decl="$(declared "$f")"
  if [ -n "$refs" ]; then
    if [ -n "$decl" ]; then
      bare="$(comm -13 <(printf '%s\n' "$decl") <(printf '%s\n' "$refs"))"
    else
      bare="$refs"
    fi
    if [ -n "$bare" ]; then
      pat="$(printf '%s\n' "$bare" | sed 's/\./\\./g' | paste -sd'|' -)"
      hits="$(mk "§($pat)([^0-9.]|$)" || true)"
      [ -n "$hits" ] && report "D3 裸节号（本文无此节）" "$f" "$hits"
    fi
  fi

  # ── D4 版本号叙事 ──
  hits="$(mk 'v[0-9]+\.[0-9]+' || true)"
  [ -n "$hits" ] && report "D4 版本号叙事" "$f" "$hits"
done

if [ "$fail" -eq 0 ]; then
  echo "✅ [文档卫生] 通过（检查 $checked 个决策记录文件；判据 D1–D4 + 阳性对照）"
else
  echo "⛔ [文档卫生] 未通过：决策记录正文须「零文件级引用」——" >&2
  echo "   把跨文件章节号改成主题词、去掉版本号与路径，只留符号型稳定 ID。" >&2
  echo "   细则见 docs/spec/adr/README.md「正文卫生」。" >&2
fi
exit "$fail"

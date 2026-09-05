# 缺陷候选：trait 块终止性——trait 块后接任何后续顶级声明解析失败

- 状态：**Open（2026-09-05 勘测立案，本批不修）**
- 发现来源：spec 反录入勘测（`docs/spec/issue/issue-spec-backfill-survey-2026-09-05.md` 矩阵 #13）

## 复现（探针见 `probes-backfill-2026-09-05/`）

- `p23-trait-terminate.pini`：`<显示>` 块（无体抽象方法 `描述|self() -> (String,)`）+ 空行 + `(盒)` 结构块 → 解析失败（「无效的表达式」）。
- `p24-trait-terminate-body.pini`：trait 方法带体（`:` 块）→ 同样失败。
- `p21-ext-constraint.pini`：trait 块 + `((盒:显示))` 扩展块 → 失败于 `((` 行（E2-002）。
- 对照 `p21a.pini`：**无 trait 块**时 `((盒:形状))` 单独解析正常——排除扩展块自身问题，锁定 trait 体循环终止条件（parseTraitDecl 未把 `((`/`{{`/`[[`/`<<`/`(` 行首声明识别为体终止）。

## 影响

trait 现状使用面窄（示例与语料未踩中），缺陷潜伏；一旦 trait 与其他顶级声明共存于同文件即触发。trait 块写在文件末尾可绕过。

## 修复方向（供实施批参考）

parseTraitDecl 的方法体循环终止条件需对齐 parseExtensionDecl 的同型判断（`isTopLevelDeclStart()` 类检查——扩展块在 L735 用 `else if isTopLevelDeclStart() { break }` 收束，trait 体循环疑似缺失对行首 `(` / `((` 的收束）。

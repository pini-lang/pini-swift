# 缺陷候选：trait 块终止性——trait 块后接任何后续顶级声明解析失败

- 状态：**Closed（2026-09-06 修复落地，见文末落地记录）**
- 发现来源：spec 反录入勘测（`docs/spec/issue/archive/issue-spec-backfill-survey-2026-09-05.md` 矩阵 #13）

## 复现（探针见 `probes-backfill-2026-09-05/`）

- `p23-trait-terminate.pini`：`<显示>` 块（无体抽象方法 `描述|self() -> (String,)`）+ 空行 + `(盒)` 结构块 → 解析失败（「无效的表达式」）。
- `p24-trait-terminate-body.pini`：trait 方法带体（`:` 块）→ 同样失败。
- `p21-ext-constraint.pini`：trait 块 + `((盒:显示))` 扩展块 → 失败于 `((` 行（E2-002）。
- 对照 `p21a.pini`：**无 trait 块**时 `((盒:形状))` 单独解析正常——排除扩展块自身问题，锁定 trait 体循环终止条件（parseTraitDecl 未把 `((`/`{{`/`[[`/`<<`/`(` 行首声明识别为体终止）。

## 影响

trait 现状使用面窄（示例与语料未踩中），缺陷潜伏；一旦 trait 与其他顶级声明共存于同文件即触发。trait 块写在文件末尾可绕过。

## 修复方向（供实施批参考）

parseTraitDecl 的方法体循环终止条件需对齐 parseExtensionDecl 的同型判断（`isTopLevelDeclStart()` 类检查——扩展块在 L735 用 `else if isTopLevelDeclStart() { break }` 收束，trait 体循环疑似缺失对行首 `(` / `((` 的收束）。

## 落地记录（2026-09-06）

- 根因（实测修正了本工单「修复方向」的符号定位）：终止检查 `if isTopLevelDeclStart() { break }` **存在于** parseTraitDecl（L1624），但被包在 `if justDedented` 门内——顶格方法（spec 合法形态，trait-method 顶格）与后续顶级声明间**无 dedent**，检查被整体跳过，`(盒)` 掉进 trait 变量签名分支报错。扩展块循环（parseExtensionDecl）的收束是无条件的，两者不对齐。
- 修复（一行级）：方法分支之后的 else 分支前加 `else if isTopLevelDeclStart() { break }`——非 IDENT 开头的顶级声明（结构块/扩展块/对象糖/import/export/后续特征块）一律收束 trait 体；方法分支在前不受影响。
- 实测：p23/p24/p21 三探针 PASS；双带体方法回归 PASS（该路径 dedent 由 parseBlock 消费、justDedented=false 进方法分支，与修复无交集）；双抽象方法+结构块 PASS。
- GCT 三钉：testProductionsTraitBodyTerminatedByStructDecl / testProductionsTraitBodyTerminatedByExtensionDecl / testProductionsTraitMultipleMethodsWithBodies（回归钉）；夹具同名入库。
- spec：trait-body 产生式加终止注记；**IDENT 同形歧义登记**（trait 后直接跟顶级裸函数会被吸收为 trait-method——spec `{ trait-method }` 贪婪语义与宿主一致，属语法设计欠定义而非本缺陷，规避法已注记；若需消除须 spec §1.3 立项）。
- 证据：E-129。

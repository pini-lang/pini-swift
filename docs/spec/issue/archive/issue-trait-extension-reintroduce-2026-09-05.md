# 特征扩展 `<<T>>` 重新引入提案（spec §1.3）

- 状态：**Closed（2026-09-06 用户裁决采纳，方案 B 行首双 token 对已落地）**
- 提案日：2026-09-05（修正批）
- 提案人：用户意见 + 勘测复核

## 背景

- 2026-09-05 批③ 曾以「词法层 `<<`/`>>` 恒合并为移位 token，特征扩展形态不可达（E2-006）」为由从 spec §A `extension-decl` 移除 `'<<' IDENT '>>' trait-body` 产生式（宿主 dispatch 分支保留但注释改标死面）。
- 用户裁决推翻该结论：**词法不可达不成立**——可通过对换行 peek/lookahead 消歧：仅当 `<<` 出现在**行首/换行后**（语句起始位）才识别为特征扩展记号，行内 `<<` 维持移位运算符。这与既有「行首双定界符 → 扩展块」的行导向分派（规则 3.2/3.14，`((`/`{{`/`[[` 同族）一致。
- 草稿含此意图（特征扩展块），批③移除属对「草稿意图未实现」条目做了反向处置——已回退：spec 产生式已恢复，Parser 分派注释已还原。

## 现状（修正批后）

- **spec**：`extension-decl` 四形态含 `'<<' IDENT '>>' trait-body`（已恢复）。
- **实现**：`Parser.parseTopLevelDecl` 的 `.lessThan` 行首双 `<` 分派分支**仍在**（未删除），但词法层 `<<` 合并为单个移位 token，特征实际不可达（E2-006 保留记号）——即产生式仍处于「spec 记载、实现不可达」状态。

## 提案内容

按治理流程重新引入（实现侧）：

1. **词法消歧**：Lexer 对 `<<` 保持合并移位 token 不变；Parser 在行首/语句起始位遇到 `.lessThan` 且 `peek(offset: 1)` 也是 `.lessThan` 时——该形态仅在空格分隔的退化输入下出现。真正的修复点在 **Lexer**：换行后的行首 `<<`（前一 token 为 newline）产出双 `.lessThan` token 对，或产出专用 `traitExtensionOpen` token；行内 `<<` 维持移位 token。二选一在评审时定（倾向后者：token 语义显式，Parser 零 lookahead）。
2. **`>>` 对称处理**：行尾 `>>` 同理（`traitExtensionClose` 或 next-token 边界判定），避免与泛型嵌套/移位右移冲突。
3. **回归面**：`GrammarConsistencyTests` 增钉——行首 `<<T>>` 解析为 extensionDecl(kind: trait)，行内 `a << b` 维持移位表达式；`diff_tokens.sh` 对既有语料无漂移（`<<` 现网语料零使用，见 E2-006 勘测）。
4. **spec**：若采纳，§A `extension-decl` 产生式已就位，仅需把「不可达」注记改为落地注记并登记 E 编号。

## 影响评估

- 词法改动面：Lexer 单点（行首判定已具备行导向基础设施）；`<<`/`>>` 现网语料零使用，无破坏面。
- 与 §A.2 二元移位互斥由 token 化保证，不新增 §A.4 消歧规则条目（或仅加一条「行首 `<<` → 特征扩展，行内 → 移位」）。

## 处置

- 待用户评审词法方案（traitExtensionOpen 专用 token vs 行首双 token 对）后落地。

## 落地记录（2026-09-06）

- 用户裁决：重新引入；词法方案二选一采纳 **B（行首双 token 对）**——Parser 顶层分派本就期望 lessThan 对（`parseTopLevelDecl` → `parseExtensionDecl` kind = traitExt），专用 token 方案的改动面优势不存在。
- 改动面：Lexer 单点（行首 `<<` 只消费第一个 `<` 返回 `.lessThan`，第二个 `<` 由正常路径产出；`awaitingFirstTokenOfLine` 标志逐行置位/清除）+ Parser 闭合位一处（traitExt 闭合接受合并态 `.rightShift` 或分离态 `.greaterThan` ×2）。
- spec：extension-decl `'<<' IDENT '>>' trait-body` 产生式加落地注（含词法消歧判据与闭合双态说明）；顺手修正批残留的 `[:' type-annotation]` 笔误（`{{` 行）。
- 钉子：GCT `testProductionsTraitExtensionBlock`（词法 4-token 断言 + traitExt 扩展块断言）、`testProductionsInlineShiftStaysBinary`（行内 `a << 2` 维持 binary leftShift）；夹具只含扩展块本体，避开 trait 块终止性既有 Open 缺陷面。
- 证据：E-128（源已删除）。

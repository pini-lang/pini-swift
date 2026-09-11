# 测试块花括号形态 `{名|test}(签名)` 勘误

- 状态：**Closed（2026-09-05 修正批落地）**
- 勘误日：2026-09-05

## 结论（草稿考据）

- 草稿 §测试函数块：**「测试函数块必须显式声明 `|test(形式参数元组,)->(返回元组,)`」**——唯一形态 = 裸声明 `名称|test(...)`，与 §不安全函数块 `|unsafe`、§复合类型方法块 `|self` 同族（显式修饰符 + 签名）。
- spec §1 测试函数块条目曾记载双形态（`名称|test(...)` **/** `{名称|test}(签名)`）——花括号形态系宿主实现时顺手扩展（TestBlockTests 实现注释自陈「与 `|func` 同机制」），草稿从未记载。用户裁决：**错误形态**。
- `TestBlockTests.testParseTestBlockBraceForm` 钉定该错误形态，属「测试钉住了实现超售」。

## 处置（2026-09-05 修正批）

1. **Parser**：撤销批③ `|test` 豁免——`braceFuncDeclModifier`/`parseTestBraceDecl` 删除，恢复 `isBraceFuncDecl` 前瞻（并修正其 pipe 分支历史缺陷：消费 `|` 后未跳过修饰符 token）；`{名|test}(签名)` 与通用花括号函数形态一并报 E2-005（提示语补 `名|test(...)` 迁移指引）。
2. **测试**：`testParseTestBlockBraceForm` → `testParseTestBlockBraceFormRejected`（拒绝断言：报错含「已移除」与「test」）；夹具文件保留（内容即错误形态样本）。裸声明形态测试（`testParseTestBlockBareForm` 等）不受影响。
3. **spec**：§1 测试函数块条目删除花括号形态并注明超售勘误；§A.4 规则 3.4 移除「唯一豁免」句。
4. **语料面**：`examples/`、`examples/selfhost/` 全部测试函数均为裸声明 `|test`，花括号形态零使用（grep 实证），无迁移成本。

## 教训归档

- spec 化实现行为时须回查草稿原意：草稿「必须显式声明 |test」被扩写为双形态，属无授权的形态增殖。
- 测试断言钉定的是实现现状，不是规范依据；治理裁定形态对错时以草稿 + 用户裁决为准。

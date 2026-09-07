# Issue：print(F64) 双后端展示格式分歧（%f vs 最短表示）

- 状态：**Closed（2026-09-08 收口，LR-8 裁决 = A 最短往返）**
- 收口记录：spec 新增「值展示语义」节（§2.8）钉四条形态规则（最短往返 /
  定点指数切换阈值 [1e-4, 1e16) / 定点恒带小数点 / e±NN 两位指数），两后端
  均委托宿主标准库 `String(Double)`（委托即单源，规范权威是 spec 四条规则）。
  落地：PiniRuntime 新增 `bk_double_to_string`（`@_cdecl`，strdup 契约、
  发射的 IR printf 消费后 `@free` 释放，现有 bk_* 35 符号签名零改动）；
  IREmitter 的 F64 print 分派改经 helper（`@fmt_double`/`%f` 常量移除）；
  解释器侧零改动（现状即规范形态）。差分套件补 `testDiffFloatPrint`
  边界值 fixture（2.5 / 0.1+0.2 / 1e15 / 1e16 / 1e21 / 1e-5 / 0.0001），
  19/19 逐字节一致。**遗留**：旧后端（IRGenerator）print(F64) 仍为 %f，
  不修（冻结约束），随 M6 翻转批删除自然消亡。证据 E-141。
- 性质：不是单侧 bug，是「print 浮点的语言语义」未单源——哪一侧是规范形态
  需要 spec 裁决。

## 分歧描述

同一程序 `print(2.5)`：

- 解释器：`stringify` 走 Swift `String(Double)` → `2.5`（最短表示）；
- LLVM 后端（新旧两代同款）：`@fmt_double` 走 C `%f` → `2.500000`。

既有测试用空白归一化/`contains` 断言掩盖了该分歧；HIR 差分套件要求
逐字节一致，F64 print 因此无法入套件。

## 需要裁决的点

1. 语言规范采用哪种展示语义（最短表示 / %f 固定六位 / 其他）；
2. 若取最短表示：LLVM 侧需换格式策略（`%g` 与 Swift 最短表示在
   有效位/指数形态上仍有大量分歧点，不能简单替换，需运行时格式化
   helper 单源两后端共用）；
3. 裁决后：差分套件补 `testDiffFloatPrint`，能力清单对应格更新。

## 关联

- `docs/issue-interpreter-float-compare-2026-09-07.md`（float 差分覆盖的
  另一前置：解释器缺比较分支）
- `docs/issue-llvm-rewrite-plan-2026-09-07.md`（M4 批②；G 格推进时顺带
  评审）

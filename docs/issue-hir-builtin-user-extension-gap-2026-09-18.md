# Issue：**内建类型的用户扩展方法**未在 HIR 侧落地（`H-3` 三级派发缺失）

> **日期**：2026-09-18｜**状态**：**Open**（只登记不修）
> **发现于**：格 `G-5`（D 类参照臂改造）—— 换腿后的判据面实测把它顶出来
> **性质**：**既有能力缺口**，并**订正一处分类错误**（`P4-β` 把该文件列进了「对照臂」）
> **归属**：**`G-6` 前置**（该文件的 `Interpreter` 是**唯一实现**，不是参照臂）

## 1. 现象（实测：`BuiltinOverrideTests` 6 条，换腿后红 4 条）

| 用例 | 换腿后实测 |
|---|---|
| `testArrayNewMethodOverride` | **降载期拒绝**：`HIR lowering error at 7:16: method 'len' calls are later grids` |
| `testStringNewMethodAddition` | **降载期拒绝**：`HIR lowering error at 7:18: method 'shout' calls are later grids` |
| `testStringContainsOverride` | `XCTAssertEqual failed: ("true") is not equal to ("false")` —— 得到**内建行为**，期望**用户扩展行为** |
| `testUnoverriddenStillBuiltin` | 同上形态（`("true"…` 起，期望用户扩展侧的值） |
| `testElementwiseAdditionOverride` · `testChainedUserAndBuiltinCalls` | 保持绿 |

⇒ **两种失败形态**，指向同一件事的两个面：
① **新增**方法（内建表没有的名字）在降载期**根本没有节点**（`… calls are later grids`）；
② **覆盖**同名内建成员时，派发**没有把用户扩展排在语言内标准库之前**（读到的仍是内建结果）。

## 2. 这条缺口的语义位置

语言约定（`H-3`，2026-08-31 落地）：内建类型（`String` / `Array`）值的成员派发是**三级** ——

```
用户扩展  >  语言内标准库  >  宿主原生
```

AST 侧实现了三级；HIR 侧**只有后两级**。⇒ 这不是「同一语义两种实现」，而是**一侧少了一级**。

## 3. 为什么它同时是一条**分类订正**

`P4-β` 的 D 类（「对照臂」）把 `BuiltinOverrideTests` 与另外 8 个文件并列。当时的分法是
「是否驱动 `Interpreter` 做执行」。该分法在这一个文件上**失效**：

- 其余 8 个文件的 `Interpreter` 是**参照物**（另一侧有独立实现，两者比对）；
- 本文件的 `Interpreter` 是**被测能力的唯一实现** —— 换成 HIR 不是「换参照物」，
  而是**换掉被测对象**，于是红的是能力、不是判据。

⇒ **判据**：`D` 类应按「`Interpreter` 在文件里扮**参照物**还是**实现**」再分一次；
「绝对期望 vs 臂间对照」这个维度**不足以**判（本文件的断言全是绝对期望，却仍是实现）。

## 4. 处置候选（**不预设**）

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** | 在 HIR 侧补齐三级派发（新增方法可达 + 覆盖优先） | 中：须动 `HIRLowerer` 的成员派发与 `HIRExecutor` 的分发表；**须走 `spec §1.3`**（语言面已有约定，属实现追上约定，不是新约定）|
| **B** | 显式退役这 6 条用例（连同语言面收紧为「用户扩展不支持」） | 小，但**用户可见能力净减** ⇒ 须走 `spec §1.3` 登记 |
| **C** | 暂不动，`G-6` 前把该文件整体移入「AST 唯一实现」清单，与 `pini dbg` 同处 | 小，但把两处缺口合成一个更大的前置 |

**建议**：**A** —— 语言约定已在册、AST 已有实现可对照，属「实现补齐」而非「新决策」。
但它与 `G-5` 的「零 `Sources` 改动」性质不同，**须独立点名**。

## 5. 判据（怎么算完成）

| # | 判据 | 测法 |
|:--:|---|---|
| 1 | 6 条用例在**默认引擎**上全绿 | `swift test --filter BuiltinOverrideTests` 6/6 |
| 2 | 三级派发的**优先序**可测 | 覆盖用例必须是「用户值」而非「内建值」 |
| 3 | 无新增红 | 全量回归逐条集合：转绿 4 / 新增 0 |
| 4 | 两引擎一致 | 同 6 条在 `PINI_INTERP_ENGINE=ast` 下同样全绿 |

## 6. 不做范围

只登记。**不改 `Sources/`、不改测试**；本批（`G-5`）已把该文件**回退到 AST 臂**并在注释里写明理由，
**回退本身不算修复** —— 它只是让该文件在 `G-6` 之前继续可用。

## 7. 复现方式

```bash
cd <repo>
swift test --disable-sandbox --scratch-path /tmp/pini-build --filter BuiltinOverrideTests
# 换腿形态下实测：Executed 6 tests, with 4 failures
# 回退到 AST 臂后：Executed 6 tests, with 0 failures
```

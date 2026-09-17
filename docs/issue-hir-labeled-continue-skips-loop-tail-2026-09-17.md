# Issue：`continue <标签>` 指向外层循环时跳过该循环的**尾部** —— `for` 不推进索引、`while` 不执行 `step`

- 状态：**Open（2026-09-17 立案；登记不修）** —— 处置待裁决，**未决策前不动源码**。
- 发现来源：**「标签语义」批**（第 3 层 spec 断言层扩面 → `ADR-039` 实现段）。
  第一个实例是补语料时**被绝对期望值照出来的**：两个解释器印 `320`，LLVM 臂印空且 `rc=0`。
- 关联（**都是相邻项，都不是同一件事，勿合并**）：
  - `docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md` —— 本单症状之所以**静默**，
    正是那单的机制：`lli` 的失败状态被丢弃，于是「崩溃」与「成功」在判据层同形。
    那单管**退出码不转发**，本单管**跳错了块**；根因、载体、影响面均不同。
  - `ADR-039` / 规范 §3 台账 `G61` —— ADR-039 只把**降载期的帧栈**从「循环」放宽到
    「可中断帧」（`if` 也能被 `break` 定向）。本单**不是**它的遗留：本缺陷在 ADR-039
    之前就存在，只是 ADR-039 让它的**可达面变大**（见「影响」）。
  - `Tests/PiniTests/SpecAssertionTests/PROVENANCE.md` —— 第一个实例以**红规格**形态驻留在那里
    （用例 `labelForContinue`），本单是它从「无主」转「有户口」的登记处。

## 性质

- **是语言级行为缺口**：两个解释器（`ast` 冻结参照 + `hir`）语义一致，**LLVM 臂不一致**。
- **是静默缺陷**：三例的 `rc` 全为 `0`，两例 `stdout` 为空、一例印出**错误的值**（`0` 而非 `20`）。
  ⇒ 任何只看退出码的判据都判它「成功」。
- **不是翻转阻塞的必要条件，但是翻转后的可见缺口**：翻转后 `ast` 参照臂删除，
  这条不一致不会再有人交叉验证 ⇒ 它需要在翻转前落地或显式接受。

## 现象（实测，2026-09-17，本机）

三通道逐夹具实测（`pini run` 两次带显式引擎 + `pini run-llvm`）。
`interp-ast` 是冻结参照，`interp-hir` 与它一致：

| # | 形态 | 外层目标 | `interp-ast` / `interp-hir` | `llvm-hir` | 差异 |
|---|---|---|---|---|---|
| 1 | 内层 `for` 里 `continue 外层for` | `for`（**无** `step`） | `320` | **空**（`rc=0`） | 索引不推进 |
| 2 | 外层 `for` **带** `step`，内层 `while` 里 `continue outer` | `for` + `step` | `300` | **空**（`rc=0`） | 索引不推进 + step 不跑 |
| 3 | 外层 `while` **带** `step`，内层 `while` 里 `continue outer` | `while` + `step` | `20` | **`0`** | **step 不跑** |
| 4 | 外层 `while` **无** `step`，深度 2 | `while`（无 step） | 一致 | 一致 | **无差异** |
| 5 | 内层 `for` 里 `continue` 外层 `while`（无 step），深度 2 | `while`（无 step） | 一致 | 一致 | **无差异** |
| 6 | `break` 指向外层 `for`，深度 2 | `for` | 一致 | 一致 | **无差异**（`break` 走 `exit`，与本缺陷无关） |

形态 1 即 `Tests/PiniTests/SpecAssertionTests/labelForContinue.pini`；
形态 2 的步骤块形如：

```
outer|for (v,) in [1, 2, 3]:
    var j = 0
    while j < 1:
        j = j + 1
        continue outer
    t = t + v
step:
    t = t + 100
```

形态 3 的判别力最强：**同一份文本，两个解释器给 `20`、LLVM 给 `0`，三者 `rc` 全为 `0`。**

## 根因（符号级，已定位到单行）

`Sources/PiniCore/CodeGen/IREmitter.swift:714`：

```swift
let target = depth == 1 ? frame.continueTarget : frame.header
```

`header` 是**循环的入口**（`while` 是条件块、`for` 是边界检查），
`continueTarget` 才是**「下一轮」的入口**（`for` 是索引自增块、`while` 有 `step` 时是 `step` 入口）。
两处帧构造实测：

| 帧 | `header` | `continueTarget` | 是否同块 |
|---|---|---|---|
| `while` **无** `step`（`IREmitter.swift:1223`） | `condLabel` | `condLabel` | **相同** ⇒ 掩盖了缺陷 |
| `while` **有** `step` | `condLabel` | `stepLabel` | 不同 ⇒ 形态 3 |
| `for` **无** `step`（`IREmitter.swift:1306`） | `condLabel`（边界检查） | `incLabel`（索引自增） | 不同 ⇒ 形态 1 |
| `for` **有** `step` | `condLabel` | `stepLabel` | 不同 ⇒ 形态 2 |

⇒ 缺陷**只在「深度 > 1 且目标帧的两个标签不同」时显形**。这也是它长期未被发现的原因：
最常见的形态（无 `step` 的 `while`）恰好是同块。

## 契约（两侧应当怎样，实测）

`continue <标签>` 指向外层循环 = **开始该循环的下一轮**，因此**该循环的尾部要执行**：

| 侧 | 证据（符号） |
|---|---|
| AST 解释器 | `Sources/PiniCore/Interpreter/Interpreter.swift:2401` —— `if cLabel == nil \|\| cLabel == label { shouldRunStep = true }`，随后 `if shouldRunStep, let step = step` 执行 step |
| HIR 解释器 | `Sources/PiniCore/Interpreter/HIRExecutor.swift` 的 `executeWhile` / `executeForIn`：深度 1 时保持 step 通路，深度 > 1 时 `depth - 1` 上抛 |
| LLVM | `iremitter` 的 `emitContinue` —— **深度 > 1 取 `header`**，与上两行相反 |

⇒ 两条解释器臂与 LLVM 臂**对「下一轮」的定义不同**，不是实现细节差异。

## 影响

- 用户可见：带标签 `continue` 指向**带 `step` 的外层循环**时 `step` 静默失效；
  指向外层 `for`（无 step）时**索引不推进** ⇒ 死循环或崩溃，且对外表现为「成功，无输出」。
- 判据面：ADR-039 之后，**带标签 `if` 也成了帧**，于是形态 3 之外又多一条可达路径 ——
  `outer|for` 里套 `tag|if` 再 `continue outer`（本批实测：两解释器 `10`、LLVM 空）。
  ADR-039 没有引入本缺陷，但让它多了一条触发路径。
- 自举/语料面：任何用「带标签 `continue` 跨层」的 Pini 代码在 LLVM 臂上不可信。

## 处置请求（待裁决，先决策后实施）

- **A（修实现，推荐）**：把 `IREmitter.swift:714` 的目标统一为 `frame.continueTarget`。
  语义依据是上表两条解释器臂的共同行为；`for` 的「下一轮」= 先自增再判边界，
  `while` 的「下一轮」= 先跑 `step` 再判条件。**代价 = 1 行**，改完形态 1/2/3 应同时转绿。
  ⚠️ 需同时核对 `for` + `step` 的组合（`continueTarget = stepLabel`）是否就是「下一轮」的正确入口 ——
  即 `step` 是否应在索引自增之后执行（`emitForIn` 的块序决定）。**这一条必须先实测再落。**
- **B（登记现状，接受）**：把「深度 > 1 的 `continue` 不执行目标循环尾部」写成规范条款，
  并撤回两条解释器臂的现有行为。**代价**：改 `Sources/` 两个解释器臂 + 规范 + 契约，
  且**收回用户今天能跑的形态**（形态 1/3 在解释器下是对的）。

推荐 **A**：B 会为了对齐一个 LLVM 侧的实现细节而改掉两个一致的引擎，
方向与「LLVM 臂向解释器收敛」的既有批序相反。

## 不做范围（立案批）

- **不改 `Sources/` 任何源码**（未决策）· 不动 `labelForContinue.pini` 的期望值（它是红规格，转绿才改）。
- **不并入** `docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md`
  （那单是判据机制，本单是语义缺口；本单转绿**不会**让那单消失）。
- 不为形态 2/3 新增语料用例 —— 第 3 层只断言**已定义**的语义，
  而这三例的期望值虽然两侧一致、但**规范里没有条款**（与本批 `ADR-039` 的 D2/D3 同型问题）。
  语料面要不要补，随本单裁决一并定。

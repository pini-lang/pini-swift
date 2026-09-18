# Issue：`G-6` 删 `Interpreter` 前必须先处置的**残余引用面**（含规划件过期读数的实测订正）

> **日期**：2026-09-18｜**状态**：**引用面已逐处有主**（`G-6a` 处置 §2.2 与 §2.1 的一行；`G-6b-1` 处置 §2.3 的 3 条并补全整面）—— 余项**全部**归 `G-6c`，随删除面消失
> **发现于**：格 `G-5`（D 类参照臂改造）的开工前引用面普查
> **性质**：**三种形态并存** —— ① 规划件的一处读数**已过期**（抽取其实已完成）；
> ② 一条**从未登记**的用户可见能力断点（`pini dbg` 无 HIR 分支）；③ 一处测试侧**无主**静态入口。
> **归属**：**`G-6` 前置**（用户 2026-09-18 裁决：立工单并并入前置）。
>
> ⭐ **本单是「`G-6` 残余引用面的总挂点」**（承 §7），且**开工须按节点名**：本单**不是一批**。
>
> **2026-09-18 本批（`G-6b` 规划期）复核结果**：
> - ✅ **§2.2 已交付**（`G-6a` 处置 B：`pini debug` 两条入口改指 HIR）—— 判据 2「能力不净减」达成。
> - ⚠️ **§2.1 的表已过期四处**（行号与形态都变了），本批**逐行订正**，见 §2.1 的订正块。
> - ⚠️ **§2.3 漏记 3 个构造点**（登记只记静态入口）—— 而它们才是 `G-6c` 的**编译阻塞面**，本批补记。
> - ✅ 判据 3「规划件读数已订正」**已达成**（`docs/issue-hir-p4-gamma-plan-2026-09-16.md` 的事实基础与
>   复现方式两处均有订正标注与指针）。
> - ✅ **§2.3 已收口（`G-6b-1`，2026-09-18）**：3 条可改指的用例已改指 `RuntimeOps.*`；
>   **整面补全**为 **8 个用例 + 1 个助手**并逐条具名归属（§2.3.1）；另补记**第三栏 = 类型标注**（见 §2.3）。
> - ✅ **判据 1「三组引用面逐处有主」已达** —— 余项**全部**落在 `G-6c` 的删除面上（逐处见 §2.3.2）。
> - ⏳ **余项**：`Sources` 的 3 处 `.ast` 分支 · 测试侧 5 条退役用例 · 2 个整体退役文件 —— 全部随 `G-6c` 消失。
>   ⇒ **本单在 `G-6c` 收口前不得归档**（判据 4 须在删除后实测）。

## 0. 一句话

`G-6` 是不可逆的「删 4143 行」批。本篇给出**删之前必须先处置的最小引用面**，
并且**订正**规划件里一个会误导后续批次的读数：规划记「静态成员被保留面使用 ~30 处」，
**去注释实测为 0 处代码引用** —— 摘要抽取（`P4-0` / `P4-1b`）**已经完成**。

## 1. 实测：真引用面（去注释扫描，2026-09-18）

判据装置：把 `.swift` 逐字符剥掉 `//` · `/* */` · 字符串字面量，再检索 `\bInterpreter\b`。
**必须去注释** —— 本仓大量 docstring 在**叙述** `Interpreter.matchArmMatches` 这类语义出处，
按原文 grep 会把这些叙述算成引用（本单的两个错误结论都出在这个坑上，见 §3）。

| 面 | 规划件（`4b154fa` 时点） | **本次实测** | Δ |
|---|---|---|---|
| `Sources` 侧 `Interpreter.<静态成员>` **代码**引用 | 39 处 | **0 处** | ⚠️ **表格已过期** |
| `Sources` 侧 `Interpreter(...)` **构造点** | 4 处 | **6 处** | ⚠️ 漏记 2 处（见 §2.1） |
| `Tests` 侧 `Interpreter(...)` 构造点 | 16 文件，未细分 | 见 `G-5` 载体 | —— |
| `Tests` 侧 `Interpreter.<静态成员>` 代码引用 | 未登记 | **5 处 / 2 文件**（其中 2 处随退役文件消亡） | ⚠️ **无主** |

## 2. 必须处置的三组

### 2.1 `Sources` 侧 6 处构造点（**规划只记了 2 处**）

⚠️ **2026-09-18 订正（`G-6b` 规划期，去注释现测）**：下表**四处**已随 `G-6a` 改变形态或行号。
现测 `Sources` 侧 `Interpreter(` **仅余 4 处**（本表前两行 + `Interpreter.swift` 自身的 1 处自构 + `ReplEvaluator`），
其余两行**已不再是构造点**。⇒ **按本表的旧形态施工会改错文件。**

| 位置 | 所在函数 | 形态 | `G-6` 后的处置 |
|---|---|---|---|
| `Sources/PiniCLI/main.swift:906` | `runRunPath` | 单文件 run 的 **AST 回落**（`if engine == .hir { … return }` 之后） | 收开关时一并删（归 `G-6c`） |
| `Sources/PiniCLI/main.swift:965` | `runRunPath` | 包 run 的 **AST 回落** | 同上（归 `G-6c`） |
| ~~`Sources/PiniCLI/main.swift:1047`~~ | ~~`runDebugFile`~~ | ⛔ **已订正**：`G-6a` 把该函数改指 HIR ⇒ 此处现在是 `HIRExecutor(programBase:)`（L1059），**`Interpreter(` 已不在其中**。见 §2.1.1 | ✅ **已交付**（`G-6a`） |
| ~~`Sources/PiniCLI/main.swift:1066`~~ | ~~`runDebugDirectory`~~ | ⛔ **已订正**：同上（现为 L1088 的 `HIRExecutor`） | ✅ **已交付**（`G-6a`） |
| `Sources/PiniCore/REPL/ReplEvaluator.swift:104` | REPL `.ast` 分支 | 收开关时删 | 归 **`G-6b`**（硬前置）：先收成一臂，`G-6c` 再删 |
| ~~`Sources/PiniCore/Debugger/DAPServer.swift:191`~~ | ~~`makeRun` 未注入时的默认路径~~ | ⛔ **已订正**：`G-6a` 已改指 ⇒ 此处现在是 `let exec = HIRExecutor()`，**不再是 `Interpreter()`** | ✅ **已交付**（`G-6a`） |

#### 2.1.1 ⚠️ `G-6a` 的处置方式带来一个**副作用**（须由 `G-6b` 收口）

`G-6a` 把 `runDebugFile` / `runDebugDirectory` 接到 HIR 时，**手写了第三份 `check → lower → execute`**
（没有复用已经存在的 `ProgramRunner`，而后者本就是 `DebugHookHost`）。
⇒ 引用面**确实解除**了，但**装配同构从「四份」变成「九处」（4 文件）**。
实测与完整清单见 `docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §1.1 / §1.2。
**这不是缺陷登记，是范围登记** —— 它正是 `G-6b` 的第一份对象清单的来源。

### 2.2 ⛔ 新增且无主：`pini debug` 的 CLI 入口**恒走 AST**（用户可见能力断点）—— ✅ **已交付（`G-6a`，2026-09-18）**

> **处置**：用户 2026-09-18 裁决「**全补实现**」⇒ `G-6a` 取本节选项 **A**
> （两条入口改指 `HIRExecutor`，照 `DebuggerTests.dbgMakeRunHIR` 的形状）。
> **判据**：`DebuggerTests` **17 passed** + **CLI 实机冒烟**（该套件走自己的 HIR helper，测试绿不算数）——
> `b 3` 后确停在 3 行；目录模式停在 `package-demo/main.pini:20` 并跑完。
> 实录见 `docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-6a` §三项处置（处置 B）。
> ⚠️ **两处订正**：① 命令名是 **`pini debug`**（不是 `dbg`）；
> ② 处置方式**未复用 `ProgramRunner`** ⇒ 副作用见 §2.1.1（归本批 `G-6b`）。
> 以下为处置前的原文，保留以留痕。

```swift
// Sources/PiniCLI/main.swift:1040
private func runDebugFile(_ path: String) {
    …
    let engine = Interpreter(programBase: absoluteProgramBase(path))   // ← 无 HIR 分支
    startDebugger(run: DebugRun(host: engine) { try engine.run(module: module) }, …)
}
// :1055 同理 —— runDebugDirectory 也是裸 Interpreter
```

**性质**：这不是「参照臂」也不是「回落」，而是**唯一实现**。
`DAPServer.swift:191` 的默认路径与它是同一件事的两面 —— DAP 侧**可以**由调用方注入 `makeRun`
（`DebuggerTests` 正是注入 `dbgMakeRunHIR`），而 **CLI 侧从不注入**。

⇒ **`G-6` 直接删除 `Interpreter` 会让 `pini debug <file>` 与 `pini debug <dir>` 整体消失**，
而 `G-6` 的判据 3 只写了「第四项（调试/DAP/REPL）**须先完成参照臂改造**才可读」——
**参照臂改造（`G-5`）不包含这两处**：它们没有第二臂可换，只有一条臂要**新建**。

**处置候选**（不预设）：

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** ✅ **已取** | 把两条入口改指 `HIRExecutor`（照 `DebuggerTests.dbgMakeRunHIR` 的形状：`check → lower → execute`） | 中：须实测 `pini debug` 的暂停点/断点行为在 HIR 侧等价（`DebuggerTests` 已有 12 条参数化用例覆盖同一面，可复用为判据） |
| **B** | 先在 `G-6` 前的某个批里补 HIR 分支并**保留** AST 分支（双引擎并存，随 `G-6` 收成一臂） | 中：多一个中间态 |
| **C** | 显式退役 CLI 调试能力，`pini debug` 报「暂不可用」 | 小，但**用户可见能力净减** ⇒ 须走 `spec §1.3` 登记 |

### 2.3 测试侧引用面 —— ⚠️ **原表只记了静态入口，漏了构造点**

⚠️ **2026-09-18 订正（`G-6b` 规划期，去注释现测）**：测试侧 `Interpreter` 引用共 **18 行 / 19 处 / 3 文件**，
其中**构造点 14 处**。原表只列了 5 处静态成员 ⇒ **漏记的 3 个构造点才是 `G-6c` 的编译阻塞面**。

**（a）静态成员引用：5 处 / 2 文件**（原表，实测复核一致）：

| 位置 | 引用 | 处置 |
|---|---|---|
| `Tests/PiniTests/StructuredConcurrencyTests/StructuredConcurrencyTests.swift`（原 :246-247） | `Interpreter.makeResult` ×2 · `Interpreter.makeError` ×1 | ✅ **已改指 `RuntimeOps.*`**（`G-6b-1`）—— 行为中性：两侧本就是逐字转调 |
| `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift:192,227` | `Interpreter.isCancelErrorValue` ×2 | **条件项**：`G-3e` 退役单的 `SuspendRuntimeTests` 节记该类 11 条**全部**退役 ⇒ 取处置 A（移入退役登记处）则随文件消亡；取处置 B（原地保留只读规格）则须一并改名 |

**（b）构造点：14 处 / 3 文件**（`G-6b` 规划期补记 —— 按「该文件 `G-6c` 之后是否存活」分成两面）：

| 文件 | 构造点 | 存活面？ | 处置 |
|---|:--:|---|---|
| `StructuredConcurrencyTests` | **3**（原 L70 · L87 · L183） | **3 条改指后存活**、5 条随引擎退役（§2.3.1） | ✅ **`G-6b-1` 已处置** |
| `SuspendRuntimeTests` | **9**（全落在退役的 11 条内） | 文件存活，但**存活的前 4 条实测零引用**（复验见 §2.3.3） | ✅ 随退役面消亡，**无需动** |
| `CPSDifferentialTests` | **2**（L22 · L30，在一处夹具驱动 helper 内） | ⛔ 14 条**全部退役** | ✅ 随文件消亡，**无需动** |

**（c）⚠️ 第三栏：类型标注**（`G-6b-1` 实测补记 —— 按（a）（b）两栏枚举**结构性看不见**）：

| 位置 | 形态 | 处置 |
|---|---|---|
| `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift:484` | `captureSuspendStdout(_ body: (Interpreter) throws -> FutureValue)` —— **闭包形参的类型标注**，既非构造点、也非静态成员 | ✅ 随退役面消亡（其 **3 个调用者**全在退役的 11 条内，见 §2.3.3） |

⇒ **测试侧引用面总数订正：19 行 / 20 处 / 3 文件**（原记 18 / 19 —— 漏的正是（c）那一行）。

#### 2.3.1 真编译阻塞面（逐条归属，`G-6b` 实测终结）

⚠️ **数它时必须沿助手展开**：该文件只有一处构造点（`runProgramAST` 内），却由 **5 条**用例共用 ——
按「构造点处数」会把 5 条算成 1 条。**这正是原登记把面记成「4 个用例」的成因**（实测 **8 个**）。

| 用例 | 驱动 | 归属 |
|---|---|:--:|
| `testCancelUnjoinedChildrenOnlyCancelsPendingOnes` | 纯 `FutureValue` 单元（无引用） | 存活 |
| `testCancelUnjoinedChildrenPropagatesToGrandchildren` | 同上 | 存活 |
| `testDetachedChildSurvivesParentReturn` | 同上 | 存活 |
| `testJoinFutureDetachesChildFromParent` | → `RuntimeOps.joinFuture` | ✅ **`G-6b-1` 已改指** |
| `testCheckpointIsNoOpWithoutOwner` | → `RuntimeOps.checkCancellation` | ✅ **`G-6b-1` 已改指**（规则本体同批上提 `RuntimeOps`） |
| `testCloseScopeCollectsLeakedErrAndCancelsPending` | → `RuntimeOps.makeResult` / `.makeError` | ✅ **`G-6b-1` 已改指** |
| `testCancelInterruptsRunningLoop` | `runProgramOnHIRTree` | 存活（`G-5` 已换腿） |
| `testSynchronousProgramUnaffectedByCheckpoints` | `runProgramOnHIRTree` | 存活（`G-5` 已换腿） |
| `testDetachBuiltinPrunesChildFromParent` | `runProgramOnHIRTree` | 存活（`G-5` 已换腿） |
| `testParentReturnCancelsUnjoinedChildTask` | HIR 腿**红**（`printing a Result value…`） | ⛔ **随 `G-6c` 退役** |
| `testJoinedChildIsNotCancelledByParentReturn` | HIR 腿**红**（`result(ok: i32) is not i32`） | ⛔ **随 `G-6c` 退役** |
| `testDeferStillRunsWhenTaskCancelled` | HIR 腿**红**（**跑得完、不抛错，断言不成立**） | ⛔ **随 `G-6c` 退役**（见 §7.3） |
| `testLeakedChildErrorFloatsToCallerResult` | HIR 腿**红**（`printing a Result value…`） | ⛔ **随 `G-6c` 退役** |
| `testDetachEscapeHatchSuppressesLeak` | HIR 腿**红**（同缺口） | ⛔ **随 `G-6c` 退役** |
| 助手 `runProgramAST` | 驱动 AST 走查（唯一构造点） | ⛔ **随 `G-6c` 一并删** |

⚠️ **那 5 条为何不在删除之前改指**（裁决依据，非拖延）：只要 AST 引擎还在，它们**仍是真实覆盖**；
提前改指或删除是**净损失**。与引擎同批消失，代价才由「引擎被删」解释 ⇒ `G-6c` 须**按名**处置。
逐条实测矩阵与复现命令见 `docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §10.2 / §10.3。

#### 2.3.2 ⭐ 判据 1 的收口：余项**全部**落在 `G-6c` 的删除面上

`G-6b-1` 之后，去注释扫描的**每一处** `Interpreter` 都在「`G-6c` 会删掉的东西」里面：

| 面 | 处所 | 为何无需前置 |
|---|---|---|
| `Sources/PiniCore/Interpreter/Interpreter.swift` | 文件自身全部命中 | **文件即删除对象** |
| `Sources/PiniCore/Interpreter/SuspendEvaluator.swift` | `extension Interpreter` 全部命中 | **文件即删除对象** |
| `Sources/PiniCLI/main.swift:906, 965` | `runRunPath` 的 **AST 回落**（`if engine == .hir { … return }` 之后） | **随引擎开关一起删**（`G-6c` 已含「收开关」） |
| `Sources/PiniCore/REPL/ReplEvaluator.swift:104` | `ReplEvaluator.run` 的 `.ast` 分支 | 同上。⚠️ **不得提前收成一臂** —— 开关还在时把 `.ast` 静默改走 HIR，正是该文件注释里点名要避免的「静默回退假绿」 |
| `Tests/…/StructuredConcurrencyTests.swift` | 助手 + 5 条用例（§2.3.1） | 与引擎同批删 |
| `Tests/…/SuspendRuntimeTests.swift` | 11 条退役用例 + 其 helper（§2.3.3） | 随挂起退役面 |
| `Tests/…/CPSDifferentialTests.swift` | 文件自身 2 处 | 14 条全退役 ⇒ **随文件消亡** |

⇒ **判据 1 已达**：`G-6c` 只需**按删除清单执行**，不需要「顺手改测试」或「顺手搬装配」。
判据 4 仍须在 `G-6c` 执行后实测（`swift build` 无 `cannot find 'Interpreter' in scope`）。

#### 2.3.3 复验：`SuspendRuntimeTests` 的存活 4 条与「类型标注」helper 的真实调用面

原记「存活的前 4 条实测零引用」为真，但**没有回答**一个决定性问题：
那个带类型标注的 helper 会不会**被存活用例拖住**（若会，它就**不能**随退役面消亡）。`G-6b-1` 逐条实测（该类共 **15 条**）：

| # | 用例 | 引用 `Interpreter` | 调 `captureSuspendStdout` | 退役？ |
|:--:|---|:--:|:--:|:--:|
| 1–4 | `testWhenResolvedDeliversValue` · `testWhenResolvedFastPath` · `testWhenResolvedReject` · `testFanOutNonBlocking` | — | — | **存活**（值层原语） |
| 5–11 | `testSuspendAwaitReleasesThread` 等 7 条 | ✅ | — | 退役 |
| 12–13 | `testJoinInsideCallArgumentRunsSideEffectOnce` · `testSyncCallChainSuspendResumesExactly` | — | ✅ | 退役 |
| 14 | `testWorkStealingOccurs` | ✅ | — | 退役 |
| 15 | `testBackpressureBoundsInflight` | ✅ | ✅ | 退役 |

⇒ ⭐ **`captureSuspendStdout` 的 3 个调用者（#12 · #13 · #15）全在退役的 11 条内**
⇒ 该 helper **随退役面消亡**，`L484` 的类型标注**不需要任何前置动作**。
（这正是「类型标注」那一栏能否免处理的关键 —— 只要有一个存活调用者，就必须先改它。）

## 3. 本单的两个错误结论（如实登记，因为它们是同一坑的两次）

普查过程中我先得到两个**后来被推翻**的结论，都是「把注释当引用」：

1. 首扫（按原文 grep）得「`Sources` 侧静态成员引用 40+ 处」，与规划件的 39 处吻合
   ⇒ 一度以为**规划件是对的**。去注释后为 **0**。
2. 中间结论「`FFIModuleTests.runProgram` 是死代码」（`G-5` 复核轮记入的）
   ⇒ 实测它在 `:181` 被 `testUndefinedForeignSymbolRejected` 调用，**不是**死代码。
   （该订正已进 `G-5` 载体，此处只作交叉引用。）

⇒ **纪律**：凡「某标识符被引用 N 处」类读数，**必须去注释**；本仓的 docstring 会大段复述
其他文件的语义出处，按原文 grep 的读数**系统性偏高**。

## 4. 判据（怎么算完成）

| # | 判据 | 测法 | 状态（2026-09-18 本批复核） |
|:--:|---|---|---|
| 1 | 三组引用面**逐处**有主 | §2.1/§2.2/§2.3 每一行都有「谁在哪一步做掉」 | ✅ **已达（`G-6b-1`，2026-09-18）** —— 余项**全部**落在 `G-6c` 的删除面上，逐处见 §2.3.2。§2.3 的 3 条已改指、整面已补全并逐条归属 |
| 2 | `pini debug` 能力**不净减** | 两条入口在 `G-6` 后仍可用（取 §2.2 的 A/B），或按 C 走完 `spec §1.3` 登记 | ✅ **已达**（`G-6a` 取 A；`DebuggerTests` 17 passed + CLI 实机冒烟） |
| 3 | 规划件读数**已订正** | `issue-hir-p4-gamma-plan-2026-09-16.md` 的「事实基础」与「复现方式」两处的「39 处」旁有订正标注与指针 | ✅ **已达** |
| 4 | 编译面**零残留** | `G-6c` 删除后 `swift build` 无 `cannot find 'Interpreter' in scope` | ⏳ 属 `G-6c`；**开工前的等价前置判据** = 去注释扫描「**存活面**引用 = 0」（见 `G-6b` 规划 §4 判据 1） |

⇒ **本单在判据 1 与 4 收口前不得归档。**

## 5. 不做范围

- **只登记不修**：本单不改任何源码、不改测试、不改规范。开工须单独点名。
  ⚠️ **本批（`G-6b` 规划期）的例外已获授权**：只做**本单自身的文档订正**（行号表 · 漏记清单 · 状态行），
  零 `Sources` / `Tests` 改动。
- **不顺手做 §2.3 的改名** —— 它属 `G-6` 前置，与 `G-5` 的换腿不是同一件事
  （换腿改的是**测试怎么驱动引擎**，改名改的是**静态工具函数的挂载点**）。
- ~~**不把 §2.2 直接按 A 做掉**~~ —— ✅ **该条已失效**：用户 2026-09-18 裁「全补实现」，`G-6a` 已按 A 做掉。

## 6. 复现方式

⚠️ **本节的 `grep` 姿势在本机不可用**（宿主 grep 整体被存根接管，见 `charter.md` §4 知识栏）；
用**去注释扫描**代替。本单 §2 的读数按 §6 的脚本取。

```bash
# 去注释后的真引用面（本单的核心读数）
python3 - <<'PY'
import re, pathlib
def strip(text):
    out=[];i=0;n=len(text)
    while i<n:
        if text.startswith("//",i):
            j=text.find("\n",i); i=n if j<0 else j; continue
        if text.startswith("/*",i):
            j=text.find("*/",i+2); i=n if j<0 else j+2; continue
        if text[i]=='"':
            j=i+1
            while j<n:
                if text[j]=='\\': j+=2; continue
                if text[j]=='"': break
                j+=1
            i=j+1; out.append('""'); continue
        out.append(text[i]); i+=1
    return "".join(out)
for p in sorted(pathlib.Path("Sources").rglob("*.swift")):
    if p.name in ("Interpreter.swift","SuspendEvaluator.swift"): continue
    for i,l in enumerate(strip(p.read_text(errors="replace")).splitlines(),1):
        if re.search(r'\bInterpreter\b', l): print(f"{p}:{i}: {l.strip()}")
PY

# `pini debug` 无 HIR 分支（§2.2）—— ✅ 已交付（`G-6a`），本命令已**不再**成立
grep -n 'if engine == .hir' Sources/PiniCLI/main.swift     # 只在 runRunPath 里（两处）；debug 两入口已改指 HIR
```

---

## 7. 配套入账：其他须随 `G-6` 具名登记的残余（2026-09-18 追加，工单巡查第二轮）

`G-6` 的判据第 4 条要求「残余**逐条具名入账**」，而本单是那本账的**总挂点** ⇒ 下列各项按用户裁决挂此。
⚠️ 本节只做**登记与指针**，不改任何源码；各项处置仍须**各自点名**。

### 7.0 ⚠️ 一处**登记纪律**（2026-09-18 本批复核补记）

本单的 §2.1 行号表与 §2.3 静态入口表在 `G-6a` **真改了源码之后**已各自过期，
而**没有任何一处回头改它**。⇒ 纪律：**凡以行号 / 函数形态登记「引用面」的单，
在被登记面发生源码改动的那一批里必须同批回头订正**；否则下一位读者会按旧形态去改**已经改过的文件**。
（本次的四处过期行号见 §2.1 的订正块；漏记的构造点见 §2.3(b)。）

### 7.1 `print` 一个 `Result` 值 —— **37 条**（用户已裁 **C · 维持现状**）

| 项 | 值 |
|---|---|
| 载体 | `docs/issue-hir-print-result-value-2026-09-17.md`（头部与 §5 已补裁决行） |
| 裁决 | **2026-09-17，用户取方案 C（维持现状）** —— 本体不修，残余记账 |
| 量 | **37 条** `printing a Result value is outside the slice`（另 2 + 1 条「同族待查」，见该件 §4） |
| 出处 | `docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md` §13.3（`G-3c-1` 交付记录：夹具面 59 条离开旧缺口 = 19 转绿 + 40 落到此面，其中 37 条为本项） |
| 性质 | **降载层有意拒绝**（`HIRLowerer.swift:2780-2782`），理由是 LLVM 侧 `Result` ABI 把错误槽擦成一个机器字（契约 §1）；**解释器侧无缺口** |
| ⚠️ `G-6` 开工时要做的 | **生成逐条清单**：`37` 目前只是**计数**，该件 §2 给了可复跑的取数命令（8 个并发目录逐夹具取首缺口）⇒ 须跑出**具名**清单再入账 |

**为什么挂 `G-6` 而不是别的批**：这 37 条的载体全是**并发目录的夹具**（`ConcurrencyTests` 等 8 个目录），
而并发面在 `G-6` 之后的形态由本批与 `G-3e`（挂起退役）共同决定 ⇒ 与删除面同批处置，
避免同一批夹具被读两次、且两次读到的分母不同。

### 7.2 并发面在 LLVM 侧的缺席 —— **记账要求**（`D-P4-35`）

- **裁决**：2026-09-17，用户复核**维持搁置** + **明确记账**。记录见
  `docs/issue-hir-p4-plan-2026-09-16.md` §7 的 `D-P4-35` 行；工单本身 = `docs/issue-llvm-concurrency-runtime-2026-09-08.md`
  （已补 2026-09-17 复核行）。
- **须记的事实**：翻转后并发面只剩「31 条**绝对输出**断言」，「**丢失的是跨实现交叉验证、不是判据**」
  （实测那 31 条不依赖任何参照臂）⇒ **不得沉默存在**。
- ⚠️ `G-6` 开工时要做的：把它作为**一条明确的能力损失**写进收口记录 ——
  性质是「**已知并接受的代价**」，不是「遗留待办」。

### 7.3 ⚠️ 5 条语言层并发用例**随引擎退役**（用户 2026-09-18 裁决；`G-6b` 逐条实测后的具名账）

**这不是「改指失败」，是「引擎能力不够」**：把这 5 条的驱动换成 HIR 腿后全红，且**全部挡在已有主的缺口上**。

| 用例 | HIR 腿上的实测 | 挡在谁身上 |
|---|---|---|
| `testParentReturnCancelsUnjoinedChildTask` | `printing a Result value is outside the slice`（`at 15:18`） | §7.1（**用户已裁 C 维持现状**） |
| `testLeakedChildErrorFloatsToCallerResult` | 同缺口（`at 11:10`） | §7.1 |
| `testDetachEscapeHatchSuppressesLeak` | 同缺口（`at 12:10`） | §7.1 |
| `testJoinedChildIsNotCancelledByParentReturn` | `type mismatch: result(ok: i32) is not i32`（`at 10:22`） | `docs/issue-hir-print-result-value-2026-09-17.md` §4「同族待查」（**未裁**） |
| `testDeferStillRunsWhenTaskCancelled` | **跑得完、不抛错（`rc=0`），但断言不成立** —— 输出只有 `主流程结束`、**缺 `清理完成`** | `docs/issue-hir-defer-not-run-on-cancel-2026-09-18.md`（**本批新立**） |

**裁决**：**随 `G-6c` 一并退役**（用户 2026-09-18「按你的建议来」，采纳建议 A）。
**代价（如实登记）**：语言层端到端覆盖 **8 条 → 3 条**；
其中「父返回取消未 join 子」在**单元层**仍有 **3 条**存活用例守着（§2.3.1 前三行）。

⚠️ **`G-6c` 必须按名处置这 5 条**，并在收口记录里点名下面这一条：

> `testDeferStillRunsWhenTaskCancelled` 退役 ⇒ **「取消时 HIR 不执行 `defer` 清理」这条缺陷
> 此后没有测试见证**。退役**不等于缺口消失** —— 它由「被测试守住」变成「只在工单里」。

⚠️ **同批订正一处未验真的写法**：`G-6b` 的规划件曾把这条 `defer` 缺口写成「已立案」，
而 `grep` 全 `docs/` **无命中** —— 它此前只在批次实录与退役件里被记着。
本批据此**新立工单**（见上表末行）；纪律见新单头部的订正段。

⚠️ **判据纪律（本项最有价值的副产品）**：这 5 条里有 1 条是 **`rc=0` 却断言不成立** ——
与 `G-5` 记的教训是同一条（`rc=0` 不蕴含断言可满足）。凡以 `rc` 判「可迁移」者，必须补断言级验证。

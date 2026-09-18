# Issue：挂起退役的残余 —— 判据保全、触发条件、以及一条被挡住的可迁移面

> **日期**：2026-09-17｜**状态**：**Open**（只登记不修）
> **发现于**：格 `G-3e`（挂起模式实现暂时退役；决策见 `ADR-043`，缺口登记 `G66`）
> **性质**：**退役动作的配套登记**。本单**不主张任何缺陷** —— 它是「计划已完成 → 记下缺陷」循环里
> 的「记下」一步：退役本身是**用户裁决**（2026-09-17），但退役**产生了**四项须显式记账的残余。
> **开工须单独点名**。

## 1. 为什么需要本单

`ADR-043` 把「挂起模式」判定为不完善并暂时退役。退役**不等于**这件事结束了 ——
它把四件需要**独立处置**的事推到了台面上。若不登记，它们会以三种方式静默消失：
① 语料随实现一起删掉（重写时只剩记忆）；② 「暂时」变成事实上的永久；③ 一条本可迁移的用例面被误记为「已退役」。

## 2. 残余一：25 条退役用例的**语料保全**（最要紧的一项）

退役面 = **25 条用例 / 24 个夹具**。这些用例是**重写挂起时的规格来源** ——
它们逐条写明了「挂起正确」是什么意思。⚠️ 依据 `ADR-031` 的一条已立纪律：
**「锁实现细节的断言退役前不得先行删除」**。

### 2.1 `CPSDifferentialTests` —— 14 条 / 14 夹具（**全部**退役）

判据形态：**同步路径与 CPS 路径的输出逐字节一致**。它是「两条路径语义对齐」的唯一器械。

| # | 用例 | 夹具 | 覆盖的构造 |
|:--:|---|---|---|
| 1 | `testDiffBasicJoin` | `testDiffBasicJoin.pini` | 基础 join |
| 2 | `testDiffJoinInsideCallArg` | `testDiffJoinInsideCallArg.pini` | call 实参内 join（副作用不重跑） |
| 3 | `testDiffCallChain` | `testDiffCallChain.pini` | 调用链（精确恢复） |
| 4 | `testDiffJoinAll` | `testDiffJoinAll.pini` | `joinAll` 聚合（调度器无关性） |
| 5 | `testDiffIfBodyJoin` | `testDiffIfBodyJoin.pini` | `if` 块体内挂起 |
| 6 | `testDiffWhileBodyJoin` | `testDiffWhileBodyJoin.pini` | `while` 体内挂起（多轮迭代） |
| 7 | `testDiffForBodyJoinWithBreak` | `testDiffForBodyJoinWithBreak.pini` | `for-in` + `break` 的 loopStack 路由 |
| 8 | `testDiffMatchJoinInValue` | `testDiffMatchJoinInValue.pini` | `match` 判别式位挂起 |
| 9 | `testDiffMatchJoinInBody` | `testDiffMatchJoinInBody.pini` | `match` case 体内挂起 |
| 10 | `testDiffTryJoinInExpression` | `testDiffTryJoinInExpression.pini` | `try` 表达式内挂起（成功路径） |
| 11 | `testDiffTryJoinInExpressionErrorPath` | `testDiffTryJoinInExpressionErrorPath.pini` | `try` 错误路径 |
| 12 | `testDiffLabeledArgs` | `testDiffLabeledArgs.pini` | labeled 实参重排 |
| 13 | `testDiffMemberMethodAfterJoin` | `testDiffMemberMethodAfterJoin.pini` | 恢复后的成员分派 |
| 14 | `testDiffDefer` | `testDiffDefer.pini` | 函数体级 `defer` + 挂起 + `return` |

### 2.2 `SuspendRuntimeTests` —— 11 条 / 10 夹具（**第 5–15 条**）

⚠️ **只退役第 5–15 条**；该类**前 4 条不退役**（值层原语，见 §4）。

| # | 用例 | 夹具 | 覆盖的性质 |
|:--:|---|---|---|
| 1 | `testSuspendAwaitReleasesThread` | `testSuspendAwaitReleasesThread.pini` | 「单步挂起」释放 OS 线程（⭐ 该能力的**定义性**判据） |
| 2 | `testBoundedPoolCompletesHighFanout` | `testBoundedPoolCompletesHighFanout.pini` | 有界池下高扇出完成 |
| 3 | `testCancelSuspendedTaskTerminatesAtResumeBoundary` | `testCancelSuspendedTaskTerminatesAtResumeBoundary.pini` | 取消在 resume 边界终结 |
| 4 | `testCancelSleepingChildInSuspendMode` | `testCancelSleepingChildInSuspendMode.pini` | 取消睡眠中的子任务 |
| 5 | `testDeferRunsAtFunctionExitInSuspendMode` | `testDeferRunsAtFunctionExitInSuspendMode.pini` | 挂起模式下的 defer 执行 |
| 6 | `testDeferPerTaskIsolatedInSuspendMode` | `testDeferPerTaskIsolatedInSuspendMode.pini` | defer 按任务隔离 |
| 7 | `testFixedPoolUsesBoundedThreadCount` | `testFixedPoolUsesBoundedThreadCount.pini` | 固定池线程数上界 |
| 8 | `testJoinInsideCallArgumentRunsSideEffectOnce` | `testJoinInsideCallArgumentRunsSideEffectOnce.pini` | call 实参内 join 的副作用恰好一次 |
| 9 | `testSyncCallChainSuspendResumesExactly` | `testSyncCallChainSuspendResumesExactly.pini` | 同步调用链的精确恢复 |
| 10 | `testWorkStealingOccurs` | `testWorkStealingOccurs.pini` | work stealing 发生 |
| 11 | `testBackpressureBoundsInflight` | **（无夹具）** | 背压上限（纯 Swift 构造，无 `.pini` 语料） |

### 2.3 保全动作（**要求**，执行时须点名）

- **`G-6` 删走查时，上述 24 个夹具文件与两个测试类必须一并保存到退役登记处**，
  **不得**随 `SuspendEvaluator.swift` 一起消失。
- 语言面语义条款的保全已在 `ADR-043` 落地（`spec §3.1` 与语言参考的挂起条款**保留原文 + 标注退役**，
  而非删除）⇒ 语料是另一半，两者合起来构成重写的完整规格来源。
- ⚠️ **判据保全不等于「测试保留」**：退役后这些用例**跑不了**（其驱动入口是挂起 API）⇒
  它们变成**只读规格**，不是可执行判据。

## 3. 残余二：「暂时」的**可测触发条件未定义**

用户裁决用词是「**暂时**退役」。而**无触发器的延期 = 静默的永久退役** ——
这正是本项目已经处理过一类的形态：`P0d` 的 `char` 预留位要求 `P5` 收口时**显式登记处置**
（见 `D-P4-36` 的代价说明），理由相同。

**当前状态**：`ADR-043` §7 已如实登记「触发条件未定义」，但**没有**给出：
① 谁在哪一步检查它；② 什么条件下应当重启挂起；③ 若不重启，如何正式转 `Deprecated`。

**候选触发器**（供裁决，本单不预设）：架构重写里程碑完成 · 自举进度到某节点 ·
出现「阻塞 join 占满线程池」的真实用户病例。

## 4. 残余三：4 条**可迁移**用例被下游缺口挡住

`StructuredConcurrencyTests` **14 条整体不退役**（测取消树 / 泄漏上浮 / `detach`，与线程模型无关）。
其中 **8 条**是语言层端到端（经 `Interpreter().run(module:)`，**阻塞路径**）。逐夹具直跑实测：

| 夹具 | rc | 挡在哪 |
|---|:--:|---|
| `testCancelInterruptsRunningLoop` | 0 | —— **已可在 HIR 上跑通，可改指** |
| `testDeferStillRunsWhenTaskCancelled` | 0 | —— 同上 |
| `testDetachBuiltinPrunesChildFromParent` | 0 | —— 同上 |
| `testSynchronousProgramUnaffectedByCheckpoints` | 0 | —— 同上 |
| `testDetachEscapeHatchSuppressesLeak` | 1 | `printing a Result value is outside the slice` |
| `testLeakedChildErrorFloatsToCallerResult` | 1 | 同上 |
| `testParentReturnCancelsUnjoinedChildTask` | 1 | 同上 |
| `testJoinedChildIsNotCancelledByParentReturn` | 1 | `type mismatch: result(ok: i32) is not i32` |

⇒ **4 条「现在就能改指」、4 条被两条既有缺口挡住**（两条**都已有主**：
前者 = `docs/issue-hir-print-result-value-2026-09-17.md`（用户已裁**维持现状**）；
后者 = 该单 §4 登记的「同族待查」两条之一）。

⚠️ **2026-09-18 实测订正（`G-5` 批）：上表「4 条可改指」实际只有 3 条成立。**

改指后逐条实测：**`testDeferStillRunsWhenTaskCancelled` 变红** —— 输出只有 `主流程结束`、
**缺 `清理完成`** ⇒ **HIR 侧取消时不执行 `defer` 清理**。该条已**回退**为走 AST 臂并在用例注释里写明。
⇒ **本表可改指数：4 → 3**（`testCancelInterruptsRunningLoop` · `testDetachBuiltinPrunesChildFromParent` ·
`testSynchronousProgramUnaffectedByCheckpoints`）。

⭐ **判据缺口（比这 1 条更值得记）**：上表「可改指」的判据是**夹具 `rc=0`**。
实测反例说明 **`rc=0` 不蕴含断言可满足** —— 那条夹具在 HIR 上确实能跑完并返回 0，
但**它跑出来的东西不对**。凡以 `rc` 作「可迁移」判据者，须补一条**断言级**验证
（本批的做法：逐条改指后真跑该用例，看它是否绿）。

⚠️ **记账要点**：这 3 条可迁移项**不属于退役面**，但它们的**驱动入口 `Interpreter` 会被 `G-6` 删除**
⇒ 若不改指，它们会**因删除而被动失效**（而不是因退役）。**这是本单与 `G-6` 之间的真实耦合。**
改指动作须单独点名。

⚠️ **2026-09-18 实测补记（`G-6b` 开工首步，逐条真跑而非按 `rc`）**：本节的「可迁移面」**已全部落实或定性完毕**，
下表是本单在 `G-6` 之前的**终局账**（复现见 `docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §10.3）：

| 类 | 条数 | 用例 | 终局 |
|---|:--:|---|---|
| 已改指 | 3 | `testCancelInterruptsRunningLoop` · `testDetachBuiltinPrunesChildFromParent` · `testSynchronousProgramUnaffectedByCheckpoints` | ✅ 走 HIR 线 |
| **不可转** | **5** | `testDeferStillRunsWhenTaskCancelled`（跑了但断言不满足）· `testDetachEscapeHatchSuppressesLeak` · `testLeakedChildErrorFloatsToCallerResult` · `testParentReturnCancelsUnjoinedChildTask`（三者 `printing a Result value is outside the slice`）· `testJoinedChildIsNotCancelledByParentReturn`（`type mismatch: result(ok: i32) is not i32`） | ⛔ **待裁**（见下） |
| 非语言层、可直接改指 | 2 | `testJoinFutureDetachesChildFromParent`（→ `RuntimeOps.joinFuture`）· `testCloseScopeCollectsLeakedErrAndCancelsPending`（→ `RuntimeOps.makeResult` / `.makeError`） | 行为中性（两侧本就是逐字转发，源码可证） |
| 非语言层、须先单源化 | 1 | `testCheckpointIsNoOpWithoutOwner`（`checkCancellation` 在 HIR 侧是 `private`） | 待裁 |

⇒ **本单 §7 的「§4 4 条可迁移 A/B」选项已失效**：可迁移的从来只有 3 条、且**已全部改指**；
真正悬着的是**那 5 条不可转的**（§7 的 B 选项「随 `G-6` 一并失效并具名入账」是它们的候选）。
⚠️ 其中 `testDeferStillRunsWhenTaskCancelled` 若退役，须在本单**点名**「该缺陷此后无测试见证」——
它是一条**已立案的能力缺口**，退役不等于缺口消失。

⚠️ 同批实测另订正一处**普查形态**：`Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift:484`
的 `captureSuspendStdout` 签名里有一个**类型标注** `(Interpreter) throws -> FutureValue` ——
它既不是构造点、也不是静态成员 ⇒ **按那两栏枚举会漏掉**。该文件存活 ⇒ 这一行必须改、或该助手随退役面删。

## 5. 残余四：阻塞 join 的**固有边界**（已在规范具名，此处只登记归属）

退役后阻塞 join **占用 worker 线程** ⇒ 有界池下**高扇出会耗尽线程池**。
该性质**固有于阻塞语义、非退役引入**，已按本批要求具名写进 `spec §3.1.5`
（「阻塞 join 的线程占用」条）。**处置归属**：重写挂起时的目标之一即消除它；
在此之前它是一条**已知边界**，不是缺陷。

## 6. 与在册件的关系

- **不是** `docs/issue-test-harness-suspend-runtime-sigsegv-2026-09-16.md`（那是测试基建的偶发崩溃）——
  但**相关**：该单的崩溃点 `testCancelSleepingChildInSuspendMode` **正在本单 §2.2 的退役表内**（第 4 条）。
  ⇒ **本单的退役使那一条的根因定位失去意义**（`G-6` 删除后该类无处可跑）。
  ⚠️ 该在册单的处置选项 A（先做最小复现）**因此被本单改变**，但其立项理由（读数污染）**不因此消失**。
- **不是** `docs/issue-hir-print-result-value-2026-09-17.md`（那是 `Result` 打印缺口）——
  本单 §4 的 4 条被它挡住。
- **是** `ADR-043` / 缺口 `G66` 的**配套登记件**（ADR 记决策，本单记残余）。

## 7. 处置（**不预设**，供后续裁决）

| 项 | 候选处置 | 现状（2026-09-18 `G-6b-1`） |
|---|---|---|
| §2 语料保全 | **A** 随 `G-6` 移入退役登记处（要求）／ **B** 原地保留测试目录但标注「不可执行、只读规格」 | ⏳ 未裁（归 `G-6c`） |
| §3 触发条件 | 需用户裁决：定触发器 / 明确「无触发器、由架构重写重新评估」 | ⏳ 未裁 |
| §4 可迁移面 | **A** 单独点名改指 ／ **B** 随 `G-6` 一并失效并具名入账 | ⛔ **该行已作废** —— 见 §7.1 |
| §5 线程占用边界 | 维持「已知边界 + 重写目标」，不单独立项 | ✅ 维持 |

### 7.1 ⛔ §4 的「4 条可迁移 A/B」已**作废并终结**（`G-6b-1` 实测后，2026-09-18）

原行的前提**两处都不成立**，故整行作废：

1. **可迁移的从来只有 3 条**（`G-5` 已把 4 订正为 3），且**已全部改指** —— 不是「待点名」，是**已完成**；
2. **那 5 条不可转的**才是真正悬着的，而原表**没有为它们设行**。

⇒ **终局账**（逐条见 §4 的终局表 · 残余单 §2.3.1 / §7.3）：

| 类 | 条数 | 处置 |
|---|:--:|---|
| 已改指（走 HIR 线） | 3 | ✅ `G-5` 交付 |
| **不可转 ⇒ 随 `G-6c` 退役** | **5** | ✅ **用户 2026-09-18 裁 A**；**具名账**见残余单 §7.3 ⇒ `G-6c` 须**按名**处置 |
| 非语言层、可直接改指 | 2 | ✅ `G-6b-1` 交付（`joinFuture` · `makeResult` / `makeError` → `RuntimeOps.*`） |
| 非语言层、须先单源化 | 1 | ✅ `G-6b-1` 交付（`checkCancellation` 上提 `RuntimeOps`，两引擎改为转调） |

⇒ §4 原先那 **4 条「可迁移」已全部落地**：**3 条改指 + 1 条**（`testDeferStillRunsWhenTaskCancelled`）
**经 `G-5` 实测订正为不可转**，并入上表第 2 行。

⚠️ **该 5 条退役后，「取消时 HIR 不执行 `defer` 清理」这条缺陷失去唯一测试见证** ——
本批已为它**新立工单**（`docs/issue-hir-defer-not-run-on-cancel-2026-09-18.md`），
且该单 §5 点名了这件事。**退役 ≠ 缺口消失。**

## 8. 不做范围

只登记。**不改源码、不改测试、不改规范**；开工须单独点名。
⚠️ 本单的四项**不得**顺手做掉 —— 它们各自的代价与时机不同（§2 随 `G-6`、§4 须独立验证 HIR 侧可跑通）。

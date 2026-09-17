# P4-γ / `G-3` 规划：并发迁移（`R1` = 保能力、迁到 HIR）

> **批**：`P4-γ` 子批 **`G-3` 前置规划**（**纯规划**）｜**日期**：2026-09-17｜**状态**：§2 已裁 ①（2026-09-17；`.join` 节点面走 `spec §1.3`，已落 `docs/spec/adr/adr-040-hir-join-node.md`，契约 60 → 61）· **`G-3a` ✅ 已交付（2026-09-17，见 §10）**
> **上游**：`docs/issue-hir-p4-gamma-plan-2026-09-16.md` §8.4（五单元表）· `docs/issue-hir-blocker-queue-2026-09-17.md` §3 丙组
> **裁决依据**：`D-P4-26`（取 `R1`，且排在 `G-6` 之前）· `D-P4-30`（记号归一：`R1` = 保）
> **本件性质**：**只读勘测 + 落盘规划**。不建实现分支、不改 `Sources` / `Tests` / 契约正文。
> ⚠️ **本件不镜像读数**（读数唯一源 = 元仓 `.workbuddy/state-readings.json`）；下列数字全部标**采集命令**，可复现。

---

## 0. 一句话

`G-3` 在五单元表里是一行（「890 行挂起求值器 → HIR」），但**实测表明那 890 行不是第一道缺口**：
31 条验收面里**没有一条**首缺口是 `join` 本身 —— **26 条死在降载层的两处前置缺口上**，
`join` 直接暴露的只有 **2 条**。⇒ 本件把 `G-3` 切成「**前置剥离（L1·L2，不依赖 CPS）**」
与「**本体（L3，CPS 求值器迁移）**」两段，前置可先交付、可独立判据、可回退。

---

## 1. 事实基础（全部实测，2026-09-17，HEAD `1438887`）

### 1.1 删与迁的对象（⚠️ 规模已变，规划件的 4673 行需订正）

| 对象 | 现读数 | `P4-γ` 规划件所记 | 说明 |
|---|:---:|:---:|---|
| `Sources/PiniCore/Interpreter/Interpreter.swift` | **3210** | 3783 | `G-1` 外移 556 行 + 其后各批续删 |
| `Sources/PiniCore/Interpreter/SuspendEvaluator.swift` | **890** | 890 | 未变 |
| **删除面合计** | **4100** | 4673 | ⇒ 规划件的「4673」是 `G-1` 之前的数 |

```sh
wc -l Sources/PiniCore/Interpreter/Interpreter.swift Sources/PiniCore/Interpreter/SuspendEvaluator.swift
```

### 1.2 那 890 行**是什么**：一个建在 AST 类型上的 CPS 求值器

`SuspendEvaluator.swift` 全文是单个 `extension Interpreter`（L19），输入类型是**AST**：

| 层 | 行段 | 输入类型 | 规模 |
|---|---|---|---|
| `containsJoin` / `containsCall` 静态扫描 | 21–157 | `Expression` / `Statement` / `Block` / `ElifBranch` / `AssignTarget` | ~137 |
| `SuspendTaskCPS`（任务状态 + 续体） | 159–197 | — | ~39 |
| `runSuspendableBodyCPS`（driver + 控制流路由） | 199–350 | — | ~152 |
| `evalK`（表达式级 CPS） | 352–464 | `Expression` | ~113 |
| `evalArgsK` / `evalElementsK` / `evalDictEntriesK` / `evalSegmentsK` | 466–501 | AST 子结构 | ~36 |
| `dispatchCallK` / `callUserFunctionK` | 503–554 | `FunctionValue` | ~52 |
| `execBlockK` / `execStmtK`（语句级 CPS） | 555–716 | `Statement` | ~162 |
| `execForK` / `execMatchK` / `try` 同步版 / while 系列 | 717–889 | AST 控制流 | ~173 |

⭐ **关键形态（本件最重要的勘测之一）**：它**不是**全量 CPS 求值器。
`evalK` 的**第一句**（L359）是「`!maySuspend(expr)` ⇒ 直接调 `evaluateExpression` 同步求值」，
`execBlockK`（L563）同理。⇒ 真实结构是「**同步求值器 + 一层薄 CPS 外壳**」：
只有含 `.join` 或含调用的子树才下沉到 CPS 分解。

**规划含义**：迁移的面**不是**「890 行全量重写」，而是
「**薄外壳换输入类型**（`Expression`→`HIRExpr`、`Statement`→`HIRStmt`）
+ **快速路径换底**（`evaluateExpression` → HIR 同步求值）」。

### 1.3 ⭐ 不在删除面内的并发基础设施（大幅缩小 `G-3`）

| 文件 | 行数 | 依赖实测 | 结论 |
|---|:---:|---|---|
| `Sources/PiniCore/Interpreter/SuspendScheduler.swift` | 159 | **只 `import Foundation`**，零 AST / 零 `Interpreter` | **不删**（挂起后端 work-stealing 池） |
| `Sources/PiniCore/Interpreter/Scheduler.swift` | 111 | **只 `import Foundation`** | **不删**（`GCDScheduler` 默认阻塞后端） |
| `Sources/PiniCore/Interpreter/Value.swift` | 562 | 值层 | **不删**（`FutureValue` 取消树 / `closeScope` / `detachFromParent` 在此） |

```sh
grep -n "^import\|Expression\|Statement\|Interpreter" \
  Sources/PiniCore/Interpreter/SuspendScheduler.swift Sources/PiniCore/Interpreter/Scheduler.swift
# 实测：两处各只有一行 `import Foundation`（Scheduler.swift 另有一行注释提及 Interpreter）
```

⇒ **要迁的是「CPS 求值器这一层」，不是「整个并发运行时」**。调度器、取消树、值语义**原地不动**。

### 1.4 验收面：**31 条**（实测逐条归因）

```sh
swift test --filter "PiniTests.ConcurrencyTests/test|PiniTests.JoinAllTests/test|PiniTests.JoinWithinTests/test|PiniTests.CancellationTests/test" 2>&1 | grep "error:"
```

**实测总数 vs 失败数**（同一命令）：`46 用例 / 31 失败`。

| 类 | 用例 | **红** | 绿 |
|---|:---:|:---:|:---:|
| `ConcurrencyTests` | 21 | **14** | 7 |
| `JoinAllTests` | 8 | **7** | 1 |
| `JoinWithinTests` | 7 | **6** | 1 |
| `CancellationTests` | 10 | **4** | 6 |
| **合计** | **46** | **31** | **15** |

> ⚠️ **口径（读数字前先看这一条）**：`46` 是**用例总数**，`31` 是**失败数**，
> 二者不矛盾；`P4-γ` 规划件 §8.4 的「用例 31 条」指的是**失败面**，**该数字经本次实测确认准确**。
> 绿的那 15 条测的是**值层 / 调度器层 / 类型层**（`FutureValue` 直构、`checkCollecting` 类型断言、
> `SuspendScheduler` 行为），**不跑 Pini 程序**，故不属 `G-3`。

**31 条逐条归因**（实测报文，按首缺口聚合）：

| # | 归因（首缺口） | 条数 | 用例 |
|---|---|:---:|---|
| **L1** | `call to unknown function 'sleep'`（intrinsics beyond print are later grids） | **12** | `Concurrency`: `testConcurrentTasksOverlapInTime` · `testNoDeadlockWithConcurrentJoin` · `testSleepBuiltinRunsInsideAsyncBody`；`Cancellation`: `testCancelErrorCarriesReadableMessage` · `testCancelledTaskJoinsAsCancelError`；`JoinAll`: `testCancellingAggregateCancelsAllMembers` · `testJoinAllCollectsResultsInArgumentOrder` · `testJoinAllWaitsInParallelNotSerially`；`JoinWithin`: `testJoinWithinCancelsTimedOutTask` · `testJoinWithinComposesWithJoinAll` · `testJoinWithinReturnsResultWhenTaskFinishesInTime` · `testJoinWithinTimesOutAsCancelError` |
| **L1** | `call to unknown function 'Error'` | **4** | `testBusinessErrorIsNotCancel` · `testErrIsDeliveredAsData` · `testJoinAllCancelsRemainingMembersAfterFailure` · `testJoinWithinPropagatesBusinessErrorNotCancel` |
| **L1** | `call to unknown function 'CancelError'` | **1** | `testUserConstructedCancelErrorIsAcceptedWhereErrorExpected` |
| **L2** | `'ok' construction requires a Result-typed context this grid` | **9** | `testAsyncFuncMultipleReturns` · `testAsyncFuncNestedCall` · `testAsyncFuncViaJoinGetsValue` · `testChainedJoinExpressions` · `testConcurrentGenericTypeInstantiationIsRaceFree` · `testConcurrentTasksNoStateCorruption` · `testJoinAndComparisonCoexist` · `testRuntimeErrorInAsyncBodyBecomesErrValue` · `testJoinAllFailsFastWithMemberError` |
| **L3** | `expression 'join' is not yet lowered to HIR` | **2** | `testAsyncFuncReturnWithoutValue` · `testJoinAllOnEmptyArrayReturnsEmptyOk` |
| **L4** | 断言形态 / 错误通道（期望类型错或降载错，实际形态不符） | **3** | `testAsyncFuncLiteralViaJoin`（期望 `Result<I32, Error>` 冲突，实际是另一形态的类型错）· `testJoinWithinRejectsNonFuture`（期望 `Future` 类型错）· `testJoinAllRejectsNonFutureElements`（期望类型错，实际是 `join` 降载错） |

⭐ **没有任何一条的首缺口是「挂起调度器缺失」** —— 31 条**全部**死在**降载层或类型层**。
`join` 本体（L3）直接暴露的只有 **2 条**。

### 1.5 ⭐ 首缺口分层（本件的核心结论）

```
L1  降载层：并发内建的降载登记缺失        17 条   sleep 12 · Error 4 · CancelError 1
L2  降载层：异步体 return 位缺 Result 上下文  9 条   'ok' construction ...
────── 以上 26 条不依赖 CPS，可先交付 ──────
L3  降载层 `.join` 节点面 + HIR 侧 CPS 求值器  2 条（首缺口）+ 其余 29 条剥离后落到此
L4  错误通道口径（断言形态不符）            3 条   归乙组 D2，不在本批
```

⚠️ **首缺口遮蔽（`P4-1a` 的教训，此处复用）**：L1 的 12 条 `sleep` 里，多数程序的**真实意图**
是「并发任务重叠」——它们**同时**需要 `sleep` 与 `join`。⇒ L1 修完后它们**不会转绿**，
而是**在 `join` 处再次失败**。这**不是** L1 的失败，是分层剥离的正常形态；
⇒ **每批的验收判据必须按「该批去除的缺口数」测，不能按「转绿数」测**
（与 `P4-γ` 规划件 §1.4 对 25 个降载标记点的同一条纪律）。

### 1.6 ⚠️ `P4-β` 的 B 类 43 条：现状订正（实测全绿，性质是「改指」不是「转绿」）

`P4-β` 的迁移分类里，**B 类「挂起/并发内部 API」= 3 文件 / 43 用例**，
当时记「保持驱动 `Interpreter`（`R1/R2` 的对象）」（`docs/issue-hir-p4-beta-migration-2026-09-16.md` §分类表 + §尾表）。

**本次实测（2026-09-17）**：

| 文件 | 用例 | 实测 |
|---|:---:|---|
| `StructuredConcurrencyTests` | 14 | **全绿** |
| `SuspendRuntimeTests` | 15 | **全绿** |
| `CPSDifferentialTests` | 14 | **全绿** |
| **合计** | **43** | **0 失败** |

```sh
swift test --filter "PiniTests.StructuredConcurrencyTests/test"
swift test --filter "PiniTests.SuspendRuntimeTests/test|PiniTests.CPSDifferentialTests/test"
```

**为什么全绿**：它们在**进程内直接构造 `Interpreter()`**，而 `PINI_INTERP_ENGINE` 的翻转
只作用于 **CLI 子进程**（`P4-2` 已实测「两把尺都看不全」的那条）⇒ 翻转**够不到**它们。

**⇒ 三条订正**（`G-3` 规划据此改口径）：

1. **「B 类 43 条」不是「要修的红」，而是「要改指的绿」** —— 与 `G-5` 的 D 类 303 条**同族**
   （绿的但载体要删），与 `G-4` 的 C 类 23 条（真的红）**不同族**。
2. **它们有归属了**：归 **`G-3`**（因为改指目标 = `G-3` 新建的 HIR 挂起入口）。`P4-β` 的
   「`R1/R2` 的对象」这句在记号上是旧的（见 §2.3），在归属上**成立**。
3. `CPSDifferentialTests` 的 14 条是 `G-3` 的**天然验收面**：它两臂跑同一 `.pini`
   （同步路径 vs CPS 路径）断言 stdout 逐字节一致（`CPSDifferentialTests.swift` L11–L49）。
   迁移后两臂应换成 **HIR 同步 vs HIR-CPS** ⇒ **它自动成为「迁移不走样」的判据**，
   且**判据能失败**（`G-3` 若语义漂移，该套必然转红）。

### 1.7 契约现状：`join` 的节点面是**已裁的预留位**

`docs/spec/hir-contract.md` §4 标题 = 「**预留位（已裁未实施，两条）**」；§4.2 全文：

> ### 4.2 `.join` 挂起语义（待 CPS 格落地）
> - **依据**：CPS 路线已裁 **R2** —— 单列一格迁到 HIR（见计划 §13）。
> - **契约预留**：`await` / `wait` 的**挂起与恢复语义**须有节点面承载；`HIRLowerer` 须为
>   `.join` **增加节点面**（副产物约束，计划 §6）。
> - **现状**：`SuspendEvaluator`（890 行）为 `extension Interpreter`，建立在 AST 走查上，
>   **不在 HIR 节点集内**（44 + 16 计数不含它）。
> - **本契约不实现**，仅预留位置与命名口径。

**实测节点计数**：`HIRExpr` **56 case**（含 3 个内部别名）· `HIRStmt` **16 case**；
**`HIRExpr` 无 `join`** · **`HIRStmt` 无 `detach`**。

```sh
grep -c "    case " Sources/PiniCore/HIR/HIRNode.swift   # 需按枚举切分，见 §7 脚本
grep -n "case .join:" Sources/PiniCore/HIR/HIRLowerer.swift
# 实测：唯一一处 .join 在 L4885，且它在一张**报错文案表**里（describeExpression），不是降载实现
```

⇒ 降载层对 `.join` 的处置是**兜底报错**（`expression 'join' is not yet lowered to HIR`），
不是「漏登记」—— 这与 L1 的「内建漏登记」是**两种不同形状的缺口**。

### 1.8 `HIRExecutor` 的状态缺口（⚠️ 含一处必须随迁的加固）

`HIRExecutor`（2147 行，`public final class HIRExecutor: DebugHookHost`）**已有**：

| 已有 | 行 | 与 `Interpreter` 侧对比 |
|---|---|---|
| `currentEnv: Environment` | 281 | ⚠️ **普通实例属性**（`Interpreter` 侧是 `ThreadLocal`） |
| `callStackNames: [String]` | 297 | ⚠️ 同上 |
| `deferStack: [[HIRBlock]]` | 308 | ⚠️ 同上（元素类型 `HIRBlock`，非 `Block`） |
| `callDepth: Int` | 288 | ⚠️ 同上 |

**缺**：`currentFuture`（取消上下文）· `debugDepth` · `scheduler` · `suspendMode` · 任务表（`cpsTasks` + 锁）。

⚠️ **必须随迁的加固（本件新发现，不写进规划会重犯旧缺陷）**：
`Interpreter` 侧那四项**全部**是 `ThreadLocal`，且注释把原因写死了 ——

> 「此前该属性在 worker 线程上被无条件 `+=` / `-=`，与 main 线程的同类操作产生**数据竞争**
> （SIGTRAP/SIGSEGV）」（`Interpreter.swift` L128 附近，`debugDepth` 的说明）

HIR 执行器目前**单线程**（无并发），所以这四项是普通属性**是对的**；一旦 `G-3` 引入 worker 线程池
（挂起必然跨线程 resume），**必须同步改为 `ThreadLocal`**，否则会**原样重现**
`Interpreter` 已经付过代价的那个竞态。`Sources/PiniCore/Common/ThreadLocal.swift` 已存在，可直接复用。

### 1.9 控制流词汇表差异：`label` → `depth`（非机械的一处）

`SuspendEvaluator` 的控制流路由用 **AST 词汇表**（标签制）：`ControlSignal.returnSignal/breakSignal(label:)/continueSignal(label:)`，
`SuspendTaskCPS.LoopControl` 存 `label: String?`（driver 的 break/continue 路由循环在 L301–324）。

`HIRExecutor` 用 **depth 词汇表**（`HIRControlSignal.breakSignal(depth:)` / `continueSignal(depth:)`），
且文件头注释**明写这是刻意的**：

> 「the lowerer resolves labels to depths (ADR-014) … squeezing a depth into a label field would mean
> re-deciding the mapping inside every loop, which is how two channels drift apart while both look correct.」

⇒ 迁移时 driver 的那段路由循环**必须重写为 depth 制**（不是改类型名），且 `LoopControl`
要记 `depth` 而非 `label`。这是 890 行里**唯一一处「不是换类型名就能过」**的地方。

---

## 2. 待裁（一条，带背景 / 选项 / 代价 / 建议）

### 裁定 1 — `.join` 的节点面：**新增节点**，还是**借既有 `call` 形状**？

**这是什么**（先展开编号）：`await` / `wait` 要在 HIR 里被表达，得在 `HIRExpr` 里有个落点。
现在没有。契约 §4.2 已经**预留**了这个位置，但它同时写着「`HIRLowerer` 须为 `.join`
**增加节点面**」—— 即**新增一个节点**。

**为什么现在要决定**：因为 `D-P4-26` 给 `G-3` 立的硬停条件是
「**迁移若须动契约那 60 个节点 ⇒ 停下先走 `spec §1.3`**」。
而契约 §4.2 说的是「须增加节点面」 ⇒ **两条判据在这里正面冲突**：

| 判据 | 口径 | 读出来的结论 |
|---|---|---|
| 契约 §4（已裁未实施） | 节点面是**已登记的预留**，实施它不是「改动既定条目」 | 可直接做 |
| `D-P4-26` 止损 | 「动那 60 个节点」⇒ 停 | 须先走 `spec §1.3` |

⚠️ **两处都可能被读成「显然」**，而它们指向**相反动作**。这正是需要裁决而不是执行者挑一条的形态。

**选项与代价**：

- **① 新增 `HIRExpr.join(inner:)`（照契约 §4.2 的字面）**
  代价 = **计数 60 → 61**；须走一次 `spec §1.3`（提议 → 影响评估 → 登记 → 落地 → 证据）；
  `tools/hir-contract-check.py` 的三方对照要同步；`HIRExecutor` 的「无 `default:`」穷尽 switch 会被强制认领（这是好事）。
  收益 = **语义诚实** —— 挂起**不是**「同步返回一个值」，用 `call` 形状表达它会让契约条目 8 的语义继续偏离实现。

- **② 借既有 `call(function:arguments:)` 按名形状**（如 `call("__join", [inner])`）
  代价 = **不动计数**（与 `argv` / `moduleRoot` / `Array.append` 同一先例，`D-P4-13` 已裁）；
  但**契约条目 8 的语义是「调用模块级具名函数」**，而 `join` 既非模块级、又非同步 ⇒
  偏差**再扩大一格**，且这个偏差**没有登记处**。
  收益 = 零治理成本、当批可落地。

**我的建议：①**（新增节点，走 `spec §1.3`）。理由三条：

1. **`D-P4-26` 的止损不是「不许动」，是「动之前先走流程」** —— ①正好走流程，且 `§1.3` 是**五步**、
   有影响评估与登记，不是重活。把它当障碍绕开，才是真正的违规。
2. **②的先例不适用**：`argv` / `moduleRoot` / `Array.append` 三者都是**同步、有返回值、无控制流副作用**的，
   `call` 的「按名回答」语义能容纳它们。`join` 要在求值点**挂起整个求值栈**（保存续体、释放 OS 线程），
   这不是「调用」能承载的 —— ②会让契约条目 8 从「范围偏窄」变成「**语义错**」。
3. **①的副作用是正向的**：`HIRExecutor` 的穷尽 switch 与核验脚本会**强制**这个节点被认领
   （`P1-2` 立的机制就是为此），比 ②的「按名回答」更不容易漂。

⚠️ **若裁 ②**，请在裁决里**同时指定**「`call` 条目 8 的偏差写在哪里」——
否则这条偏差会第三次以「无人登记的实现约定」形态留在仓里。

---

## 3. 分批建议

> ⚠️ **每批须单独点名**；本件不构成开工授权。批次切法 = **按 §1.5 的分层**，
> 而不是按「用例数平均」—— 理由同 `G-2`：**归因粒度决定后续判断质量**。

| 批 | 名称 | 内容 | 判据（可测） | 规模 |
|---|---|---|---|---|
| **`G-3a`** ✅ **已交付 2026-09-17** | **L1 并发内建降载登记** | `sleep` / `Error` / `CancelError` 三个内建加降载规则。⚠️ 三者**已在内建注册表登记**（`BuiltinRegistry.swift` L142 / value 组）⇒ 照 **`G-2a` 的「表即白名单」**先例：降载层与执行器**读同一张表**，杜绝「降载接受、执行器不答」的半支持 | **该簇 17 条的 `call to unknown function` 缺口归零**（⚠️ **不承诺转绿** —— 见 §1.5 遮蔽）；无新增红；三通道探针零位移 | 小–中（机械） |
| **`G-3b`** | **L2 异步体 return 位的 `Result` 上下文** | `HIRLowerer` 对 `=>` 异步函数体的 `return` 位给 `ok(...)` / `err(...)` 一个 `Result` 上下文 | 该簇 **9 条的 `'ok' construction` 缺口归零**（同上，不承诺转绿）；无新增红 | 中（降载层） |
| **`G-3c`** | **L3 本体：`.join` 节点面 + HIR 侧 CPS 求值器** | ① 按 §2 裁决落节点面（含走 `spec §1.3` 一次）② `SuspendEvaluator` 的薄外壳换输入类型（`Expression`→`HIRExpr`、`Statement`→`HIRStmt`、`evaluateExpression`→HIR 同步求值）③ driver 控制流路由改 **depth 制**（§1.9）④ `HIRExecutor` 补 `currentFuture` / `debugDepth` / `scheduler` / `suspendMode` / 任务表，**并把已有四项改线程本地**（§1.8） | **31 条逐条转绿**；无新增红；**`CPSDifferentialTests` 14 条两臂改指后仍逐字节一致**（§1.6 第 3 条）；契约计数按 §2 裁决落定并 clean；**若须动 60 节点而未走 `§1.3` ⇒ 本批作废** | **大** |
| **`G-3d`** | **B 类 43 条改指**（与 `G-3c` 同批或紧随） | `StructuredConcurrencyTests` / `SuspendRuntimeTests` / `CPSDifferentialTests` 三文件的入口由 `Interpreter` 改指 HIR 挂起入口 | 43 条**改指后仍全绿**；且**判据仍能失败**（注入变异时转红，防「改指即假绿」） | 小–中（机械） |

**依赖顺序**：`G-3a` → `G-3b` → `G-3c`（`G-3d` 随 `G-3c`）。
`G-3a` / `G-3b` **互不依赖**，可并行（但 D3：重任务不并行）。

### 3.1 为什么把 `G-3a` / `G-3b` 单列（而不是并入 `G-3c`）

1. **它们不依赖 CPS** —— 是纯降载层工作，**风险与本体完全不同类**。混在一起，
   一旦本体卡住（例如 §2 裁「须先走 `§1.3`」），前置工作会被**一起搁置**。
2. **它们有独立判据**（缺口归零 + 无新增红），且**可独立回退**。
3. **`26 / 31` 的体量**：前置占验收面的八成以上 —— 把它当「本体的准备动作」会**严重低估它**，
   而 `P4-1a` 的教训正是「规划预期 7→3，实测 7→6」。

### 3.2 ⚠️ 一处**不建议**的做法

**不要把 `G-3a` / `G-3b` 的「转绿数」写进任何验收表**。按 §1.5 的遮蔽，两批做完后
**`G-3` 的 31 条大概率仍红**（只是红的理由从 `sleep` 变成 `join`）。
若把它们写成「转绿 N 条」，下一批的读者会把「N 条没转绿」读成「`G-3a` 失败」——
`P4-γ` 规划件 §8.3 已经记过一次同类（口径写错会直接改变裁决）。

---

## 4. 每批必跑（沿用上游 §4 / `P4-γ` 的三条）

1. **全量回归（默认方向）** —— 先报「**执行类数 vs 基线 115**」；读数须用 `tools/hir-chunk-run.py`（护栏会作废无效读数）。
2. **`PINI_INTERP_ENGINE=ast` 方向** —— `G-3a` / `G-3b` **必须跑**（它们改降载层，触及两引擎共享路径）；
   `G-3c` 期间若改动触及引擎分派或 `ProgramRunner`，亦须跑一次（`P4-γ` §8.4 速度侧第 1 条）。
3. **全量探针 + 与冻结件逐夹具对账**（Δ 全 0 或逐条说明）；契约核验脚本 `tools/hir-contract-check.py` clean。

---

## 5. 止损点

- **`G-3c` 的硬停（`D-P4-26` 原文）**：若迁移须改动契约那 **60** 个节点 ⇒ **停下先走 `spec §1.3`**。
  ⚠️ **本件 §2 的裁决就是这条的落地**：裁 ① 时，`§1.3` 是**计划内动作**，不是止损触发。
- **`G-3a` / `G-3b`**：若实测发现该簇缺口**不是**「漏登记 / 漏上下文」而是更深的结构问题
  （例如 `sleep` 需要线程化运行时）⇒ 停下回报，不硬做。
- **`G-3c` 规模**：若 `SuspendEvaluator` 的薄外壳换型**需要重写 `evalK` 的控制流结构**
  （而非逐 case 换类型）⇒ 停下回报重估 —— §1.2 的「薄外壳」判断若被推翻，本件的分批依据随之失效。
- **`G-3d` 假绿**：改指后 43 条若**全绿且注入变异也不转红** ⇒ 该套判据已被掏空（`D-P4-21` 同族），
  停下回报。

## 6. 不做范围

- **不改契约正文**（`docs/spec/hir-contract.md` 的改动只在 §2 裁 ① 后、且随 `spec §1.3` 一并发生）。
- **不动 `SuspendScheduler` / `Scheduler` / `Value.swift`**（§1.3：不在删除面内）。
- **不做** L4 那 3 条错误通道（归乙组 `D2`，须先裁口径）。
- **不做** LLVM 侧并发运行时（乙组 `D3` 未裁：建议维持搁置）。
- **不修**在册工单（`run-llvm` 退出码 · `SuspendRuntimeTests` 偶发信号 11 · 测试基建 SIGPIPE 余项）。
- **不把本规划当开工授权**（每批须单独点名）。

---

## 7. 复现方式（勘测本规划所依据的全部读数）

```sh
# §1.1 规模
wc -l Sources/PiniCore/Interpreter/Interpreter.swift Sources/PiniCore/Interpreter/SuspendEvaluator.swift

# §1.2 SuspendEvaluator 的分层结构（按 func 定位行段）
grep -n "func \|struct \|enum \|class \|// MARK" Sources/PiniCore/Interpreter/SuspendEvaluator.swift

# §1.3 不在删除面内的三个文件之依赖
grep -n "^import\|Expression\|Statement\|Interpreter" \
  Sources/PiniCore/Interpreter/SuspendScheduler.swift Sources/PiniCore/Interpreter/Scheduler.swift

# §1.4 验收面：46 用例 / 31 失败 + 逐条归因
swift test --filter "PiniTests.ConcurrencyTests/test|PiniTests.JoinAllTests/test|PiniTests.JoinWithinTests/test|PiniTests.CancellationTests/test" 2>&1 \
  | grep -E "' (failed|passed)|Executed"
swift test --filter "PiniTests.ConcurrencyTests/test|PiniTests.JoinAllTests/test|PiniTests.JoinWithinTests/test|PiniTests.CancellationTests/test" 2>&1 \
  | grep "error:"

# §1.4 补充：夹具级首缺口（7 目录 71 条 .pini；含一个 39/32 的口径差：夹具数 ≠ 用例数）
python3 - <<'PY'
import os,subprocess,glob,re,collections
R=os.getcwd(); A=collections.Counter()
for d in ['ConcurrencyTests','JoinAllTests','JoinWithinTests','CancellationTests',
          'StructuredConcurrencyTests','SuspendRuntimeTests','CPSDifferentialTests']:
    for f in sorted(glob.glob(f'{R}/Tests/PiniTests/{d}/*.pini')):
        try:
            p=subprocess.run(['.build/debug/pini','run',os.path.relpath(f,R)],cwd=R,
                             capture_output=True,text=True,timeout=8,start_new_session=True)
            o=(p.stdout or '')+(p.stderr or '')
        except subprocess.TimeoutExpired: o=''
        m=re.search(r"unsupported feature '(.+?)'",o)
        A[(m.group(1).strip() if m else '[other]')]+=1
print(A.most_common())
PY

# §1.6 B 类 43 条现状
swift test --filter "PiniTests.StructuredConcurrencyTests/test"
swift test --filter "PiniTests.SuspendRuntimeTests/test|PiniTests.CPSDifferentialTests/test"

# §1.7 节点计数与 .join 的降载处置
grep -n "case .join:" Sources/PiniCore/HIR/HIRLowerer.swift
grep -n "join\|挂起" docs/spec/hir-contract.md

# §1.8 HIRExecutor 已有的状态
grep -n "private var \|private let \|public var " Sources/PiniCore/Interpreter/HIRExecutor.swift
```

---

## 8. 本件相对上游规划的三处订正（如实登记）

| # | 上游表述 | 实测 | 处置 |
|---|---|---|---|
| 1 | 删 **4673** 行（`P4-γ` 规划件 §1.1，`P4-0` 时点） | **4100** 行（`Interpreter` 3210 + `SuspendEvaluator` 890） | 本件 §1.1 订正；`G-6` 的规模账须按 4100 读 |
| 2 | `G-3` = 「890 行迁移」（五单元表） | 31 条**全部**死在降载层/类型层；**26 条属前置**，`join` 直接暴露仅 2 条 | 本件 §1.5 / §3：切为 `G-3a`–`G-3d` 四批 |
| 3 | `P4-β`：B 类 43 条「保持驱动 `Interpreter`（`R1/R2` 的对象）」 | 43 条**实测全绿**（翻转够不到进程内构造） ⇒ 性质是「**改指**」不是「**转绿**」 | 本件 §1.6；并入 `G-3d` |

## 9. 记号说明（`R1` / `R2`）

按 **`D-P4-30`** 归一口径读：**`R1` = 保（迁到 HIR）· `R2` = 弃（移除能力）**。
⚠️ 契约 §4.2 写「CPS 路线已裁 **`R2`** —— 单列一格迁到 HIR」⇒ **那里的 `R2` 指的是「保」**
（旧记号，与本仓现行口径相反）。`D-P4-30` 的订正清单当时只点了
`docs/issue-selfhost-probe-plan-2026-09-13.md`，**未包含契约 §4.2 这一处**
⇒ 本件登记为 `D-P4-30` 订正范围的**遗漏一处**，建议随 `G-3c` 一并加订正指针（属文档动作，不涉语义）。


---

## 10. 交付实录（`G-3a`，2026-09-17）

**分支**：`agent/pini-dev/p4-gamma-g3a-builtins`（起点 `3cc2484`）｜**规模**：4 文件 / +173 −41

### 10.1 改了什么

| 文件 | 改动 |
|---|---|
| `Sources/PiniCore/Runtime/RuntimeOps.swift` | 按名表 `concurrencyBuiltins`（`sleep` / `Error` / `CancelError`）· `sleepMilliseconds` 参数规则 · `builtinSleep(milliseconds:checkpoint:)` 分片休眠 · `errorMessageArgument` · `builtinErrorConstructor` / `builtinCancelErrorConstructor` · `makeCancelError`（自解释器迁入）· `builtinLocation`（两引擎共用同一常量） |
| `Sources/PiniCore/Interpreter/Interpreter.swift` | 五处改为**委托**共享层（`Error` / `CancelError` / `sleep` 三分支 · `makeCancelError` · `builtinLocation`）⇒ 两引擎不各持一份规则 |
| `Sources/PiniCore/HIR/HIRLowerer.swift` | 新增降载规则，**白名单读同一张表**（照 `G-2a` 定式） |
| `Sources/PiniCore/Interpreter/HIRExecutor.swift` | 新增按名分派块，**读同一张表** |

**未动**：契约（计数不变，核验 `clean`）· `SuspendScheduler` / `Scheduler` / `Value.swift` · 测试文件 · `cli/`。

### 10.2 判据（全部实测）

| 判据 | 读数 |
|---|---|
| **首缺口归零** | **41 条**夹具（7 目录 71 个 `.pini`）的 `call to unknown function` **归零**：`sleep` 33 · `Error` 7 · `CancelError` 1 |
| **无新增红** | 全量回归 **64 条失败，与基线集合相等**（fixed 0 / new 0 / still 64） |
| **两方向一致** | `PINI_INTERP_ENGINE=ast` 方向 64 条，与默认方向**逐条相同**（= 本批只动 HIR 侧的证人） |
| **契约** | `tools/hir-contract-check.py` **clean**（61/61 × 三锚点） |
| **探针** | 320 夹具 / OK 255 / PACKAGE_MEMBER 27 / WARN_CHANNEL_ASYMMETRY 20 / FRONTEND_FAIL 11 / WARN_LLVM_RC_UNPROPAGATED 4 / CHANGE_REFERENCE 2 / HARNESS_DEPENDENT 1 · **FLIP BLOCKERS 0** · leaks 0 —— 与基线**逐槽相同** |
| **变异反证（级 2）** | 单删表内 `sleep` 条目 ⇒ `unknown-fn: sleep` 恢复 **33**、`'ok'` 由 50 **精确回到 17**、`'err'` **不变 8**、其余三类不变 ⇒ **只红对应、不外溢**；变异版 `unknown function` 名单只剩 `sleep` ⇒ 证明 `Error` / `CancelError` 仍由表回答 |

⚠️ **口径（读数字前先看）**：§1.4 的「17 条」是**测试面**（前四类 46 用例里的失败数），§10 的「41 条」是**夹具面**（7 目录 71 个 `.pini`，含 B 类三目录）。两者都对，分母不同 —— 同 `P4-γ` 已记录的口径族。

### 10.3 ⚠️ 两处必须记账的边界（本格实测发现）

1. **探针不覆盖并发簇** —— 实测 7 个并发目录的夹具在探针的 **6 根里是 0 条**（根集 = `examples/` + `CodeGen/HIRTests` + `CodeGen/IRExecutionTests` + `RuntimeBackendTests` + `OptionalTests` + `CodeGen/IRPrintGoldenTests`）。⇒ 本格的「探针零位移」**是必然的、不构成对本格改动的证据**；真证据是上表的首缺口归零 + 变异反证 + 全量集合相等。（判据失明的「覆盖在而区分力不在」形态。）
2. **下一层缺口** —— 41 条剥离后**不是转绿**，而是落到下一层（实测 `'ok'` 17 → 50、`'err'` 0 → 8，合计恰 +41 ⇒ 归因闭合）。`joinAll` / `joinWithin` / `isCancel` **不在本批表内**（其回答要与 `Future` 值打交道，HIR 侧无表示）⇒ 归 `G-3b` / `G-3c`。

### 10.4 未做范围

不改契约 · 不动调度器与值层 · 不做 L4 错误通道（归乙组 `D2`）· 不修在册工单 · 不 push。

# P4-γ / `G-3` 规划：并发迁移（`R1` = 保能力、迁到 HIR）

> **批**：`P4-γ` 子批 **`G-3` 前置规划**（**纯规划**）｜**日期**：2026-09-17｜**状态**：§2 已裁 ①（2026-09-17；`.join` 节点面走 `spec §1.3`，已落 `docs/spec/adr/adr-040-hir-join-node.md`，契约 60 → 61）· **`G-3a` ✅ 已交付（2026-09-17，见 §10）** · **`G-3b` ✅ 已交付（2026-09-17，见 §11）**
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
| **`G-3b`** ✅ **已交付 2026-09-17** | **L2 异步体 return 位的 `Result` 上下文** | `HIRLowerer` 对 `=>` 异步函数体的 `return` 位给 `ok(...)` / `err(...)` 一个 `Result` 上下文 | 该簇缺口归零（实测：夹具面 **60 → 1**，剩的 1 条是**另一位置**，见 §11.2）；无新增红（实测 64 → 64，逐条集合相等）｜**不承诺转绿 —— 实测 0 条转绿**（缺口落到下一层 `join`）｜见 §11 | 中（降载层） |
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

---

## 11. 交付实录（`G-3b`，2026-09-17）

**分支**：`agent/pini-dev/p4-gamma-g3b-result-context`（起点 `276d1c1`）｜**规模**：1 文件（`Sources/PiniCore/HIR/HIRLowerer.swift`）+ 文档。

### 11.1 改了什么 —— 一条规则，三处消费

新增 `asyncBodyReturnType(declared:isAsync:)`：**`=>` 且声明返回非空 ⇒ `.result(ok: 声明返回)`**。三处消费，**读同一份规则**：

| 处 | 作用 |
|---|---|
| `lowerFunction` 的 `context.returnType` | **return 位的期望类型**（`ok(...)` / `err(...)` 由此拿到上下文） |
| `HIRFunction.returnType` | **定义侧**（体返回的就是一个 Result 值） |
| 签名表 `signatures[...]` | **调用侧**（两处若不一致就会漂 —— 照 `effectiveReturnType` 已有的同一致性纪律办） |

**为什么是「照权威写」而不是「新定一条规则」**（两条独立权威，本格实测）：

1. **前端检查器** `TypeChecker.bodyReturns` 明写：`=>` 函数**体内 return 的期望类型**为 `Result<T, Error>`；`=> ()` 返回空数组、沿用 void 放行路径。实测：异步体裸写 `return 10` 在 HIR 侧得 `E4-001`（类型错）⇒ **检查器早已要求 Result，只有降载层没跟上**。
2. **解释器**从另一侧给出同一条：`Interpreter.joinFuture` 的注释 ——「体已返回 `Result` 用例（`return ok(v)` / `return err(e)`）→ 原样透传；体返回普通值 → 自动包 `ok(v)`」。

⇒ 本格把这个位置**静态地**写成 `Result`，是同一条规则的另一半，不是第二条规则。

**未动**：`=> ()`（void）异步体 —— 语言**没有可命名的 unit 载荷类型**，且实测 **0 条**语料在 void 异步体里构造 `ok(...)` ⇒ 沿用 void 路径（登记为已知边界）；方法侧的 `=>` —— 全仓实测 **0 个**异步方法；契约 · 调度器与值层 · 前端检查器 —— 一律未动。

### 11.2 判据（全部实测）

| 判据 | 读数 |
|---|---|
| **首缺口归零**（夹具面：8 目录 83 夹具） | 旧 **60**（`'ok'` 52 + `'err'` 8）→ 新 **1**；**逐夹具对账：59 条变化全部**是 `'ok'`/`'err'` → 下一层，**其余 24 条一字未动** ⇒ 无新增红（夹具面） |
| 剩的那 1 条 | `testDiffMatchJoinInBody` 的 `match ok(1):` —— **同一报文、不同位置**（`match` 检体位，非 return 位）⇒ 本批**不认领**，另立工单 `docs/issue-hir-result-construction-without-context-2026-09-17.md` |
| 迁移去向（归因闭合） | `join 未降载` 40 · `cancel` 方法 6 · `joinWithin` 5 · `detach` 3 · `joinAll` 2 · `[other]` 2 · `try-else 位置` 1 = **59** —— 全部是**计划内的下一层** |
| **全量回归**（默认方向，3 块） | **64 → 64，逐条集合相等**（转绿 0 / 新增红 0 / 仍红 64）；分块 **26+18+20** 与基线逐块相同；**115/115 类全跑到、0 次信号** |
| `PINI_INTERP_ENGINE=ast` 方向 | 测试面 **64 条与默认方向逐条相同**；夹具面 ast 引擎 83 条中 2 条 stderr 差异，经**同二进制三次连跑**判定为**夹具自身非确定**（并发语义警告的行号随工位漂移）—— 不归本批 |
| 契约 | `clean`（**61/61** × 三锚点） |
| 探针 | **320** 夹具 · 逐槽相等（`OK 255` / `PACKAGE_MEMBER 27` / …）· 逐夹具**零位移（0/320）** · `FLIP BLOCKERS 0` |

⚠️ **探针那条对本批无区分力**（与 `G-3a` 同一失明形态）：探针 6 根**不含并发簇**（实测 7 个并发目录 0 条）⇒ 真证据是「首缺口归零 + 逐夹具账目 + 全量集合相等」。

⚠️ **口径（读数字前先看）**：§1.4 的「9 条」是**测试面**（46 用例里的失败数）；本批的「60」是**夹具面**（8 个目录 83 个 `.pini`）。两者都对，**分母不同**。

⚠️ **本批不转绿**：全量回归 **0 条转绿** —— 缺口原样落到下一层（`join` 40 条），归 `G-3c`。这与本规划 §3.2 的「不要把转绿数写进验收表」一致。

### 11.3 一处过程事故（如实登记）

本机沙箱把 `git stash` **执行了两遍**：第一遍已把改动入栈，第二遍因工作树已干净而打印「没有要保存的本地修改」⇒ 我据第二遍的输出**一度以为改动丢失**。**处置**：用三方 md5 交叉验证（工作树文件 = 改前备份 = `HEAD` 版，三者相同 ⇒ 改动确在栈里），`stash pop` 后以 `grep -c asyncBodyReturnType` = 3 复核。（同族事实：`git commit` 也会跑两遍，见 `pini-repo-handbook`。）

### 11.4 未做范围

- **不修**剩的那 1 条（`match` 检体位）—— 另立工单，只登记。
- 不动 `=> ()` void 异步体与方法侧 `=>`（边界见 §11.1）。
- 不做 `G-3c` 的 `.join` 节点面 / CPS 迁移（那是缺口的下一层）。
- 不修在册工单 · 不 push。

**下一单元**：`G-3c`（`.join` 节点面 + HIR 侧 CPS 求值器）或点名其他，**待点名**。

---

## 12. `G-3c` 开工前勘测（2026-09-17，**只读**；一项待裁 + 一项待认）

> **性质**：**零改动**（未动 `Sources` / `Tests` / 契约正文；本节是唯一新增）。
> **全部读数现测**，采集于 HEAD `a6e17ac`（`G-3a` / `G-3b` 交付之后）。
> ⚠️ **本件 §1 的事实基础采集于 `1438887`**，早于那两批 ⇒ 其中「L1 **17 条** · L2 **9 条**」
> 两行**已被消化**，**不再反映现状**。§12.1 给出**现行**缺口面；§1.5 的分层结论仍然成立
> （只是 L1/L2 两层已归零）。

### 12.1 现行夹具面：8 目录 83 夹具，首缺口逐条归类

采集：`PINI_INTERP_ENGINE=hir pini run <夹具>`，逐条取**首缺口**（83 / 83 条，无排除）。

| 首缺口 | 条数 | 属 `G-3c` 面？ |
|---|:---:|---|
| `expression 'join' is not yet lowered to HIR` | **43** | ✅ 本体（§2 裁 ① 的节点面已落，**降载规则与执行面未落**） |
| `statement 'detach' is not yet lowered to HIR` | **3** | ✅ **但 §3 的批表未列** ⇒ 见 §12.3 裁定 `D-G3c-1` |
| `call to unknown function 'joinWithin'` | **6** | ✅ **§3 未列**（`G-3b` §11.2 记为「下一层」） |
| `call to unknown function 'joinAll'` | **1** | ✅ 同上 |
| `method 'cancel' calls are later grids` | **6** | ✅ 同上 |
| 类型 / 语义层拒绝（`rc=1`，非 `unsupported`） | 17 | ✘ 归 `G-4·G-5` 与乙组 `D2`（含 `TaskIsolationTests` 的**负向**夹具 —— 它们**本就该被拒**） |
| 跑通 / 仅警告（`rc=0`） | 5 | ✘ 含 1 条**非确定**（`testWorkStealingOccurs`，`G-3b` §11.2 实测：并发警告行号随工位漂移） |
| `try-else is only supported as a statement or a variable initializer` | 1 | ✘ 另一层 |
| 空报文（`testDiffMatchJoinInBody`） | 1 | ✘ **已有主**（`match` 检体位的 `ok(1)`，`G-3b` §11.2 立的单） |
| **合计** | **83** | |

⇒ **属 `G-3c` 首缺口面的 = 59 条**（43 + 3 + 6 + 1 + 6）。
⚠️ 与 `G-3a` / `G-3b` **口径相同**：这是**夹具面**（`.pini` 条数），不是**用例面**。
本件 §1.4 的「31」是**用例面**（46 用例里的失败数），两者分母不同、都对。

采集命令（可复跑）：

```sh
export PINI_LLVM_BIN=/opt/homebrew/opt/llvm/bin
for d in ConcurrencyTests JoinAllTests JoinWithinTests CancellationTests \
         StructuredConcurrencyTests SuspendRuntimeTests CPSDifferentialTests TaskIsolationTests; do
  for f in Tests/PiniTests/$d/*.pini; do
    PINI_INTERP_ENGINE=hir pini run "$f" 2>&1 | grep -m1 -o "unsupported feature '[^']*'"
  done
done | sort | uniq -c | sort -rn
```

### 12.2 ⭐ 结构发现：`suspendMode` 的**生产面是 `false`**

- `Sources/PiniCore/Interpreter/Interpreter.swift:42` = 声明（`var suspendMode: Bool = false`）。
- **全仓赋值点实测只有 `Tests/`**：`Tests/PiniTests/CPSDifferentialTests/CPSDifferentialTests.swift:23`
  与 `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift` 的 8 处；
  `Sources/` **零赋值**（`grep -rn "suspendMode = " Sources/` 只命中一行注释）。
- `Sources/PiniCore/Run/ProgramRunner.swift` 的文件头注释**自陈**：挂起面
  （`suspendMode` / `scheduler` / `runSuspendable`）**在 HIR 引擎上未实现**。

⇒ **现行发布语义 = 阻塞 join**（`GCDScheduler` + 真线程；`joinFuture` 阻塞当前线程）。
那 890 行的 CPS 求值器（`Sources/PiniCore/Interpreter/SuspendEvaluator.swift`）
**只在测试把 `suspendMode` 翻成 `true` 时才被执行**。

⭐ **这条改变 `G-3c` 的切法** —— 它让「第一批」既能拿到判据、又是**真交付**：

| 批 | 内容 | 判据 | 触契约？ |
|---|---|---|---|
| **`G-3c-1`** ⏳ **前置已就绪：`detach` 节点面 ✅ 已落（`ADR-042`，契约 61 → 62）** | **异步管道 + 阻塞 join**：① `HIRFunction` 补**异步标记**（降载层已在 `HIRLowerer.swift:1110` 用 `isAsync` 算返回类型，**标记本身未进 HIR**）② 执行器补异步 spawn 面（`FutureValue` / `currentFuture?.addChild` / `scheduler.spawn` / `closeScope` / `flipIfLeaked` / `reject`，镜像 `Interpreter.swift:3011–3050`）③ `.join` 降载规则 + **阻塞** join ④ `Future` 值层的内建与方法（`joinWithin` / `joinAll` / `cancel` / `isCancel`）⑤ `detach` | 上表 **59 条首缺口归零**；⚠️ 与 `G-3a`/`G-3b` **不同** —— 这批**应当真转绿**（阻塞语义**就是** AST 的制作面语义） | ❓ **仅 ⑤ 待裁**（§12.3） |
| **`G-3c-2`** | **真挂起 CPS**：890 行薄外壳的 HIR 镜像 + driver 路由改 **depth 制**（§1.9）+ `HIRExecutor` 四状态改 `ThreadLocal`（§1.8）+ `suspendMode` / `cpsTasks` | `SuspendRuntimeTests` 15 条 + `CPSDifferentialTests` 14 条**改指 HIR 后仍逐字节一致** ⇒ 与 `G-3d` 天然合流 | 否 |

**为什么切**（沿用 §3.1 给 `G-3a` / `G-3b` 单列的同一条理由：**风险不同类**）：

1. **阻塞 join** 是「照已有的生产语义补齐」；**真挂起**是「跨线程上下文还原」——
   两者一旦混批，本体卡住会把可交付的一半一起拖住。
2. **访问面代价只落在 `G-3c-2`**（本批实测）：`G-3c-1` 的改动**全部在 `HIRExecutor.swift` 文件内**
   （异步臂加在 `case .call`（`HIRExecutor.swift:431`）、join 加在 `case .join`（同文件 `:1110`，现为 fail-loud）），
   **不涉及访问面调整**；而 `G-3c-2` 若照 `SuspendEvaluator.swift` 的先例**另立文件**，
   则该文件的 `private` 成员（`evaluate` `:373` / `execute` `:1506` / `executeStatements` `:1465` /
   `executeBlock` `:1443` / `pushDeferScope` `:1411` / `popDeferScope` `:1422` / `currentEnv` `:281` …）
   **必须放宽为 `internal`**，否则**跨文件扩展读不到**。另一条路是写在同一文件内
   ⇒ `HIRExecutor.swift` 由 **2177** 行涨到约 **3100** 行。**两条路都不该混进第一批。**

### 12.3 待裁

> ✅ **两项均已裁（2026-09-17，用户）**：`D-G3c-1` 取 **①（新增节点）** · `D-G3c-2` 取 **①（切）**。
> 落位：`D-P4-33` / `D-P4-34`（`docs/issue-hir-p4-plan-2026-09-16.md` 决策记录）。
> ⚠️ **`D-G3c-1` 的裁决与本节的建议相反** —— 本节建议 ②、用户取 ①。
> 下面的建议段**原样保留**（留痕：当时被建议了什么），理由以裁决为准。
> `detach` 节点面**已随之落地**（`ADR-042`，契约 **61 → 62**）。

**裁定 `D-G3c-1` —— `detach` 要不要新节点？**（唯一触契约的一项）

**这是什么**：`detach <expr>` 是语言里的一条语句（「求值得到一个 `Future` 值，把它从父任务剪枝、
不参与父返回时的自动取消」）。`HIRStmt` **16 case 且无 `detach`**；契约 §3 同样只列 16 条；
§4 预留位**只剩 `char` 一条**（`§4.2` 已随 `join` 兑现而作废）
⇒ **`detach` 没有预留位**，新增即 **61 → 62**。

| 选项 | 做什么 | 代价 |
|---|---|---|
| **①** | 新增 `HIRStmt.detach` 节点 | 契约 **61 → 62** + 走一次 `spec §1.3`（**第 2 次**，第 1 次是 `ADR-040`）+ 三锚点（`llvm` / `printer` / `interp-hir`）同步认领 + 下游引用「61」的文字跟改（`docs/spec/hir-contract.md` §0.4 与本规划件至少各一处） |
| **②** | 降成既有形状（`detach <expr>` → 求值 + 调 `Future` 的一个方法，即走 `call` 的按名形状） | 零治理成本；⚠️ 须登记「`detach` 走 `call` 形状」这一实现约定（`§2` 裁 `join` 时点名的风险：**偏差必须有登记处**） |

**我的建议：②**。判据与 §2 裁 `join` 用 ① 时**是同一把尺**，只是**结论不同**：
§2 的推理是「`join` 要在求值点**挂起整个求值栈**（保存续体、释放 OS 线程），不是『调用』能承载的」；
而 `detach` **不需要挂起** —— 它是「先把表达式求成一个值，再调该值的一个方法」
（AST 侧就是 `fut.detachFromParent()`，`SuspendEvaluator.swift:627` 一行），
正落在 §2 自己认可的那类先例里（`argv` / `moduleRoot` / `Array.append`：**同步、有副作用但无控制流**）。
⇒ 两个节点**性质不同**，同一把尺得出相反结论，**不是**两处判据打架。

⚠️ 若裁 **①**，请在裁决里**同时指定**「契约计数 61 → 62 后，哪些下游文字要跟改」——
`docs/spec/hir-contract.md` §0.4 的那句「**45 表达式节点 + 16 语句节点 = 61**」至少要被跟改，
否则下一位读者会拿旧基数核验。

**裁定 `D-G3c-2` —— 认不认 §12.2 的两批切法？**

不认则按 §3 原表单批做（代价即上表「触契约」列与访问面那两条，**一次性承担**）。

### 12.4 本节未覆盖（如实登记）

- **未跑**全量回归 / 探针 / `ast` 方向（重任务，且本批只读）⇒ 本节**不含**任何回归或探针读数。
  本节的 83 条**全部**来自 `pini run` 逐夹具直跑（8 目录，约 1.5 分钟）。
- **未测** `G-3c-2` 的规模（890 行镜像的**实际**行数、`private` 放宽的**处数**）——
  上表 §12.2 列的是**已定位的关键成员**，不是完整清单；须在 `G-3c-2` 开工时现测。
- **未动**任何文件：`Sources` / `Tests` / 契约正文 / 本件正文（§12 是唯一新增）。


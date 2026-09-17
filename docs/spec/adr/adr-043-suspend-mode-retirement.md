# ADR-043: 挂起模式实现暂时退役 —— 并发面判定为「不完善」

> **状态**：**active**（2026-09-17 用户裁决）｜**类别**：语言级（稳定性分级降级）
> **本件范围**：`§1.3` 第 1–5 步同批交付（提议 / 影响评估 / 登记 / 落地 / 证据登记）。
> **性质**：**稳定性分级降级 + 实现退役登记**，**不是能力移除** ——
> `await` / `wait` 两个关键字与其语义**一条不变**；退役的是「挂起模式」（释放当前 OS 线程）
> 这一**实现形态**，以及承载它的求值器与调度器。
> **是否破坏性**：**否**。现行发布语义就是阻塞 join（见 §2.1 两条实测），
> 故本次变化对今天的用户程序**零可见影响**；受影响的是**规范对自身状态的陈述**与**评测面**。
> **前例**：`ADR-042`（`detachStmt` 节点面）——本件逐项照其形态办，差异见 §1 末。

## 1. 提议（要解决什么）

### 1.1 触发：规范与实现之间的状态倒挂

规范把异步语义模型（`G12`）定级 **Stable**，并把「挂起模式」写进正文，含一条 **MUST**：

- `../pini-spec-v0.md` §3.1 状态头：`T7 异步语义正式化 v0.43.0 → Stable`；
- §3.1.1「挂起模式」条：`Future` 未决时任务**挂起**——保存续体、**释放当前 OS 线程**（非阻塞）；
- §3.1.3「挂起模式上下文还原（**MUST**）」：跨线程恢复时必须还原五项解释器上下文。

**而实测（2026-09-17，`5d592a2`）显示：这条路径在生产面上从未被启用。**

| 实测项 | 读数 | 判据命令 |
|---|---|---|
| `suspendMode` 的**生产**赋值点 | **0 处**（`Sources/` 只余声明 `= false` 与三处读取） | `grep -rn "suspendMode = " Sources/` |
| `suspendMode` 的**测试**赋值点 | **8 处**（全在 `Tests/`） | 同上（`Tests/`） |
| `SuspendScheduler` 的实例化点 | **0 处在 `Sources/`**，**7 处全在 `Tests/`** | 全仓检索该类型名 |
| `Interpreter.swift` 对 `suspendMode` 的自述 | 「**阶段 B（B-2 探针）开关**」 | 该文件状态字段上方注释 |

⇒ **现行发布语义 = 阻塞 join**（`GCDScheduler` + 真线程）；那 890 行 CPS 求值器
（`Sources/PiniCore/Interpreter/SuspendEvaluator.swift`，全文是 `extension Interpreter`）
**只在测试把开关翻成 `true` 时才被执行**。

### 1.2 用户裁决（2026-09-17）

原文：

> 「我说并发全都判定为不完善，认下这个不好做，而且很可能是**暂时退役**，
> 相信迁移之后会因为架构带来**重写加速度**。」

⇒ 处置方向 = **判定为不完善（降级）+ 实现暂时退役**，并**明确保留重写路径**。
`await` / `wait` 关键字**不删**（退役后两关键字行为相同，区别留作挂起回归时的语用位）。

### 1.3 为什么这不是「丢能力」（本件最要紧的一条）

规范 §3.1.1「同步/阻塞路径」条**自己写明了**替代关系：

> `wait` 为阻塞 join（占 worker 线程），**语义与挂起等价** —— 均经 `await`/`wait` 站点解构 `ok/err`。

⇒ 退役挂起，`await` / `wait` 的**语义**一条不变；丢的是**资源效率**（「释放 OS 线程」这一性质）。
再叠加 §1.1 的实测（该路径生产面从未启用）⇒ **本次变化的实质是「让规范诚实」**，
而不是「移除一项用户可达的能力」。**破坏性 = 否**（§1 头已声明）。

### 1.4 与 `ADR-042` 的差异（照其形态，但有一处不同）

`ADR-042` 是**新增契约条目**（语句 16 → 17），走 `§1.3` 是因为 `D-P4-26` 的硬停条件点名要求。
本件走 `§1.3` 的**理由不同**：`§1.2` 规定「触及 **Stable** 或跨 minor 破坏性 ⇒ **升级评审**」——
本件把 `G12` 的「挂起模式」部分**从 Stable 降级**，正落在那一条上。
⇒ **`§1.3` 第 2 步在本件是强制的**（不是形式主义），这就是本 ADR 存在的理由。

## 2. 影响评估（`§1.3` 第 2 步）

### 2.1 受影响构造与稳定性级别

| 构造 | 现级别 | 变更后 | 依据 |
|---|---|---|---|
| `await` / `wait` 的**阻塞语义**（现行唯一实现形态） | Stable | **Stable（不变）** | 规范自陈「语义与挂起等价」；本次不改其行为 |
| **挂起模式**（`suspendMode` + `SuspendScheduler`） | Stable | **Provisional** | 实现暂时退役、语义待重写 ⇒ 落入 `§1.2`「语法已定、语义可能调；允许变更，须迁移说明」 |
| 结构化并发不变契约（取消树 / B2-1 / B2-2 / 泄漏上浮 / `detach`） | Stable | **Stable（不变）** | 与线程模型无关，阻塞路径下完全成立；判据面实测仍在（见 §2.3） |
| 并发原语签名（`cancel` / `isCancel` / `join` / `joinAll` / `joinWithin`） | Experimental | **Experimental（不变）** | 规范已如此登记，本件不动 |
| 内建错误类型构造细节（`Error` / `CancelError` / `Result`） | Experimental | **Experimental（不变）** | 同上 |

⚠️ **为何不取 `Deprecated`**：`§1.2` 把它定义为「已弃用，**给定移除时间表**，明确退出」。
本件**不承诺移除**（`await` / `wait` 保留、挂起待重写）⇒ `Deprecated` 的语义与用户裁决不符，故不适用。

### 2.2 退役对象与规模（全部现测，`5d592a2`）

| 对象 | 行数 | 处置 |
|---|:---:|---|
| `Sources/PiniCore/Interpreter/SuspendEvaluator.swift` | **890** | 退役（其路径**本就在 `G-6` 删除面内**） |
| `Sources/PiniCore/Interpreter/SuspendScheduler.swift` | **159** | 退役（**新纳入** `G-6` 删除面 —— `Sources/` 零实例化） |
| `Interpreter` 成员：`suspendMode` · `cpsTasks` · `suspendTaskLock` · `runSuspendable` · `runSuspendableEntry` · `SuspendSignal` | — | 随 `G-6` 与 `Interpreter` 一并删 |
| `Sources/PiniCore/Interpreter/Scheduler.swift`（`GCDScheduler`） | 111 | **保留** —— 阻塞路径的默认后端，现行唯一实现 |
| `Sources/PiniCore/Interpreter/Value.swift`（`FutureValue` 取消树） | 562 | **保留** —— 与线程模型无关 |

### 2.3 评测面归因：43 条**逐条**（`§1.3` 第 2 步要求逐条列出用户可见影响）

三个测试类共 **43** 条（`CPSDifferentialTests` 14 · `SuspendRuntimeTests` 15 · `StructuredConcurrencyTests` 14）。

| 分类 | 条数 | 明细 | 处置 |
|---|:---:|---|---|
| **真退役** | **25** | `CPSDifferentialTests` **14/14**（经 helper 全部走挂起路径）+ `SuspendRuntimeTests` 第 5–15 条 **11 条**（全部使用 `runSuspendable` / `suspendMode` / `SuspendScheduler`） | 随退役删；**语料与语义条款先行保全**（§4.4） |
| **不退役 · 值层原语** | **4** | `SuspendRuntimeTests` 前 4 条（`testWhenResolvedDeliversValue` / `…FastPath` / `…Reject` / `testFanOutNonBlocking`）—— 该类文件头自陈「**不经由 `.pini` 求值器**」，直驱 `FutureValue.whenResolved` + `GCDScheduler` | **保留**（`FutureValue` 与 `GCDScheduler` 都不退役） |
| **不退役 · 结构化并发** | **14** | `StructuredConcurrencyTests` 全部 —— 测取消树 / 泄漏上浮 / `detach` / 检查点 | **保留**；驱动入口待改指（见 §2.4） |

⚠️ **本条推翻了本批开工前的一处估计**：曾把 `SuspendRuntimeTests` **整类 15 条**计入退役面
（依据是「该类名叫 Suspend」）。**实测前 4 条为零挂起 API 的值层原语** ⇒ 真退役是 **25 条**而非 29 条。
两条边界均已在 §2.3 具名，不静默。

### 2.4 `StructuredConcurrencyTests` 的可迁移性（实测，含**未能迁移**的具名）

该类 14 条里有 **8 条**是语言层端到端（经 `Interpreter().run(module:)`，**阻塞路径**）。
逐夹具直跑（默认引擎 = HIR）实测：

| 夹具 | rc | 结论 |
|---|:---:|---|
| `testCancelInterruptsRunningLoop` | 0 | ✅ **已可在 HIR 上跑通** ⇒ 可改指 |
| `testDeferStillRunsWhenTaskCancelled` | 0 | ✅ 可改指 |
| `testDetachBuiltinPrunesChildFromParent` | 0 | ✅ 可改指 |
| `testSynchronousProgramUnaffectedByCheckpoints` | 0 | ✅ 可改指 |
| `testDetachEscapeHatchSuppressesLeak` | 1 | ❌ `printing a Result value is outside the slice` |
| `testLeakedChildErrorFloatsToCallerResult` | 1 | ❌ 同上 |
| `testParentReturnCancelsUnjoinedChildTask` | 1 | ❌ 同上 |
| `testJoinedChildIsNotCancelledByParentReturn` | 1 | ❌ `type mismatch: result(ok: i32) is not i32` |

⇒ **4 条可迁移、4 条被下游缺口挡住**。挡住它们的两条缺口**均非本件引入**，且**都已有主**：
前者 = 在册的 `Result` 值打印缺口（用户 2026-09-17 已裁**维持现状**）；
后者 = 该工单 §4 登记的「同族待查」两条之一。
⇒ 本件**只登记**该边界，**不改指任何测试**（改指是独立动作，须单独点名）。

### 2.5 一处必须在规范里具名的能力边界

挂起退役后，阻塞 join **占用 worker 线程**：在有界池下，高扇出会耗尽线程池
（`SuspendRuntimeTests` 的 `testBoundedPoolCompletesHighFanout` / `testBackpressureBoundsInflight`
两条夹具测的正是这一性质，它们随退役删除）。
⚠️ 这不是「退役引入的缺陷」，而是**阻塞语义固有**、且**一直存在**的性质 ——
本件要求把它**具名写进规范**（§4.2 落地项之一），使之不再只存在于测试夹具里。

## 3. 登记（`§1.3` 第 3 步）

- **缺口台账**：新增 **`G66`**（本条），状态「已定义（退役登记）」、稳定性 **Provisional**。
- **ADR**：本件，登记入 `docs/spec/adr/adr-index.md`（状态列照邻居写 `active`）。
- **受影响构造**：`G12` 行（§3.1 的状态与稳定性列）与 `G62` 行（HIR `join` 节点的挂起语义）
  **须同批跟改** —— 否则台账里会同时存在「挂起 Stable」与「挂起已退役」两个状态源。

## 4. 落地（`§1.3` 第 4 步）

### 4.1 本件的落地面（**只动文档，不动源码**）

本批**不动任何源码**。理由：退役的删除动作**本就落在 `G-6` 的删除面内**
（`SuspendEvaluator.swift` 是既定删除项，`SuspendScheduler.swift` 新纳入）
⇒ 现在删会与 `G-6` 重复，且 `Interpreter` 上仍有保留面引用（须走外移）。

### 4.2 规范侧落点

| 位置 | 改什么 |
|---|---|
| §3.1 标题与状态头 | `Stable` → 分层标注：阻塞语义 Stable / **挂起模式 Provisional** |
| §3.1 证据栏 | `SuspendEvaluator` / `SuspendScheduler` 标为**已退役**，改指现行实现 |
| §3.1.1「挂起模式」条 | 标为**已退役（暂时）· 待重写**，保留语义描述供重写参照 |
| §3.1.1「同步/阻塞路径」条 | 改为**唯一现行实现形态**（不再是「默认后端」这一相对表述） |
| §3.1.3 上下文还原（MUST） | 标为**随挂起模式一并退役**（MUST 约束的对象已不在） |
| §3.1.4 探针边界 | 挂起相关的两条标注退役 |
| §3.1.5 稳定性与已知限制 | `G12 → Stable` 订正为分层；**新增**阻塞 join 的线程占用边界 |
| §3 台账 `G12` / `G62` 行 | 稳定性列与状态跟改；新增 `G66` |

### 4.3 语言参考侧落点

`../pini-reference-v0.md` 的 `await` 条（「释放当前 OS 线程（非阻塞）」一句）与
「挂起模式上下文还原（MUST）」段 —— 按 `§1.3` 第 4 步的**递交方向**，
语言参考是语言面细则的沉降处 ⇒ 同批改，保持两侧不出现相反陈述。

### 4.4 判据保全（本件的**实质交付**之一）

25 条随退役删除，但其中 **14 条差分测试**与 **11 条挂起运行时测试**是「重写挂起时」的规格来源。
⇒ 它们的 `.pini` 语料（25 个夹具）与语义条款**必须先落到登记处**，否则重写时只剩记忆。
⚠️ 理由同 `ADR-031` 的一条已立纪律：**「锁实现细节的断言退役前不得先行删除」**。

## 5. 证据登记（`§1.3` 第 5 步）

- 退役依据（生产面零启用）与规模读数，均在 §1.1 / §2.2 逐条给出判据命令与读数。
- 43 条归因表（§2.3）与 8 夹具直跑表（§2.4）为**本批实测**，采集于 `5d592a2`。
- ⚠️ **证据新鲜度**：命令示例所引行号均为**软证据**（按 `§1.4`，不参与 FRESH/STALE 判定）；
  符号定位（`suspendMode` / `SuspendScheduler` / `SuspendEvaluator`）才是硬证据。

## 6. 不做范围

- **不删任何源码**（退役的删除动作并入 `G-6`）。
- **不改指任何测试**（§2.4 的 4 条可迁移项须单独点名）。
- **不实现重写**（用户裁决明示其发生在「迁移之后」）。
- **不动 `G-4·G-5`**、不修在册工单、不 push。

## 7. 残留与待办（如实登记，不静默）

| 项 | 归属 |
|---|---|
| 「暂时」的**可测触发条件**未定义 | ⚠️ 无触发器的延期 = 静默永久退役。须在 `P5` 收口时**显式登记处置**（与 `P0d` 的 `char` 预留位同形处置） |
| `Interpreter.swift` 状态字段的「阶段 B（B-2 探针）」措辞 | 与规范的 `Stable` 不一致，属**过时措辞**；随 `G-6` 删该字段时一并消失 |
| 25 条语料的保全落点 | §4.4；须在本批交付中落地 |
| 4 条可迁移用例 | §2.4；改指须单独点名 |

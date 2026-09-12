# P1-5 勘测：调试/REPL 接口接缝（2026-09-13）

- 状态：**勘测完成（只读，未写代码）**；接缝方案待点名
- 层级：**宿主级** —— 引擎接口形态；不涉语言契约（层级判据见 `ADR-024 D6`）
- 隶属：`docs/issue-interpreter-hir-plan-2026-09-12.md` 的 **P1-5**（调试·REPL 接口预留）
- 关联：`docs/issue-hir-node-source-position-2026-09-12.md`（位置基准；**实测为 P4 前置、非本步前置**）

## 0. 一句话结论

**调试面（`debugHook` + `outputSink`）可引擎无关化，执行入口不可** ——
两者的可统一性不同，因此接缝有「浅」「深」两条路，**深度差异 = 一个量级**：
浅接缝（消耦调试面）在 P1 定位内；深接缝（引擎抽象层）**超 P1 定位，属 P2/P3 量级**。

## 1. 消费点全景（5 处，全部实测）

| # | 落点 | 角色 |
|---|---|---|
| 1 | `Sources/PiniCore/Interpreter/Interpreter.swift` | `debugHook` **声明**（引擎的属性） |
| 2 | `Sources/PiniCore/Interpreter/Interpreter.swift` | `debugPause` —— **全仓唯一构造 `DebugContext` 处** |
| 3 | `Sources/PiniCore/Interpreter/Interpreter.swift` | `debugPause` 的**全部 2 个调用点** |
| 4 | `Sources/PiniCore/Debugger/Debugger.swift` | `consult(ctx)` 消费上下文（**判据所在**） |
| 5 | `Sources/PiniCore/Debugger/DAPServer.swift` + `Sources/PiniCLI/main.swift` | **三处宿主装配**（DAP 1 处 + CLI 2 处） |

> 测试侧另有 `Tests/PiniTests/DebuggerTests/DebuggerTests.swift`（12 处装配，形态与宿主一致）。

## 2. 字段依赖（`Debugger.consult` 实测）

| 字段 | 消费点 | 用途 | 需真实位置？ |
|---|---|---|---|
| `location` | 断点匹配 + `StopEvent` + 源码行展示 | `bp.line == loc.line`、`sourceMap.line` | ✅ **唯一需要** |
| `depth` | `.over(let d): ctx.depth <= d` 单步跨过判据 | 步进语义 | ❌ 无关位置 |
| `callStack` | `backtrace` 命令 | 回溯展示 | ❌ 无关位置 |
| `variables` | `printVariable` 命令 | 变量查看 | ❌ 无关位置 |

⇒ **4 个字段中只有 1 个（`location`）依赖位置基准**，另 3 个现在就可引擎无关化。
⇒ 且断点判据是**纯行号级**（`line` 相等 + fileName 末段比对）：
HIR 侧位置未落地前，`noLocation`（`line: 0`）**永远匹配不上任何断点** ——
这不是缺陷，但使「接缝能跑」与「接缝可用」必须分开验收。

## 3. 三个关键发现

### 3.1 `debugPause` 只依赖「语句 → 位置」，不依赖语句的其他内容

`debugPause` 的 `stmt` 参数**唯一用途**是一个 16 分支 switch 取 `loc`；
`DebugContext` 的其余三个字段来自引擎自身状态（`debugDepth` / `callStackNames` / `currentEnv`）。

⇒ **位置供给可整体下移到引擎侧**，而 `debugHook` 的签名、`DebugContext` 的结构、
`Debugger`/`DAP` 的消费者**都不必改动**。这是本次勘测最有价值的一处。

### 3.2 AST 语句 16 种 ↔ HIR 语句 16 种，命名几乎一一对应

`debugPause` 的 switch 恰好 **16 个 case**，而契约的节点计数是 **44 expr + 16 stmt**。
两侧语句的 case 名几乎同构（`ifStmt` / `whileStmt` / `forInStmt` / `returnStmt` / `exprStmt` …，
AST 侧仅多 `Statement` 后缀）。

⇒ 位置工单落地后，HIR 侧的位置提取是**同构机械映射**，无新设计面。
**这也反过来支持位置工单的「选项 A（节点携带位置）」**：映射关系已经天然存在。

### 3.3 引擎的「调试面」同形，「执行入口」天然不同

| 面 | `Interpreter`（AST 引擎） | `HIRExecutor`（HIR 引擎） | 可统一？ |
|---|---|---|---|
| `outputSink` | `(String) -> Void` | `(String) -> Void` | ✅ **已同形** |
| `debugHook` | 有 | **无** | ✅ 加同名属性即可（形态相同） |
| 执行入口 | `run(module: Module)` / `run(package: Package)` | `run(module: HIRModule)` + `prepare(module:)` | ❌ **参数类型不同** |
| `init` | `(ffiConfig:programBase:)` | `()` | ❌ 不同 |

**根因**：引擎的输入本就不同（AST 引擎吃 `Module`，HIR 引擎吃 `HIRModule`），
而 `lowering` 是「选哪个引擎」的**结果**，不是引擎自身的职责。

⇒ **执行入口不能进同一个协议**；若强行统一，必须引入适配层
（`ASTEngine` / `HIREngine` 包装 lowering + 执行），**那就是引擎抽象层**。

## 4. 待裁：两条接缝路（深度差一个量级）

### S1 浅接缝（消耦调试面）—— 在 P1 定位内

1. 抽出**调试面协议**（只含 `debugHook` + `outputSink`），`Interpreter` 与 `HIRExecutor` 各自符合；
   `HIRExecutor` 补一个 `debugHook` 属性（**未接位置前恒不命中**，行为当前等同无钩子）。
2. `debugPause(_ stmt: Statement)` → `debugPause(at loc: SourceLocation)`；
   16 分支 switch 原地提取为 AST 引擎侧的私有函数（**行为零变更**）。
3. `Debugger` / `DAPServer` / CLI 三处装配改为面向协议。

**收益**：P4 迁移时调试面**零改动**；CLI 两处重复样板（module 版 / package 版）可合并。
**代价**：多一层协议，但只覆盖 2 个成员；`debugPause` 是 private + 2 个调用点，改动面极小。
**验证点**：`DebuggerTests` 12 用例全绿 + 调试行为逐字节不变（AST 路径当前行为不得有任何变化）。
**风险**：低 —— 全在本仓内部，无对外 API 变更。

### S2 深接缝（引擎抽象层）—— **超 P1 定位**

在 S1 之上再加「执行入口适配」：协议含 `run`，两侧各由 `ASTEngine` / `HIREngine` 包装
（HIR 侧包装 `lower → prepare → run`）。`DAPServer` 不再自建 `Interpreter()`，
只持有引擎协议实例。

**收益**：P4 换实现**完全零改动**（DAP/CLI 都不知道引擎是谁）。
**代价**：新增一层适配 + 需要决定「谁负责 lowering」「engine switch 归属哪一层」，
牵动 P1-3 的 `PINI_INTERP_ENGINE` 现状与 P2 的实现进度。
**判断**：这是**真架构改动**，宜并入 P2/P3（届时 HIR 侧的执行面已成形），**不在 P1-5 做**。

## 5. 倾向（供裁决，非结论）

**S1 现在做，S2 登记为 P4 前置工单。** 理由：

- S1 是「预留接缝」的**字面含义** —— 预留的是接缝（调试面的形状），不是实现。
- S2 依赖 P2 的 HIR 执行面成形（今天 44 个节点是具名 fail-loud，尚无完整执行路径），
  现在定协议形状会**基于不完整的信息决策**。
- 位置工单**不阻塞 S1**（`location` 是 4 字段之一，且 S1 不改其来源）。

## 6. 不做范围

- **不在本步解位置工单**（详见 `docs/issue-hir-node-source-position-2026-09-12.md`；
  实测其消费面比预期窄 —— 只是 4 字段中的 1 个）。
- **不做 S2 引擎抽象层**（超 P1 定位）。
- **不改 Debugger / DAP 的对外行为**（`pini debug` / `pini dap` 的输出、协议流一律不变）。
- **不动 REPL 的引擎选择**（REPL 不消费 `debugHook`，其接缝面另议，见下）。

## 7. 实时订正：REPL 不在本接缝内

计划里 P1-5 的标题写作「调试·**REPL** 接口预留」，但实测：

- `Sources/PiniCLI/REPL/ReplSession.swift` **不消费 `debugHook`**（全仓 `debugHook` 命中 5 处，REPL 零命中）。
- REPL 的形态是「每次求值新建 `Interpreter()`」，且已有自己的 `<repl>` 位置占位。

⇒ **REPL 与调试面是两条独立接缝**。REPL 迁移的真实前置是「每次求值新建实例」这一形态
（对齐 P4 的引擎选择），**不在 S1 范围**。此订正记于此，供 P1-6 收口时同步口径。

## 8. 不确定项（下一步须查）

- `HIRExecutor` 补 `debugHook` 后，**有钩子但永不命中**这一状态是否需要显式断言钉住
  （防它在位置落地后静默变成「会命中但位置是 0」）。倾向：加一条断言测试。
- `Interpreter` 的 `run(package:)` 与 `run(module:)` 是否可在协议外保持现状，
  或需在 S2 时统一为单一入口 —— 本步不裁。
- 测试侧 12 处装配是否随协议一并改造（倾向：只改生产侧三处，测试侧保持直连具体类型，
  以免把测试变成协议的二次验证面）。

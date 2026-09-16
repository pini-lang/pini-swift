# 工单：执行入口未抽象（宿主与具体引擎类型绑定，P4 换实现要改宿主）

- 状态：**Open（2026-09-13 立案；P1-5 S1 落地时实测发现，只登记不修）**
- 发现渠道：P1-5 勘测（只读）——「调试面可引擎无关化，**执行入口不可**」这一刀切在 S1 落地时被实证。
- 严重度：中（**不影响执行正确性**；影响 P4 的改动面 —— 换默认引擎时宿主侧要跟着改）
- 归属：**宿主装配层**（`DAPServer` / CLI），不是引擎实现的缺陷 —— 两台引擎的输入本就不同
- 定位：**P4 前置**（P4 要求「Debugger 与 REPL 一并迁到 HIR 引擎」；本单覆盖宿主装配那条接缝）
- 2026-09-13 补（P1-6 收口）：**P1 六步已全部完成，本单仍 Open**（它不在 P1 定位内，随 S2 一并转出）；
  同期口径订正 = **REPL 与调试面是两条独立接缝** ⇒ 本单的「宿主装配」面**不含 REPL**
  （REPL 不消费 `debugHook`，其迁移前置是「每次求值新建实例」的形态对齐）。

## 现象（实测）

两台引擎的调试面已在 P1-5 S1 统一为 `DebugHookHost`（`debugHook` + `outputSink`），
但**执行入口统一不了**：引擎吃的东西本来就不是一回事。

| 引擎 | 入口 | 输入 |
|---|---|---|
| `Interpreter` | `run(module: Module)` / `run(package: Package)` | 已检查的 AST |
| `HIRExecutor` | `prepare(module: HIRModule)` + `run(module: HIRModule)` | 已 lower 的 HIR |

**根因**：`lowering`（选哪个 IR）是**调用方的决定**，不是引擎的职责。要让 `run` 进协议，
就得假装两台引擎吃同一份程序 —— 那是把「谁负责 lower」藏进协议里，而不是解决它。

## 证据（E1 代码结构，P1-5 勘测实测）

| 事实 | 落点 |
|---|---|
| DAP 适配器持有具体 `Interpreter` 并直接调 `run` | `Sources/PiniCore/Debugger/DAPServer.swift`（`private var interpreter: Interpreter?` + `run(package:)` / `run(module:)`） |
| CLI 两处调试入口同样持有具体类型 | `Sources/PiniCLI/main.swift`（`startDebugger(module:…)` / `startDebugger(package:…)` 各一处） |
| 引擎开关在 **CLI** 层，不在引擎层 | `PINI_INTERP_ENGINE`（P1-3 落点，`Sources/PiniCLI/main.swift`） |
| 两台引擎无共同入口协议 | P1-5 S1 后 `DebugHookHost` 只含 `debugHook` + `outputSink`（**执行入口被显式排除**，见其文档注释） |

## 下游后果（本单的实际代价）

1. **P4 的改动面**：翻转默认引擎时，`pini debug` 与 `pini dap` 两条宿主路径都要改。
   若入口已抽象，这一步是「零改动」；现状是「宿主跟着引擎走」。
2. **样板重复**：CLI 的 `startDebugger` 有 module 版 / package 版两份同形样板。

## 目标形态（待裁，非结论）

- 协议含 `run`（或等价入口），两侧各由 `ASTEngine` / `HIREngine` 包装：
  HIR 侧包装 `lower → prepare → run`。
- `DAPServer` 不再自建 `Interpreter()`，只持有引擎协议实例。

## 待裁点（P4 开工前须逐项裁决）

| # | 待裁 | 说明 |
|---|---|---|
| 1 | **谁负责 lowering** —— 宿主还是引擎包装 | 决定 HIR 侧包装是「吃源码」还是「吃 HIR」 |
| 2 | **引擎开关归属哪一层** | 现在是 CLI 层环境变量（P1-3）；抽象后是否上移 |
| 3 | **接口形状何时定** | 今天 HIR 侧 44 个节点是具名 fail-loud、尚无完整执行路径 ⇒ 现在定形状＝**基于不完整信息决策** |
| 4 | **与位置工单的关系** | 若 P4 同期要接调试暂停点，则位置供给（见下）须一并到位 |

## 前置

- **P2 的 HIR 执行面成形**（`docs/issue-interpreter-hir-plan-2026-09-12.md` P2 九格）。
- **位置工单**：仅当同期要接线调试暂停点时才需要
  ⇒ `docs/spec/issue/archive/issue-hir-node-source-position-2026-09-12.md`。P1-5 S1 已把调试面协议备好，
  该单的缺口收窄为「HIR 节点无位置」一项。

## 处置（2026-09-16，LR-4 P4-3 交付，**已闭环并归档**）

四个待裁点已裁。**第 3 点（接口形状）与立项时的「目标形态（待裁）」有偏离。**

| # | 待裁 | 裁决 |
|---|---|---|
| 1 | 谁负责 lowering | **调用方（宿主）** —— 与 §现象 的根因一致：`lowering` 是调用方的决定，不是引擎的职责 |
| 2 | 引擎开关归属 | **仍在 CLI**（`PINI_INTERP_ENGINE`）—— 本单不涉及，未动 |
| 3 | 接口形状 | **`DebugRun`**（`host: any DebugHookHost` + `start: () throws -> Void`）；**不把 `run` 放进 `DebugHookHost`** |
| 4 | 与位置工单的关系 | 同期完成（位置工单已闭环，见其处置节） |

**第 3 点偏离的理由**：立项时写的是「协议含 `run`（或等价入口），两侧各由 `ASTEngine` /
`HIREngine` 包装」。但本单 §现象 已经说清了协议**不该**含 `run` —— 那等于假装两台引擎吃
同一份程序，把「谁负责 lower」藏进协议里。`DebugRun` 保住这个结论，同时达成本单两个目标：
装配端不再持有具体引擎类型（`DAPServer` 与 CLI 各一条路径），CLI 的两份同形样板合并为一份
（`startDebugger(run:sources:primaryName:)`）—— 即 §下游后果 的「样板重复」被消掉。

**闭环**：`DAPServer` 新增 `makeRun` 注入点（默认 `nil` = 自建 AST 引擎，即生产路径本身），
于是「DAP 在 HIR 引擎下也能用」成为**可断言**的事实 —— `DebuggerTests` 的 DAP 端到端用例
按引擎参数化，两台引擎各跑一遍。

## 不做范围（立项时）

- **不在 P1 内做**（P1-5 S1 已按此裁决只做浅接缝）。
- 不做并发 / CPS 相关的引擎抽象（并发不做，见执行计划）。

## 关联

- 接缝勘测与 S1 落地实录：`docs/spec/issue/archive/issue-hir-p1-5-debug-seam-recon-2026-09-13.md`
  （§4 S2 / §5 / §9；2026-09-13 随 P1-6 收口归档）
- 执行计划 P1-5 行与开工顺序：`docs/issue-interpreter-hir-plan-2026-09-12.md`

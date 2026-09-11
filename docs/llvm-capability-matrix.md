# LLVM 后端能力清单（M2 批产出）

> 状态：**数据快照（2026-09-08，M5 G1 后刷新）**，由 `tools/capability-sweep.sh`
> 实测生成，是 LLVM 重写计划（`docs/issue-llvm-rewrite-plan-2026-09-07.md`）
> M3 决策门的输入。M5 每落一格重跑一次 sweep，刷新本表。
> **M6 翻转（2026-09-12）后 `hir-emit` 通道转正为唯一 emit**：迁移期选择点
> （`PINI_HIR_PIPELINE`）已随旧生成器一并退役，故本表 `emit` 与 `hir-emit` 两列为同值。

## 方法

- 语料：`examples/` 全部 `.pini` 文件（剔除 selfhost 嵌套仓），共 **59 个**。
- 通道：对每文件依次实测 `pini emit`（IR 生成）→ `pini run-llvm`（JIT 执行，仅对 emit 通过者）
  → `pini emit`（第二次实测，列名沿用历史表的 `hir-emit`）→ `pini run`（解释器基线）。
- 工具：`tools/capability-sweep.sh`（可复跑），逐行结果
  `tools/capability-sweep.tsv`（文件 / emit / llvm / hir-emit / interp / 失败原因首行）。
- 二进制：`/tmp/pini-build` scratch 的 debug `pini`（与全量测试同源）。

## 勘误（对计划工单 M2 节）

- 语料规模实为 **59** 个，工单所记「1010 个」是早期勘察噪声，以本表为准。
- fail-loud 抛点实为 **108 处** `throw IRGenError`
  （51 `unsupportedExpression` + 46 `unsupportedFeature` + 9 `unsupportedStatement`
  + 2 `unsupportedType`），工单所记「129」为未过滤 grep 计数（含注释与文档引用）。

## 总量

| 通道 | 通过 / 总数 | 率 |
|------|------------|-----|
| `emit`（IR 生成） | 40 / 59 | 67.8% |
| `run-llvm`（JIT，仅 emit 通过者） | **40 / 40** | 100% |
| `run`（解释器基线） | 51 / 59 | 86.4% |

两点结论：emit 通过者的 run-llvm 全通——**发射层通过即端到端可用**，
瓶颈完全集中在发射层能力门；解释器 8 个 FAIL 全部是**多文件模块成员文件**
（`utils.pini` / `helpers.pini` / `api.pini` 等无 main 的库文件），单文件执行
本就不适用，不是解释器能力缺口。

## emit 失败聚类（19 个）与分桶

| 聚类 | 文件数 | 桶 | 说明 |
|------|--------|-----|------|
| 并发运行时内建未注册（`sleep` / `Error`） | 8 | **核心** | 并发语料全军覆没；内建表未接入 IR 侧 |
| 跨文件符号未注册（`向量` / `公开API`） | 2 | **核心** | 多文件模块 emit 仅见单文件 |
| `[名称\|foreign]` 块 | 2 | **核心** | FFI 头牌特性 |
| 数组方法 `get` / `slice` | 2 | **核心** | |
| 泛型 `generic(T)` | 1 | **核心** | `enum-dot-case`；LR-3 单态化落 HIR |
| 对象方法调用 | 1 | **核心** | `object.pini` 未注册方法 |
| try-else 发射 | 1 | **核心** | ADR-032 遗留 fail-loud（`^T` 返回位） |
| `cow.pini` var 绑定数组元素类型未记录 | 1 | 可延后 | 影子表记录范围缺口 |
| `multidim.pini` 标识符 `row` | 1 | 可延后 | 需个案分析（嵌套下标路径） |

## 108 处抛点的结构分类

抛点分两种性质，**只有前者是能力缺口**：

1. **特征门**（能力缺口，特征落地即消除）：try-else 发射、foreign 块、
   并发内建、数组方法、泛型类型参数、对象方法调用、跨文件符号、
   match 字面量模式（HIGH-2）、定长数组下标（集合后端重做接入）、
   top-level statement/var、Unicode 语义字符串方法（需运行时扩展）等。
2. **防御性错误路径**（非法程序守卫，**永久 fail-loud**，不进能力清单）：
   类型失配守卫（数组下标需 I32 等）、元组索引越界、Optional.some 实参数、
   未定义标识符/变量、空集合字面量类型不可解析、嵌套下标中间层非容器等——
   它们在合法程序上永不触发，重写后仍保留（HIR 层等价守卫）。

## 分格顺序草案（M4/M5 执行序）

按「语料缺口数 × 实现风险」排序，每格一次提交 + 一次 sweep 刷新：

- **G1 try-else 发射**（1 文件；ADR-032 遗留，语义已被 M2 前置批钉死）
- **G2 并发内建注册**（8 文件；一格消掉最大缺口，sleep/Error → 运行时调用）
- **G3 数组方法**（get/slice，2 文件）
- **G4 对象方法调用**（1 文件）
- **G5 泛型单态化**（1 文件；与 LR-3 HIR 类型化树强耦合，放 HIR 落地批同做）
- **G6 foreign 块**（2 文件；需 clang 链接通道验证）
- **G7 跨文件模块 emit**（2 文件；符号表跨文件注册，风险最高放后）
- **G8 零散可延后**（cow / multidim 个案）

## M3 决策门数据摘要

- 缺口集中且成簇（8/19 是同一内建注册缺失），非零散腐烂；
- emit 通过者端到端 100%——执行链路（IR → lli/clang → PiniRuntime）稳固；
- 108 抛点中特征门占比有限，重写后防御性守卫照旧；
- 旧 CodeGen 抛点自 ADR-031 立案以来持续增长（100 → 108+ 实测），
  「演进」路线的成本曲线未被打破。

以上数据交 M3 决策门裁决（增量 vs 重写），本批不做路线判断。

## HIR 迁移期已知限制（2026-09-10 起记）

本节与上文同仓、**不同语料口径**：上文分母是 `examples/` 的 59 个文件（M2 期实测），
本节记的是「旧后端可用、HIR 不可用」的**能力差**，分母为四个 LLVM 驱动测试套的夹具
（实测 222 个 `.pini`：`IRGeneratorTests` 83 / `IRExecutionTests` 75 /
`IRPrintGoldenTests` 11 / `RuntimeBackendTests` 53）。

| 限制 | 夹具 | 处置 | 记载 |
|---|---|---|---|
| 嵌套容器 COW（写链经过字典） | `RuntimeBackendTests` 4 例 | **已实现**（D1，2026-09-11），非限制 | `docs/spec/issue/archive/issue-hir-nested-dict-write-2026-09-11.md` |
| 聚合值（struct / object）打印 | `IRPrintGoldenTests` 3 例 + 多参数形态 1 例 | **已实现**（D2，2026-09-11），非限制 | `docs/spec/issue/archive/issue-hir-aggregate-value-print-2026-09-10.md` |
| 并发族（8 文件语料） | `examples/` 并发语料 | **除名立案**（LR-11）；M6 后独立里程碑 | `docs/issue-llvm-concurrency-runtime-2026-09-08.md` |
| 多槽返回 `-> (I32, I32,)` | `IRExecutionTests` 2 例 | 已实现（M6a a2 / D7=A），非限制 | 计划工单 M6a a2 节 |

**阻塞清零（D 批终值，2026-09-11）**：探针全量重跑（7 根 389 夹具），
`examples/` 78 例与 LLVM 驱动套 311 例**双双零阻塞**，本表只剩并发族一条已立案限制。
唯一非终止项 `IRGeneratorTests/testContinueInWhile.pini` 判 `TIMEOUT_ALL`——
该程序按自身语义即设计内死循环（递增语句在 `continue` 之后），非缺口。

上表的原始记载（2026-09-10 探针实测，a4 收尾状态）为「除上述三项外，四个套件内
**无其他**『旧后端通过、HIR 拒绝』的夹具」。全套件夹具扫描（`Tests/` 全量 980 个 `.pini`）
另有 68 个同类差，分布在未被 LLVM 驱动的套件中，按既定口径不入门槛。

### 本节口径的两处订正（相对计划工单早期记录）

- 计划工单曾把四套夹具数记为 **128**；实测为 **222**（与该工单同段记的「用例数」同值，
  系当时混算）。
- 门槛内阻塞数曾按两套目录记为 **7**；按四套口径，a2 时为 **11**、a3 后 **6**、
  a4 后 **3**（余下 3 项即本表首行）。


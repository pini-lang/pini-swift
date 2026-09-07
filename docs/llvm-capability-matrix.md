# LLVM 后端能力清单（M2 批产出）

> 状态：**数据快照（2026-09-08，M5 G1 后刷新）**，由 `tools/capability-sweep.sh`
> 实测生成，是 LLVM 重写计划（`docs/issue-llvm-rewrite-plan-2026-09-07.md`）
> M3 决策门的输入。M5 每落一格重跑一次 sweep，刷新本表。
> **M5 起新增 `hir-emit` 通道**（`PINI_HIR_PIPELINE=1`，迁移期选择点）：
> 记录新管线（HIRLowerer→IREmitter）的 emit 通过率；M6 翻转后该通道转正为唯一 emit。

## 方法

- 语料：`examples/` 全部 `.pini` 文件（剔除 selfhost 嵌套仓），共 **59 个**。
- 通道：对每文件依次实测 `pini emit`（旧管线 IR 生成）→ `pini run-llvm`（JIT 执行，仅对 emit 通过者）
  → `PINI_HIR_PIPELINE=1 pini emit`（新管线）→ `pini run`（解释器基线）。
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

# ADR-028: 集合下标三通道安全模型（G48 破坏性修订）

## Status

Accepted（2026-09-01 用户需求提出；2026-09-01 D-1~D-7 裁决；2026-09-01/02 落地）

> **补登记说明**：本 ADR 于 2026-09-02 **追溯补写**。变更本身已按用户裁决落地并过门禁，但当时**跳过了 spec §1.3 第 2 步（破坏性升级评审）与第 3 步（新增 ADR 记录决策理由）**。本次补写即清偿该治理债，理由见路线图 §8.3。

**修订对象**：spec §2.4.1 **G48**（集合下标安全模型，v0.49.0 定义，Provisional）。**破坏性**：读通道语义翻转 + 类型层 `Optional<T>` → `T`。

---

## Context

**用户新需求（2026-09-01）**——三通道分工：

```pini
let 元素 = 数组[5]                     ; 安全，越界 panic
let 元素 = 数组.get(5)                 ; 安全，越界返回 .none
let 元素 = unsafe 数组.getUnchecked(5) ; 不安全，越界 UB
```

**取证推翻了「这是新增能力」的初判，实为消除既有的双后端不一致**：

| 后端 | 改前行为 | 证据（符号定位） |
|---|---|---|
| 解释器 | 越界读返回 `Optional.none` | `SubscriptReadStrategy.read`（`SubscriptStrategies.swift`，`enum SubscriptReadStrategy` 内 `static func read(container:index:location:)`） |
| LLVM | 越界 `bk_panic` 终止，返回**元素盒本身** | `PiniRuntime.bk_array_get`（`@_cdecl`，OOB 走 `bk_panic`） |

该不一致的登记出处为 `docs/issue-host-optional-slice-2026-08-28`（「Optional/下标运行时 incoherence，P2-E incomplete」）。即：**LLVM 端一直是"下标断言 + panic"，是解释器的 nil 返回造成分叉**，且 G48 标注的 `Optional<T>` 类型与 LLVM 实际产出的元素类型**恰好不符**。

**连带事实**：
- `.get` / `.getUnchecked` 改前**全仓零命中**（纯新增成员方法）。
- `unsafe <expr>` 消耗点**已存在且在用**（ADR-015 / ADR-020 D6）→ 第三通道**不需新增语法面**。
- 强制解包 `!` 作用于非 Optional **已在类型层报错**（`TypeChecker` unary forceUnwrap 分支）→ D-4 无需新增判定；218 处 `]!` 迁移是被编译器强制出来的。
- 字典此前**无成员方法派发路径**（下标为语法级）→ 为使 `d.get(k)` 可解析，需新增 `.dictionary` 成员分支。

---

## Decision

**G48 改为三通道模型**，Array / Dictionary / String 一致，负索引尾部计数保留：

| 通道 | 形态 | 越界 / 缺键 | 返回类型 | 责任 |
|---|---|---|---|---|
| 安全断言 | `a[i]` | **panic**（`RuntimeError.indexOutOfRange`，**E5-005**，该码早已在册且未占用） | `T` | 语言保证 |
| 安全可选 | `a.get(i)` | `Optional.none` | `Optional<T>` | 调用者显式解包 |
| 不安全 | `unsafe a.getUnchecked(i)` | **UB** | `T` | 调用者证明界内 |

**D-1~D-7 裁决要点**：

- **D-2 panic 载体**：复用既有 `RuntimeError` 通道 + E5-005，**不引入语言级 panic 构造**（新增 panic 是全新控制流语义面，成本远高）。
- **D-3 归属**：`.get` / `.getUnchecked` 登记为**内建成员方法**（`BuiltinRegistry.memberMethods`，`inTrait = false`——不进 collection 特征面，避免用户类型被要求实现）；解释器单一分派点处理三类型。
- **D-5 字典同步**：**字典缺失键与下标越界同义**（统一「下标 = 断言存在」模型）；G48 原文亦将二者对齐（「与字典缺失键一致」）。
- **D-6 LLVM 第三通道**：LLVM 对 `unsafe` / `&` 早已显式 unsupported（ADR-015 FFI Phase 2a，用户决策 D1：解释器优先）→ 第三通道为**解释器专用**，LLVM 端沿用 unsupported。
- **D-4 `!` 语义**：下标返回 `T` 后，`a[i]!` 自动触发既有的「非 Optional 不可强制解包」报错（有类型标注时静态 E4-001，否则运行时 E5-006）；`unsafe` 未消耗任何不安全操作时**无害通过**（许可是「允许」而非「要求」）。
- **D-7 迁移策略**：一次性全改（批 1 先例；拆分会留下「下标 panic 但无 `.get`」的残废中间态）。

**记录的限制**：解释器无法表达真正的 UB——`getUnchecked` 越界在解释器以「未定义行为陷阱」（`uncheckedOrNone` 抛 E5-006）报错近似（可诊断、可测试）；调用方前置条件义务不变，LLVM 端若实现则为真 UB。

---

## Consequences

**正**
- 双后端下标语义**收敛**（解释器向 LLVM 已实现行为对齐），闭合 `issue-host-optional-slice` 登记的不一致。
- 类型层 `Optional<T>` → `T` 与 LLVM 实际产出对齐，此前类型标注与运行时**相反**的状态消除。
- 下标从「每次都要解包」变为「断言即所得」，常用写法更短；容错与热路径各有显式通道。

**负 / 代价**
- **破坏性**：既有代码 `a[i]` 由「越界得 nil」变为「越界终止」；类型由 `Optional<T>` 变 `T`。
- **迁移面**：218 处 `]!`（13 文件）+ `StdlibPini.swift` 内嵌 Pini 源码 7 处 + 自举源码 98 处；4 个 `…ReturnsNull` 夹具改为 `…Panics`。
- **残债**：LLVM 端 `.get` / `.getUnchecked` 未实现（IR 生成报 unsupported），锁步断言在无 `lli` 环境保持跳过并如实记录。

**验证（实测）**
- 宿主全量 1105/0；gate 五关 GREEN（L0 MATCH 508、parse MATCH 222+94、`pini check` 15 文件、自举 70/0、audit GREEN）。
- 三通道在三类型上逐个实跑通过；越界 panic 报 `Error: Runtime Error [E5-005]`。

**提交**：宿主 `cbdd479`（spec）、`64c2531`（通道 1）、`031adca`（通道 2/3）、`8ed57c3`（迁移）；自举 `8a1ae62`；基线第十三次重标定。

---

## 影响评估（§1.3 第 2 步，破坏性 —— 升级评审）

| 受影响构造 | 稳定性 | 变更性质 |
|---|---|---|
| G48 集合下标安全模型 | Provisional | 语义翻转 + 类型变更（破坏性） |
| 下标读类型推断（`TypeInference` subscript 分支） | Provisional | `Optional<T>` → 元素类型 `T`（破坏性） |
| 强制解包 `!` | Provisional | 行为不变，但下标位触发既有报错（迁移强制） |
| 新增 `.get` / `.getUnchecked` | 新增 | 纯新增 |
| 字典成员派发 | 新增 | 新增 `.dictionary` 成员分支 |

**评审结论**：破坏性**仅限 Provisional 面**（G48 从未 Stable），未触及 §2 Pinned Core；裁决以 D-1~D-7 逐条记录并经用户批准，等价于升级评审。**LLVM 半程在本环境无 `lli`，相关锁步断言保持跳过——如实记录，不伪造绿（ADR-024 D9）**。

---

## 证据（§1.4，符号定位；2026-09-02 重新过筛，FRESH）

| 断言 | code_ref（符号定位，行号为软证据） |
|---|---|
| 解释器下标读分派 | `SubscriptReadStrategy.read(container:index:location:)`（`SubscriptStrategies.swift:91`；`enum SubscriptReadStrategy` `:16`） |
| 越界错误载体 | `RuntimeError.indexOutOfRange`（`RuntimeError.swift:31`）；诊断码 `[E5-005] index out of range`（`Diagnostics.en.toml:126`） |
| LLVM 运行时越界 panic | `bk_array_get`（`PiniRuntime.swift`，OOB → `bk_panic`；`bk_panic` `:152`） |
| 下标类型推断 | `TypeInference.infer` 的 `.subscript` 分支（`TypeInference.swift:230`） |
| 新通道登记 | `BuiltinRegistry.memberMethods` 中 `getUnchecked`（String `:200` / Array `:215` / Dictionary `:221`） |
| 解释器分派与 UB 近似 | `Interpreter.callFunctionValue` 的 `get`/`getUnchecked` 分支；`uncheckedOrNone`（`Interpreter.swift:2650`）；字典键按任意值匹配（`:2980`） |
| 字典成员派发新增 | `Interpreter.evaluateMember` 的 `.dictionary` 分支（`:2207`） |
| 废弃提示文案 | `Parser.swift` 四处 `ParserError.invalidExpression`（`:2875` 实参、`:2938` 元组、`:2990` 字典首条目、`:3004` 字典后续条目、`:3071` 实参） |

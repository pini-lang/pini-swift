# HIR 没有泛型枚举的特化族

> 状态：**Closed / ARCHIVED（2026-09-16）** —— 主题已由 `G-2d` 的 `S1` 交付解决，本件移入
> `docs/spec/issue/archive/`。**不得作为当前行为依据**（处置记录见文末「归档处置」）。
> 立案：2026-09-16（**只登记不修**）｜发现于：`G-2d` 勘测，它是该子批**全部**对象的起点。
> 上游：`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-2d` 行。

## 1. 现象（实测，2026-09-16，`main` = `2d49c1f`）

用户声明的泛型枚举 + 显式类型实参构造：

```pini
[结果<T, E>]
ok(T)
err(E)

main|func() -> ():
    var a = ok<I32, String>(42)
    match a:
        case ok(v):
            print(v)
            return
        case err(e):
            print(e)
            return
    return
```

| 命令 | 结果 |
|---|---|
| `PINI_INTERP_ENGINE=ast swift test --filter GenericEnumTests` | 通过（5/5）|
| 默认（HIR） | **4 条红**，全为 `HIR lowering error at 1:1: associated value '?' of case 'ok' lacks a resolvable type` |

同类：`[盒子<T>] 满(T) / 空()` 的 `满<I32>(5)`、`空<String>()`（`testGenericEnumDistinctSpecializations`）。

**受影响的用例**（实测计数）：`GenericEnumTests` 4 条 · `GenericRuntimeTests` 1 条。

## 2. 符号级根因（实测，非推断）

1. **特化状态只有两个族**：`HIRLowerer.G10SpecializationState` 声明
   `structSpecializations` 与 `funcSpecializations`（`Sources/PiniCore/HIR/HIRLowerer.swift` L50–51），
   **没有 `enumSpecializations`**。
2. **枚举注册不做替换**：`lower(module:)` 的枚举预扫里，case 的载荷类型直接走
   `resolveAnnotationType(param.type, userTypes:)`。`T` / `E` 不在 `userTypes` 里
   ⇒ 解析失败即抛所述错误。
3. ⇒ 缺的是**一整个特化族**：枚举模板 → 按类型实参产出特化枚举（替换 case 载荷类型）→
   构造点按 `名字<实参>` 解析到特化体 → `match` 按特化体取载荷类型。
   与 `registerStructSpecialization`（同文件 L898 起）同形，但**多一条 `match` 分派链**。

## 3. 为什么不在 `G-2` 内做

`G-2` 的每个子批做的都是「**放宽一道守卫** / **把实现接上既有节点**」。
本项不是：它要**新增一个特化族**并接上构造点与 `match` 两处解析。
把它塞进 `G-2` 会让该批的性质从「补降载面」变成「实现泛型枚举」，规模与风险都不是同一量级。

⇒ 单独立项。它同时是 `P4-γ` 之外的一条独立推进线（与 `G-3` 的并发迁移同属「大」）。

## 4. 2026-09-16 勘测订正（两处成本偏重）＋ 开工前规划指针

用户于 2026-09-16 裁决形态取 **C**（**限定为准 · 裸名为糖**），并点名出规划。规划件：

> **`docs/issue-hir-generic-enum-specialization-plan-2026-09-16.md`**
> （分 `S0` 语言面登记 → `S1` 降载层三站 → `S2` 收口；**每阶段须单独点名**）

本件两处表述经读码勘测**偏重**，收口时按规划件 §6 订正：

| 本件原文 | 订正 |
|---|---|
| §2 第 3 条「缺的是**一整个特化族**……与 `registerStructSpecialization` 同形，但**多一条 `match` 分派链**」 | **偏重**：类型层**已有**同功能件（`TypeEnvironment.lookupSpecializedEnumCase` 连载荷类型替换都做完，且构造点与 match 绑定处**已在调用**）；**`match` 分派链不成立** —— `lowerMatch` 的 `.enumeration(name:)` 分支按**名字**通用，执行器 `matchStmt` 刻意不读 `scrutineeType`。⇒ 缺的只是**降载层的三个中间站** |
| §1「受影响的用例：`GenericEnumTests` 4 条 · `GenericRuntimeTests` 1 条」 | **补一句性质区分**：其中 **2 条属「错误通道」议题**（`testGenericEnumArgumentCountMismatch` · `testUndefinedGenericTypeStillThrows`，均期望**运行期** `RuntimeError`），**不属本批** ⇒ 本批承诺 **3 条**转绿，不承诺 5 条 |

⚠️ 另有一条**语言面缺口**（规划件 §0 / `S0` 的对象）：语言参考定义了泛型枚举的**声明**
（`[可选<T>] 有(T,) 无`）与非泛型枚举的**构造**，但**未定义泛型枚举用例的显式类型实参挂在哪**。
⇒ 须先走规范变更治理流程登记，**实现不得先于登记**。

---

## 归档处置（2026-09-16，`G-2d` 的 `S1` 交付）

**处置 = 主题已解决，归档。** 本件立案的主题是「**HIR 没有泛型枚举的特化族**」，
由 `S1`（分支 `agent/pini-dev/p4-gamma-g2d-s1`，提交 `3e2716b`）在降载层补齐三站而**解决**：
模板收集多收泛型枚举 ＋ 用例名→owner 索引 · `registerEnumSpecialization` 按实参替换 case 载荷类型 ·
构造站点一个助手服务两形态（限定由书写给出、裸名落 `ADR-026` D1 三档）。

**判据（现跑，逐条）**：

| 判据 | 读数 |
|---|---|
| 指定用例转绿 | `testGenericEnumConstructionAndMatch` · `testGenericEnumErrBranch` · `testGenericEnumDistinctSpecializations` **3 条全绿**（逐条点名） |
| 无新增红 | 基线 **75** → 候选 **72**；转绿 3 / **新增 0** / 仍红 72 逐条相同；两方向逐类 **116/116 相同** |
| 探针 | 319 夹具 vs `G-2` 探针**归一化后逐条相同（变化 0）**；vs `P4-0` 冻结件唯一变化归属 `G-2a` |
| 契约计数 | `hir-contract-check` 三锚点各 **60/60** 覆盖 · clean |
| LLVM 侧 | `emit` rc=0 且**无未定义符号**；`run-llvm` 输出 `42` 与 HIR 一致 ⇒ **不需要额外工作** |

**明确转移（不随本件归档结案）**：本件 §1 列的 5 条受影响因素里，**2 条不属「特化族缺失」**
而属**错误通道**议题 —— `testGenericEnumArgumentCountMismatch` · `testUndefinedGenericTypeStillThrows`
均期望**运行期** `RuntimeError`，而静态降载层在构造期即拒。这两条**仍红**，
归 `docs/issue-hir-static-rejection-vs-runtime-error-2026-09-16.md`（在册），
本件不再承载。

⚠️ **一处如实登记的缺口**：`ADR-037` 定为「**为准**」的**限定形态**目前只在**降载层与 LLVM 通道**可用，
**AST 走查侧不支持**（报 E5-001）。走查将于 `P4-γ` 删除 ⇒ 不投入；差分夹具全用裸名形态 ⇒ **测试面不可见**。
已在 `ADR-037` 与规范 `G59` 同步。

**归档时的路径变更**：本件原名由宿主级 `docs/` 下同名文件移入 `docs/spec/issue/archive/`；
全部入向引用（规划件 · 批次记录 · `ADR-037` · 证据表）已同批改指。

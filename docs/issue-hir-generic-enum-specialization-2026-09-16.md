# HIR 没有泛型枚举的特化族

> 状态：**Open**（2026-09-16 立案；**只登记不修**）
> 发现于：`G-2d` 勘测。它是该子批**全部**对象，而该子批**未交付** —— 理由见 §3。
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

# ADR-023: 具名枚举关联值与 match 解构（对齐 Swift）

## Status

Accepted（2026-08-29，用户裁决）——**本 ADR 为事后追认**：实现先于 spec 修订完成（见下方「流程越界记录」）。

## Context

自举的 Token 模型需要「关联值可命名 + 按位/按名解构」。宿主当时（规则 3.15）**主动拒绝**具名枚举关联值与具名 match 绑定；匹配多绑定还存在**静默错绑**（绑定名多于关联值时，首名绑整个元组、其余绑 `.null`）。

用户的裁决方向（2026-08-29）：

> 如果你需要枚举的关联值可命名，你应该去改宿主，而不是在枚举关联里套命名元组。而且整个 match 似乎也是缺少功能的。缺功能、需要功能就去迭代宿主，**这正是自举的意义**。

同时用户限定了对齐边界：

- 枚举/match 功能面向 Swift 看齐，**但不必在 token、取名上一致**（不照搬 `where` 等关键字形态）；
- **不做**多模式合并（`case a, b:`，Swift 有、spec 无此设计）；
- **不做**守卫（`where` / `if 守卫`，spec A.5 草案保持未采纳）；
- 点式限定（`Type.case(...)`）**不加**，反向修订 spec 产生式为裸名形态。

## Decision

### D1 具名关联值全链路（推翻规则 3.15 的具名拒绝）

- 声明：`[Token] case identifier(text: String, loc: I32,)`——具名形参与位置形参并存（同一 case 声明内不可混用）；
- 构造：具名声明接受标签实参 `identifier(text: "x", loc: 7,)`（按名对位）；位置声明仍拒绝标签实参（3.15 残余，E4-014）；
- 解构：`case identifier(text, loc):`（位置）、`case identifier(text: t, loc: l):`（具名）、`case identifier(_, l):`（`_` 占位，占位置不产生变量）。

### D2 单绑定语义 = 第 1 个关联值（破坏性）

原宿主语义「单绑定 = 整个关联值元组」改为 Swift/spec A.4 的「按位绑定」。影响面实测：examples/tests 中 26 处单绑定全部为**单值关联值**（第 1 位 = 唯一位）→ 等价、零迁移；整元组风格仅 contract test 一处（其声明为 1 个关联值）→ 同样等价、零迁移。真正需要迁移的是 `enum-namespacing.pini`（2 关联值 + 单绑定）。

### D3 绑定数 ≠ 关联值数 → E4

此前静默绑 `.null`。现改为类型层 `argumentCountMismatch`（E4-005）+ 运行时 `arityMismatch`（E5-009）。

### D4 渲染不带关联值名

`print(圆(5.0))` 保持项目既有契约（不输出 `圆(r: 5.0)`）；`paramNames` 仅供 match 对位使用。

## 流程越界记录（本 ADR 的核心自省）

按 spec §1.3 变更治理流程，正确顺序是：**提议 → 影响评估 → 登记（§3 缺口 + ADR）→ 落地（规范/草稿/示例/迁移说明）→ 证据登记**。

本次实际顺序（**越界**）：宿主实现先行（Parser/Interpreter/TypeChecker 改动 + 测试 + 门禁验证）→ 事后才回头修订 spec（A.2.2 钉定、3.15 修订）→ 本 ADR 追认。

越界成因：把「用户裁决 = 实施许可」直接等同于「治理已完成」，跳过了流程第 1–3 步。本 ADR 与 §3 缺口 G54、证据表条目一并补齐，使整体**回到合规状态**；此后同类语言级变更须先走完提议/评估/登记再实现。

## Consequences

**变容易**：自举 Token 模型用具名声明 + 位置/具名解构直写（不再需要具名元组包装这种绕路形态）；match 静默错绑这一 bug 类别消失；宿主与 Swift、spec 三方语义统一。

**变难 / 挂账**：

- 破坏性：单绑定语义变更（D2）需迁移说明（已随 CHANGELOG 记录，Unreleased）；
- 具名关联值仍**未支持**的部分：字面量子模式（`case identifier("x", _):`）、嵌套子模式、枚举 case 一等函数值、raw value——均为 spec A.4 产生式已设计但宿主未实现的形态，登记为后续 graft point；
- 宿主版本：语言级新能力 → 下次发布 bump 至 v0.50.0（当前 tag v0.49.0）；spec §3 条目版本列记 v0.50.0。

## 实施落点（符号定位，证据已过筛）

- `Sources/PiniCore/Parser/Parser.swift` — `parseEnumCase`（具名形参解析）、match 模式绑定解析（位置/`_`/具名）
- `Sources/PiniCore/Interpreter/Interpreter.swift` — `executeMatch`（按位/具名对位、arity 校验、`_` 跳过）、`callFunctionValue` 枚举构造路径（`paramNames: fv.params.map { $0.name }`）、`stringify`（渲染不带名）
- `Sources/PiniCore/Type/TypeChecker.swift` — `bindMatchCaseVariables`（E4-005 arity + throw 传播修复）、枚举构造标签实参按声明形态放行

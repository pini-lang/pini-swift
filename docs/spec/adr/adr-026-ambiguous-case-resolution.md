# ADR-026: 歧义 case 名消歧与类型传播（自举探针批次 1）

## Status

Partially Accepted（2026-08-30，自举探针 G-P6/G-P8/G-P2/G-P3 修复批次；D5 双段落地：本 ADR 与 spec 修订同期于实现）

范围修订（2026-08-30，批次 1 收口时复审）：D1/D2/D3 已落地并验证（宿主全量 1037 测试 0 失败）；**D4 移出本批次**（重定性为未来语言特性，见 D4 修订）；**D5 缩窄**为推断补齐（原「运行时装箱大改」无证据支撑——G-P9 的 SIGSEGV 已重新归因为无界递归并以深度护栏修复，非装箱缺陷）。

## Context

自举 parser 阶段（S0–S4）以可执行探针实测出四个同根缺口（`examples/selfhost/docs/host-gaps.md` G-P6/G-P8/G-P2/G-P3，宿主侧落点 `docs/spec/issue/archive/issue-bootstrap-gap-remediation-2026-08-30.md`）：

1. **歧义 case 名无路可走（G-P6）**：`TypeEnvironment.parentEnum(of:)` 以单值字典 `enumCaseToParent[caseName]` 反查父枚举，跨枚举同名 case 时后注册者覆盖前者；解释器预扫描将歧义名排除出全局函数表（迫使限定写法），但 ADR-023 已裁定**不加点式限定形式**——歧义名因此构造无门。实测：E4-005（按错误父枚举校验 arity）、E4-001（expected expr, got int_lit）。
2. **self 调用类型丢失（G-P8）**：方法体内 `let x = self.f()` 绑定被推成 Any，后续与字面量比较即 E4-001；外部接收者 `a.f()` 保持类型（探针实证）。
3. **数组元素类型擦除（G-P2）**：`append` 返回 `Array<Any>`。前次修复（3eede4d）以**全局占位名 `T`** 承载元素身份、`TypeSubstitutor` 查表期替换——名字无作用域、可撞任何 `T`（9e54e27 回退自认「approach was wrong, not just the details」）。
4. **case 值无类型身份（G-P3）**：case 值不能作关联值、return 位置拒收（"expected keyword, got kw_var"；自举 lexer 以 keyword-as-text 绕行）。

## Decision

### D1 裸名 case 构造的消歧规则（G-P6①）——静态收敛版（2026-08-30 修订）

**修订（2026-08-30 设计讨论裁决）**：原则收敛为「**case 由复合类型确定成员身份，运行期不做动态猜测**」。原第 2 档（运行期按实参动态类型计分消歧）**移除**——它让成员身份由实参嗅探决定，违反本原则。

裸名 case 构造 `caseName(args)` 的父枚举解析顺序：

1. **期望类型唯一命中**（形参声明、显式标注、返回类型、case 关联参数声明）→ 该枚举的成员；静态决议经决议表交接运行期（`BareCaseResolutionRegistry`，键 = 调用点位置）；
2. **模块内恰好一个枚举声明该 case** → 该枚举；
3. **歧义且无期望类型** → **编译错误**，要求限定形式 `枚举名.caseName(...)`（限定构造通道既有，`EnumName.caseName(...)` 恒可用）。

spec 钉定点：enum-case 产生式小节（已钉）；match 小节见 D2。配套：`.caseName(...)` 点号构造语法立项为提案（见 `docs/spec/issue/proposal-dot-case-construction-2026-08-30.md`），择破坏窗口裁决。

### D2 match 模式按 scrutinee 类型解析（G-P6②）

`match v` 的 `case caseName(...)` 模式按 `v` 的静态枚举类型解析父枚举；scrutinee 类型不可知时按 D1 动态规则。spec §2.4.3（match）钉定。

### D3 self 调用类型传播（G-P8）

对象方法体内 `self.f()` 的返回类型按 `f` 的声明签名传播，与外部接收者一致。类型检查器单点修复（self 调用的推断路径补齐）。

### D4 数组元素类型身份（G-P2）——移出本批次，重定性为语言特性提案

**修订（2026-08-30）**：复查证据后本决策的前提不成立——`append` 返回 `Array<Any>` 是 **ADR-020 登记的签名契约**（`BuiltinRegistry.swift` `returns: [any]`），不是缺陷；且语言**没有数组元素标注语法**，`var xs = []` 起步的累积器**本无元素类型可供传播**。9e54e27 回退的教训恰是「不要从用法中发明元素身份」——原 D4（作用域化类型变量）方向上重蹈覆辙。

正确路径：**向 spec §1.3 提案「数组元素标注 `[T]`」**（独立语言特性，显式声明元素身份，另行排期）。在此之前，`[Any]` 累积 + 消费点 match 解构是当前契约下的**惯用法**，自举侧按此登记为 `MITIGATED-BY-DESIGN`，不作为待关闭偏差。

### D5 case 值类型身份——缩窄为推断补齐（G-P3）

**修订（2026-08-30）**：D1/D2 落地后，限定构造 `Enum.case(...)` 已能推断父枚举类型（TypeInference）；剩余缺口仅为**裸名且父枚举唯一**的 case 构造不推断类型（`return int_lit(...)` 位置拒收）。本批次只做该窄修复：裸名唯一 case 构造按 `parentEnums(of:)` 候选集推断父枚举类型（约数行，复用现有机制）。原「运行时装箱大改」无证据支撑，移出。

## Consequences

**变容易**：自举侧拆除全部绕行（case 改名还原、内联比较还原、`[Any]` 流还原、keyword-as-text 还原）；用户代码中同名 case 的多枚举模块成为合法形态。

**变难 / 挂账**：

- 歧义名的动态消歧依赖实参类型可判——纯 arity 撞车的歧义对（同参量数同参型）仍需限定写法或改名，spec 明示此边界；
- 解释器歧义预扫描与静态检查器必须共享同一候选集，两侧规则漂移由差分门禁拦截；
- 数组元素类型身份（原 D4）待「数组标注 `[T]`」特性提案走 spec §1.3 排期，不在本 ADR 范围内。

## 实施落点（符号定位）

- `Sources/PiniCore/Type/TypeEnvironment.swift` — `enumCaseToParent` 单值字典 → 多值候选集（`parentEnums(of:)`）
- `Sources/PiniCore/Type/TypeChecker.swift` — `checkEnumCaseConstruction` / `refineEnumCaseConstruction` 按 D1 消歧
- `Sources/PiniCore/Interpreter/Interpreter.swift` — `registerEnumCaseConstructor` 存关联参数类型；`.call` 裸名歧义路径按 D1 动态消歧
- `Sources/PiniCore/Interpreter/Interpreter.swift` — D3：self 调用推断补齐

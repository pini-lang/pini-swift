# ADR-026: 歧义 case 名消歧与类型传播（自举探针批次 1）

## Status

Proposed（2026-08-30，自举探针 G-P6/G-P8/G-P2/G-P3 修复批次；D5 双段落地：本 ADR 与 spec 修订同期于实现）

## Context

自举 parser 阶段（S0–S4）以可执行探针实测出四个同根缺口（`examples/selfhost/docs/host-gaps.md` G-P6/G-P8/G-P2/G-P3，宿主侧落点 `docs/issue-bootstrap-gap-remediation-2026-08-30.md`）：

1. **歧义 case 名无路可走（G-P6）**：`TypeEnvironment.parentEnum(of:)` 以单值字典 `enumCaseToParent[caseName]` 反查父枚举，跨枚举同名 case 时后注册者覆盖前者；解释器预扫描将歧义名排除出全局函数表（迫使限定写法），但 ADR-023 已裁定**不加点式限定形式**——歧义名因此构造无门。实测：E4-005（按错误父枚举校验 arity）、E4-001（expected expr, got int_lit）。
2. **self 调用类型丢失（G-P8）**：方法体内 `let x = self.f()` 绑定被推成 Any，后续与字面量比较即 E4-001；外部接收者 `a.f()` 保持类型（探针实证）。
3. **数组元素类型擦除（G-P2）**：`append` 返回 `Array<Any>`。前次修复（3eede4d）以**全局占位名 `T`** 承载元素身份、`TypeSubstitutor` 查表期替换——名字无作用域、可撞任何 `T`（9e54e27 回退自认「approach was wrong, not just the details」）。
4. **case 值无类型身份（G-P3）**：case 值不能作关联值、return 位置拒收（"expected keyword, got kw_var"；自举 lexer 以 keyword-as-text 绕行）。

## Decision

### D1 裸名 case 构造的消歧规则（G-P6①）

未限定 case 构造 `caseName(args)` 的父枚举解析顺序：

1. **期望类型优先（静态）**：调用点存在期望类型且其命名的枚举声明了该 case → 解析到该枚举；关联参数按其声明逐参校验；
2. **实参类型次之（动态）**：无期望类型或期望不命中候选时，运行时按实参值的动态类型与各候选的关联参数类型计分，取最高分（并列取字典序首个父枚举，保证确定性）；类型不可判时退化为 arity 匹配；
3. 全部候选皆不合 → 维持既有报错。

spec 钉定点：构造产生式小节增补上述消歧规则；match 小节见 D2。

### D2 match 模式按 scrutinee 类型解析（G-P6②）

`match v` 的 `case caseName(...)` 模式按 `v` 的静态枚举类型解析父枚举；scrutinee 类型不可知时按 D1 动态规则。spec §2.4.3（match）钉定。

### D3 self 调用类型传播（G-P8）

对象方法体内 `self.f()` 的返回类型按 `f` 的声明签名传播，与外部接收者一致。类型检查器单点修复（self 调用的推断路径补齐）。

### D4 作用域化类型变量（G-P2 的正确路径）

数组元素类型身份不得用全局占位名承载。类型变量必须**作用域化**于其泛型构造子实例（`Array<I32>` 的元素变量仅在该特化内可见），替换机制按实例作用域查表。此为 9e54e27 回退教训的结构化结论。

### D5 case 值完整类型身份（G-P3）

case 构造值是其父枚举类型的一等实例：可作关联值、可在期望父枚举/Any 的位置返回。运行时装箱补齐（含 Any 强转一致性）。

## Consequences

**变容易**：自举侧拆除全部绕行（case 改名还原、内联比较还原、`[Any]` 流还原、keyword-as-text 还原）；用户代码中同名 case 的多枚举模块成为合法形态。

**变难 / 挂账**：

- 歧义名的动态消歧依赖实参类型可判——纯 arity 撞车的歧义对（同参量数同参型）仍需限定写法或改名，spec 明示此边界；
- 解释器歧义预扫描与静态检查器必须共享同一候选集，两侧规则漂移由差分门禁拦截；
- D4 需要类型子系统重构（作用域化替换），工作量最大，单独批次落地。

## 实施落点（符号定位）

- `Sources/PiniCore/Type/TypeEnvironment.swift` — `enumCaseToParent` 单值字典 → 多值候选集（`parentEnums(of:)`）
- `Sources/PiniCore/Type/TypeChecker.swift` — `checkEnumCaseConstruction` / `refineEnumCaseConstruction` 按 D1 消歧
- `Sources/PiniCore/Interpreter/Interpreter.swift` — `registerEnumCaseConstructor` 存关联参数类型；`.call` 裸名歧义路径按 D1 动态消歧
- `Sources/PiniCore/Interpreter/Interpreter.swift` — D3：self 调用推断补齐

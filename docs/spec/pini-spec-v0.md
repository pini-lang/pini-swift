# Pini 不完善规范 v0（Pini Provisional Specification v0）

> **性质**：本文件是一份**故意不完美、版本化、随演进完善的权威规范**。它是代码、README 与示例应当对齐的**单一事实源（single source of truth）**。`Pini草稿.md` 降级为「设计意图与理由（rationale）」附录，README 与示例必须 conform 到本规范。
>
> **制定依据**：以 `Pini草稿.md` 为基线，吸收 Swift 语言对照。早期独立的 `pini-gap-analysis.md`（缺口）/ `pini-tensions.md`（冲突）已于 `d9fe9de` 清理，其内容合并入本规范 §3 缺口登记与路线图；下方 `缺口 N.N` / `T N` 代码仅作历史追溯标签。
>
> **核心前提（产品决策）**：在 v0.x 阶段，**语法仍可能发生破坏性更新**。本规范不假装已稳定；它通过「稳定性分级 + 已知缺口登记 + 变更治理」来把不确定性**显式化、可控化**，而不是隐藏它。这正是规范「不完善」二字的含义——缺口被登记，而非被掩盖。

---

## 0. 事实源层级与权威关系

```
本规范 spec v0  ──(权威，代码/文档/示例对齐对象)
   │
   ├── Pini草稿.md        ── 设计意图/理由（rationale），不可单独作为兼容性依据
   ├── README.md             ── 用户文档，必须 conform 本规范（修正其旧语法与失效引用）
   ├── examples/*.pini         ── 必须符合本规范，否则视为示例缺陷
   ├── docs/pini-*.md     ── 分析文档（缺口/张力/路线），引用本规范
   ├── docs/diagnostic-codes.md ── 诊断错误码**人类可读派生视图**（迟维护，权威映射在 TOML 资源，见 §2.6）
   ├── docs/test-refactoring-principles.md ── 工程标准（测试规范），受本规范 §6 治理（细则见该文档）
   └── docs/pini-comment-style-guide.md ── 工程标准（注释规范），受本规范 §7 治理（细则见该文档）
```

> 注：`docs/diagnostic-codes.md` 在事实源层级中属**派生/低权威**——错误码的权威映射是 `Sources/PiniCore/Resources/Diagnostics.{en,zh}.toml`（见 §2.6），本 md 可落后于 TOML 而不视为规范违规（迟维护）。

- 任何「草稿写了、本规范没写」的构造，以**本规范为准**；本规范未定义处按 §3 已知缺口处理（不臆测）。
- README 中指向 `../.trae/Pini语言规范.md` 的失效引用，已重指向本文件（P0 快速胜出项之一，见 §5）。
- **文档引用约定（跨文件章节缩减）**：表述中**允许提及其他文件**（文件名），但**不允许直接引用其他文件的具体章节号**——跨文件章节号会随对方文件演进而漂移成悬空引用（与本规范 §1.4 行号软证据同理）。治理原则：**见到即缩减**（把「其他文件 §N」缩减为仅文件名或粗粒度主题词）。同文件内部章节引用（如「见 §2.4.1」）不受限。豁免：机器元数据字段（如证据表 `spec_ref`）与历史归档快照（如 CHANGELOG 变更记录）可保留章节号。

---

## 1. 版本与演进策略（容忍破坏性更新）

### 1.1 版本号语义
- **v0.1**：首个基于草稿的规范快照（即本文件初版）。
- **v0.x（Pre-stable）**：允许**破坏性更新**。每次 minor 必须：① 附迁移说明（migration notes）；② 标注受影响的稳定性分级。
- **v1.0（Stable）触发条件**：核心构造（类型声明、函数、控制流、错误处理、访问控制）定为 Stable 且测试覆盖达标；§3 已知缺口收敛到可接受子集。v1.0 起破坏性变更须经完整变更流程并至少一次 deprecation 周期。

### 1.2 稳定性分级（Stability Tiers）—— 兼容性承诺的颗粒度
每个语言构造在规范中标注一级：

| 级别 | 含义 | v0.x 内破坏性变更 | 承诺 |
|------|------|-------------------|------|
| **Stable** | 已锁定语义 | 不允许（如需，须走 v1.0 路径） | 向后兼容 |
| **Provisional** | 语法已定、语义可能调 | 允许，须迁移说明 | 短期兼容，可能变 |
| **Experimental** | 语法/语义均可能大改（如 泛型运行时） | 允许，可不保证兼容 | 不承诺 |
| **Deprecated** | 已弃用 | 给定移除时间表 | 明确退出 |

### 1.3 变更治理流程（RFC/ADR 轻量版）
1. **提议（Proposal）**：说明动机、影响面、是否破坏性。
2. **影响评估**：标注受影响的构造及其稳定性级别；若触及 Stable 或跨 minor 破坏性，升级评审。
3. **登记**：写入 §3 缺口（新缺口；必要时新增 ADR 记录决策理由。
4. **落地**：更新本规范对应章节 → 同步 `Pini草稿.md`（作为 rationale）→ 同步 README/示例 → 发布 迁移说明。
5. **证据登记**：凡在正文引用代码出处，以**符号定位为主、行号为软证据**（见 §1.4）登记入证据表并打时间戳；被 §A 引用、但未在本次治理中重新验证过筛的证据，须在证据表标注 `STALE（待刷新）`。

### 1.4 证据新鲜度协议（Evidence Freshness）—— 权威性由证据支持，证据有时效

> spec 的权威性由**证据**支持（每处引用指向实现，以**符号定位为主**）；证据具有**时效性**——代码演进会使语义变更、符号迁移/删除、旧引用失效。本协议要求治理时维护**证据表**，把「某处 spec 声称有证据」与「证据当前是否可信」分开记账。

- **证据表（TOML）**：存于 `docs/evidence-table.toml`（机器可管理/可 diff/可脚本过筛）。每条记录 = `{ assertion / spec_ref | code_ref（符号定位 + 软行号） | validated_at 时间戳 | status }`。状态为 `FRESH`（本次治理 ≤60 分钟内验证通过）或 `STALE`（未在 60 分钟内重新验证，或验证失败）。
- **行号 = 软证据（软定位）**：`code_ref` 中的行号**仅作快速查看指导，不参与 FRESH/STALE 判定**。理由：① 注释/编辑会系统性移动行号（如本规范 §A 出处曾整体漂移 +120~180 行，语义完全未变）；② 一般引述（如「见 `Parser.parseFuncDecl`」）并不携带行号。证据的**权威判定键是符号名 + 语义**；行号漂移而符号仍在附近时，证据依然可信，治理时可顺手更新行号但不强制。
- **粒度（60 分钟）**：证据自 `validated_at` 起 **60 分钟**内视为可信；超过 60 分钟未重新验证 → 自动降级 `STALE`（不可信）。
- **过筛不成即不可信**：治理时对涉及证据重新过筛（grep/read 对应 `code_ref`）——**找不到符号、或语义不符** → 标 `STALE`，**不得**作为写入依据。机械过筛（行号存在/符号存在）≠ 可信；语义验证才算 FRESH。**行号对不上不自动降级**（见上「行号=软证据」）。
- **刷新协议（MUST）**：刷新证据时——① 把待刷新的 `STALE` 条目**拷贝到新条目**（保留待验证痕迹）；② **移除旧条目**；③ 重新验证后写入新 `validated_at`。每次治理只保留一张当前证据表（`docs/evidence-table.toml`）。
- **禁止**：以 `STALE` 证据作为写入 spec 的依据；凭记忆填符号/行号；复制他处引用未经重新验证。
- **存疑证据显式化**：任何「非常早期设定、未按本协议重新验证」的证据必须标记为 `STALE（待刷新，早期设定）`，不得假装可信（如 §A.4 规则 3.2 方法缺省假定）。

---

## 2. 本版本已钉住的核心（Pinned Core，v0.1）

> 即便未来可能重构，本版本**先固定**以下语义，使实现与文档有可对齐的基线。钉住 ≠ 永久不变；钉住项多为 Provisional，破坏性变更须走 §1.3。

### 2.1 类型声明定界符（行首语义）
| 记号（行首） | 含义 | 稳定性 |
|--------------|------|--------|
| `(名称)` | 结构块 / struct（值类型） | Provisional |
| `{名称}` | 引用块 / `object`（引用类型，ARC） | Provisional |
| `[名称]` | 枚举块 / enum | Provisional |
| `<名称>` | 特征块 / trait | Provisional |

### 2.2 集合与表达式位置（非行首，靠「行首/非行首」消歧）
- `[...]` 非行首 = 数组 / 字典字面量；`{...}` 非行首 = 集合字面量；`(...)` 非行首 = 元组 / 优先结合；`<>非行首` = 泛型实参。
- **消歧锚点**：当前以「是否出现在行首」为唯一规则（已知脆弱，见 §3 G2；本版本固定该法，未来可换算法）。

### 2.3 程序结构
- 顶级 = 单行标识符声明 与 复合块**交替**；块边界由下一个顶级声明隐式关闭（无 `}` 结束符）。
- **缩进敏感**：顶级声明顶格；函数体（含顶级函数）必须缩进 ≥1 层，缩进亦用于标识控制流子块边界。
- **注释**：`;` 开启，持续到行尾（示例须补带 `;` 的用例以验证词法，见 §3 G13）。

### 2.4 变量 / 函数 / 控制流 / 错误
- 变量：`var`（可变）/ `let`（不可变）。
- 函数签名：`名(形式参数元组,)->(返回元组,)`；方法显式 `|self`；单返回糖 `(T,)`；空返回 `()`。
- 控制流：`if/elif/else`、`while`（可带 `step:` 步进块；带标签跳出经 `标签|控制流关键字` 定向，如 `outer|while 条件:`——标签为裸标识符、无 sigil，见 §2.4.1）、`match/case`（case 缩进进 match 子块；通配 `case _:`，D3①）。**实现状态：标签语法已落地（ADR-014）；旧 `scope 块标签:` 已转 reserved-error。**
- 错误：`try/except` 基于**返回元组**显式传播（非异常式）；约定细节见 §3 G3。

#### 2.4.1 语言表面与实现状态（构造级索引）

> 下表按**语言构造**聚合「规范状态」与「实现状态」，是 §3 缺口登记（按主题视角）的补充视图。
> 标注：**规范状态** = 语义是否已在本文档定义（已定义 / **部分** = 语法已定义于 §A、运行语义未定 / 未定义-Experimental）；**实现状态** = ✅ 已实现、◐ 部分、✗ 未实现；**证据** = 源码符号或 `examples/*.pini`。
> 「实现 ✅ 且 规范未定义」者，语义**未落定**、按 Experimental 对待（登记缺口，非反录入为事实），正式语义待 RFC/ADR 落定。

| 构造 | 规范状态 | 实现状态 | 稳定性 | 证据 |
|------|----------|----------|--------|------|
| `var` / `let` 变量 | 已定义 | ✅ | Provisional | `Token.swift` `Keyword` |
| `func` 函数声明 | 已定义 | ✅ | Provisional | `Parser.parseFuncDecl` |
| 函数体强制缩进 ≥1 层（§A.2.3 `func-body` 仅 `INDENT { statement } DEDENT`；禁止顶级内容态顶格累积语句；trait 抽象方法豁免） | 已定义且已实现（任务 #13 草稿意图采纳） | ✅ | Provisional | `Parser.parseBareFuncDecl` 强制 INDENT / `ParserTests.testParseTopLevelFunctionBodyWithoutIndentRejected` |
| 测试函数块 `|test`（`名称|test(参数元组,) -> (返回元组,)` / `{名称|test}(签名)`；`pini test [path]` 收集范围内顶级 `|test` 逐一执行——收集单位 = 模块（G49）：无参 = 模块根全量收集，显式 `<path>` 限定范围且可加回 `[build] exclude` 排除目录；参数按类型注入零值；`Interpreter.runTests` 为运行时入口） | 已定义（v0.42.0，见 G41；收集单位更正见 G49） | ✅ | Provisional | `pini test` 子命令 / `TestBlockTests` / `TestBlockSwiftTests` / `examples/test.pini` |
| `assert` 内建（`assert(条件: Bool,)` / `assert(条件: Bool, 消息: String,)`；条件 false 抛 `RuntimeError.assertionFailed`，LLVM 端经 `@bk_panic` 终止） | 已定义（v0.42.0，见 G41） | ✅ | Provisional | `BuiltinFunctionTests` / `PiniRuntime.pini_panic` |
| 方法 `\|self` | 已定义 | ✅ | Provisional | `Keyword.self` |
| 类型声明定界符 `( ) { } [ ] < >` | 已定义（§2.1） | ✅ | Provisional | `Parser.parseTopLevelDecl` |
| 扩展块 `((T))`/`{{T}}`/`[[T]]`/`<<T>>`（规则 3.2/3.14：类型体只含字段/用例，方法须移扩展块并显式 `\|self`/`\|own`；扩展块内禁自由函数；trait 扩展允许抽象签名） | 已定义且已实现（ADR-016，任务 #12） | ✅ | Provisional | `Parser.parseExtensionDecl` / `ExtensionDecl.swift` / `examples/struct.pini` 等 |
| 内嵌组合（结构体内裸父类型名行） | 部分（检测已定义 §A.4 3.9；嵌入运行语义未定） | ✅ | Experimental | `examples/composition.pini`、`Parser.swift:497-515` |（嵌入，非并集）
| 泛型 `<T>` + 运行时单态化 | 未定义（部分 G8/G18/G24） | ✅ | Experimental/Provisional | `examples/generic.pini`、`examples/generic-func.pini` |
| trait 约束求解 | 未定义（G8） | ✅ | Experimental | `examples/trait.pini` |
| `if` / `elif` / `else`（含同级缩进块匹配） | 已定义 | ✅ | Provisional | `Parser.parseIf` |
| `while` + `标签|while` / `break label` | 已定义（部分 G11；标签经 `标签|控制流关键字` 定向，ADR-014；**已实现**） | ✅ | Provisional | `Parser.parseWhile(label:)` + 规则 3.13；`examples/control_while.pini` |
| 块标签 `标签|控制流关键字`（标签落在 if/while/for 上；`break 标签`/`continue 标签` 按标签名定向；旧 `scope 块标签:` 已逆转，ADR-014） | 已定义且已实现（ADR-014；`scope` 关键字转 reserved-error） | ✅ | Provisional | 规则 3.13（已实现）；`examples/control_while.pini` |
| 文档注释 `#`（行首，到行尾；语义=行注释，与 `;` 并存） | 已定义（v0.39.0，见 G35） | ✅ | Provisional | `Lexer.swift` `;`/`#` 行级跳过；`examples/`（文档注释用法） |
| `while ... step:` 步进块 | 已定义（v0.34.0，见 G32） | ✅ | Provisional | `Interpreter.executeWhile` + `Token.step`；`examples/step.pini` |
| `match` / `case` | 已定义 | ✅ | Provisional | `Parser.parseMatch` |
| `match` 子块结构 + `case _:` 通配 | 已落地（v0.42.0，见 G28）：case 缩进进 match 子块；通配=`case _:`；`default:`/pass 通配子块已移除 | ✅ | Provisional | `examples/match.pini` |
| `for-in` 迭代 | 已定义且已实现（v0.39.0，见 G36：`for (模式元组,) in 集合值:` + `step:`；模式元组与集合元素一一对应绑定、`_` 占位忽略；标签经 `标签|for` 定向，ADR-014，**已实现**） | ✅ | Provisional | `Parser.parseFor(label:)` / `Interpreter.executeFor` / `StmtEmitter.generateForStatement`；`examples/for.pini` |
| `defer` 块退出清理 | 部分（语法已定义 §A.2.4 defer-stmt；LIFO 运行语义按 G39 待转正，草稿已有意图） | ✅ | Experimental | `examples/defer.pini` |
| `return` / `break` / `continue` | 已定义 | ✅ | Provisional | `Keyword` |
| `pass` no-op 占位语句 | 已定义 | ✅ 已落地 | Provisional | `Pini草稿.md`、本规范 §2.4.2、示例 `validated-match.pini` |
| 元组 `(a, b)` | 已定义 | ✅ | Provisional | `TupleExpr` |
| 元组解构 `var (t, e) = rhs`（模式元组绑定，复用 for-in 模式元组产生式） | 已定义（v0.42.0） | ✅ | Provisional | `TupleDestructureTests` |
| 元组元素访问 `.0` / `.名称`（含命名元组标签） | 已定义（v0.42.0） | ✅ | Provisional | `.tupleIndex` / tuple labels / `TupleIndexTests` / `TupleNamedTests` |
| `^` 右值糖（解包 / err 控制返回；与中缀位异或、类型糖 `^T` 三重身份消歧） | 已定义（v0.42.0） | ✅ | Provisional | `ResultUnwrapTests` |
| 字符串插值 `\(...)` | 已定义（G13） | ✅ | Provisional | `examples/lexical.pini`、`Token.interpolatedString` |
| 复合赋值 `+= -= *= /= %= &= \|= ^= <<= >>=` | 部分（语法与折叠已定义 §A.2.4/§A.4 3.11；溢出/符号语义未定） | ✅ | Experimental | `Token.*Assign`、`Interpreter.evaluateBinaryOp`（Parser 折叠为 `.assign` 内 binary） |
| 位运算 `& ^ ~ << >>` | 部分（语法与优先级已定义 §A.1.2/§A.2.5/§A.3 层 5；溢出/符号语义未钉住） | ✅ | Experimental | `Token.bitwise*`、`BinaryExpr`/`UnaryExpr` |
| 匿名函数（`func` + 块体，含 async + 参数标注） | 已落地（v0.31.0，见 G29） | ✅ | Experimental | `Expression.funcLiteral`、`Parser.parseFuncLiteral`、`examples/lambda.pini` |
| 匿名函数参数类型标注 `(n: T,)` | 已落地（v0.31.0：支持，与具名函数一致） | ✅ | Experimental | `TypeInference.inferFuncLiteral` 消费 `p.typeAnnotation`；调用点校验（`FuncLiteralTests`） |
| `detach <expr>` 语句（fire-and-forget：子任务从父 scope 剪枝、结局不再归父所有，§A.2.4 detach-expr-stmt；`detach(future)` 内建函数已升格为保留关键字） | 已定义且已实现（任务 #13） | ✅ | Provisional | `Keyword.detach` / `Statement.detachStatement` / `SuspendEvaluator.detachFromParent` / `examples/syntax-future-handle.pini` |
| 下标 `a[i]`（`subscript`） | 已实现（安全模型 G48：负索引尾部计数 + 越界读返回可空 `nil` + 切片语法 `a[i:j]`，见 §A.2.5 / `SubscriptStrategies.swift`） | ✅ | Experimental | `Parser`/`Interpreter` 下标路径 / `SubscriptStrategies.swift` |
| `own` 关键字（G50 更名自 `Self`，理由：G4 命名体系全小写 snake_case 自洽；语言无所有权模型，`own` 无歧义） | 已定义（类型层出现 §A.2.6；trait 签名内 `own` 返回类型经 conformance 校验替换为具体实现类型——`TypeChecker.replaceSelf`，抽象/默认实现均覆盖） | ✅ | Provisional | `Token.swift` `Keyword.own`、`TypeChecker.replaceSelf` / `TraitConstraintTests.testSelfReturnTypeConformance`/`testSelfReturnTypeInDefaultImplementation` |
| 数组 / 字典 / 集合字面量 | 已定义（G17；COW 值语义见 G34，v0.38.0） | ✅ | Provisional | `examples/collections.pini`、`examples/cow.pini` |
| 内建错误类型 `Error()` / `Result` / `CancelError()` | 已实现（G12 异步模型已定义，Stable；错误类型构造细节未钉定，仍 Experimental） | ✅ | Experimental | `examples/concurrency.pini`、`Interpreter` |
| 弱引用 `WeakRef`（`WeakRef(obj)`；`.target` / `.isAlive`；引用语义复制共享同一 box、弱引用计数对称配对） | 已定义（v0.42.0，见 G42） | ✅ | Provisional | `Interpreter`/`ARCManager`/`WeakRefTests` |
| 懒加载 `LazyRef<T>`（构造 `LazyRef<T>(初始化闭包)` / 推断糖 `LazyRef(闭包)`；`.value` 同步 once 获取；引用语义复制共享同一 box；多线程首访仅一个线程执行初始化） | 已定义（v0.42.0，见 G40） | ✅ | Provisional | `examples/lazyref.pini` / `Interpreter`（`.lazyRef`）/ `PiniRuntime.pini_lazyref_*`（LLVM） |
| `Optional` | 部分（类型糖 `?T`/`nil` 已定义 §A.2.6/G30/G31；运行时释放/提升语义未定） | ✅ | Experimental | `Interpreter` |
| `nil` 关键字（= `Optional.none` 等效常量） | 已定义（v0.35.0，见 G30） | ✅ | Provisional | `Keyword.nil` / `Parser.parsePrimaryAtom` / Pini草稿.md（G30） |
| `?` 可选类型糖（前缀 `?T` = `Optional<T>` 类型层缩写） | 已定义（v0.36.0，见 G31） | ✅ | Provisional | `Token.questionMark` / `Parser.parseTypeAnnotation` / Pini草稿.md（G31） |
| `iota()` 枚举序位自增 | 已移除（v0.29） | ✗ | Removed | 违反无元编程原则；字面量默认亦随规则 3.15（ADR-016）移除——枚举关联参数仅位置类型 |
| 异步 `=>` 派发 + `await`/`wait`（`await` 异步体挂起 / `wait` 同步阻塞 join；挂起模式经自建续体运行时释放 OS 线程、精确恢复；同步/阻塞 join 为默认路径） | 已定义（G12 / §3.1；v0.41.0 落地，v0.43.0 T7→Stable） | ✅ | Stable | `examples/concurrency.pini` / `SuspendEvaluator.swift`、`SuspendScheduler.swift` |
| `import` / `export`（解析 + **跨模块** enforce） | 已定义（P4 v0.23；跨模块语义 **G52**） | **◐** | Provisional | `Parser.parseImportDecl`（**仅解析，语义零消费者**：`SemanticAnalyzer`/`TypeChecker`/`IRGenerator` 均 `break`）；现有「跨文件 enforce」实由 `_` 前缀完成，与 import/export 无关；跨模块 enforce 待 G52 落地 |
| `pini.toml` 模块清单 | 已定义（P4 v0.23；边界细则见 **G52**） | **◐** | Provisional | `Package`/`FileLoader` 加载 + 跨文件符号 + 可见性 enforce **已实现**；`[dependencies]` 仅记录不解析、`spec`/`[[bin]].entry`/`[lib]`/`[tool.pini]` 不消费、跨模块依赖解析与 MVS **未实现**（G52） |
| 标准库内建函数（28 个，按 ADR-020 D4 六组组织：collection/char/pointer/io/math/concurrency/value） | 部分（G14 文件 IO 已落地；字符谓词已定义 ADR-019；并发签名未钉） | ✅ | Provisional/Experimental | `BuiltinRegistry`（单点登记）/ `Interpreter` 内建分发 |
| 文件 IO `readFile`/`writeFile`/`readLine` | 已落地（G14） | ✅ | Provisional | `examples/io.pini` |
| `[名称\|foreign]` 块（§A.2.2 foreign-decl：外部 C 函数签名，块内函数自动 `\|unsafe`；运行时经预注册原生函数表解析 `malloc`/`free`/`memcpy`/`memset`/`strlen`/`puts`/`strcmp`/`cstr`；未注册函数注册期 fail-fast） | 已定义且已实现（ADR-015，Phase 2a 解释器优先；LLVM 端显式 unsupported） | ✅（解释器） | Experimental | `Parser.parseForeignDecl` / `Interpreter.registerNativeFunctions` / `FFITests` / `examples/ffi.pini` |
| `unsafe <expr>` 消耗点 + `&` 取地址（§A.2.5：前缀一元；`unsafe` 标记单次不安全操作；`&` 仅 unsafe 上下文可用，非 unsafe 上下文报 E4-001；解释器 `&` 为快照取址） | 已定义且已实现（ADR-015，Phase 2a） | ✅（解释器） | Experimental | `Expression.unsafe`/`.addressOf` / `TypeChecker.unsafeContextDepth` / `FFITests` |
| `\|unsafe` 函数修饰符（仅自由函数：顶层或 foreign 块签名；函数体自动不安全上下文；扩展块方法 / trait 签名标它报错） | 已定义且已实现（ADR-015，Phase 2a） | ✅（解释器） | Experimental | `Parser.parseBareFuncDecl`（`allowUnsafeModifier`）/ `TypeChecker.checkFuncBody` / `FFITests` |
| `*T` 原始指针 + C 兼容性（§A.2.6：元素须标量/纯值结构体/另一指针；禁 object 及含 object 复合类型，ARC 隔离） | 已定义且已实现（ADR-015，Phase 2a） | ✅（解释器） | Experimental | `TypeAnnotation.pointer` / `TypeChecker.validateDeclPointerTypes` / `Value.rawPointer` / `FFITests` |
| 指针原语 `load`/`store`/`addressof`（按指针元素类型编解码 I8/I16/I32/I64/F32/F64/Bool/指针；runtime C-ABI 面 `bk_ptr_*`） | 已定义且已实现（ADR-015，Phase 2a） | ✅（解释器） | Experimental | `Interpreter.registerPointerBuiltins` / `RawPointerValue` / `PiniRuntime.pini_ptr_*` / `FFITests` |

#### 2.4.2 `pass` 关键字（no-op 占位 + 通配子块校验性匹配）

> **状态**：已定义、已落地（v0.30.0）。本小节为权威语义定义。稳定性 **Provisional**。

`pass` 是一个 **no-op 占位语句**：求值结果为 `null`，无副作用；可作任意语句位置，也支持 `:` 后的单行表达式形式（`if 条件: pass`）。

**具体用途（产品规格）**：

1. **占位空块（结构占位）**：语法要求块体但当前无操作——`if/elif/else/while` 后接 `pass`，保留控制结构骨架、避免「空块非法」，语义明确「我有意不做事」。
2. **match/case 分支占位（防御性 no-op）**：`case 已读: pass`，比空块更清楚「我知道这个分支、故意不做」。（match 通配兜底用 `case _:`，见 §2.4.3。）
3. **显式吞掉错误（try/except）**：`try f(): except e: pass` 表示「已知该错误可安全忽略」，比空 `except` 块更显式。
4. **桩函数 / 待实现接口（stub）**：`func 尚未实现(): pass` 作为接口/trait 默认实现的占位，便于增量开发与编译期占位。
5. **trait 默认方法空实现**：trait 提供「默认什么都不做」的方法，`object`/struct 未覆盖即沿用 `pass`。
6. **显式「已处理」分支标记（防御性 no-op）**：`match`/`case` 中某分支确实无需动作时 `case 已读: pass`，比空块更清楚「我知道这个分支、故意不做」。

**语义边界（明确 NOT 用途）**：
- `pass` 值为 `null`，**不是**有意义的表达式值（不应 `let x = pass` 当有效值使用）。
- `pass` 不终止控制流（不像 `break`/`return`），仅占位。
- `pass` 与 match 穷尽性**无关**（见 §2.4.3）：match 穷尽性检查为内建契约，不再由「通配子块 = `pass`」触发。

### 2.4.3 match 子块结构 + `case _:` 通配 + 穷尽性（G28）

**现况**：
- **结构**：`case` 缩进进 `match` 子块。
- **通配**：通配兜底为 `case _:`（`default:` 与裸 `pass` 通配子块不存在）。
- **穷尽性/可达性**：枚举 match 缺变体且无 `case _:` → 语义错误 `nonExhaustiveMatch`（检查**总是开启**）；字面量 match（值域无限）静态不检查，未命中且无 `case _:` 时保持静默（运行时）。

**语法**：
```
match 值:
    case 模式[:绑定]:
        block
    case _:
        block
```

**穷尽性契约（R1）**：
- 匹配值推断为枚举类型：case 未覆盖全部变体、且无 `case _:` 兜底 → `nonExhaustiveMatch`（编译期）。
- 匹配值为字面量（int/float/string/bool）：静态不检查（值域无限），运行时未命中且无 `case _:` 时静默（R3）。
- `case _:` 为通配兜底，与 `default`/pass 通配子块语义等价；运行时捕获一切未命中值。

### 2.4.4 `try`/`except` 错误传播模型（errors-as-data，非异常式）（G3）

> **状态**：已定义、已落地（v0 现状；G3 闭环）。本小节为权威语义定义。稳定性 **Provisional**。
> **证据**：`Interpreter.executeTry`（Interpreter.swift:1996）、`^` 右值糖 `ResultUnwrap`（Interpreter.swift:1385/1393，`throw UnwrapErrSignal`；`UnwrapErrSignal` 由函数边界 Interpreter.swift:2536-2538 捕获注入返回元组末槽）、`examples/` 并发与错误示例。

`try expr` 将 `expr` 求值为 `(值, 错误)` 元组，**错误位 = 元组第 2 元素**（`elements[1]`，Interpreter.swift:2002-2005）；`^` 右值糖（`^T` ≡ `Result<T>`）把 `Result` 解包：`ok(v)` → `v`，`err(e)` → 抛 `UnwrapErrSignal`，由函数边界捕获并注入**返回元组末槽**——错误始终是值，不在调用栈上抛异常（errors-as-data）。

**成功 / 错误判定**（`executeTry`，Interpreter.swift:2007-2035）：
- 错误位为 `.null` 或空字符串 → 视为**无错误**，执行 `try` 块（成功路径）。
- 错误位非空 → 执行 `except` 子句：将错误值绑定到 `except` 变量（`clause.errorVar`），执行首个 `except` 子句体后返回。

**与异步错误的关系**：`await`/`wait` join 得到的 `Future` 经 `Result` 解构后，其 `CancelError` 同样落在 `(值, 错误)` 元组的错误位中，**经 `except` 正常捕获、不穿透 `try`/`except`**（与 §2.4.1 异步行一致）；`CancelError` 不绕过 errors-as-data 模型。

**已知限制（Provisional 显式登记）**：
- 单 `except` 子句，**不按错误类型分派**：多个 `except` 时仅首条被匹配（Interpreter.swift:2020-2034 取首个 clause）；类型化多分支 `except` 为后续增强。
- 成功路径的「值」不自动绑定到名字：`try` 块内默认不可直接引用被 `try` 表达式的成功值（须另行 `let` 捕获）。

### 2.5 访问控制（约定制 4 级）

> **现况**：可见性由「符号名 `_` 前缀 + 文件/目录名 `_` 前缀」共同决定（约定制；旧 `^^`/`_^`/`__` 符号制已移除）。实现：`VisibilityLevel.forSymbol(name:fileName:)`（`Sources/PiniCore/AST/Visibility.swift`）按「符号名 `_` 前缀 → private / 文件名 `_` 前缀 → internal / 目录名 `_` 前缀 → package / 默认 → public + `main` 豁免」推导，跨文件 enforce 经 `PackageSymbolIndex`（语义层 `build` 拦截重声明、类型层 `isVisible(from:)` 判定）。演示与测试：`examples/package-demo`、`CrossFileVisibilityTests`、`FieldVisibilityTests`。**跨模块边界（G52 收口，原 G15 缺口）**：跨模块（import/export）边界 enforce 与块式别名表（`[名称|import]`/`[类型名称|export]`）已由 **G52** 决议——`import` 即依赖、依赖图禁环、全导入绑定别名、`别名.符号` 限定访问、跨模块引入门槛仅 `public`；**宿主实现待做**，详见 `issue-module-system-rules-2026-08-28.md`。

- **可见性四级（取三者最严格者为准）**：

  | 级别 | 触发条件 | 可见范围 | 等价参考 | **可被跨模块引入**（G52） |
  |------|----------|----------|----------|:---:|
  | **private** | 符号以 `_` 开头 | 当前类型内部 | Swift `private`、Go 小写首字母 | ❌ |
  | **internal** | 符号不以 `_` 开头，且所在**文件名**以 `_` 开头 | 当前文件内 | Swift `internal` | ❌ |
  | **package** | 符号不以 `_` 开头，且所在**目录名**以 `_` 开头 | 当前包内 | Swift `package`、Go internal 包 | ❌ |
  | **public** | 符号 / 文件 / 目录均不以 `_` 开头 | 全局 | Swift `public`、Go 大写首字母 | ✅ |

  （符号名 `_` 为硬私有，覆盖文件/目录逻辑；多信号同现时取最严格可见性。）

  **跨模块引入门槛 = 仅 `public`**（G52 D8）。`package` 级的释义由此收窄为「本模块及其后代子模块可见、**不可被跨模块引入**」；`public` = 「同模块可见 **且** 可被引入」。二者在 G52 之前同桶（无第二模块可"引入给"），R4 落地后**首次获得区分度**。
  `private` 与 `internal` 在可达范围上**保持同桶**（均为"仅本文件可达"），不做区分——**封装性由文件内保证**（G52 D14）；二者差异在作用域是符号级还是文件级，不在可达范围。

- **`_` 单一语义原则（已决）**：`_ ` 统一表示「**退出默认表面 / 仅限显式 opt-in**」——凡被标 `_` 的一侧即退出其所属上下文的默认表面，须显式引用方可触及。三种语境同属一根轴：
  - 声明符号 `_名称` → 符号退出默认可见表面 → private（仅类型/块内显式可达）；
  - 导出表别名 `_C = StructC` → 该导出项退出导出表面 → 抑制导出（non-exported）；`StructB = _StructB` 反之（把私有原符号提升为公开别名）；`_D = _StructD` 无意义；
  - 导入表别名 `_B = "路径"` → 该导入项退出显式表面清单 → opt-in / 隐式依赖（须显式引用，不自动进入默认命名空间）。
  - **决策理由（弃用方案 B）**：方案 B 拟为导入隐式性另立 `implicit` 关键字；但 Pini 中**每个独特关键字的通用块都有各自不同的内部语法**，新增关键字即新增一套块语法、扩大语法不一致面。复用 `_` 作为贯穿多语境的「退出表面」修饰符，可避免关键字 / 块语法增殖，与既有「`_ ` 前缀即修饰」约定一致。故采用方案 A（泛化 `_` = 退出默认表面），导入隐式性不再另立关键字。

- **元数据**：`pini.toml` 描述模块名 / 版本 / 依赖（P4 落地）。

- **import / export 逃生舱（P4 落地）**：`[名称|import]` 绑定包路径到用例标识符（全导入）；`[类型名称|export]` 显式覆盖默认导出规则——提升 `_` 私有符号为公开（`StructB = _StructB`），或把公开符号降为非导出（`_C = StructC`）。

- **依赖图与跨模块访问（G52）**：
  - **`import` 即依赖**：`import` 是**文件级**声明（每个文件自己的 `[名称|import]` 块）；**模块依赖 = 该模块所有文件 import 的并集**（与 Go 同构：import 按文件书写，依赖按模块聚合）。
  - **依赖图无环**：构建时检测模块依赖图，成环则报错，并给出可读路径（如 `app → text → uni → app`）。环检测通过 ⇒ 依赖图为 **DAG** ⇒ 可拓扑序编译，**顶层初始化顺序良定义**。
  - **禁环的代价**：父子模块**不能互相使用**——需要互相引用时必须抽出第三方模块（依赖倒置）。
  - **全导入**：绑定模块到别名。**注入 = 以 `别名.符号` 限定访问**，而**不是** `import.别名.符号`——块头名（`[名称|import]` 中的 `名称`）只是标签，**不进访问路径**。别名**静态消解**，不占运行时值命名空间，故永不与用户变量重名。
  - **别名一致性**：模块内**非 `_` 别名**到模块的绑定必须全局一致；`_别名` 为**文件私有导入**，不进模块共享表面、不受此限。
  - **清单节（G52）——依赖分两个通道，判据是「目标**根**有无 `pini.toml`」**：
    - `[require]` / `[require.<tap>]`：**根有** `pini.toml`，即 Pini 模块。**可 `import`、激活 MVS**；条目集合**由代码中的 `import` 生成**（人工只可覆盖版本约束）。落地 `deps/<name>/`——各模块自带清单，由 **R1 自动切出**父模块的扫描。
    - `[resources]` / `[resources.<tap>]`：**根无** `pini.toml`，即非 Pini 资源（语料、数据集、脚本等）。**不可 `import`、不参与 MVS**；固定落地 **`.pini/resources/<name>/`**（R6：点前缀 ⇒ 不参与扫描），**无 `to` 参数**。**只查根、不查深层**（R7）。
    - 判据**双向强制**且**只看目标根**（R7）：把资源写进 `require`、或把模块写进 `resources`，均报错并指引到另一侧。
    - `[tap]` 声明**从哪来**；`[replace]` 提供**强制版本 / 本地 / 换 fork** 替换（仅主模块生效）。`[dependencies]` **已移除**（职责拆分给 `require` + `resources`）。
  - **非源码内容的落点与扫描（G52 R5–R6）**：**点前缀目录（`.` 开头）不参与任何模块的源码扫描**，其整棵子树跳过——**只取 `.`，不取 `_`**（`_` 在 Pini 是 **package 级可见性**语义，Go 的「工具不可见」语义不可照搬）。工具管理的非源码内容统一置于模块根的 **`.pini/`** 下：`resources/<name>/`（资源）、`toolchain/<name>/`（宿主）、`build/`（产物）、`cache/`（缓存）、`version`（宿主版本 pin）。
    ⇒ 项目现有的宿主 **`pini-swift` 属 `.pini/toolchain/` 一类，不属 `resources`**——它是**工具链**（读清单的那个东西，不是被清单描述的东西；Go 不在 `go.mod` 里写 Go 编译器）。
  - **文件命名（G52 R8）**：模块清单 = **`pini.toml`**（原 `module.toml`），锁文件 = **`pini-summary.toml`**（原 `_summary.toml`）。文件名是 R1 判定模块边界的**哨兵**，须特异到误判率近零（通名会让外来工程被**静默**误判为子模块）；**旧名 `module.toml` 命中即报错**，不得静默降级为「无清单」。
  - **版本与命令**：版本按 **MVS** 求解（输入 = `[require]` 的传递闭包），结果生成到 `pini-summary.toml`（生成物但**必须提交**）。命令集 `pini mod {tidy, refresh, verify, graph}`——`tidy` **离线**对齐集合、`refresh` 重解版本并下载（**唯一联网**；build 永不抓取）、`verify` 执行校验和、`graph --cycles` 输出依赖环。

- **稳定性**：约定制方案标 **Provisional**（v0.x 允许破坏性变更，须附迁移说明）；旧符号制 `^^`/`_^`/`__` 已移除（不进入 Deprecated 共存期）。

### 2.6 诊断错误码权威映射（Diagnostic Codes）

> **状态**：已落地（T1/T11，v0.44.0 批次 A）。本小节为权威治理规则。稳定性 **Provisional**。

- **权威映射（single source）**：错误码 → 消息/建议模板的**唯一权威映射在 TOML 资源**——`Sources/PiniCore/Resources/Diagnostics.{en,zh}.toml`（经 `Bundle.module` 加载；`--lang zh|en` 切换，未覆盖码回退 zh）。代码侧 `DiagnosticProviding` 协议元数据（`Sources/PiniCore/Common/Diagnostic.swift`）与 `ErrorFormatter.formatDiagnostic` 渲染（`Error: <类型> [<code>]`）以 TOML 为文案源。
- **登记规则（append-only）**：新增错误码**只须登记 TOML**（两语言资源同步登记；已分配的码不删除、不复用；新码追加段内编号）。**不得**以任何人类可读文档（含 `docs/diagnostic-codes.md`）作为登记入口——消除多重事实。
- **域段约定**：E0 通用 / E1 词法 / E2 语法 / E3 语义 / E4 类型 / E5 运行时 / E6 IR 生成；E7 警告段预留（warning 通道）。
- **派生视图（低权威，迟维护）**：`docs/diagnostic-codes.md` 为人类可读**派生视图**（错误码→含义），**可落后于 TOML 而不视为规范违规**；其内容不具权威性，不一致时以 TOML 为准。同步为低优先级维护（随批次顺手更新，非强制）。
- **一致性检查（建议）**：`tomllib` 可脚本比对 TOML 键集与 `Diagnostic.swift` 分发；派生 md 不纳入一致性门禁。

---

### 2.7 FFI 与 unsafe（Experimental，ADR-015）

> **状态**：已实现（Phase 2a 解释器优先，2026-08-27 落地；稳定性 **Experimental**，v0.x 内可大改）。语义定义见本小节与 §A EBNF。实现策略（用户决策 D1）：**解释器优先（Phase 2a），LLVM 端暂缓**。落地规划见 `docs/pini-landing-plan-v048.md`。

Pini 通过 FFI 调用宿主 / C 侧函数，并暴露最小不安全面以操作原始内存。设计原则：**不安全范围最小化**、**与 ARC 隔离**、**严守 C ABI（spec §3.2，不得泄漏 Swift 类型）**。

- **FFI 配置**：`pini.toml` 中 `[ffi] abi = "C"` 可省略，默认 C；不引入文件级 / 块级 ABI 覆盖；混合 ABI 拆分模块处理。
- **`unsafe` 表达式前缀**：标记单次不安全消耗点，精确控制最小不安全范围；作用于紧随其后的单次函数调用或指针操作；复合表达式用括号 `unsafe (加载(p) + 1)`；任何函数体内可用（`unsafe` 消耗点）。
- **`|unsafe` 自由函数**：仅限自由函数，表示「调用者须保证前置条件」；禁止与 `|self` / `|test` 组合；函数体自动处于不安全上下文，内部无需 `unsafe` 前缀；匿名函数不可标 `|unsafe`（闭包体内用 `unsafe` 消耗点；闭包不继承外层不安全上下文）。
- **`*T` 原始指针**：`*T` 指向 `T` 的原始指针；`T` 须为 C 兼容类型（标量、纯值类型结构体、或其他指针类型），**禁止 `object` 或含 `object` 字段的复合类型**；持有 / 传递 / 比较指针安全，解引用 / 指针算术 / 类型转换须在 `unsafe` 消耗点后；初始化与释放由用户手动保证（建议 `defer` 释放）；`&` 为不安全取地址前缀。
- **`[名称|foreign]` 块**：声明外部 C 函数签名，块内函数自动视为 `|unsafe`；不接收内联 ABI 参数，继承模块级 `pini.toml` 设定的 FFI ABI（默认 `"C"`）。
- **与 ARC 的隔离**：`*T` 指向的内存不是 ARC 对象，不参与自动引用计数；编译器确保 `*T` 不能指向 ARC 对象（类型约束），不允许将 ARC 对象转换为 `*T`（除非经标准库安全借用函数）。
- **安全封装模式**：不安全内核写成 `|unsafe` 自由函数（显式获得全部输入），安全方法 / 函数检查前置条件后通过 `unsafe` 消耗点调用。

- **FFI 类型白名单（顶层签名）**：`[名称|foreign]` 块内函数的**顶层参数与返回值**仅允许以下 C 兼容类型（声明期静态校验，不合规则报错，见 §8 错误表）：
  - **标量**：`I8`/`I16`/`I32`/`I64`、`U8`/`U16`/`U32`/`U64`、`F32`/`F64`、`Bool`、`()`（void，即空返回）。
  - **指针**：`*T`（T 为标量 / 纯值类型结构体 / 另一指针；`*T` 元素须 C 兼容，见 §A.2.6）。
  - **永远禁止**（顶层签名）：by-value 结构体、对象（及含 object 字段的复合类型）、`String`、`Optional`、`Result`（`^T`）、元组（含多返回元组）、函数类型。
  - **`Char` 不进入 FFI 标量集**：C `char` 符号性由实现定义，字节缓冲统一用 `I8`/`U8`；`Char` 保留为一般语言类型，不出现在 FFI 签名（与解释器指针原语按 I8/U8 编解码一致，避免 ABI 符号性歧义）。`*T` 元素同理排除 `Char`。
  - 注：`*T` 的**元素**可为纯值类型结构体（仅作地址 + 布局，可控）；但**按值（by-value）的结构体作为顶层参数 / 返回值**不在 Phase 2 范围（见下「实现分阶段」）。

- **foreign 函数解析顺序（shim 白名单 → 裸 C 绑定）**：一个 foreign 函数名按固定优先级解析，二者分属不同类别：
  1. **原生 shim 白名单**（Phase 2a 已落地）：运行时预注册实现（如 `cstr(s: String)` 把 Pini 字符串转 C 字符串——其签名可含 Pini 友好类型，非 100% C 兼容），由 runtime 实现、不走符号查找。
  2. **裸 C 绑定**（Phase 2b 解释器已落地，ADR-017）：按块名对应库经 `dlsym` 解析符号；签名必须 100% C 兼容（上述白名单）。注册期为每个函数按精确 C 签名生成 **thunk 闭包**（`@convention(c)` 函数指针，见下「类型映射与 thunk 工厂」），避免 libffi 依赖——因 Phase 2a 已将顶层类型收敛为封闭集，分支可枚举。
  - 解析顺序固定 ① → ②；未命中任何类别则在注册期 fail-fast 报错（提示可用 shim 表 + 库/符号未找到错误 E5-016/E5-017）。`cstr` 等 shim 与裸绑定因此不再矛盾（§3「禁止 String」的例外有了归属）。

- **`[ffi]` 模块配置（模块级，§6.1）**：`pini.toml` 可声明 `[ffi]` 表（前向配置，Phase 2b 起消费）：
  - `abi`：**全局唯一**，默认 `"C"`，子模块**不可覆盖**（与模块级 ABI 决策一致）。
  - `search_paths`：库搜索路径，**分层追加**（子模块追加到父模块之后；可声明替换）。
  - `libs`：需链接的库列表，**全局统一链接**（LLVM 阶段拼接 `-L`/`-l`）。
  - `parseManifest` 对未知 `[table]` 容错忽略（缝 ⑦）。
  - 解释器经 `Interpreter(ffiConfig:)` 注入合并后的 `FFIConfig`（`FFIConfig.default` 兜底系统默认路径）；`libc` 为保留库名，直连系统 C 库（`RTLD_DEFAULT`），不经路径搜索。

- **类型映射与 thunk 工厂（裸 C 绑定）**：Phase 2b 解释器为每个裸绑定 foreign 函数生成 `([Value]) throws -> Value` thunk：
  - 标量参数/返回：`I8/U8/I16/U16/I32/U32/I64/U64`→`CChar/CShort/CInt/CLong/...`、`F32/F64`→`CFloat/CDouble`、`Bool`→`CBool`，`@convention(c)` 原样传值。
  - 指针参数/返回：`*T`→裸地址（`UnsafeRawPointer`，Pini 的 `RawPointerValue` 即裸地址，直接透传）。
  - 返回 `()`→`Void`。
  - 冷门组合（如罕见标量对位）抛「unsupported signature」已知限制。thunk 经 `SystemDL`（Darwin/Linux `dlopen`/`dlsym`/`dlclose` 封装）+ `FFILoader`（库名→路径解析、句柄缓存）落地。

- **实现分阶段（架构闭环，实现按节奏）**：FFI **设计已闭环**——语法（`foreign` 块 / 库名映射 / 模块级 ABI）、类型映射、unsafe 边界、安全封装模式均已定义，无模糊地带；**实现分三阶段演进**：
  - **Phase 2a（✅ 已落地）**：解释器 + 预注册原生函数表 + `*T` / unsafe 静态约束；LLVM 端 FFI 显式 unsupported（D1 决策）。
  - **Phase 2b 解释器（✅ 已落地，ADR-017）**：`dlsym` 动态符号解析 + `[ffi]` 配置解析 + thunk 工厂 + `SystemDL`/`FFILoader`/`ForeignThunk` 三文件；LLVM 端 FFI 缝合层仍 ⏳（Phase 2b-LLVM，复用 §3.2 单一 `@bk_*` C-ABI 边界）。
  - **Phase 2c（⏳ 已规划，可选）**：by-value 结构体 ABI 层（System V AMD64 / AAPCS 传参规则）。自举编译器不需要，仅在生态确实需要时立项。

> **已知限制（Experimental 显式登记）**：解释器端 FFI 已落地（Phase 2a + Phase 2b 解释器，2026-08-27）——原生函数表为**预注册 Swift 实现**（malloc/free/memcpy/memset/strlen/puts/strcmp/cstr），**裸 C 绑定经 `dlsym` 动态加载**（库未找到 E5-016 / 符号未找到 E5-017）。LLVM 端 FFI 仍显式 unsupported（D1，留 Phase 2b-LLVM）。解释器 `&` 为**快照取址**（写回不更新原变量），与 LLVM 端真引用语义不同——见 CHANGELOG。by-value 结构体 ABI 属 **Phase 2c（可选，未实现）**；`Char` 不纳入 FFI 标量集（与解释器指针原语按 I8/U8 编解码一致）。变参函数（`printf`）、回调/函数指针参数（`qsort` 比较器）、`errno`/线程局部访问、非 C 的 ABI 均 out-of-scope（Phase 2b 不支持）。

## 3. 已知缺口登记（Known Gaps Register）—— 「不完善」的显式清单

> 凡列入下表者，本规范**明确声明 unspecified**，读者不得视为已承诺行为。每项随演进在对应版本填补或收敛。

> **关于「计划版本」列**：该列为**推测性目标版本**，仅表示预期落地的 spec 次版本，**不等同于 roadmap 的 P 阶段**，二者无直接一一对应。实际落地点以 `pini-roadmap-next.md` 的 P 阶段为准。

| 编号 | 主题 | 状态 | 稳定性 | 计划版本 | 关联 |
|------|------|------|--------|----------|------|
| G1 | 形式化 EBNF（声明/表达式/语句/类型） | 已定义（权威文法见 §A 附录；原草案降为历史） | Provisional | v0.43.0 | 缺口 1.1 / §A |
| G2 | 行首定界符分派（类型声明 vs 字面量） | 已定义（§A.4 规则 3.0 / §2.1–§2.2；「行首位置」单一锚点，脆弱性显式登记） | Provisional | v0.43.0 | Parser.swift:347-384 / §A.4 3.0 |
| G3 | `try`/`except` 返回元组错误传播（errors-as-data，非异常式） | 已定义（§2.4.4；错误位=元组第 2 元素，`^` 右值糖注入返回元组末槽） | Provisional | v0.43.0 | Interpreter.swift:1996 / 1383 / §2.4.4 |
| G12 | 异步语义模型（`=>` 派发 + `await`/`wait` join + 结构化并发 + 协作式取消；取代立场 B 的 `<=` 前缀，见 ADR-012） | 已定义（权威契约见 §3.1；v0.41.0 落地，T7 正式化 v0.43.0 → **Stable**） | Stable | v0.43.0 | SuspendEvaluator.swift / SuspendScheduler.swift / Value.swift / §3.1 |
| G40 | `LazyRef<T>` 懒加载（`.value` once / 引用语义 / 双后端；无 `.valueFuture`） | 已采纳（v0.42.0 转正） | Provisional | v0.42.0 | `docs/pini-roadmap-next.md` |
| G41 | `测试函数块 |test`（`pini test` 子命令 / `assert` 内建 / 参数注入零值 / SwiftTesting 宿主） | 已采纳（v0.42.0 转正） | Provisional | v0.42.0 | `docs/pini-roadmap-next.md` |
| G42 | `Ref 系类型引用语义`（独立 Value case + class 承载、复制共享状态） | 已采纳（v0.42.0 转正） | Provisional | v0.42.0 | `docs/pini-roadmap-next.md` |
| G43 | FFI 与 unsafe 子系统（`foreign` 块 / `*T` 指针 / `&` 取址 / `unsafe` 表达式 / `|unsafe` 函数 / 与 ARC 隔离） | 已实现（Phase 2a 解释器优先 + Phase 2b 解释器 dlsym 动态加载：foreign 块 + 原生函数表 / `*T` C 兼容性校验 / `&`+unsafe 上下文 / `|unsafe` 函数 / `dlsym` 裸 C 绑定 + thunk 工厂 + `[ffi]` 配置 + `SystemDL`/`FFILoader`；LLVM 端 FFI 仍显式 unsupported，D1） | Experimental | v0.48.0（Phase 2a）/ v0.48.3（Phase 2b 解释器，ADR-017） | §2.7 / §A.2.2(`foreign-decl`)/§A.2.5(`&`/`unsafe`)/§A.2.6(`*T`) |
| G44 | 控制流标签语法反转（`scope 块标签:` → `标签|控制流关键字`；`scope` 关键字转 reserved-error） | 已实现（ADR-014：parseStatement 标签分派 + parseIf/parseWhile/parseFor(label:)；`scope` 转 reserved-error） | Provisional | v0.48.0（Phase 1） | §A.4 规则 3.13 / ADR-014 |
| G45 | 字符谓词 `is_letter`（UCD \p{L} 字母判定，`String -> Bool`；空串/首字符非字母 → false） | 已实现（解释器端；自举 lexer 前置，issue-lexer-gaps-2026-08-28 P1-A） | Provisional | v0.49.0 | §A.1.1 IDENT（`\p{L}` 实现原语）/ ADR-018 G1 |
| G46 | 数组 `append` 成员方法（**函数式**返回新数组，原数组不变，COW 值语义；`a.append(x)`） | 已实现（解释器端；自举 lexer 前置：token/诊断收集，issue-lexer-gaps-2026-08-28 P1-B） | Provisional | v0.49.0 | §2.4.1 G17（集合字面量）/ G34（COW） |
| G47 | 数组栈操作 `last` / `pop`（函数式：`a.last()` 读栈顶、空 → null；`a.pop()` 返回 `(新数组, 栈顶)` 元组） | 已实现（解释器端；自举 lexer 前置：IndentTracker 缩进栈，issue-lexer-gaps-2026-08-28 P1-C） | Provisional | v0.49.0 | §2.4.1 G17 / G34 |
| G48 | 集合下标安全模型（安全通道）：① 负索引尾部计数（`i<0 → len+i`，`-1`=末元素、`-len`=首元素）；② 越界（读）返回可空 `nil`（与字典缺失键一致，`Value.null`），调用者显式解包；③ 切片语法 `a[i:j]`/`a[i:]`/`a[:j]`/`a[:]`（Python 风半开区间，步长暂缓），脱糖为成员调用 `a.slice(i, j)`（开放边界传 `nil`）；④ `substring(start, end)` 负索引由"夹 0"改"尾部计数"（Python 一致）。下标写越界仍报错（不能经赋值越界扩容器）。`a[i]` 类型推断为 `Optional<T>`（P2-E） | 已实现（解释器端；issue-lexer-gaps-2026-08-28 P2-A/B/C/D/E；unsafe 单元素直接访问通道 P2-F 搁置至 roadmap backlog） | Provisional | v0.49.0 | §A.2.5 `postfix-suffix` / `SubscriptStrategies.swift` / `Interpreter.evaluateMember`(`slice`) / `TypeChecker.defineMethod`(`slice`) / P2 安全模型流程图（issue-lexer-gaps-2026-08-28） |
| G49 | 模块清单与测试收集收口（TDD 解锁）：① 清单 schema 单一 `[package]`（`project` 概念不入 pini.toml——模块系统以子模块无痛组合为目标，所有 pini.toml 同一 schema；工作区级概念未来另立文件）；② `[build] exclude = [...]`（Provisional）显式排除路径——**G52 D27 收窄：它是 `pini test` 收集范围的排除，不是模块树扫描的排除**（依据本表 §1 `pini test [path]` 可「加回排除目录」的语义）；模块树扫描的边界由 R1（清单）与 R5/R6（点前缀 / `.pini/`）决定，`exclude` **不参与**；③ `pini test [path]` 收集单位 = 模块（回归 G41「收集所有 `|test`」原意）：无参 = 模块根全量，显式路径限定范围且可加回排除目录，模块外单文件保持单文件行为 | 已定义（决议落档 issue-tdd-module-blockers-2026-08-28；宿主实现待做） | Provisional | v0.49.0 | G41 / pini-project-spec §7（清单 schema）/ issue-tdd-module-blockers-2026-08-28 |
| G50 | 关键字更名 `Self` → `own`（类型内自指 + 扩展块方法修饰符 `|own`，与 `|self` 配对）。理由：G4 命名体系全小写 snake_case 唯一小写例外归一；语言未引入所有权模型，`own` 无歧义可用。破坏性更名（Provisional 期内，趁自举早期执行） | 已定义且已实现（宿主随动完成 2026-08-29：`Token.Keyword.own` / Parser 四触点（isSelfMethodStart / parsePrimaryAtom / parseTypeAnnotation / parseIdentifier）/ `TypeChecker.replaceSelf` 匹配 "own"；`Self` 降级为普通标识符，与自举 L0 词法一致，`diff_tokens.sh` 默认语料 MATCH） | Provisional | v0.49.0 | G4（命名体系）/ §A.1 keyword / method-decl / modifier 产生式 / 规则 3.13、3.14 |
| G51 | spec 权威收口（用户拍板"spec 是权威事实源"）：① import/export 块形式为唯一顶级形态（Pini草稿块形式，宿主裸语句为已知偏差、收敛待办）；② 花括号函数声明产生式作废移除（过时语法，宿主已拒）；③ 花括号对象 = `[X\|object]` 的糖仅裸名；④ defer 双形态（相邻单行语句 + `:` 块形式，块形式宿主待实现）；⑤ trait-body 产生式落地（`\|self` 本身方法 / `\|own` 本型方法 / 无修饰符抽象签名）；⑥ match 守卫与标量绑定挪 §A.5 未采纳草案；⑦ KEYWORD 补 `pass`（34 个）；⑧ DELIMITER 收编 `@` 保留待用 | 已定义（spec 修订完成；宿主收敛项：裸 import/export 移除 + 块形式、defer 块形式、test 关键字对齐） | Provisional | v0.49.0 | Pini草稿 §[名称\|import]/§<特征块名>/§defer/§{对象块} / issue-spec-impl-syntax-audit-2026-08-28 |
| **G52** | **模块系统规则收口**：① **物理边界**——以 `pini.toml` 划分模块，目录树排除含 `pini.toml` 的子目录（嵌套即**词法包含**，非 Go 的切断）；`deps/` 只放 `require` 的模块（各自带清单，R1 自切）；非 Pini 依赖与宿主落 **`.pini/`**（R5/R6 点前缀不参与扫描）——原「`deps/` 为保留目录永不扫描（R1'）」**已由 R6 撤销**。② **依赖图无环**——`import` 即依赖（文件级声明，模块依赖取并集），构建时 SCC 检测，成环报错并给出环路径；DAG ⇒ 拓扑序编译，子模块为独立编译单元。③ **版本 MVS**——输入 = `[require]` 的传递闭包，结果生成到 `pini-summary.toml`（**生成物但必须提交**）。④ **跨模块访问**——须 `import`，全导入绑定模块到别名，**注入 = `别名.符号`**（非 `import.别名.符号`），别名静态消解。**清单双通道**（判据 = 目标**根**有无 `pini.toml`）：`[require]`/`[require.<tap>]`（**根有**：可 import、激活 MVS，条目由 import 生成）／`[resources]`/`[resources.<tap>]`（**根无**：不可 import、不参与 MVS、固定落 `.pini/resources/<name>/`、**只查根不查深层**），双向强制；另有 `[tap]`（从哪来，org 显式书写）／`[replace]`（强制版本 / 本地 / 换 fork，仅主模块生效）；**移除 `[dependencies]`**（职责拆分给 require + resources）。**命令** `pini mod {tidy, refresh, verify, graph}`（tidy 离线、refresh 唯一联网、verify 执行校验和、graph `--cycles` 输出环；无全局缓存、无 clean）。**校验和必备**（`manifest_sum` + `sum`，SHA-256，规范化遍历，TOFU）；`commit` 为来源定位非校验凭证，二者并存 | 已定义（决议落档 `issue-module-system-rules-2026-08-28`，**D1–D28**（R5–R8 见 `issue-pini-dir-namespace-2026-08-29`）；**宿主实现待做**） | Provisional | v0.50.0 | **G15（模块系统边界缺口，由本条收口）** / G49 / G51 / ADR-017 / `pini-project-spec` §3 §4 §7 / §2.5 访问控制 |
| **G53** | **可变数组机制（缓冲性能收口，post-bootstrap）**：解释器值模型下 `Array.append` 为 O(k) 元组拷贝（`Value` 结构体 memcpy），逐元素累积整体 O(n²)——自举 lexer 大语料实测（423KB → 99s，ADR-020 D5 bench）。拟引入：运行时数组唯一性判定（对齐 ADR-001 `shares`）+ COW 感知原地写 + `|unsafe` 跳过检查的原地写通道；特征方法内不安全行为经 `unsafe <expr>` 消耗点表达（ADR-020 D6），`|unsafe` 维持仅限自由函数。自举期官方缓冲写法 = 「数组逐元素 append + 末尾 join」（D5 惯用法） | 已定义（ADR-020 D5/D6 裁决推迟至 post-bootstrap，**须 bench 证据立项**；惯用法已落地 lexer） | Experimental | v0.50.0 | ADR-001（shares/COW）/ ADR-020 D5 D6 D7 / ADR-015（unsafe 语义） |
| **G54** | **具名枚举关联值与 match 解构（宿主迭代，对齐 Swift）**：① 具名形参声明 `case E(x: T, y: U,)` 合法（推翻规则 3.15 具名拒绝；spec A.2.2 具名四形态收口，张力 T4 关闭）；② 具名声明接受标签实参构造（按名对位），位置声明维持拒绝（E4-014）；③ match 解构支持位置绑定 / `_` 占位 / 具名绑定 `x: v`；④ **单绑定 = 第 1 个关联值**（原「绑整元组」→ 破坏性，D2）；⑤ 绑定数 ≠ 关联值数 → E4-005（原静默绑 .null）；⑥ 枚举值渲染不带关联值名（项目契约 `圆(5.0)`）。**实现先于 spec 修订**（2026-08-29 事后追认，见 ADR-023「流程越界记录」） | 已定义**且已实现**（宿主 ADR-023；**破坏性迁移**：单绑定语义，见 CHANGELOG 迁移说明） | Provisional | v0.50.0 | ADR-023 / ADR-016（规则 3.15 原裁定） / §A.2.2 associated-param 四形态 / §A.4 match-pattern / `examples/enum-named.pini` |



> **已闭环缺口索引**：正文引用的以下 G 号已随版本闭环（已定义 / 已落地 / 已采纳 / 候选），故不列入上表；对应落点：G8（trait 约束求解，Experimental，§2.4.1）、G9（ARC，见下 Optional 条）、G11（块标签 `scope 块标签:`，§2.4.1/ADR-013）、G13（注释 `;`/`#`，§A.1.4）、G14（文件 IO，§2.4.1）、**G15（模块系统边界，§2.5 残留 → 由 G52 收口）**、G17（数组/字典/集合字面量，§2.4.1）、G18/G24（泛型与运行时单态化，Experimental）、G28（match 子块 + `case _:`，§2.4.3）、G29（匿名函数，§2.4.1）、G30（nil，§2.4.1）、G31（`?T` 糖，§2.4.1）、G32（step，§2.4.1）、G34（COW 值语义，§2.4.1）、G35（`#` 文档注释，§2.4.1/§A.1.4）、G36（for-in，§2.4.1）、G37（扩展块，候选 §A.5.3）、G39（defer 语义，候选 §A.5.5）。

> **已实现但运行语义未全钉定（Experimental，语义待定）**：以下构造已由解释器实现并被示例使用；其中语法若已在 §A 定义则标注出处，**运行语义未全钉定**者均按 Experimental 对待、不承诺兼容——这是「登记缺口」而非「反录入为事实」（避免「实现即规范」）：
> - `defer`（块退出前 LIFO 清理）—— 草稿（`defer 块退出前清理:` 小节）已有 LIFO 语义意图（资源释放/清理）；示见 `examples/defer.pini`；**意图候选项 G39**（见 `docs/pini-roadmap-next.md`），若采纳拟 Experimental→Provisional。
> - 具名枚举关联值（`[E] case A(x: T)`）—— **已钉定并已实现**（2026-08-29，张力 T4 收口）：具名形参声明 / 标签实参构造（按名对位）/ match 具名绑定（`case A(x: v):`）全链路可用；位置形态并存（同一 case 声明内不可混用）；绑定数 ≠ 关联值数 → E4。宿主规则 3.15 的具名拒绝随之修订。
> - 内嵌组合（结构体内首行裸父类型名）—— 语法检测已定义（§A.4 规则 3.9 / Parser.swift:497-515，草稿（`(结构块)` 组合示例））；运行语义（字段/方法嵌入复用）按张力 T5 待钉定（示见 `examples/composition.pini`）。
> - 复合赋值（`+= -= *= /= %= &= \|= ^= <<= >>=`）—— 语法与折叠已定义（§A.2.4 assign-op / §A.4 规则 3.11）；溢出/符号运行语义未定，张力 T1·。
> - 位运算（`& ^ ~ << >>`）—— 语法与优先级已定义（§A.1.2 / §A.2.5 / §A.3 层 5）；溢出/符号运行语义未钉住。
> - 内建函数全集（28 个，ADR-020 D4 归组，宿主 `BuiltinRegistry` 为唯一事实源）—— **collection**：len；**char**：is_letter / is_ascii_digit / is_number / chars；**pointer**：load / store / addressof；**io**：readFile / writeFile / readLine；**math**：abs / min / max / sqrt / sin / cos / tan；**concurrency**：sleep / isCancel / joinAll / joinWithin；**value**：print / assert / ok / err / Error / CancelError。字符谓词签名已钉住（G45 / ADR-019：String -> Bool，chars 为 String -> Array\<String\>）；字符串 `upper`/`lower`/`contains`/`substring`/`split` 为**成员方法**（非自由函数，§A.2.5）。其中并发原语签名未钉住（Experimental），其余签名随 ADR-019/ADR-020 逐步钉定。
> - `Optional` —— 类型层糖 `?T`（G31）与 `nil`（G30）已定义（§2.4.1 / §A.2.6）；运行时释放/提升语义未定（与 G9 ARC 关联）。下标读（G48）类型推断为 `Optional<T>`，越界返回 `nil`。
> - 内建错误类型 `Error()` / `Result` / `CancelError()` —— 由 G12（Stable）纳入异步错误模型；`Error`/`CancelError` 构造与 `Result` 成员语义随 G12 已定义，细节（构造参数、字段）待钉定。
> - 下标 `a[i]`（`subscript`）—— 安全模型已定稿（G48）：负索引尾部计数、越界读返回 `nil`、切片语法 `a[i:j]`（脱糖 `a.slice(i, j)`）、`substring` 负索引尾部计数（Python 一致）。unsafe 单元素直接访问通道（P2-F）搁置至 roadmap backlog（经 trait 为集合默认派发不安全访问）。
> - `own` 关键字（类型内自指，G50 更名自 `Self`）—— 类型层出现已定义（§A.2.6 type-annotation `'self'|'own'`）；作用域运行语义未定。
> - 泛型运行时单态化特化（调用点 `T` 占位通配 + 延迟特化队列）—— `examples/generic-func.pini` 演示，调用点行为未全钉住（部分由 G18/G24 覆盖）。
>
> 其正式语义将在对应版本（预计 v0.3+）通过 RFC/ADR 落定；在此之前示例可演示，但规范不保证其行为长期稳定。

### 3.1 异步语义契约（G12，Stable）

> **状态**：已定义、已落地（v0.41.0 落地 `=>` 派发 + `await`/`wait`；T7 异步语义正式化 v0.43.0 → **Stable**）。本小节为权威异步语义定义（结构化并发不变契约），具规范事实源地位。
>
> **术语（ADR-012，v0.41.0）**：异步 join 运算符为 `await`/`wait` **关键字前缀**（取代立场 B 的 `<=` 前缀）——`await` 用于异步函数体（`=>` 派发）内挂起等待，`wait` 用于同步上下文阻塞 join；二者均映射 `.join` AST 节点（`Parser.swift:2237-2246`）。`<=` 已回归**纯比较运算符**（中缀），无前缀 join 义（见 §A.4 规则 3.1）。
>
> **证据**：`SuspendEvaluator.swift`（`evalK` CPS 求值 / `.join` 挂起分支 / 上下文五项还原）、`SuspendScheduler.swift`（挂起后端 work-stealing 池）、`Scheduler.swift`（`GCDScheduler` 默认阻塞后端）、`Interpreter.swift`（`joinFuture` / `joinWithin` / 并发原语 `cancel`/`isCancel`/`join`/`joinAll`）、`Value.swift`（`FutureValue` 取消树 / `closeScope`）。

#### 3.1.1 `=>` 派发与 `await`/`wait` 挂起语义

- **`=>` 派发**：函数签名以 `=>` 引入的函数体即异步函数（`Parser.parseFuncDecl` 识别 `doubleArrow`，产出 `Expression.funcLiteral`，`Parser.swift:945/965`）。
- **`await`/`wait` 求值**：`await expr`（异步函数体内）/ `wait expr`（同步上下文）求值 `expr` 得 `Future`，经 `Result<T, Error>` 解构——**错误即数据，不抛出**（与 §2.4.4 errors-as-data 一致）。
- **挂起模式**（`suspendMode`，`SuspendScheduler` 后端）：`Future` 未决时当前任务**挂起**——保存续体（精确恢复点）、释放当前 OS 线程（非阻塞），`Future` 决后经 executor 从精确恢复点续跑；CPS 求值器支持任意表达式深度挂起、已执行副作用**不重跑**（如 `print(await f())` 恰打印一次）。`Future` 已决则直接取 `ok/err` 值，不挂起（`SuspendEvaluator.swift:358-384` `evalK` 的 `.join` 分支；挂起判定 `suspendMode && !fut.isFinished` 于 `:374`）。
- **同步/阻塞路径**（默认后端 `GCDScheduler`，`Interpreter.swift:25` `scheduler = GCDScheduler.shared`）：`wait` 为阻塞 join（占 worker 线程），语义与挂起等价——均经 `await`/`wait` 站点解构 `ok/err`。挂起模式是**新增能力**，默认行为不变（`Interpreter.swift:1377-1382`）。
- **`joinWithin(t, ms)`**：带超时**阻塞** join，超时归约为 `err(CancelError)`，不受挂起模式影响（探针边界，见 §3.1.4）；手动取消与超时在调用方同构（`isCancel(e)` 均为 true）（`Interpreter.swift:664-676`，B2-5）。

#### 3.1.2 结构化并发不变契约

- **B2-1 取消树（父子结构）**：每个 `Future` 是取消树节点；spawn 时父**强持有**子（`children: [FutureValue]`）、子**弱引用**父（`weak var parent: FutureValue?`，`Value.swift:30-31`）——无保留环。父被取消时递归取消全部子；父已取消后新登记的子立即取消（不漏网）。取消树即派发树，与调用方是否保留子句柄无关。
- **B2-2 父返回自动取消**：任务体结束（正常返回 / 抛错 / 被取消）时，`cancelUnjoinedChildren` 取消所有**未 join 且未完成**的子任务（`Value.swift` `cancelUnjoinedChildren`），保证子生命周期不超出父、零泄漏；已 join 的子经 `detachFromParent()` 脱离父约束（兼剪枝，避免 `children` 无界增长）。
- **joinAll 聚合（fail-fast）**：多 `Future` 聚合为单个 `Future`；任一成员 `err` 立即以该 `err` 返回并取消其余未完成任务；成员 `cancel` 经 `onCancel` 联动取消（父子链不被篡改）。
- **失败传播（甲，严格结构化）+ `detach` 出口**：函数体 `return` 即 scope 的**显式 join 边界**——一个从未被 `await`/`wait` join、也未被 `detach`、却 resolve 为 `err` 的子任务，其失败在该边界上浮：`closeScope` 收集 leaked 失败（`Value.swift:106`），若局部结果本为 `ok(v)` 则翻为 `err(aggregate)`（**唯一有界 override**，正当性来自「失败不得泄漏」；错误始终是值、可被 `await`/`wait` 解构与 `match`，非异常注入）。已 `await`/`wait` join 的错误在 join 站点已被 `ok/err` 解构，不再计入父失败。「未 join 被取消」属预期（不记失败），「未 join 失败」才须上浮，二者不可混淆。**`detach <expr>`** 为语句形式（任务 #13 升格：§A.2.4 `detach-expr-stmt`，Spine 级内建语义不变）：将子任务从父 scope 剪枝、**主动退出所有权**（结局不再归父所有，既不触发上浮、也不被 B2-2 取消）——fire-and-forget 的唯一合法出口，使（甲）可逆（`Parser.parseStatement` 分派，`Interpreter`/`SuspendEvaluator` 执行剪枝，`Value.swift:69` `detachFromParent`）。

#### 3.1.3 协作式取消与上下文还原

- **协作式取消**：取消不强杀线程，于下一个挂起 / resume 边界生效——挂起模式在 **resume 边界统一检查点**（任务被取消经 `onCancel` 即时唤醒、resume 入口 `checkCancellation` 见 cancelled 即抛 `CancelError` 终结；即使挂起等待的 `Future` 永不 resolve / 已 `detach`，取消也即时生效，`SuspendEvaluator.swift:227` `onCancel` / `:262` `checkCancellation`）；同步/阻塞路径检查点位于循环头 / 函数入口 / 睡眠分片。**非挂起即不可中断**（同 Swift）：紧循环不挂起则循环中不可被打断，循环头/回边检查仍保留。`CancelError` 经 `Result` 显式传播，不穿透 `try`/`except`（与 §2.4.4 一致）。
- **挂起模式上下文还原（MUST）**：挂起/恢复跨线程（work-stealing 复用 OS 线程）时，continuation 必须捕获并还原解释器线程上下文 `{currentEnv, currentFuture, deferStack, debugDepth, callStackNames}`，否则上下文串台（类比 Swift `Executor` 上下文 / Kotlin `CoroutineContext`）。已落地（`SuspendTaskCPS`，`SuspendEvaluator.swift:164`；保存-还原于 `:237-258`）。

#### 3.1.4 探针边界（显式报错，不静默错）

- 挂起模式暂不支持泛型构造实参内的 `await` 及 `callFunctionValue` 特殊形态（枚举构造 / `Optional` / `WeakRef`）在含 `await` 实参下的逐形复制；此类路径报「挂起模式暂不支持」（`.genericConstruct` 边界 / `resultUnwrap`（`^`）含 `await` 实参探针，`containsJoin` 判定于 `SuspendEvaluator.swift`）。
- `joinWithin` 保持阻塞语义（见 §3.1.1）。完整 CPS 化覆盖 `match` / `try` / `for` / labeled 实参 / `break` / `continue` 内挂起（已支持，并经同步/CPS 差分测试逐字节对齐）。

#### 3.1.5 稳定性与已知限制

- **G12 → Stable**（v0.43.0，T7 正式化）：异步语义模型（派发 / join / 结构化并发 / 协作式取消）正式钉定。
- **仍 Experimental（登记于 §3，函数签名未钉住）**：并发原语 `cancel` / `isCancel` / `join` / `joinAll` / `joinWithin` 的**函数签名**；内建错误类型 `Error()` / `CancelError()` / `Result` 的构造参数与字段细节。模型已由 G12（Stable）定义，但签名/构造细节待后续版本钉定。

### 3.2 运行时 shim 边界与长期愿景（C ABI）

**现状（阶段 1 已落地，维持）**：集合 / COW / LazyRef（G40）运行时采用 Swift 实现的 shim 库 `libPiniRuntime`（`.dynamic` target，`lli --dlopen` / `clang -L/-l` 加载），emitted IR 经 `call @bk_*` 调用。内部以**不透明句柄**（IR `ptr`）承载，类型检查 / 推断层只见 opaque handle，不暴露 Swift 专有类型；`IRBuilder` 对集合与 LazyRef 一律建模为 opaque C-ABI handle。`@bk_*` 仅接受 / 返回 C 兼容类型（`void*`/`i8*` 句柄、`i64`/`i32` 标量、长度）。已实装的 C-ABI 面：`bk_array_*` / `bk_dict_*` / `bk_set_*`（G34 COW）+ `bk_lazyref_*`（G40 S3，统一 `(ptr,ptr,ptr)->ptr` wrapper ABI）+ `bk_panic`（G41 assert）+ `bk_handle_*`（share 管理）。

**硬性约束（MUST，现即生效）**：shim 与用户代码的边界必须是 **C ABI**，不是 Swift 泛型 ABI——违反即锁死自举终态，使 Swift 成为永久依赖。已实证可守住不泄漏 Swift 类型（越界即错误、空数组、双后端逐字节一致等回归门禁锁进 `RuntimeBackendTests`）。

**统一 shim 边界**：集合（G34）、并发（§3.1 挂起后端需要的 `NSLock`/`NSCondition`/GCD 替换）与 LazyRef（G40）**共用单一 `libPiniRuntime` C-ABI 面**，不另设独立 shim；C-ABI 纪律只在 §3.2 一处施加。FFI 的 foreign C 调用（Phase 2b）同样经此单一 C-ABI 边界（复用 `@bk_*` 面或同构的 `dlopen`/`dlsym` 边界），**不引入第二个 ABI 面**——守住「不泄漏 Swift 类型」（§2.7 三阶段模型）。

**长期愿景（Deferred，按需触发，不排期）**：
- **阶段 2（C-ABI 版本化固化）**：触发条件 = 出现真实第二后端（pthread/Windows）或并发跨平台需求。届时 shim 边界固定为 C ABI 并版本化：`libPiniRuntime` 暴露 semver API 版本号；emitted 模块头写入所依赖的 rt 版本；`@bk_*` ABI **append-only**（只新增、不改签、不删）。当前**不提前固化**——过早版本化是永久性 ABI 税，无近期回报。
- **阶段 3（自举纯 libc，北极星）**：Pini 成熟后以自身重写同一组 C ABI 函数替换 Swift shim；用户程序从「依赖 libPiniRuntime + Swift runtime」变为「只依赖 libPiniRuntime」；若 `@bk_*` 后续内联 / 直接生成 IR，可做到**纯 libc**。不设定时间表。

**自举前置检查（阶段 3 的指导清单，2026-08-24 建立）**：
1. **shim 边界 C ABI 不泄漏**——已守住（MUST + `RuntimeBackendTests` 门禁）。
2. **语言自宿主能力**：Pini 需能表达「重写 `@bk_*`」所需的程序结构（内存布局、互操作、错误收口）——当前 `ok`/`err`、`match`、泛型、`LazyRef`、`|test` 已提供核心构件。
3. **FFI / 内存管理（T14，最大前置缺口）**：自举需要调用 libc（`malloc`/`free`/`memcpy` 等）并操作不透明指针——**T14 FFI 尚未实现**，是阶段 3 启动前必须补的关键能力；在此之前 shim 保持 Swift 实现。
4. **目标清单**：待用 Pini 重写的 C-ABI 函数集 = `bk_handle_*` + `bk_array_*` + `bk_dict_*` + `bk_set_*` + `bk_lazyref_*`（逐一对照 `PiniRuntime.swift` 的 `@_cdecl` 面）。

**回滚**：若阶段 1 实测内部不变量无法守住，可回退到「纯 LLVM 手写 IR」——因阶段 2 边界尚未固化，回退成本可控。

---

## 4. 破坏性变更管理（Breaking-Change Policy）

- **允许**：v0.x 内对任意 **Provisional / Experimental** 级构造的破坏性变更，只要走 §1.3 并附迁移说明。
- **限制**：
  - **Stable** 级在 v0.x 内不应破坏；确需破坏时须进入 v1.0 路径（deprecation 周期）。
  - **禁止静默破坏**：任何破坏性 minor 必须有迁移说明；代码改动须同步规范与示例。
- **迁移支持**：每次破坏性 minor 提供迁移指南；如影响面广，提供 codemod / `pini migrate` 辅助。
- **沟通**：在 README「已知限制 / 变更日志」与本项目文档中同步公告，确保利益相关者（实现者、示例维护者、早期用户）可见。

---

## 5. 与既有文档的关系

- **输入**：`Pini草稿.md`（rationale）；早期 `pini-gap-analysis.md` / `pini-tensions.md` 已合并入本规范 §3 与路线图。
- **下游**：`pini-roadmap-next.md` 以本规范为交付物。
- **形式文法产物**：T5 的 EBNF（S2–S4）与候选产生式（S5）已并入本规范 **§A 附录**，为形式文法的唯一载体（原草案与事实基线文档已删除）。G1/G2/G3 已随 §A / §2.4.4 闭环（见 §3）。
- **工程标准（测试）**：`docs/test-refactoring-principles.md` 为项目**强制测试规范**，受本规范 §6 治理（细则见该文档）。
- **工程标准（注释）**：`docs/pini-comment-style-guide.md` 为项目**强制注释规范**，受本规范 §7 治理（细则见该文档）。与测试规范协和：测试规范要求「写意图」，注释规范约束「意图之外不叙事、不引易变外部」。
- **诊断码派生视图**：`docs/diagnostic-codes.md` 为 `Sources/PiniCore/Resources/Diagnostics.{en,zh}.toml` 的人类可读**派生视图**（迟维护，低权威；权威映射见 §2.6，不一致以 TOML 为准）。

---

## 6. 测试规范（Testing Standards）

> 本节将 `docs/test-refactoring-principles.md` 确立为项目**强制工程标准**，受本规范治理（与语言语义同源、同变更流程 §1.3）。测试是 v0.x 演进的 safety net——任何 Provisional/Experimental 构造的落地都必须伴随可回归测试（呼应 §1.1 演进策略）。完整细则（模板、示例代码、checklist）见该文档；本节给出权威摘要。

### 6.1 三要素（每条测试必备）
- **意图用例（Intent Case）**：测试名 `test[模块][行为]`，一眼可见验证目的；方法首行注释写明意图。
- **推进性测量（Advancing Measures）**：断言「期望行为发生」（`XCTAssertEqual`/`XCTAssertTrue`/`XCTAssertNotNil` 等），对期望值具体明确。
- **驳回性测量（Dismissing Measures）**：断言「非期望行为不发生」（`XCTAssertNotEqual`/`XCTAssertThrowsError`/`XCTFail` 拦截错误路径），覆盖边界与错误处理。

### 6.2 组织：按模块 + 按行为
- 每个主模块独立测试类：`ASTTests` / `LexerTests` / `IndentTrackerTests` / `ParserTests` / `EnvironmentTests` / `ErrorTests` / `InterpreterTests`（见 `PiniTests.swift`）；新增模块须同步新增测试类。
- 模块内按行为分类（token 类型 / 特殊情形 / 错误情形）。

### 6.3 覆盖策略
- **每模块至少一测试**，无模块裸奔。
- **成功 / 边界 / 错误三路径**全覆盖；**测外部行为而非实现细节**（不窥探内部类结构）。
- 跨模块集成测试（lexer→parser→interpreter 全链路）用于关键特性。

### 6.4 隔离与复用
- 每测试独立自建 fixture、不依赖共享状态、自清理。
- 公共装配抽 `private func runProgram(_:)` 之类 helper（仓库已广泛采用）。

### 6.5 错误与回归
- 显式校验错误**类型与载荷**（`XCTAssertThrowsError` + 模式匹配）。
- **每个 bug 修复必配测试**：先红（复现）→ 修复 → 绿（通过），防回潮。

### 6.6 验收清单（测试 DoD）
- [ ] 每模块至少一测试类
- [ ] 每条测试含意图 / 推进 / 驳回三要素
- [ ] 按模块 + 行为组织
- [ ] 错误路径随成功路径同测
- [ ] 测试独立隔离
- [ ] 全绿、无回归

---

## 7. 注释规范（Comment Standards）

> 本节将 `docs/pini-comment-style-guide.md` 确立为项目**强制工程标准**，受本规范治理（与语言语义同源、同变更流程 §1.3）。定位：把 §0「跨文件章节缩减」与 §1.4「行号=软证据、符号名+语义为权威」两条既有治理原则，操作化为代码注释的日常写法——不新增立场，只落地既有原则。完整细则（分级、正反样例、lint 正则、迁移批次）见该文档；本节给出权威摘要。

### 7.1 寿命不对称（本规范为何要管注释）
代码注释是**持久、慢维护**空间（改代码常忘改注释）；spec 段落 / ADR / issue / CHANGELOG / 行号是**半持久、快演进**空间。注释里指向快变外部的耦合必然腐化。故：**原因与来源进受版本治理的外部文档，注释只留自包含陈述 + 符号型稳定 ID**。

### 7.2 注释准许内容
- **自包含的行为 / 不变量**：用代码自身词汇（符号名、类型、前置/后置条件）陈述非显然行为；读注释不需跳转外部。
- **符号型稳定 ID**（单行，最多一句）：`ADR-0NN` / `G##` / `E#-###` / `issue-YYYY-MM-DD`。这类 ID 是**语义键**，不随文件编辑漂移，符合 §1.4 权威判定键。
- **测试意图注释**：§6.1 强制要求，保留且鼓励。

### 7.3 注释禁止内容（与既有治理原则同源）
| 禁止项 | 依据 | 替代写法 |
|---|---|---|
| **行号**（`X.swift:123`） | §1.4 行号=软证据，编辑即漂移 | 用符号名定位 |
| **跨文件章节号**（`spec §2.7`、`roadmap §3`） | §0 跨文件章节缩减（见到即缩减） | 缩减为符号型 ID（`ADR-015` / `G43`）或粗粒度主题词（「见 spec FFI 与 unsafe 主题」） |
| **文件路径 / 文档名快照** | 文件可重命名或删除，注释里必成死链 | 只留符号型 ID |
| **版本号叙事**（「v0.48.0 起改为…」「逆转 ADR-013」） | §1.3 变更事实归 CHANGELOG 归档 | 注释只述现况 + 留当前有效 ADR ID |
| **摘抄 spec 段落** | spec 为单一事实源，复制即双份维护 | 留 ID，不复制 |
| **裸 `TODO` / `FIXME`** | 无追踪 ID 即无治理 | 必带 `issue-` / `ADR-` ID |

### 7.4 ID 可兑付性（ADR 登记为前置条件）
注释中的 `ADR-0NN` 必须能在受版本治理的文档中被兑付（查到标题、决策、落地版本）。**ADR 登记表是本节的前置设施**：无登记表时，注释里的 ADR ID 属悬空指针，视为规范缺口（登记于 §3 待补项，随注释规范落地批次一并闭合）。

### 7.5 验收清单（注释 DoD）
- [ ] 无注释含行号引用
- [ ] 无注释含跨文件章节号或文档名快照
- [ ] 无版本号叙事（变更事实在 CHANGELOG）
- [ ] `TODO`/`FIXME` 均带稳定追踪 ID
- [ ] 引用的 ADR / G / E 码均可在受治理文档中兑付
- [ ] 测试意图注释齐备（呼应 §6.6）

## A. 形式文法（EBNF 附录）

> **定位**：T5「形式文法 + 运算符优先级」的权威交付物（S2–S5 并入）。本附录是 Pini 语言的**完整形式文法 EBNF**（词法 + 语法 + 运算符优先级/结合性 + 记号消歧），是形式文法的**唯一载体**（原草案 `grammar-ebnf-draft.md` 与事实基线 `grammar-facts.md` 已并入本附录后删除，见 CHANGELOG v0.46.0）。

---
```ebnf
(* ======================================================================== *)
(*  Pini 语言完整形式文法 EBNF                                          *)
(*  词法 + 语法 + 运算符优先级/结合性 + 记号消歧                              *)
(* ======================================================================== *)

(* ======================================================================== *)
(*  A.0  符号约定与全文档通用规则                                           *)
(* ======================================================================== *)

(*
  记号约定：
    ::=          定义
    |            备选
    [ ... ]      可选（0 或 1 次）
    { ... }      重复（0 或多次）
    ( ... )      分组
    'x'          终结符字面量
    IDENT INT    词法类
    (* ... *)    注释
    <snake_case> 非终结符

  ⚠️ 语言自身用 ( ) [ ] { } < > | 作为定界符/运算符，
     故 EBNF 中所有语言符号一律加引号，与 EBNF 元符号严格区分。

  行首语义：
    '(' '[' '{' '<' 在行首位置（NEWLINE 之后）触发顶级声明分派。
    同一 token 在表达式/类型位置有不同语义。
    顶级声明顶格；函数体（含顶级函数）必须缩进 ≥1 层（任务 #13 采纳草稿意图），
    顶级声明归属由「声明交替规则」决定。
*)

(* ======================================================================== *)
(*  A.1  词法文法                                                            *)
(* ======================================================================== *)

(* ---- A.1.1  词法类 ----------------------------------------------------- *)

IDENT        ::= ID_START ID_CONTINUE*;
ID_START     ::= [\p{L}_];
ID_CONTINUE  ::= ID_START | NUMERIC;
NUMERIC      ::= (* Unicode numeric property 字符（Numeric_Type ≠ None），即
                  宿主 Character.isNumber 语义；严格超集 \p{N}——含 三/万 等
                  Lo 类带数值汉字。随 ADR-019 D3 放宽；实现原语 = 内建谓词
                  is_letter（\p{L}）/ is_number（numeric property）/
                  is_ascii_digit（[0-9]，仅数字字面量用，见 INT） *)
(* 首字符：Unicode 字母或下划线；后续：Unicode 字母/数字属性字符/下划线
   '_' 开头的 _名称 走专用访问控制路径 *)

(* 宽松词法（ADR-021）：未被上述词法类匹配的字符产出单字符 IDENT token
   （文本 = 该字符）；词法器对任何输入不报错——非法性诊断由解析/语义阶段
   给出（如 `$` 落在表达式位 → 未定义变量/意外 token）。字符串未闭合在行尾
   隐式终止；非法转义原样保留进内容；畸形进制/指数回退为 int + 标识符。
   中英文键盘可产生字符全集按此覆盖；全角符号暂走同一兜底（专用处理搁置）。 *)

KEYWORD      ::= 'var' | 'let' | 'func' | 'enum' | 'object'
               | 'if' | 'elif' | 'else' | 'match' | 'case'
               | 'while' | 'step' | 'for' | 'in'
               | 'try' | 'except' | 'return' | 'break' | 'continue'
               | 'self' | 'own' | 'defer' | 'import' | 'export'
               | 'nil' | 'capture' | 'await' | 'wait'
               | 'unsafe' | 'test' | 'foreign' | 'detach'
               | 'scope' | 'pass';
(* 共 34 个。scope 保留但不再使用；test 为测试函数块修饰符关键字（宿主暂以标识符修饰符路径实现，待对齐）；pass 为空语句关键字 *)

INT          ::= [0-9]+ | '0x' [0-9a-fA-F]+ | '0b' [01]+ | '0o' [0-7]+;
FLOAT        ::= [0-9]+ '.' [0-9]+ [EXP]? | [0-9]+ EXP;
              (* 小数点后必须跟数字 *)

EXP          ::= ('e'|'E') ['+'|'-'] [0-9]+;

STRING       ::= '"' { STRING_CHAR | ESCAPE } '"';
STRING_CHAR  ::= (* 除 '"' 与换行外的任意字符 *);
ESCAPE       ::= '\' ('n'|'t'|'r'|'0'|'\\'|'"'|'(');

INTERP       ::= '"' { STRING_CHAR | ESCAPE | '\(' INTERP_EXPR ')' } '"';
INTERP_EXPR  ::= (* 平衡括号表达式源码；可含嵌套 ()[]{} 与字符串；
                    不支持嵌套 '\\(' *);

BOOL         ::= 'true' | 'false';

(* ---- A.1.2  运算符 token ------------------------------------------------ *)

OPERATOR ::= '+' | '-' | '*' | '/' | '%'                    (* 算术 *)
           | '++' | '--'                                    (* 自增自减 *)
           | '&&' | '||' | '!'                              (* 逻辑 *)
           | '==' | '!=' | '<=' | '>=' | '<' | '>'         (* 比较 *)
           | '&' | '|' | '^' | '~' | '<<' | '>>'          (* 位 *)
           | '='                                            (* 赋值 *)
           | '+=' | '-=' | '*=' | '/=' | '%='              (* 复合赋值 *)
           | '&=' | '|=' | '^=' | '<<=' | '>>=';

(* ⚠️ 多重角色：
   - '|' : 按位或（表达式） / 声明修饰分隔符（行首/声明）
   - '&' : 按位与（表达式） / 取地址前缀（unsafe）
   - '^' : 按位异或（表达式） / 结果类型糖（类型） / 右值解包前缀（表达式）
*)

(* ---- A.1.3  分隔符与布局 token ------------------------------------------ *)

DELIMITER ::= '(' | ')' | '[' | ']' | '{' | '}' | ':' | ',' | '->' | '=>' | '.' 
            | '|' | '?' | '*' | '@';

NEWLINE   ::= (* 行尾换行，每行行尾产出 1 个 NEWLINE *);
INDENT    ::= (* 行首缩进大于栈顶 → push + INDENT *);
DEDENT    ::= (* 行首缩进小于栈顶 → 逐层 pop + DEDENT *);
EOF       ::= (* 文件结束 *);

(* '#' 被注释拦截；'@' 保留待用（G51，宿主 lexer 已产出 at token）
   '?' 可选类型前缀；'*' 指针类型前缀 *)

(* ---- A.1.4  注释 -------------------------------------------------------- *)

COMMENT ::= ';' { (* 除换行外任意字符 *) }                    (* 行注释 *)
          | '#' { (* 除换行外任意字符 *) };                   (* 文档注释/退化行注释 *)

(* ======================================================================== *)
(*  A.2  语法文法                                                            *)
(* ======================================================================== *)

(* ---- A.2.1  模块与顶级结构 ---------------------------------------------- *)

module          ::= { NEWLINE } { top-level-decl NEWLINE } EOF;

top-level-decl  ::= import-decl | export-decl
                  | struct-decl | object-decl | object-decl-sugar | enum-decl | bare-func-decl
                  | trait-decl | extension-decl | foreign-decl;

import-decl     ::= '[' 'import' '|' 'import' ']' NEWLINE { import-item };
import-item     ::= IDENT '=' STRING;
(* import/export 块形式是唯一顶级形态（G51，Pini草稿 §[名称|import]/§[类型名称|export]）；
   顶级裸 `import X`/`export X` 语句不属于本语言——宿主现行裸语句实现为已知偏差，收敛待办；
   import 绑定包路径，`_` 前缀别名 = 注入的隐式包调用别名；export 为可见性别名导出表（与 `_` 访问控制联动） *)

export-decl     ::= '[' 'export' '|' 'export' ']' NEWLINE { export-item };
export-item     ::= IDENT '=' IDENT                      (* 符号重命名 *)
                  | IDENT ':' type-annotation;           (* 类型别名声明 *)
(* 类型别名禁止递归，暂不支持泛型 *)

(* ---- A.2.2  类型声明（数据与逻辑分离） ------------------------------------ *)

(* 行首 '(' → 结构块（值类型） *)
struct-decl     ::= '(' IDENT ['<' generic-params '>'] ')' NEWLINE struct-body;

(* 行首 '[' → 对象/枚举块：无修饰符默认枚举 *)
object-decl     ::= '[' IDENT ['<' generic-params '>'] ['|' 'object'] ']' type-body;
enum-decl       ::= '[' IDENT ['<' generic-params '>'] ['|' 'enum'] ']' enum-body;

(* 行首 '{' → 函数块或对象块 *)
object-decl-sugar ::= '{' IDENT '}' type-body;                     (* [X|object] 的糖，仅裸名；Pini草稿 §{对象块} *)

(* 行首 '<' → 特征块 *)
trait-decl      ::= '<' IDENT '>' trait-body;

trait-body      ::= { trait-method };
trait-method    ::= IDENT ['|' ('self' | 'own')] func-signature [func-body];
(* 无修饰符签名 = 抽象方法（须被实现）；'|self' = 本身方法（实例方法，允许捕获 self 及其成员）；
   '|own' = 本型方法（类型级方法，own 指代实现特征的被扩展类型，禁止捕获外部对象）；
   有体 = 默认实现（<<扩展特征块>>，G51/Pini草稿 §<特征块名>） *)

(* 扩展块 *)
extension-decl  ::= '((' IDENT [':' type-annotation] '))' method-body   (* 结构扩展 *)
                  | '{{' IDENT [':' type-annotation] '}}' method-body   (* 对象扩展 *)
                  | '[[' IDENT [':' type-annotation] ']]' method-body   (* 枚举扩展 *)
                  | '<<' IDENT '>>' trait-body;                         (* 特征扩展 *)

(* 外部函数块 *)
foreign-decl    ::= '[' IDENT '|' 'foreign' ']' foreign-body;

(* 数据与逻辑分离：
   - 类型体内仅字段（数据）
   - 方法必须写在扩展块中（逻辑）
   - 同文件扩展块可访问私有字段；跨文件不可
   - 扩展块内无自由函数 *)

struct-body     ::= [composition-line] { field-decl };
type-body       ::= { field-decl };                    (* 对象体仅字段 *)
enum-body       ::= { enum-case };
method-body     ::= { method-decl };                   (* 扩展块仅方法 *)
foreign-body    ::= { foreign-signature };

composition-line ::= IDENT;                            (* 结构体组合：体首行裸父类型名 *)

field-decl      ::= IDENT ':' type-annotation ['=' expression];

enum-case       ::= IDENT ['(' type-annotation {',' type-annotation} [','] ')'];
(* Swift 风格：位置关联参数，不具名，位置绝对对应，无默认值 *)

method-decl     ::= IDENT ['|' 'self' | '|' 'own'] func-signature [func-body];

foreign-signature ::= IDENT func-signature;
(* foreign 块内函数自动标记为 |unsafe *)

(* ---- A.2.3  函数声明 ------------------------------------------------------ *)

func-signature  ::= ['<' generic-params '>'] '(' [param {',' param}] ')'
                    [('->' | '=>') '(' [ret-item {',' ret-item}] ')']
                    [func-body];

param           ::= IDENT [':' type-annotation]
                  | IDENT '=' expression;              (* 默认参数 *)

ret-item        ::= [IDENT ':'] type-annotation;

modifier        ::= 'func' | 'self' | 'own' | 'test' | 'unsafe' | 'foreign';

bare-func-decl  ::= IDENT ['|' modifier] ['<' generic-params '>'] func-signature;

func-literal    ::= 'func' '(' [param {',' param}] ')'
                    [('->' | '=>') '(' [ret-item {',' ret-item}] ')'] ':' func-body;
(* 匿名函数必须使用 func 关键字 *)

func-body       ::= INDENT { statement } DEDENT;
(* 草稿意图（函数体必须按层次缩进且至少缩进一层）已采纳（任务 #13）：函数体强制缩进，
   不再允许顶级内容态顶格累积语句。空体 = `INDENT DEDENT`。 *)

(* ---- A.2.4  语句 ---------------------------------------------------------- *)

statement       ::= var-decl | assign-stmt | return-stmt | break-stmt | continue-stmt
                  | if-stmt | while-stmt | for-stmt | match-stmt | try-stmt
                  | defer-stmt | pass-stmt | expression-stmt
                  | detach-expr-stmt;

var-decl        ::= ('var' | 'let') IDENT [':' type-annotation] ['=' expression];

assign-stmt     ::= assign-target assign-op expression;
assign-target   ::= IDENT | postfix-expression '.' IDENT | postfix-expression '[' expression ']';
assign-op       ::= '=' | '+=' | '-=' | '*=' | '/=' | '%=' | '&=' | '|=' | '^=' | '<<=' | '>>=';

return-stmt     ::= 'return' [expression];
break-stmt      ::= 'break' [IDENT];                   (* 不携带值 *)
continue-stmt   ::= 'continue' [IDENT];                (* 仅循环标签有效 *)

(* 标签语法：标签|控制流关键字 *)
if-stmt         ::= [IDENT '|'] 'if' expression control-block
                    { 'elif' expression control-block }
                    [ 'else' control-block ];

while-stmt      ::= [IDENT '|'] 'while' expression control-block ['step' control-block];
for-stmt        ::= [IDENT '|'] 'for' '(' pattern-tuple ')' 'in' expression control-block
                    ['step' control-block];

pattern-tuple   ::= (IDENT | '_') { ',' (IDENT | '_') } [ ',' ];

match-stmt      ::= 'match' expression ':' { match-case };
match-case      ::= 'case' match-pattern control-block;
match-pattern   ::= '_' | INT | FLOAT | STRING | BOOL | IDENT | 'nil'
                  | IDENT '.' IDENT ['(' match-pattern {',' match-pattern} [','] ')'];
(* 枚举解构按位置绑定；'_' 占位忽略；支持 if 守卫 *)


try-stmt        ::= 'try' expression control-block { 'except' IDENT control-block };
defer-stmt      ::= 'defer' (assign-stmt | expression-stmt)   (* 相邻单行形式，宿主现行 *)
                | 'defer' control-block;                      (* 块形式（草稿 §defer），宿主待实现 *)
pass-stmt       ::= 'pass';
expression-stmt ::= expression;
detach-expr-stmt ::= 'detach' expression;

control-block   ::= ':' (expression | INDENT { statement } DEDENT);

(* scope 语句已撤销；scope 关键字保留但不再使用 *)

(* ---- A.2.5  表达式 -------------------------------------------------------- *)

expression      ::= or-expr;

or-expr         ::= and-expr { '||' and-expr };
and-expr        ::= equality-expr { '&&' equality-expr };
equality-expr   ::= comparison-expr { ('==' | '!=') comparison-expr };
comparison-expr ::= bitwise-expr { ('<' | '>' | '<=' | '>=') bitwise-expr };
bitwise-expr    ::= term { ('&' | '|' | '^' | '<<' | '>>') term };
                (* 位运算同级左结合 *)
term            ::= factor { ('+' | '-') factor };
factor          ::= unary-expr { ('*' | '/' | '%') unary-expr };

unary-expr      ::= ('await' | 'wait' | '^' | '!' | '++' | '--' | '~' | '+' | '-' | '&' | 'unsafe') unary-expr
                  | primary-expr;
(* await/wait: join 挂起等待
   ^: 右值解包前缀
   &: 不安全取地址
   unsafe: 不安全消耗点 *)

primary-expr    ::= primary-atom postfix-suffix*;

postfix-suffix  ::= '(' [call-arg {',' call-arg}] ')'
                  | '.' IDENT
                  | '[' subscript ']';

subscript       ::= index | slice;
index           ::= expression;
slice           ::= [expression] ':' [expression];
(* 下标 / 切片语法（G48 安全模型，Phase 2 引入）：
   - 单元素下标  a[i]   : index := expression；i 可为前缀负号表达式（负索引 → 尾部计数，-len..-1）。
   - 切片        a[i:j] : 半开区间 [i, j)；两侧 expression 均可省略表示开放边界
                  （i 省略 ≡ 0 起，j 省略 ≡ 长度止），故 a[i:] / a[:j] / a[:] 均合法（步长 k 暂缓）。
   - 边界的负号是普通前缀表达式（§A.3 层级 8），非 slice 语法特殊符号。
   - 实现脱糖：a[i:j] / a[i:] / a[:j] / a[:] 统一脱糖为成员调用 a.slice(start, end)，
     开放边界以 nil（Optional.none）传递；运行时与集合 .slice 行为一致
     （见 G48 / SubscriptStrategies.swift / issue-lexer-gaps-2026-08-28 P2-B）。 *)

call-arg        ::= [IDENT ':'] expression;

primary-atom    ::= IDENT [generic-construct]
                  | 'self' | 'own'
                  | func-literal
                  | INT | FLOAT | STRING | INTERP | BOOL
                  | 'nil'
                  | '(' [expression {',' expression}] ')'
                  | '[' collection-literal ']'
                  | '{' [expression {',' expression}] '}'
                  | builtin-call;

generic-construct ::= '<' type-annotation {',' type-annotation} '>'
                      ('(' [call-arg {',' call-arg}] ')' | '.');

collection-literal ::= ']'
                     | expression ':' expression {',' expression ':' expression} ']'
                     | expression {',' expression} ']';

builtin-call    ::= 'LazyRef' ['<' type-annotation '>'] '(' func-literal ')'
                  | 'assert' '(' expression [',' STRING] ')';
(* LazyRef<T>(初始化闭包) / LazyRef(闭包)
   assert(条件) / assert(条件, 消息) *)

(* capture 在匿名函数体内部：capture 标识符，多行列出，不支持捕获表达式 *)

(* ---- A.2.6  类型注解 -------------------------------------------------------- *)

type-annotation ::= '?' type-annotation                          (* ?T ≡ Optional<T> *)
                  | '^' type-annotation                          (* ^T ≡ Result<T> *)
                  | '*' type-annotation                          (* *T ≡ 指针 *)
                  | '[' type-annotation ']'                      (* [T] ≡ 数组 *)
                  | '[' type-annotation ':' type-annotation ']'  (* [K: V] ≡ 字典 *)
                  | '{' type-annotation '}'                      (* {T} ≡ 集合 *)
                  | IDENT ['<' type-annotation {',' type-annotation} '>']
                  | '(' [type-annotation {',' type-annotation}] ')'
                    [('->' | '=>') '(' [type-annotation {',' type-annotation}] ')']
                  | 'self' | 'own';

generic-params  ::= IDENT ['|' type-annotation] {',' IDENT ['|' type-annotation]};
(* 泛型约束使用 '|' 分隔，与声明修饰符语法一致 *)

(* ======================================================================== *)
(*  A.3  运算符优先级/结合性总表                                              *)
(* ======================================================================== *)

(*
  层级（低→高）  运算符                                          结合性
  1             ||                                               左
  2             &&                                               左
  3             == !=                                            左
  4             < > <= >=                                        左
  5             & | ^ << >>                                      左（同级）
  6             + -                                              左
  7             * / %                                            左
  8             前缀: await wait ^ ! ++ -- ~ + - & unsafe        —
  9             后缀: () . []                                     —

  ⚠️ 位运算四则同级（& | ^ << >> 无分层），与 C 系不同。
*)
```
---
### A.4 记号消歧规则（语义约束，EBNF 补充）

EBNF 无法表达前瞻（lookahead），以下消歧规则是文法的**组成部分**，实现与未来解析器生成必须遵守：

| # | 规则 | 说明 | 出处 |
|---|------|------|------|
| 3.0 | **行首定界符分派** | `'('` `'['` `'{'` `'<'` 在**行首**（NEWLINE 后）→ 顶级类型声明分派（`struct`/`object`/`enum`/`func`/`trait`）；同一 token 在表达式/类型位置（非行首）→ 字面量/元组/泛型/优先结合。本版本**固定「行首位置」单一锚点**为消歧算法 | §2.1 / §2.2 / Parser.swift:347-384 |
| 3.1 | `await`/`wait` 前缀 join | `await`/`wait` 为关键字、仅作表达式起始位前缀 → 映射 `.join` AST（异步体挂起 / 同步阻塞，由 suspendMode 上下文决定）；`<=` 已回归**纯比较运算符**（中缀，无前缀 join 义） | Parser.swift:2237-2246 / §2.4.1 |
| 3.2 | **类型体内禁止函数声明** | 类型体内只允许字段声明。解析器在类型体中遇到函数声明头（`IDENT '('` 或 `IDENT '|' modifier`）→ 报错：方法应移至同文件扩展块中，并显式使用 `\|self` 或 `\|own` | Parser.swift（已实现，ADR-016）：parseStructDecl/parseObjectDeclContent/parseEnumDeclContent 抛 invalidStatement（`name|func` 顶级函数除外）；methodDefaultAssumption 状态机已移除 |
| 3.3 | `'<'` 泛型构造 vs 比较 | 表达式右值位置：`IDENT '<' type-annotation {',' type-annotation} '>'` 且 `>` 后跟 `'('`/`'.'` 才判定 `generic-construct`，否则回退比较；`'>>'`（rightShift）→ 回退（不支持嵌套） | Parser.swift:2380-2461 |
| 3.4 | `'{...}'` 函数 vs 对象 | 预读 `'{' IDENT ('\|mod')? '<泛型>'? '}'` 后第一个非换行 token 是 `'('` → 函数块；否则对象块。无修饰符 `'{名称}'` 默认为对象 | Parser.swift:554-593 |
| 3.5 | `'[名称\|...]'` 枚举 vs 对象 | `\|object` → 对象；`\|enum` → 枚举；**无修饰符默认枚举** | Parser.swift:427-441 |
| 3.6 | 裸函数声明判定 | `IDENT ('\|mod')? '<泛型>'? '(' 参数 ')'` 后跟 `'->'`/`'=>'` → 裸函数声明；否则语句 | Parser.swift:1139-1184 |
| 3.7 | match `'default'` 消歧 | `default` 是普通标识符；在 match 子块内出现 `default:` 被**显式报错**（提示改用 `case _:`），不再特判为默认分支 | Parser.swift:1911-1916 |
| 3.8 | 泛型构造 lookahead 失败回退 | 任一环节不满足 → 恢复 position 回退为比较运算 | Parser.swift:2380-2461 |
| 3.9 | 内嵌组合 | `'(' 类型 ')'` 后首行裸父类型名、非字段/裸函数 → 内嵌父类型 | Parser.swift:497-515 |
| 3.10 | match 子块结构 | match 子块内**只允许 `case`**；`case _:` 为通配兜底；`default:`/裸 `pass` 通配子块已移除 | Parser.swift:1894-1921 |
| 3.11 | 复合赋值折叠 | `x op= y` 语法上是 assign；语义 = `x = (x op y)`（Parser 折叠为 assign 内 binary） | Parser.swift:1652-1690 |
| 3.12 | `nil` 映射 | 表达式/匹配模式中 `nil` ≡ `Optional.none`（member / enumCase("none")） | Parser.swift:2359-2364、1945-1949 |
| 3.13 | **标签语法消歧** | 语句位置遇到 `IDENT '|'`：若 `'|'` 后是 `'if'`/`'while'`/`'for'` → 解析为带标签语句（`标签\|if` / `标签\|while` / `标签\|for`）；若 `'|'` 后是其他 token → 回退为按位或表达式。声明位置（模块顶层/扩展块内）：`IDENT '|'` 后是 `'self'`/`'own'`/`'func'`/`'test'`/`'unsafe'`/`'foreign'` → 方法/函数声明修饰符 | Parser.swift（已实现，ADR-014）：parseStatement 标签分派 + parseIf/parseWhile/parseFor(label:)；`scope` 关键字转 reserved-error（G44） |
| 3.14 | **扩展块内禁止自由函数** | 扩展块（`((...))`/`{{...}}`/`[[...]]`）内只允许带 `\|self` 或 `\|own` 的方法声明。遇到无这些修饰符的函数声明 → 报错：自由函数应移至模块顶层 | Parser.swift（已实现，ADR-016）：parseExtensionDecl（`((T))`/`{{T}}`/`[[T]]`/`<<T>>` 四种扩展，含泛型 `((盒<T>))`）校验 |
| 3.15 | **枚举关联参数仅位置类型**（**2026-08-29 修订：具名部分解除**——用户裁决「枚举关联值需要具名就迭代宿主」；spec A.2.2 具名四形态随之收口） | 枚举用例括号内接受具名形参 `IDENT ':' type-annotation` 或位置 `type-annotation`（同一声明内不可混用）；仍不允许 `IDENT '='`（默认值）或裸字面量。match 解构支持位置绑定 / `_` 占位 / 具名绑定 `IDENT ':' IDENT`；绑定数 ≠ 关联值数 → E4-005 | Parser.parseEnumCase（具名解析）、match 模式绑定解析（具名/`_`）；Interpreter.executeMatch（按位/具名对位、arity 运行时校验、paramNames 入值）；TypeChecker.bindMatchCaseVariables（E4-005 arity）、具名声明标签实参放行 |
| 3.16 | **下标 vs 切片消歧** | `[` 内首个非空白 token：若为 `:` → 切片（开放起始边界）；否则先解析 `expression`，其后紧跟 `:` → 切片，否则为单元素索引。实现以前瞻 `:` 判定，避免 expression 贪婪吞噬边界 | Parser.swift `parsePrimarySuffix`（issue-lexer-gaps-2026-08-28 P2-B） |
| 3.17 | **切片开放边界语义** | `a[i:]`/`a[:j]`/`a[:]` 省略的边界脱糖为 `nil`（同 3.12 的 `Optional.none`），运行时 `.slice` 以起始 0 / 末尾长度填补；切片为半开区间 `[i, j)`，边界负索引尾部计数（G48） | Parser.swift `parsePrimarySuffix` + Interpreter `.slice`（G48 / SubscriptStrategies.swift） |

> ⚠️ **规则 3.13 与 3.14 的上下文区分**：
> - 语句上下文（函数体/方法体内）：`IDENT '|'` 后跟控制流关键字是标签；后跟其他 token 是表达式
> - 声明上下文（模块顶层/扩展块内）：`IDENT '|'` 后跟修饰符关键字是声明修饰；后跟其他 token 是裸函数声明的一部分（如 `函数名|func(...)`）
> - 这两个上下文由解析器当前状态（是否在语句块内）天然区分，无需额外前瞻

> ⚠️ **规则 3.2 与 3.14 的协同**：
> - 类型体内：函数声明 → 报错（提示移至扩展块）
> - 扩展块内：自由函数 → 报错（提示移至模块顶层）
> - 模块顶层：自由函数 → 合法；方法声明（带 `\|self`/`\|own`）→ 报错（提示移至扩展块）
---

### A.5 意图候选项产生式（草案，未采纳）

> ⚠️ **未采纳**：以下产生式**不代表当前语言**，仅作为未来采纳时的 graft point（对应 spec v0 已知缺口登记）。采纳须走 spec 变更治理流程 + 版本 bump。当前实现以 §1–§3 为准。

```
(* G51 挪入：match 守卫与标量绑定——Pini草稿 match-case 无此设计，宿主未实现；未来采纳时启用 *)
match-case      ::= 'case' match-pattern ['if' expression] [match-binding] control-block;
match-binding   ::= '(' [IDENT ':' IDENT | IDENT] {',' [IDENT ':' IDENT | IDENT]} ')';
```

### A.6 验证记录

#### A.6.1 词法 EBNF ↔ `pini tokens` 抽查（/tmp/token-probe.pini）

覆盖：进制前缀、科学计数法、字符串转义、插值字符串、布尔、`;` 注释、嵌套缩进栈、运算符最长匹配。实测（节选）：

```
2:15 int 31                     ← 0x1F 十六进制 ✅
3:10 float 0.0314               ← 3.14e-2 科学计数法 ✅
5:12 interpolatedString "你好，\(计数 + 1)！"  ← 插值 ✅
7:1  indent →                   ← if 子块缩进 ✅
8:1  indent →                   ← 嵌套缩进 ✅
9:1  dedent ←                   ← else 回到 if 级 ✅
11:1 dedent ← / dedent ←        ← 块结束逐层弹出 ✅
7:26 lessThanOrEqual <=         ← 中缀比较 ✅
```

> 词法 EBNF §1 与实测 token 流一致。

#### A.6.2 语法 EBNF ↔ 全量示例 parse 回归

`find examples -name "*.pini"` → **46/46 PASS**（含 multifile/package-demo 子目录；新增 `examples/slice.pini` 覆盖 G48 切片语法 `a[i:j]`/`a[i:]`/`a[:j]`/`a[:]`，已纳入 `ExamplesRunTests` 黄金输出表与 `ExamplesConformanceTests` 的 `check` 门）。EBNF §2 覆盖全部已实现语法构造。

#### A.6.3 优先级/结合性判别式（14/14）

`a - b - c` → 左结合 ✅；`a + b * c` → 乘优先 ✅；`a & b == c` → 比较高于位 ✅；`a << 1 + 2` → 加减高于移位 ✅；`a || b && c` → && 高于 || ✅；`a == b != c` → 同级左结合 ✅；`-a + b` → 一元高于二元 ✅；`a * b % c` → */% 左结合 ✅；`a && b || c` → 左结合 ✅；`a[i] + 1` → 后缀先于二元 ✅；`f(x).g` → 后缀链 ✅；`a[i][j] = v` → 下标写目标 ✅；`await f()` → 前缀挂起 join ✅；`a <= b` → 中缀比较 ✅。

#### A.6.4 优先级表 ↔ Parser 调用链一致性

`parseExpression → parseAssignment → parseOr → parseAnd → parseEquality → parseComparison → parseBitwise → parseTerm → parseFactor → parseUnary → parsePrimary`（Parser.swift:2053-2296）与 §A.3 总表 9 层**一一对应**，无缺层/无错序（S4 核对）。

#### A.6.5 回归门禁

`swift test --disable-sandbox`：941 测试全绿（0 失败）——含解释器 / LLVM 后端（RuntimeBackendTests 三执行路径锁步）/ 示例门禁 / SwiftTesting 宿主。

---

*（本附录由 T5 草案 S2–S5 并入规范，v0.43.0；原独立草案与事实基线文档 v0.46.0 删除，本附录为形式文法唯一载体。）*

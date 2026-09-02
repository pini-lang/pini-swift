# Pini 新版 spec 落地规划（v0.48.0 候选）

> **状态**：执行中（Phase 0 治理起步）。本文是 `Pini草稿.md`（更新意图）+ `pini-spec-v0.md`（人工干预）所定义「新版 spec」的落地规划，遵循 spec v0 §1.3 变更治理与 GIT_WORKFLOW。
> **制定依据**：所有「代码现状」结论均经 `grep`/`Read` 证据核实（见 §3 证据列），非凭记忆。
> **已拍板决策**（用户，2026-08-26）：
> - **D1 FFI 范围**：解释器优先、LLVM 暂缓（仿 LazyRef 模式；FFI 标 Experimental 保可逆）。
> - **D2 交付形态**：先把本规划持久化到文件，再从 Phase 0 治理起步（切 feature 分支 → 补 spec prose/ADR/证据表 → Phase 1→2→3）。

---

## 1. 背景与范围

- 草稿意图新增：**FFI/unsafe 全套设计**（`foreign` 块 / `*T` 指针 / `&` 取址 / `unsafe` 表达式 / `|unsafe` 函数）、**控制流标签反转**（`scope 块标签:` → `标签|控制流关键字`）、**函数体强制缩进 ≥1 层**、`Self` 在 trait = 被扩展类型、LazyRef 改名+`.value`-only。
- 人工干预 spec：§A EBNF 重构并正式写入 `foreign-decl`/`*T`/`&`/`unsafe`/`detach-expr-stmt`；新增消歧规则 **3.13/3.14/3.15**（均标 `Parser.swift（需实现）`）；规则 3.2 由「方法缺省假定」改为「类型体内禁止函数声明」。
- **核心结论**：新版 spec 的大部分构造代码尚未实现；spec 自身内部不一致（§2 散文 vs §A）；FFI 是此前 roadmap 定为 `T14`「单独立项 / 自举前置最大缺口」、尚未立项的特性，现经草稿+§A 静默进入 spec，但 prose/ADR/缺口表全缺。

## 2. 新版 spec 变更摘要

| 区域 | 变更 |
|---|---|
| §A EBNF | 重构为单 fenced 块；加 `foreign-decl`/`foreign-signature`、`*T` 指针类型、`&`/`unsafe` 一元前缀、`detach-expr-stmt`；删 A.5 候选 C-1~C-5 详细产生式 |
| §A 消歧 | 3.2 改为「类型体内禁止函数声明」；新增 3.13（标签 `标签\|kw`）、3.14（扩展块禁自由函数）、3.15（枚举关联参数仅位置类型） |
| 草稿 | 新增 `## FFI与unsafe` 全文；标签示例改 `outer\|while`；函数体强制缩进；`\|unsafe` 入捕获表；`Self` trait 语义；LazyRef 改名 |

## 3. 缺口分析（新版 spec/意图 vs 当前代码，已核实）

| 构造 | 新版 spec 位置 | 代码现状（证据） | 复杂度 |
|---|---|---|---|
| **FFI 全套**（foreign/`*T`/`&`/`unsafe`/`\|unsafe`） | §A EBNF；草稿全文 | **完全未实现**：`Sources` 搜 `foreign`/`Foreign` 零命中（仅 Diagnostics TOML + runtime 的 Swift `UnsafePointer` 无关项）；`Token.swift:280-303` 关键字枚举**无** `unsafe`/`foreign`/`detach` | 极大（新子系统） |
| **标签反转** `标签\|关键字` | §A EBNF + 规则 3.13 | 代码仅实现**旧** `scope 块标签:`：`Parser.swift:1549 parseScope`→`scopedBlock`；while/for `label:nil`（`1796`/`1862`）；ADR-013 注释（`1774-1775`/`1836-1837`） | 中（破坏性 + 迁移） |
| **规则 3.2** 类型体禁函数 | §A 规则 3.2（需实现） | 代码**相反**：`methodDefaultAssumptionActive`（`Parser.swift:21/253/447…`），遇类型体内函数假定为方法，否则抛 `methodDefaultAssumptionTerminated`（`1043`/`1207`，`ParserError.swift:27`） | 中 |
| **规则 3.14** 扩展块禁自由函数 | 规则 3.14（需实现） | 未实现 | 小 |
| **规则 3.15** 枚举关联参数仅位置 | 规则 3.15（需实现） | 未实现 | 小 |
| **函数体强制缩进 ≥1** | 仅草稿（§A 无对应） | 代码允许非缩进体：`func-body ::= INDENT{…}DEDENT \| { statement }` | 小（草稿未进 spec，需先采纳） |
| **`detach` 语句形式** | §A `detach-expr-stmt` | `detach` 是内建（`Interpreter`），非语句关键字（`Token` 无 `detach`） | 小 |
| **`Self` 在 trait = 扩展类型** | 草稿 + §2.4.1 片段 | `Token` 有 `Self`；大概率已实现，待验证 | 极小 |
| **LazyRef** | 草稿 | **已实现**（G40 v0.42.0，引用语义 `.value`，`.valueFuture` 已弃） | 无（仅核对） |

**迁移爆破面（标签反转）**：`examples/for.pini:48`、`examples/control-while.pini:33` + 7 测试文件（`BlockLabelTests`/`GrammarConsistencyTests`/`LSPTests`/`RuntimeBackendTests`/`SuspendRuntimeTests`/`ParserTests`/`StructuredConcurrencyTests`）。

## 4. 必须先解决的治理问题（blocker）

1. **spec 内部自相矛盾（最高优先级）**：§2.4.1 散文（spec 行 `94/115/116/121`）仍规定 `scope 块标签:`（ADR-013），§A EBNF + 规则 3.13 规定 `标签\|关键字` 且 `scope`"保留但不再使用"。落地前须对齐；为不虚假声称已实现，§2.4.1 改为新设计但标「实现状态：待 Phase 1」。
2. **FFI 是「文法孤儿」**：草稿有完整设计、§A 有文法，但 spec **prose（§2.x）、§3 缺口表、ADR 全缺**。T14 此前未立项。须先补 FFI prose + ADR-015 + §3 缺口登记再写码。
3. **关键字集漂移**：§A.1.1 标称 33 关键字（含 `unsafe`/`foreign`/`test`/`detach`），`Token.swift` 仅 lex 子集（证据 E-047 称 30）。随 Phase 1/2 补齐或修正声明。
4. **证据表未刷新（违反 §1.4）**：新规则 3.2/3.13/3.14/3.15 未进 `evidence-table.toml`；E-047 关键字数应更新为 33。
5. **版本**：当前 `v0.47.0`（CHANGELOG）。含破坏性变更 → `v0.48.0` + 迁移说明（spec §1.1 允许 v0.x 破坏性变更，须迁移说明）。

## 5. ADR 草案

### ADR-014 · 控制流标签语法反转（`scope label:` → `标签|关键字`）
- **上下文**：ADR-013(v0.41.0) 的 `scope 块标签:` 与草稿/§A 新模型 `标签|控制流关键字` 冲突；新模型把标签直接绑在 `if/while/for` 上，取消独立 `scope` 语句。
- **决策**：采纳新模型。`scope` 关键字保留但**改为 reserved-error**（使用即报错）；`break/continue 标签` 按标签名定向不变。
- **后果**：破坏性。codemod `examples/for.pini:48`、`examples/control-while.pini:33` + 7 测试文件。`Statement.scopedBlock` 停止产出（AST 节点暂留，消费者后续清理）。
- **状态**：Proposed。

### ADR-015 · 采纳 FFI & unsafe 子系统
- **上下文**：自举北极星要求调用 libc（`malloc/free/memcpy` + 不透明指针），T14 是阶段 3 前置；草稿已给出完整设计。
- **决策（D1，解释器优先、LLVM 暂缓）**：① `unsafe` 表达式前缀（最小不安全范围）；② `|unsafe` 自由函数（不安全上下文）；③ `*T` 原始指针（仅 C 兼容类型，禁 object，与 ARC 隔离）；④ `&` 取址；⑤ `[X|foreign]` 声明外部 C 函数。FFI 标 **Experimental** 保可逆。LLVM 端暂缓（仿 LazyRef：先解释器，未支持子集显式 unsupported）。
- **后果**：新增 Lexer/Parser/AST/TypeChecker/Interpreter/CodeGen/Runtime 七层；LLVM 调外部 C 是最难点（按决策推迟）。严守 spec §3.2 C-ABI **不得泄漏 Swift 类型**。
- **状态**：Proposed。

### ADR-016 · 解析器声明上下文收紧（规则 3.2/3.14/3.15）
- **决策**：类型体内遇函数声明 → 报错指引「移到同文件扩展块用 `|self`」；扩展块内遇自由函数 → 报错「移到模块顶层」；枚举关联参数仅接受位置 `type-annotation`（拒 `IDENT:`/`IDENT=`/字面量）。移除 `methodDefaultAssumption` 状态机。
- **后果**：破坏性（任何「类型体内写方法」旧写法失效），须扫描 examples/tests 确认无存量。
- **状态**：Proposed。

### ADR-017 · Phase 2b 解释器 dlsym 动态加载
- **上下文**：ADR-015 在 Phase 2a 仅落地「解释器预注册原生函数表」（shim 白名单）；`dlsym` 动态符号解析与 `[ffi]` 配置被标记为 D1 暂缓的后续阶段（CHANGELOG v0.48.2 范围说明）。自举编译器所需 `libc`/`libm` 已在 shim 表内，但 FFI 的本体意义是「调用任意 C 库」——需真实 `dlsym` 加载。本 ADR 决策 Phase 2b **解释器半场**的机制（LLVM 端 FFI 仍 D1 暂缓，见 Phase 2b-LLVM）。
- **决策**：
  1. **动态加载用 `dlopen`/`dlsym`/`dlclose`**（Darwin/Linux 经 `SystemDL` 封装），不引入链接期绑定、也不引入 libffi 依赖。
  2. **每签名 thunk 工厂**：因 Phase 2a（§2.7）已将顶层签名收敛为**封闭集**（标量 + 指针 + `()`），在 foreign 注册期为每个函数按精确 C 签名生成 `([Value]) throws -> Value` 闭包（`@convention(c)` 函数指针），避免 libffi 的复杂度——类型集封闭使分支可枚举。
  3. **解析顺序（已在 §2.7 锁死）**：shim 白名单（`nativeFunctions`）优先 → 否则按 `fd.name` 经 `FFILoader` 解析库 + `dlsym` 裸绑定。`fd.name` 从「仅组织名」升级为真实库绑定键。
  4. **`[ffi]` 配置**：`abi` 全局唯一不可改、`search_paths` 分层追加、`libs` 全局链接；子模块可追加。`parseManifest` 对未知 `[table]` 已 `default: break` 容错（缝 ⑦）。
  5. **不泄漏 Swift 类型**（§3.2 纪律），与 shim 同走单一 C-ABI 边界。
- **后果**：新增 `SystemDL`/`FFILoader`/`ForeignThunk` 三文件 + `Package` 的 `[ffi]` 解析（`FFIConfig`）。解释器自此能调任意系统/用户 `.so`/`.dylib`。新诊断码 **E5-016**（库未找到）/ **E5-017**（符号未找到）。LLVM 端 FFI 仍显式 `unsupported`（D1 暂缓至 Phase 2b-LLVM）。变参/回调/`errno` 仍 out-of-scope（§2.7 已登记）。
- **状态**：Proposed（实现见 v0.48.3）。

## 6. 分阶段落地计划

> 遵循 GIT_WORKFLOW：master 受保护，走 `feature/agent/pini-dev/<slug>`；Conventional Commits；身份 `Pini Dev <dev@pini.local>`。当前 `Pini草稿.md` 与 `pini-spec-v0.md` 为 **staged 未提交**，须先切分支再提交（不直推 master）。

**Phase 0 · 治理补全（先于任何代码）** — `feature/agent/pini-dev/spec-v048-governance`
1. 提交人工已 staged 的草稿+spec 基线。
2. 对齐 §2.4.1 散文与 §A（标签反转、`scope` reserved，标「待 Phase 1」）。
3. 写 FFI prose（§2.x，Experimental）+ ADR-015 + §3 缺口登记（G43 FFI / G44 标签反转）。
4. 刷新 `evidence-table.toml`（补 3.13/3.14/3.15；E-047 关键字数→33）。
5. `printVersion`→`0.48.0`；CHANGELOG 加 v0.48.0。
- DoD：spec 内部一致、FFI 有 prose+ADR、证据表刷新通过 `tomllib`。

**Phase 1 · 非 FFI 解析器对齐** — `feature/agent/pini-dev/parser-reconcile`
- ADR-014（标签反转 + `scope` reserved-error + codemod 2 示例/7 测试）、ADR-016（3.2/3.14/3.15）、`detach-expr-stmt`、函数体强制缩进（若 Phase 0 已采纳进 spec）。
- 测试：TDD 三要素；`ExamplesConformanceTests` 全绿为门禁。

**Phase 2a · FFI & unsafe 解释器优先** — `feature/agent/pini-dev/ffi-interp`
- Lexer：`unsafe`/`foreign`/`detach` 关键字 + `&` + `*T` 指针 token。
- Parser/AST：`foreign-decl`/`UnsafeExpr`/`PointerType`/地址取/不安全上下文。
- TypeChecker：`*T` C 兼容性约束（禁 object）+ ARC 隔离保证。
- Interpreter：`unsafe` 消耗点、`load/store/addressof` 经 runtime `bk_*`（§3.2 C-ABI）、`foreign` 调原生 C（注册原生函数表）。
- Runtime：`libPiniRuntime` 加 `@_cdecl` 指针 primitives。
- 测试：双后端锁步覆盖解释器部分；LLVM 不支持子集显式 unsupported。

**Phase 3 · 收口** — `feature/agent/pini-dev/ffi-finish`
- `Self` 在 trait 语义验证+文档；`|unsafe` 捕获表行；README（标签语法、FFI）；roadmap（T14 状态）；`merge --no-ff` 回 master。

## 7. 风险与权衡

| 风险 | 影响 | 缓解 |
|---|---|---|
| FFI 范围失控（原 T14 单独立项） | 最大单特性，LLVM 调外部 C 极难 | 先解释器后 LLVM（D1）；FFI 标 Experimental 保可逆 |
| spec 欠规范即实现（FFI 有文法无 prose） | 高返工 | Phase 0 先写 prose+ADR 再写码 |
| 破坏性标签变更静默误编译 | 旧 `scope` 代码静默失败 | `scope` 改 reserved-error + codemod 全部存量 |
| 证据新鲜度（§1.4）被忽略 | 治理违约 | Phase 0 刷新证据表，新规则全登记 |
| 关键字集漂移 | 文档≠实现 | 随 Phase 1/2 补齐或修正 §A.1.1 声明 |

## 8. 执行日志（append-only）

- 2026-08-26：规划制定 + 缺口核实（证据见 §3）；用户拍板 D1/D2；本文件持久化；切 `feature/agent/pini-dev/spec-v048-governance` 并提交人工 staged 基线；开始 Phase 0 治理补全。
- 2026-08-26：Phase 1（非 FFI 解析器对齐）全量落地——ADR-014（a62aa21）、ADR-016 规则 3.15（a710f51）、detach 语句（313cda3）、函数体强制缩进（c03ef4f）、扩展块子系统（7bab11f）。970 XCTest + 44 SwiftTesting 全绿。
- 2026-08-27：Phase 2a（FFI & unsafe 解释器优先）落地——foreign 块 + 原生函数表 + `*T` + `unsafe`/`&`/`|unsafe` + 指针原语；983 XCTest 全绿；LLVM 端显式 unsupported（D1 保留）；dlsym 动态解析与 LLVM FFI 列后续。

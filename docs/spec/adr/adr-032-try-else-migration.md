# ADR-032：try-else 迁移与 `^` 右值糖脱糖（错误模型单一化）

- 状态：Accepted（2026-09-07 立项）
- 层级：语言级
- 关联：ADR-031（时序前置：LLVM 后端重写）、spec §2.4.4 / §3 G3、`docs/Pini草稿.md`（意图源，只读资产，不随仓分发）
- 影响面：spec §2.4.4 / §A、`Sources/PiniCore`（Parser / AST / Desugar / ConstantFolder / SemanticAnalyzer / TypeChecker / Interpreter / SuspendEvaluator / CodeGen/StmtEmitter）、`Sources/PiniCLI`、examples 语料 3 文件、`Tests/PiniTests`（TryExceptTests / CPSDifferentialTests / IRExecutionTests）

> 本 ADR 记**约束与判据**，不记操作细节。分阶段执行计划（M0–M5）由执行批次维护。

---

## 1. 约束（本 ADR 改变了什么）

1. **try-else 取代 try-except**：错误传播表层原语只有一种——try-else，具有两种位置形态：
   - 语句位：`try 表达式 else 错误绑定名: 控制流语句/块`
   - 表达式位：`try 表达式 else 错误绑定名: 控制流语句` 作为表达式后缀出现（如 `let x = try f() else err: return err`），其值为成功路径的解包值（D1=B 裁决）。
2. **`except` 一步删除**：`except` 关键字自落地批起从文法移除；解析遇 `except` 报常规解析错误（D2 裁决：无迁移提示、无并存窗口、无过渡期）。
3. **try-else 只接受 `Result`**：操作数静态要求为 `Result<T, E>`（复用既有静态拦截路径）；成功路径求值为解包值 `T`；错误路径把 err 值绑定到错误绑定名后执行控制流语句。**`(值, 错误)` 二元元组错误位约定退役**（D3=B 裁决）：`try` 不再接受任意二元元组；多返回值与错误传播彻底分离。
4. **`^` 右值糖重定义为脱糖**：`^e` ≡ `try e else err: return err`，规范语义以 try-else 表达式形态给出；`UnwrapErrSignal` 信号机制与「函数边界捕获注入返回元组末槽」随之退役。`^T` 类型糖（`^T` ≡ `Result<T>`）、中缀位异或 `^`、复合赋值 `^=` **不受影响**。
5. **await 错误通道**：`CancelError` 经 Result / try-else 捕获；§2.4.4 中「经 `except` 正常捕获」的描述随 §2.4.4 重写一并改写。
6. **时序**：本迁移是 ADR-031 LLVM 后端重写的**前置前端收敛**；ADR-031 的 P3（垂直切片）起的后端工作在本迁移 M0–M5 收口前不得开工，`except` / `UnwrapErrSignal` 形态不得进入新后端。
7. **落地顺序固定**：M1 spec/EBNF 反录（§2.4.4 重写、try-stmt 产生式、§A.4 复查、§A 关键字表与词法注记）→ M2 实现（首步：GrammarConsistencyTests 增补 try-else 断言先红 → 实现落地转绿，同批收口全量绿基线；收口时补 CHANGELOG 迁移说明）→ M3 语料（examples 与 `examples/selfhost` 独立仓 two-track 提交）→ M4 `^` 脱糖落地 → M5 证据登记与工单收口。

---

## 2. 必要性（不做会怎样）

- **N-1 双错误模型并存**：§2.4.4 元组错误位（错误位 = `elements[1]`，`.null`/空串判据）与 Result / `^` 信号机制并存；同一「errors-as-data」意图有两套语义不同的事实源。
- **N-2 错误槽指定是隐式魔法**：`^e` 的错误传播依赖「函数返回元组末槽」的隐式约定，无法完整脱糖为显式控制流（D3=B 裁决理由，2026-09-07）。
- **N-3 时序风险**：新后端若在表层形态收敛前开工，`except` / `UnwrapErrSignal` 将被固化进重写产物。

---

## 3. 充分性（判据可机械核验）

- **S-1 文法单一**：spec §A 与实现文法中 `except` 归零；try-else 产生式唯一（语句位 + 表达式位）。
- **S-2 语义单一**：`grep -rE 'UnwrapErrSignal' Sources/` 归零；try-else 操作数静态拦截仅 `Result`。
- **S-3 行为保护**：迁移后 `examples/try.pini` 与 `examples/selfhost` 语料在解释器与 LLVM 端到端全绿。`^` 右值糖在 examples / Tests 语料中**真实使用为 0 处**（2026-09-07 实测：全部匹配为字符串字面量或中缀位异或），脱糖无行为回归面。
- **S-4 测试账实相符**：`Tests/PiniTests/TryExceptTests/TryExceptTests.swift`（92 行 / 8 用例）的元组模型用例随 D3=B 改写为 Result 语义或删除；`IRExecutionTests` 错误槽用例随 ABI 映射显式化改写。

---

## 4. 止损判据

| # | 判据 | 动作 |
|---|---|---|
| S-1 | M2 实现超出盘点落点（约 10 文件）未收敛 | 停止；降级为并存窗口方案并记工单（与 D2 冲突时回到裁决） |
| S-2 | M4 脱糖改动触及 Parser/Desugar 之外的表达式求值链路 | 停止；`^` 暂限语句位可用，记工单 |
| S-3 | selfhost 探针（嵌套独立仓）迁移后无法自验 | 停止；host 侧先行收口，selfhost 迁移转独立工单 |

---

## 5. 落地记录

### 2026-09-07（立项，M0）

- 裁决记录：D1=B（try-else 表达式位形态）、D2（一步删除、无迁移提示）、D3=B（元组错误位约定退役）、D4（LLVM 重写前置收敛，ADR-031 P3 前不开工）。
- 实测基线（2026-09-07）：`^` 真实 rvalue 使用 0 处；try/except 语料 3 文件（`examples/try.pini`、`examples/selfhost/src/ast/ast.pini`、`examples/selfhost/src/main.pini`）；Tests 无 `.pini` 夹具，内嵌代码集中于 `TryExceptTests.swift` / `CPSDifferentialTests` / `IRExecutionTests`。
- 本批产出：本 ADR、spec §3 G3 状态登记、工作区 LLVM 方案稿（`LLVM后端重写方案-2026-09-07.md`，未入仓）时序段。spec §2.4.4 / EBNF 正文重写待 M1，本批不动实现代码。

### 2026-09-07（M1 反录）

- spec `docs/spec/pini-spec-v0.md` 反录完成（10 处）：§2.4.4 整节重写（try-else 唯一原语、语句位+表达式位、`^e` 定义性脱糖、元组错误位退役、CancelError 通道改写）；§A KEYWORD 表移除 `'except'`；§A.2.4 `try-stmt` 改写为 `try-expr` + `try-handler`（单行 handler 限 return/break/continue/pass，块形式须以控制流终止）；`try-expr` 挂入 §A.2.5 primary 位（不占优先级层，`'else'` 关键字天然终止操作数）；§2.4.1 构造索引 `^` 行、pass 占位惯用法、§3.1.3 CancelError 引用同步；§3 G3 状态改「已定义（已反录）」并勘误计划版本 v0.50.0 → v0.53.0。
- **计划修正（就地修订约束 7，同日裁决授权）**：①原 M1 含「GrammarConsistencyTests 先红」——实测该测试族无任何 try/except 断言、亦不 grep spec 正文，前提不成立；先红改为 M2 首步（增补 try-else 断言红 → 实现转绿同批），迁移窗口不挂红基线。②「CHANGELOG 迁移说明」移至 M2 收口——`docs/spec/CHANGELOG.md` 只记公开版本，版本号随实现落地时定。
- 本批零代码改动；全量测试基线不受影响（spec 文本无自动化断言）。
- 迁移窗口标记：§2.4.4 状态注已声明「宿主现状与本节暂不一致属迁移批预期状态，非漂移」；G3 证据行标 STALE（M2 刷新）。

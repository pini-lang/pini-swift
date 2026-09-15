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
- 实测基线（2026-09-07，**M3 批勘误**）：`^` 真实 rvalue 使用 0 处；try/except 语料实足迹为 `examples/try.pini` 与 selfhost 仓 `src/lexer/lexer.pini`（关键字表镜像）+ `examples/lex_corpus.pini`（L0 语料 2 行）——立项时记的「`examples/selfhost/src/ast/ast.pini`、`examples/selfhost/src/main.pini`」系普查口径粗糙的误记（子串误命中），M3 精查推翻，勘误于此（原论证撤回）。Tests 无 `.pini` 夹具，内嵌代码集中于 `TryExceptTests.swift` / `CPSDifferentialTests` / `IRExecutionTests`；**另漏列 `ResultUnwrapTests`**（`^` 语义测试文件，M2 实测补齐）。
- 本批产出：本 ADR、spec §3 G3 状态登记、工作区 LLVM 方案稿（`LLVM后端重写方案-2026-09-07.md`，未入仓）时序段。spec §2.4.4 / EBNF 正文重写待 M1，本批不动实现代码。

### 2026-09-07（M1 反录）

- spec `docs/spec/pini-spec-v0.md` 反录完成（10 处）：§2.4.4 整节重写（try-else 唯一原语、语句位+表达式位、`^e` 定义性脱糖、元组错误位退役、CancelError 通道改写）；§A KEYWORD 表移除 `'except'`；§A.2.4 `try-stmt` 改写为 `try-expr` + `try-handler`（单行 handler 限 return/break/continue/pass，块形式须以控制流终止）；`try-expr` 挂入 §A.2.5 primary 位（不占优先级层，`'else'` 关键字天然终止操作数）；§2.4.1 构造索引 `^` 行、pass 占位惯用法、§3.1.3 CancelError 引用同步；§3 G3 状态改「已定义（已反录）」并勘误计划版本 v0.50.0 → v0.53.0。
- **计划修正（就地修订约束 7，同日裁决授权）**：①原 M1 含「GrammarConsistencyTests 先红」——实测该测试族无任何 try/except 断言、亦不 grep spec 正文，前提不成立；先红改为 M2 首步（增补 try-else 断言红 → 实现转绿同批），迁移窗口不挂红基线。②「CHANGELOG 迁移说明」移至 M2 收口——`docs/spec/CHANGELOG.md` 只记公开版本，版本号随实现落地时定。
- 本批零代码改动；全量测试基线不受影响（spec 文本无自动化断言）。
- 迁移窗口标记：§2.4.4 状态注已声明「宿主现状与本节暂不一致属迁移批预期状态，非漂移」；G3 证据行标 STALE（M2 刷新）。

### 2026-09-07（M2 实现落地）

- **GrammarConsistencyTests 先红→绿同批**：增补 7 断言（语句位/表达式位结构、`^` 脱糖形态、块形式、旧 try 块拒绝、单行 handler 白名单拒绝、`except` 词法降级 IDENT）。
- **实现落地**（`Expression.tryExpression` 取代 `Statement.tryStatement`/`ExceptClause`/`Expression.resultUnwrap`，编译器穷尽性驱动全部消费者更新）：`Parser.parseTry` 重写 + `parseTryHandler`（单行白名单四语句，块形式复用 parseControlBlock）+ parseUnary 挂表达式位 try + `^` 前缀 Parser 层脱糖；`Interpreter` tryExpression 求值（ok→载荷；err→绑定 errorVar 执行 handler，ControlSignal 自然冒泡）；`SuspendEvaluator` CPS 对齐（operand 含 join 时挂起，handler 含 join 显式拒绝）；`UnwrapErrSignal`/`makeUnwrapErrorReturn`/`executeTry` 全删（S-2 归零达成）；`ExprEmitter` try-else fail-loud（同旧 `^` 边界）；`StmtEmitter.generateTryStatement` 退役；`Token` 关键字表移除 `except`；LSP 补全同步。
- **测试/语料迁移**：TryExceptTests 8 用例全部改写为 Result 语义（err("") 无空串特判、pass 吞错惯用法、`^` 脱糖行为面 2 例）；CPS 两夹具改写；`testTryStatement_LLI` 删除（LLVM 发射待后端批）；`examples/try.pini` 迁移（解释器自验「读取失败」）。
- **计划修正（就地修订约束 7）**：M2 内已含 `^` 脱糖落地（原 M4 范围），M4 并入 M2；M3 剩 selfhost 仓 two-track 迁移；M4 阶段撤销。
- **收口件**：`docs/spec/CHANGELOG.md` v0.53.0 迁移说明；spec §3 G3 证据行 STALE 刷新（`executeTry`/`ResultUnwrap` → `Parser.parseTry`/`Expression.tryExpression`）。
- **实测规范点（转 M5 工单）**：返回位只接受元组 ⇒ 函数返回 `Result` 须以 `^T` 类型糖嵌入元组（`-> (^T,)`），spec §2.4.4 未明说此写法。
- 全量测试基线以本批实测为准（79 项相关类先行全绿，全量见提交记录）。

### 2026-09-07（M3 selfhost 同步）

- selfhost 仓（嵌套独立仓，two-track 提交）commit `bbf1b91` → merge `104d31b`：`src/lexer/lexer.pini` 删 `kw_except` case 与 `is_keyword` except 分支（关键词表对齐宿主 33 个）；`examples/lex_corpus.pini` 删裸 `except:` 探针行（裁决：L0 语料只载现役关键字面）；`pini.toml` spec 兼容锚 0.1 → 0.2；`.pini/baseline` 第 20 次重校准（host=`6485609`，version=0.53.0，spec=0.2）。
- 六门 GREEN：L0 MATCH 505 / parse MATCH 253+94 / check 15 文件 / test 70/0 / audit GREEN（改前红态：L0 唯一差分 = 语料 L17 `except`，宿主 IDENT vs bootstrap keyword）。
- 宿主侧缺陷（M3 发现，已立工单）：宿主 `MiniTOML` 不剥值行行内注释 → G52 Def-3 入口一致性校验 E5-018 误报（`docs/spec/issue/archive/issue-minitoml-inline-comment-2026-09-07.md`）；selfhost 清单值行注释改独立行规避，宿主根因待工单修复。

### 2026-09-07（M5 收口——迁移批次关闭）

- 证据登记：E-132（源已删除；try-else 唯一原语落地：双形态/`^` 脱糖/CPS 对齐/LLVM fail-loud；全量 1220/0/113，GCT 7 断言红→绿）/ E-133（源已删除；旧模型七符号零残留，S-2 归零）/ E-134（源已删除；selfhost 第 20 次重校准六门绿）——全部现跑重筛 FRESH。
- 工单兑付：`docs/spec/issue/archive/issue-caret-type-sugar-tuple-return-2026-09-07.md` 立案（M2 预告的「规范点转 M5 工单」）。
- spec §2.4.4 状态注迁移窗口标注解除（「STALE 待 M2 刷新」→「已落地」，M2 刷新的遗留残留清零）。
- 迁移状态：M0-M3 完成、M4 并入 M2（阶段撤销）、M5 收口——**本迁移批次关闭**。LLVM 侧遗留两项已由工单承接（try-else fail-loud 发射待 ADR-031 后端批；`-> (^T,)` spec 明文化），不在本 ADR 范围内连续修复。

### 2026-09-12（证据表滚动清理核实）

- 上文「2026-09-07」节登记的三条证据（E-132 / E-133 / E-134）（源已删除）**不在当前 `docs/spec/evidence-table.toml` 内**：
  该表为滚动表，`tools/evidence_sweep.py` 按条目状态清理，本次清理发生在 M6b 翻转批的表刷新。
- 处置（本 ADR 只增不改）：登记行**保留为历史记录**，条目本体见对应提交历史；spec §2.4.4 的两个
  证据引用已同步改为指向本 ADR（原文断言「证据表 E-132..E-134（源已删除），FRESH」在条目清理后不可核验）。
- 口径（待固化为规则）：**归档件、已关闭工单、ADR 与 spec 的历史登记行允许引用已清理的证据 ID**；
  活跃文档与源码注释不应引用当前表外的 ID。

### 2026-09-15（上节「口径」被取代）

- 本 ADR **只增不改**：上文 2026-09-12 节保留为历史记录，本条只记它已被取代，不改动原文。
- **被取代者**：① 该节的**处置**（把 spec 正文的证据引用改为指向本 ADR）；② 该节的
  **「口径（待固化为规则）」**——「归档件、已关闭工单、ADR 与 spec 的历史登记行允许引用已清理的
  证据 ID」。后者是 `meta.dangling_policy` 三分类的源头。
- **取代者**（用户 2026-09-15 裁定；spec §1.4「ID 与「不得被外部引用」」已同步）：**表 ID 一律不得被
  任何外部载体引用**（表内每条标 `citable = false`），**不再按载体分类给口子**；历史载体确需保留一条
  已删编号的痕迹时，写 `E-NNN（源已删除）`。理由：本表是滚动表，「哪些载体可以引用」是一条每新增一类
  载体就要重判的规则，而「引用**必然**悬空」是结构事实——按载体分类只会让分类本身变成维护负担。
- **器械**：`tools/evidence_sweep.py --check` 对表外无标注的编号**报错并非零退出**，
  `hooks/pre-commit` 每提交无条件执行；该节「处置」所依赖的**债务可见性载体 `meta.dangling_ids`
  已废除**（债务从「记进表里待人工处置」改为「器械当场拦下」）。
- 登记：`docs/spec/issue/issue-evidence-id-retype-2026-09-15.md`。

# 工单：HIR 节点不携带源码位置（执行侧诊断与调试器失去位置基准）

- 状态：**Open（2026-09-12 立案；LR-4 P1-2 引擎骨架落地时实测发现，只登记不修）**
- 发现渠道：P1-2（HIR 执行引擎骨架）——`RuntimeError` 的每个 case 都要求 `SourceLocation`，
  而 HIR 节点的类型定义里没有这个字段，执行侧只能填占位位置。
- 严重度：中（**不影响执行正确性**；影响诊断质量，且是 P4 调试器/REPL 迁移的**位置基准前置**）
- 归属：HIR 形态（**节点类型定义**）——不是执行器实现的缺陷，执行器只是第一个暴露它的消费者

## 现象（实测）

P1-2 的引擎对任何节点缺口都只能报占位位置：

```
Error: ... node 'arrayLiteral' is dispatched but not implemented yet (P1-2 skeleton)
  at <hir>:0:0
```

`<hir>` 不是文件名，是**显式占位符**（`HIRExecutor.noLocation` 的 `fileName`）。
选用一个可辨识的假名而非空串，是为了让「没有位置」这件事在诊断里**看得见**——
否则它会与「有位置但为空」混淆，被读成正常的空文件名。

## 证据（E1 代码结构）

| 事实 | 落点 |
|---|---|
| HIR 节点类型**零** `SourceLocation` | `Sources/PiniCore/HIR/HIRNode.swift` 全文 0 处（60 个节点 case 均无位置字段） |
| 位置只活在 **lowering 过程**里，不进节点 | `Sources/PiniCore/HIR/HIRLowerer.swift` 有 `SourceLocation` 参数贯穿（`expressionLocation` / `statementLocation` 辅助 + `HIRLoweringError.location`），但产物 `HIRExpr`/`HIRStmt` 不带 |
| 解释器侧的位置来自 **AST 节点** | `Sources/PiniCore/Interpreter/Interpreter.swift` 的 `debugHook: ((DebugContext) -> DebugAction)?` 以 AST 语句位置构造 `DebugContext` |
| 调试器消费 `SourceLocation` | `Sources/PiniCore/Debugger/Debugger.swift`（`StopEvent.location` / `Breakpoint` 匹配）、`Sources/PiniCore/Debugger/DAPServer.swift`（`event.location.line`） |

> 注：`HIRLowerer.swift:2945` 等处也会退化成 `SourceLocation(line: 0, column: 0, fileName: "")`
> ——这是**同类问题的第二个面**（lowering 侧对无位置 AST 节点的兜底），本单只登记，不合并处置。

## 下游后果（本单的实际代价）

1. **诊断质量**：HIR 执行引擎报的运行时错误无法指认现场（无行号、无源码片段）。
   与 LLVM 侧对比：LLVM 路径在 **lowering 期**报位置，故门控错误仍有 `at 文件:行:列`；
   执行期错误两侧都拿不到位置——本单只覆盖执行侧的 HIR 面。
2. **P4 的调试器/REPL 迁移（真前置）**：执行计划 P4 要求
   「Debugger 与 REPL 一并迁到 HIR 引擎」（**两条接缝、路径不同**；本单只覆盖调试面那条）。
   断点与单步事件的判据是
   **语句级 `SourceLocation`**（`Breakpoint(fileName:line:)` 与 `StopEvent.location`）。
   HIR 语句无位置 ⇒ 迁移后 `debugHook` 无从判定「现在停在第几行」。
   **故 P4 开工前必须先解本单**（或另立等价的位置供给方案）。
   > 2026-09-13 补（P1-5 S1 落地后）：调试面已抽象为 `DebugHookHost`、两台引擎同形
   > ⇒ P4 迁移**不再另需改调试器子系统**，本单成为其**唯一位置缺口**。
   > 另注：HIR 侧 `debugHook` 已声明但**未接暂停点** —— 位置落地前接线会报占位位置，
   > 断点（按行号相等匹配）永不命中而入口停/单步停在虚构行；该休眠态有断言钉住。
3. **P3 的三层判据**：spec 断言层与「逐语句」粒度若需定位到源行，同样依赖本项。

## 处置选项（未裁决，立项时展开）

- **A：给 HIR 节点加位置字段**。60 个节点 case 逐个加 `SourceLocation`（或一个
  `position` 载体），`HIRLowerer` 全部构造点补填。**改动面最大**，但一次到位，
  且使「HIR 是完整表示」成立（今天 HIR 丢掉了源位置，本身就是「表示不完整」）。
- **B：旁挂位置表**。节点不携带位置，另出一张 `节点标识 ↔ SourceLocation` 的侧表，
  由 lowering 期填充。改动面小，但引入**第二个必须保持同步的载体**
  （节点增删要同步维护表，与 `docs/spec/hir-contract.md` 的三方核验形成第四方）。
- **C：仅按需分格补**。只给控制流/可停点语句（`ifStmt`/`whileStmt`/`forInStmt`/`call`…）
  加位置——够 P4 的断点用，不足以做完整诊断。**最小面**，但「哪些节点该有位置」会成为
  一个持续扩大的特例清单。

**倾向**（供立项参考，非裁决）：A 与「HIR 后端无关契约」的定位一致，且避免 B 的多源同步
与 C 的特例蔓延；代价是一次大范围机械改动，宜与 P2 的某一格合并开工以摊薄。

## 不确定项（立项时须先查）

- 60 个节点类型的构造点数量与分布（`HIRLowerer` 4167 行），本单未统计。
- LLVM 侧是否存在「执行期错误需要位置」的同类缺口——本单只取证了 lowering 期。
- `HIRLoweringError.location` 是否已足够覆盖 emit 系命令（已有
  `docs/issue-emit-diagnostic-source-snippet-2026-09-10.md` 处理源码片段面）。

## 处置（2026-09-16，LR-4 P4-3 交付，**已闭环并归档**）

位置供给落地了，采用**选项 B 的一个变体**（块级平行数组），**不是立项时倾向的 A**。

**载体 = `HIRBlock`**：块从裸类型 `[HIRStmt]` 升级为一个值，含 `statements` 与**平行的
`positions`**。`positions` 由 `HIRLowerer.lowerBlock` **唯一填充** —— 那是「一个 `Block`
变成 HIR 语句」的唯一入口 —— 所以 B 所担心的「第二个必须保持同步的载体」**不存在**：
位置与语句是同**一个值**的两半（同构造、同传递），不是另立一张需要跟着节点增删维护的表。

**为什么不用 A（60 个节点各加位置字段）**：A 要改 60 个 case 定义、全部构造点，以及全部
模式匹配点（执行器 / LLVM 发射器 / 打印器 / 测试）；而且会让 `HIRStmt: Equatable` 的合成
把位置纳入比较 —— 既有的结构断言要么因此失败，要么得手写 `==` 把成本转嫁回来。B-variant
的改动面是它的一个零头，**提供的位置信息等价**（都是语句级）。

**精度与解释器同源**：位置记的就是 `Statement.location`，正是
`Interpreter.statementLocation` 读的同一个东西 ⇒「两引擎停在相同的行」是**构造上的事实**，
不是靠约定对齐。判据是 `DebuggerTests` 的「两引擎停在逐项相同的行上」用例。

**闭环**：暂停点接线在 `HIRExecutor.executeStatements`（与解释器同点、同上下文、同 `.quit`
契约）。休眠断言被**反转而非删除**：`HIRExecutorTests` 现在用两个用例分别钉住
「有位置 ⇒ 逐语句在该行暂停」（`testDebugHookPausesAtTheSourceLineOfEveryStatement`）
与「无位置 ⇒ 不暂停」（`testHandBuiltHIRWithoutPositionsIsNotPausedOn`）。

**残留（未做，不阻塞）**：本单 §证据 的注所提的「lowering 侧兜底位置」
（`HIRLoweringError` 之外那些退化成 `SourceLocation(line: 0, column: 0, fileName: "")` 的点）
仍原样；HIR **节点**依旧不带位置（LLVM 路径继续在 lowering 期报位置，这一点未变）。

## 不做范围（立项时）

**本单不修。** P1-2 已按「占位位置 + 明文登记」交付并验收（占位位置由测试断言钉住，
保证它不会静默变成「看起来有位置」）。开工需点名。

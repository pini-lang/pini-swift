# ADR-042: HIR 契约新增 `detachStmt` 节点（`detach` 的落点）

> **状态**：**active**（2026-09-17 用户裁决）｜**类别**：宿主级（HIR 契约；受 `ADR-034` 治理）
> **本件范围**：**`§1.3` 第 1–4 步同批交付**（提议 / 影响评估 / 登记 / 落地-规范面与节点面）。
> 第 5 步「证据登记」随本批完成（见「溯源」）。
> **第 3 步的「实现面」不在本件** —— 降载规则与两台引擎的行为留给格 `G-3c-1`，理由见 §4 D1。
> **前例**：`ADR-040`（`join` 节点面）——本件逐项照它的形态办，**并明确记下与它不同的一处**（§1 末）。

## 1. 提议（要解决什么）

`detach <expr>` 是语言里的一条**语句**（`detach-expr-stmt`，任务 #13 把 `detach` 从内建函数升格为关键字），
语义是「求值操作数得到一个 `Future` 值，把它从父任务**剪枝**，父返回时不再取消它」——
fire-and-forget 的**唯一**合法出口。但它在 HIR 里**没有落点**：`HIRStmt` 16 case 无 `detach`。

⚠️ **与 `ADR-040` 的关键不同，必须先说清**：`join` 那次是**兑现一个已登记的预留位**
（契约旧 §4.2 早已裁「`HIRLowerer` 须为 `.join` 增加节点面」），而 `detach` **从来没有预留位** ——
`§4` 的预留位当时**只剩 `char` 一条**。⇒ 这是**新增契约条目**，不是**实施既定条目**。
这个区别正是 `D-P4-26` 那条硬停条件（「迁移若须动契约那 60 个节点 ⇒ 停下先走 `spec §1.3`」）
**点名要拦**的形态，所以本件不是可选项。

**触发**：`G-3c` 开工前勘测（`docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md` §12.1）把 8 个并发目录
**83 条夹具逐条归类**，发现 **3 条**的首缺口是 `statement 'detach' is not yet lowered to HIR`，
而规划件的批次表**没有列它**。勘测把它列为两项待裁之一（`D-G3c-1`）。

**裁决**：用户 2026-09-17 取 **①（新增节点）**，**与勘测件的建议（② 降成既有 `call` 形状）相反**。
裁决理由（以裁决为准，此处如实转录）：`detach` 是**语言里的一条语句**，不是某个值的方法；
用 `call` 的按名形状承载它，会让契约语句表「**17 条 = 语言语句全集**」这条性质**悄悄失真** ——
而那条性质正是「有没有节点没被登记」这个问题的答案本身。

> 📌 **勘测件的建议段原样保留在载体里**，未改写 —— 它是「当时被建议了什么」的留痕，
> 与裁决不同**不是因为它错了**，而是因为权衡的两端（语义诚实 / 治理成本）由用户定权重。

## 2. 现状实测（动手前先量）

### 2.1 节点集与契约的实数（口径：`tools/hir-contract-check.py`）

| 面 | 改动前 | 改动后 |
|---|---|---|
| 契约条目 | 45 表达式 + 16 语句 = **61** | 45 + **17** = **62** |
| `HIRNode.swift` 节点集 | 45 + 16 = 61 | 45 + **17** = 62 |
| 锚点 `llvm` / `printer` / `interp-hir` | 各 61/61 | 各 **62/62** |

⚠️ **口径一律以核验脚本为准**（`ADR-040` §2.1 已吃过高频正则的亏：一次性正则跨过 enum 边界，
数出过不存在的 case）。

### 2.2 三锚点是**双向**核验 ⇒ 「契约行 + enum case + 三锚点」是门禁强制的**最小自洽单元**

中途态实测（只改代码、未改契约）：

```
contract: 45 expr + 16 stmt = 61 entries
code:     45 expr + 17 stmt = 62 cases
anchor llvm / printer / interp-hir  各 covers 62/62 nodes
FAIL: node-without-contract: detachStmt
```

⇒ 反向也成立（只改契约 ⇒ `contract-without-node` 立刻报红）。四件事**必须同批**，
这不是风格选择，是门禁强制的**最小自洽单元**。

### 2.3 代码面改动面（实测：编译器即探针）

在 `HIRNode.swift` 只加一个 case 后构建，编译器报出**恰好 3 处** `switch must be exhaustive`：

| 文件 | 行 | 函数 | 性质 |
|---|---|---|---|
| `Sources/PiniCore/HIR/HIRPrinter.swift` | 36 | `dumpStmt` | 打印 |
| `Sources/PiniCore/Interpreter/HIRExecutor.swift` | 1507 | `execute` | 执行 |
| `Sources/PiniCore/CodeGen/IREmitter.swift` | 560 | `emitStatement` | 发射 |

⭐ **比 `ADR-040` 那次少一处** —— 那次是 4 处（多一个 `IREmitter.hirType`），因为它加的是**表达式**节点，
而 `hirType` 只在表达式位被问；语句位没有对应的「语句类型」查询。⇒ **本批的锚点数少 1 是结构使然，不是漏做**。

⭐ **`HIRLowerer` 不在其列** —— 该文件对语句用的是一条 `default` 兜底。这意味着两件事：

1. **加节点不会替我们接上降载**：`HIRLowerer` 仍在原处兜底拒绝 `detach`
   （`statement '\(statement.kindName)' is not yet lowered to HIR`）；
2. ⇒ **语言可观察行为零变化**（见 §5.1），这是本批最要紧的保真条件。

### 2.4 两侧既有形态（决定各锚点怎么写）

| 锚点 | 既有形态 | 本批怎么写 |
|---|---|---|
| `interp-hir` | 全 61 节点**已实现**；「未实现者 fail loud、点名节点」的旧机制已随 `P2b G9` 撤除 | **fail-loud**（`RuntimeError.invalidOperation`），不静默 no-op |
| `llvm` | 自称「no unsupported paths」，未实现位一律 `fatalError(… HIRLowerer guarantees …)` | **fail-loud**（`fatalError`）——语义 = 「不该到达」 |
| `printer` | 纯渲染，无语义 | **真实现**（`detach <expr>`，逐字镜像源码形式） |

### 2.5 语义权威取自 AST 侧，不新定

`Interpreter.executeStatement` 的 `.detachStatement` 分支（`Sources/PiniCore/Interpreter/Interpreter.swift:1288`）：

```swift
let value = try evaluateExpression(expr)
guard case .future(let fut) = value else {
    throw RuntimeError.typeMismatch(
        expected: "Future<T, Error>", got: Interpreter.describeValueKind(value), location: detachLoc)
}
fut.detachFromParent()
```

两条被本件照抄的性质：

1. **操作数非 `Future` ⇒ 运行期类型不符**，不是降载期拒绝 —— 这是**运行时**的检查，
   静态层判不出（CPS 路径同形，见 `SuspendEvaluator.swift:617`）；
2. **剪枝是值层的一次调用**（`Value.detachFromParent()`），**不挂起、不产出值** ⇒ 语句位，
   且**不需要 `type`**（对照 `join(future:type:)` 要带 `type`，因为表达式位要钉站点结果类型）。

## 3. 影响评估（触及契约 ⇒ 依硬停条件走 `§1.3`）

**本件触及契约三处**：§0.4 计数基线、§3 语句表（新增第 17 行）、§6 待办汇总（新增一行）。
`D-P4-26` 的硬停条件写明「若须动那 60 个节点 ⇒ 停下走 §1.3」⇒ 本件即该流程的入口，
**并且本件正是它要拦的那一类**（新增条目，非兑现预留）。

### 3.1 签名：为什么是 `detachStmt(inner:)` 而不带 `type`

| 选择 | 判定 |
|---|---|
| 带 `type`（对照 `join`） | ❌ `join` 带 `type` 是因为**表达式位**产出 `Result<T>`、站点类型必须可查；`detach` 是**语句位**，不产出值 ⇒ 没有站点类型可钉 |
| 不带 `type` | ✅ 操作数类型在其**自身节点内**（typed tree）—— 与 `exprStmt` / `returnStmt` 同形 |

⚠️ **一个必须写明的边界**：**没有任何 `HIRType` case 表示 future**（`HIRType` 无 `future`）。
这不是本件引入的缺口 —— `ADR-040` §3.1 已就同一问题定过立场：**`Future` 是运行时值
（`Value.future`），不是 HIR 静态类型**。本件沿用，并把它登记为 `G-3c-1` 的前置（见 §6）。

### 3.2 稳定性分级与递交条件

| 项 | 判定 |
|---|---|
| 该构造的稳定性级别 | **Provisional**（并发面 `G12` 为 Stable，但 HIR 侧承载面首次落地） |
| `§1.3` 第 4 步「递交语言参考」**三条条件** | ①✅ Provisional ②❌ **实现侧证据不足**（降载与引擎行为均未落地）③✅ 无未裁决张力 |
| ⇒ 结论 | **本批不递交**（②不成立）。语言参考侧条款维持现状，待 `G-3c-1` 落地后随证据一并递交 |

### 3.3 爆炸半径

| 项 | 实数 |
|---|---|
| 契约条目 | +1（语句 16 → 17、合计 61 → 62） |
| `Sources/` 改动 | **3 处 switch、3 个文件**（§2.3 实测） |
| `HIRLowerer` 改动 | **0**（不接降载，见 §2.3 与 §4 D1） |
| 既有语料是否可观察到差异 | **否** —— `detach` 当前不可达（§5.1 实测） |
| 是否触及 `B 组缺陷`（规范已裁、实现偏离） | 否（本件不涉及字符串 / 切片面） |
| 是否递交语言参考 | 否（§3.2 条件②不成立） |

## 4. 决定

**新增 `HIRStmt.detachStmt(inner:)`；契约语句条目 16 → 17、合计 61 → 62。**

同批落地四件事，顺序不可拆：

1. **契约**：§0.4 计数基线 → 62（并记明**两条增量性质不同**：`join` 是兑现预留、`detachStmt` 是新裁）；
   §3 表头「16 条」→「17 条」、新增第 17 行；§6 待办汇总新增一行；
2. **节点面**：`Sources/PiniCore/HIR/HIRNode.swift` 加 case；
3. **三锚点**：按 §2.4 的形态补齐（两处 fail-loud + 一处真实现）；
4. **本件 + 台账**：本 ADR 与 `docs/spec/pini-spec-v0.md` §3 台账 `G64`。

### D1 —— 节点面**本批落地**，降载与引擎行为**留 `G-3c-1`**

**理由**（沿用 `ADR-040` D1 的同一把尺）：契约查的是**存在**不是**行为**
（核验脚本自述「existence, not behaviour」），且 §2.4 的 fail-loud 形态保证
「lowerer 若先接上、而引擎未跟上」会**报错而非算错**。

⚠️ **与 `ADR-040` 不同的一处，须说明**：`detach` 的**行为**其实**不难**实现
（就是 §2.5 那 6 行），但**本批仍然不实现**，理由只有一条 ——
**它今天不可达，因此不可验证**。写进去的代码没有任何测试能覆盖它，
其正确性只能靠读者相信；而 `G-3c-1` 会让它**可达**，那时同一个 6 行改动能拿到真证据。
⇒ 现在实现 = 制造一段**无法证伪的代码**，这与本仓「不拿低级证据冒充高级」的纪律相反。

### D2 —— 两处 fail-loud 而非静默 no-op

**理由**：`detach` 存在的意义是**压制一条泄漏警告**。若在这里静默 no-op，
「看起来像一条能用的 fire-and-forget 出口」——而那正是它要防的形态。
`HIRExecutor.swift` 头注已就同类问题表过态：
「A silent `.null` would have made this engine look finished and let the differential probes
compare against a fiction」。本批沿用该立场。

## 5. 后果与破坏性

### 5.1 破坏性判定：**非破坏**（语言可观察行为零变化）

| 面 | 本批前 | 本批后 | 判定 |
|---|---|---|---|
| `detach` 的降载 | 兜底拒绝（`not yet lowered`） | **不变**（`HIRLowerer` 未动） | 无变更 |
| 其余 61 节点行为 | — | 不变（三锚点只增一个不可达分支） | 无变更 |
| 契约计数 | 61 | 62 | 计数变更，非语义变更 |

**实测护栏**（本批执行，判据见 §5.2）：

| 项 | 读数 |
|---|---|
| 夹具面（8 个并发目录 83 夹具，逐条取首缺口） | 与勘测基线**逐条相同**：`detach 未降载` **仍 3 条**（节点面不接降载 ⇒ **预期不动**） |
| 全量回归（3 块） | **64 → 64，逐条集合相等**（无新增红） |
| `PINI_INTERP_ENGINE=ast` 方向 | 逐条相同（本批只动 HIR 侧） |
| 契约 | `clean`（**62/62** × 三锚点） |

⚠️ **本批的判据要说清一句**：`detach` 那 3 条**不该动** —— 若它们动了，说明节点面越界接了降载，
那才是事故。本批的正确读数是「**缺口数不变**」，不是「转绿」。

### 5.2 判据纪律（本仓已两次吃亏，此处预先声明）

1. **「备份 → 回退 → 恢复」必须逐步验证内容**（`grep` 关键字），不能只看命令退出码
   —— `ADR-040` §5.1 实测过「两侧跑的是同一版本」的假绿；
2. **二进制哈希不能当版本判据** —— Swift 产物不可复现构建，可靠依据只有**源码内容**。

## 6. 不在范围

- **不给 `HIRLowerer` 加 `detach` 降载规则** —— 加了会让节点从「不可达」变「可达而必失败」，
  行为**变差**（报错点从「未降载」变成「无引擎」），无收益。归 `G-3c-1`。
- **不实现两台引擎的行为**（见 §4 D1）。
- **不实现 `join` 的挂起语义、不动 `SuspendEvaluator`（890 行）与 `Interpreter` 的挂起状态**。
- **不给 `HIRType` 加 `future` case** —— 该问题属 `G-3c-1` 的异步管道（`ADR-040` §3.1 已定立场：
  `Future` 是运行时值）。⚠️ **本件把它登记为 `G-3c-1` 的前置之一**：
  `HIRFunction` 无异步标记、`HIRExecutor` 零异步面、且 `G-3b` 让**签名表**把异步函数的调用位类型
  报成 `Result`（而调用实际产出 `Future`）⇒ 这三件须在 `G-3c-1` 一并裁齐。
- **不做 `R2` 记号的统一订正**（见 `D-P4-30`）。
- **不递交语言参考**（§3.2 条件②不成立）。
- **不动 `join` 的 `§4.2` 兑现标记**（它是旧引用的追溯锚）。

## 7. 溯源

- **用户裁决**：2026-09-17 ——「`D-G3c-1` detach 要新节点」（即 §4 的 D1）。
  落位：`D-P4-33`（`docs/issue-hir-p4-plan-2026-09-16.md` 决策记录）；
  队列登记：`docs/issue-hir-blocker-queue-2026-09-17.md` §2 的 `D-G3c-1` ✅ 行。
- **触发面**：格 `G-3c` 的开工前勘测（`docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md` §12.1；
  83 条夹具逐条归类，报出 3 条 `detach` 缺口 ⊂ 59 条首缺口面）。
- **语义依据**：`Sources/PiniCore/Interpreter/Interpreter.swift:1288`（AST 侧权威）；
  `Sources/PiniCore/Interpreter/SuspendEvaluator.swift:617`（CPS 路径同形）；
  `Sources/PiniCore/Interpreter/Value.swift`（`detachFromParent`）。
- **相关登记**：`docs/spec/pini-spec-v0.md` §3 台账 **`G64`**；契约 §0.4（计数）· §3.17（新条目）· §6（待办）；
  `ADR-034`（契约治理）、`ADR-040`（`join` 节点面，前例）、`ADR-012`（`await` / `wait` 术语）。
- **证据**：机制面 = `tools/hir-contract-check.py`（本批实测 `clean`，62 条目 / 三锚点 62/62；
  中途态实测 `FAIL: node-without-contract: detachStmt`）；改动面 = 编译器报错定位（§2.3）；
  保真面 = 夹具面缺口数不变 + 全量回归逐条集合相等（§5.1）。
  证据表登记见本批提交（`docs/spec/evidence-table.toml`）。

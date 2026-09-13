# Issue：E7-001 假阳性 —— 仅经成员调用使用的变量被报「未使用」

- 状态：**Closed / LANDED（2026-09-12 立案 → 同日 E1+E3 验证根因 → 同日实施并回归；2026-09-13 工单整理批核验归档，证据 E-161。落地证据：成员调用接收者分支 + 双测试，见下「处置」节）**
- 层级：**宿主级** —— 诊断实现的假阳性，非语言契约变更（层级判据见 `ADR-024 D6`；
  目录约定见 `docs/README.md`）
- 发现来源：P0 审计的 E3 实测顺带观察
  （`docs/issue-interpreter-hir-gap-audit-2026-09-12.md` §7.4 观察 1）
- 关联：`docs/spec/diagnostic-codes.md`（E7-001 定义；注意该表自述「权威以
  `Sources/PiniCore/Resources/Diagnostics.{en,zh}.toml` 为准」）；
  `docs/issue-diagnostic-channel-parity-2026-09-12.md`（**另一回事**：那条工单管
  「警告写 stderr / LLVM 通道静默」的**通道**问题，与本报的**假阳性**不同根因，勿混）

## 现象（E3 实测，2026-09-12）

P0 的 M0–M8 夹具实测中，下列形态**均报** E7-001（而变量**确实被使用**）：

```
Warning: 语义警告 [E7-001] 未使用的变量 's'
```

| 夹具 | 变量 `s` 的实际用法 | 误报？ |
|---|---|---|
| M0 / M1 / M2 | `s.substring(...)` | ❌ **误报** |
| M3 | `s.upper()` / `.lower()` | ❌ **误报** |
| M5 | `s.split(",")` | ❌ **误报** |
| M4 | `s[1:3]` / `len(s)` | ✅ 未误报 |
| M6 / M7 | `len(s)` / `s[1:3]` | ✅ 未误报 |

## 可疑根因（**未经验证，仅登记为假设**）

形态差异恰好落在「**成员调用** vs **下标 / 内建实参**」：

- **误报组**：变量**只**出现在**成员方法调用的接收者**位置（`s.method(...)`）
- **正常组**：变量出现在下标（`s[i]`）或作为内建函数实参（`len(s)`）

⇒ **疑为**「成员调用的接收者未被计为『使用』」。

⚠️ **该推断未经代码验证**。按证据三级制，它属「E3 观察 + 未追的 E1 假设」，
**不得当作结论使用**（P0 审计原文即写「疑为」）。定位前勿据此设计修复。

## 根因（已验证，2026-09-12；证据级 = E1 代码结构 + E3 实测）

上述假设**成立**。定位到唯一一处代码缺口，`Sources/PiniCore/Semantic/SemanticAnalyzer.swift`：

```swift
// :741
case .call(let callee, let arguments, _):
  if case .identifier(let name, let location) = callee {          // ① 只处理 callee 是裸标识符
    try requireDefined(name, location, isFunction: true)
  }
  if case .member(let objExpr, let memberName, _) = callee,
    case .identifier(let aliasName, let aliasLoc) = objExpr,
    let info = importAliasInfos[aliasName] { ... }                // ② 只处理「别名.符号(...)」跨模块
  for arg in arguments {                                          // ③ 只检查实参
    try checkExpression(arg.expression)
  }
```

`words.join("-")` 的 `callee` 是 `.member(.identifier("words"), "join", ·)`：① 不匹配、② 因
`importAliasInfos["words"] == nil` 不匹配、③ 只走实参 ⇒ **接收者 `words` 从未被送入
`checkExpression`**。链条如下：

| 环节 | 落点 | 事实 |
|---|---|---|
| 唯一的「使用」登记点 | `:230`（`requireDefined` 解析命中时 `usedSymbols.insert(name)`）；另一处为 `:503`（capture 即引用） | 不调用 `requireDefined` ⇒ 不登记 |
| 断定点 | `:698 emitUnusedWarnings()`，由 `checkBlock` 的 `defer` 在块作用域退出时调用 | 读 `usedSymbols` 判未使用 |
| **对照分支（证明了缺口而非通例）** | `:759 case .member(let object, _, _):` 对非别名 base **有** `try checkExpression(object)` | 同类对象检查在别处存在，仅 `.call` 分支缺失 |

**实测判据（P1-4 顺带取得，2026-09-12）**：

| 夹具 | 结果 |
|---|---|
| `var words = ["a", "b"]` + `print(words)` | **不报**（变量作为内建实参 → 走 ③） |
| `var words = ["a", "b"]` + `print(words.join("-"))` | **报 E7-001**，而程序正确打印 `a-b` ⇒ 误报 |

后者即本单最小复现（三行）。同时解释了本单上表的「正常组」：
`s[1:3]` 走 `case .subscript(container, …)` 的 `checkExpression(container)`；
`len(s)` 里 `s` 是实参，且 `len` 是裸标识符 callee。

**与 `docs/issue-diagnostic-channel-parity-2026-09-12.md` 仍不同根因**：那一条管
「警告写 stderr / LLVM 通道静默」的**通道**面；本条的成因是**使用计数漏登记**，与通道无关。
（但两者会**叠加**成探针侧的假阻塞，见该单新增的「对探针判据的后果」节。）

## 影响

- **不改变程序行为**，属**诊断质量**问题：噪声会训练用户忽略警告，进而漏掉**真**警告。
- **与 HIR 无关**（P0 审计已判定）：两条通道共用同一检查阶段，故不是后端差异。

## 待验证项

1. ✅ **已完成**（2026-09-12）：`E7-001` 产生处 = 语义检查阶段
   `SemanticAnalyzer.emitUnusedWarnings()`；**不在** `IREmitter`，也**不在** HIR。
2. ✅ **已完成**（2026-09-12）：登记路径 = `requireDefined` 行 230 的 `usedSymbols.insert`；
   判定结论 = **「成员调用分派漏登记接收者」**（非更上层的通用缺陷）——见「根因（已验证）」节。
3. ✅ **已完成**（2026-09-12）：阳性对照已补 —— 见「处置」节的**三组对照表**。做法比原计划
   更强：除「纯未使用仍报」外，另加**可达性对照**（未定义接收者必须报 E3-001），
   用于排除「靠跳过检查路径消除误报」这种假修。本单上表的「正常组」由全量回归覆盖
   （1234 / 3 skipped / 0 failures）。

## 处置（**已于 2026-09-12 实施**）

> **本节初稿写「本工单只登记，不实施」**（P0 收口期的缺陷记录，非该批修复项）。
> 该处置已按**用户 2026-09-12 的点名**改变：「登记不修项中**形成阻塞或工作量小**者即修」。
> 本单满足**工作量小**（单点改动、机械可验）；判据原文见
> `docs/issue-interpreter-hir-plan-2026-09-12.md` 的治理循环节。

### 实施（2026-09-12）

- **改动**：`Sources/PiniCore/Semantic/SemanticAnalyzer.swift` 的 `.call` 分支 ——
  在「别名限定调用」判断之后追加 `else if case .member(let receiver, _, _) = callee`
  分支，令**非限定**接收者走 `checkExpression(receiver)`。
- **归属问题就此消解**：初稿担心的「接收者检查该补 `checkExpression` 还是另走一条解析路径」
  有现成答案 —— **与既有 `.member` 独立表达式分支同构**，不引入新路径、不新增判据来源。
- **对既有告警面的影响**：只把接收者送进既有检查 ⇒ 只会**让原本误报的消失**，
  并让**原本漏报的未定义接收者显形**（即下表第三组）。全量回归无新增失败。

| 组 | 形态 | 修复前 | 修复后 |
|---|---|---|---|
| 缺陷 | `print(words.join("-"))` | 报 E7-001（但程序正确打印 `a-b-c`） | **通过** |
| 阴性对照 | 变量确实未用（`print("hello")`） | 报 E7-001 | **仍报 E7-001** |
| 可达性对照 | `print(nosuchvar.join("-"))` | 不报 | **报 E3-001，位置指向接收者（列 11）** |

- **测试钉住**：`Tests/PiniTests/SuggestionTests/SuggestionTests.swift` 新增
  `testMethodCallReceiverCountsAsUse`（正向）与 `testMethodCallReceiverIsChecked`（反向），
  两份 `.pini` 夹具置于同目录。**全量回归 1234 / 3 skipped / 0 failures**（2026-09-12）。
- **未覆盖面（登记不修）**：`.member` **独立表达式**分支同样只在 base 是 `identifier`
  且非模块别名时才递归 —— `a.b().c` 这一形态里 `a` 不被登记，属**同类第二面**。
  本次**未实证复现、未修改**（避免为未观测形态预判式修复）；一旦有实测复现即并入本单。

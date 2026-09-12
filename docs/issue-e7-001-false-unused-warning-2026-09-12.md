# Issue：E7-001 假阳性 —— 仅经成员调用使用的变量被报「未使用」

- 状态：**Open（2026-09-12 立案；P0 收口期登记；**根因已于同日经代码级证据验证**
  ——见下「根因（已验证）」节；**仍未实施**）**
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
3. ⬜ **仍待**（开工第一步）：阳性对照 —— 编一例**纯未使用**变量，确认修复前后**仍报**
   （避免把假阳性修成漏报）。另需回归本单上表的「正常组」保持不报。

## 处置（未裁）

**本工单只登记，不实施**（P0 收口期的缺陷记录，非本批修复项）。
实施时应含回归：上表「误报组」必须不再报、「正常组」保持不报、纯未使用仍报，三者同时成立。

**根因验证不改变处置**：定位完成不代表可当场修 —— 修 `:741` 需决定「接收者检查」的
归属（是补 `checkExpression(objExpr)` 还是走另一条解析路径），且要评估对既有语料
告警面的影响，属独立一格的活。**开工需点名。**

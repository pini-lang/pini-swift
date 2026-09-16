# P4-2 勘测 · 翻转前置核对（翻转后的行为变更面）

> 状态：**已交付**（2026-09-16；**勘测批，不改源码**）
> 对象：**把「翻转后行为会变的夹具面」从推断变成实测清单** —— 即 P4 分批表给本批的那条
> 「类型检查面不对等」，以及围绕它的整个单文件夹具面。
> 上游：`docs/issue-hir-p4-plan-2026-09-16.md` 的 `P4-2` 行；口径出处 = 主计划里
> 「763 个解释器用例」（那是指**直接驱动解释器的 66 个测试文件 / 763 个用例**，本批实测现为 **66 文件 / 796 用例**）。

## 1. 为什么需要这一批（一句话）

P4 翻转后**默认引擎改变**，于是「同一个程序在两条引擎下的行为是否一致」从**开发期的对照**
变成**用户可见的语义**。此前只有两把尺在量它，而两把尺都看不全（见 §3）。

## 2. 面的量（实测，2026-09-16，`4379710`）

| 项 | 数 |
|---|---|
| `.pini` 夹具总数 | **1005** |
| —— 包成员（位于含清单的目录下） | 33 |
| —— **单文件面**（本批的核对对象） | **972** |
| 测试 `.swift` 文件 | 120 |
| —— **直接驱动 `Interpreter(` 的文件** | **66** |
| —— 这些文件里的 `func test` 数 | **796**（主计划当时记 763） |
| 直接驱动 `HIRExecutor(` 的文件 | **2**（执行器自身单测 + 调试测试） |

⇒ 翻转的**测试改造面**是那 66 个文件；**行为核对面**是 972 个单文件夹具。

## 3. 两把尺，都看不全（**本批的头号发现**）

| 尺 | 覆盖面 | 读数 | 盲区 |
|---|---|---|---|
| **全量探针**（`tools/hir-parity-probe.py`） | **6 根精选语料**（`IRExecutionTests` / `RuntimeBackendTests` / `OptionalTests` / `IRPrintGoldenTests` / `CodeGen/HIRTests` / `examples`），319 夹具 | `FLIP BLOCKERS 0` | **不含**并发 · CPS · 内建 · 挂起 · 结果解包 · 泛型等目录 —— 而差异**恰恰集中在那里** |
| **`PINI_INTERP_ENGINE=hir` 全量回归** | 全部测试 | 1269 / **0 failures** | 环境变量**只影响 CLI 子进程**；那 796 个**进程内**用例不读它 ⇒ **翻转面根本没被这轮跑过** |

⇒ **两把尺都不构成「翻转后不会变」的证明。** 本批补的第三把尺见 §4。

## 4. 实测：972 个单文件夹具的双引擎对比

方法：对每个单文件夹具跑 `pini run <file>`（默认引擎）与 `PINI_INTERP_ENGINE=hir pini run <file>`，
比较 `rc` / `stdout` / `stderr`。

| 结果 | 数 |
|---|---|
| 两引擎逐项相同 | **786** |
| **差异** | **186**（19.1%） |

**差异按 hir 侧真正的 `Error` 行分类**（⚠️ 取错误码时**不能看 stderr 首行** —— 多数首行是 `E7-001` 未使用变量一类的**警告**，真因在其后）：

| 类别 | 数 | 归属 |
|---|---|---|
| **`E6-004`** 降载层未实现 | **125** | **未实现面**（并发 / 挂起 / 泛型 / 内建等）⇒ 见 §5.2 |
| **`E4` 族**（类型检查） | **48** | **本批对象** ⇒ §5.1 |
| 反向：仅 AST 被拒（`E5-006` / `E5-017`） | 7 | HIR 侧缺门禁 ⇒ §5.3 |
| AST 侧 Swift 崩溃（`ast=-5`，`Index out of range`） | 2 | AST 侧健壮性 ⇒ §5.4 |
| 同 `rc=0` 但 `stdout` 差 1 字节 | 2 | 值展示 / override ⇒ §5.5 |

**`E4` 族的分解**：`E4-001` 39 · `E4-013` 4 · `E4-005` 4 · `E4-006` 2 · `E4-007` 2 · `E4-008` 1。

## 5. 逐条处置

### 5.1 类型检查面不对等（48 个夹具）—— **本批的正题**

**形态**（最小可复现，实测三例，均 `ast rc=0` / `hir rc=1 E4-001`）：

| 程序 | AST | HIR |
|---|---|---|
| `var x: I32 = "str"` 后 `print(x)` | rc=0，**输出 `str`** | rc=1（`E4-001`）|
| 传错参数类型 `取整("字符串")` | rc=0，**输出 `字符串`** | rc=1 |
| 返回类型不符 `return "字符串"`（声明 `I32`） | rc=0，**输出 `字符串`** | rc=1 |

**根因**：HIR 降载**需要** checker 的推断结果 ⇒ HIR 单文件路径**必须跑类型检查**；
而 AST 单文件路径只跑语义门禁（既有口径，不是本系列引入的）。

**48 个里区分正/负向**（负向 = 夹具本身故意带类型错误、测试期望被拒）：

- **`E4-001` 的 39 个**：命名含 `Mismatch` / `Rejected` / `TypeChecked` / `IsEnforced` 等负向词的 **26 个**
  ⇒ **不是回退面**（它们本就在验证「被拒」，翻转后只会更贴合）；
  **其余 13 个需人工判**（清单见 §6）。
- 其余 `E4-0xx` 的 9 个同法需判。

⇒ **处置**：翻转时**按 HIR 语义走**（单文件也跑 checker），并把「带类型错误的程序由『可运行』
变为『被拒』」作为**用户可见语义变更**登记（release note / 规范），而非缺陷。
⚠️ §6 那 13 个**必须先逐个核对**：若其中确有「测试期望它跑通」的正向用例，则要么改用例、
要么该夹具的写法需要修正 —— **不得在翻转时静默变红**。

### 5.2 降载层未实现（125 个夹具）—— **不由本批承接**

按目录集中在：`ConcurrencyTests` 17 · `CPSDifferentialTests` 14 · `BuiltinFunctionTests` 10 ·
`SuspendRuntimeTests` 8 · `TryExceptTests` 8 · `examples` 8 · `JoinAllTests` 7 ·
`StructuredConcurrencyTests` 7 · `TaskIsolationTests` 7 · `JoinWithinTests` 6 · `CancellationTests` 5 …

⇒ 大头是**并发 / 挂起（CPS）族**。**它的性质是能力取舍**：翻转后这些程序在 HIR 下不可用，
而它们在 AST 下可用 —— 这正是 `P4-6`（R1/R2 取舍）在册的那件事。
**本批把它的量从抽象取舍变成具体数字：125 个夹具**，供该批决策时使用。
**不并入本批**（属未实现面，不是核对面）。

### 5.3 反向：仅 AST 被拒（7 个）—— 两处 HIR 侧门禁缺口

| 夹具 | AST | HIR | 说明 |
|---|---|---|---|
| `AmbiguousCaseResolutionTests` / `DotCaseConstructionTests` / `IRExecutionTests` 的 5 个裸 case 歧义用例 | rc=1（`E5-006`） | **rc=0** | HIR 侧**不报**该歧义 |
| `FFIModuleTests` / `FFITests` 的 2 个「未定义外部符号」用例 | rc=1（`E5-017`） | **rc=0** | HIR 侧**不报**未定义外部符号 |

⇒ **HIR 侧缺门禁**：翻转后这两类错误会**静默消失**（程序照跑）。属**行为放宽**，
须登记并逐条处置（补门禁 / 改用例）。⚠️ 与 P4-0 的「declared-foreign 门」同族。

### 5.4 AST 侧 CLI 崩溃（2 个，`ast=-5`）

`BuiltinMemberValidationTests/testArgumentC…` 与 `CallSiteValidationTests/testArgumentCountT…`：
AST 引擎经 **CLI** 跑这两个**负向**夹具时 **Swift 运行期崩溃**（`ContiguousArrayBuffer: Index out of range`），
而 HIR 侧正常拒绝（`E4-005`）。

⇒ 这是 **AST 侧的健壮性缺陷**（负向输入未走成诊断而走成崩溃）。**按末态退役口径不修**（AST 将删除），
但**登记在案**；若翻转前仍有用户路径经 CLI 触达，则该崩溃会随 AST 一并消失（**不是**回退）。

### 5.5 同 `rc=0` 但输出差 1 字节（2 个）

`BuiltinOverrideTests` 的两个用例（`String.contains` 被 override / 未 override）。
⇒ **值展示或方法解析的细节差异**，须逐条核对（影响用户可见输出）。**登记，不在本批修**。

## 6. 需人工判定的 13 个（`E4-001` 里非负向命名的夹具）

```
CPSDifferentialTests/testDiffCallChain
CodeGen/IRExecutionTests/testAsyncFunction_LLI
CodeGen/IRExecutionTests/testAsyncVsSyncParity_LLI
CodeGen/IRExecutionTests/testAwaitConsumption_LLI
ConcurrencyTests/testAsyncFuncLiteralViaJoin
GrammarConsistencyTests/testBackfillForceUnwrap
ParenEqualsTests/testEnumNamedConstructionUsesEquals
ReturnTypeConsistencyTests/testBareReturnInBranchOfNonVoidFunction
ReturnTypeConsistencyTests/testBareReturnInNonVoidFunction
StdlibTests/testMathAbs
SuspendRuntimeTests/testSyncCallChainSuspendResumesExactly
SymbolDisambiguationTests/testDoubleArrowMarksFuncAsync
TypeCheckerTests/testCheckForeignCallRequiresUnsafeContext
```

⇒ **这 13 个是「翻转后可能转红」的主要嫌疑**，须在 P4 开工时逐个核对（判据：该夹具的测试**期望它跑通**吗）。

## 7. 复现方式（本批的器械留在 `/tmp`，判据可重放）

| 产物 | 内容 |
|---|---|
| `/tmp/p4_2_face.py` | 972 夹具 × 2 引擎的全量对比（~30s）|
| `/tmp/p42-singlefile-face.tsv` | 原始结果（972 行）|
| `/tmp/p4_2_reclass.py` | 按 hir 侧**真正 Error 行**重分类（**不要用首行**）|
| `/tmp/p42-diff-classified.tsv` | 186 个差异的定类结果 |

⚠️ **两条器械纪律**（本批踩到并记下）：① 判「两引擎是否相同」时**必须把 stderr 计入**，
但**取错误码时不能用首行** —— 警告会盖住真因；② 单文件面的分母是 **972**，
而探针的分母是 **319**，**两个数不可互换陈述**。

## 8. 不做范围

不改源码 · 不改测试 · 不补 HIR 门禁（§5.3）· 不修 AST 崩溃（§5.4，末态退役口径）·
不动并发/挂起未实现面（§5.2，属 `P4-6` 与后续批）· 未 push。

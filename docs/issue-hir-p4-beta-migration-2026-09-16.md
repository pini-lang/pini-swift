# P4-β 交付记录：测试面迁移到 HIR 驱动

> **批**：`P4-β`（P4 本体第二批）｜**日期**：2026-09-16｜**状态**：✅ 已交付
> **上游**：分批表 `docs/issue-hir-p4-plan-2026-09-16.md` §3.2（P4-β 行 + `D-P4-21`…`D-P4-24`）
> **前置**：`P4-α` ✅（默认引擎已切 HIR）

本件是**交付记录 + 红数台账**。红数部分不是「遗留问题清单」，而是
**`P4-γ` 前置裁决 `R1/R2` 的实证输入**（分批表写明 P4-β 的唯一目的是「把抽象取舍变成具体数字」）。

---

## 1. 本批的对象：为什么「测试面迁移」不是一次批量改名

`P4-γ` 要删掉 AST 走查（`Interpreter.swift` 3783 行 + `SuspendEvaluator.swift` 890 行）。
在此之前，**测试套件仍钉在走查上**：67 个测试文件、798 个用例经 `Interpreter` 跑程序。
不改它们，删走查就等于把套件一起删掉——包括「HIR 引擎能跑真实程序」这件事**唯一的大面积证据**
（探针只覆盖 319 个精选夹具，见 `P4-2` 勘测件）。

⇒ 本批把**可以迁的那些**改成驱动 HIR，并把**不能迁的那些**连同原因做成清单。

### 1.1 面的四分类（实测，不是估算）

| 类 | 判据 | 文件 | 用例 | 本批处置 |
|---|---|:---:|:---:|---|
| **A 可迁** | 只驱动 `Interpreter` 做执行；无 HIR 侧用法、无挂起内部 API、无 `runTests` | **50** | **429** | ✅ **迁移** |
| **B 挂起/并发内部 API** | 用 `suspendMode` / `scheduler` / `runSuspendable` / `prepareSuspend` / `runSuspendableEntry` / `checkCancellation` / `joinFuture` / `mainFunctionValue` | 3 | 43 | 保持驱动 `Interpreter`（**R1/R2 的对象**）|
| **C `runTests`** | 用 `runTests` / `TestRunResult`（测试块驱动） | 4 | 23 | 保持（HIR 侧无对应入口）|
| **D 对照臂** | **把 `Interpreter` 当参照臂**（同时驱动 HIR 侧或 LLVM 侧） | **9** | **303** | ⛔ **刻意不迁**（见 §1.2）|

合计 66 文件 / 798 用例；第 67 个文件（`ReplEvaluatorTests.swift`）是分类器的**假阳性**
（它含的 `Interpreter(` 在一条历史注释里，本身不驱动解释器），已剔除。

### 1.2 ⛔ D 类：迁了会让判据**失明**

这 9 个文件的 303 个用例，其结构就是「同一程序跑两个引擎、断言结果相同」：

| 文件 | 用例 | 参照臂是什么 |
|---|:---:|---|
| `HIRDifferentialTests` | 89 | AST 臂 vs HIR 臂 |
| `IRExecutionTests` | 81 | `Interpreter` 臂 vs LLVM 臂 |
| `RuntimeBackendTests` | 51 | `runViaInterpreter` 臂 vs 后端臂 |
| `HIRExecutorTests` | 30 | `Interpreter` 臂作 HIR 执行器的对照 |
| `OptionalTests` | 20 | 含 HIR 降载对照 |
| `DebuggerTests` | 17 | 双引擎参数化（`P4-3` 所建）|
| `DotCaseConstructionTests` · `BuiltinOverrideTests` · `IRPrintGoldenTests` | 15 | 含降载对照 |

⇒ 若把这 303 个用例的 `Interpreter` 也换成新入口，**两侧都成 HIR**，对照恒真 ⇒ **全部变成假绿**。

这类风险与 `P4-2` 的「两把尺都看不全」同族：**判据可能在改动中被无声地掏空**。
所以判据不能写成「凡用 `Interpreter` 的都换成新入口」，必须按**它在文件里扮什么角色**分。

⚠️ **同时这也是 `P4-γ` 的又一块代价**（本批量出，登记）：
删掉走查后，这 **303 个对照用例的参照臂消失** ⇒ 它们要么重写（改用别的参照物）、
要么随走查一起退役。**不能用「反正会删」一句话带过**——它们目前是差分证据的主体。

---

## 2. 交付

### 2.1 新件：`Sources/PiniCore/Run/ProgramRunner.swift`

引擎无关的「跑一个程序/包」入口，形状照抄调用方**实际用到**的那一小片：

| 成员 | 说明 |
|---|---|
| `init(ffiConfig:programBase:)` | 与 `Interpreter` 同签名，调用方零改构造形态 |
| `outputSink` · `debugHook` · `processArguments` · `entryFiles` | 四个调用方会设的钩子 |
| `run(module:)` · `run(package:)` | 同签名 |

内部是 **`check → lower → execute`**：`TypeChecker` + `HIRLowerer`（**与 CLI 其他 HIR 路径同一份**）
→ `HIRExecutor`。前端不新写第二份，所以这是迁移而不是第二个实现。

**两处对等职责**（迁移引入，本批修）：

1. **入口一致性门禁走两条路径** —— 原 `Interpreter` 在单模块**与**包两条路径都调
   `checkEntryConsistency`；首版只做了单模块，实测被 `testEntryMismatchThrowsDiagnosticError` 抓住
   ⇒ 补包路径（搜遍 `fileUnits` 找 `main` 声明位置）。
2. **「无 main」的错误类型对齐** —— 两个引擎遇同一条件**阶段不同**：AST 在**运行期**抛
   `RuntimeError.mainNotFound`；降载器在 **lower 期**就拒绝（它要产出一个可执行程序）。
   ⇒ 在入口按**条件**问「模块里有没有 `main`」（`D-P4-20` 的同一处置），不捕获后匹配错误消息。
   `HIRExecutor` 自己也会抛这个错误，但走不到那里。

**顺序**：`requireMain` 放在**类型检查之后**——AST 路径是「声明注册（含各种声明级检查）→ 最终
`mainNotFound`」，放在最前会让「没有 main」**遮蔽**程序真实的类型错误。

**一处刻意的保留**：`ffiConfig` 字段保留了形状但**本路径不消费**（HIR 引擎经自己的内建表解析
foreign 调用，无动态库加载）。不静默丢弃而是留字段 + 注释 + 本条登记：
**「调用方传了会被静默忽略的配置」正是值得命名的失败形态**。

### 2.2 迁移面

50 个文件、**62 处** `Interpreter(` → `ProgramRunner(`，另 9 处描述驱动链路的注释同步改指。
改动 `+74 −71`；`git diff -w` 行数**相同**（无纯空白 churn）。

**未改**：`ReplEvaluator` 的 `.hir` 分支与 CLI 的两处 HIR 装配仍是各自一份
⇒ 与 `ProgramRunner` 存在三份同构逻辑。抽单源登记为 **`P4-γ` 的整合项**
（那时 `Interpreter` 要删、`ReplEvaluator` 的 `.ast` 分支要删，正好一并收）。

---

## 3. 判据（全部现跑）

| 判据 | 读数 |
|---|---|
| 编译 | `swift build --build-tests` **0 error**（接口形状与迁移面完全吻合，无需改调用方）|
| **迁移面已驱动 HIR** | 50 文件 / **429 用例**经 `ProgramRunner` 跑（62 处构造）|
| **未迁移面零位移** | 84 个失败**全部落在迁移文件内**；B / C / D 三类 **0 失败** |
| **默认方向全量回归** | **84 failures** |
| **`PINI_INTERP_ENGINE=ast` 方向** | **84 failures，失败集合与默认方向完全相同**（双向差集为空）⇒ 迁移后的测试**不读环境变量**，引擎由构造类型决定 ⇒ **迁移是真实的，不是靠默认开关** |
| 全量探针 | 六槽 254 / 27 / 12 / 2 / 20 / 4 = 319 · `FLIP BLOCKERS 0` · 与 `P4-0` 冻结件 **`cmp` 逐字节相同**（md5 `84deca2f…`，**连续第五批同值**）⇒ 对单文件面零位移 |
| 进程残留 | `lli --dlopen` 残留 **0** |

⚠️ **上游给 P4-β 的验收是「迁移后全量回归 0 failures」——该判据按实测不可达**（见 §4）。
按 `P4-1a` 的同一处置，本轮把它订正为可测形式：**「已迁面全部驱动 HIR ∧ 未迁面零位移 ∧ 残余逐条归因」**
（`D-P4-22`）。这不降低标准：不可达的绿数若被当成目标，就会诱导「把测试改松」而不是「把缺口记账」。

---

## 4. 红数台账（84 条，两组切面）

### 4.1 按失败机制

| 机制 | 数 | 说明 |
|---|:---:|---|
| **降载层未实现** | **73** | `E6-004` 族：`later grids` 34 · other 15 · async/Result 形状 12 · `is not yet lowered` 12 |
| **类型检查不对等** | **7** | `ProgramRunError.typeCheck`（`E4-001/012`）—— `P4-2` 已登记的**行为变更**，非缺陷 |
| **其他** | **4** | 见 §4.3 |

### 4.2 按语言特性簇（`R1/R2` 的输入形态）

| 簇 | 数 | 属 R2（弃并发）可消？ |
|---|:---:|:---:|
| **C1 并发 / 异步 / 任务**（`join` · `'ok'` 构造 · `sleep` · `CancelError` · `Error` · `joinAll` · `joinWithin` · 取消） | **33** | ✅ **这才是 R2 的对象** |
| C2 内建字符串 / 字符 / 数值函数（`chars` · `chr` · `ord` · `is_letter` · `is_number` · `len on i32` · `print` 无参） | 11 | ❌ |
| C5 集合方法（`append` · `last` · `.get` · 字典字面量） | 8 | ❌ |
| C3 一元运算符（`plus` · `increment` · `decrement` · `bitwiseNot`） | 6 | ❌ |
| C6 泛型枚举 / 泛型（`associated value '?' lacks a resolvable type` · `unknown generic`） | 5 | ❌ |
| C7 跨模块 / 未解析符号（`reference to undeclared variable`） | 5 | ❌ |
| C8 类型检查不对等 | 5 | ❌（行为变更，不是能力）|
| C4 作用域块 / `defer`（`statement 'scoped block' is not yet lowered`） | 3 | ❌ |
| C9 `try-else` 只能用语句/变量位置 | 1 | ❌ |
| C10 数组元素标注（`non-scalar annotation`） | 1 | ❌ |
| C11 深度护栏**文案**（两引擎**都拦住了**，`reason` 措辞不同） | 1 | ❌ |
| C12 声明级检查缺失（`引用块不可组合` 只在 `Interpreter.swift:964`，HIR 无对应 + `requireMain` 抢先） | 1 | ❌ |
| C13 降载期类型不符（`type mismatch: string is not i32`） | 1 | ❌ |
| C14 其他 | 3 | ❌ |

### 4.3 「其他」四条已逐条定性

| 用例 | 形态 |
|---|---|
| `FFITests.testUndefinedNativeFunctionRejected` | 期望「未注册原生函数」运行时报错；HIR 侧无动态库配置消费点（与 §2.1 的 `ffiConfig` 保留同一件事）|
| `LazyRefTests.testLazyRefNonFunctionArgFails` | 期望 `RuntimeError`；两侧拒绝**时机/类型**不同 |
| `ResultUnwrapTests.testErrStopsFunctionBody` | 降载层 `try-else` 位置限制 |
| `ParserRestructureTests.testBracketObjectNotComposable` | 期望 AST 走查内部的声明级检查（C12）|

---

## 5. ⭐ 给 `R1/R2` 的结论（本批最重要的产出）

上游把 `R1/R2` 描述为「保能力 ⇒ 迁 CPS；不保 ⇒ 能力消失」，读起来像**二选一**。数字说不是：

- **R2（弃掉并发面）最多只能消掉 33 / 84（39%）。**
- 其余 **51 条属基础语言面**：一元运算符、内建字符/字符串函数、集合方法、作用域块/`defer`、
  泛型枚举、跨模块符号解析、类型检查不对等。
  ⇒ **这些没有「弃掉」这个选项**：它们是语言基础能力，弃掉就是语言回退，而不是「砍掉一个特性面」。
  ⇒ 它们**只能实现**（R1 的对应物，但不属 `R2` 的取舍语境）。

**因此**：`P4-γ` 的闸门不止 `R1/R2`。删走查之前必须先把那 51 条所属的降载面补齐，
否则「翻转完成」的代价不是「少一个并发特性」，而是**基础语言面大面积回退**。

⚠️ 本批**不为这 84 条立项**：它们是同一根因簇（HIR 降载层覆盖面），逐条开局单会把
一次「补降载面」的规划拆成 84 张纸片——正是「连续修复致规模膨胀」的入口。
它们的户口在 §4.2 这张表里，按簇归入 `P4-γ` 前置规划。

---

## 6. 本批未做（登记，不修）

| 项 | 归属 |
|---|---|
| B 类 43 用例（挂起/并发内部 API） | `R1/R2` 裁决（`P4-6`）|
| C 类 23 用例（`runTests`） | HIR 侧无对应入口 ⇒ 需新批或随走查处置 |
| D 类 303 用例的参照臂 | `P4-γ`（删走查后必须处置，见 §1.2）|
| C11 深度护栏 `reason` 文案对齐 | 改的是**用户可见**报错文本 ⇒ 需裁决，不在本批 |
| C8/C13 的错误类型与时机对齐 | 与 `D-P4-20` 同族，跨引擎对等面 |
| `ffiConfig` 的 HIR 消费点 | 与 §2.1 同一件事，属降载面实现 |
| `ProgramRunner` / `ReplEvaluator` / CLI 三份同构逻辑抽单源 | `P4-γ` 整合项 |
| `InterpreterTests.swift` 文件名与类名已不达意 | 命名整理留 `P4-γ`（本批只做迁移，不改名以免扩大 diff）|

---

## 7. 复现方式

```sh
# 迁移面是否真的驱动 HIR：两个方向必须给出逐项相同的失败集合
swift test --disable-sandbox --scratch-path /tmp/pini-build                       # 84
PINI_INTERP_ENGINE=ast swift test --disable-sandbox --scratch-path /tmp/pini-build # 84, identical set

# 未迁移面零位移：失败必须全部落在 50 个迁移文件内
# 探针（单文件面）
python3 tools/hir-parity-probe.py --out /tmp/p4b-final.tsv
cmp /tmp/p4-0-final.tsv /tmp/p4b-final.tsv && echo IDENTICAL
```

⭐ **第二条判据是本批的鉴别力所在**：若有人把 `ProgramRunner` 的引擎改成跟随
`PINI_INTERP_ENGINE`，两个方向的失败集合就会散开，这条判据立刻报出来。

# `G-6b` 开工规划：装配整合 + 测试侧引用面（`G-6c` 之前的最后一段可逆工程）

> **批**：无（本件是**规划**，不是批次；开工须**单独点名**）
> **日期**：2026-09-18｜**状态**：**待点名**
> **上游**：`docs/issue-hir-p4-gamma-plan-2026-09-16.md` §8.4（`G-6` 行）·
> `docs/issue-hir-p4-gamma-batches-2026-09-16.md`（`G-6a` 交付记录 · 其「未做范围」为本批的第一份对象清单）
> **前置单**：`docs/issue-interpreter-residual-reference-surface-2026-09-18.md`（`G-6` 残余引用面总挂点）
> ⚠️ **本件只做规划**：不改任何源码 / 测试 / 工具；不建分支。
> ⚠️ **本件不镜像读数** —— HEAD / 测试数 / 探针槽位 / 分支数的唯一源 = 元仓 `state-readings.json`。

---

## 0. 一句话

`G-6b` 是 `G-6` 三批制的第二批，排在**不可逆的 `G-6c`（删 4137 行）之前**。
它要满足的判据只有一条：

> **`G-6c` 删掉 `Interpreter` 之后，`swift build` 与 `swift test` 仍然编得过，
> 且删除批里不需要顺手改测试、不需要顺手搬装配。**

⚠️ **本件不是把「已登记的四项」照抄一遍**。开工前逐项实测后，登记的四项里：
**两项的面比登记的大**（漏记了构造点与 `G-6a` 新写的装配）、**一项与删除无关**（整合不阻塞删除）、
**一项的判据写法已失效**（「两引擎一致」在该文件上已不可测）。逐条见 §1.3 · §2 · §5.4。

---

## 1. 事实基础（全部现测，2026-09-18，HEAD `ec70667`，**工作树干净**）

> 测量姿势统一：`.swift` 逐字符剥掉 `//` · `/* */` · 字符串字面量后检索。
> ⚠️ **必须去注释** —— 本仓大量 docstring 在**叙述**语义出处，按原文 grep 的读数系统性偏高
> （同一坑的两次实例见 `docs/issue-interpreter-residual-reference-surface-2026-09-18.md` §3）。

### 1.1 `Sources` 侧的装配点：**9 个调用点 / 4 个文件**

「装配」= `check → lower → execute` 这条同构序列。按 `HIRLowerer.lower` 与 `HIRExecutor(` 定位：

| # | 位置 | 输入形状 | 现状 | `G-6b` 处置 |
|:--:|---|---|---|---|
| 1–4 | `Sources/PiniCore/Run/ProgramRunner.swift` L81–111 / L119–136 / L180–195 / L205–213 | module · package ×（运行 / 测试） | **已是统一入口**（`P4-β` 建 · `G-4` 补齐测试面） | 作为**目标形态**，不外移 |
| 5 | `Sources/PiniCLI/main.swift:832` `runHIREngine` | module | 手写 `checkCollecting` + `persistAcrossScopesForCodegen` + `lower` + `HIRExecutor` 直构 | 接统一入口 |
| 6 | `Sources/PiniCLI/main.swift:860` `runHIRPackageEngine` | package | 手写 `lower` + `HIRExecutor` 直构（前置由调用方做） | 接统一入口 |
| 7 | `Sources/PiniCLI/main.swift:1044` `runDebugFile` | module | `G-6a` 新写：`checkCollecting` + `lower` + `HIRExecutor` + `DebugRun` | 接统一入口（`ProgramRunner` 本就是 `DebugHookHost`） |
| 8 | `Sources/PiniCLI/main.swift:1071` `runDebugDirectory` | package | 同上（package 形态） | 同上 |
| 9 | `Sources/PiniCore/Debugger/DAPServer.swift:191` | module · package | `G-6a` 新写：两分支各一份 `check → lower` + `HIRExecutor` + `DebugRun` | 同上 |
| 10 | `Sources/PiniCore/REPL/ReplEvaluator.swift:96` | module | 手写 `checkCollecting` + `lower` + `HIRExecutor`；**另有 `.ast` 分支（L104）** | 见 §2.2 |
| — | `Sources/PiniCLI/main.swift:1456` `typeCheckThenGenerate` | module | 手写 `check → lower` → **`IREmitter`（不执行）** | 见 §2.3 |
| — | `Sources/PiniCLI/main.swift:1509` `runHIRPackageEmit` | package | 同上（package 形态） | 见 §2.3 |

**去注释后的原始计数**（可复跑，见 §8）：`HIRLowerer.lower` **13** · `checkCollecting` **10**（含定义 1）·
`.check(package:` **8** · `persistAcrossScopesForCodegen = true` **13** · `HIRExecutor(` **8** ·
`engine == .hir` **2** · `ProgramRunner(` **2**。

⇒ **装配序列在 `Sources` 侧被抄了 9 遍**（`ProgramRunner` 的 4 处是它的家，另 5 处在 CLI/DAP）**，每遍都带着
同一句 `persistAcrossScopesForCodegen = true` 与各自的检查/上报风格。**

### 1.2 ⚠️ 登记说「四份」，实测是 **9 个调用点 / 4 文件**

登记原文（`G-6a` 载体的「未做范围」与 `G-6` 行）写的是：

> 四份同构装配整合 —— `runHIREngine` · `runHIRPackageEngine` · `runHIRPackageEmit` · `resolveHIRPackage`，与 `ProgramRunner` 代码同构

三处与实测不符，**须逐条订正**：

| 登记项 | 实测 |
|---|---|
| `resolveHIRPackage` | ⛔ **全 `Sources/` 零命中** —— 该符号今天不存在（`G-6a` 之前的一次观察，函数已改名或已合并） |
| `runHIRPackageEmit` 计入「装配」 | ⚠️ 它下游是 **`IREmitter`，不执行** ⇒ 与其余 8 处**不同类**。并进来会把 LLVM 发射面拖进「运行装配」 |
| 只列 `runHIREngine` / `runHIRPackageEngine` | ⛔ **漏记 4 处**：`runDebugFile` · `runDebugDirectory` · `DAPServer`（两分支）· `ReplEvaluator` |

⭐ **其中两处是 `G-6a` 自己写出来的**：`G-6a` 为了「`pini debug` 两条入口改指 HIR」，
在 `runDebugFile` / `runDebugDirectory` 里**又手写了一份** `check → lower → execute`，
而没有复用 `ProgramRunner`（它已经是 `DebugHookHost`，形状天然够用）。
⇒ **本批的登记面在 `G-6a` 之后变大了**，而 `G-6a` 的「未做范围」仍写着「四份」。
这不是缺陷，是**登记未跟上事实**：本件按实测重列（§1.1）。

### 1.3 `Tests` 侧的引用面：**18 行 / 19 处引用 / 3 个文件**（登记只记了 5 处 / 2 文件）

| 文件 | `Interpreter(` 构造点 | `Interpreter.<静态成员>` | 该文件 `G-6c` 之后的命运 |
|---|:--:|:--:|---|
| `Tests/PiniTests/StructuredConcurrencyTests/StructuredConcurrencyTests.swift` | **3**（L70 · L87 · L183） | **3**（L246 · L247） | ⛔ **整体存活**（`G-3e` 裁：14 条不退役）⇒ **不改指就编译不过** |
| `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift` | **9**（全落在退役的 11 条内） | **2**（L192 · L227，同在退役两条内） | 文件存活（**前 4 条不退役**），但**该 4 条实测零引用** ⇒ 无需改指 |
| `Tests/PiniTests/CPSDifferentialTests/CPSDifferentialTests.swift` | **2**（L22 · L30，在一处夹具驱动 helper 内） | 0 | 14 条**全部退役** ⇒ 随文件消亡 |

⭐ **判据级结论（本件最重要的一条实测）**：

> `G-6c` 的**真编译阻塞面** = `StructuredConcurrencyTests` 的 **4 个用例 / 6 处引用**
> （3 构造点 + 3 静态成员）。**其余 13 处引用全部随退役面消亡**，不构成阻塞。

⚠️ 而登记单 `docs/issue-interpreter-residual-reference-surface-2026-09-18.md` §2.3 **只列了那 3 处静态成员**，
**未列 3 个构造点** ⇒ 若照登记单施工，`G-6c` 会在删除瞬间得到一屏 `cannot find 'Interpreter' in scope`。
**这是本批必须补记的第一件事。**

### 1.4 `G-6b` 的四项登记对象，逐项实测定性

| 登记项 | `G-6c` 的前置？ | 实测依据 |
|---|:--:|---|
| ① 四份同构装配整合 | ❌ **不是** | 删除只依赖 3 个 `.ast` 分支消失（`main.swift:901/952` 的 `engine == .hir` 分派 · `ReplEvaluator:104`）；其余装配点已是 HIR-only、不引用 `Interpreter` |
| ② `ReplEvaluator` 的 `.ast` 分支 | ✅ **是** | 它是 `Sources` 侧最后一处 `Interpreter(...)` 之一（另两处是 `main.swift:906/965` 的回落） |
| ③ 测试侧引用面 | ✅ **是** | 见 §1.3：4 个存活用例 / 6 处引用 |
| ④ `InterpreterTests` 改名 | ❌ 不是（编译无关） | 该件 12 条用例**已驱动 `ProgramRunner()`**（`P4-β` 迁移），仅是**文件 / 目录 / 类名不达意**；不改也编得过 |

⇒ **②③ 是硬前置，①④ 是质量项。** ①的取舍见 §5.1；④ 的处置见 §2.4。
⚠️ 本件**不**把这四项当成「必须同批」——那正是 `P4-β` 教训的反面（按角色定，不按出现次数定）。

### 1.5 一条**判据已失效**（随 `G-6a` 交付）

关掉的工单 `docs/issue-hir-builtin-user-extension-gap-2026-09-18.md` 判据 4 写：

> 同 6 条在 `PINI_INTERP_ENGINE=ast` 下同样全绿

实测：`Tests/PiniTests/BuiltinOverrideTests/BuiltinOverrideTests.swift` 的 harness 已改指
`ProgramRunner()`（L31）⇒ **该文件不读 `PINI_INTERP_ENGINE`**（引擎由构造类型决定，`P4-β` 的设计）
⇒ 判据 4 **结构性不可测**，与 `G-4` 记的「`pini test` 改指后不再看该开关」**同族**。
⇒ 处置 = 订正判据写法（替代物 = 全量回归的新增红 0），**不是**去跑一个跑不出来的方向。

### 1.6 探针器械：**现行形态是「恒不可用」，不是「量到陈旧二进制」**

`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-6a` 记录写：「不显式设 `PINI_SWEEP_BIN` 就会**量到陈旧二进制**」。
**实测订正**（本批现测）：

| 项 | 值 |
|---|---|
| 默认值（`tools/hir-parity-probe.py:251`） | `/tmp/pini-build/arm64-apple-macosx/debug/pini` |
| 该路径**今天是否存在** | ⛔ **不存在**（`No such file or directory`）⇒ 走 `os.access(BIN, os.X_OK)` 失败分支 ⇒ **明确报错 `rc=1`**，**不是**静默 |
| 现行布局（`swift build --show-bin-path`） | `.build/out/Products/Debug/pini`（`--scratch-path X` 时 = `X/out/Products/Debug/pini`） |
| 提示语（`:647–650`） | 叫人建 `--scratch-path /tmp/pini-build` ⇒ 产出落在 `out/Products/Debug`，**与默认值指向的那条仍不同** ⇒ 照提示建完，默认值**仍然找不到** |

⇒ **「量到陈旧二进制」是历史态**（旧布局文件还在 `/tmp` 里时，`os.access` 通过 ⇒ 静默量旧件）。
**现行态 = 无 env 时探针恒不可用**。两态都指向同一个根因（**默认值写死了历史布局的绝对路径**），
但严重性与修法的表述不同 ⇒ **单独立案**（见 §2.5），并**订正** `G-6a` 载体里的那句。

---

## 2. 对象清单（本批要动的东西，逐项带判据）

### 2.1 装配整合的**目标形态**（待裁 §5.1 定形后落）

现有 9 个调用点里，**只有 5 个**（`main.swift` 4 + `DAPServer` 1 处两分支 + `ReplEvaluator` 1）需要动；
`ProgramRunner` 自我 4 处是家，不外移。

### 2.2 `ReplEvaluator` 的 `.ast` 分支（硬前置）

`Sources/PiniCore/REPL/ReplEvaluator.swift:102–143` 的 `switch engine`：`.hir` 支保留、`.ast` 支（L104）随 `G-6c` 删除。
⚠️ **两处形态要点**（`P4-4` 已立，本批不得回退）：
① 引擎仍是**参数**（不是协议要求）；
② 「无 main」在**降载之前**按**条件**判定（`hasMainFunction`），不按错误消息匹配。
⇒ 收成一臂时，`tolerateMissingMain` 的语义**保持**，只是不再有第二臂对照。

### 2.3 emit 面（**与装配整合分开**）

`typeCheckThenGenerate`（单文件）与 `runHIRPackageEmit`（包）共享**前半段**（`check → 置持久表 → lower`），
下游是 `IREmitter`。⇒ 若整合取「只搬前半段」的口径，这两处可一并收进共享 helper；若取「全经 `ProgramRunner`」，
须先给 `ProgramRunner` 加一个**不执行**的出口 —— 那会让它的名字说谎（它不 run）。取舍见 §5.1。

### 2.4 `InterpreterTests` 改名（质量项，可后置）

| 现状 | 实测 |
|---|---|
| 路径 | `Tests/PiniTests/InterpreterTests/InterpreterTests.swift` |
| 类名 | `InterpreterTests` |
| 用例数 | **12**（全部已驱动 `ProgramRunner()`） |
| 问题 | **名字已不达意** —— 它承载的不再是「解释器测试」（`P4-β` 刻意未改名以免扩大 diff） |

⚠️ **该事项在全仓的唯一起载处是 `docs/spec/issue/archive/issue-hir-p4-beta-migration-2026-09-16.md` §6**
（已归档件），`G-6` 行指向 `P4-γ` 规划件 §8.8 ⇒ 改名时须一并给出新名的**判据**（见 §4）。

### 2.5 探针默认路径（器械，见 §5.3）

`tools/hir-parity-probe.py:251` 一行 + `:647–650` 的提示语一行。**单独立案**：
`docs/issue-hir-parity-probe-default-bin-path-2026-09-18.md`。

---

## 3. 分批建议（若 ① 与 ②③④ 拆开，则本批切两半）

| 子批 | 内容 | 判据 | 可逆性 |
|---|---|---|---|
| **`G-6b-1`** | **硬前置**：测试侧引用面改指（§1.3 的 4 个用例 / 6 处）+ `ReplEvaluator` 的 `.ast` 分支收成一臂 | 全量回归**逐条集合相等**（新增红 0）· 该 4 个用例与 REPL 面全绿 · 契约 `clean` | 提交级回退 |
| **`G-6b-2`** | **质量项**：装配整合（§2.1，含 emit 面按 §5.1 的裁决）· `InterpreterTests` 改名 · 探针 1 行（若裁 A） | 全量回归**逐条集合相等** · 探针与冻结件对账 · 三个 CLI 子命令（`run` / `debug` / `repl`）实机冒烟 | 提交级回退 |

**为什么切两半**：`G-6b-1` 是**必须**（不做则 `G-6c` 编译不过），`G-6b-2` 是**应该**（不做则末态仍抄 9 遍）。
混批会把「必须」的那半的交付风险绑在「应该」的那半上 —— `P4-γ` 规划 §4 裁定 2 的同一把尺
（**归因粒度决定后续判断质量**）。若用户要一次做完，则**按 `G-6b-1` → `G-6b-2` 的提交序**走两个提交点。

---

## 4. 判据（逐条可测）

| # | 判据 | 测法 |
|:--:|---|---|
| 1 | **`G-6c` 的编译面零阻塞** | 删除后 `swift build` 无 `cannot find 'Interpreter' in scope`；**开工前**可用「去注释扫描 `Interpreter` 的存活面引用 = 0」提前证 |
| 2 | **无新增红** | 与开工基线**逐条**比对（转绿 / 新增 / 仍红三集合，**新增必须 0**），不是比总数 |
| 3 | **装配形状收成一处** | 去注释后 `Sources` 侧 `checkCollecting` + `persistAcrossScopesForCodegen = true` + `HIRLowerer.lower` 的**同现序列**只剩目标形态（§5.1 裁决后给出目标计数） |
| 4 | **行为零变更**（`G-6b-2`） | 三个用户可见入口的实机冒烟：`pini run <file>` · `pini run <dir>` · `pini debug <file>` · `pini repl`；每项与改前**逐字节相同** |
| 5 | **改名有判据**（§2.4） | 新名描述的是「这些用例现在测什么」，不是「它们曾经属于谁」；改后 `swift test --filter <新类名>` 跑得到 12 条 |
| 6 | 门禁 | 契约 `clean`（62/62 · 三锚点）· 文档链接 0 过时 · comment-lint · evidence_sweep |

⚠️ **判据 3 不是「少了几处」**，而是「**同现序列**只剩一处」—— 单看 `HIRLowerer.lower` 的处数会把
`IREmitter`（emit 面）与 `HIRExecutor`（运行面）算成一回事，而它们**下游不同**（§1.2）。

---

## 5. 待裁（三项，各带背景 / 选项 / 代价 / 建议）

### 5.1 `G-6b-2` 的整合**目标形态**取哪个

**这是什么**：9 个装配点收成几处、收成什么。`ProgramRunner` 是 `P4-β` 为「测试面」建的统一入口，
它的语义是 **「运行一个程序」（run / runTests）**，本身**不发射 IR**。

**为什么现在要决定**：它决定本批要动几个文件、以及 `G-6c` 的删除批是「只删」还是「删 + 搬」。

**选项与代价**：

- **A 全部经 `ProgramRunner`**（含给 emit 面新增一个 `lower*` 出口）：
  代价 = `ProgramRunner` 的职责从「运行」扩到「运行 + 只降载」，**名字开始说谎**；
  收益 = 只有一处装配，判据 3 最容易测。
- **B 前半段单独成器**：新立一个只做 `check → 置持久表 → lower` 的类型（如 `ProgramFrontend`），
  `ProgramRunner` 内部用它、emit 两处也用它；`ProgramRunner` 只保留「运行」语义：
  代价 = 多一个类型（约 40 行）；收益 = **职责边界与下游一致**（运行 vs 只降载），
  且 `ReplEvaluator` 的「无 main 容忍」也能落在同一个前半段上。
- **C 只做硬前置（`G-6b-1`），整合后置到 `P5`**：
  代价 = `G-6c` 之后 `Sources` 侧仍抄着 8 遍同构序列，且**不可逆批期间的读数是它给的**；
  收益 = 本批最小。

**我的建议**：**B**。理由：装配序列里**真正共享的是前半段**（`checkCollecting` / `check(package:)` /
`persistAcrossScopesForCodegen = true` / `HIRLowerer.lower`），而**下游分两类**（`HIRExecutor` 执行 /
`IREmitter` 发射）。A 把两类硬塞进一个名字里；C 让整合无限期后置，而它正是 `G-6` 行登记过的动作。
⚠️ 但 **B 有一个必须认的代价**：新类型是**新增抽象** ——若实测发现它除了转发什么都不做
（即前半段只有 4 行），那就取 **A**，别为 4 行造一个类型。**这个判断留给开工第一步实测**。

### 5.2 `StructuredConcurrencyTests` 那 4 个用例改指到哪（硬前置）

**这是什么**：4 个用例（`testJoinFutureDetachesChildFromParent` · `testCheckpointIsNoOpWithoutOwner` ·
`testSynchronousProgramUnaffectedByCheckpoints` · `testCloseScopeCollectsLeakedErrAndCancelsPending`）
驱动 `Interpreter().run(module:)` 做**语言层端到端**（阻塞路径）；`G-6c` 删了就编译不过。

**为什么现在要决定**：不改指 ⇒ `G-6c` 编不过；全部改指 ⇒ 可能重演 `G-5` 那条教训
（`testDeferStillRunsWhenTaskCancelled`：**`rc=0` 不蕴含断言可满足** —— 换腿后它跑完了但**跑出来的东西不对**）。

**选项与代价**：

- **A 先测后改**：开工第一步逐条"换腿 + 真跑该用例"（不按 `rc` 判），能绿的改、不能绿的**立案**并保留 AST 臂：
  代价 = 一次定向测试（4 条）；收益 = 每个不能改的都有主，且**不把测试改松**。
- **B 全部改指，红的按新缺口立案**：代价 = 先让 4 条变红再逐条归因，中间态有一屏红；收益 = 流程最短。
- **C 留到 `G-6c` 一并处理**：代价 = **不可逆批被测试改造绑住**，回退粒度变粗；收益 = 少一批。

**我的建议**：**A**。理由：`G-5` 已经用实测证明「按 `rc` 判可迁移」是**不成立的判据**（该单 §4 的显式登记），
而本批的 4 条目测与那一条**同族**（都测取消 / defer / 检查点语义），必须先跑再改。

### 5.3 探针默认路径的 1 行：并入本批，还是单列

**这是什么**：`tools/hir-parity-probe.py:251` 的默认值指向一个**今天不存在**的历史布局（§1.6）。

**为什么现在要决定**：`G-6b-2` 的判据里就有探针护栏 —— 而**该缺陷会让探针在无 env 时直接不可用**，
即它是本批**自己的**阻塞。按 `charter.md` D2（当场修须**同时**满足「构成阻塞」+「工作量小」），两条都满足。

**选项与代价**：

- **A 并入 `G-6b-2`**：代价 = 本批多动 1 个 `tools/` 文件（`P4-γ` 的「器械例外」先例 = `D-P4-29` 的 `SIGPIPE` 修复）；
  收益 = 护栏读数可信，且**恢复「不设 env 也能跑」**。
- **B 单列一小批**：代价 = 多一次分支 / 合并 / 读数的流程开销；收益 = 混合面更干净。
- **C 只登记不修**（本批已按此立案）：代价 = 本批及 `G-6c` 每次都须显式设 `PINI_SWEEP_BIN`，**忘了就恒报错**。

**我的建议**：**A**。理由：它满足 D2 的两个条件，且 `D2` 的例外已有先例（`SIGPIPE` 那次也是「一次性投入换其后每批提速」）。
⚠️ 但**是否修**由你定 —— 本件只登记，不改工具。

### 5.4 ⚠️ 顺带请裁：`G-6` 三批制的**范围登记**要不要写进权威载体

三批制的切法（`G-6a` / `G-6b` / `G-6c`）目前**只出现在两处「未做范围」的句子**里
（`G-6a` 载体的末段、主计划 `G-6` 行的指针），而 `P4-γ` 规划 §8.4 的批次表里 **`G-6` 仍是单独一行**。
⇒ 后果实测：本件开工前就出现了「四份 vs 9 处」的登记落差（§1.2）。
**是否本批把三批制写进 §8.4 的批次表**（`G-6` 行拆三行）？代价 = 动一处权威载体 + 若干入向引用；收益 = 下一位读者不再从「未做范围」里拼范围。

---

## 6. 止损点（触发即停）

1. **整合若须改降载层或执行器语义**（`HIRLowerer` / `HIRExecutor` 的行为）⇒ **停**，回来重估切分 ——
   本批的定义是「装配搬家」，不是「语义变更」。
2. **`G-6b-1` 的 4 个用例若超过 2 条不可改指** ⇒ 停，回报（说明 `G-6c` 的编译阻塞面比 §1.3 估计的大，
   块要重切）。
3. **任一读数变化**（哪怕 1 条）在 `G-6b-2`（纯搬家批）上出现 ⇒ 立即回退该子批 ——
   与 `G-1` 的止损同形（「零行为变更」的批有变化，说明搬的不只是装配）。
4. 单批回归 >5 失败且 >1 小时无收敛（沿用 `ADR-031` §4 口径）。

---

## 7. 不做范围

- **不开 `G-6c`**（删本体 · 收 `PINI_INTERP_ENGINE` · 探针两通道化 + 新冻结件）。
- **不动 spec 语言面正文**（本批零语言面变更；若 `G-6b-1` 触发语义问题 ⇒ 走 §1.3，不在批内决定）。
- **不修在册工单**（`issue-hir-parity-probe-default-bin-path-2026-09-18.md` 与其余全部 —— 除非 §5.3 裁 A）。
- **不处置退役面**（`SuspendRuntimeTests` 的 11 条 · `CPSDifferentialTests` 的 14 条 · 语料保全动作）——
  归 `G-6c` 与 `docs/issue-suspend-retirement-residuals-2026-09-17.md`。
- **不把 `HIRModule` 声明顺序非确定**（`docs/issue-hir-nominal-decl-order-nondeterminism-2026-09-18.md`）顺手修掉 ——
  它不阻塞本批，且「归属：待裁」。
- **不 push**；**不把本件当成开工授权**（每子批须单独点名）。

---

## 8. 复现方式（勘测本规划所依据的全部读数）

```sh
cd <repo>

# 1.1 / 1.2 装配点（去注释；必须去注释 —— 本仓 docstring 会复述语义出处）
python3 - <<'PY'
import re, pathlib
def strip(t):
    out=[];i=0;n=len(t)
    while i<n:
        if t.startswith("//",i):
            j=t.find("\n",i); i=n if j<0 else j; continue
        if t.startswith("/*",i):
            j=t.find("*/",i+2); i=n if j<0 else j+2; continue
        if t[i]=='"':
            j=i+1
            while j<n:
                if t[j]=='\\': j+=2; continue
                if t[j]=='"': break
                j+=1
            i=j+1; out.append('""'); continue
        out.append(t[i]); i+=1
    return "".join(out)
PAT = {'lower': r'HIRLowerer\.lower', 'checkCollecting': r'checkCollecting',
       'checkPkg': r'\.check\(package:', 'persist': r'persistAcrossScopesForCodegen\s*=\s*true',
       'Interpreter(': r'\bInterpreter\(', 'HIRExecutor(': r'\bHIRExecutor\(',
       'engine==hir': r'engine\s*==\s*\.hir', 'ProgramRunner(': r'\bProgramRunner\('}
for name, rx in PAT.items():
    hits=[]
    for p in sorted(pathlib.Path("Sources").rglob("*.swift")):
        for i,l in enumerate(strip(p.read_text(errors="replace")).splitlines(),1):
            if re.search(rx, l): hits.append(f"{p}:{i}")
    print(f"{name}: {len(hits)}  {hits}")
PY

# 1.3 Tests 侧引用面（同上 strip 函数）
#   预期：18 行 / 19 处 / 3 文件；构造点 3 + 9 + 2

# 1.4 删除面规模（时点读数，不是承诺；权威点位见 P4-γ 规划 §8.7）
wc -l Sources/PiniCore/Interpreter/Interpreter.swift \
      Sources/PiniCore/Interpreter/SuspendEvaluator.swift \
      Sources/PiniCore/Interpreter/SuspendScheduler.swift

# 1.6 探针默认路径与现行布局
grep -n 'PINI_SWEEP_BIN' tools/hir-parity-probe.py
swift build --show-bin-path
ls -la /tmp/pini-build/arm64-apple-macosx/debug/pini   # 现测：No such file or directory

# 1.5 判据失效
grep -n 'PINI_INTERP_ENGINE' Tests/PiniTests/BuiltinOverrideTests/BuiltinOverrideTests.swift   # 零命中
```

---

## 9. 与其它载体的关系

- **本件不镜像读数** ⇒ 与跑一次测试无关；需要改的只有「对象清单变了」。
- **对象清单的第一份出处** = `docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-6a` · 未做范围
  （⚠️ 其中的「四份」已按 §1.2 订正）。
- **残余引用面的总挂点** = `docs/issue-interpreter-residual-reference-surface-2026-09-18.md`
  （本件给它的 §2.1 行号表与 §2.3 清单各补一条订正）。
- **删除面规模** = `docs/issue-hir-p4-gamma-plan-2026-09-16.md` §8.7（**唯一权威点位**）。

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

> ⛔ **2026-09-18 开工首步实测：本件 §1.3 · §5.1 · §5.2 的读数已被推翻，`G-6b` 止损点 2 命中 ⇒ 块待重切。**
> **本批未产生任何提交**（`Sources/` / `Tests/` 未动）。**重切前先读 §10**，本节以下凡与 §10 冲突之处以 §10 为准。

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

> ⛔ **已被 2026-09-18 开工首步实测推翻 —— 下面是错的，正确读数见 §10.2（8 个用例 / 5 处引用 + 1 个助手）。**
> 错因：把助手 `runProgramAST` 的构造点记成一个「1 处引用」，未沿它展开到 **5 条**调用用例。

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

### 2.1 ⛔ 装配整合 —— **已撤销**（2026-09-18，见 §10.4 / §10.6）

~~目标形态待裁 §5.1 定形后落；现有 9 个调用点里只有 5 个需要动，`ProgramRunner` 自我 4 处是家。~~

**撤销**：§10.4 把 12 个调用点按**五维**摊开后，**变体数与调用点数同阶** ⇒ 它们不是「同一段代码抄了 N 遍」。
用户 2026-09-18 裁决采纳「**不整、订正登记**」⇒ **本节的对象清单作废**；
登记订正落在 `docs/issue-hir-p4-gamma-plan-2026-09-16.md` §8.4（权威批次表）等在位载体。
⚠️ **不得据本节去「顺手整合」** —— 那会把一次已被否证的重构重新引入。

### 2.2 `ReplEvaluator` 的 `.ast` 分支（硬前置）

`Sources/PiniCore/REPL/ReplEvaluator.swift:102–143` 的 `switch engine`：`.hir` 支保留、`.ast` 支（L104）随 `G-6c` 删除。
⚠️ **两处形态要点**（`P4-4` 已立，本批不得回退）：
① 引擎仍是**参数**（不是协议要求）；
② 「无 main」在**降载之前**按**条件**判定（`hasMainFunction`），不按错误消息匹配。
⇒ 收成一臂时，`tolerateMissingMain` 的语义**保持**，只是不再有第二臂对照。

✅ **2026-09-18 重裁（`G-6b-1` 实测后）：它不是「硬前置」，而是「随删除消失」** —— 见 §2.3.2（登记在残余单）。
理由：引擎开关（`PINI_INTERP_ENGINE`）**还在**时把 `.ast` 静默改走 HIR，正是该文件注释里点名要避免的
「静默回退假绿」⇒ 提前收成一臂会**改变用户可见行为**。故它与两处 CLI 回落一起**随开关在 `G-6c` 消失**。

### 2.3 emit 面（**随 §2.1 一并失效**）

~~`typeCheckThenGenerate`（单文件）与 `runHIRPackageEmit`（包）共享前半段，下游是 `IREmitter`；
若整合取「只搬前半段」的口径可一并收进共享 helper。~~

⛔ **本节随 §2.1 的撤销而失效**：emit 面的取舍**只在「要不要整合」成立时才有意义**，
而整合的前提已被否证。⚠️ 两处 emit 入口**本批一行未动**，其形状属 `G-6c` 的读（`§1.1` 表内层级 11/12）。

### 2.4 `InterpreterTests` 改名（质量项，可后置）

| 现状 | 实测 |
|---|---|
| 路径 | `Tests/PiniTests/InterpreterTests/InterpreterTests.swift` |
| 类名 | `InterpreterTests` |
| 用例数 | **12**（全部已驱动 `ProgramRunner()`） |
| 问题 | **名字已不达意** —— 它承载的不再是「解释器测试」（`P4-β` 刻意未改名以免扩大 diff） |
| ✅ **处置（`G-6b-2`）** | 改名 **`ProgramExecutionTests`**（**目录 / 文件 / 类**三级，`git mv` 保历史）；判据见下 |

⚠️ **该事项在全仓的唯一起载处是 `docs/spec/issue/archive/issue-hir-p4-beta-migration-2026-09-16.md` §6**
（已归档件），`G-6` 行指向 `P4-γ` 规划件 §8.8 ⇒ 改名时须一并给出新名的**判据**（见 §4）。

✅ **已处置（`G-6b-2`，2026-09-18）**：新名 = **`ProgramExecutionTests`**，
判据 = **描述「这些用例现在测什么」**（端到端程序执行），而非「它们曾经属于谁」；
`--filter ProgramExecutionTests` 仍跑得到原 **12 条**。入向引用（spec 的测试类清单 ·
测试目录分类件 · 测试原则件的类表与代码示例）同批改完。

### 2.5 探针默认路径（器械，见 §5.3）

`tools/hir-parity-probe.py:250–252` 的默认值 + `:647–650` 的提示语。**单独立案**：
`docs/issue-hir-parity-probe-default-bin-path-2026-09-18.md`。

✅ **已修（`G-6b-2`，裁 A）**：默认值改为**运行时解析** —— 问 SwiftPM（`swift build --show-bin-path`，
可选 `--scratch-path` 透传）拿产物路径；`PINI_SWEEP_BIN` 仍可覆盖；
工具内**零硬编码产物布局**（判据 3 实测 0 处命中）；失败提示语给出的命令**照做即落在解析处**（无第二步）。

---

## 3. 分批建议（若 ① 与 ②③④ 拆开，则本批切两半）

| 子批 | 内容 | 判据 | 可逆性 |
|---|---|---|---|
| **`G-6b-1`** ✅ **已交付** | **引用面 + 单源化**（重切后）：测试侧 3 条改指（§2.3.1 的 3 条 · 非 4 个用例）+ `checkCancellation` 上提 `RuntimeOps` + 5 条退役**具名入账** | ✅ 全量回归**逐条集合相等**（56 → 56，新增红 0 / 转绿 0）· 契约 `clean` | 提交级回退 |
| **`G-6b-2`** ✅ **已交付** | ~~装配整合~~（**撤销**）· `InterpreterTests` 改名 · 探针默认路径~~1 行~~（改运行时解析） | ✅ 探针四判据实测 · 四入口实机冒烟 · 回归集合相等 | 提交级回退 |

⚠️ **`G-6b-1` 的原定范围有两处被重切订正**（详见 §10）：① 「测试侧引用面」实为 **8 个用例 + 1 个助手**，
不是 4 个用例；② `ReplEvaluator` 的 `.ast` 分支**从硬前置改为随删除消失**（提前收成一臂 = 静默回退假绿）。

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

---

## 10. 开工首步实测（2026-09-18）：⛔ 止损点 2 命中，块待重切

> **状态**：勘测完成，**零提交** —— `Sources/` / `Tests/` / `tools/` 未动，工作树停在 `8db4e52`。
> **本节的作用**：本件 §1.3 · §5.1 · §5.2 的读数**已实测推翻**；重切方案见 §10.6（**待裁**）。
> ⚠️ 本节的实验改动（临时换腿）**已全部还原**，`git status` 实测为空。

### 10.1 `Tests` 侧引用面：登记 18 行 / 19 处 → 实测 **19 行 / 20 处**

| 文件 | 登记（§1.3） | 实测（去注释） | 判定 |
|---|---|---|---|
| `Tests/PiniTests/StructuredConcurrencyTests/StructuredConcurrencyTests.swift` | 3 构造 + 3 静态 = 6 处 | 3 行 / 6 处（L70 · L87 · L183；L246 ×2 · L247 ×1） | 一致 |
| `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift` | 9 构造 + 2 静态 = 11 | **12 行 / 12 处** | ⚠️ **漏记 1 行** |
| `Tests/PiniTests/CPSDifferentialTests/CPSDifferentialTests.swift` | 2 构造 | 2 行 / 2 处 | 一致 |
| **合计** | 18 行 / 19 处 | **19 行 / 20 处** | ⚠️ |

漏记的那一处在 `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift:484`：

```swift
private func captureSuspendStdout(_ body: (Interpreter) throws -> FutureValue) throws -> [String]
```

它是**闭包的类型标注** —— 既不是构造点、也不是静态成员 ⇒ **按「构造点 + 静态成员」两栏枚举时结构性看不见**。
⚠️ 它的编译后果与构造点**相同**：该文件存活 ⇒ 这一行必须改、或该助手必须随退役面删。

⭐ 推广判据：**引用面普查只数「构造点 / 静态成员」两栏会漏掉第三栏 —— 类型标注**（参数、返回值、泛型实参）。
下次普查照 `\bInterpreter\b` 全量数，不预设形态。

### 10.2 ⛔ `G-6c` 的真编译阻塞面：登记「4 个用例 / 6 处引用」→ 实测 **8 个用例 / 5 处引用 + 1 个助手**

`Tests/PiniTests/StructuredConcurrencyTests/StructuredConcurrencyTests.swift` 共 **14 条**用例。
沿用「夹具 → 驱动 → 引用点」映射后：

| 用例 | 驱动 | 引用点 | `G-6c` 之后 |
|---|---|---|:--:|
| `testCancelUnjoinedChildrenOnlyCancelsPendingOnes` | 纯 `FutureValue` 单元 | — | 存活 |
| `testCancelUnjoinedChildrenPropagatesToGrandchildren` | 纯 `FutureValue` 单元 | — | 存活 |
| `testDetachedChildSurvivesParentReturn` | 纯 `FutureValue` 单元 | — | 存活 |
| **`testJoinFutureDetachesChildFromParent`** | `Interpreter().joinFuture` | **L70** | ⛔ 编不过 |
| **`testCheckpointIsNoOpWithoutOwner`** | `Interpreter().checkCancellation` | **L87** | ⛔ 编不过 |
| **`testCloseScopeCollectsLeakedErrAndCancelsPending`** | `Interpreter.makeResult` / `.makeError` | **L246 ×2 · L247 ×1** | ⛔ 编不过 |
| `testCancelInterruptsRunningLoop` | `runProgramOnHIRTree` | — | 存活 |
| `testSynchronousProgramUnaffectedByCheckpoints` | `runProgramOnHIRTree` | — | 存活 |
| `testDetachBuiltinPrunesChildFromParent` | `runProgramOnHIRTree` | — | 存活 |
| **`testParentReturnCancelsUnjoinedChildTask`** | `runProgramAST` | 经助手 | ⛔ 助手需换腿 |
| **`testJoinedChildIsNotCancelledByParentReturn`** | `runProgramAST` | 经助手 | ⛔ |
| **`testDeferStillRunsWhenTaskCancelled`** | `runProgramAST` | 经助手 | ⛔ |
| **`testLeakedChildErrorFloatsToCallerResult`** | `runProgramAST` | 经助手 | ⛔ |
| **`testDetachEscapeHatchSuppressesLeak`** | `runProgramAST` | 经助手 | ⛔ |
| — | 助手 **`runProgramAST`** | **L183** | ⛔ 须换腿或删 |

⇒ **8 个用例 + 1 个助手**，不是 4 个用例（**低估 2×**）。

**根因**：§1.3 把 `L183` 记成「一个构造点」，**没有沿 `runProgramAST` 展开** ——
那个助手被 **5 条**用例共用。⚠️ 同族判据：**助手（helper）不是「一处引用」，它是一组用例的入口**；
普查引用面时必须**把助手的调用者一起展开**，否则阻塞面会系统性低估。

### 10.3 ⛔ 那 8 个用例里 **5 条在 HIR 腿上红**（逐条真跑，不按 `rc` 判）

**实验做法**：把助手 `runProgramAST` 的实现**临时**从 `Interpreter` 换成 `ProgramRunner`
（只改驱动，不改断言、不改夹具）⇒ 整类 14 条一次跑完，逐条取结果。

| 用例 | HIR 腿上的实测 | 在册主 |
|---|---|---|
| `testDeferStillRunsWhenTaskCancelled` | **跑了、且不抛错**，但断言不成立 —— 输出只有 `主流程结束`，**缺 `清理完成`** | `G-5` 实测记录；缺口 = 「取消时 HIR 不执行 `defer` 清理」 |
| `testDetachEscapeHatchSuppressesLeak` | `HIR lowering error at 12:10: printing a Result value is outside the slice` | `docs/issue-hir-print-result-value-2026-09-17.md`（用户已裁 **C 维持现状**） |
| `testLeakedChildErrorFloatsToCallerResult` | 同上（`at 11:10`） | 同上 |
| `testParentReturnCancelsUnjoinedChildTask` | 同上（`at 15:18`） | 同上 |
| `testJoinedChildIsNotCancelledByParentReturn` | `HIR lowering error at 10:22: type mismatch: result(ok: PiniCore.HIRType.i32) is not i32` | 同一单 §4「同族待查」（**未裁**） |
| 其余 9 条 | 绿 | — |

⭐ **5 条全部挡在已有主的缺口上**（4 条归 `Result` 打印 / 类型族，1 条归取消时的 `defer` 清理），
与 `docs/issue-suspend-retirement-residuals-2026-09-17.md` §4 的记录**吻合**，与该件「4 个用例」不合。
⇒ **这 5 条不是「改指的技术问题」，是「引擎能力」问题**：`G-6c` 删掉 AST 走查后，它们**无处可跑**。

### 10.4 ⛔ §5.1 的裁决前提被实测推翻：装配「同构」是登记的假象

把 12 个调用点按**四个维度**摊开（不是按「有没有 `check → lower`」）：

| # | 调用点 | `lower` 时机 | 错误面 | 下游 | `mergedWithImports` |
|:--:|---|---|---|---|:--:|
| 1–4 | `Sources/PiniCore/Run/ProgramRunner.swift`（4 处） | 立即 | `throw ProgramRunError.typeCheck` | `HIRExecutor` | ✅ **用** |
| 5 | `Sources/PiniCLI/main.swift` `runHIREngine` | 立即 | 逐条 `printError` + `exit(1)` | `HIRExecutor` | ❌ |
| 6 | `Sources/PiniCLI/main.swift` `runHIRPackageEngine` | 立即（前置由调用方做） | 调用方 `catch` | `HIRExecutor` | n/a |
| 7 | `Sources/PiniCLI/main.swift` `runDebugFile` | **延迟到会话启动** | `printError` + `exit(1)` | `DebugRun` | ❌ |
| 8 | `Sources/PiniCLI/main.swift` `runDebugDirectory` | **延迟到会话启动** | 同上 | `DebugRun` | n/a |
| 9 | `Sources/PiniCore/Debugger/DAPServer.swift` | **延迟到会话启动** | `throw` | `DebugRun` | ❌ |
| 10 | `Sources/PiniCore/REPL/ReplEvaluator.swift` | 立即 | `throw ReplError.typeError` | `HIRExecutor` | ❌ |
| 11 | `Sources/PiniCLI/main.swift` `typeCheckThenGenerate` | 立即 | 逐条 stderr + `exit(1)` | `IREmitter` | ❌ |
| 12 | `Sources/PiniCLI/main.swift` `runHIRPackageEmit` | 立即 | 调用方 `catch` | `IREmitter` | n/a |

**结论**：**变体数与调用点数同阶**（错误面 4 种 × 时机 2 种 × 下游 2 种 × import 合并 2 种 × `requiresMain` 2 种），
⇒ 抽出来的共享类型**只能逐点转发**。这比 §5.1 预设的触发条件（「前半段只有 4 行 ⇒ 退 A」）**更极端**：

- **B**（新立 `ProgramFrontend`）⇒ 造出一个几乎纯转发的类型，**它花掉的复杂度买不回任何东西**；
- **A**（全经 `ProgramRunner`）⇒ 要吸收 4 种错误风格与**调试面的延迟 lower**，**做不到「全经」**；
  能给 emit 面加的那个「不执行」出口还会让它的名字继续说谎。

⇒ **A 与 B 都不可取** —— 选项需**重裁**（§10.6 之②）。登记说的「四份同构装配」**不是一个抽象机会**，
是一组**看起来像**共有前端的调用点。

⚠️ 顺带一条**待查项**（本批未裁定，不动手）：`runHIREngine`（CLI 单文件）与 `ProgramRunner.run(module:)`
在 `HIRLowerer.mergedWithImports` 上**不同**（前者不用）。`Sources/PiniCore/Run/ProgramRunner.swift`
的类注释把这一差异记成「AST 单文件路径曾经漏合并 import，导致别名被读成未声明变量」——
若 CLI 的单文件路径**今天仍有同一个缺陷**，那它是**用户可见缺陷**（记缺陷 → 提工单），
而**不是**「整合顺手修掉」的对象。本批只登记、**未实测**（`G-6b-2` 的判据 4 要求零行为变更 ⇒ 不可顺手修）。

### 10.5 复现方式（本节全部读数）

```sh
cd <repo>

# 10.1 去注释枚举 Tests 侧 Interpreter 引用面（含「类型标注」第三栏）
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
FUNC=re.compile(r'^\s*(?:public |private |internal |fileprivate |final |static |@\w+ )*(?:func|var|let)\s+(\w+)')
for p in sorted(pathlib.Path("Tests").rglob("*.swift")):
    owner=""; lines=strip(p.read_text(errors="replace")).splitlines(); hits=[]
    for i,l in enumerate(lines,1):
        m=FUNC.match(l)
        if m: owner=m.group(1)
        if re.search(r'\bInterpreter\b', l): hits.append((i,owner))
    if hits: print(p, len(hits), hits)
PY

# 10.3 换腿矩阵：把 runProgramAST 的驱动换成 ProgramRunner 后跑整类
#   （实验改动必须还原：git checkout -- <该测试文件>）
swift build --build-tests --disable-sandbox --scratch-path /tmp/pini-build
swift test --disable-sandbox --scratch-path /tmp/pini-build --filter StructuredConcurrencyTests
```

### 10.6 ⛔ 待裁（重切）—— 三项，各带背景 / 选项 / 代价 / 建议

> ✅ **2026-09-18 已裁**（用户「按你的建议来」⇒ 三项建议全部采纳）：
> **① 建议 A** —— 那 5 条**随 `G-6c` 退役**并**具名入账**（`defer` 那条须在单里点名「此后无测试见证」）；
> **② 建议 B** —— **撤销**「装配整合」动作，**订正登记**（`G-6b-2` 承载）；
> **③ 建议 A** —— 把 `checkCancellation` **单源化**到 `RuntimeOps`（本批已交付）。
> ⇒ **`G-6b-1` 已交付**（③ + 3 条改指 + 具名入账），实录见
> `docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-6b-1` 节。
> ⚠️ 以下「待裁」文字保留为**选项的原始记录**（含代价对比），其**待裁状态即失效**。

**① 那 5 条不可转的用例怎么办**（主裁）
- **是什么**：`testParentReturnCancelsUnjoinedChildTask` · `testJoinedChildIsNotCancelledByParentReturn` ·
  `testDeferStillRunsWhenTaskCancelled` · `testLeakedChildErrorFloatsToCallerResult` ·
  `testDetachEscapeHatchSuppressesLeak` —— 语言层端到端，HIR 上跑不动（§10.3）。
- **为什么现在要决定**：不改动它们，`G-6c` 删引擎时它们连文件一起废；而它们的处置**决定 `G-6c` 是
  「只删」还是「删 + 补能力」**。
- **选项与代价**：
  - **A 随 `G-6c` 退役 + 具名入账**：代价 = 语言层端到端覆盖 8 条 → 3 条；
    但「父返回取消未 join 子」在**单元层**仍有 3 条存活用例守着；
    ⚠️ `testDeferStillRunsWhenTaskCancelled` 退役等于**放弃对一条已立案缺陷的测试见证**。
  - **B 先补齐 4 个 HIR 缺口再改指**：代价 = 把 4 张在册单从「非前置」提为 `G-6c` 前置，
    **不可逆批被能力补齐绑住**；且 `Result` 打印那一条**要改用户已下的「维持现状」裁决**。
  - **C 改夹具的观测通道**（不打印 `Result`，改用语言层判定 `err`）：代价 = 改 3 份夹具并逐条实测
    会不会再撞缺口；**对 `defer` 那一条无效**（它是在 HIR 上真跑、缺口在能力上，不在观测上）；
    收益 = 保住 3 条覆盖且不扩 `G-6c`。
  - **我建议 A + 单独把 `defer` 那一条的去向写清**：`defer` 缺口已立案，退役要**在单里点名**
    「该缺陷此后无测试见证」，避免它静默存在。C 可作为 A 之后的追加项，不该塞进本批。
- ⚠️ 本项**归属本来就在** `docs/issue-suspend-retirement-residuals-2026-09-17.md` §7（本件 §7 已声明不做）。

**② 装配整合的形态**（因 §10.4 而重裁）
- **是什么**：A/B 都被实测推翻（§10.4）。真问题是「那 12 个调用点到底还整不整」。
- **选项与代价**：
  - **A 整**：只把**逐字相同的那一行**（`persistAcrossScopesForCodegen = true`）或其载体收口，
    例如实测该行能否由 `HIRLowerer.lower` 自己承担（**须先实测它是不是真必要**）；
    代价 = 需要动 `HIRLowerer` 的入口语义（**止损点 1 的邻域**）；收益 = 少一处机械重复。
  - **B 不整，改写登记**：把这 12 处**不是**「同构装配」这一事实写进 `G-6` 行，
    承认它们只在**形状上**相似；代价 = `G-6` 行要删掉「装配整合」这一动作；收益 = 省掉一次
    只为满足登记而做的重构。
  - **C 后置到 `P5`**（原 §5.1 的 C）：代价 = `G-6c` 之后仍抄着同构序列；收益 = 本批最小。
  - **我建议 B**：登记的「装配整合」前提（同构）被实测否证，那么**该做的是订正登记，不是硬做整合**。
    若你更想留一条收口动作，则取 A 的**最小形式**，但须先实测那一行是否必要。

**③ 接缝用例 `testCheckpointIsNoOpWithoutOwner`**（本批新发现的独立项）
- **是什么**：它驱动 `Interpreter().checkCancellation`（`Sources/PiniCore/Interpreter/Interpreter.swift:61`）。
  同一语义在 `Sources/PiniCore/Interpreter/HIRExecutor.swift:2480` 有一份**逐字相同**的拷贝，
  但是 `private` ⇒ **测试改指不到**。
- **选项与代价**：
  - **A 单源化**：把该语义提到 `Sources/PiniCore/Runtime/RuntimeOps.swift`（那里已住着
    `joinFuture` / `makeCancelError` / `isCancelErrorValue` 等同族），两引擎各自转调，测试改指 `RuntimeOps.*`。
    代价 = 动 `HIRExecutor` 一处（**止损点 1 的邻域**，但属「单源化」而非「语义变更」）；收益 = 判据留在 HIR 侧。
  - **B 退役该用例**：代价 = 丢一条单元级接缝判据；
    但它的**语言层意图**（同步路径不受检查点影响）已由存活的
    `testSynchronousProgramUnaffectedByCheckpoints`（走 HIR 线）守着。
  - **我建议 A**：`RuntimeOps` 就是这类共享运行期谓词的既有家，且 `G-6a` 已证明「单源化能同时
    喂到两条腿」（内建扩展那次）。

**另有两条不需要裁决、只须告知**：
- 探针默认路径那 1 行（§5.3 裁 **A**）：**独立于本止损**，可随重切后的任一批落地，修法取运行时解析。
- `InterpreterTests` 改名（§2.4）：质量项，编译无关，同样不阻塞。


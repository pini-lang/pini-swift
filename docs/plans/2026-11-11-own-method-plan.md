# 本型方法：|own 的调用面与静态派发

- 状态：主链路已落，四类载体在两后端同值；余项与读数见「执行记录」。
- 基线：`bfbdee07`（`main`，与 `origin/main` 一致）。
- 上承：`docs/spec/pini-reference.md` 的 §4.6 与 §5.2；IR 节点语义以 `docs/spec/ir-contract.md` 为准，运行时符号以 `docs/spec/runtime-abi.md` 为准。
- 旁证：分片与细化写法、「尚未定」写法沿用本仓既有实施计划的体例；两份原计划文档不在本仓，本件不指向具体计划文件。
- 性质：实施计划。现状判定收在「现状取证」章，不另立审计报告；本件不修源码、不跑探针。
- 范围：首版只做非泛型结构体、对象块、给定块、枚举块上的本型方法，编译期按类型名静态派发；不做泛型特化、trait 默认实现、继承与组合展平、`own` 作表达式值、跨模块可见性。四类载体由**首版范围**裁定；声明位置统一是扩展块，枚举体自带 `methods` 的登记缺口不进首版。
- 取证口径：源码与规范原文的静态清点，未跑编译器探针；运行期读数由**补判据**片开工后先补。
- 前提：单仓单会话开发，无外部并发约束；改动须过 `hooks/pre-commit` 的注释、格式、文档链接三条门禁，并按 `GIT_WORKFLOW.md` 走特性分支。

## 结论

`docs/spec/pini-reference.md`:1061 的 `TODO(本型方法)` 把承接条件写成一句：先定类型接收者的调用语法与派发规则。**调用面**已裁定取点号复用，本件据此展开其余裁决。

| 方案 | 调用写法 | 落点 | 代价 |
|---|---|---|---|
| 点号复用（已取） | `点.原点()` | 复用 `.member(.identifier(类型名), 名字)` 与 `.call`，零新增 token 与表达式 case | 要新增「接收者是类型名」的通用分支，定与枚举用例构造的消歧优先级，放行给定块类型名在接收者位；与 §4 的「类型名不进值位」承诺撞形 |
| 新限定符 | `点::原点()` | 独立语法位，无歧义 | 词法、Token、解析、打印、去糖、展开、签名序列化共 15 个以上文件，新增表达式 case 触发 8 处无 `default` 的穷尽 switch 编译失败 |

**调用面**取点号复用：本型方法是给类型的方法，类型名作接收者与 Swift 的写法同源。可承载性不由 `Optional.none` 证明，那在推断与降载两层都是硬编码特判；真正的先例是降载期「先查枚举表、再看变量」的通用决议（`Sources/PiniIR/IR/IRLowerer.swift`:3270，`色彩.绿`），类型名作接收者已经有可拦截的位置。切换触发条件：若**消歧优先级**在实测中出现符号表判不了的同名冲突，再回到**新限定符**。

| 裁决 | 内容 | 代价 |
|---|---|---|
| 目标 | 让本型方法以类型为接收者、编译期静态派发，方法体不带隐式 `self` | 不提供运行期多态，子类型与特征不能覆写 |
| 次序 | 先**定契约**，再**立表**、**收调用**、**改降载**，最后**通后端**与**补判据** | 契约没定，后面几片各自猜 |
| 边界 | 不动既有方法数组的读数，不新增运行时符号 | 拿不到跨模块的静态派发，首版只在本模块内成立 |

一句话：机械零件大半已齐，缺的是**两类方法的分道**与**类型接收者的既有决议次序改写**，不是从零造一条新管线。

## 现状取证

| 事实 | 位置 | 对计划的约束 |
|---|---|---|
| 本型方法修饰符 `own` 声明侧已通：函数声明的 `FuncDecl.modifiers` 保留修饰符字符串，扩展块规则 3.14 与实例方法修饰符一并放行 | `Sources/PiniSyntax/AST/Declarations/FuncDecl.swift`:6、`Sources/PiniSyntax/Parser/Parser.swift`:776-811、`Tests/PiniTests/TypeMethodModifierTests.swift`:19-32 | 不需新增 token 或表达式 case 就能写声明；现有单测只钉语法位 |
| `docs/spec/pini-reference.md`:1110 写「类型体只含字段/用例，方法须移扩展块」；现有 `|own` 单测也把方法写在 `((点))` 扩展块里 | `docs/spec/pini-reference.md`:1108-1113、`Tests/PiniTests/TypeMethodModifierTests.swift`:21-28 | 声明位置统一是扩展块，四类载体只决定方法挂到哪个类型名下 |
| 方法登记有两个入口：类型体内方法走 `defineMethod`，扩展块方法走 `registerExtensionMethods`，后者按 `x.targetType` 挂到全部载体且不读 `modifiers` | `Sources/PiniSemantics/Type/TypeChecker.swift`:1541, 1573, 1607, 1778-1787, 1830-1834 | **立表**片的分流主入口是扩展块登记，不是三处类型体登记；两处都要按 `own` 分流 |
| `TypeChecker` 读 `modifiers` 的 `test` 与 `unsafe`，但不读 `own` / `self` | `Sources/PiniSemantics/Type/TypeChecker.swift`:533, 1513, 2110 | 现状是「声明能写、一调用就错」；准确说法是不做本型分流，不是不读修饰符 |
| 类型环境已有一张按类型名索引的方法签名表，字段名 `typeMethods`，语义上是实例方法表 | `Sources/PiniSemantics/Type/TypeEnvironment.swift`:54, 187-207, 316-340 | 新表另起主题词；IR 层新字段不复用 `typeMethods`，否则同一个词两层反义 |
| 降载时 `lowerMethod` 强制注入首位 `self`；`IRTypeDecl.methods` 的「每个方法都已 self-parameterized」契约写在源码注释，不在 `docs/spec/ir-contract.md` 的条目里 | `Sources/PiniIR/IR/IRLowerer.swift`:2101-2135、`Sources/PiniIR/IR/IRNode.swift`:659-684 | 本型方法不能塞进现有方法数组，否则参数表错位；`IRTypeDecl(` 构造点全仓 2 处（`Sources/PiniIR/IR/IRLowerer.swift`:2098、`Tests/PiniTests/IRValidatorTests.swift`:150） |
| 成员调用按裸名查源码声明、按 `方法__类型` 发普通 `.call`，receiver 作首实参 | `Sources/PiniIR/IR/IRLowerer.swift`:4984-5039 | 同名实例方法与本型方法会撞，命名规则须先定 |
| 两个后端按数组遍历发射或展平，并按 mangle 名注册分发表 `moduleFunctions` 与 `methods` | `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift`:128, 535-538, 571-575, 6024、`Sources/PiniHost/Interpreter/IRExecutor.swift`:124-127, 260, 452、`Sources/PiniIR/IR/IRModule.swift`:334-344、`Sources/PiniIR/IR/IRValidator.swift`:158, 184 | **通后端**不只是多遍历一次：新数组须在两张分发表、`displayNames` 与 `IRValidator` 各注册一次，否则 `.call` 查表 miss、诊断名还原不了、撞名无人拦 |
| `own` 作类型标注已通，作表达式（`selfTypeKeyword`）推断返回空、降载主体无分支 | `Sources/PiniSemantics/Type/TypeChecker.swift`:945-953、`Sources/PiniSemantics/Type/TypeInference.swift`:286、`Sources/PiniSyntax/Parser/Parser.swift`:2817、`Sources/PiniIR/IR/IRLowerer.swift`:6187 | `docs/spec/pini-reference.md`:1340 的「`own` 仅本型方法内可用」是第二个缺口；`Sources/PiniIR/IR/IRLowerer.swift`:6187 的 `kindName` 已有 `selfTypeKeyword` 分支，别漏改 |
| 「类型名作接收者」有两条既有读数：`Optional.none` 是关键字构造的同构 AST 加两层硬编码特判；枚举型名限定用例 `色彩.绿` 是「先查枚举表、再看变量」的通用决议 | `Sources/PiniSyntax/Parser/Parser.swift`:2856-2861、`Sources/PiniSemantics/Type/TypeInference.swift`:249-253、`Sources/PiniIR/IR/IRLowerer.swift`:3258-3266, 3267-3288 | 点号复用要动的是后者那条既有决议次序；**收调用**片先钉住两条读数 |
| 给定块类型名出现在值位由静态检查直接拒绝，源码注释举的例子含 `配置.方法()`；`.member` 的接收者会递归进这层检查 | `Sources/PiniSemantics/Type/TypeChecker.swift`:2568-2578, 2834-2835, 2665-2673、`Sources/PiniSemantics/Type/TypeError.swift`:35-38、`Sources/PiniSemantics/Common/Diagnostic.swift`:253 | 给定块上的 `类型.方法()` 会被 `E4-015` 拦在语义层；**立表**与**收调用**片须按「成员已登记为本型方法」放行这一支，其它值位不放宽 |
| `docs/spec/pini-reference.md`:1309 承诺「类型名不进值位，裸写作接收者被拒」 | `docs/spec/pini-reference.md`:1309-1310 | 与点号复用撞形；既有承诺段不删不改，就地加 `TODO(本型方法)` 细分说明 |
| 枚举体自带 `methods`，方法体检查会走，但 `enumDecl` 登记分支只有 `defineEnum` 加 trait 方法 | `Sources/PiniSyntax/AST/Declarations/EnumDecl.swift`:8、`Sources/PiniSemantics/Type/TypeChecker.swift`:1616-1639, 1826 | 与「方法须移扩展块」的既有承诺冲突；首版不补这条缺口，记进「风险」章 |
| `displayNames` 把 mangle 过的 IR 名还原成源码写法 `类型.方法` | `Sources/PiniIR/IR/IRModule.swift`:30-31, 332-344 | 新增改名段要给一份还原规则，诊断才读得懂 |

注意 `examples/` 下 `|own` 与独立词 `own` 零命中；纯子串 `own` 有 7 处，都是 `owned` / `_owner` 这类英文与字段名，不是关键字。这与 `TODO(本型方法)` 里那句「仓库也没有可运行示例」一致。

## 裁决

### 命名与落位

`TypeEnvironment` 并行一张**本型方法表**（字段 `ownMethodSignatures`）；IR 名由 `Sources/PiniIR/IR/IRName.swift` 的 `ownMethod(_:on:)` 统一给出 `own__方法__类型`，与实例方法 `方法__类型` 分道。本型方法降载成**顶层 `IRFunction`**，不是 `IRTypeDecl` 的新数组：`IRModule.functions` 本就被两个后端、`IRValidator` 与 `displayNames` 遍历，挂上去即自动发射、验证、还原展示名，调用点不传 receiver、方法体不带 `self`。

决策理由：枚举无名义类型归并路径（`Sources/PiniIR/IR/IRLowerer.swift`:340），若按原案给 `IRTypeDecl` 加字段，四类载体里的枚举得另建一条 IR 通道；顶层函数与内建类型扩展方法是同一条既有通道（`builtinExtensionMethods`），一处覆盖四类载体，后端零改动。代价是「落点」表中 `IRNode.swift`、`IRModule.swift`、`IRValidator.swift` 与两个后端的行不再需要改，计划据此收口。

### 语言面契约

本型方法是给类型的方法。调用写作 `类型.名字()`，接收者是类型名，编译期按类型名静态派发；方法体不带隐式 `self`，`self` 只属于本身方法，`own` 作类型标注仍按既有规则。`类型.名字` 与枚举用例构造撞形时，先按本型方法解析，未命中再按用例名反查父枚举，最后落到字段与本身方法；本型方法与本身方法同名时各按各的写法解析，互不遮蔽。

声明位置是扩展块，与 `|self` 并列；首版载体为结构体、对象块、给定块、枚举块，非泛型。泛型特化、trait 默认实现、继承与组合展平、`own` 作表达式值、跨模块可见性不进首版。

注意 本节的「首版」是计划口径，只写在本件；`docs/spec/pini-reference.md` 是权威规范，不收实现状态、排期与内部结构，实现到位后由**文档收口**片按事实订正。

### 调用消歧

裁定优先级：接收者是已登记类型名时先查**本型方法表**，未命中再按用例名反查父枚举，最后落到字段与实例方法。这条会反转降载期「先查枚举表、再看变量」的既有次序，故判据写在**定契约**片，**收调用**片先钉住 `Optional.none`、`色彩.绿` 与 `形状.圆(...)` 的既有读数再改分支，逐条对比，不静默加例外。若实测出现期望类型也不足以收敛的同名冲突，**调用面**的裁定要重新过一遍。

### 载体登记

**首版范围**含结构体、对象块、给定块、枚举块，四类载体统一由扩展块 `registerExtensionMethods`（`Sources/PiniSemantics/Type/TypeChecker.swift`:1781）按 `x.targetType` 登记，一处覆盖四类。类型体内若写了带 `own` 的方法，:1541、:1573、:1607 三处同样按修饰符分流。枚举体 `e.methods` 的登记缺口与「方法须移扩展块」的既有承诺冲突，首版不补，也不在 `enumDecl` 分支另开路径。

注意 三项已裁定，**定契约**片可以动笔；但 `docs/spec/pini-reference.md` 的 `TODO(本型方法)` 与 :1309 属未实现项与既有承诺，按权威规范改动原则保留原文，实现到位前零改动，不按裁定改写，也不把实现状态写进规范。

## 落点

| 文件 | 改什么 |
|---|---|
| `Sources/PiniSemantics/Type/TypeEnvironment.swift` | 新增本型方法表与查询；既有 `typeMethods`（实例方法表）不动 |
| `Sources/PiniSemantics/Type/TypeChecker.swift` | `registerExtensionMethods` 与三处类型体登记按 `own` 分流；`givenBlockTypeInValuePosition` 门禁按本型方法放行；`.member` 与调用校验增加类型名接收者分支；不动 `enumDecl` 登记分支 |
| `Sources/PiniSyntax/Parser/Parser.swift`、`Sources/PiniSyntax/AST/Expressions/Expression.swift` | 点号复用下不改 |
| `Sources/PiniIR/IR/IRLowerer.swift` | `lowerMethod` 分叉、`Optional.none` 特判不动、既有枚举表决议前插入本型方法查表、调用点不传 receiver、独立改名段 |
| `Sources/PiniIR/IR/IRNode.swift`、`Sources/PiniIR/IR/IRModule.swift` | `ownMethods` 字段与 `displayNames` 还原规则 |
| `Sources/PiniIR/IR/IRValidator.swift` | 新数组的形状与撞名规则；同名两类方法撞名在此拦，不落到用户诊断 |
| `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift`、`Sources/PiniHost/Interpreter/IRExecutor.swift` | 发射、展平并把新名字注册进 `moduleFunctions` 与 `methods` |
| `Tests/PiniTests/OwnMethodTests.swift`（拟新建） | 声明、调用、四类载体、同名两类方法共存、负例各一组 |
| `examples/own-method.pini`、`examples/golden/own-method.pini.out`、`examples/README.md`（拟新建或改） | 一条能过 check / run / run-llvm / golden 四条腿的可运行示例，头部三要素与映射表登记照 `examples/README.md` 约定 |
| `docs/spec/pini-reference.md` | **定契约**片不碰；实现到位后由**文档收口**片按事实订正 §4.6、§5.2 与 `TODO(本型方法)`，未实现项保留原文、就地加标记，不删段、不按裁定改写 |
| `docs/spec/ir-contract.md` | `IRTypeDecl` 结构契约不在本件条目内；**改降载**片核 §5.8 结构不变量的适用性，需要立条目则按「先改本件再改代码」办 |
| `Sources/PiniSemantics/Resources/Diagnostics.zh.toml`、`Sources/PiniSemantics/Resources/Diagnostics.en.toml` | 零占号，两份表都不改；负例复用 `E4-009`，见「诊断」章 |

## 分片

| 分片 | 内容 | 验收 |
|---|---|---|
| 定契约 | 在计划文档写定语言面契约；`docs/spec/pini-reference.md` 原文一律不动，实现到位后由**文档收口**片按事实订正 | 每条写法都能指回一处源码判据；权威规范 diff 为空 |
| 立表 | 本型方法表与两处登记入口的 `modifiers` 分流；给定块类型名门禁放行 | 四类载体同名实例方法与本型方法各查各表，互不遮蔽；`swift test` 全绿且 `swift test list` 条目数不减 |
| 收调用 | `.member` 识别类型名接收者，既有枚举表决议次序改写 | `Optional.none`、`色彩.绿` 与 `形状.圆(...)` 读数逐字不变 |
| 改降载 | `lowerMethod` 分叉、独立改名段、调用点不传 receiver | 同名两类方法 IR 名不撞，参数表逐位可对 |
| 通后端 | 发射、展平并注册两张分发表 | `run` 与 `run-llvm` 同值 |
| 补判据 | 声明、调用、四类载体、共存、负例单测；一条可运行示例；差分探针 | `swift test list` 条目数只许不减；`tools/examples-gate.py` 四条腿全绿 |
| 文档收口 | 按事实订正 spec 的 `TODO(本型方法)`，落本件的执行记录 | `tools/check-doc-links.sh` 通过；注释、格式、文档链接三条门禁过 |

**定契约**先落：**立表**、**收调用**、**改降载**三片都读同一份契约，契约没定就各自猜。**补判据**与**文档收口**最后收，不分散到各片顺手改。

## 细化

### 两项补充裁定

**提交粒度**：取细分，按下面的提交单元一笔一笔落，约 11 笔。理由是本件已写「挤成一笔时，语料变红分不清是哪条判据放的」；门禁放行、次序改写、结构新增各自可单独回退。代价是每笔都要跑三条门禁。

**声明位置**：首版只认扩展块写法 `((类型名))` 里的 `|own`，枚举体自带 `e.methods` 的登记缺口不补。Swift 的 `Type.method()` 静态派发已由**调用面**兑现；声明位置是 Pini 自己的语法约束（`docs/spec/pini-reference.md`:1110），为它改既有承诺会放大量级，不进首版。缺口记进「风险」章。

### 开工前置

工作区现有两份 11-08 删除未暂存、本件未跟踪、`docs/spec/pini-reference.md` 的引用修订未提交。按 `GIT_WORKFLOW.md` 从 `main` 切 `dev-agent-pini-own-method`，把这三件收成特性分支上的第一笔提交，不在 `main` 上落笔。身份取 `Pini Dev <dev@pini.local>`，`--no-ff` 合回后显式切回工作分支。先 `swift build` 保证 `.build/debug/pini` 在，否则格式门禁直接红；全量 `swift test` 走前台单实例，不后台挂起。

### 提交单元

| 分片 | 提交单元 | 具体动作 | 验收 |
|---|---|---|---|
| 定契约 | 契约落笔 | 在计划文档「裁决」章写定语言面契约（调用写法、消歧优先级、`self` / `own` 可用范围、四类载体与边界）；`docs/spec/pini-reference.md` 一字不动 | 每条写法指回一处源码判据；权威规范 diff 为空；文档链接门禁过 |
| 立表 | 签名分表 | `Sources/PiniSemantics/Type/TypeEnvironment.swift`:54 旁新增 `ownMethodSignatures` 与定义／查询；`typeMethods` 不动。`Sources/PiniSemantics/Type/TypeChecker.swift`:1781 与 :1541 / :1573 / :1607 按 `modifiers.contains("own")` 分流 | `swift test` 全绿且 `swift test list` 条目数不减；同名两类方法各查各表 |
| 立表 | 门禁放行 | `Sources/PiniSemantics/Type/TypeChecker.swift`:2572-2577 的 `givenBlockTypeInValuePosition` 在 `.member` 接收者位按「成员已登记为本型方法」放行；:2665-2673 的 callee 豁免不动 | 给定块上 `类型.方法()` 能过 `check`；把给定块名当实参仍报 `E4-015` |
| 收调用 | 接收者识别 | `Sources/PiniSemantics/Type/TypeInference.swift`:249-276 的 `.member`：:251 的 `Optional.none` 特判不动，前面加「接收者是已登记类型名 → 查本型方法表」 | 三条既有读数逐字不变 |
| 收调用 | 次序改写 | `Sources/PiniIR/IR/IRLowerer.swift`:3258-3288：:3261 特判不动，在 :3270「先查枚举表、再看变量」之前插入本型方法查表 | `Optional.none`、`色彩.绿`、`形状.圆(...)` 读数不变 |
| 改降载 | 降载分叉 | `Sources/PiniIR/IR/IRLowerer.swift`:2101-2135 `lowerMethod` 不注入首位 `self`、用独立改名段；:4984-5039 调用点不传 receiver；:6187 核 `kindName` 的 `selfTypeKeyword` 分支 | 同名两类方法 IR 名不撞，参数表逐位可对 |
| 改降载 | 结构新增 | `Sources/PiniIR/IR/IRNode.swift`:661-685 加 `ownMethods` 与 init；两个构造点（`Sources/PiniIR/IR/IRLowerer.swift`:2098、`Tests/PiniTests/IRValidatorTests.swift`:150）同步；`Sources/PiniIR/IR/IRModule.swift`:334-344 多遍历一次；`Sources/PiniIR/IR/IRValidator.swift`:158, 184 补形状与撞名规则及阴性夹具；核 `docs/spec/ir-contract.md` §5.8 适用性 | `IRValidator` 阴性夹具会响；撞名不落到用户诊断 |
| 通后端 | 双端注册 | `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift`:535-539, 571-575 注册进 `moduleFunctions` 并发射；`Sources/PiniHost/Interpreter/IRExecutor.swift`:260 注册进 `methods`（查表在 :452） | `run` 与 `run-llvm` 同值 |
| 补判据 | 负例覆盖 | 新建 `Tests/PiniTests/OwnMethodTests.swift`，对齐 `import Testing` + `@Test` / `#expect`；覆盖四类载体、同名共存、`E4-009`、`self` 误用 `check` 失败、给定块名当实参仍 `E4-015`、三条既有读数 | `swift test list` 条目数只许不减 |
| 补判据 | 示例落地 | `examples/own-method.pini`（头部三要素照 `examples/hello.pini`）、`examples/golden/own-method.pini.out`、`examples/README.md` 映射表；`examples/gate-baseline.tsv` 不增行 | `tools/examples-gate.py` 四条腿全绿；差分探针过 |
| 文档收口 | 事实订正 | 按事实订正 `docs/spec/pini-reference.md`:1165 规则表与 `TODO(本型方法)` 状态；未实现项原文保留加标记；本件落执行记录 | 三条门禁全过；合回主干前跑容器 CI |

每笔提交前分开跑 `bash hooks/comment-lint.sh`、`bash tools/check-doc-links.sh`、`PINI_BIN=.build/debug/pini python3 tools/fmt-gate.py`。每片各自可回滚，语料变红时按提交单元定位，不跨片回滚。

注意 每片各自可回滚：**立表**纯新增不改行为，**收调用**只碰接收者分支，**改降载**只碰方法降载与调用点。挤成一笔时，语料变红分不清是哪条判据放的。

## 诊断

**码位配额**裁定为零占号：首版不新增任何编号，两份诊断表零改动。

| 情形 | 处置 | 要点 |
|---|---|---|
| 类型上无此本型方法 | 复用 `E4-009`（`TypeError.unknownMember`，`Sources/PiniSemantics/Common/Diagnostic.swift`:247，`Sources/PiniSemantics/Resources/Diagnostics.zh.toml`:129-130） | 「类型 '{typeName}' 没有成员 '{memberName}'」的载荷天然适配，点名类型与成员 |
| `self` 误用于本型方法体、实例方法里用 `own` | 不设专用码位 | 本型方法体不登记 `self` 变量，`.selfKeyword` 在 `Sources/PiniSemantics/Type/TypeInference.swift`:284 取空、`.selfTypeKeyword` 在 :286 取空，落既有推断失败通路；负例单测验 `check` 失败，不验码位。要一句专门文案须新增编号，单独立项，不进首版 |
| 同名两类方法撞名 | `Sources/PiniIR/IR/IRValidator.swift` 拦，实现漂移而非用户诊断 | 作者不该看到 |

现表读数：E4 段最大 `E4-035`、E7 段 `E7-007`；`E4-036` 全仓只在本件被提及过，两份诊断表均无此码位，先前「只出现在某份计划的建议里」的说法无法证实，已订正。`E6-008`（`Sources/PiniSemantics/Resources/Diagnostics.zh.toml`:249-253）的注释「编号归属一经分配即不复用」是零占号决定的依据：编号是不可逆资源，能不占就不占。本裁定下两份表不动，`tools/diagnostics-parity-check.py` 保持绿。

## 风险

| 风险 | 说明 | 处置 |
|---|---|---|
| 消歧优先级改变既有语义 | `类型.名字` 同时可能是枚举用例构造；降载期既有次序是「先查枚举表、再看变量」，改成先查本型方法表会让 `形状.圆(...)` 静默换义 | **收调用**片先钉三条既有读数，逐条对比后再改分支，不静默加例外 |
| 给定块类型名被拦在语义层 | `checkExpression` 的 `givenBlockTypeInValuePosition`（`E4-015`）把 `配置.方法()` 当类型名进值位拒绝；`.call` 的显式构造豁免只覆盖 callee 位 | **立表**片按「成员已登记为本型方法」放行这一支，其它值位一律不放宽；负例覆盖把给定块名当实参 |
| 语言面既有承诺撞形 | `docs/spec/pini-reference.md`:1309 写「类型名不进值位，裸写作接收者被拒」 | **定契约**片不碰原文；语言面契约收在计划文档，实现到位后由**文档收口**片按事实订正，不按裁定反推规范 |
| 枚举体自带 `methods` 的登记缺口 | `Sources/PiniSyntax/AST/Declarations/EnumDecl.swift`:8 允许写方法、:1826 也会检查方法体，但 `enumDecl` 登记分支只有 `defineEnum` 加 trait 方法；补登记会与「方法须移扩展块」的既有承诺冲突 | 首版只认扩展块写法，缺口不补、不删；要接则单独立项并先改规范 |
| `own` 作表达式值未接线 | 推断返回空、降载主体无分支；若首版不接，§5.2 的承诺继续悬空 | **定契约**片写进边界；要接则单独立项，不塞进本计划 |
| `using` 形参位置 | `Sources/PiniSyntax/Parser/Parser.swift`:3480-3498 的 `UsingParamPosition` 定义里，:3483 只是 `.typeBodyMethod` 的文档注释；拒绝逻辑在 `rejectionReason`，本型方法没有 receiver 可插默认实例 | **立表**片复核位置规则，必要时在解析期明确拒绝并给文案 |
| 注释门禁 | 新增注释禁裸待办、日期、版本、行号、文档名与改动史 | 按注释门禁的 C1 至 C8 判据（定义在 `tools/check-comment-lint.py`）写，提交前过钩子 |

## 已裁定

三项裁定已定，本件据此收口；裁定后先改本件，再改 `docs/spec/pini-reference.md`，最后动源码。

**调用面**：取点号复用。本型方法是给类型的方法，参考 Swift，类型名以 `类型.名字()` 作接收者。`类型.名字` 与枚举用例构造撞形时的优先级见「裁决」的调用消歧；**新限定符**只作切换备选，触发条件是实测出现符号表判不了的同名冲突。

**首版范围**：结构体、对象块、给定块、枚举块，编译期按类型名静态派发。泛型特化、trait 默认实现、继承与组合展平、`own` 作表达式值、跨模块可见性各是一片独立工作，不进首版。四类载体统一由扩展块登记，见「裁决」的载体登记。

**码位配额**：零占号。不新增编号，两份诊断表不动；负例复用 `E4-009`，`self` / `own` 作用域不设专用文案。理由与代价见「诊断」章。

**提交粒度**与**声明位置**两项补充裁定见「细化」章。

注意 三项互不等价：**调用面**定方向，**首版范围**定量级，**码位配额**定不可逆编号。三项都已裁定，但裁定解除的是本件的写作约束，不等于授权把未实现项按裁定改写进规范，也不等于把实现状态、排期与内部结构写进规范。

## 执行记录

分支 `dev-agent-pini-own-method`，自 `bfbdee07` 起。

| 提交 | 内容 |
|---|---|
| `7cceb97` | 收工作区现状：两份 11-08 文档删除、spec 引用修订、计划文档 |
| `750e6cc` | 契约归位：易腐实现内容撤出 spec，语言面契约写进本件 |
| `70b0824` | 立表片：本型方法签名表、四处登记分流、给定块接收者门禁放行 |
| `5662f25` | 主链路：命名与降载、调用点决议、四类载体示例与负例覆盖 |

读数：`swift build` 增量通过；`swift test --disable-sandbox` 673 个测试 / 100 套件全绿（11 个已知问题，较基线多 3 个新测试）；`tools/examples-gate.py` 四条腿无回归；注释、格式、文档链接三条门禁通过。`docs/spec/pini-reference.md` 只在实现到位后按事实订正 §4.6 的 TODO 与规则表，未实现项与既有承诺段保留原文。

注意 `own` 作表达式值（`selfTypeKeyword`）仍按 §5.2 的承诺悬空，推断返回空、降载主体无分支；本型方法多返回槽暂不支持，调用点明确报错。两项都单独立项，不塞进首版。

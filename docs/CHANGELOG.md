# CHANGELOG

> 宿主实现（pini-swift）**实现版本演进记录**。语言版本里程碑见 `spec/CHANGELOG.md`（语言级）；治理变更见 `spec/adr/`（决策记录）与 `spec/issue/`。
> 版本号与 `pini version` 输出同源：`PiniCore/Common/Version.swift`。

## v0.54.0 (2026-09-18)

> 本版是 `LR-4`（IR 统合为全后端枢纽，`P0`–`P5` 全 ✅）与 `P0d`（`Char` 类型落地、收格）两个里程碑的收口版本。
> ⚠️ 版本号取 **0.54.0**：语言级 CHANGELOG 此前已发布 `v0.53.0`（2026-09-07，try-else 迁移），该号已被占用、不可复用。
> ⚠️ 下方 `### 09-14 → 09-18` 为**简要收编**（该窗口 200 个提交无逐条记录）；其后各节是 09-14 之前已登记的条目，**逐条未改写**。

### 10-01

- **`readFile` 取消 64 KiB 上限，两侧同改读全文件**（`auth-70`）：`readFile` 此前按固定字节数**静默截断**
  （越限部分丢弃 · 无诊断 · **退出码 0**）。那条上限不是语言选的 —— 它继承自发射器的固定栈缓冲，
  而且与契约自己的语义列（「读取文件的**全部内容**」）直接冲突 ⇒ 删除。两侧都改：解释器直接读全；
  LLVM 侧由「`fread` 进固定栈缓冲」改为经运行时 shim（新 C ABI 符号 `bk_read_file`，分配契约同 `bk_cstr`）。
  **用户可见变化一条**：超过 64 KiB 的文件现在被**整份**读入（此前得到的是前 64 KiB，且无任何提示）。
  ⚠️ `readLine` 的 256 字节行上限**不变**（那是 `fgets` 的缓冲契约、两侧一致、且是登记在案的 A1 行为）。
  判据：新 `ReadFileBuiltinTests` 三条（超旧上限读全 / 缺文件走错误通道 / LLVM 腿同判），变异反证三条各打一条判据。
  证据：两腿各读到 70000 字节文件的末尾标记（改前两腿均只读到 65536 字节、末标记不可见、退出码 0）。

- **`split` 的分配按源串长度算 + 单文件 LLVM 入口补语义门禁**（`auth-76`）。两处独立缺陷：
  **(a) 切分路径的两处分配**（`IREmitter.emitStringSplit`）—— 两次暂存拷贝写在固定 `alloca i8, i64 1024` 上
  再 `memcpy(strlen(source))`，源串一长就砸栈；token 复制按 `strlen` 分配后 `strcpy`，终止符写到区外一字节。
  修法：暂存改 `malloc(strlen+1)` + 用完 `free`；token 复制改 `strlen+1`。⚠️ 两处都**不再用固定常数**，
  也不在循环里留变长 `alloca`（后者是 `stringSubstring` 那条已登记的教训）。**可达性**：自举的
  `makeScanner` 就是 `source.split("\n")`，源串是整份文件文本 —— 这条缺陷此前一直踩着。
  **(b) 单文件 LLVM 入口漏了语义门禁** —— `emit` / `compile` / `run-llvm` 走的 `typeCheckThenGenerate`
  只跑类型检查、不跑语义分析，而 `check` 与**模块级** `emit` 都跑 ⇒ 同一份源两条路**不同判**。
  **用户可见变化一条**：`emit` / `compile` 开始拒绝它们此前接受的源（实测：闭包引用外层变量而未写
  `capture` 行的源，此前 `emit` 照出 237 行 IR、`compile` 照印 `102`；现在四条入口一致报 `E3-008`）。
  判据：新 `EntryParityTests`（四入口同判，含阳性对照）· `SplitPathTests`（行为级两路对照 +
  产物结构级「`malloc` 尺寸不得直接取 `strlen` 结果」）。变异反证三条各打一条判据。
  证据：长源串从「原生崩（栈转储落在 `bk_array_set`）」变为两路同为 `2800` / `40`；ASan 下
  `WRITE of size 85 → 84-byte region` 消失；自举各层在 ASan 下由 3 / 19 升到 16 / 19 干净。
  ⚠️ 「门禁提速」本体**未达成**（门禁仍走双层解释、原生臂未接），剩余阻塞是**另一个族**，报告 §5 已登记。

### 09-19

- **测试树重建，框架迁到 Swift Testing**：09-18 清空的测试面开始重建。两份判定标准（规范 §6 的权威摘要与
  `spec/test-refactoring-principles.md` 细则）由 XCTest 语汇迁到 Swift Testing —— `@Test("一句话意图")` 显示名加
  函数名 `test[模块][行为]`、`#expect` / `try #require` / `Issue.record`；门控类用例的「跳过」以**可见且计数**的
  已知问题（`withKnownIssue`）承载，环境已配置而工具缺失则硬失败。**三要素与目录约定不变**：一套件一目录、
  夹具与套件同目录、夹具名即消费它的用例名。
- **语法接受面语料入库为测试**：2026-09-05 反录勘测留下的探针语料（原 `examples/probes/`）迁入
  `Tests/PiniTests/GrammarAcceptanceTests/`，一个夹具一条用例：29 条（21 接受 / 8 拒绝），其中 13 条同时钉运行产物。
  另含两条结构性判据 —— 夹具名与用例名的闭合检查、以及命令行与进程内前端**逐夹具结论一致**的对账（需指定命令行
  路径，未指定时以已知问题显式记账而非静默通过）。同批修正三处语料自身的错误：字典尾逗号的键写成裸标识符
  （语义层报未定义变量）、`while` 的 step 夹具用不可变计数器（一旦被执行即永久循环）、以及一条把「扩展块泛型约束」
  写成「类型体带约束」的名实不符。⚠️ `!` 强制解包要求 unsafe 上下文这条规则**已在实现里、尚未写进规范**，
  本批按实现记账并单独立了一条负向夹具；它是否入规范另需裁决。
- **Swift 源码缩进统一为 4 空格**：此前仓内两种风格并存（老代码 1 空格 / 级：81 个文件；新代码 4 空格：16 个文件，
  含三个最大文件 IRLowerer / IREmitter / IRExecutor）。本次用**工具链内建的** `swift format` 一次性统一
  （91 文件 / +19426 −18866 行）。配置落仓根 `.swift-format`：**只启用缩进设置，43 条可选规则全部关闭** ——
  默认规则会改写非缩进内容（拆 `;`、给集合字面量加尾逗号），且 `AlwaysUseLowerCamelCase` 会指向 `@_cdecl`
  导出的 C ABI 符号名（`libPiniRuntime` 的 `bk_*`，38 处），开着它要么门禁天生红、要么有人改绿而破坏 ABI。
  ⚠️ **未引入任何依赖、未建插件、未改 `Package.swift`**（一次性动作，不作长期设施）。配置文件的唯一作用是钉住
  4 空格；删掉它则任何一次裸跑 `swift format` 会把缩进改回工具默认的 2 空格，并连带引入上列各项改写。
  验收（**非抽样**）：`swiftc -dump-parse` 归一化后**逐文件语法树相同**（113/113，含字面量值与多行字符串内容）·
  独立 scratch 全量重建 0 错误且**警告数与改前完全相同**（255/255）· 32 条测试全绿 · 注释与文档链接两道门禁绿。
  目标一律显式列出（`Sources Tests Package.swift`）：`swift format` 的递归跳过隐藏目录，但会进入非隐藏的嵌套目录
  —— 本仓 `examples/selfhost` 是嵌套独立仓。
- **测试夹具独立一层，消掉 SwiftPM 的 unhandled 告警**：29 个 `.pini` 夹具迁入
  `Tests/PiniTests/GrammarAcceptanceTests/Fixtures/`，清单加一行 `exclude: ["GrammarAcceptanceTests/Fixtures"]`
  ⇒ 构建告警从 255 行降到 254、`unhandled` 归零。动因：SwiftPM 把目标目录内的非源文件判为 unhandled，
  而 `exclude` **只能按路径、不能按扩展名**，所以夹具必须独占一层才能一条排掉（否则每加一个夹具都要改清单）。
  加载器与套件各改一处定位（`PiniFixtureLoader` 的 `Fixtures/` 分支、套件的 `suiteDirectory`），
  其余 4 个消费点从单一属性派生、一行未动；32 条用例与夹具内容均未改。⚠️ 实测留档：改用
  `resources:` 指向套件目录会让该目录里的 `.swift` **不再被编译**，整个套件被静默丢弃 ——
  构建仍退出 0、告警也会消失，**只有「测试汇总行」能发现**，故不用那条路。
- **器械解析层跟上框架**：`tools/ir-chunk-run.py` 与 `tools/three-edge-union.py` 解析测试输出时同时认两个框架
  （套件起始行、失败行、汇总行三处形状都不同，且 Swift Testing 不产 `Executed ...` 行）；分块驱动的失败集合元素
  由「类 + 方法」二元组归一为字符串。⚠️ 只认一种框架的后果是**静默失效** —— 另一种的套件会整体落进「未跑」而被
  护栏判作废，账目看起来只是「这次读不出来」。另：`three-edge-union.py` 的两条测试边对象在 G-6c 与测试树清空后
  已不存在，今天一律读作未测，属既存状态。

### 09-14 → 09-18（简要）

- **`LR-4`「IR 统合全后端」完成**（`P0`–`P5` 全交付）：旧 AST 走查求值器与挂起引擎整体退役 —— `Interpreter` / `SuspendEvaluator` / `SuspendScheduler` / `REPL/InterpreterEngine.swift` 四文件共 **4162 行**删除，`PINI_INTERP_ENGINE` 引擎开关退役；IR 成为**全部后端共用的唯一枢纽**，语义权威由「以某一后端为定义处」上移到契约件 `docs/spec/ir-contract.md`（IR 契约）。执行通道的表述由「三通道」改为**两执行通道 × 一个诊断来源器械**（探针口径见 `docs/issue-interpreter-ir-plan-2026-09-12.md` §8.1）。
- **`Char` 类型落地**（Char 类型引入，格 `P0d`，已收格）：`Char` = **extended grapheme cluster 标量**（不是 Unicode 码点、不是 UTF-8 字节），表示**与 `String` 同构**（零新 ABI），不变式「恰含 1 个字素」归类型系统承担；FFI 既有单字节 `Char` 更名 **`CChar`**；相容桥 = **`Char → String` 单向加宽**（窄化被拒）。六字符原语签名迁移（`is_letter` / `is_ascii_digit` / `is_number` / `ord` 取 `Char`，`chr` 取 `I32` 返回 `Char`，`chars` **参数保持 `String`**、仅元素改 `Char`）。两条边界裁决：`ord` 的空串哨兵 `-1` **作废**（该签名下「空串」不可表达）；`chr` 越界由「返回空串」改为 **panic**（走 下标三通道安全模型 既定通道 `E5-005`，不新增诊断码）。
- **契约新增两个节点**（走 spec §1.3）：`join`（`await` / `wait` 的挂起点，IR join 节点）与 `detachStmt`（`detach` 语句，IR detach 节点）⇒ 契约语句 **16 → 17**、合计 **61 → 62**。⚠️ 两者本批**只落节点面、行为未接**（节点今天不可达），降载与两台引擎的行为另格。
- **挂起模式实现退役**（挂起模式退役）：`await` / `wait` **保留且语义不变**，退役的只是「释放当前 OS 线程」这一**实现形态**（CPS 求值器 + 挂起调度器）；生产面实测**零启用** ⇒ **对用户程序零可见影响、非破坏性**；⚠️ **不承诺移除**（故分级取 `Provisional` 而非 `Deprecated`）。
- **语言级新裁决登记**（泛型枚举构造形态 / 数值字面量转换 / 标签 break 定向范围 / 静态层优先）：泛型枚举用例构造形态（限定形态 `枚举名<实参…>.用例(载荷…)` 为准、裸名形态为糖）；数值字面量**不**隐式转小数、`abs` 放宽到整数且保型（**本件只登记，实现另批**）；标签 `break` 可定向**任意带标签结构**（含 `if` 块）、`continue` 仅循环标签有效、内层同名标签遮蔽外层、标签与变量属独立命名空间；错误发现**静态层优先**（静态可判定者须在类型检查 / 降载层被拒，静态层不得抢报运行期错误）。
- **文档面治理**（语言参考纳入事实源 / 036）：语言参考纳入事实源（分面权威、成熟成果由规范**递交**沉积）；路线图退役（实测 79% 内容过时）后抽北极星执行指引入项目规范。
- ⚠️ **本版对外登记的一处已知破损**：selfhost 的 `check` 因字符原语**参数面 5 处**（缺口台账 `G70`，跨仓）现为**红**。宿主四道门禁**均显式排除** selfhost ⇒ 不污染宿主门禁，但该红由 `P0d` 造成、**不因收格消失**。
- ⚠️ **随收格登记、未排期的后续单元**（各须单独点名）：LLVM 端 grapheme 运行时 shim（缺口台账 `G69`）· selfhost 字符原语参数面 5 处（`G70`）· 字符字面量 `'c'` 格 · selfhost 语义面重校（授权轨 `auth-6`）。

> 批 7（远程 tap）当时未登记，此处一并补上；批 8 为 G52 工单的收尾补修。

### Breaking
- **IO 三项语义对齐到 IR 契约（2026-09-14，P2b「IO 语义格」）**：`IR 契约` D3 的 A 组三项由「已裁、解释器未改」落地为两侧一致——**改的是解释器侧**，LLVM 侧维持不变。用户可见变化三条：① **`readLine` 不再剥离行终止符**（输入 `"line\n"` 现返回 `"line\n"`，此前返回 `"line"`），且超 **255 字节**的行被截断；② **`readFile` 上限 65536 字节、超出静默截断**（此前无上限——读大文件会返回不完整内容而无任何提示）；③ **`writeFile` 返回写操作整型结果码**（成功 `0`），不再是 void/`null`。另修 LLVM 侧 `readLine` 在输入耗尽时的未定义行为：`fgets` 的 NULL 此前被直接交给 `%s`，实测打印 `(null)`（7 字节）而解释器输出空串（1 字节），现两侧一致为空串。两处尺寸常量单源化为 `Sources/PiniCore/Common/IOLimits.swift`（解释器与发射器共用，防各自漂）。**迁移面实测零受害**：全仓无超 64 KiB 的 `.pini`、selfhost 语料均 ~2 KiB，受害测试期望值已随改（`Tests/PiniTests/IOTests/`）。上限本身的合理性**未裁**、另案：`docs/issue-io-limit-from-emitter-2026-09-12.md`（含**超长行流位置语义**补记——该分歧仍存在）。证据：readLine 保留行终止符、readFile 截断。
- **LLVM 后端整体替换为 IR 管线（2026-09-12，M6b 翻转批）**：旧的直接发射后端（`IRGenerator` / `IRTypeMapper` / `IRGenError` / `Emit/` 族，共 11 文件 5443 行）与迁移期开关 `PINI_IR_PIPELINE` 一并删除，`emit` / `compile` / `run-llvm` 恒走 `IRLowerer → IREmitter`，`IR` 成为唯一代码生成路径。用户可见变化三条：① `emit` 对模块成员文件**恒输出包级 IR**（此前取决于迁移开关是否置位）；② LLVM 通道 `f64` 打印**不再补足 6 位小数**（`3.000000` → `3.0`，与解释器一致）；③ LLVM 通道**字符串相等判定修正**（夹具 `testDiffStringEquality` 在旧后端输出 `false`，现与解释器一致输出 `true`）。此外 **22 个旧后端拒绝的样例现可由 LLVM 通道运行**（含 `cow` / `array-basic` / `multidim` / `slice` / `try` / `ffi` / `object` / `enum-dot-case` 八个示例），1 例旧后端崩溃（`testDiffFloatPrint`）随之消失。证据：执行与契约套件迁到 IR 管线 + 旧代码生成器整体删除；计划与完成记录见 `docs/issue-llvm-rewrite-plan-2026-09-07.md`。

### Added
- **IR 引擎实现 IO 三节点（2026-09-14，P2b「G9」）**：`fileWrite` / `fileRead` / `readLine` 三处打靶点（`throw not implemented`）补齐为实现，逐臂镜像解释器——同一 `IOLimits` 上限、同一 `resolveIOPath` 基准解析、同一错误文案，差异仅在「非 String 实参」的英文报错用词（已登记不修）。用户可见变化一条：**IR 通道下的这三条内建调用由「报错退出」变为可用**（`fileWrite` 返回整型码、`fileRead` 走 64 KiB 静默截断、`readLine` 保留行终止符且在输入耗尽时返回空串）。本格使**打靶点 3 → 0**，`Sources/` 全树不再有 `notImplemented` 残留，P2b 三格清空；**阻塞槽零新增**（`FLIP BLOCKERS 27 → 27`）。附带补齐**基准管道**（用户裁定「做满 6/6」）：`IRExecutor` 新增 `programBase`，`PiniCLI` 把 `absoluteProgramBase(path)` 上提到引擎分派之前，使 IR 通道与 AST 通道取**同一个值**（入口文件所在目录），非前缀相对路径不再静默读 CWD 的同名文件。三个新差分夹具（写码 `0\n7\n` / 读上限 `65536\n` / 读行保留终止符 `6\n`）落在 `IRDifferentialTests`；`IRExecutorTests` 的「Fail-loud gaps」表整段删除（补三臂后零引用，其防回归断言改由差分夹具承担）。夹具 316 → 319。证据：IO 三节点在 IR 引擎侧实现。
- **LLVM 歧义 case 构造的期望类型静态决议（2026-09-07）**：跨枚举同名 case 的点号/裸名构造 `.圆(3.0)` / `圆(3.0)` 在 LLVM 端经 checker 静态决议表（`BareCaseResolutionRegistry`）消歧——`enumCaseQualifiedKey` 歧义分支查表命中即按期望类型父枚举构造（对齐解释器通道），未命中维持既有报错（fail-open）；位置键对齐：call 形态两侧均用外层 call 的 loc（`generateCall` 签名加 `at:` 线程），无实参形态用表达式自身 loc；唯一名路径零改动（golden IR 不变）。此前 LLVM 端歧义名一律报 E6-004 要求限定形式（D-3 报错 + 立案）。详见 `docs/spec/issue/archive/issue-llvm-dotcase-expected-type-2026-09-04.md`
- **门控陈旧夹具收口 + 双后端缺键/换行语义对齐（2026-09-07）**：① LLVM 单参/插值 print 补发尾部换行（`@fmt_newline`；此前仅多参 print 带换行，双后端 stdout 分歧被测试空白归一化掩盖）；② 字典缺失键语义对齐 G48 三通道——`bk_dict_get` 缺键改 `bk_panic`（原「NULL → 补零值」/print 位「打 null」特例移除，与解释器 panic 一致）；③ D3 夹具迁移 G57 字典 `=` 记法并移除三通道前的缺键打 null 残留行；④ `testArraySubscriptWriteBothBackends` 转 D1 边界负向断言（无门控恒可执行）。详见 `docs/spec/issue/archive/issue-gated-stale-fixtures-2026-09-05.md`
- **trait-body 终止性修复（2026-09-06）**：trait 块后接任何后续顶级声明（结构块/扩展块/对象糖/import/export/后续特征块）解析失败——终止检查 `isTopLevelDeclStart()` 被包在 `if justDedented` 门内，顶格方法（spec 合法形态）与后续声明间无 dedent 时检查被跳过。修复：`parseTraitDecl` 循环 else 分支前加无条件收束（对齐扩展块循环）。GCT 三钉（trait+结构块 / trait+扩展块 / 多带体方法回归）；spec trait-body 产生式加终止注记 + IDENT 同形歧义登记（trait 后跟顶级裸函数被吸收为 trait-method，spec 贪婪语义与宿主一致，规避法已注记）。详见 `docs/spec/issue/archive/issue-trait-body-termination-2026-09-05.md`
- **特征扩展块 `<<T>>` 重新引入（2026-09-06）**：批③曾以「词法不可达」移除 spec 产生式，经用户裁决推翻（行首 `<<` 可消歧）后按治理流程重新引入实现。词法消歧 = **行首 `<<` 拆为两个 `.lessThan` token**（Parser 顶层分派本就期望该 token 对 → traitExt 扩展块，主体零改动；行首作表达式起始位无前缀 `<<`，零歧义），行内 `<<` 维持移位合并；闭合 `>>` 行内恒合并为 `.rightShift`，traitExt 闭合位接受合并态与分离态（`<<T>>`/`<<T >>`）。GCT 双向钉：行首 `<<动物>>` → extensionDecl(kind: traitExt) + trait-body 方法、行内 `a << 2` 维持 binary(op: .leftShift)。spec §A extension-decl 产生式加落地注。详见 `docs/spec/issue/archive/issue-trait-extension-reintroduce-2026-09-05.md`
- **数组元素标注 `[T]` 语义检查（批 F）**：`[T]`/`[K: V]`/`{T}` 标注对集合字面量初始化、字面量赋值右值、Array.append 实参做逐元素类型检查（期望类型下推，通配 `_`/`Any` 放行）；标注仅做检查——内建特征化 签名契约不动（append 仍返回新数组），无标注累积器 `var ys = []` 语义零变更（实施前实测 `[1, "a"]` 混型与 `append("a")` 均静默通过）
- **点号用例构造 `.caseName` / `.caseName(args)`（批 E）**：前导点 = 成员意图标记（D-1 与 Swift `UnresolvedMemberExpr` 同构：解析期专用未解析节点，决议在类型检查阶段期望类型优先——期望类型命中 > 唯一父枚举回退 > 歧义拒绝）；成员意图不受本地位遮蔽影响；内建 Optional `.some`/`.none` 直达；spec primary-atom 产生式同步入 §A。解释通道全量可用；LLVM 端唯一名可用、歧义名 unsupported（D-3 报错 + 立案，跟踪于 issue-llvm-dotcase-expected-type；2026-09-07 已收口——歧义名经 checker 静态决议表消歧，见 Added 2026-09-07 条目）
- **字符谓词 LLVM 后端（批 C1）**：`is_ascii_digit` 实现（C 字节串首字节判 ASCII [0-9]，ASCII 域与解释器 grapheme 首字符一致，空串 NUL 自然 false）；`is_letter`/`is_number`/`chars` 显式 unsupported（E6-002——需运行时 Unicode 表 / grapheme 切分，v1 不入 C 字符串后端；对齐 moduleRoot/argv 惯例）——lexer-gap-closure §6「LLVM 端四内建」挂账以此收口
- **远程 tap 抓取**（G52 批 7）：`TapFetcher` 支持 `github:<org>` / `git:<url>` / `file:<path>`（`git:` 接受本地路径 ⇒ 整条链路可离线端到端测试）；`git clone`/`fetch`+`checkout` + `rev-parse` 取 `commit`
- **经典 MVS**：候选来自远端 tag，取满足全部约束的**最小**版本（`^1.0` → `1.0.0`，不是 `1.2.3`）；全约束为 `*` 时按 D21 回填取最新
- **有界不动点迭代**：依赖的版本决定其自身的 `[require]`，故约束集随选择而变；上限 8 轮，不收敛即报错而非静默取某一轮
- resources 由 `refresh` 落地到 `.pini/resources/<name>/`（此前目录不存在则静默跳过，资源永远不进锁文件）
- **`[replace]` 三种形态**（G52 批 8 / D13）：版本覆盖（只换版本）、`file:`（换本地目录）、`github:`/`git:` fork（可带 `@版本`）；版本类替换并入 MVS 约束当下界；fork 与本地形态锁文件 `tap` 记 `replace`

### Removed
- **花括号函数声明 `{名}(...)`（批③）**：object 语法糖引入前的古早函数声明形态，按治理流程移除（G51② 裁决 + 2026-09-05 用户确认；此前 spec 产生式已移除而宿主仍接受——G51② 行文「宿主已拒」当时与事实不符，本次落地后成立）。行首 `{名}` 恒为对象声明糖；检测到旧形态报 E2-005 迁移提示——改裸声明 `名|func(...)`，测试函数用 `名|test(...)`，类型方法移扩展块显式 `|self`。语料零使用，`parseFuncDecl`（花括号通用形态）死面删除；三处钉定旧形态的测试改为拒绝断言（含批③曾豁免的 `{名|test}(签名)`——见 Changed 修正批）。spec §A.4 规则 3.4 同步重写。详见 `docs/spec/issue/archive/issue-remove-brace-function-decl-2026-09-05.md`

### Changed
- **GrammarConsistencyTests 补钉（批⑤，2026-09-06）**：反录勘测矩阵 row 1–7 的漂移面全部转为双向断言 8 个测试——尾逗号七形态 PASS（形参/返回/调用/数组/字典/集合/类型元组含函数类型标注）、调用位标签 `=` PASS + `:` 拒（报错含迁移提示）、后缀 `!` → `unary(op: .forceUnwrap)` AST 节点、元组解构 var/let → `varDestructure`（isMutable 双态）、扩展块泛型 `((取值<T>))` PASS、限定 case 解构 `case 形状.圆(r):` 拒（E2-001）、单类型返回糖 `-> I32` 拒（防误引入）；夹具随测试同名入库；`<<T>>` 按裁决不钉（spec 有产生式、宿主不可达，留 `docs/spec/issue/archive/issue-trait-extension-reintroduce-2026-09-05.md` 评审）。勘测工单 `docs/spec/issue/archive/issue-spec-backfill-survey-2026-09-05.md` 随批⑤收口关闭
- **§A.6 验证记录可重跑化（批④，2026-09-06）**：五小节由过期快照（46/46 示例、941 测试全绿、/tmp 临时探针已丢失）改写为「命令 + 判据 + 豁免指针 + 最近实测」协议——词法探针入库 `docs/spec/issue/probes-a6-2026-09-05/lex-probe.pini`、示例回归锚定 ExamplesConformanceTests/ExamplesRunTests（实测 80 个 .pini）、优先级判别式锚定 GrammarConsistencyTests 测试族符号名、门禁豁免挂 `docs/spec/issue/archive/issue-gated-stale-fixtures-2026-09-05.md`；绝对数字一律以命令现跑输出为准
- **修正批（2026-09-05，用户二次裁决）**：① 批③ `|test` 花括号豁免撤销——草稿 §测试函数块仅要求显式 `|test` 裸声明，`{名|test}(签名)` 系宿主实现超售（错误形态），随 E2-005 一并拒绝（详见 `docs/spec/issue/archive/issue-test-block-brace-form-errata-2026-09-05.md`）；② spec §A `extension-decl` 的 `'<<' IDENT '>>' trait-body` 特征扩展产生式恢复（批③移除系误判——行首 `<<` 可经 peek/lookahead 消歧，重新引入走 `docs/spec/issue/archive/issue-trait-extension-reintroduce-2026-09-05.md` 提案）；③ `isBraceFuncDecl` 修正历史缺陷（pipe 后未跳过修饰符 token，带修饰符形态前瞻失效）；④ 实测确认形参默认值无实现（`parseParameter` 显式不处理），spec「无默认值」与实现一致，草稿缺省参数意图维持 A6 提案池
- **§A.6 验证记录可重跑化（批④）**：五小节由过期快照（「46/46 PASS」「941 测试全绿」、/tmp 临时探针）改为「命令 + 判据 + 豁免指针 + 最近实测」协议——词法探针入库存放 `docs/spec/issue/probes-a6-2026-09-05/lex-probe.pini`（`pini tokens` 重放）、示例回归锚定 `ExamplesConformanceTests`/`ExamplesRunTests` 两门、优先级判别式锚定 `GrammarConsistencyTests` 测试族、回归门禁挂 `docs/spec/issue/archive/issue-gated-stale-fixtures-2026-09-05.md` 已知豁免清单；绝对数字一律以命令现跑输出为准登记
- **spec 反录入批①②（会话特赦，2026-09-05）**：EBNF 收编既成事实与修正笔误级漂移——尾逗号全形态（参数/返回/实参/类型元组/集合字面量）、调用位标签 `=`（原 `[IDENT ':']` 与实现矛盾）、后缀 `!` 强制解包、元组解构 `var (a, b) = rhs`、扩展块泛型 `((盒<T>))`；match-pattern 限定形态 `IDENT '.' IDENT` 移除（实现拒绝，A10 提案登记不反录）。批②：§A.4 及全文 17 处腐烂 `Parser.swift:NNNN` 行号全部换符号名锚点（grep 可兑付，符合 §7.5 DoD）。勘测矩阵与探针资产：`spec/issue/archive/issue-spec-backfill-survey-2026-09-05.md` + `probes-backfill-2026-09-05/`（26 探针）；副产品立案 issue-trait-body-termination-2026-09-05（trait 块后接顶级声明解析失败，Open 不修）
- **`[[bin]].entry` / `[lib].entry` 生效**（G52 批 9 / Def-3）：声明后 `main` 必须定义在声明的入口文件，否则报 `entryMainMismatch`（runtime-018）；**未声明沿用「全局找 main」**，既有工程零行为变更
- `graph.order` 定为**导出视图**（外部工具消费，非解释器输入）；解释器的依赖就绪顺序由 `loadImports` 递归结构保证，并以三层依赖链测试钉住
- 模块扫描深度按**来源**划分：`deps/` 落地根只扫根级（远程清单省解析），其余目录递归（本地模块 `src/` 布局被 import 时正常加载）
- 锁文件 `tap`/`source` 多 requirer 时取**字典序最小 requirer**（`<root>` 恒优先）；`versionComponents` 按分量剥 `v`/`V` 前缀
- 资源寻址：**v1 明确不提供**产品内 API（判据见 project-spec §3.3；此前为「待定」悬空项）

### Fixed
- **前缀 `++`/`--` 语义钉定并修复三处缺陷（F3 / 批 A）**：表达式位与成员/下标目标现读-改-写回（此前表达式位、成员/下标不写回）；不可赋值目标（字面量等）为编译错误（此前 `++1` 求值为 2）；语句位与表达式位同轨（`Interpreter.evaluateIncDec`）
- **foreign 调用 unsafe 门禁（F5 / 批 A）**：安全上下文裸调 `[X|foreign]` 函数报 E4-001（此前不拦，「该消耗而未消耗」反向缺口；与 空 unsafe 消耗点无害 正交）；`examples/ffi_module/cstring.pini` 1 处裸调已迁移加 `unsafe`
- **BinaryOperator 死面删除（F2 / 批 A）**：`logicalAnd` / `logicalOr` / `power` 永不被构造（解析器在 and/or 层构造 `.and`/`.or`），删除无行为变化；assign 族「仅语句级」入 spec 规则 3.11
- 锁文件 `commit` 此前恒为 `-`（只写不读），现为真实的来源定位符；`tap` / `source` 同样补上读取，`verify` 报错回显来源
- **R7 双向封闭**：`resources X` 而 X 的根含 `pini.toml` → 报错指引改用 `[require]`（此前只兑现正向）
- **`file:` 替换不再往用户本地目录抓取**（批 7 引入的回归）：落地目录被换成本地目录后，抓取仍按 tap 的 spec 执行，会在用户的开发工作区里 `fetch`+`checkout`

### Changed
- **`test` 收编为关键字（G51 / 批 A）**：宿主 lexer 对齐自举 `kw_test` 与 spec KEYWORD（共 34）；`名称|test` 修饰符经词法接出，`pini test` 收集路径不变
### Internal
- 三层嵌套模块夹具 `Tests/PiniTests/ModuleSystemTests/demo3/`（R1 递归排除此前只有两层覆盖）

## v0.52.0 (2026-09-02)

### Added
- **模块工具链 `pini mod`**（G52 批 3）：`tidy`（离线对齐 require↔import）/ `refresh`（本地 tap 重解版本 + 写 `pini-summary.toml`）/ `verify`（SHA-256 校验和执行点）/ `graph [--cycles]`
- **清单双通道**：`[tap]`/`[require]`/`[resources]`/`[replace]` 及点分子表、`[[ ]]` 数组表（MiniTOML）；MVS v1（本地 `file:` tap）
- **隐式别名注入**（D-4，括号内记法收口 后续裁决）：`_别名 = path` = 注入全导入（文件级裸调用或 `_别名.符号` 限定）；冲突 E3-013；名字不一致 E7-002 弱警告（E7 段首个发出的警告）
- **argv 透传**（F6）：`argv()` 内建返回脚本路径之后的裸参数（LLVM 端暂 unsupported）
- 多项 import 块；R1 嵌套清单父扫描排除补全

### Changed
- **破坏性**：旧 `[dependencies]` 清单节命中即报错（指引 `[require]`/`[resources]`）；单文件 `pini run` 现过语义门禁（E3 拒绝后才执行）

### Fixed
- `run(package:)` 补加载 import 块（跨模块限定调用运行时 E5-001，语义/类型检查不受影响）

### Internal
- MiniTOML 共享解析器、纯 Swift SHA-256（NIST 向量验证）、语义警告通道（E7 段）上 stderr、子进程 CLI 测试基建

## v0.51.0 (2026-09-02)

### Added
- **下标三通道**（G48 破坏性修订，下标三通道安全模型）：`a[i]` 安全断言（越界 panic E5-005）；`.get(i)` 安全可选（越界 `.none`，Array/Dictionary/String 一致，字典键按任意值匹配）；`unsafe .getUnchecked(i)` 不安全（解释器以「UB 陷阱」E5-006 近似，LLVM 端未实现报 unsupported）
- **跨行字面量**（G55，A12 方案 B / 路 C）：普通括号内 NEWLINE 等同空白、缩进不参与；块携带括号（开括号同行紧跟 `func`）布局照常——草稿「原地调用 IIFE」形态由此可用；自举 lexer 同步（差分 L0 MATCH 508）
- **括号内 `=` 记法**（G57，括号内记法收口）：实参标签 / 字典条目 / 元组标签 / 枚举具名构造统一 `=`（注入方向）；自举 parser 同步

### Changed
- **破坏性**：下标读返回元素类型 `T`（原 `Optional<T>`），越界由「得 nil」改「panic」；`unsafe a[i]!` 类剥壳写法失效（迁移见 `docs/spec/migration-2026-09.md` §A）
- **破坏性**：注入位旧 `:` 记法（`f(a: 1)`、`[k: v]`、`(a: 1,)`、`E(x: 1)`）废弃并报错（带迁移提示）；match 具名绑定 `case A(x: v):` 保留 `:`（§B）
- 解释器下标语义向 LLVM 既有 panic 行为**收敛**（`@bk_array_get` 一直 `bk_panic`），闭合双后端不一致（`issue-host-optional-slice`）

### Fixed
- Dictionary `.get(key)` 误要求整数索引——键现按任意值匹配（批 2 缺陷，批 3 取证发现）

## v0.49.0 (2026-08-29)

### Added
- **内建单点登记表**（内建单点登记/D4）：`BuiltinRegistry` 承载 28 个内建声明（名字/归组/签名/三层开关），解释器、类型检查、语义分析三处表驱动派生；成员方法表驱动派发（String/Array 11 方法）
- **collection 内建特征声明面**（内建特征化 步骤 A）：抽象签名 + String/Array 标记式 conformance；用户类型严格校验可用
- **标准库语言内下沉试点**（内建双层结构）：`StdlibPini.swift` 内嵌 Pini 源，`String.contains` 为首个 Pini 实现的成员方法（body-first 派发通道）
- **码点原语**（词法门禁 H1）：`ord`/`chr`（grapheme 首 Unicode scalar；空串/越界/代理区哨兵）
- **字符谓词扩容**（G45/谓词集三层对齐）：`is_ascii_digit` / `is_number` / `chars`（grapheme 预切）；`is_letter` 三层登记
- **宽松词法**（宽松词法）：未知字符 → 单字符标识符 token（`unknown` 类型移除）；非法转义原样保留；字符串行尾/EOF 隐式终止；畸形进制/指数回退 `int` + 标识符（`0xg` → `int 0` + `identifier xg`）
- **G49**：模块级 `pini test` 收集 + `[build] exclude`

### Changed
- **G50（破坏性）**：`Self` 关键字更名 `own`，`Self` 降级普通标识符（对齐自举 lexer 与 spec EBNF）
- **module.toml → pini.toml**；R5：点前缀路径构件扫描跳过
- 语言级文档迁移至 pini-meta 仓库（自举验证契约）——2026-08-30 由 规范治理归位 迁回本仓 `docs/spec/`

### Fixed
- G48 下标安全模型：负索引尾部计数、越界 nil、切片语法、substring 尾部计数；下标读严格 Optional some/none（P2-E）
- String `notEqual` 分派缺失（语言内 contains 试点发现）
- 后缀 `!` 强制解包 + 回退透明解包（嵌套下标）

## v0.50.0 (2026-08-29)

### Breaking
- **match 单绑定语义**（单绑定取第 1 个关联值）：`case X(b):` 的 `b` 现在绑定**第 1 个关联值**（原为整个关联值元组）。
  迁移：`case 圆(r):` 对 2 关联值声明 → 改写 `case 圆(r, _):`。
  实测影响面：examples/tests 中 26 处单绑定均为单值关联值（等价、零迁移）；
  `examples/enum-namespacing.pini` 已迁移（2 关联值 + 单绑定）。
- **绑定数与关联值数不匹配 → E4-005**（原静默绑 `.null`）。

### Added
- 具名枚举关联值全链路（具名关联值与 match 解构）：声明 `case E(x: T, y: U,)`、标签实参构造（具名声明）、
  match 具名解构 `case E(x: v):`、`_` 占位。

## v0.48.4 (2026-08-24)

- Initial public release of Pini (Swift implementation)

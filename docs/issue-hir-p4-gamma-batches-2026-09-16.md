# P4-γ 批次执行记录（G-1 → G-5）

> **上游规划**：`docs/issue-hir-p4-gamma-plan-2026-09-16.md`（六批划分 + 三件待裁）
> **判据基线**：`P4-β` 收口 —— **104** failures（分批执行，115/115 类全覆盖）
> **本件性质**：**逐批执行记录**。规划件保持为规划；执行事实写在这里。

---

## G-1 静态成员外移 ✅（2026-09-16）

**目的**：让 `P4-γ` 删 `Interpreter` 时**保留面不受影响**（否则删除会伪装成一次大检修）。

### 交付

| 项 | 内容 |
|---|---|
| 新件 | `Sources/PiniCore/Runtime/RuntimeOps.swift`（**618 行**，`public enum RuntimeOps`）|
| 搬走 | **32 个静态成员 / 556 行实现** |
| `Interpreter.swift` | **3784 → 3260 行**（-524）；保留 **32 个转发**（同名同签名）|
| 改指 | `HIRExecutor.swift` **31 处** · `Value.swift` **2 处** ⇒ `Interpreter.x` → `RuntimeOps.x` |
| 未改 | `Interpreter.swift` 自身的内部调用（转发保证同名可用）· `SuspendEvaluator.swift` **零改动** |

### ⭐ 方法：名单必须按**传递闭包**算，不能按「引用清单」列

首版按「保留面（`HIRExecutor` / `Value`）引用了哪些成员」列名单 ⇒ 得 **25 个**。
编译后连续暴露**三层**内部依赖：

| 轮 | 编译器报出的缺失 | 说明 |
|---|---|---|
| 1 | `typeMismatch` · `intArg` · `trigArgument` · `builtinErrorTypeName` · `builtinCancelErrorTypeName` | 被搬者的**直接**依赖 |
| 2 | `ptrArg` · `valueKindName` | 更下一层 |

⇒ 改为**一次算传递闭包**（脚本 `/tmp/g1_closure.py` 的逻辑）：

```
从「保留面引用的成员」出发，反复取「被选成员块内引用的同类静态成员」，
直到不动点 ⇒ 32 个
```

⚠️ **闭包必须同时认三种引用形态**，漏一种就少算：

| 形态 | 例 | 为何要算 |
|---|---|---|
| 裸名 | `typeMismatch(...)` | 同类内静态可省略前缀 |
| `Interpreter.` 前缀 | `Interpreter.makeResult(...)` | **搬运会把它改写成 `RuntimeOps.`** ⇒ 不带前缀会被漏掉 |
| `Self.` 前缀 | `Self.typeMismatch(...)` | 搬进 `RuntimeOps` 后 `Self` 自然指对，**不需要改**，但**必须计入闭包** |

⭐ 实测：只认裸名 ⇒ 27 个（漏 `typeMismatch`）；再加 `Interpreter.` ⇒ 30 个（漏 `valueKindName`）；
三种全认 ⇒ **32 个，与两轮编译日志报出的缺失名完全吻合**。

### 一处刻意的可见性放宽

5 个成员原是 `private static`（`typeMismatch` · `intArg` · `trigArgument` · `ptrArg` · `valueKindName`）。
转发在**另一个文件**里，跨文件访问不到 `private` ⇒ **`RuntimeOps` 侧去 `private`（升为 internal）**，
而 **`Interpreter` 侧的转发保留 `private`** ⇒ **对外封装不变**，只在模块内可见性上放宽一格。
⚠️ 这是**编译期可见性**的变化，不是行为变化；已在此登记，避免日后被读成「悄悄放开了 API」。

### 判据（**零行为变更**，全部现跑）

| 判据 | 读数 |
|---|---|
| 编译（含测试） | **0 error** |
| 执行覆盖 | **115 / 115 个类**（对账基线，缺 0）|
| **失败集合** | **104**，与 `P4-β` 基线 **`fixed: none / new: none`** ⇒ **逐条完全相同** |
| 归属 | 104 条**全在迁移文件内**；非迁移面 **0** |
| 探针 | 与 `P4-0` 冻结件 **`cmp` 逐字节相同**（md5 `84deca2f…`，**连续第六批同值**）|
| 进程残留 | 0 |

⇒ **`G-1` 达成「零行为变更」**，且**保留面与 `Interpreter` 的解耦已成立**（可验证：删掉 `Interpreter` 的实例面后，
`HIRExecutor` / `Value` 不再引用它）。

---

## G-2 基础面降载缺口（八子批）

### G-2a 字符 / 字符串 / 数值内建 ✅（2026-09-16）

**范围**：`chars` · `chr` · `ord` · `is_letter` · `is_number` —— 5 个内建 / **9 条用例**。

**做法（单源，不是补第二份实现）**：

| 面 | 改动 |
|---|---|
| `RuntimeOps` | 加 5 个实现（从 `Interpreter` 的 `if fv.name == …` 链**搬**）+ 一张 **按名表** `characterBuiltins` |
| `Interpreter` | 5 个分支改为**委托** `RuntimeOps` ⇒ 两引擎共用一份实现 |
| `HIRLowerer` | 加一条降载规则，**白名单读同一张表** |
| `HIRExecutor` | 加一个分派块，同样读那张表 |

⭐ **「表即白名单」是刻意的**：此前 `HIRExecutor` 的按名回答是一串 `if name == …`，容易与降载侧
名单漂移。现在两侧读同一张表 ⇒ **「降载接受、执行器不答」这种半支持在结构上不可能**。

**判据**：

| 判据 | 读数 |
|---|---|
| 编译 | 0 error |
| 执行覆盖 | 115 / 115 |
| **转绿** | **9 条，与预期逐条吻合**（`chars`×3 · `chr` · `ord` · `is_letter`×2 · `is_number`×2）|
| 新增红 | 1 条（见下，已处置）|
| 探针 | 254 / 27 / **11** / 2 / 20 / 4 + **`HARNESS_DEPENDENT` 1** · `FLIP BLOCKERS` **0** |

### ⚠️ G-2 的固有代价：每补一个降载面，LLVM 侧就多一个洞（**本批实测，规划未预见**）

`G-2a` 让降载层接受 `is_letter` 之后实测：

```
pini emit <该夹具>   →   rc=0（看起来成功），IR 里却出现对 `is_letter` 的未定义调用
```

与 `argv`（`P4-1b`）**完全同型** ⇒ 已并入在册工单
`docs/issue-hir-argv-llvm-runtime-surface-2026-09-16.md` §8（**不另开单**，对象相同）。

⭐ **这不是 `G-2a` 的疏漏，而是 `G-2` 的结构性代价**：`G-2` 的每个子批都在做「让降载层接受某特性」，
而那些特性**在 LLVM 侧大多没有运行时段** ⇒ 每补一子批就多一批「`emit` 静默产出不可用 IR」的符号。
⇒ **待裁（规划 §4 之外的新增项）**：LLVM 侧运行时段是**并入 `G-2` 逐子批同步**，还是**单立一批**后补。

**一处判据更新（按实测）**：`IRExecutionTests.testIsLetterUnsupportedViaIRGen` 守的是
「降载层拒绝 `is_letter`」—— 该事实已被本批推翻 ⇒ 测试改名 `testIsLetterLowersAfterG2a`、
断言改为**降载成功**，注释指向上述工单（LLVM 侧那条事实**不在此断言**，因为 `IREmitter` 的
失败通道是 `fatalError`，表达不了）。

### G-2b 集合方法 ✅（2026-09-16）

**范围**：`.get` 落在字典上 · `join` 的元素类型。

| 项 | 内容 |
|---|---|
| 分支 | `p4-gamma-g2b-collections` → 合并点 **`9f4850e`** |
| 做法 | **纯降载面**：两处都不是新节点 —— `.get` 的索引期望按接收者类型走（Array/String 要 I32，Dict 用键类型），`join` 去掉 `[String]` 限制（节点语义本就是「逐元素 stringify 再拼分隔符」）|
| 判据 | 89 → **86**（转绿 3，新增 0）；含一个意外同路转绿 `ParenEqualsTests/testDictionaryLiteralUsesEquals` |

⚠️ **该簇的三个方法没做，理由是结构性的**：`append` · `last` · `pop` **在契约里没有可落的节点**。
`ADR-034 D5` 冻结节点集，而规划 §6 把「改契约计数」排除在 `G-2` 之外 ⇒ 保持原守卫并**另立工单**
（`docs/issue-hir-collection-method-nodes-2026-09-16.md`），不在本批硬造。
⇒ **本簇转绿 2，低于 §2.2 预期的 8**；缺口归上述约束，不归「更早的降载层」。

### G-2c 一元运算符 ✅（2026-09-16）

**范围**：`~` · 一元 `+` · 前缀 `++`/`--`（6 条，与预期逐条吻合）。

| 项 | 内容 |
|---|---|
| 分支 | `p4-gamma-g2c-unary` → 合并点 **`4cd7c0b`** |
| 做法 | `~` 加 `HIRUnaryOp.bitwiseNot` 走既有 `.unary` 节点（两引擎共用 `RuntimeOps.unaryValue`，**不写第二份实现**）；一元 `+` 是数值恒等 ⇒ **降成操作数本身**、不造节点；`++`/`--` 是**读-改-写**，由 `lowerIncDec` 出存储语句 |
| 判据 | 95 → **89**（转绿 6，新增 0）· 探针与 `G-2a` 读数**逐夹具零位移** |

⭐ **两条实测教训（都是「看起来对、跑出来错」）**：

1. **方向必须落在算子上，不能落在常量上** —— 写成 `step = op == .increment ? 1 : -1` 再一律 `.add`，
   `--x` 就成了 `5 - (-1) = 6`（实测拿到 6 而非 4）。正确是 `subtract` 配常量 `1`。
2. **返回值要「回读」，不能复用算术节点** —— `var m = ++n` 展开为「写回 n」+「把 m 初始化」，
   若初始化复用 `binary(.add, load(n), 1)`，它会**再读一次 n**（此时已是 6）⇒ 得 7 而非 6。
   回读 `load(n)` 才是解释器的语义（表达式值 = 改写后值）。

⚠️ **无副作用表达式节点**是本簇的结构约束：写操作只能落在语句上，故**表达式位**的 `++`/`--`
被显式挡住（报错文案说明只支持语句位与变量初始化位）。

### G-2d 泛型（枚举特化）❌ 未交付（2026-09-16）

**结论**：**本批做不了**，且理由不是「守卫太窄」。

`GenericEnumTests` 的 4 条与 `GenericRuntimeTests` 的 1 条要求**用户泛型枚举**能声明与特化
（`ok<I32, String>(42)` · `满<I32>(5)` · `空<String>()`），并让 `match` 进入 `ok`/`err` 分支取关联值。
`HIRLowerer` 的 `G10SpecializationState` **只有 `structSpecializations` 与 `funcSpecializations`**，
**没有枚举对应物**；枚举注册处按 `resolveAnnotationType` 直接解析 case 的载荷类型，
泛型参数 `T` 在那里无法解析 ⇒ 报 `associated value '…' of case 'ok' lacks a resolvable type`。

⇒ 这是一个**新的特化族**（枚举模板 → 特化枚举 → 构造点解析 → match 载荷类型），
不是一个可以放宽的守卫。**另立工单**：`docs/spec/issue/archive/issue-hir-generic-enum-specialization-2026-09-16.md`
（**已归档** —— 该工单主题由 `G-2d` 的 `S1` 于 2026-09-16 解决，处置记录写在归档件内）。

⭐ **2026-09-16 勘测订正（本行两处偏重）**：① **类型层已有同功能件**
（`TypeEnvironment.lookupSpecializedEnumCase` 连载荷类型替换都做完，且在构造点与 match 绑定处已被调用）；
② **`match` 分派链不成立** —— `lowerMatch` 的 `.enumeration(name:)` 分支按**名字**通用，
执行器 `matchStmt` 更刻意不读 `scrutineeType`（按值比对）。
⇒ 缺的只是**降载层三个中间站**，不是照结构体那条路抄一遍。
⚠️ 另：下面只点出 1 条错误通道用例，实测是 **2 条**（`GenericEnumTests` 的
`testGenericEnumArgumentCountMismatch` 也期望**运行期** `RuntimeError`，
文案「实参个数不符」由 `Interpreter.swift:1614` 产生）⇒ 本簇 5 红中**只有 3 条**属本批。
⭐ **开工前规划**：`docs/issue-hir-generic-enum-specialization-plan-2026-09-16.md`
（用户裁决形态取 **C**：限定为准 · 裸名为糖；分 `S0` 语言面登记 → `S1` 降载层三站 → `S2` 收口）。

另一条（`testUndefinedGenericTypeStillThrows`）要求「未定义泛型类型」抛**运行期** `RuntimeError`，
而静态降载层在**编译期**就拒了它。二者属**错误通道**问题（见下方 G-2h 的全局发现），不单独处置。

### G-2e `try-else` 位置与 `ok`/`err` 上下文 ✅（半数，2026-09-16）

| 项 | 内容 |
|---|---|
| 分支 | `p4-gamma-g2e-try-context` → 合并点 **`3a7bde7`** |
| 做法 | `lowerTry` 对**字面量** `ok(...)`/`err(...)` 操作数自行定型：`ok` 的载荷定 ok 半；`err` 没有 ok 类型 ⇒ **`I32` 占位** |
| 判据 | 83 → **79**（转绿 4，新增 0）|

⚠️ **占位类型是本批最弱的一处，如实登记**：`err` 的 ok 半在 `^T` 表层**不存在**，
取 `I32` 是「让树保持全类型」的手段（与 `pass` 降成 `intConst(0)` 同族做法），
靠「该半不可达」成立 —— 字面量 `err(...)` 只有语句位能到达，而语句位丢弃 ok 值。

**未做的 4 条及各自的门**：3 条要 `try-else` 出现在**表达式位**（`print(^ok(7))` · `print(try ok(5) else e: return)` ·
`return ^err(9)`）⇒ 需要**前导语句上提机制**（HIR 无带副作用的表达式节点）⇒ 另立工单；
1 条是 `print(e)` 命中「err 槽类型擦除」的 LLVM Result ABI 门。

⇒ 本簇 **4/8 = 恰为半数**，按规划 §5 止损线处于临界，缺口逐条点名。

### G-2f 作用域块 / `defer` ✅（2026-09-16）

| 项 | 内容 |
|---|---|
| 分支 | `p4-gamma-g2f-defer` → 合并点 **`637a01e`** |
| 做法 | `defer:` 带缩进体**解析成 scoped block**，原先把它当单条语句降载 ⇒ 落到 catch-all。改为经 `lowerBlock` 降载该块 |
| 判据 | 86 → **83**（转绿 3，新增 0）|

⚠️ 原报错位置是 **`0:0`** —— 既不指 defer 也不指块，这正是「按语句种类糊一个默认分支」的报错代价。

### G-2g 跨模块符号 ✅（部分，2026-09-16）

| 项 | 内容 |
|---|---|
| 分支 | `p4-gamma-g2g-module-symbols` → 合并点 **`2d49c1f`** |
| 做法 | ① **单文件运行路径接入同一份导入合并**：`ProgramRunner.run(module:)` 原先直接降载模块，从未合并 `import` 目标 ⇒ `helper.加法(1,2)` 的别名被当变量读。② **合并的同名歧义改为拒绝** |
| 判据 | 79 → **77**（转绿 2，新增 0）· `ImportInjectionTests` 仍 9/9 |

⭐ **本批最重要的一处判断：把「错误」换成了「更响的错误」**。
平铺合并给所有被引入模块**一个共享命名空间**，于是两个模块导出同名 public 符号时会**静默取后者**。
三层嵌套夹具正是为钉这件事而存在（`frontend`/`syntax` 各导出 `取值` = 100/10），
合并后实测 **输出 20 而非 110** —— 在本批改动之前它是**被拒绝**的。
⚠️ **「拒绝」换成「错值」是判据质量的退步**，故补上供货方追踪：两个不同模块抢同一个顶层名时**拒绝并点名**：

```
imported modules '<frontend 根>' and '<syntax 根>' both export the top-level
name '取值': this channel merges import targets into one module, so it cannot
keep their namespaces apart
```

⇒ 该夹具**仍是红的，但是响亮地红**。要转绿需要**按模块的作用域**（不是放宽守卫），不在 `G-2` 内夹带。

⚠️ **转绿 2 对预期 10**：预期是按旧报错文本（「未声明变量」）数的，
而那 10 条里**只有 3 条**真的关于模块符号，其余是 `append`（节点冻结）与无关成因。已记账，避免读成缺口。

### G-2h 其余（余量）✅（部分，2026-09-16）

| 项 | 内容 |
|---|---|
| 分支 | `p4-gamma-g2h-residue` → 合并点 **`d1585e8`** |
| 做法 | ① **深度护栏单源化**：上限 120 与报错文案原先两引擎各一份（一份英文一份中文，靠注释人工对齐）⇒ 收进 `RuntimeOps`；② `print()` 无参 = 空行，原先被降载层直接拒 |
| 判据 | 77 → **75**（转绿 2，新增 0）· 带 **`[ast-walk]`** 标记（`Interpreter.swift` 那一行是从冻结面**删除**一份私有拷贝，不是新增）|

⚠️ **改文案撞出一条在册判据**：`HIRExecutorTests.testRunawayRecursionEndsInADiagnosableError`
断言旧英文句式 ⇒ 转红。它的**主题**是「护栏以可诊断理由触发」，不是「理由是英文」，
故断言改指共享文案并把理由写进注释（否则代码统一了、测试还把分裂钉住）。

### ⭐ G-2 全批的**头号发现**：余量的大头是「错误通道」而非「缺功能」

统计余下 75 条的成因，**占比最大的一类是**：测试断言**运行期**错误形状
（`RuntimeError.invalidOperation` / `typeMismatch`），而**静态降载层提前在编译期拒了同一个程序**。

| 例 | 测试期望 | 实际 |
|---|---|---|
| `FieldVisibilityTests` 私有字段越权 | 运行期 `RuntimeError` | 编译期 `E4-012` |
| `TupleIndexTests` 越界下标 | 运行期 `invalidOperation` | 编译期 `E4-001` |
| `TupleDestructureTests` 非元组解构 | 运行期 `typeMismatch` | 编译期 `E4-001` |
| `BuiltinFunctionTests` `assert(1)` / `len(5)` | 运行期 `invalidOperation` | 编译期类型错 / 降载拒绝 |
| `ResultUnwrapTests` 对非 Result 解包 | 运行期 `typeMismatch` | 编译期 `E4-001` |

⇒ **同一个程序被拒**，差异只在**在哪个阶段拒、报什么种类**。
这不是「HIR 缺功能」，而是**「语言规范要求运行期 trap，静态层提前拒了」是否可接受**的问题 ——
**不能靠改测试结案**。已立为**独立议题**：`docs/issue-hir-static-rejection-vs-runtime-error-2026-09-16.md`。

### G-2 总账（实测，逐子批全量回归，130 类**逐类单跑**）

| 子批 | 合并点 | 前 | 后 | 转绿 | 新增 |
|---|---|---:|---:|---:|---:|
| （起点 = `G-2a` 收口） | `0f12a56` | — | 95 | — | — |
| G-2b 集合 | `9f4850e` | 89 | 86 | 3 | 0 |
| G-2c 一元 | `4cd7c0b` | 95 | 89 | 6 | 0 |
| G-2e try 上下文 | `3a7bde7` | 83 | 79 | 4 | 0 |
| G-2f defer 块 | `637a01e` | 86 | 83 | 3 | 0 |
| G-2g 跨模块 | `2d49c1f` | 79 | 77 | 2 | 0 |
| G-2h 余量 | `d1585e8` | 77 | **75** | 2 | 0 |
| G-2d 泛型枚举 | — | — | — | **0** | — |

**`G-2` 合计：95 → 75（转绿 20，新增 0）**；`G-2d` 未交付（另立工单）。

⚠️ **两个子批低于 §2.2 预期**（`G-2b` 2/8 · `G-2g` 2/10），原因各不相同、均已逐条点名：
前者是**契约节点集冻结**，后者是**预期数本身按旧报错文本误算**。两条都不指向「更早的降载层」，
故未触发 §5 的「停下回报」以外的动作。

### ⚠️ 判据器械的可靠性缺口（本批实测，影响上面每一个读数）

`PiniTests.SuspendRuntimeTests` **偶发 SIGSEGV**：

| 运行 | rc | 实际执行的方法数 |
|---|---:|---:|
| `G-2` 基线 | 1 | **3 / 15**（`testCancelSleepingChildInSuspendMode` 处信号 11 死掉）|
| `G-2c` / `G-2b` | 0 | 15 / 15（全过）|

⇒ **崩溃的类对「只看退出码/只看有无解析到失败」的读者表现为通过**，
而本批的读数正是按那个口径取的。这不是本批引入的，但**它给本批每一个数字设了上限**。
已并入测试基建工单族（对象与在册 SIGPIPE 那份不同：那份是**终止信号**吞掉后续类，
这份是**并发运行期**的非确定性崩溃）：`docs/issue-test-harness-suspend-runtime-sigsegv-2026-09-16.md`。


## G-3 R1/R2 实施

（待执行）

## G-4 `runTests` 归宿

（待执行）

## G-5 303 个对照用例的参照臂

（待执行）

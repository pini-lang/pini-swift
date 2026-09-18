# P4-γ 批次执行记录（G-1 → G-6）

> **上游规划**：`docs/issue-hir-p4-gamma-plan-2026-09-16.md`（原六批划分 + 三件待裁；
> **2026-09-16 晚修订为五单元**见该件 **§8**）
> **判据基线**：`P4-β` 收口 —— **104** failures（分批执行，115/115 类全覆盖）；
> **最新读数 = 72 failures**（2026-09-16 现跑，116 类逐类单跑；真实测试类 115）
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
（`docs/spec/issue/archive/issue-hir-collection-method-nodes-2026-09-16.md`），不在本批硬造。
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
⭐ **开工前规划**：`docs/spec/issue/archive/issue-hir-generic-enum-specialization-plan-2026-09-16.md`
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


## G-0 口径订正 ✅（2026-09-16，纯文档）

| 项 | 内容 |
|---|---|
| 交付 | `docs/issue-hir-p4-gamma-plan-2026-09-16.md` **新增 §8**（裁决登记 · `G-6` 判据订正 · 批次修订 · 记号归一）· 主计划新增 **`D-P4-25…30`** 六条决策 · SIGPIPE 工单状态改为**已授权修复**并新增 §8 处置 |
| 判据 | **只动 `docs/`**（零源码改动）；文档链接门禁过 |
| 做了什么 | ① `G-6` 的「**全量回归 0 failures**」按 `D-P4-22` **同形订正**为四条可测形式（0 现测不可达：余 72 条）；② 三条裁决落位；③ 批次修订为**五单元**；④ 查出并钉死 **`R1`/`R2` 记号反向冲突**（`D-P4-30`）；⑤ 订正一处「**主计划 §7**」歧义（上游 `…hir-plan-2026-09-12.md` 与 `…p4-plan-2026-09-16.md` 各有一个 §7） |
| 为什么单列一批 | **不先改口径，其后每批都跑在错的验收线上** —— 这是 `P4-γ` 长时间开不了工的直接机制，不是流程洁癖 |

---

## G-2R `G-2` 的余量 — ✅ **已交付**（2026-09-17 凌晨）

**对象**（2026-09-16 现跑，逐条具名）：**结构体拷贝静默错值**
（`ValueSemanticsTests.testStructCopySemantics`，在册工单 `docs/issue-hir-struct-copy-missing-2026-09-14.md`；
⚠️ **它不是「缺功能」而是「算错」** —— `var b = a; b.x = 99` 时 AST 打 `1`、HIR 打 `99` ⇒ **优先于一切补功能**）·
`CrossFileRuntimeTests` 3 · `ArrayElementAnnotationTests` 2 · 浮点 / 数学 / 模块作用域 / 枚举具名构造 /
递归枚举 / `LazyRef` 推导糖 各 1。

**判据（实际）**：**72 → 68** —— 转绿 **4** / 新增红 **0** / 仍红 68 逐条相同；探针 319 夹具逐夹具对账；
契约 60 节点 clean。
**前置**：SIGPIPE 器械修复 ✅。

### ⚠️ 本批只做到 **4 条**，不是原承诺的 12 条

取**真实失败面**（不按用例名猜）后的范围订正：

| 归口 | 条数 | 明细与处置 |
|---|---:|---|
| ✅ **本批交付** | **4** | 结构体值拷贝 · `F64(...)` · `LazyRef(...)` 推断糖 · 无标注形参跨文件传参 |
| 迁出 → `append` 命名调用路 | 4 | `ArrayElementAnnotationTests` 2 · `CrossFileRuntimeTests` 限定/歧义枚举构造 2（**全报** `method 'append' calls are later grids`） |
| 迁出 → 语言面裁决 | 3 | `abs` 多态 · 整数字面量→小数 · 具名元组元数 ⇒ **已由登记批 `ADR-038` / `G60` 处置** |
| 迁出 → 模块作用域 | 1 | `ModuleSystemTests` 三层嵌套同名导出（`G-2g` 已明示不夹带） |

**两条提交**（分支 `agent/pini-dev/p4-gamma-g2r-b`）：

- **`f4bfd36`** 降载层 + 执行器 + 单源化（4 文件 / +112 −15）
- **`1588c58`** LLVM 侧 `F64` 改 `sitofp` —— **交付自查时实测发现**：`emit` 返回 0 却产出引用
  未定义符号 `@F64` 的 IR（`run-llvm` 报 `use of undefined value`）⇒ 本批若不修就是**新引入一处静默坏 IR**。
  修后 `emit` 零未定义符号、`run-llvm` 输出 `3.5 / 7.0` 与 HIR 逐字一致。

### ⚠️ 一处必须在册的判据差异（本批实测，第三例）

三条转绿里，**`LazyRef(闭包)` 推断糖只在「进程内测试入口」可用**：CLI 面 `pini run` 仍被
**类型检查器**拦下（`E3-002 undefined function 'LazyRef'`，**两引擎相同**）；
而**显式形态 `LazyRef<I32>(闭包)` 在 CLI 上完全可用**（输出 `7`）。
⇒ 「测试面绿 ≠ 用户可见入口可用」。**前两例**：`P4-2` 的引擎开关只影响 CLI 子进程 · `G-2d` 的限定形态只在降载层与 LLVM 通道。
补齐它需要让检查器认识「内建泛型类型 + 推断糖」（`BuiltinRegistry` 的 `typeSignature = nil` 只记名不登记类型层签名），
属**类型层工程** ⇒ **如实登记，不在本批**。

**另两条 CLI 面已实测可用**：`F64(...)` → `3.5 / 7.0`（HIR 与 LLVM 逐字一致）· 无标注形参 → 单文件两引擎都输出 `hi`。

**不在本批**：16 条结构性大件（各有归属批或待裁项）· 13 条错误通道（待规范口径裁决）。

## G-2S 集合成员方法走内建特征派发（`append` / `last` / `pop`）— ✅ **已交付**

**由来**：`G-2R` 的验收面清单里 **4 条被 `append` 挡住** ⇒ 用户给出架构方向
「**数组的 `append` 应当有一个内置特征来分发它的默认实现**」并批准独立成批。
**本批是族粒度三段制的首例试点**（该工作方式 2026-09-17 由用户固化，见 `llvm-grid-closeout`）。

### ① 验收面一次列全

7 条：`CollectionsTests` 3 红（`append` 函数式 · `last`+`pop` · 空数组 `last`/`pop`）
+ 被 `append` 挡住的 4 条（`ArrayElementAnnotationTests` 2 · `CrossFileRuntimeTests` 2）。
⚠️ **清单阶段即界定出 3 条不属本批**（见下「止损」）⇒ 可交付面**预先是 4 条**，不是 7 条。

### ② 做法（不新增契约节点）

`get` / `slice` 当年各占一个**专用节点**（`optionalGet` / `sliceCall`），而契约的 60 个节点是**冻结**的
⇒ 这三条改走**按名调用**（`Array.append` / `Array.last` / `Array.pop`），执行器按名回答
—— 与 `argv` / `moduleRoot` 同一先例。规则本体落在 **`RuntimeOps.arrayMethods`（单源）**，
与 AST 侧同一套语义；`append` 不接受非数组接收者。

**降载层给的静态类型 = 运行期的真实产物**（不是表里那个宽松的 `Any`）：
`append` ⇒ `Array<T>` · `last` ⇒ `Optional<T>` · `pop` ⇒ `(Array<T>, Optional<T>)`。

**三处落点**：`RuntimeOps`（表 + 三条规则 + 接收者校验）· `HIRExecutor`（按名回答）·
`HIRLowerer.lowerMemberCall`（三条分支，插在 `slice` 之后、兜底之前）。

### 判据（全部现跑）

| 判据 | 读数 |
|---|---|
| 转绿 | **68 → 64**：`testArrayAppendFunctionalReturnsNewArray` · `testArrayLastAndPopStackSemantics` · `testArrayLastPopOnEmptyReturnsNull` · `testAppendArgumentAccepted` |
| 无新增红 | 转绿 **4** / 新增 **0** / 仍红 64 **逐条相同** |
| 契约 | **60/60** 三锚点 clean ⇒ **未新增节点**（本批的核心约束） |
| CLI 面 | **逐条实测**：输出与期望**逐字一致**（`[1, 2, 3]`/`[1, 2, 3, 4]` · `3`/`3`/`[1, 2]` · `null`/`null`/`[]` · `[7]`） |
| 探针 | 319 夹具逐夹具对账（见本批证据条目） |

### ⚠️ 止损三条（验收面清单阶段界定，**如实登记不修**）

`ArrayElementAnnotationTests.testWildcardAndUnannotatedUnchanged`（无标注累积器：先 `append(1)` 再 `append("b")`）·
`CrossFileRuntimeTests.testCrossFileQualifiedEnumCaseConstruction` 与 `testCrossFileAmbiguousCaseAllowsQualified`
（`var xs = []` 无标注空数组 + `append(枚举值)`）。

**三条同属一个议题：静态层缺「动态 / 未定类型」的表示** —— 无标注空数组的元素类型默认落 `i32`，
append 别的类型即报 `type mismatch: enumeration(...) is not i32`；无标注累积器要的是同一件事。
它与本批 `G-2R` 的「**无标注形参**」**同源** ⇒ 两者**应合并为一个议题单独立项**，不在本批。

### ⚠️ 器械加固（随交付）

**`tools/hir-chunk-run.py`** —— 分块整跑驱动**固化进仓**，并加**读数有效性护栏**：
跑到类数为 0，或有类根本没跑到 ⇒ **判作废 · 不写清单 · 删掉该路径上的旧清单 · 退出码 2**。

**起因是一次真事故**：后台跑 `swift test` 会被沙箱拦临时目录清理 ⇒ 115 个类**全部 0 执行、失败也是 0**
—— 一张**形状完全合法的整表假绿**（不删旧清单的话，下一轮读者会把上一轮读数当本轮结果）。
同类事故此前已发生过一次（`G-0` 批）⇒ 按「**连续两批同类过程失误**」触发**取消触发**并上报；
**用户裁决 = 改进**：① 前后台按「是不是 `swift test`」分（该判据已订正进 `pini-repo-handbook`）·
② 读数入对账前先看「跑到 N/总数」· ③ 器械级护栏（本条）。

## G-3 并发迁移（`R1`）— 待点名

**裁决（2026-09-16）**：取 **`R1` = 保并发能力、迁到 HIR**，且**排在 `G-6` 之前**（`D-P4-26`）。
**对象**：`Sources/PiniCore/Interpreter/SuspendEvaluator.swift`（890 行）承载的
`await` / `wait` / `join` / `joinAll` / `joinWithin` / 取消 → HIR（**调度器 + `Future` + 取消**三件）。
**用例 31 条**：`ConcurrencyTests` 14 · `JoinAllTests` 7 · `JoinWithinTests` 6 · `CancellationTests` 4。

**判据**：31 条**逐条**转绿；无新增红；若改动触及引擎分派则跑 `ast` 方向一次。
**⚠️ 硬停**：若迁移须改动契约那 **60** 个节点 ⇒ **停下先走 `spec §1.3` 治理**（规划 §5，**已随 `R1` 生效**）。
**⚠️ 记号**：本件与 `P4-β` 件的 `R1`/`R2` 与 `docs/issue-selfhost-probe-plan-2026-09-13.md` **相反**，见 `D-P4-30`。
**工程理由（本批补记）**：**要移植的 890 行就是即将被删的 890 行** —— 后置则只剩 git 历史、无法并排验证。

## G-4·G-5 `runTests` 归宿 + D 类参照臂改造 — ✅ **两半均已交付**（2026-09-18）

> 两件**合并为一批**（互不依赖，且都在 `G-6` 之前必须处置）。

### G-4：✅ **已交付**（2026-09-18，单批）

> **裁决**：`D-P4-31` 取 ① —— **在 HIR 侧实现测试块驱动**（保能力）。
> **追加范围（用户 2026-09-18 当场裁）**：本批一并实现 **HIR 侧 `dlsym` 加载器** ——
> 把在册工单 `docs/spec/issue/archive/issue-hir-vendored-ffi-unsupported-2026-09-17.md` 的目标并入，
> 使「vendored FFI 在默认引擎上不可运行」这条**用户可见回退**不成立。

**开工前实测订正三处**（规划记「C 类 4 文件 / 23 用例」）：① `TestBlockSwiftTests`
不在 `Tests/PiniTests/`，在 `Tests/PiniSwiftTests/`（另一 target）；② 「23」只数了
`PiniTests` 一侧，实际 **26**；③ 26 条里**只有 10 条真驱动 `runTests`**。

**交付**：
| 面 | 内容 |
|---|---|
| HIR 结构 | `HIRFunction` 增 `isTest` / `sourceFile`（后者是包级 `fileScope` 的承载） |
| 降载层 | `HIRLowerer.lower` 增 `requiresMain: Bool = true` —— 默认保持原行为，既有 20+ 调用点零改动 |
| 执行器 | `HIRExecutor.callFunction(named:args:)`（`run` 只够到 `main`，测试要够到每一个） |
| 入口 | `ProgramRunner.runTests(module:)` / `runTests(package:fileScope:)`；`TestRunResult` 迁入 `ProgramRunner`（免随 `G-6` 消失） |
| FFI | `foreignNames: Set` → `foreignDecls`（名 → 库 + 签名）；引擎级 `FFILoader`；`ForeignThunk.annotation(for: HIRType)` |
| 改指 | CLI 2 处 + **10 条**用例（4 文件） |

**判据（全部现测）**：
| 判据 | 读数 |
|---|---|
| 26 条判据面 | **26/26 绿**（`PiniTests` 23/0 · `PiniSwiftTests` 3/0） |
| `pini test` 双引擎 | 3 夹具**逐字节相同**（rc 0/1/0 亦相同） |
| FFI 生产路径 | `pini run examples/ffi_module/` **rc=0**，与 AST **逐字节相同**（md5 同） |
| FFI 测试面 | `pini test cstring.pini` 与包模式各 **2 通过 0 失败** |
| 无新增红 | 全量回归逐条 57 → 57：转绿 0 · **新增 0** · 仍红 57（默认与 `ast` 两方向逐条相同） |
| 契约 | clean **62/62**，计数未变 |
| 探针 | 320 夹具 · 逐夹具**差异 0** · 七槽相同（⚠️ 本批对象不在探针根集 ⇒ 无区分力，只作护栏） |
| 变异反证 | **两级成立**：M1 恢复 `requiresMain` ⇒ 无 `main` 夹具回红（`E6-004`）；M2 禁用 foreign 分派 ⇒ FFI 夹具回红 |

**⭐ 一处必须记账的后果**：`pini test` 改指后**不再看 `PINI_INTERP_ENGINE`**（实测 `ast`
方向与默认逐字节相同）⇒ 「`ast` 方向」这条判据对 `pini test` 面**从此失效**。这是
`D-P4-31` 的直接后果、不是缺陷；`pini run` 的 `ast` 方向仍有效，全量回归的对照臂在那里。

**下游**：工单 `docs/spec/issue/archive/issue-hir-vendored-ffi-unsupported-2026-09-17.md` **闭环**（走其 §4 路径 ①）·
`docs/spec/pini-spec-v0.md` 两处口径订正（§3 台账 `[名称|foreign]` 行 · 长期愿景 T14 行）。

### G-5：✅ **已交付**（2026-09-18，单批）

> **裁决（用户 2026-09-18）**：① **`B`**（补降层独立证人）· ② **`B`**（本批吸收 `FFIModuleTests`
> + `StructuredConcurrency` 的 4 条改指）· ③ **`A`**（探针仍 3 通道，留给 `G-6`）。
> **交付分支**：`agent/pini-dev/p4-gamma-g5-reference-arms`。**零 `Sources/` 改动。**

**对象（开工前实测订正）**：`D` 类 9 文件 **304 用例**（规划记 303）；另有 ②B 吸收进来的 2 处。
**换腿点 = 15 个 `func`**：10 个臂助手 + 5 处用例体内直构。

#### 1. 换腿表（每条都实测过）

| 文件 | 原参照臂 | 换成 | 备注 |
|---|---|---|---|
| `HIRDifferentialTests`（89） | `runInterpreter` / `runPackageInterpreter` | **HIR 树走查**（`ProgramRunner`） | 另一侧是 LLVM ⇒ 两执行器对照 |
| `IRExecutionTests`（81） | 用例体内 4 处直构 | 同上 | 另一侧是 LLVM |
| `RuntimeBackendTests`（51） | `runViaInterpreter`（16 调用点） | 同上 | 另一侧是 LLVM |
| `OptionalTests`（20） | `runProgram` | 同上 | 另一侧是 LLVM |
| `IRPrintGoldenTests`（2） | `runViaInterpreter` | 同上 | 另一侧是 LLVM |
| `HIRExecutorTests`（31） | `runBothChannels` 的 AST 臂 | 删 AST 臂；**改用冻结期望**（①B） | 见 §2 |
| `DebuggerTests`（17） | 双引擎参数化（`DebugEngine.allCases`） | **收成一臂**（`.ast` 例移除） | 见 §3 |
| `DotCaseConstructionTests`（7） · `BuiltinOverrideTests`（6） | `runSource` / `runProgram` | 见 §4 | |
| ②B `FFIModuleTests`（7） | `runModule` / `runProgram` | `runModule` → HIR；**`runProgram` 回退** | 见 §4 |
| ②B `StructuredConcurrencyTests`（14） | `runProgram` | 4 条改指 → **实测只 3 条可改** | 见 §4 |

#### 2. ①B：两条**不依赖 LLVM 通道**的冻结证人

| 证人 | 对象 | 规模 | 为什么需要 |
|---|---|:--:|---|
| `probeGoldens` | `HIRExecutorTests` 的 12 条手写探针 | 12 | 探针的旧参照物就是 AST 臂；换腿后它没了 |
| `loweringDigests` | 受影响各**具名夹具**的降载结构摘要 | **83** | 换腿后两臂读**同一棵降载树** ⇒ 「降载器静默吞掉结构」对任何臂间对照都不可见 ⇒ 观测点必须**上移一层**，且**不跑任何执行通道** |

**取值可信度是测出来的，不是声明的**：`probeGoldens` 取自 HIR 树走查臂，单看只是「钉住今天」——
故同批**直接测量**：把仍在源码里的 AST 走查臂驱动同样 12 条探针源，**0 条不一致** ⇒
这些值就是**被退役那条臂的读数**（正是换腿前 `assertParity` 断言的那个等式，此处对臂本身重测）。

**「不依赖 LLVM」也是测出来的**：`PINI_LLVM_BIN` 未设且 LLVM 不在 `PATH` 时实测 ——
`HIRDifferentialTests` **89/89 跳过**、语料 2 通道对照**跳过**，而
`testNamedFixturesMatchFrozenLowering` **照常执行并通过**。
⇒ 这批程序在没有工具链的机器上**仍有证人**，是设计的结果、不是碰巧。

**三条不在表内、**具名**而非静默丢弃**：`testAsyncFunction_LLI` · `testAwaitConsumption_LLI` ·
`testAsyncVsSyncParity_LLI` —— 它们**今天根本降不了载**（`type mismatch: i32 is not result(ok: i32)`，
try-else 迁移前的旧形态），与 `IRExecutionTests` 用 `XCTSkipIf(true, …)` 跳过它们**同因**；
断言它们当前失败等于**把已知错误答案钉死**，故只具名。

#### 3. `DebuggerTests` 的收一臂（**执行面收窄 29 → 17 例，如实登记**）

`DebugEngine` 移除 `.ast` 例（枚举与 `dbgDrive` 的 `switch` 保留，`switch` 不带 `default:`
⇒ 再增一例会编译失败而非静默走默认分支）。12 条参数化用例由「每例 2 台引擎」变「1 台」
⇒ **执行例数 29 → 17**。两条「两引擎对比」用例的**判据转移**：

| 原用例 | 处置 |
|---|---|
| `testDebugSurfaceIsEngineAgnostic` | 保留仍可失败的一半（协议面装配）→ `testDebuggerAssemblesThroughTheProtocolSurfaceOnly` |
| `testBothEnginesStopOnTheSameLines` | 改为**对冻结序列**的断言 → `testStopSequenceMatchesTheFrozenExpectation`（冻结值 `[2, 3, 4, 5]`，取自换腿前两臂逐项相同的那次读数） |

#### 4. ⚠️ **三处实测判定「不可换腿」，已回退**（本批最重要的实测结论）

| 处 | 换了会怎样（实测） | 性质 | 归属 |
|---|---|---|---|
| `BuiltinOverrideTests`（6 例红 4） | 降载期拒（`method 'len'` / `'shout' calls are later grids`）+ 用户扩展**未覆盖**内建（读到 `true`，期望 `false`） | **HIR 缺「内建类型的用户扩展方法」这一级派发** | 新立工单 + `G-6` 前置 |
| `FFIModuleTests.testUndefinedForeignSymbolRejected` | **不再抛错**（`did not throw`），`puts` 照常输出 | **HIR 对「声明了但找不到的 foreign 符号」不 fail-fast** | 新立工单 + `G-6` 前置 |
| `StructuredConcurrencyTests.testDeferStillRunsWhenTaskCancelled` | 输出只有 `主流程结束`、**缺 `清理完成`** | **HIR 取消时不执行 `defer` 清理** | 写进退役件「残余三」的实测订正 |

⭐ **一处分类订正**：`P4-β` 的 `D` 类把 `BuiltinOverrideTests` 与另外 8 个文件并列（分法 = 「是否驱动
`Interpreter` 做执行」）。该分法在这一个文件上**失效** —— 其余 8 个的 `Interpreter` 是**参照物**，
本文件的 `Interpreter` 是**被测能力的唯一实现** ⇒ 换掉它不是「换参照物」而是**换掉被测对象**。
⇒ `D` 类须按「`Interpreter` 扮**参照物**还是**实现**」再分一次；
「绝对期望 vs 臂间对照」这个维度**不足以**判（本文件的断言全是绝对期望，却仍是实现）。

⭐ **一处判据缺口**：退役件原记 `StructuredConcurrency` 「4 条可改指」，判据是**夹具 `rc=0`**。
实测该 4 条里 **1 条不成立**（rc=0 而断言红）⇒ **`rc=0` 不蕴含断言可满足**。

#### 5. 判据（全部现测）

| 判据 | 读数 |
|---|---|
| 受影响面**逐类**（11 类，每类独立输出文件） | **325 执行 / 3 跳过 / 0 失败** |
| 3 条跳过是谁 | `IRExecutionTests` 的 `testAsyncFunction_LLI` · `testAwaitConsumption_LLI` · `testAsyncVsSyncParity_LLI`（`XCTSkipIf(true, E6-004)`，**换腿前即跳过** ⇒ 无回退） |
| 全量回归（3 块，`hir-chunk-run.py`） | **57 → 57**，0 次信号，**逐条集合相等**（= 新增红 0 / 转绿 0） |
| 契约 | **clean 62/62**，计数未变 |
| 探针（护栏，③A） | **320 → 320**，**逐夹具判定变化 0**，`FLIP BLOCKERS 0` |
| **变异反证两级** | 见下表 |
| 零 `Sources/` 改动 | `git diff --name-only -- Sources` 为空 |

**变异反证（2×2 分工表，失败数）**：

| 变异（一轮内改、跑、还原） | 降载摘要 | 探针冻结表 |
|---|:--:|:--:|
| **M1** 降载层：`HIRModule` 丢掉最后一个名义声明 | **8** | 0 |
| **M2** 值层：单个 `print` 追加一个字符（**共享规则**，两臂同源） | 0 | **1** |

⇒ 两条判据各自观测**自己那一层**、且**互不冒充**；M2 尤其说明：**共享规则**的改动在臂间对照里是
**静音**的，而**冻结表**能抓住它。
器械自带三条硬要求：锚点唯一性预检 · 「变异确实生效」md5 自检 · `finally` 还原 + 逐字节对账
（每轮还原后 md5 与变异前相同；收尾 `git diff -- Sources` 为空）。

#### 6. 同批新立工单（4 件，均只登记不修）

1. `docs/issue-interpreter-residual-reference-surface-2026-09-18.md` —— `G-6` 前置：残余引用面
   （含 **`pini dbg` 两条入口恒 AST、无 HIR 分支**；并**订正**规划件「静态成员 ~30 处」为实测 **0 处**）
2. `docs/issue-hir-builtin-user-extension-gap-2026-09-18.md` —— 内建类型的用户扩展方法未在 HIR 落地
3. `docs/issue-hir-foreign-symbol-not-found-not-loud-2026-09-18.md` —— 未找到的 foreign 符号不 fail-fast
4. `docs/issue-hir-nominal-decl-order-nondeterminism-2026-09-18.md` —— `HIRModule` 声明顺序非确定
   （**两处**：名义清单 + **函数尾段**）

#### 7. 方法层沉淀（三条，已进技能）

1. **`Read` 渲染的缩进不可信**——`FFIModuleTests.swift` 是**1 空格**缩进（第 4 个已知例外文件）
   ⇒ 多文件编辑脚本**必须先普查缩进**（本批靠守卫拦住了一次「命中 0 次」）。
2. **`private` 是文件作用域**：同文件的 `extension` 能访问，**另一个类不能** ⇒ 一次性器械要写成
   `extension` 形态。
3. **器械的产物不要走日志**：JSON 经测试日志传输时转义被破坏 ⇒ 直接落盘
   （「只从日志里活着回来的冻结表不是冻结表」）。

#### 8. 未做范围

不改 `Sources/` · 不动探针通道数（③A）· 不修在册工单（三处缺口只登记）·
不把 3 条不可换腿项「顺手改掉」· 不 push。

### 参照臂改造的已知障碍（在册，不属本批）

`run-llvm` **丢弃 `lli` 退出码**（`docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md`）·
`emit` 对 `argv` 一类**静默产出引用未定义符号的 IR**（`docs/issue-hir-argv-llvm-runtime-surface-2026-09-16.md`）。
⇒ 二者使 `LLVM` 作参照臂时**会漏判某些失败**；本批须**逐夹具标注**哪些落 golden 正是因此。

## G-6a 前置处置（三张单补实现）— ✅ **已交付**（2026-09-18）

**对象**：`§8.2` 判据 3 要求「删走查前须先处置 `pini dbg` 的两条 AST-唯一入口」，加上 `G-5`
实测出的另两处「换了腿就红」。三张单原**均无处置方式**，本批按用户裁决取「**全补实现**」
（不把能力缺口翻译成测试期望被调低）。三批制的第一批（`G-6a`）。

### 与规划的偏差（两处，均为实测订正）

1. ⚠️ **命令名订正**：工单里 4 处写 `pini dbg`，实际子命令是 **`pini debug`**
   （`Sources/PiniCLI/main.swift` 的 `case "debug"`）。对象（那两个函数）不受影响。
2. ⚠️ **一处裁决前提实测失效**：原计划把 `testIRUnsupportedForBuiltinExtension` 的断言
   「从降载期拒绝**改指到 LLVM 侧仍拒绝**」。实测**该前提不成立** —— 处置 C 的实现把
   **LLVM 侧也一并带通**了（扩展方法降载成普通 `module.functions` ⇒ IRGen 按名调用即可，
   **不需要**给 `IREmitter` 加分派）。故照 `IRExecutionTests.testIsLetterLowersAfterG2a`
   的先例改为**正向断言**（改用例名、保留夹具名），并把 spec `§2.4.1` 的 H-3 行边界标记
   为**已关闭**（状态列 `✅（解释器 + HIR + LLVM）`）。

### 三项处置与证据（各自红 → 绿）

| # | 单 | 处置 | 灯基线 → 结果 |
|---|---|---|---|
| A | `foreign` 符号未找到不 fail-fast | `HIRExecutor.prepare(module:)` 改 `throws`，登记后**急切解析**；链序照解释器：**先 `RuntimeLibcShims` 白名单、再 `dlsym`**（顺序反了会把 `cstr`/`puts` 误报为找不到） | `FFIModuleTests` **1 红 → 0**（`did not throw`，与工单预测逐字吻合） |
| B | `pini debug` 两条入口恒 AST | `runDebugFile` / `runDebugDirectory` 改指 `HIRExecutor`（照测试侧 `dbgMakeRunHIR` 三步）；`DAPServer` 默认路径把 `check`/`lower` 一并放进 `start`，三类错误走同一上报通道 | `DebuggerTests` **17 passed** + **CLI 实机冒烟**（该套件走自己的 HIR helper，测试绿**不算数**）：`b 3` 后确停在 3 行；目录模式停在 `package-demo/main.pini:20` 并跑完 |
| C | 内建类型的用户扩展方法未在 HIR 落地 | 根因 = 扩展块注册要求 `nominals[targetType] != nil`，内建类型不是名义声明 ⇒ 方法体从未降载。修法 = 模块级**预扫描**（须先于函数降载）+ `lowerMemberCall` 最前加**用户扩展优先**分支 + 两个类型映射 helper | `BuiltinOverrideTests` **4 红 → 0** |

⭐ **处置 C 的附带结论**：`BuiltinOverrideTests` 的 6 条用例从「AST 臂撑」换成 HIR 臂后**全绿**，
即 `G-5` 判定的「不可换腿」第三条**已被消解**（该判定原本成立，是因为能力缺失而非参照臂问题）。

### 收口判据（全部现测）

| 判据 | 读数 |
|---|---|
| 判据 1 **新增红 0** | 同法重测两侧：基线 **57**（块 23+14+20）→ 本批 **56**（22+14+20）；**逐条集合比对 = 新增红 0 · 转绿 1 · 仍红 56**。转绿那条 = `FFITests.testUndefinedNativeFunctionRejected`（处置 A 的连带） |
| 判据 2 探针 | 七槽**逐项相同**：OK 255 / PACKAGE_MEMBER 27 / FRONTEND_FAIL 11 / HARNESS_DEPENDENT 1 / CHANGE_REFERENCE 2 / WARN_CHANNEL_ASYMMETRY 20 / WARN_LLVM_RC_UNPROPAGATED 4（=320）· **FLIP BLOCKERS 0** · **process leaks 0**。⚠️ **不能宣称逐夹具相同** —— 冻结件在 `/tmp` 已被系统清理，本轮只能与记录的七槽计数比分 |
| 契约 | `tools/hir-contract-check.py` **clean**（45 expr + 17 stmt = 62，三锚点各 62/62） |
| 门禁 | 文档链接校验 0 过时 · comment-lint 待批末一并跑 |

⚠️ **重测基线的手法与代价**：判据 1 要求「逐条比对」，而基线清单从不落档（只在 `/tmp`），
已被清理 ⇒ 采「暂存本轮改动 → 从 `ca5de98` 取回 5 个源码文件 → 跑 → 还原 → `stash pop`」，
**跑完即验还原**（`git status` 三文件、`stash list` 为空）。同日复核：基线 57 与本批前记录的
「`G-5` 实测 57」**一致** ⇒ 中间两轮工单巡查的零改动断言得到交叉验证。

⚠️ **一条工具缺陷（2026-09-18 已立案；原记的表述已订正）**：`tools/hir-parity-probe.py:251` 的默认二进制路径
写死为 **`/tmp/pini-build/arm64-apple-macosx/debug/pini`** —— 该布局**不是** `swift build --show-bin-path`
今天写的那套（`<scratch>/out/Products/Debug`）。⚠️ **订正两处**：
① 原文「不显式设 `PINI_SWEEP_BIN` 就会**量到陈旧二进制**」**只对历史态成立**（旧布局文件还在 `/tmp` 里时）；
**现行态**（本批现测：旧布局文件已被系统清理）= **无 env 时探针恒不可用**（明确报错、`rc=1`）。
两态根因相同，但危害不同 ⇒ 不得只写历史态那一句。
② `:647–650` 的提示语同样把人引向**半成品动作**（照它构建完，产物落在 `out/Products/Debug`，
与默认值指向的那条**仍不同**）。
⇒ 载体：`docs/issue-hir-parity-probe-default-bin-path-2026-09-18.md`（**只登记不修**；是否并入 `G-6b` 见该批规划 §5.3）。
本批两次误读（一度把「同一夹具两条路径结论相反」当成架构矛盾）均由此而来。

### 未做范围

不改 `G-6b` 的对象 · 不动 `G-6c`（删本体、收开关、探针两通道化）· 不 push ·
不处置三张前置单在册状态（本批只做实现）。

⚠️ **2026-09-18 订正（`G-6b` 规划期现测）**：上面这句里的「`G-6b` 的对象」原写「**四份**同构装配整合 · …」，
实测为 **9 个调用点 / 4 个文件**，且 `resolveHIRPackage` 今天**不存在**。逐项订正与完整清单见
`docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §1.1 / §1.2。
⭐ **其中两处是 `G-6a` 自己写出来的** —— 处置 B 把 `runDebugFile` / `runDebugDirectory` 接到 HIR 时，
**手写了第三份 `check → lower → execute`**（没有复用已是 `DebugHookHost` 的 `ProgramRunner`）
⇒ 本批在解除引用面的同时，**使装配同构从「四份」变成「九处」**。这不是缺陷，是**登记未跟上事实**。

⛔ **2026-09-18 二次订正（`G-6b-2`）：这条「同构」判断本身也被推翻了。** 12 个调用点按**五维**
（`lower` 时机 / 错误面 / 下游类型 / `import` 合并 / `requiresMain`）摊开后，**变体数与调用点数同阶**
⇒ 它们不是「同一段代码抄了 N 遍」，而是**看起来像共有前端**的 N 个不同调用点。
⇒ 用户 2026-09-18 裁决「**不整、订正登记**」，「装配整合」**从 `G-6` / `G-6b` / `G-6c` 的对象里撤销**。
依据见 `docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §10.4；订正落点见
`docs/issue-hir-p4-gamma-plan-2026-09-16.md` §8.4。
⚠️ **这是同一件事的两次订正**（先是「四份 → 九处」的量，再是「同构」这个前提本身）——
两次都来自**实测**，两次都说明**按形状登记而不按机制核实**会连续出错。

⚠️ **三张前置单的在册状态（2026-09-18 已在 `G-6b` 规划批内处置完毕，此处留痕）**：
`issue-hir-builtin-user-extension-gap-2026-09-18.md` → **已交付**（判据 4 已订正）·
`issue-hir-foreign-symbol-not-found-not-loud-2026-09-18.md` → **已交付**（判据 4 已于 `G-6b-1` 复核通过，四判据全达）·
`issue-interpreter-residual-reference-surface-2026-09-18.md` → **部分交付**（余项归 `G-6b` / `G-6c`，**不得归档**）。


## G-6b-1 引用面改指 + `checkCancellation` 单源化 — ✅ **已交付**（2026-09-18）

> **授权**：用户 2026-09-18「按你的建议来」⇒ 采纳 `G-6b` 规划 §10.6 的**三项自查建议**
> （① 5 条不可转用例**随 `G-6c` 退役** ② **撤销**「装配整合」动作、改为订正登记 ③ 单源化 `checkCancellation`）。
> **上游**：`docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §10（开工首步止损的实测与重切选项）
> **本批真改源码**（`Sources` 3 文件 + `Tests` 1 文件）；**`G-6b-2`** 承载 ②与器械、改名。

### 改了什么（逐处）

| # | 位置 | 改动 |
|:--:|---|---|
| 1 | `Sources/PiniCore/Runtime/RuntimeOps.swift` | **新增** `checkCancellation(_ owner:)` —— 该规则的**唯一实现**（`@inline(__always)`，函数体与原先两份**逐字相同**） |
| 2 | `Sources/PiniCore/Interpreter/Interpreter.swift` | 原实现 → **转调** `RuntimeOps`（注释写明上提理由；`SuspendEvaluator` 及其热路径调用点一行未动） |
| 3 | `Sources/PiniCore/Interpreter/HIRExecutor.swift` | **删掉私有拷贝**（含其文档），两处调用改指 `RuntimeOps.checkCancellation` ⇒ **净删**，不是加一层 |
| 4 | `Tests/…/StructuredConcurrencyTests.swift` | 3 条用例改指（`joinFuture` · `checkCancellation` · `makeResult`/`makeError` → `RuntimeOps.*`）；助手 `runProgramAST` 的文档改写为**那 5 条退役的具名依据** |

⭐ **为什么单源化是必须的**：`HIRExecutor` 那份是 `private` ⇒ 这条接缝在测试侧**只能经由某个引擎的名字**断言，
而那正是它会在删除日一起消失的原因。上提到 `RuntimeOps`（那里已住着 `joinFuture` / `makeCancelError` /
`isCancelErrorValue`）之后，判据落在**规则本身**上，不落在某个引擎上。

### 判据（全部现测）

| 判据 | 读数 |
|---|---|
| **新增红 0** | 分块驱动 115 类**两侧各跑一遍**：基线 **56**（22+14+20）→ 本批 **56**（22+14+20）；**逐条集合比对 = 新增红 0 · 转绿 0 · 仍红 56**（**集合相等**，不是只比总数） |
| ⭐ 基线的**互证** | 本批起点基线与本批前记录的 `G-6a` 收口读数（56）**逐条相同**，且与 25 分钟前落盘的上一轮失败清单**逐条相同** ⇒ 树稳定、装置可信 |
| **编译面零阻塞** | 去注释扫描：`Tests` 侧 `Interpreter` **只剩助手那一处**（原 6 处 → 1 处）；`Sources` 侧余项**逐处落在 `G-6c` 的删除面上**（逐条见残余单 §2.3.2） |
| 契约 | `tools/hir-contract-check.py` **clean**（45 expr + 17 stmt = 62，三锚点各 62/62） |
| 用户可见入口冒烟 | `pini run <file>` · `pini run <dir>` · `pini debug <file>` · `pini repl` **四入口均正常**（`debug`：停在入口 → `l` 列断点 → `c` 跑完 → 输出 `3.0/4.0/5.0`） |
| 前置复核 | `foreign` 单**判据 4**（vendored FFI 不受急切解析影响）：两引擎 `rc=0` + stdout **逐字节相同** ⇒ ✅ |

### ⭐ 本批最有价值的产出：三处实测订正

1. **测试侧引用面 18/19 → 19/20** —— 漏的是 `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift:484`
   的**闭包形参类型标注**。按「构造点 + 静态成员」两栏枚举**结构性看不见**它
   ⇒ 普查一律用 `\b<TypeName>\b` **全量**数，形态划分只可用于分类、不可用于枚举。
2. **「类型标注」那一栏能否免处理，必须实测** —— 原怀疑它会被存活用例拖住；逐条实测
   `captureSuspendStdout` 的 **3 个调用者全在退役的 11 条内** ⇒ 才敢判「随退役面消亡」。
   若有**一个存活调用者**，就必须先改它 —— 这是**判据成立与否的前提**，不是细节。
3. **一处「已立案」未验真** —— 规划件把 `defer` 缺口写成「已立案」，`grep` 全 `docs/` **无命中**。
   本批**据实新立工单** `docs/issue-hir-defer-not-run-on-cancel-2026-09-18.md`；
   纪律：凡写「已立案」，须回 filesystem 用 `grep -rl` 验。

### 未做范围

- **那 5 条不可转用例与助手**：**随 `G-6c` 退役**，本批**只入账不删**。
  理由不是拖延：**AST 引擎还活着时它们仍是真实覆盖**，提前删是**净损失**；与引擎同批消失，
  代价才由「引擎被删」解释。`G-6c` 须**按名**处置它们（具名账 = 残余单 §7.3）。
- **`G-6b-2` 的对象**（撤销「装配整合」登记 · 探针默认路径 · `InterpreterTests` 改名）—— 不在本批。
- `Sources` 侧 3 处 `.ast` 分支：**随开关一起删**，本批不动。
  ⚠️ 明确记一条**「不得提前做」**：开关还在时把 REPL 的 `.ast` 静默改走 HIR，正是「静默回退假绿」。
- `G-6c`（删本体 · 收开关 · 探针两通道化）· 不 push。

## G-6b-2 登记订正 + 器械修复 + 改名 — ✅ **已交付**（2026-09-18）

> **授权**：用户 2026-09-18「按你的建议来」⇒ ② 撤销「装配整合」、订正登记；并执行两项告知项（探针 · 改名）。
> **上游**：`docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §10.4 / §10.6 · 上一节（`G-6b-1`）

### 三项处置

| # | 项 | 结果 |
|:--:|---|---|
| ① | **撤销「装配整合」并订正登记** | 该动作从 `G-6` / `G-6b` / `G-6c` 的对象里**移除**。订正落在 **6 个在位载体**：`P4-γ` 规划 §8.4（权威批次表 · `G-6` 行 + `G-6b` 行）· 同件 §8.4 的「9 处装配」注 · `P4-γ` 集群计划（`P4-γ` 行）· 阻塞队列（`G-6` 行）· 本件（`G-6a` 注）· 残余单 §2.1.1。⚠️ **归档件不改**（历史叙述） |
| ② | **探针默认二进制路径** | 写死 → **运行时解析**（问 SwiftPM），新增 `--scratch-path`；四判据逐条实测，见下一节 |
| ③ | **`InterpreterTests` 改名** | → **`ProgramExecutionTests`**（**目录 / 文件 / 类**三级，`git mv` 保历史）；入向引用 **3 个 spec 级载体**（语言面测试类清单 · 测试目录分类件 · 测试原则件的类表与代码示例）同批改完 |

⭐ **①的判据**：`grep` 全 `docs/` 的「装配整合 / 同构装配」命中处**逐条**要么已撤销、要么判定为**历史叙述**
（归档件、以及「当时写下」的段落）。⚠️ **撤销不是删字** —— 原文保留并标注：
「按形状判同构」这一次误判本身值得留痕，且它是**同一件事的第二次订正**
（先是「四份 → 九处」的量，再是「同构」这个**前提**本身）。

### 探针四判据（逐条实测）

| # | 判据 | 实测 |
|:--:|---|---|
| 1 | **无 env 可用** | `env -u PINI_SWEEP_BIN … --scratch-path /tmp/pini-build` ⇒ **`rc=0`**；首行 `binary under test: /tmp/pini-build/out/Products/Debug/pini`；78 夹具 · `FLIP BLOCKERS 0` |
| 2 | **覆盖仍生效** | 设 `PINI_SWEEP_BIN=<repo>/.build/…/pini` ⇒ 工具**读的是它**（两枚二进制 **md5 不同**：`73e01257…` vs `ac1c1b29…`） |
| 3 | **不再绑字面量** | 工具内**零**硬编码产物布局（`arm64-apple-macosx` / `out/Products` / `/tmp/pini-build` **全仓 0 命中**） |
| 4 | **提示语自洽** | 解析失败时打印 `build it with:  swift build --disable-sandbox --product pini --scratch-path <同一个>` ⇒ 照做即落在解析处，**无第二步骤** |

⚠️ **一处行为变化（须记）**：探针**新增 `--scratch-path`**；不带它时解析的是 SwiftPM 默认布局（仓内 `.build`），
而本仓各批一贯用 `--scratch-path /tmp/pini-build` 构建 ⇒ **规范调用式下调为带该旗标**（已同步进 skill）。
这不是缺陷：**一个解析出来的默认值只能有一个**，而本仓有两个常用 scratch ⇒ 让调用方说明，比让工具猜更诚实。

### 判据（全部现测）

| 判据 | 读数 |
|---|---|
| 回归**集合相等** | **重跑一次**（因改了测试面）：115 类 / 三块 **22+14+20 = 56**，与基线**逐条集合相等**（新增红 0 · 转绿 0） |
| ⚠️ 为什么必须重跑 | 改名会**改变测试发现**。判据不是「数的总数相同」，而是「**改名后的类真的被跑到**」—— 实测 chunk2 的 suite 清单里出现 `ProgramExecutionTests`；且分块驱动的「未跑类」护栏为 **0**（若沿用旧类名清单，它会以 `exit 2` 判整表作废） |
| 改名判据 | `swift test --filter ProgramExecutionTests` 跑得到 **12 条**（与原名同数） |
| 契约 | `clean` 62/62 |
| 门禁 | comment-lint 六层全过 · doc-links 1099 引用通过 · evidence 0 违规 |

### 未做范围

- **不改归档件**（`docs/spec/issue/archive/*` 里对 `InterpreterTests` 的引用属历史）。
- **不动 `G-6c` 的对象**（删本体 · 收开关 · 探针两通道化 + 新冻结件）。
- **不 push**。

## `G-6c-1` 删 AST 走查本体 + 收引擎开关 — ✅ **已交付**（2026-09-18，`9deea90`）

> **授权**：用户 2026-09-18 点名 `G-6c`，并对三项待裁给「这次按你的建议来」⇒ ① `InterpreterEngine`
> 整体删 ② `ReplEvaluator` 的两臂一致用例改造为单臂绝对断言（参照臂读数冻结成期望）③ 器械族同族收口、
> `three-edge-union.py` 取「标为已失去对象 + 台账改判」。
> **规模**：20 文件 / **+385 −5077**（删除面 **4162 行** = `Interpreter` 3090 + `SuspendEvaluator` 890 +
> `SuspendScheduler` 159 + `InterpreterEngine` 23）。
> ⭐ **本批是整条 LR-4 主线上第一个不可逆批**：删除面一旦落地就没有回退对象（`D-B3=A` 的末态就是退役）。

### 开工前实测：删除到底会带走什么

| 核的项 | 实测 | 结论 |
|---|---|---|
| `Interpreter` 的 41 个 `static` 成员 | **全是一行转发**（`{ RuntimeOps.xxx(…) }`），存活面引用**全部**是 `RuntimeOps.*` | ⭐ 冻结件 §2 记的「共享单源风险」**已不成风险**：删本体时它们一起消失，零影响 |
| 同名不同物 | 命中的同名人分属 `HIRLowerer` / `ProgramRunner` / `BuiltinRegistry` / `RuntimeError` | 不能用「同名」判引用，须逐处看 |
| `Scheduler` 协议 | `HIRExecutor` 与 `RuntimeOps` 都在用 | **保留**（只有 `SuspendScheduler` 那份实现随测试退役） |
| `SuspendSignal` | 定义在 `Interpreter.swift`，引用全在删除面内 | 随文件消亡 |
| 全仓 `\bInterpreter\b` | **79 行** = 删除面 61 + `Sources` 余 3 + `Tests` 余 15 | 与残余单 §2.3.2 的预言逐处吻合 |

### 改了什么

| 面 | 改动 |
|---|---|
| 删除 | 4 个源文件（三个走查件 + `InterpreterEngine`）· `CPSDifferentialTests` 整份（14 条） |
| 开关 | `selectedInterpreterEngine()` 整段删除；`runRunPath` 两处 AST 回落删除；`ReplEvaluator` 的 `engine:` 参数与 `.ast` 分支删除；`ReplSession` 不再持有引擎 |
| 测试 | `SuspendRuntimeTests` 11 条 → 保留 4 条值层原语（本文件 506 → 103 行）· `StructuredConcurrencyTests` 14 条 → 9 条（删 5 条 + AST 助手）· `ReplEvaluatorTests` 去参数化 + 两条「两臂一致」改造 |
| 注释 | 全仓**逐处**订正指向已删符号的注释（`HIRExecutorTests` 的四处出处指针 · `BuiltinOverrideTests` 的分类结论改历史陈述 · `HIRExecutor` / `ProgramRunner` 的缺口清单 · `DAPServer`） |

⭐ **`ReplEvaluatorTests` 那两条为什么不是删掉**：它们的断言对象是「两臂逐项相同」，参照臂一删就没有第二臂可比。
但那次一致**是这批输入唯一的读数** ⇒ 正确处置是**把读数冻结成期望**（判据从「两台互证」升级为「一台对规格」）。
值**不是设计出来的**：`G-6c` 把 7 个输入逐条经 CLI REPL 实测核对（`printf '<输入>\n' | pini repl`），
得 `3 / 7 / 7 / hi / -5 / true / true`，再写成期望。⇒ 覆盖一条不丢，且红了会**指名道姓**。

### 判据（全部现测）

| 判据 | 读数 |
|---|---|
| **编译面零阻塞** | `Sources` 与 `--build-tests` **各 0 个 error**（残留面与 §2.3.2 逐处吻合 ⇒ 按清单执行即够，无需顺手改测试） |
| **无新增红** | 分块驱动 **114 类**（清单减去整份退役的 `CPSDifferentialTests`）：基线 **56** → 本批 **56**，**逐条集合相等**（新增红 0 · 转绿 0 · 仍红 56） |
| 契约 | `clean` 62/62 |
| 用户可见入口 | `run` 单文件 · `run` 目录 · `repl` · `debug` **四入口实机冒烟全通** |
| 开关已惰性 | `PINI_INTERP_ENGINE=ast` 与 `=__bogus__` 都**照常运行**（旧行为对非法值是报错退出 1）⇒ 该变量已无意义 |

### ⭐ 删除的爆炸半径里浮现的两条缺陷（**都已立案/闭环，都不在本批顺手修**）

1. **`pini run <目录>` 不做入口一致性校验** —— 新单 `docs/issue-cli-package-entry-check-2026-09-18.md`。
   实测：同一份「entry 与 main 不符」的包，默认引擎打印 `42` 并 `rc=0`，`ast` 回落臂正确报 `E5-018`。
   ⚠️ **归因订正**：**不是**删除造成的 —— 默认路径自 P4 翻转起就不校验（CLI 只给解释器注入 `entryFiles`）；
   删除的真实影响是**「回落时还查」这条退路也没了**。⇒ 独立小批，处置候选 A/B/C 在单里。
2. **`HIRExecutor` 的「No struct value-copy」缺口条目已关闭，而文档未撤、工单仍 Open** ——
   用**该工单自己的最小见证**重跑：见证一（`var b = a` → `b.x = 99` → `print(a.x)`）现打 **`1`**（缺口开着时是 `99`）；
   四个落点逐处 `RuntimeOps.copyIfStruct` 已应用；`ValueSemanticsTests.testStructCopySemantics` **通过**。
   ⇒ 工单状态改「已交付并闭环」，**并如实登记两条限制**：见证二（struct 写入 struct 字段）**未能复现**
   （转写出的夹具报 `E4-001`）⇒ 该落点**只有代码证据、没有见证证据**。

### 未做范围

- **`G-6c-2`**（探针两通道化 · 器械族 · 冻结件作废 · 残余账）—— 见下一节。
- **不 push**。

## `G-6c-2` 探针两通道化 + 器械族收口 + 冻结件作废 + 残余账 — ✅ **已交付**（2026-09-18）

### 探针：从「三通道」到「两执行通道 + 一诊断来源仪器」

删掉参照臂后，`interp-ast` 与 `interp-hir` 会变成**同一条命令** ⇒ 三通道表会报出**没有任何东西测过的「一致」**。
这是本仓反复记录的失败模式，故 `G-6c-1` 先给探针**加封印**（拒绝出数、非零退出），`G-6c-2` 再改造，封印随之移除。

⭐ **替代观测层不是「补一个替身」，而是把观测点上移**（承 `G-5` 的定式）：

| 面 | 原来由谁作证 | 现在由谁作证 |
|---|---|---|
| 执行等价 | `ast` ⇄ `hir` ⇄ `llvm` 三方 | **两臂**：`interp-hir` ⇄ `llvm-hir` |
| 一条诊断**来自哪一层** | 参照臂「也报同一条」 | **`pini check`**：它**只跑前端、什么都不执行**，直接观测该诊断属不属于共享前端 |

⇒ `check` **不是第三个通道**（它不执行，不能对行为作证），是**仪器**；分类里只有**一个槽**咨询它，
且要求它报**同一个诊断码**（仅「都出声」不算佐证 —— 前端在抱怨别的事不是佐证）。

### 改了什么

| 面 | 改动 |
|---|---|
| `hir-parity-probe.py` | 通道块与 VERDICTS 逐条改写；`classify` 重写（两执行通道 + 仪器）；`diag_code()` 新助手与 `DIAG_CODE` 常量；TSV 列 `a_*` → `c_*`；summary 顺序表与分组去退役槽；封印移除 |
| 槽集 | **退役 4 个**：`TIMEOUT_AST` · `CHANGE_F64` · `CHANGE_OTHER` · `CHANGE_REFERENCE`（全是「参照臂是异类」类）。**重定义 2 个**：`WARN_CHANNEL_ASYMMETRY`（改由 `check` 佐证）· `GAP_BEHAVIOR`（改成两臂的**纯**两通道形式）。**削弱 1 个**：`WARN_LLVM_RC_UNPROPAGATED`（不再有「参照臂也失败」的旁证，改由 LLVM 臂自己的 stderr 佐证 —— 已在文档里写明是**减弱**） |
| 器械族 | `three-channel.py`（`ast` 通道 → 前端仪器；文件名保留，理由写在文件头）· `hir-spec-assert.py`（通道表去 `interp-ast`；生成模式从「三通道一致」改「各通道一致」）· `compare-sweeps.py`（文档订正）· `three-edge-union.py`（**标为已失去对象、不重构**，台账 `CG-03` 改判） |
| 冻结件族 | `docs/hir-ast-walk-freeze.md` **标作废**（按其自定判据）· `hooks/commit-msg` 的 `[ast-walk]` 段**已删** · `tools/ast-walk-freeze-check.py` **已删** |

### ⭐ 闭合账目（逐夹具，不是只比总数）

| 项 | 读数 |
|---|---|
| 分母 | **320** 夹具（与参照臂时代**同一键集**：仅在前 0 · 仅在后 0） |
| 逐槽 | **5 槽逐槽相同**：`PACKAGE_MEMBER` 27 · `WARN_CHANNEL_ASYMMETRY` 20 · `FRONTEND_FAIL` 11 · `WARN_LLVM_RC_UNPROPAGATED` 4 · `HARNESS_DEPENDENT` 1 |
| 迁移 | **恰好 2 条**：`CHANGE_REFERENCE → OK`，且就是那两条「参照臂是异类」的夹具（`testBareCaseAmbiguousExpectedTypeViaLLI` · `testDotCaseAmbiguousExpectedTypeViaLLI`）⇒ **逐条相同 318/320，其余 Δ 全 0，归因闭合** |
| 阻塞 | **`FLIP BLOCKERS 0`** · 阻塞明细段为空 · 0 lli 存活 · 0 散落 `.ll` |
| 新冻结件 | `/tmp/g6c-two-channel-frozen.tsv`，36838 字节，`md5 ca4417cffe4c62e8a8fe48ec520d48f5`（**新分母 320**，与旧件同分母） |
| ⭐ 替换件的判别力 | `WARN_CHANNEL_ASYMMETRY` **仍为 20**（逐条相同）⇒ `check` 仪器**复现了参照臂在该槽上的全部鉴别力**，不是「换了个更松的判据把数凑回去」 |

⚠️ **一句必须说清的话**：`CHANGE_REFERENCE` 那 2 条的**信息没有丢**，但它**不再存在于探针里** ——
它记在本节（一次性迁移事实），而不是被做成一张 2 行的永久例外表。永久例外表会让「参照臂曾经不同意」
看起来像一条**当前**判据，而那已经不是一个能问的问题。

### 上游 P4 四项判据逐项复核

| # | 原判据 | 复核结果 |
|:--:|---|---|
| 1 | 全量回归 | **56 条失败，与基线逐条集合相等**（交付前），且判据形态按 `G-0` 的订正读（「已迁面全绿 ∧ 未迁面零位移 ∧ 残余逐条归因」） |
| 2 | 全量探针 0 阻塞 | ✅ **`FLIP BLOCKERS 0`**（新两通道口径） |
| 3 | 763 个解释器用例全绿 | ⚠️ 该集合**已不存在**（`G-0` §8.2 已裁其对应物）：A 类 429 例早已改指；本批再退役 30 条（5 并发 + 11 挂起 + 14 CPS），其归属见下一小节 |
| 4 | 调试/DAP/REPL 用例全绿 | ✅ 四入口实机冒烟 + 定向面 28/28 绿（含 `DebuggerTests` 17 条） |

### 残余具名入账（**不得静默转红**）

**A. 本批退役的用例（30 条，逐条归因）**

| 组 | 条数 | 归因 | 归属批 |
|---|:--:|---|---|
| `StructuredConcurrencyTests` 语言层 | **5** | 换到现役引擎后全红，且**每条撞在已有主的缺口**上（`Result` 值打印 3 · 结果类型 1 · `defer` 清理 1） | `G-6c-1`（用户 2026-09-18 裁 A） |
| `SuspendRuntimeTests` 挂起面 | **11** | 驱动的是建在走查上的整套挂起机制（`suspendMode` / `runSuspendable` / 自研池），机制随走查退役 | `G-6c-1` |
| `CPSDifferentialTests` | **14** | 同上：同步/CPS 两路径的差分，两路径都建在走查上 | `G-6c-1` |

⚠️ **代价如实登记（不粉饰）**：
- **语言层端到端并发覆盖 8 条 → 3 条**（「父返回取消未 join 子」在**单元层**仍有 3 条存活用例守着）。
- **`defer` 清理那条退役后，「取消时 HIR 不执行 `defer` 清理」这条缺陷不再有测试见证** ——
  只在工单里（`docs/issue-hir-defer-not-run-on-cancel-2026-09-18.md`）。**退役不等于缺口消失。**
- **挂起语义（`<=` 释放线程 · resume 边界取消 · work-stealing · 背压）此后没有测试见证**，且换到现役引擎上**未落地**
  （`Recorded`：`ADR-043` 退役该实现）。这是一次**能力净减**，不是「测试简化」。

**B. 本批之前既有的 56 条失败**：全部**保持原状**（逐条集合相等）⇒ 无一条被本批顺带转红或转绿。

**C. 判据面的暴露**：`three-edge-union.py` 失去对象（见器械表），其原覆盖的「包通道 `ast<->hir`」一条
**不再有人测**；替代面 = 探针的两执行通道 + 仪器。

---

## `G-6c-2` 收口回填（2026-09-18）—— 指针全篇扫 · 判据 ③ 逐项复核 · 两张工单状态

> 本节记的是**收口动作本身**：`G-6c-1` / `G-6c-2` 改了什么见上两节，本节记**它们把哪些别处的说法变成了假话**。

### 1. 指针全篇扫（收口技能 §3 的硬要求）

扫法：`grep` 全 `docs/`（去 `archive/`）的 `下一单元` / `下一格 = ` / `待点名` / `未开` / `已交付四` / `仅余` / `待做`，
命中处**逐条判定**「活指针」（描述现在）还是「历史叙述」（讲过去）。

**A. 改为当前值的（21 + 8 = 29 处，涉及 10 份文件）**

| 载体 | 处 | 原写法 | 判为 |
|---|---|:--:|---|
| `docs/issue-hir-p4-gamma-plan-2026-09-16.md` | 8 | 顶部行「仅余 `G-6`（待点名）」· §2 导语 · §8.4 状态行「下一单元 = `G-6`」· `G-6` 行无 ✅ · `G-6c` 行「⏳ 未开」· 被推翻的「4 个用例 / 6 处引用」块 · §8.7 表缺末测点与终结说明 | **活指针** |
| `docs/issue-hir-p4-plan-2026-09-16.md` | 2 | 顶部「已交付四」「仅余 `G-6`」· `P4-γ` 行尾「`G-2R`/`G-3`/`G-4·G-5`/`G-6` 待做」 | **活指针** |
| `docs/issue-hir-blocker-queue-2026-09-17.md` | 2 | §4 的 `G-6` 行「`G-6c` 未开」· 同格可逆性列「**不可逆**（`G-6c`）」· 另加头部收口刷新行 | **活指针** |
| `docs/issue-interpreter-hir-plan-2026-09-12.md` | 2 + 新 §14 | §13「开工顺序」行尾 `下一单元 = G-3c-1` · 件末 `下一单元 = G-3c-2` · **§7 里程碑表 `P4` 行** | **活指针** |
| `docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` | 1 | 头部「**状态**：待点名」（该批已交付并已执行） | **活指针** |
| `docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md` | 1 | §13 尾 `下一单元 = G-3c-2`（`ADR-043` 已取消该单元） | **活指针，替 `G-3e` 补账** |
| `docs/issue-interpreter-residual-reference-surface-2026-09-18.md` | 5 + 新 §8 | 头部状态 · §1 余项「不得归档」· §4 判据 4 行 · §4 结语 · §0「删 4143 行」 | **活指针** |
| `docs/issue-p0d-char-scheduling-2026-09-17.md` | 1 | §2 约束 3「主线正在不可逆面之前」⇒ **窗口已关闭** | **活指针，且是立法性前提** |
| `docs/issue-hir-import-module-symbols-2026-09-16.md` | 1 | §3「翻转前置……本单是硬前置」 | **活指针，且已被事实否证** |
| `docs/issue-hir-labeled-continue-skips-loop-tail-2026-09-17.md` | 1 | §性质「它需要在翻转前落地或显式接受」 | **活指针，期限已过** |

**B. 判定为历史叙述、一字未动的**

| 载体 · 处 | 为何不动 |
|---|---|
| `docs/issue-hir-p4-gamma-plan-2026-09-16.md` §2 六批表的「删 4673 行」行 | 该表**自己已标**「已被 §8.4 修订…保留以留存规划期的判断痕迹」；改它等于篡改痕迹 |
| `docs/issue-interpreter-hir-plan-2026-09-12.md` §13 内各格条目尾部的 `下一单元 = …` | 写的是「**当时**下一格是谁」，是编年体 |
| `docs/issue-hir-p4-plan-2026-09-16.md` §7 的 `D-P4-x` 决策记录行 | 裁决记录（如 `D-P4-28` 的「修订为五单元」）记的是**决定**，不是现状 |
| `docs/issue-hir-cg-ledger-batch-2026-09-17.md` §7「不启动 `G-3` / `G-4·G-5` / `G-6`」 | 那是**该批自己的不做范围声明**，在它的语境内为真 |
| `docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md` §1.1 / §14.5 的行数读数 | 各自的时点读数；`§8.7` 已声明自己是行数的唯一权威点位 |
| `docs/hir-ast-walk-freeze.md` 全文 | 已在 `G-6c-2` 作废并标明「以下一律按历史读」 |
| `docs/spec/adr/adr-031-*.md` 的「翻转前任一时刻可经 git revert 回退」 | ADR 正文，记录当时的决定 |

### 2. ⭐ 判据 ③ 的复核落点（**不重复记账**）

`G-6` 判据第 ③ 条要求「上游 P4 行四项逐项复核」—— **逐项结论见上节 `G-6c-2` 的
「上游 P4 四项判据逐项复核」表**，本节**不重复列数**（同一笔账写两处，两处会各自漂）。

本批在那一侧只补做了一件事：

- ✅ **上游 `docs/issue-interpreter-hir-plan-2026-09-12.md` §7 里程碑表的 `P4` 行已就地订正**：
  补 ✅ 已交付、写明四个删除文件 / 4162 行、开关退役、探针改口径，并把**原验收四句标注为
  「已被 `D-P4-25` 订正、不得再作判据读」**（原因见 `docs/issue-hir-p4-gamma-plan-2026-09-16.md` §8.2），
  同格写入现行四条与交付读数。
  ⚠️ 这一步是**必要**的：不写，「**763 个解释器用例全绿**」这个**已不存在的集合**
  会继续作为上游判据被下一批引用（`P4-β` 把 A 类 429 例改指 `ProgramRunner` 之后，它已不是有意义的集合）。

### 3. ⚠️ 扫描顺带发现的两处**陈旧早于本批**（如实登记，不假装是本批的口径）

| # | 处 | 陈旧自 | 本批处置 |
|:--:|---|---|---|
| 1 | 主计划 `issue-interpreter-hir-plan-2026-09-12.md` §13 行尾与件末的 `下一单元` | **`G-3e` 收口（2026-09-17）** —— `G-3c-2` 取消后未回填 | 就地加过期标注 + 新增 §14；**替上一格补账** |
| 2 | `issue-hir-p4-gamma-g3-plan-2026-09-17.md` §13 尾同一句 | 同上 | 同上，并在标注里写明是**替 `G-3e` 补的** |

⚠️ **这两处正落在 `p2-plan` 已记录过的同一个坑上**（「『下一格』指针一处未扫 ⇒ 四处陈旧」）——
说明该纪律虽已写进收口技能，**G-3e 那批仍未照做**。本批按纪律补上，**不据此改动技能**（一次实证不足以定论）。

### 4. ⛔ 两处「过期措辞」同时是**实质事实变化**（不只是措辞）

这两条**不是**指针问题，是**判据的前提变了**，故单列：

| 处 | 变化 | 实测证据 |
|---|---|---|
| `docs/issue-hir-import-module-symbols-2026-09-16.md` §3 | 原写「**任何**带 `import` 的包在 HIR 引擎下不可运行」+「本单是**翻转硬前置**」。现在：翻转已执行而本单未落地 ⇒ 「硬前置」措辞过期；**且影响面比原文窄** | `demo/app`（普通 `import`）**rc=0，输出 `3`**；仅 `demo3/app`（两模块导出同名顶级符号）**rc=1 · `E6-004`** |
| `docs/issue-hir-labeled-continue-skips-loop-tail-2026-09-17.md` §性质 | 原写「翻转后 `ast` 参照臂删除 ⇒ 不会再有人交叉验证 ⇒ 需在**翻转前**落地或显式接受」。两件都没发生 ⇒ 那句话**从预测变成了事实** | `interp-ast` 臂已删 ⇒ 该单 §现象表的 `interp-ast` 一列**不再可复现**，`interp-hir` 失去一致性伙伴 |

⚠️ **本批对这两条只做「改状态 + 记事实与日期」，不做裁决、不改本体**（处置属工单治理循环）。
⚠️ **两条本身的缺陷都仍在册且仍 Open** —— 本批**没有**修掉它们，只是让它们的措辞不再说假话。

### 5. 本批**未做**（按纪律）

**不 `git mv` 任何工单**（归档动作属工单治理循环）· 不修在册工单的**本体**（只改状态行/加事实注）·
不动 `Sources` / `Tests`（`G-6c-2` 区间实测零改动）· 不 push · 不改收口技能。

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


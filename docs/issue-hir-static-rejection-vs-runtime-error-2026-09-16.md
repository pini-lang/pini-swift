# 静态降载层提前拒绝，而测试断言运行期错误形状

> 状态：**Open —— 规范侧已裁并落地；本体（用例期望值改写）未做**。
> ⚠️ **2026-09-18 工单巡查批订正一处失效指向**：旧头部写「本体待 `G-4·G-5` 实施」，
> 而 `G-4` 与 `G-5` **已交付、且未做此事**（`G-4` 改指的是「驱动 `runTests` 的 10 条用例」，
> `G-5` 改的是「`D` 类 15 处换腿」）⇒ 该指向**已失效**。
> 这 13 条用例的期望值改写实为 **`G-6` 残余**（`D-P4-25` 判据第 4 条「残余逐条具名入账」）的一部分。
> ⚠️ **本次订正未实测那 13 条的当前红绿**（要实测须跑全量回归，不在本批范围）⇒ 属**推断**，如实标注。
> ⚠️ **另有 2 条已转入本单**（由 `docs/spec/issue/archive/issue-hir-generic-enum-specialization-2026-09-16.md`
> 归档时明确转移，原文写「明确转移（不随本件归档结案）」）：`testGenericEnumArgumentCountMismatch` ·
> `testUndefinedGenericTypeStillThrows` —— 同族（期望运行期、实得静态层拒），**本单实际承载 13 + 2 = 15 条**。
>
> ✅ **裁决（2026-09-17，用户）**：取 **①** —— **规范写明「编译期拒」**。
> 落位 = `ADR-041`（`docs/spec/adr/adr-041-static-layer-rejection.md`）+ spec **§2.4.5** + **G63**。
> **判据绑定方法（用户原话）**：**通过测试方法断言维持验证** —— 负向夹具**不删**，
> 改断言「该程序被拒 ∧ 拒绝发生在静态层 ∧ 错误码是哪一个」。
> ⚠️ **本单 §2 第 4 点那条纪律已被执行**：先裁规范、再改用例 ⇒ **用例期望值的改写归 `G-6`**。
> ⚠️ **`D2` 的另一半（诊断通道奇偶 20 条）不并入本单** —— 归 `docs/issue-diagnostic-channel-parity-2026-09-12.md`。
> 发现于：`G-2` 全批收口时的成因归类。它是**余量里占比最大的一类**。
> 上游：`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的「G-2 全批的头号发现」。

## 1. 现象（实测，2026-09-16，`main` = `d1585e8` 之前的 75 条余量）

同一批测试里，**程序都被拒绝**，差异只在**在哪个阶段被拒、报什么种类**：

| 用例 | 测试断言（运行期）| 实际（编译期）|
|---|---|---|
| `FieldVisibilityTests/testPrivateFieldAccessThrowsAtRuntime` | `RuntimeError` | `E4-012` field is type-private |
| `TupleIndexTests/testOutOfBoundsIndexThrows` | `invalidOperation` | `E4-001` expected tuple(2), got index 2 |
| `TupleDestructureTests/testRuntimeNonTupleRightThrows` | `typeMismatch` | `E4-001` expected tuple, got I32 |
| `ResultUnwrapTests/testUnwrapNonResultThrows` | `typeMismatch` | `E4-001` expected Result<T, E>, got I32 |
| `BuiltinFunctionTests/testAssertNonBoolConditionThrows` | `invalidOperation` | `E4-001` expected Bool, got I32 |
| `BuiltinFunctionTests/testLenThrowsForInteger` | `invalidOperation` | HIR 降载拒绝 `len on 'i32'` |
| `GenericRuntimeTests/testUndefinedGenericTypeStillThrows` | `invalidOperation`「未定义的泛型类型」| HIR 降载拒绝 `unknown generic` |
| `FFITests/testUndefinedNativeFunctionRejected` | 运行期报错 | 降载拒绝 |
| `LazyRefTests/testLazyRefNonFunctionArgFails` | `RuntimeError` | 降载拒绝 |
| `ParserRestructureTests/testBracketObjectNotComposable` | 解析错误「引用块不可组合」| `未找到 main 函数` |

## 2. 这是什么问题（**不是**「HIR 缺功能」）

1. 这些测试的共同形状是「**喂一个非法程序，断言抛某类运行期错误**」——
   它们是在 **AST 走查是唯一引擎**的时代写的：那时很多检查只能到运行期才发现。
2. HIR 是**静态降载层** ⇒ 它在降载期就看出同一个程序不合法，于是**更早、以另一种错误种类**拒绝。
3. ⇒ **程序语义（被拒）一致，判据的形状不一致**。这不是回归，也不是缺口；
   它是「**语言规范说运行期 trap，而静态层提前拒了**」这件事本身**是否可接受**的问题。
4. ⚠️ **它不能靠改测试结案**：把断言从 `RuntimeError` 改成「编译期报错」，
   等于**用实现去定义规范**。要动就得先裁「这些情形规范要求在哪一层拒」。

## 3. 影响面（实测口径）

本类在 `G-2` 收口时的 75 条余量中**占比最大**，横跨 10 个测试类。
⇒ **`P4-γ` 余量的性质不是「一批待补的降载面」，而是「一半以上是判据形状待裁」**。
这一条直接影响 `G-6`（删走查）的判据设计：**删掉走查后，这些用例的期望值必须重写**，
而重写方式取决于本单的裁决。

## 4. 待裁（供后续，本单不预设）

| 选项 | 含义 | 代价 |
|---|---|---|
| A 保持「静态层更早拒」| 规范写明这些情形**编译期拒绝**，改测试断言 | 规范变更（§1.3 五步）+ 逐条改断言；`LLVM` 侧行为须同步核 |
| B 让 HIR 延后到运行期 | 静态层放过，运行时抛同一形状 | 静态层要**故意漏检**，与本项目「降载层不静默放行」的立场冲突 |
| C 分层写规范：能静态判的编译期拒、不能的留运行期 | 逐条判定 | 需要逐条过 10 个类，工作量最大，但结论最稳 |

⚠️ **建议倾向 C**（逐条），理由：A 会把「本来能早发现」的检查降级为运行期，
B 与 `P4` 的存在理由相抵；而 C 的代价是**一次性**的逐条梳理，且同时产出 `G-6` 需要的期望表。

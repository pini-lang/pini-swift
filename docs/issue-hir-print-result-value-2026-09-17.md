# Issue：HIR 侧「Result 值的消费面」未实现（打印 / 运算 / 赋值）

> **日期**：2026-09-17｜**状态**：**Open**（只登记不修）
> **发现于**：格 `G-3c-1`（异步管道 + 阻塞 join）
> **性质**：**既有缺口被揭开**，不是 `G-3c-1` 引入的缺陷 —— 本批的连接动作把上游遮蔽去掉后，
> 一批夹具的**首缺口**落到这条规则上（`G-3c-1` 交付记录：夹具面 59 条离开旧缺口 = 19 条转绿 + **40 条**落到此面）。
> **归属**：**下一批**（不在 `G-3c-1` 内）。归属哪一格待裁 —— 它不是 `G-3c-2`（真挂起 CPS）的对象。

## 1. 现象

`G-3c-1` 之前，下面这条规则**不可达**：凡是要打印一个 `Result` 值的程序，都先死在更上游的
`expression 'join' is not yet lowered to HIR`。`G-3c-1` 接通 join 之后，它成为**首缺口**：

```
HIR lowering error at 8:18: printing a Result value is outside the slice
```

### 1.1 影响面（实测，2026-09-17）

判据面 = 8 个并发目录的 **83** 个 `.pini` 夹具（`ConcurrencyTests` · `JoinAllTests` ·
`JoinWithinTests` · `CancellationTests` · `StructuredConcurrencyTests` · `SuspendRuntimeTests` ·
`CPSDifferentialTests` · `TaskIsolationTests`）。

| 首缺口 | 条数 | 属本条？ |
|---|:---:|---|
| `printing a Result value is outside the slice` | **37** | ✅ 主项 |
| `type mismatch: result(ok: i32) is not i32` | 2 | ⚠️ 同族待查（见 §4） |
| `operator 'plus' operand types differ (result(ok: i32) vs i32)` | 1 | ⚠️ 同族待查（见 §4） |
| 其余（无 `unsupported` 报文 / `'ok'` 上下文 / `try-else` 位置） | 43 | ✘ 各有其主 |

用例面（4 类 46 用例）实测 **24 条失败**，其中约 **20 条**的红因就是本条（其余见 §4）。

### 1.2 为什么它此前看不见

**首缺口遮蔽**：`pini run` 只报**第一条**缺口。在本批之前，这些程序的执行路径上
`join` 更早 —— 于是本条既不在任何读数里，也不在任何人的清单里。这不是漏登记，
而是「**遮蔽是相对于当前已实现节点集**」这一性质的又一实例（与 `P4-1a`、`G-3a` 两批同族）。

## 2. 复现

```sh
# 单条：任一打印 await 结果的夹具
.build/debug/pini run Tests/PiniTests/ConcurrencyTests/testAsyncFuncMultipleReturns.pini
# 实测输出：Error: ... HIR lowering error at <行>:<列>: printing a Result value is outside the slice

# 面：8 目录逐夹具取首缺口
for d in ConcurrencyTests JoinAllTests JoinWithinTests CancellationTests \
         StructuredConcurrencyTests SuspendRuntimeTests CPSDifferentialTests TaskIsolationTests; do
  for f in Tests/PiniTests/$d/*.pini; do .build/debug/pini run "$f" 2>&1 | grep -m1 "unsupported feature"; done
done | sed "s/.*unsupported feature '//;s/'$//" | sort | uniq -c | sort -rn
```

## 3. 根因（符号级）

`Sources/PiniCore/HIR/HIRLowerer.swift`，`print` 的**单参形式**降载分支：

- `HIRLowerer.swift:2780-2782` —— `if case .result = loweredArgs[0].type { throw unsupported("printing a Result value is outside the slice", at: location) }`
- 同分支上邻另有一条同类拒绝（`:2774-2779`，打印错误绑定名，理由写明「the err slot is type-erased」）。

⇒ 这是一条**有意的、已登记的**降载期拒绝，理由是 **LLVM 侧的 `Result` ABI 把错误槽类型擦除了**
（`docs/spec/hir-contract.md` §1 `result(ok:)`：三槽 `{ i64, ok, i64 }`，错误槽擦为一个机器字）。
打印一个 `Result` 值需要**按值展示 `ok` / `err` 用例**，而擦除后的错误槽没有可打印的形态。

**两侧现状**：

| 侧 | 打印一个 `Result` 值 |
|---|---|
| 解释器（AST 走查 / HIR 执行器） | ✅ 支持 —— `Result` 是普通枚举值，`stringify` 走枚举渲染 |
| HIR 降载 + LLVM 发射 | ❌ 降载期拒绝（本条） |

⇒ 缺口在**降载/发射层**，解释器侧无缺口。这与 `G-3c-1` 的连接动作**无关** ——
本批只是让它从「被遮蔽」变成「首缺口」。

## 4. 同批暴露的另两条（如实登记，**归属待查**）

| 报文 | 条数 | 待查什么 |
|---|:---:|---|
| `type mismatch: result(ok: i32) is not i32` | 2 | 该夹具在 AST 侧是否本就该被拒（负向夹具）？若是，HIR 拒绝**是对的**，本条只是把「已拒」换了个层 |
| `operator 'plus' operand types differ (result(ok: i32) vs i32)` | 1 | 同上 —— 把 `Result` 当 `i32` 用**

⚠️ **这两条不得按「缺陷」记账**，除非实测确认对应夹具在 AST 侧是**通过**的。
按 `D-P4-32`（错误发现的层次 = 静态层优先）的口径，被静态层拒绝本身不是缺陷。

## 5. 处置方案（**未决策前不动源码**）

- **方案 A · LLVM 侧按契约补齐 `Result` 值的展示**：为 `result(ok:)` 的打印提供运行时段
  （按 tag 分派 `ok` / `err`，`err` 侧只能展示擦除字/占位）。代价 = 新增运行时段（涉 `libPiniRuntime` C ABI）
  + 契约 §2.32/§2.33 一族的表述可能须一并复核；收益 = 与解释器对齐、并发面用例可转绿。
- **方案 B · 收窄语义：规定「`Result` 值不可直接打印」**：走 `spec §1.3` 把该限制写进规范，
  并改那批**负向期望**的用例。代价 = **用户可见语义收窄**（解释器现可打印，须一并改）；
  收益 = 零实现成本。⚠️ 与 `D-P4-32`「静态层优先」同向，但影响的是一批**正向**用例，
  不是负向夹具 ⇒ **不属同一族处置**。
- **方案 C · 维持现状（只登记）**：把 37 条留作已知缺口，随 `G-6` 的残余清单具名入账。

**本单不预设选择** —— 三者的代价差在「用户可见语义」与「实现规模」之间，须由用户裁决。

## 6. 与在册件的关系

- **不是** `docs/issue-hir-package-run-unsupported-2026-09-16.md`（那是包运行入口）；
- **不是** `docs/issue-diagnostic-channel-parity-2026-09-12.md`（那是警告通道奇偶）；
- **是** `docs/issue-hir-p4-gamma-plan-2026-09-16.md` §2 台账里
  `outside the slice` 那一行的**具体化** —— 该行当时只按措辞聚合计数，没有具名载体；
  本单补上具名载体与符号级根因。
- ⚠️ 本条**不影响** `G-3c-1` 的判据：那批的判据是「59 条首缺口归零 + 无新增红」，
  两条均已达成（见该批交付记录）。

## 7. 不做范围

只登记，**不改源码、不改规范、不改用例**；开工须单独点名。

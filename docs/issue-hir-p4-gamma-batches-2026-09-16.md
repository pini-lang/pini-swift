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

（待执行 · 每子批实测后回填）

## G-3 R1/R2 实施

（待执行）

## G-4 `runTests` 归宿

（待执行）

## G-5 303 个对照用例的参照臂

（待执行）

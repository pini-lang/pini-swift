# 测试基建：失败路径不关 pipe ⇒ 全量回归被 SIGPIPE 打死、其后 23 个 suite 不执行

> **状态**：Open（**只登记不修**）｜**立案**：2026-09-16｜**暴露批**：`P4-β`（测试面迁移）
> **对象**：`Tests/` 下的 stdout 捕获 helper —— `dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)` 那一族

## 1. 现象（实测）

全量回归在**跑到某个并发测试时整个 xctest 进程死亡**，其后的 suite **根本不执行**：

```
error: Process '/Volumes/.../xctest /tmp/pini-build/arm64-apple-macosx/debug/PiniPackageTests.xctest'
       exited with unexpected signal code 13
```

**signal 13 = SIGPIPE**。崩溃点是 `StarvationTests.testPoolRespectsMaxConcurrency`（`started` 之后无结果行）。

### 1.1 量化（对照同一口径的基线日志）

| 日志 | suite 数 | 结果 |
|---|:---:|---|
| `P4-α` 基线（全绿，`0 failures`） | **115** | 全部执行；`All tests passed`；总值 **1270** |
| `P4-β` 整跑（`84 failures`） | **92** | 在 `StarvationTests` 处中断；`All tests` 的收尾行**缺失**；累加仅 **1035** |

⇒ **23 个 suite 从未执行**（`StarvationTests` 之后按字母序的全部）。

**改分批执行后（115 类全覆盖）**：失败 **104 个** —— 即**有 20 个失败原先藏在那 23 个未执行的类里**。
这是本条最直接的代价：**不是「少跑一些测试」，而是「读数少了一部分且看不出来」**。

## 2. ⚠️ 为什么这是**判据**问题，不只是稳定性问题

未执行的 suite 在日志里**没有任何失败行**。任何「按失败集合统计」的判据都会把它们读成**通过**。

本批就踩了这个坑：首版结论写「未迁移面 **0 位移**」，而事实是那 23 个 suite 里包含：

- **迁移面内的 11 个**（`ValueSemanticsTests` · `TupleIndexTests` · `TupleNamedTests` · `TupleDestructureTests` · `TraitDefaultTests` · `StdlibTests` · `WeakRefTests` · `SymbolDisambiguationTests` · `TryExceptTests` · `StepBlockTests` · `StructTests`）
- **B 类（挂起/并发内部 API）的 2 个**（`SuspendRuntimeTests` · `StructuredConcurrencyTests`）
- **C 类（`runTests`）的 1 个**（`TestBlockTests`）

⇒ 「没跑」被读成「通过」。**判据必须在报告读数前先验证「suite 数 == 基线 suite 数」**——这条应以「读数前的前置检查」形式固化。

## 3. 机制（实测到候选级，未穷尽）

1. 那族 helper 的模式是：`dup2(pipe写端, 1)` → 跑程序 → 成功路径 `closeFile()` + `dup2` 恢复 → 读 pipe；
   **失败路径（`catch`）只 `dup2` 恢复 stdout 并 `close(originalStdout)`，不关 pipe 写端**。
2. 实测统计：`catch` 块中恢复 stdout 的共 **46 处**，其中 **43 处**未关 pipe 写端（分布在 **43 个文件**）。
3. **为何现在才暴露**：迁移前这些 helper 的失败路径几乎走不到（全量 `0 failures`，只有 3 个 skipped）；
   `P4-β` 之后一次性出现 **84 个失败** ⇒ 失败路径被大量走到。

⚠️ **未确认**：fd 上限**不是**原因（本机 `RLIMIT_NOFILE` 软上限 1048575，84 次泄漏远未触及）。
真正的 SIGPIPE 触发点（「谁在写一个读端已关的管道」）**尚未定位到行**；
`--filter` 子集跑（19 个失败 + 3 个 suite）**不崩** ⇒ 与**累积量**相关，支持「失败路径资源未清干净」的方向，
但需要一次专门的定位实验（例如在 helper 里断言 fd 表，或对单测做故障注入）。

## 4. 影响面

- **判据面（首要）**：任何全量回归读数都可能**不完整**，且**表面看不出**（无失败行）。
- **工程面**：并发相关测试（池/任务）在全量跑里处于「有时跑到、有时跑不到」的状态 ⇒ 它们的绿是偶然的。

## 5. 待裁的处置路线（三选一，**本单不预设**）

| 路线 | 内容 | 代价 |
|---|---|---|
| **A 修 helper** | 43 个文件的 `catch` 路径补 `pipe.fileHandleForWriting.closeFile()`；或把 helper 统一成 `defer` 恢复 | 43 文件机械改动；**不保证**解决（SIGPIPE 触发点未定位到行）|
| **B 忽略 SIGPIPE** | 测试进程 `signal(SIGPIPE, SIG_IGN)`（或 xctest 启动参数）| 一行，但**掩盖**而非修掉资源泄漏；且改的是测试基建的全局行为 |
| **C 分批跑（本批的临时处置）** | 把全量拆成若干 `--filter` 批，逐批执行后合并 | **不修任何东西**、判据立刻可信；但每次读数要跑 N 次，且**不能替代**根因修复 |

## 6. 本批的临时处置（记录，不是结论）

`P4-β` 的读数改由**分批执行**取得（按字母序把 115 个类切成 5 批，逐批 `--filter`，再合并失败集合），
并在交付记录里**标注取得方式**与「首版按整跑统计得出的『未迁面零位移』已作废」。

⚠️ 本条不改变本单的 Open 状态：**分批跑是判据的绕行，不是缺陷的修复**。

## 7. 相关

- 本批的交付记录（含红数与判据取得的完整说明）：`docs/issue-hir-p4-beta-migration-2026-09-16.md`
- 分批表的判据节（每批必跑三条）：`docs/issue-hir-p4-plan-2026-09-16.md` §4

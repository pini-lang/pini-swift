# Issue：HIR 引擎不支持目录/模块运行 —— P4 翻转后包运行全线失败

- 状态：**Open（2026-09-16 立案；P4 阻塞面勘测实测发现，只登记不修）**
- 发现渠道：**P4 阻塞面勘测**（在 `PINI_INTERP_ENGINE=hir` 下跑全量回归，与默认 AST 引擎下的
  结果对照）。这不是读代码读出来的，是**把引擎切过去跑一遍**跑出来的。
- 严重度：**中** —— 影响面见下方专节：**测试面 7 / 1269（0.55%），且全部落在 `ImportInjectionTests` 一个类**；用户面 = 目录/模块运行这一条路径。
  ⚠️ **2026-09-16 用户裁决下调**：本单首版写「高 · 包运行全线失败」，**定性过重** —— HIR 引擎本体是完整的，缺的只是 CLI 的**包运行入口**这一条路径。
- 归属：CLI 装配 + HIR 侧包运行入口，**不是**某个 HIR 节点的缺陷
- 定位：**P4 前置** —— 翻转后 HIR 成为默认引擎，本项即由「一个受限的可选通道」变为
  「**目录/模块运行不可用**」（⚠️ **范围限定**：仅此一条路径，单文件运行不受影响）

## 现象（实测，非估计）

`Sources/PiniCLI/main.swift` 在目录分支上显式拒绝：

```
// LR-4 P1-3：HIR 引擎当前只接单文件。不静默回落到 AST 引擎——那会让调用方
// 以为自己在看 HIR 通道的结果。
if engine == .hir {
    printError("Error: PINI_INTERP_ENGINE=hir 暂不支持目录/模块运行，当前仅支持单文件。")
    exit(1)
}
```

**HIR 引擎下的全量回归实测（2026-09-16，`1e05ad3`）**：

| 引擎 | 结果 |
|---|---|
| `ast`（默认） | 1269 / 3 skipped / **0 failures** + swift-testing 45 / 14 suites |
| `hir` | 1269 / 3 skipped / **7 failures** + swift-testing 45 / 14 suites |

7 个失败**全部**落在 `ImportInjectionTests`（4 个测试方法），断言失败形态两类：

1. 期望有输出、实际**空串** —— `XCTAssertEqual failed: ("") is not equal to ("[甲, 乙]")`
   （包被加载了但什么都没跑出来）；
2. 直接撞上那条拒绝 —— `XCTAssertTrue failed - 应报语义未定义，实际：Error:
   PINI_INTERP_ENGINE=hir 暂不支持目录/模块运行，当前仅支持单文件。`

## 影响面（实测，非估计）

| 面 | 实测 |
|---|---|
| 测试面 | **7 failures / 1269（0.55%）**，全部集中在 `ImportInjectionTests`（4 个方法）|
| 用户面 | `pini run <目录/模块>` 在 HIR 引擎下被拒；**单文件运行不受影响** |

⇒ **不是「HIR 引擎不完整」** —— 引擎本体在单文件面上是完整的，缺的是 CLI 的**包运行入口**。

## 为什么现有判据看不见它（本单最该记的部分）

这是**覆盖盲区**型假绿的又一例，且比既有几例更危险：

- **探针（`tools/hir-parity-probe.py`）看不见**：它只跑**单文件**夹具，遇到包成员一律落
  `PACKAGE_MEMBER`（**非阻塞槽**，当前 27 个）⇒ 探针的 `FLIP BLOCKERS` 判据对
  「HIR 根本不接包」**结构性失明**。
- **默认引擎下的全量回归也看不见**：`PINI_INTERP_ENGINE` 默认 `ast`，1269 全绿证明的是
  **AST 通道**的状态，与 P4 翻转后的世界无关。
- ⇒ **「探针 0 阻塞 + 全量回归全绿」这两个 P4 验收判据，在本项上都是绿的**，
  而 P4 一旦翻转就会全线转红。**判据绿不等于没有这个洞。**

**发现它的唯一姿势**：把 `PINI_INTERP_ENGINE=hir` 显式传进 `swift test` 跑一遍。
（本单主张：**这条应固化为 P4 开工前的固定勘测动作**，而不是靠谁想起来。）

## 与既有工单的关系（不重复登记）

| 工单 | 覆盖 | 与本单的关系 |
|---|---|---|
| `docs/spec/issue/archive/issue-hir-engine-abstraction-2026-09-13.md` | **执行入口抽象**（`run` 进协议、`DAPServer` 不持有具体类型） | **相邻但不同** —— 它管的是「换引擎时宿主装配要不要跟着改」（**改动面**），本单是「HIR 侧**根本没有**包运行入口」（**能力缺口**）。抽象完也仍需有人实现 HIR 侧的包运行。 |
| `docs/spec/issue/archive/issue-hir-node-source-position-2026-09-12.md` | HIR 节点无位置 | 无关（本项不涉及位置） |
| `docs/spec/issue/archive/issue-hir-builtin-callee-unowned-2026-09-14.md` | 内建 callee 解析 | 无关（不同的失败面） |

⇒ 本单**不并入** abstraction 单：那单的交付判据是「协议成形」，而协议成形后本洞仍在。

## 处置选项（待裁，本单不修）

| 选项 | 做什么 | 代价 |
|---|---|---|
| **A** | HIR 侧补齐包运行入口（`run(package:)` 等价物 + CLI 解除拒绝） | 需 lowering 整包、处理跨模块符号与注入；工作量中–大 |
| ~~**B**~~ | ~~P4 翻转时保留 CLI 层的 AST 回落~~ | **已排除（2026-09-16 用户裁决：「照裁决来」）** —— 与 `D-B3=A`（末态退役走查）直接冲突：保留回落等于给走查留一条命脉。**不再作为候选** |
| **C** | 缩小 P4 范围：先只翻单文件运行，包运行维持现状并**明示**不支持 | 用户可见能力回退，须走 spec 治理登记。⚠️ **2026-09-16：不排期，仅留作 A 的退路** —— 论证见 `docs/issue-hir-p4-plan-2026-09-16.md` §1（四条理由，核心 = 影响面 0.55% 不足以支撑一次能力回退；且 B 已排除 ⇒ A 是唯一选项）。**仅当 A 开工后实测发现它不止是装配层**（需改 lowering / 跨模块符号解析）才回来启用 |

## 归属与排期

本单的处置与排期**不在本单内** —— 见 `docs/issue-hir-p4-plan-2026-09-16.md`（P4 阻塞面分批计划）：本项 = **批次 P4-1**，判 D-P4-1 / D-P4-2 / D-P4-3。

## 待办（P4 开工前）

1. 裁决上表 A / B / C；
2. 无论取哪项，都**先把「HIR 引擎下跑全量回归」固化为 P4 的验收动作** ——
   否则下一个同类缺口（探针与默认引擎都看不见）仍会漏到翻转之后。

---

## 2026-09-17 状态更新（`A1` 批实测，本单结论须按此细化）

`A1` 批把**包通道**接进判据器械（见 `docs/hir-criteria-gap-ledger.md` §10），
顺带对本单做了一次现测。**三处要订正**：

1. **「CLI 显式拒绝」已不成立** —— 本单 §现象引的那段 `if engine == .hir { printError(…暂不支持目录/模块运行…) }`
   **实测已从 `Sources/PiniCLI/main.swift` 移除**（`grep` 零命中）。这是选项 **A** 的装配面交付
   （`P4-1a`：包运行入口）留下的结果。
2. **HIR 现在会真的进包通道，且部分成功** —— 8 个宿主模块实测：
   **3 个 `agreed`**（`examples/package-demo` · `examples/multifile` · `…/ModuleSystemTests/demo/app`，
   两臂 rc/stdout 逐项相同），**2 个 `diverged`**，**3 个两臂都拒**。
3. ⇒ **本单的标题级结论「HIR 不支持目录/模块运行」应读作「**模块级子缺口有三类**」**，
   而不是一条整体性拒绝：

| 子缺口 | 夹具 | 归谁 |
|---|---|---|
| 依赖模块的**命名空间**（两模块导出同名顶级符号 ⇒ 合并式降载保不住） | `…/demo3/app` | `docs/issue-hir-import-module-symbols-2026-09-16.md`（本单**不**认领） |
| **vendored FFI 符号**（`[ffi] libs`，dlsym 第二段） | `examples/ffi_module` | `docs/spec/issue/archive/issue-hir-vendored-ffi-unsupported-2026-09-17.md`（新立） |
| 依赖模块被当入口跑（无 `main`）时**报错码两臂不同**（`ast E5-007` vs `hir E6-004`） | `demo/helper` · `demo3/app/frontend` · `…/syntax` | 本单（属**错误通道口径**，与乙组 `D2` 同族；只登记） |

⚠️ **本单判据面的那句「发现它的唯一姿势 = 显式传 `PINI_INTERP_ENGINE=hir` 跑全量回归」需要补一条**：
全量回归**仍然看不见**上表前两类（它们的夹具在探针与回归里都是 `PACKAGE_MEMBER` / 不入根集）
—— 看见它们的是**包通道**这一条新边。⇒ 「把引擎切过去跑一遍」是**必要不充分**的勘测动作。


---

## `A2` 批补记（2026-09-17）：**`run-llvm` 侧归本单**，附可复制的复现

队列甲组 `A2` 的实测把「`run-llvm` 不接受目录」与「`rc=0` 掩盖」**分成两件事**，
并判定**前者归本单、后者归 `docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md`**。
本节按该判定把指针**补实**（此前台账 §9 与本单都只写「在册工单」，**没有指名**）。

### 事实（实测 2026-09-17，`291a4b3`）

```sh
export PINI_LLVM_BIN=/opt/homebrew/opt/llvm/bin

pini run-llvm examples/package-demo ; echo "rc=$?"
#   stderr: Error: The file “package-demo” couldn’t be opened.
#   rc=1     ← ⚠️ 显式失败，不是静默
pini run-llvm examples/multifile ; echo "rc=$?"
#   rc=1

pini run examples/package-demo ; echo "rc=$?"
#   stdout: 107
#   rc=0     ← 解释器侧包通道（P4-1a）走的是另一条实现，有完整目录分支
```

| 通道 | 目录输入 | rc | 性质 |
|---|---|:---:|---|
| `pini run <目录>` | ✅ 正常 | 0 | `runRunPath` 有目录分支（`P4-1a`） |
| `pini run-llvm <目录>` | ❌ 读不到 | **1** | `case "run-llvm"` 直接把参数当**文件**读（`main.swift:1729`），无目录分支 |

### 为什么归本单

本单主题 = **「包/目录运行这条入口缺能力」**。`run-llvm` 缺的正是同一件事的
**LLVM 通道版本**：解释器侧入口已由 `P4-1a` 补齐，LLVM 侧从未有过。

⚠️ **但它不是本单首节那种「判据看不见」的假绿** —— 它**显式 `rc=1`**，脚本与 CI 都看得见。
它的真实危害只有一条：**探针那 27 条 `PACKAGE_MEMBER` 在 `hir⇄llvm` 边上不可能被覆盖**
（见 `docs/hir-criteria-gap-ledger.md` §9/§10 与 `docs/issue-hir-blocker-queue-2026-09-17.md` §1-A1）
⇒ 这条边对包成员的**永久未测**，是本单的直接后果，不是探针的疏漏。

### 订正

本单与台账 §9、阻塞队列 §1.1 此前记的「`run-llvm <目录>` … **`rc=0`**」**是错的**：
现测 `rc=1`（两个二进制各三次连跑，读数逐项相同）。`rc=0` 那条读数属**另一条路径**
（lli 真跑起来之后 `terminationStatus` 被丢弃），已由上面那张单载明并订正。
**本批不替那次读错编解释**，只给出可复现的现测与符号级根因。

**本批不做**：不改 `Sources/PiniCLI/main.swift`（`run-llvm` 原样无目录分支）·
不新建单（两条缺陷同载体同 `case`，拆单会让「一处代码的两个不足」分家）· 不 push。

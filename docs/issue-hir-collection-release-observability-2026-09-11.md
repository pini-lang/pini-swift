# Issue：集合释放缺少「执行等价」判据能看见的钉子（HIR 零发射 + 唯一信号是 IR 文本断言）

- 状态：**Closed（2026-09-11 立案；同日裁决「先补实现再翻转」并由 H1-B 落地，
  见文末「裁决」「实现落点实测」「H1-B 落地」三节；2026-09-12 M6b 翻转批收口关单 ——
  释放实现已成为唯一发射路径，48 条 IR 契约断言在翻转后全部保持绿色）**
- 发现来源：M6c 判据升级过程中暴露的判据盲区（执行等价探针对集合释放**结构性失明**）
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（翻转批 b3 的删除范围）、
  `docs/issue-legacy-i64-print-sext-2026-09-07.md`（旧后端冻结先例）

## 现状（实测）

集合释放（`bk_array_destroy` / `bk_dict_destroy` / `bk_set_destroy`，以及
`bk_handle_retain` / `bk_*_ensure_unique_at`）的**唯一信号**是
`Tests/PiniTests/RuntimeBackendTests/RuntimeBackendTests.swift` 里的 IR 文本断言。

实测计数（2026-09-11）：含 `destroy` / `ensure_unique` / `handle_retain` 的断言
**24 条**，分布在 16 个测试函数，两类形态：

- **纯 IR 文本型**（名字含 `IRContract`）：`testNestedCOWIRContract`、
  `testCOWIRContract`、`testD423ReassignAndScopeCleanupIRContract`、
  `testD423NestedCollectionNotOverReleasedIRContract`、
  `testLoopBodyCollectionReleasesIRContract`、`testBreakCollectionReleasesIRContract`、
  `testContinueCollectionReleasesIRContract`、`testReturnCollectionReleasesIRContract`。
  断言直接统计 IR 文本里 `call void @bk_array_destroy` 的出现次数（精确到 1/2/3 次）。
- **混合型**（名字含 `AllThreeBackends`）：`testLoopBodyCollectionAllThreeBackends` 等，
  行为对比之外也带 IR 计数断言。

伴生缺口：**HIR 侧完全不发射集合释放**——`bk_*_destroy` 在 HIR 管线里零引用
（K3 / D9）。即翻转后这类程序在 LLVM 侧全程不回收。

## 为什么执行等价判据看不见它

释放与否**不改变 stdout**：漏释放是内存泄漏，过释放才可能崩。三通道执行等价探针
（`tools/hir-parity-probe.py`）比对的是输出，因此对整类缺口结构性失明——
与「`emit` 成功 ≠ 能跑对」是同一类判据粒度问题。

## 为什么本批不实施（止损）

把「IR 文本断言」换成「行为钉子」需要以下之一，二者都超出「语句·类型面」的格边界：

1. **运行时活句柄观测 API**。`PiniRuntime.swift` 内部已有活句柄登记
   （`_liveHandles`）与引用计数，但**未导出**。导出只读计数属运行时导出面新增
   （还要联动 AOT 静态链接的符号可见性回归测试）。
2. **HIR 测试驱动**。需要让 RuntimeBackendTests 能跑 HIR 管线并比对释放行为；
   该驱动即翻转批 b2-1 的产物，**已被 S-3 止损中止**（改动在分支的 stash 里）。

按 M6c 计划的止损点（「单格若需引入新 ABI 设施/超出语句·类型面 → 停手改登记为工单」），
本批停在立案。

## 风险（时点敏感）

翻转批 b3 会删除旧管线测试与这套 IR 文本断言。**在删除之前**若没有替代信号，
集合释放将彻底不可观测——HIR 零释放的缺口会静默进入翻转后世界。

## 建议处置（两步，均待裁决）

1. 导出只读观测原语（活句柄计数即可，最小面），并补 AOT 链接可见性钉子。
2. 把 `*IRContract` 的 destroy 计数断言改为行为断言：同一 fixture 跑完后活句柄
   计数归零；`*AllThreeBackends` 的 IR 部分同步替换。
   注意 HIR 当前归零会失败——这正是需要的信号，应在 b3 之前先决定
   「HIR 是否实现集合释放」，再决定断言取「必须归零」还是「已知豁免 + 计数上限」。

---

## 裁决（2026-09-11，M6b 翻转批复勘后）

上面「建议处置」第 2 步的前置问题已定：**HIR 实现集合释放**（不取豁免）。
即翻转前先补上释放路径，而不是让缺口带进翻转后世界。

## 实现落点实测（2026-09-11 补）

**HIR 侧现状**：`IREmitter` 全文按 `scopeDepth` / `scopeStack` / `declaredCollections` /
`abandoned` / `cleanup` / `destroy` 检索 —— **1 处命中，且是注释**。发射器**没有作用域栈**。
`HIRStmt` 亦**无块作用域节点**（无 block / scope / cleanup 形态）。

**旧后端参照（要在 HIR 侧重建的三件套）**：

- 登记：`registerLocalCollectionVar(name, slot, irType)` —— 仅当 `isCollectionHandleType(irType)`
  才登记；同层同名去重（否则出口双释放 → 过释放 → UAF）。
- 存储：`scopeStack: [[ScopeVar]]`，按作用域深度分层。
- 发射：`emitBlockCleanup(depth)`（块自然落入出口，释放本层反序）、
  `emitScopeCleanup()`（函数/闭包出口，遍历残留层）、
  `emitContainerDestroy(slot, irType)`（load 后调 `bk_*_destroy`）；
  重赋值路径在写新值前先释放旧句柄。

**发射路径数**：`StmtEmitter` 内 6 处块出口 + break/continue 放弃层循环 2 处 +
`return` 终止边 + `ModuleEmitter` / `ClosureEmitter` 函数出口 —— **≥5 个发射路径**，
超出「单项能力需改超过 3 个发射路径即转立案」的边界，故本项按立案—分格推进。

**运行时侧无需改动**：`bk_array_destroy` / `bk_dict_destroy` / `bk_set_destroy` /
`bk_lazyref_destroy` 实现齐全（`Sources/PiniRuntime/PiniRuntime.swift`）。缺的只是发射侧调用。

## 受影响契约的精确期望值（`RuntimeBackendTests`，实测）

| 用例 | 期望 `destroyCount` | 语义 |
|---|---|---|
| `testD423ReassignAndScopeCleanupIRContract` | 3 | 1 重赋值旧句柄 + 2 出口顶层 |
| `testD423NestedCollectionNotOverReleasedIRContract` | 2 | 顶层出口 + 嵌套块末（零 UAF） |
| `testLoopBodyCollectionReleasesIRContract` | 1 | `while_body` 块末，每轮执行一次 |
| `testBreakCollectionReleasesIRContract` | 2 | break 路径 + 非 break 路径各一次 |
| `testContinueCollectionReleasesIRContract` | 2 | continue 路径 + 非 continue 路径各一次 |
| `testReturnCollectionReleasesIRContract` | 1 | return 前释放顶层，且不发生双重释放 |
| `testForInNestedCollectionIRContract` | — | for-in 嵌套集合 |

另有区域归属断言（`exit_block` / `while_body` / `if_then` 内）与变异反证锚点
（禁用 break 清理必须使断言红灯）。

补充：`IRExecutionTests` 全文 `destroy` 引用数为 **0** —— 本缺口不影响该套件，
它挡的是 `RuntimeBackendTests`。

## 分格建议（估 3–4 格，超 4 格即回到豁免或最小可行）

1. 作用域栈 + `allocVar` 时登记（集合句柄类型判定）+ 函数出口清理
2. 块级清理（`ifStmt` / `whileStmt` / `forInStmt` 的 body 出口）
3. 终止边（`returnStmt` / `breakStmt` / `continueStmt`）
4. 重赋值旧句柄（`storeVar` / `subscriptStore`）

每格验收 = 对应契约逐条转绿，**且变异反证仍能红灯**（禁掉新写的清理路径，
断言必须失败）—— 否则是「断言无法区分修复前后」的假绿。

---

## H1-B 落地（2026-09-11）：HIR 侧集合释放

实现落在 `Sources/PiniCore/CodeGen/IREmitter.swift`（单文件）。设计上不新建机制，
而是复用既有 `pendingDefers` 的帧栈范式，把三件套压缩成「一个帧栈 + 五个挂点」。

| 件 | 旧后端 | HIR 落地 |
|---|---|---|
| 登记 | `registerLocalCollectionVar`（同层同名去重） | `registerReleasedHandle`（同帧同 slot 去重） |
| 存储 | `scopeStack` 分帧存 `ScopeVar` | `pendingReleases` 分帧存 `ReleasedHandle` |
| 发射 | `emitBlockCleanup` / `emitScopeCleanup` / `emitContainerDestroy` | `emitReleases(downTo:)` |

**挂点（五处）**

1. **帧栈挂进 `emitBlock`**。块边界就是帧边界——函数体 / `if` / `while` / `forIn` /
   `match` / `try` 的体全走 `emitBlock`，故句柄栈只需挂一处，不必触碰各个调用方。
2. **块末释放**。自然落入边释放本帧（`releaseBase > 0`）；循环体因此每轮释放一次。
   函数体的帧（`releaseBase == 0`）**不在块末释放**，留给函数出口——与旧后端
   「顶层作用域只由 `emitScopeCleanup` 处理」的形状一致。
3. **函数出口**。fall-through 的 `exit_block:` 内释放顶层帧；`return` 在 `ret` 之前
   发射自己的副本（两条运行时路径，各发射一份，互不重叠）。
4. **终止边**。`LoopFrame` 增 `releaseBase`（对应既有 `deferBase`），`break` / `continue`
   在跳转前释放被放弃的层。
5. **重赋值**。`storeVar` 在 store 之前释放该 slot 的旧句柄（运行时只递减，
   别名仍持有时旧句柄存活）。

`for … in` 的元素绑定在 `emitBlock` **之前**发射（`alloca` + `store`），故 `emitBlock`
增可选参数 `seedingReleases:`，把这些句柄并入循环体帧，否则它们会落到外层帧。

**判据取「HIR 与旧后端的 IR 计数逐条相等」而非「测试转绿」**：受影响契约
（`Tests/PiniTests/RuntimeBackendTests/RuntimeBackendTests.swift`）直接驱动旧后端
`IRGenerator`，HIR 落地不改变它们的颜色。真正有区分力的判据是两侧 IR 对齐，
外加三通道执行等价探针（`tools/hir-parity-probe.py`）负责抓过释放导致的崩溃。

**验收**

| 契约夹具 | 期望 destroy | 旧后端 | HIR |
|---|---|---|---|
| `testD423ReassignAndScopeCleanupIRContract` | 3 | 3 | 3 |
| `testD423NestedCollectionNotOverReleasedIRContract` | 2 | 2 | 2 |
| `testLoopBodyCollectionReleasesIRContract` | 1 | 1 | 1 |
| `testBreakCollectionReleasesIRContract` | 2 | 2 | 2 |
| `testContinueCollectionReleasesIRContract` | 2 | 2 | 2 |
| `testReturnCollectionReleasesIRContract` | 1 | 1 | 1 |
| `testForInNestedCollectionIRContract` | 1 | 1 | 1 |

区域归属另验 22 项（出口段只释顶层、嵌套块变量不在出口释、break 分支在跳出口前释、
`destroy` 位于 `ret` 之前等），两侧全过。

**变异反证**：M1 禁用整条 `emitReleases` → 7 例全红（Reassign 恰剩 1 处，走的是重赋值
路径）；M2 只禁用 `emitReassignRelease` → 仅 Reassign 红（3 → 2），其余 6 例不动。
判据具备逐路径区分力。

## 已知残留（同批登记，均为漏释放或与旧后端同源，不阻塞翻转）

1. **函数参数的集合句柄不登记**。旧后端在函数入口登记参数（`ModuleEmitter`），HIR 未登记
   → 有集合参数的函数少释放一份 share（漏释放，非过释放）。
2. **`match` 绑定不登记**。枚举 / Optional payload 绑定到集合句柄时不登记，同上。
3. **`return <集合值>` 未 retain**。两条路径都先释放作用域句柄再求值返回表达式，
   返回的句柄可能已被回收 —— 与旧后端同源，非本格引入。
4. **`for … in` 的 `step:` 块读已释放的元素绑定**。循环体块末释放 `row`，`step:` 复用
   同一 slot —— 与旧后端同源。
5. **无初始化器的集合声明**（`var x: [I32]`）。旧后端同样无条件登记，块末释放会读未初始化
   slot。HIR 与旧后端行为一致，非本格引入。

以上 1–2 是 HIR 侧相对旧后端的**新增缺口**（陈旧后端有、HIR 没有），3–5 是同源缺口。
1–2 的选择理由是「宁漏勿过」：漏释放只是泄漏，过释放是 use-after-free。

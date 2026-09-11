# Issue：HIR 侧嵌套下标写的 COW 独占化链仅数组单态（本批降级为显式拒绝）

- 状态：**Closed（2026-09-11 立案；同日 D 批 D1 格实现为真分派，见文末「D1 落地」节）**
- 发现来源：M6c 判据升级（执行等价探针替换只看 `emit` 成败的旧判据）暴露的 F4 族
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（M6c 收敛批）；
  `docs/llvm-capability-matrix.md`（迁移期已知限制节）

## 现象与实测

三种形态，同一根因：

| 夹具 | 形态 | HIR（改动前） |
|---|---|---|
| `Tests/PiniTests/RuntimeBackendTests/testNestedAliasCOWBothBackends.pini` | `d["a"][0] = 7`（dict 根） | **非法 IR**：lli 报 `'%t105' defined with type 'ptr' but expected 'i32'` |
| `Tests/PiniTests/RuntimeBackendTests/testNestedSubscriptWriteBothBackends.pini` | 同上 | 非法 IR（`'%t129'`） |
| `Tests/PiniTests/RuntimeBackendTests/testNestedCOWIRContract_2.pini` | 同上 | 非法 IR（`'%t21'`） |
| `Tests/PiniTests/RuntimeBackendTests/testNestedMixedContainerCOWBothBackends.pini` | `a[0]["k"] = 9`（dict 中间层）、`p["x"]["y"] = 5`（dict 根与中间层） | **静默别名污染**：`print(b)` 给 `[{k: 9}, {k: 2}]`，应为 `[{k: 1}, {k: 2}]`；`q` 同理 |

注意最后一例的严重性：它不是拒绝，而是**静默错**——写 `a` 改到了 `b`，值语义被破坏。

## 根因（符号级）

`Sources/PiniCore/CodeGen/IREmitter.swift` 的 `emitUniqueContainerHandle`：

- `.load(name, _)` 分支把容器**硬编码**为 `%bk_array*` 做 bitcast，返回类型也硬编码；
- `.subscriptGet(inner, index, _)` 分支只发射 `bk_array_ensure_unique_at`，
  **没有字典分支**，且不按子类型修正句柄类型；
- 文件头只声明 `bk_handle_ensure_unique` 与 `bk_array_ensure_unique_at`，
  缺 `bk_dict_ensure_unique_at`。

于是字典参与的链路上：字符串键（`ptr`）被送进 `bk_array_ensure_unique_at` 的 `i32` 形参
→ 非法 IR；或 `emitSubscriptStore` 的字典分支走 `emitExpr(container)` 取句柄、
**不做任何分裂** → 共享 box 被原地改写。

对照两侧：

- **运行时机制齐全**（不在 LLVM 层）：`Sources/PiniRuntime/PiniRuntime.swift` 的
  `bk_handle_ensure_unique` / `bk_array_ensure_unique_at` / `bk_dict_ensure_unique_at`
  三个入口均已存在且被旧后端验证过。
- **旧后端实现完整**：`Sources/PiniCore/CodeGen/Emitters/ExprEmitter.swift` 的同名函数
  按动态句柄类型分派（数组走数组入口、字典先装箱键再走字典入口），是可直接对照的参考实现。
- **仅新发射层的链是数组单态**。故本项不是「缺少机制」，而是**发射层少接了一半入口**。

## 本批处置（已落地，`agent/pini-dev/llvm-m6c-convergence`）

取「先降级为显式拒绝」：`Sources/PiniCore/HIR/HIRLowerer.swift` 在降级期判定
「嵌套写链路上出现字典」即抛 `E6-004`，**不再发射**会死在 lli 或静默污染的 IR。
拒绝措辞自述为 later grid，与该能力面的既有门控声明一致。

**判据边界（易错，务必保留）**：

- 只对**下标目标**（`container` 本身是 `Expression.subscript`）成立；
  **单层写不得拒绝**——`d0["k"] = 9`、`p[0] = row` 这类普通变量目标是平坦写路径，
  数组与字典两条 store 分支都会把分裂后的句柄写回变量槽，本就正确。
  首版判据曾因只看「容器类型是字典」而误伤 `examples/cow.pini` 与
  `Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/testDiffCow.pini`，已修正。
- **纯数组嵌套写（任意深度）不得拒绝**：`m[0][0] = v`、`t[0][1][0] = v`、
  `c[0][0] += v` 在 HIR 下均正确。

## 验收实测（18 个含嵌套下标的夹具全集）

| 项 | 结果 |
|---|---|
| 变化 | **4 例**，全部为预定目标：3 例非法 IR → `E6-004`，1 例静默污染 → `E6-004` |
| 不变 | **14 例**，含 `examples/cow.pini`、`examples/multidim.pini`、`examples/array-basic.pini`、`examples/collections.pini` 全部门槛分母语料 |
| 回归 | **1310 / 0 / 0** |

翻转阻塞计数不变（判据升级口径下仍为 7）：本项把「静默错 / 隐晦错」转成「显式错」，
不减少缺口，只是让缺口可见。

## 建议处置（未决，待排期）

1. **镜像旧后端分派**（推荐路径）：`emitUniqueContainerHandle` 按容器类型选
   `bk_array_ensure_unique_at` / `bk_dict_ensure_unique_at`（后者需键装箱与 tag），
   句柄类型按各层实际类型定型，并补 `declare`。参考实现在
   `Sources/PiniCore/CodeGen/Emitters/ExprEmitter.swift`，逐行对照即可；
   预计与已完成的语句发射类格同量级。
2. 若估工显示需触 >3 个发射路径或引入新 ABI 设施，按 ADR-031 §4 的 S-4 止损
   转为永久豁免并写明理由。
3. 无论实现或豁免，都需与解释器做逐字节对齐验证（嵌套字典、字典套数组、
   数组套字典、复合赋值路径），并补差分夹具。

**本轮不实现的理由**：C4 的裁决是「先把静默错转成显式错」，实现另立格；
且该能力面在计划中属语句 / 类型发射面之外，拉进收敛批会让本批失去可停的形状。

## D1 落地（2026-09-11）：发射层按容器类型分派

按建议处置 1（镜像旧后端分派）实现，未触 S-4 止损：**1 个文件 3 处**
（`Sources/PiniCore/CodeGen/IREmitter.swift`）。

1. **声明表补齐**：dict 家族补 `declare ptr @bk_dict_ensure_unique_at(ptr, ptr, i32, i32)`
   （legacy 在 `IRGenerator.swift` 已有同款）。
2. **独占化链按类型定型**：`emitUniqueContainerHandle` 的每层句柄改为按实际类型
   签发（数组 `%bk_array*` / 字典 `%bk_dict*`），字典层照抄 legacy 的键装箱三件套
   （`keyBox` alloca → store → `keyWidth` → `keyTag`）。
3. **字典写链接入同一条链**：`emitSubscriptStore` 的字典分支在目标是下标时先取
   独占句柄——这正是原文「静默别名污染」的来源。
4. **撤降级门控**：`HIRLowerer` 的判定与两个辅助函数（连同其两个调用点）整体移除。

### 验收实测

| 项 | 结果 |
|---|---|
| 目标 | 4 例全部 `GAP_EXEC` → **`OK`**（三通道 `rc=0/0/0`，输出逐字节一致） |
| 值语义 | `print(b)` 恢复 `[{k: 1}, {k: 2}]`（原为 `[{k: 9}, {k: 2}]` 静默污染）；`t[0][1][0]`、`p["x"]["y"]`、复合赋值 `c[0][0] += 5` 三条路径均正确、别名不受影响 |
| 影响面 | 8 个含嵌套下标写的夹具；探针三根 203 例比对中**仅这 4 例 verdict 变动**，其余 199 例零改动 |
| `examples/` | 78 例**零阻塞** |
| 回归 | **1310 / 0 / 0** |

原文「翻转阻塞计数不变」的表述随本次实现作废：这 4 例已计入 D 批清零（8 → 0）。

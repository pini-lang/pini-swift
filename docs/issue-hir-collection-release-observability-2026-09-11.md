# Issue：集合释放缺少「执行等价」判据能看见的钉子（HIR 零发射 + 唯一信号是 IR 文本断言）

- 状态：**Open（2026-09-11 立案；M6c 横切项 X3 触发止损点，未实施）**
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

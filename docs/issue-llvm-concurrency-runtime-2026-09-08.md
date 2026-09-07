# Issue：并发执行模型在 LLVM 后端缺席（`=>` / wait / await / Future）

- 状态：**Open（2026-09-08，M5 分格扩张批勘测中由 LR-11 裁决除名立案）**
- 发现渠道：M5 G2 勘测——并发语料 8 文件的 sweep 首层失败是 `sleep` 内建
  未注册，但修掉后暴露的是完整并发执行模型缺口：`=>` 进程声明（调用即派发
  worker 线程）、`wait`/`await` 阻塞 join 与挂起恢复、`Future` 句柄、ok/err
  结算、协作式取消。不是「注册两个内建」能覆盖的格。
- 裁决记录：LR-11 = **A（除名立案）**——并发不进 M5 分格序列，迁移完成
  （M6）后作为独立里程碑启动；启动前 LLVM 端并发语料维持 emit fail-loud。
- 范围输入（立项时展开）：解释器侧并发语义权威 = spec 并发章节 +
  `SuspendEvaluator` / `Scheduler`；HIR 侧需要并发语句/表达式节点集与
  线程化运行时（`PiniRuntime` 现为同步宿主库）。
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md` LR-11 / M5 批次回填。

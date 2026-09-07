# Issue：LLVM 后端重写——执行计划与 LR-* 决策登记（ADR-031 落地）

- 状态：**Open（2026-09-07 架构经用户确认，M0 待点名；本工单为 LLVM 重写的常驻计划载体，各批收口在此回填）**
- 关联：`docs/spec/adr/adr-031-llvm-backend-rewrite.md`（约束与判据权威）；`docs/issue-interpreter-hir-unification-2026-09-07.md`（LR-4 单独立案）

## 架构（用户确认版，2026-09-07）

```
Source → Lexer → Parser → AST → SemanticAnalyzer → TypeChecker
                                                      ├─→ Interpreter（AST 树解释，本次不动）
                                                      └─→ HIRLowerer（AST+类型信息 → HIR）
                                                              └─→ LLVM Emitters（HIR → IR 文本，纯机械）
                                                                      └─→ clang/lli → PiniRuntime
```

目录（沿 PiniCore 顶层按表示层命名的既有惯例）：

- **`Sources/PiniCore/HIR/`（新增顶层）**：`HIRNode`（类型化树节点，类型已解析）、
  `HIRModule`（模块/函数/内存布局与 vtable）、`HIRLowerer`（AST+类型信息 → HIR，
  全部类型决策/泛型单态化/捕获分析收敛/能力门单点）、`HIRPrinter`（调试 dump，可选）
- **`Sources/PiniCore/CodeGen/`（原址重建）**：`IREmitter`（新顶层入口，无 40+ 可变
  共享状态的 god class）、`Emit/` 分域发射器（纯机械降级）、`IRBuilder` /
  `IRGenError` / `LLVMToolchain`（保留复用）

依赖规则（S-2 机械核验）：

- `HIR/` 依赖 AST + Type + Semantic；不依赖 CodeGen
- `CodeGen/` 只依赖 HIR；目录内 grep `AST` 引用 / `PiniType` 判断分支 = 0
- `unsupported` 能力抛点全仓 = 1（HIRLowerer 内）；发射器内 = 0

## 决策记录（LR-* 编号，全仓唯一前缀）

| ID | 决策点 | 裁决（2026-09-07） |
|---|---|---|
| LR-1 | 门控硬化策略（约束 5 落地方式） | 折中：环境已配置但工具缺失/失配 → 显式失败并报原因；环境未配置 → 保留跳过但打印单行显式说明。用户裁决「按建议来」 |
| LR-2 | 新实现落点与命名 | `CodeGenV2/` 提案被用户驳回；定案 = `HIR/` 新顶层 + `CodeGen/` 原址重建（架构确认） |
| LR-3 | HIR 形态 | **类型化树**（HIR 节点带已解析类型，控制流保持树形，发射器遍历时自管标签/phi） |
| LR-4 | 解释器是否走 HIR | **本次否**——迁移中无法做到；单独立案
`docs/issue-interpreter-hir-unification-2026-09-07.md`，LLVM 迁移完成后解释器与 LLVM 后端共同依赖 HIR |
| LR-5 | 兼容开关 | **无任何 CLI 开关，直接替换**——已有解释器后端，项目未进 1.0.0 不考虑兼容；回退手段 = 提交边界 git revert（用户裁决） |
| LR-6 | M3 决策门：路线判定 | **重写**（用户裁决「按倾向来」，2026-09-07）。判定依据 = M2 能力清单：缺口成簇（8/19 并发内建单簇）、emit 通过者端到端 40/40、抛点持续增长 100→108、泛型等需全局类型视野的能力在 god class 结构下不可做；增量路线为 8 次外科手术 × 共享状态回归风险，重写为 1 次架构 + 8 次填格 |

## ADR-031 连带修订（随 M0 落地）

- 约束 1「CLI 后端开关切换、旧 CodeGen 切换前保持可构建」→「直接替换，无兼容开关；
  旧 CodeGen 在新管线差分绿前保持服务，冻结功能新增不变」
- S-4「新旧并存由 CLI 开关控制」→「回退由提交边界承担（git revert），无运行时开关」
- 约束 2/3/4/5/6/7/8 不变

## 里程碑（每批独立验收 + 证据登记；除 M3 分叉点外逐批等点名）

- **M0 文档与 ADR 修订批**（零代码）：ADR-031 上述两处就地修订；README 架构图加
  HIR 节点 + 目录结构节更新 + 特性表「LLVM 端 unsupported」改口径（按能力清单逐格
  消除）；`docs/BUILDING.md` 补门控环境判据（约束 6：完整登录 shell 实测、
  `source ~/.zshrc` 判据、工作树/自定义 scratch 测量无效）。验收：doc-links /
  comment-lint 全绿。
- **M1 门控硬化批**：按 LR-1 折中落地（约束 5）；验收 = 完整环境全量 0 skip 全绿。
- **M2 能力清单批**：`examples/` 语料（1010 个 `.pini`）批量实测
  `emit`/`compile`/`run-llvm` 通过率；129 处抛点分类核心必支持/可延后/永久不支持；
  try-else 发射归入核心格；产出 `docs/llvm-capability-matrix.md` + 分格顺序草案。
- **M3 决策门（分叉点，必须停）**：按 M2 数据判定增量 vs 重写，判定依据回填
  ADR-031 §6；带数据请用户确认路线。
- **M4 HIR 核心批**：`HIR/` 目录落地（LR-3 类型化树）+ 垂直切片——最小可执行子集
  差分绿（解释器 vs 新管线逐字节一致；IRExecutionTests 82 + RuntimeBackendTests 51
  为基线语料）。
- **M5 分格扩张批**：按能力矩阵逐格推进，每格一次提交 + 一次差分验证；单格失败不
  回滚已完成格。
- **M6 翻转批（一次性）**：删旧 CodeGen 9 文件 → CLI 接新管线 → `IRGeneratorTests`
  149 处 IR 文本断言同批删除（约束 8）→ README 终版更新。

止损判据：ADR-031 §4 原文四条（影子类型表 ≥7 张；单次回归 >5 测试且 >1 小时；单次
收敛扩散 >4 个 emitter；单项核心能力需改 >3 个 emitter）——任一触发即停并回 M3。

不做范围：PiniRuntime / `bk_*` 35 符号 ABI 改动；解释器行为变更（LR-4 已另立
工单）；spec 语言面改动；LR-4 统一改造（等 LLVM 迁移完成后另行立项）。

## 批次回填

- **M0 完成（2026-09-07）**：ADR-031 约束 1 / S-4 / §4 步骤 6 / §5 首条就地修订
  （LR-5 直接替换）；README 架构图加 HIR 节点 + 目录结构节加 `HIR/` +
  FFI 特性行「LLVM 端 unsupported」改「按能力清单逐格补齐」+ 双后端说明加重写
  指针；`docs/BUILDING.md` 补「LLVM 门控测试的环境判据」节（约束 6 落地：
  `source ~/.zshrc` 判据、自动化 PATH 无效、工作树/自定义 scratch 测量无效）。
  零代码改动。下一步 M1（LR-1 门控硬化）待点名。
- **M1 完成（2026-09-07）**：`Tests/PiniTests/CodeGen/LLVMGate.swift` 门控单点
  落地（LR-1 折中：环境已配置但工具/动态库缺失或失配 → 硬失败并报因；环境未配置
  → 保留 skip 且单行明示缘由与开启方式）；三文件 101 处静默 skip 点统一改走门控
  （IRExecutionTests 83 / RuntimeBackendTests 15 / IRPrintGoldenTests 2）。
  三象限实测：完整环境 1226/0/0 skip（全绿面不变）；假 `PINI_LLVM_BIN` + 剥 PATH
  → 51 中 37 硬失败（修复前为静默 skip——两次假「门关」的根因关闭）；剥 PATH
  未配置 → 37 skip 全部带单行说明。证据 E-137。下一步 M2（能力清单批）待点名。
- **M2 完成（2026-09-07）**：能力清单批落地。`tools/capability-sweep.sh`
  （可复跑）+ `tools/capability-sweep.tsv` + `docs/llvm-capability-matrix.md`。
  **两处勘误**：语料实为 59 个 `.pini`（非 1010，工单 M2 节原记数是早期勘察噪声）；
  fail-loud 抛点实为 108 处 `throw IRGenError`（非 129，旧数为未过滤 grep 噪声）。
  核心数据：emit 40/59（67.8%），emit 通过者 run-llvm **40/40 全通**；
  19 个 emit 失败聚成 9 簇（并发内建 8 / 跨文件 2 / foreign 2 / 数组方法 2 /
  泛型 1 / 对象方法 1 / try-else 1 / 可延后 2）；108 抛点分「特征门（能力缺口）」
  与「防御性错误路径（永久 fail-loud）」两性质；分格顺序草案 G1–G8 已定。
  数据交 M3 决策门，本批不做路线判断。下一步 M3（决策门，分叉点必须停）待点名。
- **M3 完成（2026-09-07，决策门通过）**：路线定案 **LR-6 = 重写**（用户裁决）。
  重写展开已向用户陈述并获倾向确认：HIR 四件（HIRNode 类型化树 / HIRModule
  内存布局与 vtable / HIRLowerer 唯一能力门 / HIRPrinter 调试 dump）+
  CodeGen 原址重建（IREmitter 无共享状态 + Emit/ 分域，IRBuilder /
  IRGenError / LLVMToolchain / PiniRuntime ABI 四块保留复用）。
  执行序 M4 垂直切片（最小子集差分绿，同时验证 LR-3 树形表达力）→
  M5 按 G1–G8 逐格（每格一次提交 + 一次 sweep 刷新）→ M6 一次性翻转
  （删旧 9 文件 5622 行 + 149 处 IR 文本断言同批删 + 文档终版）。
  止损判据沿用 ADR-031（影子表 ≥7 / 单次回归 >5 测试且 >1h /
  收敛扩散 >4 emitter），新增「新实现长影子表 = 决策未收拢，停」。
  下一步 M4（HIR 垂直切片批）待点名，开工前先出细化步骤。

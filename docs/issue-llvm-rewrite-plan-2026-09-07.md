# Issue：LLVM 后端重写——执行计划与 LR-* 决策登记（ADR-031 落地）

- 状态：**Open（常驻计划载体；M0–M4 与 M5 前置小批已完成并回填，活跃 Open 工单清零，下一步 M5 分格扩张批待点名——开工前先出细化步骤）**
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
| LR-7 | float 比较补齐形态 | **A 全量六分支**（用户裁决，2026-09-08）：解释器补 == != < <= > >= 六个 `(.float, .float, op)` 分支照 int 形态；混合 int/float 比较维持 checker 拒绝（E4-001），非解释器缺口 |
| LR-8 | print(F64) 展示语义 | **A 最短往返**（用户裁决，2026-09-08；A/B/%g 三方案调研后定）：spec 钉四条形态规则（§2.8 值展示语义），两后端委托宿主标准库 `String(Double)`；LLVM 侧经运行时 `bk_double_to_string`（只新增符号，bk_* 现有签名零改动）；%g 方案否决（指数阈值第三形态，工程量同 A 且语义不净） |
| LR-10 | 旧后端 i64 print sext 处置 | **wontfix**（用户裁决，2026-09-08）：旧后端冻结 + M6 整体删除自然消亡，新管线已 trunc 修正；工单关闭，M5 期间出现硬需求再翻案 |
| LR-11 | 并发语料（8 文件）在 M5 的处置 | **A 除名立案**（用户裁决「按建议来」，2026-09-08）：并发语料真身是 `=>`/wait/await/Future 真并发执行模型，非「注册两个内建」；立案 `docs/issue-llvm-concurrency-runtime-2026-09-08.md`，M6 后独立里程碑启动；M5 格序顺移（数组方法升 G2） |
| LR-12 | Result 的 IR ABI（G1） | **A 定长 tagged 三字聚合**（用户裁决「按建议来」，2026-09-08）：`{ i64 tag, <T> ok, i64 err }`；Pini 的 `^T` 书写面只钉 T 不钉 E（checker 实测 `err(42)` 放行）→ err 槽类型擦除为机器字（构造位加宽、try 位绑字）；ok/err 构造与解包全内联 IR，运行时零改动 |

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
- **M4 完成（2026-09-07，三批收口）**：
  - **批①**（`4e550ed`）：`HIR/` 四件落地（LR-3 类型化树）——`HIRNode`
    （类型化节点 + LoweredExpr{node, type} 包装统一携带决策）、`HIRModule`
    （单值返回布局）、`HIRLowerer`（AST+类型信息 → HIR，模块预签名 pre-pass
    支持前向调用，唯一能力门 unsupported 单点，elif 降嵌套 if）、`HIRPrinter`
    （调试 dump）。HIRLowererTests 6 用例绿，验证 LR-3 树形表达力
    （while+if 嵌套 / 跨函数预签名 / 能力门拒绝）。
  - **批②**（`429b649`）：`CodeGen/IREmitter.swift`（HIR→IR 文本，机械翻译
    零类型推导，每模块新实例与旧 IRGenerator 零共享状态）+ HIRDifferentialTests
    17 fixture（解释器 vs 新管线 stdout 逐字节一致，锁步 harness）。关键发射
    决策：块嵌套 slot 栈解析遮蔽、i64 print 用 trunc（旧后端 sext 为非法 IR）、
    字符串比较 strcmp、CJK hex-mangle。HIR 全套 23/23 绿。
  - **探针发现三件**（差分设计的直接产出，已立工单并排期，见下）：
    解释器无 float 比较分支（issue-interpreter-float-compare）、旧后端
    print(I64) 非法 sext（issue-legacy-i64-print-sext）、print(F64) 双后端
    格式分歧（issue-print-f64-format-parity）。
  - **批③**（本提交）：计划工单回填 + E-139 证据登记 + 全量回归零回归验证 +
    合 main。
  - **排期登记（避免跨会话遗失）**：
    - issue-interpreter-float-compare → **M5 首格（G1）开工前的前置小批**：
      解释器补六个 float 比较分支 + 单测，随即为差分套件补 float fixture；
      与 issue-print-f64-format-parity 的格式裁决联动（fixture 期望值取决于
      print(F64) 格式裁决结果）。
    - issue-print-f64-format-parity → **M5 G1 前需用户裁决** print(F64)
      语义格式（最短表示 vs 定点），属语言语义面；裁决后与上一条同批落地。
    - issue-legacy-i64-print-sext → **建议不修（wontfix）**：旧后端已冻结
      功能新增（ADR-031 约束 1），M6 翻转批将整体删除旧 CodeGen，新管线
      已用 trunc 修正；随 M6 自然消亡，待用户确认后关闭。
  下一步 M5（分格扩张批，G1 try-else 起）待点名；M5 开工前先处理上述前置小批。
- **M5 前置小批完成（2026-09-08，两批 + 三工单收口）**：
  - **批A（LR-7，`9497557`）**：`evaluateBinaryOp` 补六 float 比较分支
    （TDD 红→绿）；差分套件补 `testDiffFloatCompare`。
  - **批B（LR-8，本提交）**：spec §2.8「值展示语义」钉最短往返四条形态规则；
    PiniRuntime 新增 `bk_double_to_string`（委托 `String(Double)`，strdup +
    IR 侧 free 契约）；IREmitter F64 print 切 helper（`@fmt_double` 移除）；
    差分 harness 加 `--dlopen` 运行时加载；补 `testDiffFloatPrint` 边界
    fixture（1e15/1e16、1e-4/1e-5 阈值等），19/19 逐字节一致。
  - **工单收口**：float-compare Closed（LR-7）；print-f64-format-parity
    Closed（LR-8，旧后端 %f 遗留随 M6 消亡）；legacy-i64-print-sext
    Closed（LR-10 wontfix）。证据 E-140 / E-141。
  - 全量回归零回归后合 main。下一步 M5 分格扩张批（G1 try-else 起）待点名，
    开工前先出细化步骤。
- **M5 分格扩张批进行中（2026-09-08，细化步骤经用户批准；LR-11=除名立案 /
  LR-12=Result 内联 tagged ABI；每格一次提交 + 一次 sweep 刷新；两波合 main：
  波① G1–G3，波② G4–G7）**：
  - **G1 try-else（本提交）**：LR-12 Result ABI —— `HIRType.result(ok:)`
    （`^T` 注解映射；err 槽类型擦除为机器字）、`HIRExpr.resultConstruct`
    （ok/err 构造，err 载荷加宽 sext/zext/ptrtoint/bitcast→i64）、
    `HIRStmt.tryStmt`（tag 提取 + condbr 双臂；err 臂绑定类型擦除错误字、
    ok 臂按 T 精确载荷）；表达式位 try-else 降为 allocVar + tryStmt
    （okTarget）；`^e` 糖 ok 路径同型。差分 +3 fixture（22/22）。
    **探针发现 2 件**：①`^T` checker 对 E 不设约束（`err(42)` 放行）→
    err 槽只能类型擦除（LR-12 依据）；②handler 内 `return err` 解释器流出
    **裸错误载荷**（非 re-box，返回位类型洞）→ LLVM 管线非 void 位门控 +
    立案 `issue-try-else-raw-err-return-2026-09-08`。CLI 加迁移期选择点
    `PINI_HIR_PIPELINE=1`（M6 翻转时与旧管线一并消亡）；sweep 加 hir-emit
    通道（HIR 6/59：M4 切片 + try.pini）。并发除名立案
    `issue-llvm-concurrency-runtime-2026-09-08`（LR-11）。
  - **G2 勘测触发止损（2026-09-08，停待裁决）**：能力矩阵的格粒度按「旧后端
    缺口 delta」估格（G2 = get/slice 2 文件），但新管线从 M4 最小切片起步，
    每格语料需要的是**整个特性族的新建**而非 delta——实测：
    - array-basic（矩阵记「仅 get 缺口」）对新管线缺：数组字面量、下标读写、
      len、嵌套数组、`.get`→Optional、match some/none、break——**整个数组族
      + Optional + match + break**；
    - slice.pini（矩阵记「仅 slice 缺口」）另需：负索引、半开/开放切片、
      越界夹紧、数组/Optional 的 print 格式化（`[20, 30]` / `some(50)` /
      `none`）、字符串切片——旧后端 bk_array_* 之外还需新运行时符号。
    M2 矩阵的「8 文件并发 = 一格」同源于此估法（LR-11 已实证除名）。
    **G2–G7 全部按族重估**：G2 = 数组族（核心：字面量/下标/len/嵌套 + Optional
    + match + break；切片/格式化建议拆 G2b），G3 = 对象族（布局/方法/self），
    G4 = 泛型单态化族，G5 = foreign + clang 通道，G6 = 跨文件符号表，
    G7 = 零散。工程量每族 ≈ 数百行 + fixture，非「一格一提交日」粒度。
    处置建议：①按族重估后继续，sweep hir-emit 通道（现 6/59）为唯一进度
    度量；②M5 改为「按族推进、可分会话」的滚动批，完成一族合一次 main。
    待用户裁决后继续。

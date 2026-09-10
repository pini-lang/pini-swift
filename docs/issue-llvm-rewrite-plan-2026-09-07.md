# Issue：LLVM 后端重写——执行计划与 LR-* 决策登记（ADR-031 落地）

- 状态：**Open（常驻计划载体；M0–M4 与 M5 分格扩张批 G1–G15 全部完成并回填，
  差分 60/60、回归 1293/0/0、sweep hir-emit 51/59——剩余 8 行全为并发族豁免
  （独立立案 issue-llvm-concurrency-runtime-2026-09-08），M6 flip 门槛达成，
  待点名执行旧后端删除与迁移开关退役）**
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
- **M6a 准备批（零删除，可停）**：按双分母补齐缺口——G16 元组族 / G17 内建与类型
  修补 / G18 trait self 与空数组，加三项横切（`programBase` 烘焙、诊断面接
  `DiagnosticProviding` ＋ `fopen` 判空、口径重扫）。验收 = 双分母全绿且真 flip
  阻塞清零。
- **M6b 翻转批（一次性）**：迁移 LLVM 驱动测试套（补 typecheck 对齐 CLI）→ 删旧
  CodeGen 9 文件 → CLI 去 `PINI_HIR_PIPELINE` 门恒走新管线 → `IRGeneratorTests`
  149 处 IR 文本断言同批删除（约束 8）→ README 终版更新。
  顺序硬约束：**迁移测试必须先于删源码**。

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
  - **G2 数组族完成（2026-09-08，用户裁决 A=按族滚动后执行）**：三批 +
    收口，分支 `agent/pini-dev/llvm-m5-g2-array`：
    - **批1 读路径**（3bc6c08）：`HIRType.array(element:)`（`%bk_array*`
      句柄拼写）、`arrayLiteral/subscriptGet/lenCall` 降载（同构性检查；
      checker 不推断集合字面量 → 无注解变量「降值取型」兜底，契约同旧
      codegen 侧推断）；发射经 `bk_array_create/get/len` + 逐元素装箱
      `bk_array_set`（tag 与旧 `bkTagForLLVMType` 逐值对齐，运行时零改动）。
    - **批2 写路径 + COW**（a7a8a19）：`subscriptStore`（嵌套写自顶向下
      ensure-unique 链：根 `bk_handle_ensure_unique` → 逐层
      `bk_array_ensure_unique_at`，顺序为运行时硬约束）+ 复合赋值读改写
      （语句位 binary op 钩子）+ 别名位 retain 四处（所有权契约 ③）+
      分裂句柄写回持有槽。无注解变量取型推广为「推断失败即降值取型」。
      门控边界测试翻转：数组入列、字典字面量成为新记录边界。
    - **批3 Optional + match + break**（97b40f7）：`optional(wrapped:)`
      tagged 聚合 `{ i64, T }`（some=0/none=1；none=语言级 nil，用户裁决
      D-G2-1）；`arr.get(i)` = `bk_array_len` 边界内联分支 + 栈槽汇流
      （无 phi）；`matchStmt` 通用 case 骨架（caseName + 单位置绑定，
      Optional scrutinee 先接线，enum 后续族复用同节点；未命中 panic =
      matchNotExhaustive 对齐）；break 指向最近 while，无循环裸 break 降
      `bk_panic`（探针实证解释器顶层报错 → fail-loud 对齐，非静默 skip）；
      `bk_panic` 调用位补 `unreachable`（noreturn call 非 terminator）。
    - **验收**：差分 +3 fixture（25/25）；全量回归 1257/0/0；端到端锚点
      `examples/array-basic.pini` 双管线逐字节一致；sweep hir-emit
      **6/59 → 8/59**（array-basic、step 进列）。array-basic 头注 %f 差异
      说明已更新（LR-8 收敛态）。G2b（切片/格式化）与 enum match 留后续族。
  - **G2b 切片与值格式化族完成（2026-09-08，分支
    `agent/pini-dev/llvm-m5-g2b-slice-format`）**：单批落地（8c09b78）+ 收口。
    - **值格式化**：print(array) 经运行时 `bk_array_len/get` 循环递归渲染
      `[e1, e2]`（字符串裸排、", " 分隔、bool/F64 按「值展示语义」注），
      栈槽 induction 无 phi；print(optional) tag 分支 `some(payload)`/`none`。
    - **none 字面量**：切片糖开放边界脱糖为 `Optional.none` 成员表达式 →
      降为 `optionalConstruct(isSome: false, ...)`（镜像 resultConstruct）。
    - **负索引**：下标读与 `.get` 经 select 链尾部计数（G48 语义）。**本批
      修复批3 潜伏缺口**：负 `.get` 原本通过 slt 边界检查、会在
      `bk_array_get` 内 panic（与解释器 some(尾计数) 分叉）——勘测探针发现，
      同批修复并记入差分。
    - **String 通道**：`s.get(i)` → `Optional<String>`、`s[i]` 裸字符
      （panic 通道）、`s.slice` —— 内联 strlen 扫描 + 字节拷贝（**字节
      语义 = 既有 len(string) ASCII 局限**，多字节字符与解释器 Character
      计数分叉，工单级已知项非静默）。
    - **切片**：数组建新句柄 + 内联拷贝循环（嵌套句柄元素 retain 一份，
      所有权契约 3）；字符串拷贝进动态 alloca 缓冲 + NUL 终止；边界钳制
      [0, len]、hi < lo → 空值——与 StdlibPini 下沉实现逐语义对齐，
      运行时零改动。
    - **验收**：差分 +2 fixture（27/27）；全量回归 1260/0/0；sweep
      hir-emit **8/59 → 9/59**（slice.pini 进列）；slice.pini 头注
      some(50) 过时行就地修正（实测 50，负下标走 panic 通道）。
      裸空数组字面量 `print([])` 维持门控（元素类型不可解析，登记边界）。
  - **G3 名义类型族完成（2026-09-08，分支
    `agent/pini-dev/llvm-m5-g2b-slice-format` 续批 12b45ec）**：struct 值布局
    + object 引用 + 方法/self。
    - **类型注册表**：模块预-pass 收集 structDecl/objectDecl；方法块
      `((T))`/`{{T}}` 在解析层是 extensionDecl（数据与逻辑分离），
      预-pass 将 extension 方法合并进注册表后降载。
    - **HIR 形态**：`HIRType.nominal(name:isObject:)`（`%struct.X*` 栈承载
      / `%object.X*` 含 i32 refcount 头、字段偏移 +1，镜像 legacy ABI）；
      `HIRModule.types`（HIRTypeDecl：字段含降载默认值 + 方法 HIRFunction）；
      `construct` / `fieldGet` / `fieldStore` 节点。
    - **方法**：降为 self 参数化的普通函数，IR 名 `方法__类型`
      （双下划线分隔不与 mangle 输出冲突）；`self` 首参（.selfKeyword 降
      load）；成员调用把接收者作隐式首参。
    - **构造**：`名()` 忽略实参（legacy createInstance 对齐），字段取声明
      默认值（zeroConst 镜像），object 写 refcount=1；ARC 不递减
      （v0.x 与 legacy 同界，已记录）。
    - **sqrt**：F64 libc 内接（struct.pini 语料依赖），头声明无条件发射。
    - **记录边界**：struct 赋值为指针别名（legacy ABI 同构，与解释器值拷贝
      语义的分叉未被语料触达）；print(名义值) 维持门控（格式化后续族）。
    - **验收**：差分 +2 fixture（29/29）；全量回归 1262/0/0；sweep
      hir-emit **9/59 → 11/59**（object.pini、struct.pini 进列）。
      mangle 提升为共享 IRName（双管线单源）。
  - **规划补全批（2026-09-08，纯规划不动源码，分支
    `agent/pini-dev/llvm-m5-plan-backfill`）**：对现存 48 个 hir-emit FAIL
    文件逐文件取证 gate 错误（一次性探针测试，用后即删；CLI 诊断丢失缺陷
    另立 `issue-hir-cli-diagnostic-loss-2026-09-08.md`），归簇后重排剩余
    格序。**stop-loss 时的 G4–G7 命名粒度不足以覆盖语料**：枚举、闭包、
    字典/集合、Optional 直写、tuple、字符串深化、struct 深化等簇无格可归。
    重排后剩余格序（格号沿用至 M6）：
    - **G4 枚举族**（enum / enum-named / enum-namespacing / enum-dot-case /
      match ×5）：enum 声明注册 + tagged union ABI（legacy `%enum.X =
      { i32, payload... }` 镜像）+ match 通用骨架接 enum scrutinee + enum
      类型注解映射。match 骨架为 G2 预留接口，接线即用。
    - **G5 字典/集合族**（collections / dict-set-d2 / cow ×3）：
      `bk_dict_*` / `bk_set_*` 运行时 ABI 现成，构造/下标读写同 G2 打法；
      cow 的 COW 语义经既有 ensure_unique 通道。
    - **G6 闭包/高阶族**（closures / lambda / lambda-typed / higher-order
      ×4）：函数类型参数注解 + lambda 字面量降载 + 捕获环境（legacy
      ClosureEmitter 381 行可镜像）。
    - **G7 Optional 直写族**（optional / optional-sugar ×2）：
      `.some(v)` / `Optional.none` 裸名构造 + `?T` 注解糖映射。
    - **G8 元组返回**（tuple ×1）：定长聚合返回 ABI（LR-12 tagged 模式
      同族扩展，`{ T1, T2 }`）。
    - **G9 字符串深化**（stdlib / defer / lexical ×3）：字符串方法链
      （upper 等）+ 字符串插值 print 路径。
    - **G10 泛型单态化族**（generic / generic-func / lazyref ×3）：
      构造点单态化（legacy genericTemplates 模式镜像）。
    - **G11 struct 深化族**（composition / access / multidim ×3）：
      组合类型方法名分派（R1.1 composedMethodSuffix 镜像）+ 访问控制
      语义 + 多维数组（enum-match 通用化后自然解锁）。
    - **G12 trait 族**（trait / validated-match ×2）：trait 默认实现
      分派（legacy tryTraitMethodDispatch 镜像）；依赖 G4 枚举。
    - **G13 跨文件族**（multifile ×2 + package-demo ×4，原 G6）：
      import/export 符号表入 HIR（`unknown function 向量` gate）。
      模块成员文件无 main 的 FAIL 与 legacy SKIP 同义，不计门槛。
    - **G14 foreign/FFI 族**（ffi ×2，原 G5）：foreign 声明块 + U64 等
      无符号类型映射（gate：`return type 'U64'`）+ clang 通道。
    - **G15 控制流与内建零散**（for / control-while / compound-assign /
      io / test ×5，原 G7 拆实）：for-in、continue、位运算符族
      （bitwiseAnd 等）、print 多实参、assert 内建。
    - **依赖序建议**：G4 → G5 → G7 → G8 → G9 → G6 → G10 → G11 → G12 →
      G13 → G14 → G15（小格前置杠杆后置；并发 ×8 不占格，独立里程碑）。
    - **M6 flip 门槛建议（待裁决）**：G4–G15 全绿（hir-emit = 51/59，
      模块成员文件 6 个按 legacy SKIP 同义豁免）+ 并发豁免清单，方可执行
      旧后端删除。门槛此前为空定义，本批补全。
  - **G7 Optional 直写族完成（2026-09-08，先于依赖序点名执行，分支
    `agent/pini-dev/llvm-m5-g7-optional-direct`，7543a84）**：
    - `HIRType(from:)` 映射 `Optional<T>` 泛型注解——`?T` 糖在解析层归一
      为同一形态，一处映射双覆盖。
    - `Optional.some(v)` 降为 `optionalConstruct(isSome: true)`，载荷在
      有注解上下文时采用包裹类型（宽度对齐）；`Optional.none` / `nil`
      字面量已在 G2b/G3 就位。
    - `case nil:` 在降载位归一为 `case none:`（D-G2-1：none 即 nil）。
    - **验收**：差分 +1 fixture（30/30）；全量回归 1263/0/0；sweep
      hir-emit **11/59 → 13/59**（optional ×2 进列）。
  - **G4 枚举族完成（2026-09-08，分支
    `agent/pini-dev/llvm-m5-g4-enum`，24b1a9a）**：tagged union 镜像
    legacy ABI（`%enum.X* = { i32 tag, max-arity 案载荷类型 }`，按值槽存）。
    - 注解解析增用户类型表（struct/object/enum，穿透函数/方法/字段/变量）。
    - 构造：裸零载荷标识符（plus）、位置调用 圆(2.0)、具名标签调用
      identifier(text= x)、限定 形状.圆(...)（类型名接收者）、dot-case
      .圆(...) / .none，跨枚举同名经 checker BareCaseResolutionRegistry
      静态决议（E-131 对齐）。
    - match：通用骨架增枚举路径（i32 tag 分派、GEP+load 载荷，Optional
      走 extractvalue 双路），具名/_ 绑定、通配末臂、未知 tag panic；
      print(枚举值) 运行期 tag 分派渲染 caseName(p1, p2)。
      hir-emit **13/59 → 19/59**（枚举 ×5 + 连带解锁 1）；枚举五语料
      双管线逐字节一致（CLI 实测）。
  - **G5 字典/集合族完成（2026-09-08，分支
    `agent/pini-dev/llvm-m5-g5-dict-set`，e6cdd15）**：
    - `HIRType.dict(key:value:)` / `.set(element:)` / `.tuple(labels:
      fieldTypes:)`（collections 语料所需的最小带标签元组切片：构造
      insertvalue + 标签读 extractvalue；完整元组返回/解构仍归 G8）。
    - 字典/集合字面量经 `bk_dict_create/set`、`bk_set_create/add` 构造
      （元素按各自 tag 装箱、句柄线程化）；字典下标读/写经
      `bk_dict_get/set`（缺键 panic，G48 三通道对齐）；len 扩展到
      dict/set/string（内联 strlen，字节语义 = 既有 ASCII 局限）。
    - **两个语义修复（连带 legacy 缺陷）**：①别名点 retain 扩展到
      dict/set 句柄 + 嵌套容器下标读——`var row = g[0]` 后父容器仍持有
      内层句柄，下次写必须分裂（legacy 漏此 retain，正是 legacy 过不了
      cow.pini 的原因之一）；②字符串元素 tag 从 handle(4) 改 raw-ptr(3)
      ——不可变 C 串无 share count，handle tag 使 dict cowCopy 对只读
      常量字节做 retain（dict 别名分裂时 segv）。
    - **验收**：差分 +3 fixture（35/35，cow/collections/dict-set-d2 语料
      直用）；全量回归 1268/0/0；sweep hir-emit **19/59 → 22/59**
      （collections / cow / dict-set-d2 / validated-match 进列）；门控
      边界再翻：lambda 为下一记录边界（G6 闭包族）。

  - **G8 元组返回 + G9 字符串深化完成（2026-09-08，分支
    `agent/pini-dev/llvm-m5-g8-tuple-return`，68ade52，两格同批）**：
    - G8：`HIRType(from:)` 映射元组注解（`((I32, I32,),)` 尾逗号语料
      形态覆盖，标签递归）；函数返回定长聚合；print(tuple) 渲染
      `[v1, v2]` / `[label: v]`（探针钉定：无标签方括号、有标签
      `label: ` 前缀，与解释器 stringify 逐字节对齐）。
    - G9 stdlib：upper/lower（memcpy + toupper/tolower 循环）、contains
      （strstr）、substring（memcpy 外拷）、**split 两遍 strtok（先计数
      后填充，产真 `Array<String>`**——legacy 走格式化字符串捷径，与解
      释器类型语义分叉，新管线取解释器通道）、join；abs/min/max I32
      select、sin/cos llvm 内接、tan = sin/cos（legacy 对齐）。
    - G9 defer：`deferStmt` 在块作用域正常结束位 LIFO 执行（循环体每
      轮末尾含内）；break/return 与 defer 交互语料未触达，不设门控面。
    - G9 lexical：插值各部件经值展示管线写入栈缓冲（F64 走
      bk_double_to_string 最短往返——**修复 legacy 在此路径的 %f 分叉**
      ；数组部件递归渲染）；`s1 + s2` 串接接通（malloc 拼接，defer 语
      料增量建串依赖）。
    - **验收**：差分 39/39（+4：tuple/stdlib/defer/lexical）；全量回归
      **1272/0/0**；sweep hir-emit **22/59 → 26/59**。

  - **G10 泛型单态化族完成（2026-09-08，分支
    `agent/pini-dev/llvm-m5-g10-generics`，泛型 struct + 泛型函数，lazyref
    跨格豁免）**：
    - **预扫描单态化**：模块级预-pass 收集泛型 struct/函数模板，
      `precollectGenericUses` 全模块扫 `.genericConstruct` 使用点，按
      「模板名 + `_` + 类型实参名拼接」注册特化（`盒<I32>` → `盒_I32`，
      镜像 legacy GenericsEmitter mangling；幂等去重）。
    - **struct 特化**：字段类型替换 + `((盒<T>))` 扩展方法重特化（实测
      钉定：parser 对 `((盒<T>))` 产出 targetType=`盒`（剥 `<T>`），
      特化匹配按 `specializedName.hasPrefix("\(ext.targetType)_")` 反向
      判定——首版按 `ext.targetType == specialized.name` 正向匹配全空，
      差分测试拦住）。
    - **函数特化**：`身份<T>` → `身份_I32` 参数/返回注解替换；特化体经
      `lowerGenericFuncCall` 在 `.genericConstruct` 表达式位分发（实测
      钉定：parser 对 `身份<I32>(x = 100)` 产出**独立** genericConstruct
      节点实参内含，非 `.call` 包裹 callee——首版分派位写错，编译器与
      差分双通道拦截）。
    - **发射接线**：泛型模板跳过签名预扫描/函数发射/typeDecl 发射；
      特化 struct 补发 typeDecl（字段 + 重特化方法，IR 名
      `方法__盒_I32`）；`FunctionContext` 增 `genericFuncTemplates`
      供调用点分发。
    - **lazyref.pini 跨格豁免**：`LazyRef<T>(闭包)` 依赖闭包 fat
      pointer（G6 能力），本格不实现，维持 hir-emit FAIL（E-149 登记
      豁免理由）。
    - **验收**：差分 41/41（+2：generic/generic-func 语料直用）；全量
      回归 **1274/0/0**；sweep hir-emit **26/59 → 28/59**。

  - **G6 闭包/高阶族完成（2026-09-09，分支
    `agent/pini-dev/llvm-m5-g6-closures`，closures / lambda /
    lambda-typed / higher-order ×4）**：
    - **HIR 节点**：`HIRType.function(params:returnType:)`（fat pointer
      `{ ptr, ptr }` ABI spelling）；`HIRExpr.closureLiteral`（id +
      paramNames/paramTypes + captures + body）、`.functionValue`（具名
      函数作为值）、`.indirectCall`；`HIRStmt.captureMarker`（`capture`
      语句降为标记，捕获集在字面量创建点解析）。
    - **降载**：`HIRType(from:)` 映射函数类型注解；模块预扫
      `precollectClosureIds` 按「行:列」分配稳定闭包 id（legacy 注册表
      契约）；`lowerFuncLiteral` 创建点自由变量分析（体引用 − 参数 −
      本块声明 − 顶层函数名），按引用捕获（env 字段 = 被捕获变量存储槽
      指针，与解释器 currentEnv 共享语义一致）；闭包体在独立
      FunctionContext 降载（参数/捕获预播种，外层变量不渗入）。
    - **调用点分派**：函数类型变量 callee `f(x)` → indirectCall（签名
      比对实参）；内联字面量直接调用同通道；值位具名函数 →
      functionValue。
    - **发射**：创建点 malloc env + 逐捕获 GEP/store 槽指针 +
      insertvalue fat pointer；闭包 define 缓冲至模块末尾拼接
      （`@__closure_N(ptr %env, args...)`，env GEP 取回槽指针注册为
      局部符号）；具名函数作为值走 env 忽略适配器
      `@__adapter_<mangled>`（#8 语义：直接传 code 会实参错位）；间接
      调用恒按闭包 ABI extractvalue code/env。**勘测钉定**：env 结构
      类型声明必须进模块头——创建点 GEP 在 main 体内先于尾部声明，
      lli 报 `base element of getelementptr must be sized`（首版放尾部
      被差分拦住）。
    - **lazyref.pini 维持豁免**：`LazyRef<T>(...)` 是泛型构造但模板未
      在语料内声明（实测：`unknown generic 'LazyRef'`），依赖跨文件/
      内建泛型（G13 域），G6 解除不了该格（E-149 豁免理由更新）。
    - **测试维护**：`testGateRejectsLambda` 边界断言过期（lambda 已进
      slice），改为正向 `testLambdaLowersToClosureLiteral`（闭包字面量
      形态断言）。
    - **验收**：差分 **45/45**（+4：四语料直用）；全量回归
      **1278/0/0**；sweep hir-emit **28/59 → 32/59**（closures /
      lambda / lambda-typed / higher-order 进列）。
  - **G11 struct 深化族完成（2026-09-09，分支
    `agent/pini-dev/llvm-m5-g11-struct-deepening`，composition / access
    / multidim ×3）**：
    - **i8 标量进 slice**：`HIRType.i8` 新 case（llvmSpelling `i8`、
      isNumeric）；`HIRType(from:)` .simple 增 `I8` 映射；字段/方法
      返回/字段读全通道可用，算术发射拓宽至 i32（与解释器语义对齐）。
    - **composition 展平**：模块预扫后 `flattenComposedNominals` 对齐
      解释器 `mergeComposedType`（子前父后、同名子覆盖、visited 防
      环）；`NominalInfo.decl` 改 var、增 `composedParent` 与
      `replacing(fields:methods:)`；typeDecls 循环的 fields 与
      methods 均从展平后 registry 取（首版只换 methods → emitter
      `unknown nominal field`，差分拦住）；合并方法存回
      extensionMethods，mangling 保持子侧 `方法__子类型`。
    - **unsafe 恒等降载**：`lowerExpr` 增 `.unsafe` 恒等透传。
    - **死臂 match parity**：match 非 Optional/enum scrutinee → 死臂
      （发射不派发）；`lowerMatch` default 分支 `lowerDeadArmBody`
      按「绑定类型 = scrutinee 类型本身」注册绑定（外层绑 row =
      array(i32)、内层绑 v = i32，scrutinee 即绑定值非 element）；emitter
      `emitMatch` default 由 fatalError 改 `emitExpr(scrutinee)` 后跳
      过全部臂。**勘测钉定**：解释器裸下标读返回裸值
      （`print(m[1])` → row），match some/none 静默不命中——语料头宣
      称的「下标读返回 Optional」语义解释器也未实现，宿主级语义缺口
      立工单（不在本格修）。
    - **验收**：差分 **45→48**（+3：三语料直用）；全量回归
      **1281/0/0**；sweep hir-emit **32/59 → 35/59**（composition /
      access / multidim 进列；multidim legacy FAIL E6-002 属既有）。

  - **G12 trait 族完成（2026-09-09，分支
    `agent/pini-dev/llvm-m5-g12-trait-validated-match`，trait /
    validated-match ×2）**：
    - **TraitRegistry 预扫**：`lower()` G12 pre-pass 收集 traitDecl →
      traits 字典、struct/object 带 traits → typeTraits 字典，组装
      `HIRLowerer.TraitRegistry`；traitDecl 签名预扫进 signatures 表
      （`traitSignatureInfo` 剥首 self 参数，供后声明函数解析）。
    - **默认体特化收集**：`TraitDefaultCollector`（class，跨嵌套
      FunctionContext 传播，seen 去重）；主循环 traitDecl 放行
      （default 体不在声明点发射）；模块组装前
      `functions.append(contentsOf:)` 注入。
    - **dispatch fallback**：`lowerMemberCall` own/ext method 未命中
      → 按 typeTraits 顺序找 trait 的 `signatures.first(where: { 名
      == memberName && body != nil })` → `lowerTraitDefaultCall` 剥
      self 首参、`resolveAnnotationType` 解析类型（支持 user
      types）、`lowerMethod` 特化为 `方法__类型` IR 名、返回
      `.call(function: irName, [receiver] + args, ...)`。
    - **裸字段注入（bindInstanceFields parity）**：lowerMethod 中
      selfType 为 nominal 时从 nominalTypes 取字段表进
      `context.selfFieldTypes`（+ selfTypeNameLowered /
      selfIsObjectLowered）；identifier case variableTypes miss 后
      fallback → `.fieldGet(base: .load("self"), ...)`，解释器方法
      体裸字段名可直接读的语义在 HIR 对齐。
    - **勘测钉定**：解释器 member 分派序 typeFields → typeMethods
      （own+ext）→ typeTraits 默认体；trait sig 首参 `("self", nil)`
      与 ext method `params=[] modifiers=["self"]` 两种 self 形态；
      legacy `tryTraitMethodDispatch` 剥 self 首参挂
      receiverIRType 进 pendingSpecializations。**run-llvm 与解释器
      已知语义分歧**：纯 default 场景 legacy trait 方法名 mangle 无
      接收者特化（两类型撞同名函数，猫调狗的覆盖版）；HIR 通道按接
      收者类型特化 `方法__类型`，行为与解释器一致，属修正而非回归。
    - **验收**：差分 **48→50**（+2：trait / validated-match）；全量
      回归 **1283/0/0**（基线 1281 + 新增 2）；sweep hir-emit
      **35/59 → 36/59**（trait 进列；validated-match 本为 PASS）。

  - **G13 批 1（lazyref）完成（2026-09-09，分支
    `agent/pini-dev/llvm-m5-g13-crossfile-lazyref`，跨文件族的
    LazyRef 先行小格）**：
    - **HIR 三件套新增**：`HIRType.lazyRef(element:)`
      （`%bk_lazyref*`）；`lazyRefConstruct(closure:type:)` /
      `lazyRefValue(handle:type:)` 两 HIRExpr case。
    - **降载分派**：`HIRType(from:)` 注解映射收 `LazyRef<T>`；
      `.genericConstruct` case **模板分派前**特判 `typeName ==
      "LazyRef"`（内建优先，用户同名模板不可遮蔽——legacy
      builtin-first 契约对齐）；`.member` 与 `lowerMemberCall`
      双入口收 `.value`（字段形态 + 零参调用形态）。
    - **发射**：`usesLazyRef` flag 条件头声明（不触碰无 LazyRef
      模块的 golden IR）；`@__lazyref_wrapper_<T>` 按元素 IR 拼写
      去重缓冲（统一 ptr ABI，运行时分配输出 box——wrapper 内
      alloca 逃逸 UB 由 runtime 侧规避）；元素 bytes/tag 表对齐
      legacy `lazyRefElemInfo`（**string 用 raw-ptr tag 4**，非
      array 族 share-counted tag 3——常量字节无 share count）。
    - **勘测钉定**：`LazyRef<I32>(闭包)` 解析为
      `.genericConstruct(typeName:"LazyRef", ...)`（非 .call 包裹）；
      闭包 id 由 precollectClosureIds 经 genericConstruct 实参遍历
      预注册（G6 链路复用，无需新预扫）。
    - **验收**：差分 **50→51**（+1：testDiffLazyRef，once 缓存 +
      复制共享语义 parity）；全量回归 **1284/0/0**；sweep hir-emit
      **36/59 → 37/59**（lazyref.pini 进列，G6/G10 期跨格豁免解除）。
    - **G13 批 2（跨文件大头）完成（2026-09-09，分支
      `agent/pini-dev/llvm-m5-g13-crossfile-package`）**：
    - **HIRLowerer.lower(package:)（D1）**：全包 declarations 合并为
      虚拟模块，跑既有单模块 pre-pass 链——trait/nominal/enum 注册表、
      签名表、闭包预收集、单态化全部免费升级为全局预扫；跨文件引用
      与同文件前向引用同路解析。可见性不重复 enforce（D4，checker
      package context 已 enforce）。
    - **closureId 键修正**：键从 `行:列` 扩为 `文件:行:列`——合并包内
      两文件可有同行列字面量，旧键会合并二者的捕获（legacy
      ClosureEmitter 契约的文件分量在单文件世界是隐式的）。
    - **effective return type**：void 声明但体中带值 return 的函数/
      方法，在定义侧、签名表、调用点三处统一升级为返回值类型——
      解释器运行时真把值流出去（package-demo 语料活文档明载「void，
      返回值运行时照常返回」），LLVM ABI 需静态单返回类型。
    - **CLI emit 自动切换（D2）**：`PINI_HIR_PIPELINE=1` 下文件属于
      清单模块即走 package 管线；裸文件维持单文件行为；模块根经
      locateModuleRoot 向上解析（嵌套 `_` 目录 helpers.pini 因此进道）。
    - **进程内 Package 差分驱动（D3）**：HIRDifferentialTests 增
      loadPackageCorpus（FileLoader.loadDirectory 同款入口）+
      runPackageInterpreter/runPackageNewPipeline 双通道；语料直引
      examples/multifile 与 examples/package-demo（零 fixture 副本）。
    - **验收**：差分 **51→53**（+2：testDiffPackageMultiFile /
      testDiffPackageDemo）；全量回归 **1286/0/0**（基线 1284 + 新增 2）；
      sweep hir-emit **37/59 → 44/59**（跨文件 7 行全 PASS）。
    - **G14 foreign/FFI 族完成（2026-09-09 落地，2026-09-10 回填；分支
      `agent/pini-dev/llvm-m5-g14-ffi`，合并 b08ceb4 / 提交 ea9c5b2）**：
    - **HIR 表达式面（S3c）**：新增 `pointerLoad` / `pointerStore` /
      `addressOfVar` 三 case。load/store **以指针的元素类型重降载值实参**
      （无注解字面量采纳该类型）；store 在值已声明时保留值自身类型，
      编码为**截断**（解释器 parity）。
    - **`&x` 语义（D-B 裁决，真指针）**：降为变量的 alloca 地址。解释器
      的**快照别名缺口**（写回不回写原变量）为已记录分歧，语料限定只读
      路径（`ffi.pini` 只读指针）。
    - **发射（S3d）**：有类型 load 把 i8 经 `sext` 加宽到 i64（对齐解释器
      统一整数表示）；store 按值的 IR 类型截断。
    - **print 多实参（D-A=A1）**：逐实参 stringify、空格分隔、末尾单个
      换行——`examples/io.pini` 三行形态与解释器逐字节一致。
    - **foreign 块**：按声明的外部签名发 `declare`；libc 已预声明符号
      （printf/malloc/free/strlen/memcpy）跳过；Pini 专有 `cstr` 垫片映射
      到新运行时导出 `bk_cstr`（与解释器垫片 strdup parity）。
    - **`assert(cond, msg?)` 最小降载**：使 `|test` 块可编译；false 边打印
      后 `bk_panic`。harness 不执行 `|test` 块（不参与差分基线）。
    - **Harness（D-C=C1）**：package 管线把 foreign 的 search-path 库作为
      额外 `--dlopen` 传入，镜像解释器 FFILoader；`examples/ffi_module` 的
      cstring 语料因此可跑。
    - **改动面**：IREmitter +144 / HIRLowerer +206 / HIRModule +35 /
      HIRNode +49 / HIRPrinter +12 / PiniRuntime +14 /
      HIRDifferentialTests +69。
    - **验收**：差分 **53→55**（+2：ffi.pini、ffi_module/cstring.pini
      双管线逐字节一致）；全量回归 **1288/0/0**；sweep hir-emit
      **44/59 → 47/59**（+3：ffi / ffi_module/cstring / test）。**该批
      当次未刷新 capability-sweep.tsv**，47/59 由矩阵历史比对复原
      （见 G15 回填的归因表）。
    - **G15 控制流与内建零散完成（2026-09-10；分支
      `agent/pini-dev/llvm-m5-g15-control-flow`，红灯基线 bee4a2f）**：
    - **for-in**：新增 `HIRStmt.forInStmt(pattern:elementTypes:kind:iterable:body:step:)`
      + `HIRForIterableKind`。iterable 的 HIR 类型决定容器种类与逐字段
      元素类型（array/set = 1 字段、dict = 2 字段 `(k, v)`）；模式元组字段
      数与元素字段数**严格相等**（`_` 占位计入 arity——解释器
      `decomposePatternRow` 契约）。发射镜像 legacy `generateForStatement`：
      bitcast → len → 隐藏 i32 索引槽 → cond/body/step/inc/exit，按 kind 选
      accessor（`bk_array_get` / `bk_set_at` / `bk_dict_key_at|val_at`），
      每轮 fresh slot 重绑模式变量。
    - **step 块（while + for-in）**：`whileStmt` 加 `step:` 关联值，发射
      cond/body/step/step.end/end 布局，body 回边指向 step；`break` 跳过
      step，`continue` 触发 step。**模式变量在 for-in 的 step 中仍可见**
      （解释器以 `currentEnv = loopEnv` 执行 step）——首版给 step 开新作用域
      致 `examples/for.pini` 撞 `load of undeclared variable` 硬崩，差分
      fixture 补钉后修复。
    - **continue / 标签 break·continue（ADR-014）**：`loopLabels: [String?]`
      栈（innermost last）+ `resolveLoopDepth` 把标签解析为展开深度；
      `breakStmt`/`continueStmt` 由裸形态改为携带 `depth: Int`，发射侧用
      `LoopFrame(exit:header:continueTarget:)` 栈按 `count-depth` 取目标。
    - **不可解析目标恢复 fail-loud**：循环外裸 break / 无匹配标签的 break
      降为新增的 `HIRStmt.panicStmt(message:)`（`bk_panic` + `unreachable`），
      而非降载期硬报错——解释器只让信号逃逸到顶层报错，硬报错会拒掉解释器
      接受的程度（实测：该做法曾使 `testDiffArrayGetMatch` /
      `testDiffMultidimArray` 两个既有 fixture 红）。
    - **位运算符族与复合赋值**：`HIRBinaryOp` 补
      `bitwiseAnd/bitwiseOr/bitwiseXor/leftShift/rightShift`；`init?(compound:)`
      补 `andAssign/orAssign/xorAssign/leftShiftAssign/rightShiftAssign`；
      发射侧指令选择 `and`/`or`/`xor`/`shl`/`ashr`。
    - **文件 IO 内建**：新增 `fileWrite(path:content:)` / `fileRead(path:)`
      两 HIRExpr case；发射 fopen/fwrite/fclose 与 fopen/fread(64 KiB 栈缓冲)/
      NUL 终止/fclose。`usesFileIO` flag 条件声明 + 模式串常量（不触碰无 IO
      模块的 golden IR）。`readFile` 返回值拼写必须是 `i8*` 而非 `ptr`——
      `emitScalarPrint` 只把 `i8*` 当 C 串，`ptr` 落进 `%d` 默认分支把地址
      当整数打印（首版实测输出 `1832249304`）。
    - **诊断透出**：`HIRLoweringError` 加 `LocalizedError` + `errorDescription`，
      CLI 侧由 `HIRLoweringError error 1` 变为带 `行:列` 与细节文本——本格
      五个语料死点因此可定位。
    - **发现并顺带修复**：`examples/step.pini` 在旧矩阵里 hir-emit 标 PASS 是
      **假绿**——capability-sweep 只测「发射是否成功」，而 HIR 管道**静默丢弃
      step 块**。本格实现 step 后该行 PASS 由假转真（计数不变，语义变化），
      并以 `testDiffStep` 差分 fixture 钉住（含 for-in step 引用模式变量、
      break 跳过 step 两个判别性形态）。
    - **验收**：差分 **55→60**（+5：testDiffForIn / testDiffContinueBreakLabel /
      testDiffBitwiseCompound / testDiffIoFile / testDiffStep）；全量回归
      **1293/0/0**（基线 1288 + 新增 5）；sweep hir-emit **47/59 → 51/59**。
    - **归因表（G14+G15 共 +7 行，由 `capability-sweep.tsv` 历史比对复原）**：
      G13 收口 44/59 → G14 +3（ffi、ffi_module/cstring、test）→ G15 +4
      （for、control-while、compound-assign、io）。剩余 8 行全为并发族
      （`concurrency*`），属 `docs/issue-llvm-concurrency-runtime-2026-09-08.md`
      的 M6 豁免清单，不占格。
    - **新立工单**：`docs/issue-bitwise-or-parse-2026-09-10.md`——单竖线 `|`
      位或表达式无解析通道，且 **spec 自身矛盾**（`bitwise-expr` 产生式含
      `'|'`、§A.4 规则 3.13 称回退为按位或表达式，但记号转换表无 `'|'` 行、
      同节记事句称「仅经 `|=` 去糖」）。语言级欠定义，需 spec §1.3 决策
      （补通道 A / 收敛规范 B），**未决策前不动源码**。
    - **下一格**：M5 分格 G1–G15 全部完成（51/59，剩 8 行并发豁免）——
      M6 flip 门槛达成，待点名执行旧后端删除与 `PINI_HIR_PIPELINE` 开关退役。
      另有两条独立立案线未启动：解释器统一 HIR（`docs/issue-interpreter-hir-unification-2026-09-07.md`）、
      并发运行时（`docs/issue-llvm-concurrency-runtime-2026-09-08.md`）。

- **M6 前置勘测完成（2026-09-10，仅勘测与规划，零代码改动）**：

  - **口径修正（本批最重要的结论）**：M6 flip 门槛原定义的分母是 `examples/` 59 个
    文件，但翻转要删的 `IRGenerator` **同时是 4 个测试套的驱动**（`IRGeneratorTests`
    / `IRExecutionTests` / `RuntimeBackendTests` / `IRPrintGoldenTests`，共 222 个
    用例、149 处 IR 文本断言、128 个夹具）。这批夹具**不在那条分母里**——门槛达标
    不等于翻转安全。故门槛改**双分母**：`examples/` 59 + LLVM 驱动测试套夹具 128。
  - **实测缺口（判据：legacy emit 通过 且 HIR emit 失败）**：
    `IRExecutionTests` 13 个 + `RuntimeBackendTests` 1 个 = **14 个真 flip 阻塞**；
    另有 5 个在 CLI 口径下**两条管线都失败**（前端/checker 本就拒绝，非后端缺口）。
    整个 `Tests/` 目录 965 个 `.pini` 中 HIR 不通过 434 个，其中 325 个属此类低价值项
    ——口径按「该夹具是否由 LLVM 后端驱动」收窄，不做全量覆盖。
  - **14 夹具收敛为 3 格**（按同一 `HIRLowerer` 落点聚簇，非按测试套分）：
    - **G16 元组族（7）**：多槽返回（2）／`.0` 位置索引（1）／解构声明（1）／
      `len(tuple)`（1）／无标签元组构造（2）。
    - **G17 内建与类型修补（5）**：`readLine`／`is_ascii_digit`／i8 struct 字段写／
      无注解参数回退 I32（2）。`is_letter` 保持 fail-loud（Unicode 语义，非缺口）。
    - **G18 trait self 与空数组（2）**：trait 默认方法 `self` 类型解析／
      `let a = []` 元素类型推导。
  - **横切三项**：`programBase` 烘焙补入 HIR；`HIRLoweringError` 接
    `DiagnosticProviding`（复用 E6 码面）＋ `fopen` 判空；口径重扫。
  - **新增探针** `tools/m6-triage-probe.sh`（与 `capability-sweep.sh` 并列）：
    两遍扫描——① 全部 `Tests/**.pini` 的 HIR 发射；② 按 legacy 通道把失败分为
    「真 flip 阻塞」与「前端本就拒绝」。产出 `/tmp/hir-fixture-sweep.tsv`
    与 `/tmp/m6-blockers.tsv`。
  - **决策（D1–D7，用户 2026-09-10 裁决「按你的倾向来」）**：
    - **D1** 门槛口径 = 双分母（见上）。
    - **D2** 测试判据统一 = 迁移时补 typecheck（对齐 CLI）。现状
      `IRExecutionTests.runViaLLI` 默认 `typeCheck: false`（81 例仅 2 例显式开），
      而 HIR 的类型决策单点要求 checker 先行——故 18/1 是上界估计。
    - **D3a** COW 的 IR 文本契约改行为断言（差分），不移植文本断言。
    - **D3b** `IRPrintGoldenTests`：翻转动工时先读 2 例断言内容再定。
    - **D4** `programBase` 烘焙补入 HIR（**必做**）。现状 HIR 侧缺失，
      `readFile("data.txt")` 在 CWD≠脚本目录时 **lli 段错误**，而解释器与 legacy
      均正常（legacy 经 `BuiltinsEmitter.generateIOPathArgument` 编译期烘焙）。
      旧后端运行期基准语义只覆盖字面量路径，非字面量路径的运行期基准为**已知限制**，
      不在本批闭环。
    - **D5** `HIRLoweringError` 实现 `DiagnosticProviding` 复用 E6-001…E6-005 码面
      ——翻转会静默退役 5 个已登记错误码，接续比退役代价低。
    - **D6** HIR 侧 `fopen` 返回 NULL 判空转 `bk_panic`（限一行级，不展开为完整
      IO 错误模型）。
    - **D7** 多槽返回 `-> (I32, I32,)` 与单槽元组 `-> ((I32, I32,),)` 是**不同构造**：
      G8 只覆盖后者（`examples/tuple.pini` 形态），前者在 HIR 侧门控
      （`decl.returnTypes.count <= 1`）。`examples/` 59 文件**零使用**多槽返回，
      故该缺口在原门槛里完全不可见。裁决 = **补齐（A）带止损**：若实测需改动
      >3 个发射路径（触 ADR-031 §4 的 S-4）立即转立案。
  - **M6 拆两批**：**M6a 准备批**（零删除、可停：3 格 + 3 横切）→ 点名 →
    **M6b 翻转批**（8 步一次性：迁移测试 → 删测试 → 删 9 文件 → CLI 去 env 门
    → 文档终版 → 冒烟 → 证据 → 合 main）。顺序硬约束：**b2 迁移测试必须先于
    b4 删源码**，否则迁移与删除同时失败时无法定位。
  - **顺带发现的既知不一致**（登记不改）：`examples/tuple.pini` 的注释宣称
    `.0`／`.名称`／解构 `var (a, b) =` 已支持，但该文件只演示整体元组，而
    `.0` 与解构在 HIR 侧均被门控——该行的 hir-emit PASS 高估实际能力
    （性质同 G15 的 step 假绿）。

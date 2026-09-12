# Issue：解释器统一 HIR —— P2（分格实现）执行规划

- 状态：**P2a 进行中 —— 第 1 格（G4 集合与下标的，7 节点）已交付并合入 main**；
  **下一格 = P2a 第二格（G2 元组），待点名**。规划轮（2026-09-13 早些时候）**只读勘测 + 落盘规划，
  未改任何源码**；G4 的交付实录见 §8.1，其范围订正见 `D-P2-5`。
- 隶属：`docs/issue-interpreter-hir-plan-2026-09-12.md` 的 **P2**（常驻主计划载体；
  本件是 P2 一格的细目载体，参照 P0 审计件与 P1-5 勘测件的先例另立）。
- 前置：**P1 ✅ 六步全部完成**（2026-09-13 收口）—— 三实通道探针、契约核验脚本、HIR 引擎骨架、
  引擎开关、调试面协议均已就位。
- 关联：`docs/spec/hir-contract.md`（**语义权威清单**，本件的族边界与验收锚点）；
  `docs/spec/adr/adr-034-hir-contract.md`（判准与 A/B/C/D/E 组裁决）；
  `docs/issue-hir-string-slice-byte-based-2026-09-11.md`（B 组字符语义）；
  `docs/issue-io-limit-from-emitter-2026-09-12.md`（A1/A2 上限）；
  `docs/issue-diagnostic-channel-parity-2026-09-12.md`（`GAP_HIR_ENGINE` 过宽，路由 P3）

## 0. 主决策（用户裁决，2026-09-13）

| # | 决策点 | 裁决 |
|---|---|---|
| **D-P2-1** | 含分歧面的四格（G4 的 `len`/`slice` 字符串侧、G7、G8、G9）怎么排 | **后置为 P2b**（与既有登记一致：IO 语义格 / `stringSplit` 格已裁排期，B 组已登记，取址 A/D1 已裁） |
| **D-P2-2** | 分格的族边界以哪套为准 | **以契约 §2/§3 的分节为准**（契约是语义权威，`ADR-034 D1`） |
| **D-P2-3** | P2a 第一格 | **G4 集合与下标的容器侧**（`arrayLiteral` 独占 10 夹具，杠杆最大；容器侧无分歧） |

## 1. 事实基础（2026-09-13 实测，可复现）

| 项 | 实测值 | 取法 |
|---|---|---|
| 缺口面 | **44 个**（35 expr + 9 stmt） | `Sources/PiniCore/Interpreter/HIRExecutor.swift` 的具名 fail-loud 分支 |
| 探针基准（73 夹具） | `OK 23` / `HIR_ENGINE_TODO 50` / **`FLIP BLOCKERS 0`** / 进程零残留 | `tools/hir-parity-probe.py --root Tests/PiniTests/CodeGen/HIRTests` |
| 首缺口节点 | **20 个** | 同上（按节点聚合输出） |
| 首缺口 top3 | `arrayLiteral` 10 · `construct` 9 · `tupleConstruct` 8 | 同上 |
| 遮蔽面 | 其余 **24 个缺口从未作为首缺口出现** | 同上 |
| 全量测试基线 | XCTest **1235 / 3 skipped / 0 failures** + swift-testing **45** | 见主计划载体 §13 |
| HIR 引擎规模 | 491 行 / 15 节点实现 / 44 缺口具名 fail-loud | `HIRExecutor.swift` |

### 1.1 分族（族边界 = 契约分节，共九格 / 44 缺口）

| 格 | 契约锚点 | 缺口节点 | 数 | 分歧面 |
|---|---|---|---|---|
| **G1 控制流** | §3.5/8/11/12/13 | `forInStmt` `deferStmt` `breakStmt` `continueStmt` `panicStmt` | 5 | 无 |
| **G2 元组** | §2.24/25 | `tupleConstruct` `tupleIndexGet` | 2 | 无 |
| **G3 闭包与函数值** | §2.11/12/13 | `closureLiteral` `functionValue` `indirectCall` | 3 | 无 |
| **G4 集合与下标** | §2.18–23 + §3.10 | `arrayLiteral` `dictLiteral` `setLiteral` `subscriptGet` `subscriptStore` `lenCall` `sliceCall` | 7 | **`lenCall`/`sliceCall` 的 `String` 侧**（B 组） |
| **G5 具名类型与字段** | §2.26/28 + §3.15 | `construct` `fieldGet` `fieldStore` | 3 | 无 |
| **G6 枚举 · Optional · Result · try** | §2.15/16/17/27 + §3.9/14 | `resultConstruct` `optionalConstruct` `optionalGet` `enumConstruct` `tryStmt` `matchStmt` | 6 | 无 |
| **G7 字符串与内建** | §2.9 + §2.14/35–42 | `stringCase` `stringContains` `stringSubstring` `stringSplit` `arrayJoin` `stringConcat` `interpString` `isAsciiDigit` `printMulti` `assertCall` | 10 | **B 组 4 项 + A 组 1 项（`split`）** |
| **G8 指针与 LazyRef** | §2.7/2.10 | `pointerLoad` `pointerStore` `addressOfVar` `lazyRefConstruct` `lazyRefValue` | 5 | **`addressOfVar`（A/D1）** |
| **G9 IO** | §2.8 | `fileWrite` `fileRead` `readLine` | 3 | **A 组 3 项全部** |

> 契约把**元组**归「集合」（§2.5）、把 **IO** 与 **LazyRef** 各自独立成节（§2.8 / §2.10）；
> 主计划 §7 手写的九格曾把元组归「函数与调用」、IO 并入字符串格。**本件以契约为准**（D-P2-2）。

### 1.2 语料面（夹具）

- 差分夹具 **73 个**，位于 `Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/`。
- **首缺口分布 ≠ 夹具覆盖**：探针只报「最先撞上的那个缺口」，被它遮住的节点有夹具却不出现。
  ⇒ **每格开工第一步用 `--filter` 实测该格夹具面，不得拿上一格的清单做加减。**
- **多特性夹具**：`testDiffStdlib.pini` 一个夹具含 6 个节点（`upper`/`lower`/`contains`/
  `substring`/`split`/`join`）⇒ 转绿无法归因 ⇒ **格内需先做夹具最小化**（P1-4 已有此教训与做法）。
- **零覆盖面**：指针/取址在差分夹具中**零覆盖**（唯一先例见 `examples/ffi.pini`、`examples/multidim.pini`）
  ⇒ G8 需从零写夹具，且须先确认表层语法（守手则 §3 铁律：从既有语料抄，不凭记忆写）。
- **不可验证项**：`assertCall` 契约明载「仅 `|test` 块使用，差分夹具从不执行」⇒ 无差分路径，
  判据只能走**单元级**（手写单个 HIR 节点直接驱动引擎，同 P1-2 的缺口探针做法）。

## 2. 关键结构性发现（决定本格的判据与排期）

### 2.1 P2 的进度判据是三态，不是两态

探针 `classify` 的末尾三行（`tools/hir-parity-probe.py`）：

```
h_out == a_out  →  CHANGE_*      （不计入 FLIP BLOCKERS）
l_out == a_out  →  GAP_BEHAVIOR  （阻塞）
否则             →  GAP_UNKNOWN   （阻塞）
```

⇒ **同一份契约语义，写成 AST 侧行为落非阻塞槽、写成 LLVM 侧行为可能落阻塞槽**。
这不是判据偏心：`interp-ast` 是**冻结参照**，与它一致 = 「无行为变更」；
与它不一致且 LLVM 也不同 = 「三方分歧、无法归因」。

### 2.2 分歧面分两类，处置完全不同（排期的分水岭）

| 类 | 契约要求哪一侧改 | HIR 若按契约实现 | 含义 |
|---|---|---|---|
| **B 组**（`len` `slice` `stringCase` `stringContains` `stringSubstring`） | **LLVM 侧**（解释器已合契约） | 落 `CHANGE_*` | **不阻塞，但也不转 `OK`** ⇒ 该格验收判据须写成 `CHANGE_*` |
| **A 组 + 取址**（`fileWrite` `fileRead` `readLine` `stringSplit` `addressOfVar`） | **解释器** | **落 `GAP_UNKNOWN` = FLIP BLOCKER** | ⇒ **必须先把两侧裁齐再做 HIR**，不能靠「照规范写」绕过 |
| `arrayJoin` | 待裁（P1-4 实测未复现偏离） | —— | B 组正式应为 **5 项** |

⇒ **P2b 的前置 = 先裁齐两侧**（IO 语义格 / `stringSplit` 格 / 字符串字节语义格 / 取址格）。
它们**均有既有登记**，不需新裁决：IO 与 `stringSplit` 由 P0b 停损 6 拆项并已排期；
B 组载于 `docs/issue-hir-string-slice-byte-based-2026-09-11.md`；取址由契约 §6 记为 A/D1。

### 2.3 「P2 = 九格」需订正为「九格 + 一格已由 P1-2 覆盖」

主计划 §7 的 P2 行首项是「① 标量与算术」。**实测该族 0 缺口**（P1-2 已实现标量常量、
`load`/`binary`/`unary`/`call`/`printCall`），只余 `minOf`/`maxOf`/`abs` 的**算子映射遗留**
（AST 通道是内建调用、HIR 侧是算子，见 `HIRExecutor.operatorFor` 返回 `nil` 的注释）——
该遗留并入 G1 或单列小项处理，**不占一格**。

## 3. 分批

### P2a —— 无分歧面（26 缺口，先行）

G1 控制流(5) · G2 元组(2) · G3 闭包与函数值(3) · G5 具名类型与字段(3) · G6 枚举族(6) ·
**G4 整族(7)**（`arrayLiteral` `dictLiteral` `setLiteral` `subscriptGet` `subscriptStore`
`lenCall` `sliceCall`）

> ⚠️ **本节条目曾与它自己的批次总数脱节**（2026-09-13 实测）：原文把 G4 写成「容器侧(5)」、
> 把 `lenCall`/`sliceCall` 列入 P2b，逐项相加得 **24 / 20**，而两次标题写的总数是 **26 / 18**。
> **总数才是对的**（5+2+3+3+6+**7** = 26；10+5+3 = 18），条目分解是旧的。
> **`D-P2-5` 取总数**：G4 整族在 P2a 交付，`lenCall`/`sliceCall` 不随字符串侧后置。
> 教训与 §1.1 末注同源：**手写清单会与它的汇总数脱节 ⇒ 开工前重算，别信条目。**

**验收**：该格夹具 `HIR_ENGINE_TODO → OK`（三通道逐字等值）+ 全量回归 + 变异反证两级。
**例外（B 组）**：`lenCall`/`sliceCall` 的 `String` 侧是**已登记的** B 组差异（契约要求改的是 LLVM 侧）
⇒ 按契约实现只会落 `CHANGE_*` 槽（非阻塞、也不转 `OK`）；故这两节点在**含非 ASCII 的语料**上验收
须判 `CHANGE_*`。本批的 73 个差分夹具全为 ASCII，实测三臂一致 ⇒ G4 这两节点仍记 `OK`。

### P2b —— 分歧面（18 缺口，后置）

G7 字符串与内建(10) · G8 指针与 LazyRef(5) · G9 IO(3)

**前置**：IO 语义格 / `stringSplit` 格 / 字符串字节语义格 / 取址格**裁齐两侧**。
**验收**：B 组节点判 `CHANGE_*`（非阻塞、登记为已知差异）；A 组与取址节点在裁齐后判 `OK`。

### 每格工作模板（五步，固定）

1. **实测夹具面**：`tools/hir-parity-probe.py --root … --filter <该族关键词>`，落盘整份 sweep 再读；
2. **夹具最小化**：多特性夹具拆到单节点（每夹具恰一个被测算子，变异才可判定）；
3. **实现**：镜像解释器语义（值层复用既有 `Value`/`Environment`，不新造第二份语义源）；
4. **验证**：该族夹具转绿 + 全量回归（基线对账用 stash 法见手则）+ 契约核验脚本仍 `clean`；
5. **变异反证两级**：① 全禁该族 → 该族**全部**转红；② 只禁单路径 → **只有**对应用例红；
   还原后 md5 逐字节对账。

## 4. 判据

1. **执行等值层**（三层判据之第一层，见主计划 §8）：三通道逐字等值 + 全量回归 + 变异反证两级。
   **分层读数**：`OK` / `HIR_ENGINE_TODO` / `CHANGE_*` / `FLIP BLOCKERS` **不可合并成一个数**
   —— 只有「失效时会动的数」才构成守门。
2. **规范一致性层**：`tools/hir-contract-check.py` 全绿（三锚点 60/60）—— 本格只增实现不增节点，
   故该读数应恒定；**它若变动即为意外，须查明**。
3. **spec 断言层**：留待 P3。

## 5. 止损点（触发即停）

1. 单格回归 **>5 测试失败且 >1 小时无收敛**（`ADR-031` §4）→ 停，回退该格。
2. **`bk_*` ABI 被迫改动**（`ADR-031` 约束 4 冻结）→ 路线选错，立即停。
3. 某节点**无法用现有值层表达** ⇒ 退化为「只做语义规范化」或另立形态项，不硬推。
4. 分歧面若**必须先改用户可见行为且无迁移窗口** ⇒ 拆项，不硬推（沿用停损 6 口径）。
5. 夹具最小化中发现**判据本身无区分力**（红了但理由不对）⇒ 先修判据再继续（P1-2 有前例）。

## 6. 不做范围

- **不做并发 / CPS**（`SuspendEvaluator` 与 AST 走查的冲突另待裁，见主计划载体）；
- **不碰契约与节点集**（P2 只增实现，不增删节点；`char` 节点与 `.join` 挂起语义是预留位，
  分别待 `P0d` 与 CPS 格）；
- **不修 AST / LLVM 侧实现**（B 组「修实现」与 A 组「统一」各自的载体已在册，不在 P2a）；
- **不做 `P0d`、字符字面量 `'c'` 格**；
- **不做值层合并**；不做性能优化；**WASM 端不排期**；
- **不 push**（除用户明确指示）。

## 7. 停止点

- 本轮交付 = **本规划件 + 主计划载体的 P2 行指针**，**未动任何源码**。
- ~~**下一步 = P2a 第一格（G4 集合与下标的容器侧），待点名**~~ ⇒ **已点名并交付（2026-09-13，
  实录见 §8.1）**。第一格开工前按五步模板第 1 步实测了该格夹具面，结论与偏差均记在 §8.1。
- ~~**下一步 = P2a 第二格（G2 元组：`tupleConstruct` `tupleIndexGet`），待点名**~~ ⇒
  **已点名并交付（2026-09-13）**，范围经 `D-P2-6` 扩为**含标签模型的整个元组族**，实录见 §8.2。
- **下一步 = P2a 第三格（G1 控制流，5 缺口），待点名**。P2a 六格已交付两格（G4 / G2），余 G1 / G3 / G5 / G6。
- 完整交付日志与后续各格实录**回填至主计划载体 §13** 与本件 §8。

## 8. 分格交付实录

（格式参照主计划载体 §13：交付内容 / 验证读数 / 变异反证 / 记缺陷。主计划载体 §13 存**同一条**的
完整版，此处保留读数与判据结论，避免两处发散。）

### 8.1 G4 集合与下标的（P2a 第 1 格，2026-09-13，分支 `agent/pini-dev/hir-p2a-g4-collections`）

**范围订正（D-P2-5）**：7 节点**整族**在 P2a 交付 —— `arrayLiteral` `dictLiteral` `setLiteral`
`subscriptGet` `subscriptStore` `lenCall` `sliceCall`。原 §3 把后两者按「字符串侧」划入 P2b，
与本节批次总数（26/18）矛盾，且**节点不可分割**：`lenCall` 是一个契约条目（§2.5 第 22 条），
把它的非 ASCII 行为留在 P2b，P2a 的「该族转绿」就无法闭合。故取总数口径。

| 面 | 前 | 后 |
|---|---|---|
| HIR 探针（73 夹具） | `OK 23` / `TODO 50` / `BLOCKERS 0` | **`OK 28`** / **`TODO 45`** / `BLOCKERS 0` / 零残留 |
| 首缺口 top | `arrayLiteral 10` · `construct 9` · `tupleConstruct 8` | `construct 9` · `tupleConstruct 9` |
| 新转绿夹具 | —— | `ArrayRead` `ArrayWrite` `Cow` `DictSet` `EmptyArray`（+5） |
| 全量回归 | 1235 / 3 skipped / 0 | **1236 / 3 skipped / 0** + swift-testing 45（+1 = 新增切片用例） |
| 契约核验 | `clean` 60/60 | `clean` 60/60（**预期恒定**，本格只增实现不增节点） |

- **实现口径**：语义**镜像**解释器，不新造第二份语义源 —— 读写规则留 `SubscriptReadStrategy` /
  `SubscriptWriteStrategy`；`len` 提为 `Interpreter.containerLength` 唯一事实源；`slice` 因已下沉
  Pini 源（`ADR-020 D2`）无 Swift 参照，改为原生镜像并由差分探针与原文绑定。
- **覆盖洞（本格最重要一条）**：`sliceCall` 是唯一无转绿夹具的节点 —— 唯一触及它的
  `testDiffSlice` 同时用开放边界（`a[:2]`/`a[3:]`/`a[:]`），降载为 optional 构造 ⇒ 它在**枚举族**
  就被拦下，整型边界路径**被执行但从未被比对**（整轮失败 ⇒ 输出不比较）= 手则「覆盖盲区」第四类。
  处置：补手写 parity 用例（钳制 / 全越界 / 负尾计数，Array 与 String 各覆盖），**该用例在 ②b
  变异下唯一转红**，区分力自证。反向核查：嵌套下标写回由 `m[0][1] = "B"` 覆盖（绿）、
  `setLiteral` 去重由 `{10, 20, 10, 30}` 覆盖（绿）⇒ **不属覆盖洞**。
- **变异反证两级**：① 整族 7 节点改回 fail-loud ⇒ 读数**精确退回本格前基线**（`OK 28→23`、
  `TODO 45→50`），5 夹具按正确节点名回 TODO；②a 只禁 `dictLiteral` ⇒ XCTest 1 红（红因文本为
  `node 'dictLiteral'`），探针 `--filter Dict` 单夹具入 TODO、`--filter Array` 数组族 3 个 `OK` **不动**；
  ②b 只禁 `sliceCall` ⇒ **唯一**红为手写切片用例（红因文本 `node 'sliceCall'`），语料 parity 全绿。
  还原后 md5 逐字节一致 ∧ 与 `/tmp` 备份 `cmp` 相同。
- **记缺陷**：**无新增工单**。覆盖洞属格内验证、已就地补齐；AST 侧 `sliceBound` 死代码沿用既有登记。
- **未做**：未改 AST / LLVM 任一侧实现；未动契约与节点集；未 push。

### 8.2 G2 元组族（P2a 第 2 格，2026-09-13，分支 `agent/pini-dev/hir-p2a-g2-tuples`）

**范围（`D-P2-6`，用户裁决）**：格内两节点之外，把 **F1/F2 一并修** ⇒ 本格交付 =
**元组节点实现** + **含标签模型的整个元组族**。

**节点面**：`tupleConstruct`（分量名随**值**走）· `tupleIndexGet`（位置读取）——
后者的规则本体提为 `Interpreter.tupleElement`（**唯一事实源**，纯搬移），
`evaluateTupleIndex` 变薄包装，否则「元组下标是什么」会出现第二个定义处。

**标签模型（F1 / F2）**：解释器只在两处补写分量名，引擎在同址复刻，规则本体不复制：

| 规则 | 解释器落点（既有） | 引擎落点（本格） |
|---|---|---|
| ① 显式 `return` 出口补写声明名 | `applyReturnLabels` | `HIRExecutor.call` 的 `returnSignal` 路径，喂入 `HIRFunction.returnType` 的声明标签（E4） |
| ② 带元组注解的绑定 | `applyTypeAnnotationLabels` | `HIRExecutor.allocVar`（E5）+ 降载侧 `HIRLowerer.slotType` |

配套改动六项：`resolveReturnType` default 分支携带 `decl.returnLabels`（E1）·
`TypeEnvironment.FunctionSignature.returnLabels` + `TypeChecker.signatureReturnLabels` 与 5 处注册点 ·
`TypeInference` 两处多槽调用返回类型改用 `sig.returnLabels`（E6）· `HIRExecutor.declaredReturnLabels` ·
`slotType`（把「声明不比初始化器多说名字」编码为**全 nil**）+ `allocVar` 判据**收窄**为
`labels.contains(where: { $0 != nil })` · `Interpreter.relabelled`（**纯搬移**，两臂共用）。

| 面 | 前 | 后 |
|---|---|---|
| HIR 探针（全根） | 73 夹具 `OK 33` / `TODO 36` / `GAP_HIR_ENGINE 4` | **74 夹具 `OK 34`** / `TODO 36` / `GAP_HIR_ENGINE 4` |
| 格内 `--filter Tuple` | —— | **7 夹具：`OK 5` / `GAP_HIR_ENGINE 2`**（后两者为假阻塞，见下） |
| 既有 73 夹具判定 | —— | **逐夹具对账：零变化**（唯一差异是新夹具 `testDiffTupleLabels` 本身） |
| `FLIP BLOCKERS` | 0（G4 交付时） | **4（全部为判据产物，实质分歧 0）** |
| 全量回归 | 1236 / 3 skipped / 0 + 45 | **1240 / 3 skipped / 0 + 45**（+4） |
| 契约核验 | `clean` 60/60 | `clean` 60/60（**预期恒定**：只增实现不增节点） |
| 门禁 | —— | comment-lint L1–L6 全绿；doc-links 491 引用通过 |

**+4 用例逐条对账**（`npm` 式账目，全在本分支）：`HIRDifferentialTests.testDiffTupleLabels` ·
`HIRExecutorTests.testNamedReturnLabelsFollowTheInterpretersTwoRules` ·
`HIRLowererTests.testNamedReturnTypeCarriesItsComponentLabels` ·
`HIRExecutorTests.testTupleLabelsAreCarriedIntoTheValue`（属**节点实现**那半，非 F1/F2 那半）。

**结构发现一（最重要的那条）：标签模型在 HEAD 上静态不完整。**
`let r = 除余(17, 5)` 之后 `r.商` 在 HEAD 上是 **`unknownMember` 类型错误**——解释器运行期
却会补写这个名字。⇒ F1/F2 不只是「让引擎对齐参照」，而是把**静态视图**与**运行期值**对齐
（证据：L1 整族禁用轮的日志里，该用例的第一条失败就是 `test sources must typecheck`）。

**结构发现二：本格把标签模型收敛成两臂共用一份实现**（`Interpreter.relabelled`），
于是逐字节等价看不见「共同源被删」。曾据此加一条字面期望值钉子，**变异实测证明其冗余并撤回**
（见下"判据纪律"）。

**变异反证两级**（七轮，每轮锚点唯一性断言 + md5 逐字节核验还原；器械经修正后使用）：

| 轮 | 禁用的路径 | 实测（`control` 为 `testTupleLabelsAreCarriedIntoTheValue`） |
|---|---|---|
| L1 | 整族（stash 全部 `Sources/`） | **5/5 全红**（含 control：节点实现与标签改动一并回退） |
| M2 | 引擎返回点改写（E4） | `exec_labels` · `corpus` |
| M3 | 绑定判据放宽回 `!labels.isEmpty`（E5 条件） | `exec_labels` · `corpus` · **`control`** |
| M4 | `slotType` 剥离（`return declared`） | `exec_labels`（**唯一只红一个用例的一轮**） |
| M5 | 声明返回标签（E1） | `exec_labels` · `corpus` · `lowerer` · `diff` |
| M6 | 推断侧标签（E6，两处同时） | `exec_labels` · `corpus` · `diff`（**以类型检查失败形式**） |
| M7 | 共享的 `relabelled`（**两臂**） | `exec_labels` · `corpus` · `diff`（**以两臂同时抛错形式**：`未定义变量: 商`） |

**两处与事先预测不符，如实记录**：
1. **`control` 不是中性对照** —— 事先断言它免疫 M3/M4；M3 实测把它打红，日志给出确切红因：
   HIR 臂输出 `["[3, 2]", "3", "3", "[1, 2.5]"]`，即 `let t = (商 = 3, 余 = 2,)` 的标签被**洗掉**。
   ⇒ `slotType` 的全 nil 输出对**普通具名字面量绑定**同样承重。它也不是"既有 G5 用例"，
   而是**本分支节点实现那半新增的用例**（`git diff` 核对），**骑在绑定路径上**。
2. **M4 可观测** —— 事先预测它不可观测（误以为 `slotType` 与收窄后的判据是冗余对）；
   实测它是唯一只红一个用例的一轮，红因正是促使 `slotType` 出现的形状：
   隐式尾表达式 `let s = 其余(17, 5)` 被误加分量名（第 4 行 `[商: 3, 余: 2]` vs 参照 `[3, 2]`）。

**判据纪律（本格第二条结论）：撤回了自己刚加的字面期望值钉子。**
M7 表明「共享源被删」**不会**造成两臂静默一致，而是**两臂同时抛错**（读 `r.商` 需要标签才能解析），
本器械本就会失败；而「只改渲染」的共享变异只会打到解释器臂，由 LLVM 差分臂抓住
（M2/M3/M4 的 `diff` 全绿 + M5/M6 的 `diff` 转红，正说明两个器械是**分工**而非冗余）。
⇒ 该钉子**无独占区分力**，按「不添加未证实区分力的判据」撤回；撤回后单跑 M7 读数**逐项不变**（已实测）。

**记缺陷（3 张，均按判准只登记不修）**：
- `docs/issue-llvm-trailing-expression-return-2026-09-13.md`（**新建**）：v1–v6 六夹具完整表征 ——
  **凡非 void 函数以尾表达式返回值，LLVM 通道返回的是返回槽残留**（有参得第一参数、无参得 `1`），
  **静默错误结果**；基线逐字复现；根因源码级定位到 `IREmitter` 唯一的 `.exprStmt` 分支
  （丢弃表达式值，全文无「尾表达式写返回槽」规则）；**语料零覆盖**（73 夹具中无该形状，
  `testDiffNoTrailingReturn.pini` 名不副实）。两条 HIR 后端都实现了这条规则，只有发射器没有。
- `docs/issue-tuple-label-binding-rule-2026-09-13.md`（**新建**）：§1 位置式注解盖住具名值
  （解释器与 llvm 两臂一致、只有引擎分叉，**语料不可达**，含两套精确修法及代价）·
  §2 泛型方法/函数特化丢标签（两处就地注明「Recorded, not fixed」）·
  §3 **spec 级待裁**：具名返回的**隐式**尾表达式是否带分量名（前置 = 先修值）。
- `docs/issue-diagnostic-channel-parity-2026-09-12.md`（**维护**）：本格兑现其预言 ——
  「当前不可达」被**实测证伪**，`FLIP BLOCKERS 4` 全部是 `E7-001` 假阳性造成的**假阻塞**
  （四夹具三臂 `rc` 全 0、stdout 逐字一致）；计数器的收窄时机**上交为决策点**，本格不自改。

**未做**：未改 AST 侧渲染与 LLVM 侧实现；未动契约与节点集；未收窄探针 `GAP_HIR_ENGINE`；
未修两张新工单任何一项；未 push。
⇒ **下一格 = P2a 第三格（G1 控制流），待点名**。

## 9. 决策记录

| 编号 | 决策点 | 裁决（2026-09-13，用户） |
|---|---|---|
| **D-P2-1** | 分歧面排期 | **后置为 P2b**，前置 = 两侧裁齐（既有登记，无需新裁决） |
| **D-P2-2** | 族边界 | **以契约 §2/§3 分节为准** |
| **D-P2-3** | 第一格 | **G4 集合与下标的容器侧** |
| D-P2-4 | P2 判据形态 | **三态**（`OK` / `CHANGE_*` / 阻塞槽）；分层读数，不合并成单一数字（§2.1–2.2） |
| **D-P2-5** | G4 的 `lenCall`/`sliceCall` 是否随其 `String` 侧后置 | **不后置**：两节点在 P2a **整节点**实现（镜像解释器 = 契约的 grapheme 语义），其 `String` 侧分歧仍作为**已登记的 B 组差异**保留，P2a 验收对这两节点在非 ASCII 语料上记 `CHANGE_*`（D-P2-3 的「容器侧」由此**扩展为整族 7 节点**） |
| **D-P2-6** | G2 的范围：格内两节点之外，F1/F2 两个既有缺陷是否随格修 | **都修，扩为「含标签模型的整个元组族」**（F1 执行侧 `call` 丢返回标签 / F2 降载侧拒绝注解标签绑定与返回类型标签），接受更大范围及其额外的变异证伪要求（实录 §8.2） |

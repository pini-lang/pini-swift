# Issue：解释器统一 HIR —— P2（分格实现）执行规划

- 状态：**P2a 进行中 —— 已交付 5 格**（G4 集合与下标的 7 节点 · G2 元组族 · G1 控制流 6 节点 ·
  **G6 枚举 · Optional · Result · try 6 节点（2026-09-14 重放交付）** ·
  **G5 具名类型与字段 3 节点（2026-09-14）**）；
  **下一格 = P2a 第六格（G3 闭包与函数值，3 缺口：`closureLiteral` / `functionValue` / `indirectCall`），待点名**。
  规划轮（2026-09-13 早些时候）**只读勘测 + 落盘规划，未改任何源码**；
  G4 实录见 §8.1（范围订正 `D-P2-5`）· G2 见 §8.2（范围 `D-P2-6`）· G1 见 §8.3 ·
  **G6 见 §8.4（重放）** · **G5 见 §8.5（两次范围订正：类型方法解析入格 / 内建 callee 立单）**。
  ⚠️ 本行与主计划载体的同型指针此前在 G1 收口时**漏改**，已由 G6 重放批一并订正（详见 §8.4 末条）；
  G5 收口时按 `grep -n '下一格 = '` **全篇扫**复核，未再发现新漏项。
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
- ~~**下一步 = P2a 第三格（G1 控制流，5 缺口），待点名**~~ ⇒ **已点名并交付（2026-09-13）**，
  实录见 §8.3。**实测该格缺口为 6 个而非规划的 5 个** —— 规划表的 G1 行漏了 `stringConcat`
  （它被列在 G7 行），而**契约把字符串连接归控制流侧语句族**；格内按契约口径实现，见 §8.3「范围订正」。
- ~~**下一步 = P2a 第四格（G6 枚举 · Optional · Result · try，6 缺口），待点名**~~ ⇒
  **已点名并交付（2026-09-14 **重放交付**，实录见 §8.4）**。该格曾于 2026-09-13 完整交付过
  （归档提交 `647b218`，合并点 `8089c0b`），随后 main 被硬回退而离开主线；本次按「重放批」
  在新基准上重建（勘测结论 = **复用而非重写**）。重放实测**两处器械侧缺陷**
  （M1 打靶结构性不可观测 / `slice` 对照选错）与归档结论一致，均归 **P3**，不阻塞本格。
- ~~**下一步 = P2a 第五格（G5 具名类型与字段，3 缺口），待点名**~~ ⇒ **已点名并交付（2026-09-14）**，
  实录见 §8.5。**本格不是重放**（归档 `86fdafd` 是 TDD 红灯态，dispatch 三行未接线）⇒ 工作 = 复用素材 + 补完。
  格内**两次范围订正**：① 必须扩入**类型方法解析**（21/30 夹具需要）；② 裸内建 callee **不解析**
  （2/30，代价 = 两夹具升为 `GAP_EXEC`，`BLOCKERS` **23 → 25**），归属缺口已立独立工单。
- **下一步 = P2a 第六格（G3 闭包与函数值，3 缺口：`closureLiteral` / `functionValue` / `indirectCall`），待点名**。
  P2a 六格已交付五格（G4 / G2 / G1 / G6 / G5），**余 G3 一格**；P2a 收尾后转 P2b 三格（G7 / G8 / G9）。
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
⇒ ~~**下一格 = P2a 第三格（G1 控制流），待点名**~~ ⇒ **已点名并交付，见 §8.3**
（此指针在 G1 收口时漏改，由 G6 重放批订正）。

### 8.3 G1 控制流（P2a 第 3 格，2026-09-13，分支 `agent/pini-dev/hir-p2a-g1-control-flow`）

**范围（`D-P2-7`；**格内范围判定，非用户裁决**）**：本格交付 **6 节点** ——
`forInStmt` `breakStmt` `continueStmt` `deferStmt` `panicStmt` `stringConcat`
（E1 证据：`HIRExecutor.swift` 的 `git diff` 恰好移除这 6 条 `notImplemented`）。

⚠️ **这与规划表 §1.1 的排列不一致，订正须记录**：
§1.1 的 **G1 行记「5 缺口」**（`forInStmt` `deferStmt` `breakStmt` `continueStmt` `panicStmt`），
而把 `stringConcat` 列在 **G7 行**（10 节点）。契约的确切归属是 **§2.9「字符串与内建」第 41 条**
（注记为「C 组：两侧结果一致，仅分配方式不同」）—— **不是控制流侧**。
本格把 `stringConcat` 纳入 G1 的**理由是夹具依赖，不是契约分类**：
defer 夹具**需要字符串拼接来构造其期望输出**，缺它则本格无法闭合（出处 = `HIRExecutor.swift`
的节点清单 docstring：「plus the `stringConcat` the defer fixtures need to build their expected string」）。

**由此产生的账目后果（登记，待确认）**：`stringConcat` 自 G7 移入 G1 后，
**P2a 26 → 27 缺口、P2b 18 → 17 缺口**（总 44 不变）。本件**不自行改写** §1.1/§3 的既有数字
（该两处已有「条目分解与总数脱节」的前科，教训见 §3 的 ⚠️），仅在此登记该回归项，待点名下格时一并厘清。

| 面 | 前 | 后 |
|---|---|---|
| HIR 探针（6 根 / 308 夹具） | `OK 109` / `TODO 141` / `GAP_HIR_ENGINE 13` / `GAP_EXEC 3` / **`FLIP BLOCKERS 16`** | **`OK 137`** / **`TODO 112`** / **`GAP_HIR_ENGINE 14`** / `GAP_EXEC 3` / **`FLIP BLOCKERS 17`** |
| HIR 探针（HIRTests 单根 / 74 夹具，台账可比口径） | `OK 34` / `TODO 36` / `GAP 4` / 首缺口节点 **20** | **`OK 38`** / **`TODO 32`** / `GAP 4` / 首缺口节点 **16** |
| 逐夹具对账（308 夹具） | —— | **29 处变化，全部可解释**：28 `TODO→OK` + 1 `TODO→GAP_HIR_ENGINE`；**零新增/零消失夹具** |
| 全量回归 | 1240 / 3 skipped / 0 failures + swift-testing 45 | **1246 / 3 skipped / 0 failures（0 unexpected）· EXIT=0**（+6，恰为本格新增用例） |
| 契约核验 | `clean` 60/60 | `clean` 60/60（**预期恒定**：只增实现不增节点） |
| 门禁 | —— | comment-lint L1–L6 全绿；doc-links **523 引用**通过（上格 491） |
| 进程残留 | —— | **零**：`lli` 0 / `pini` 0 / 探针 0 / stray `.ll` 0（探针自报 same） |

**逐夹具对账（本格最重要的一条纪律动作：不看总数看差集）**

- **28 处 `TODO→OK`** 按首缺口节点分解：`forInStmt` 12 · `deferStmt` 6 · `breakStmt` 6 · `continueStmt` 5
  = **28**，与 `HIR_ENGINE_TODO 141→112`（−29）**逐项吻合**（差的 1 个见下条）。
- **1 处 `TODO→GAP_HIR_ENGINE`** = `tests/…/RuntimeBackendTests/testBreakCollectionReleasesIRContract.pini`
  —— 该夹具原被「`breakStmt` 未实现」拦下，本格实现后**这层屏蔽变薄**，露出 stderr 的 `E7-001` 假阳性
  ⇒ 落进假阻塞桶。**这是已登记机制（「P2 每实现一个节点这层屏蔽就薄一分」）的又一实例**，
  不是本格引入的缺陷：三臂 `l_rc/h_rc/a_rc` 全 0、stdout 逐字一致，**实质分歧 0**。
- **`FLIP BLOCKERS 16 → 17` 的 +1 就是上一条**（定义 = `GAP_EXEC + GAP_HIR_ENGINE + GAP_BEHAVIOR + GAP_HANG`，
  后两者为 0）。两处阻塞槽**身份已核**：`GAP_EXEC` 3 个与基线**完全相同**
  （`testBuiltinMathFloatsViaLLI` / `testBuiltinMathIntegersViaLLI` / `examples/ffi.pini`，
  均为 `l=0 h=1 a=0` 的 `E5-006`，属既有 HIR 侧缺口 + FFI 未实现，不在本格范围）；
  `GAP_HIR_ENGINE` **14 个全部是 `E7-001` 假阳性**（基线 13 个亦然，`13 + 新增 1 = 14`）。
- **`G1` 六节点在「后」的 `HIR_ENGINE_TODO` 里出现 0 次**（全部归零）。
  ⚠️ `panicStmt` 与 `stringConcat` **从未作为首缺口出现**（被更早的节点遮蔽）
  —— 再次实证「**首缺口分布 ≠ 夹具覆盖**」；两者的区分力由**手写单通道用例**承担（见下）。

**覆盖洞与判据补强（本格第二条结论：「未实现」与「实现正确」在抛错形态下不可区分）**

- `testBreakWithoutAnEnclosingLoopDoesNotRunOnSilently`（循环外裸 `break` 的 fail-loud 用例）在
  **全部 6 次变异下均不红**（含整族禁用、含 `breakStmt` 单点禁用）—— 根因：**「节点未实现」恰好也抛错、
  也停输出**，与「实现正确（按契约硬报错）」在断言层**完全无法区分**，故该用例当时是**弱判据**。
- 处置（`D-P2-8`，用户裁决「就地补强断言并复验」）：断言加
  `XCTAssertFalse(text.contains("not implemented"), …)` —— 把「必须是**处理了**这个 break」与
  「**根本没实现**」分开。**复验实测**：补强后族 **19 绿 / 0 红**；单点变异 `breakStmt` 下该用例
  **转红**（`TARGET 是否变红: YES`），且其余控制流用例仍绿 ⇒ 补强有效、区分力自证。
- **一级判据的历史状态（如实记录）**：本格第①级（整族禁用）的期望「相关用例**全部**转红」在补强
  **之前**未完全满足（7 个相关用例中第 7 个不红）；补强后该缺口闭合。第②级（单点禁用）判据通过。

**变异反证两级（六次独立观测，每轮锚点唯一性预检 + 还原后 md5 逐字节对账）**

| 变异 | 红集 | 计数 |
|---|---|---|
| ① 整族禁用（stash 全部 `Sources/`） | 4 新增 parity + corpus + panic = 6 | 5 unexpected |
| ② `forInStmt` | corpus · defer · ForInIterableFamilies · ForInStep · UnwindDepth | 5 |
| ② `breakStmt` | corpus · defer · ForInStep · UnwindDepth（**补强后 + 裸 break 用例**） | 4（补强后 5） |
| ② `continueStmt` | corpus · UnwindDepth | 2 |
| ② `deferStmt` | corpus · DeferRunsWhenBreakOrReturn… | 2（与预测逐条吻合） |
| ② `panicStmt` | PanicStmtFailsLoud… | 1 |

还原校验：第①级 `stash pop` 后 5 文件 md5 **逐字节相同**；第②级每轮起终点均 md5 断言；
还原后族回绿（104 用例 / 0 失败 / 0 错误），复跑 `breakStmt` 轮后二进制重建
（md5 `862101265d…` == 冻结基线）。

**判据陷阱查实（`(N unexpected)` 不是红数）**：6 次观测一致二分 —— **测试方法抛错计入 `unexpected`**、
`XCTAssert*` 失败计入 `expected`。全仓无 `XCTExpectFailure|withKnownIssue|Issue.record`
（机制未证、反例 0）⇒ **判红必须读失败清单，不能读 `(N unexpected)`**。

**记缺陷（2 张，均已在计划内当场处置或立案）**

- **编译缺陷（当场修）**：`HIRExecutorTests.swift:353/355` 写成 `.printCall(...)` ⇒ **60 条编译错误**
  （`printCall` 属 `HIRExpr`，语句侧须经 `exprStmt`）。改为 `.exprStmt(.printCall(...))`，未动语义。
  教训 = 手则 §4 新增条「**『用例写了』≠『用例能编译』**」（`Sources/` 与 `Tests/` 是两个编译单元，
  `swift build` 全绿不代表测试目标能编译）。
- **弱判据（当场补强）**：见上「覆盖洞与判据补强」；并已在手则 §4 登记同型陷阱。
- **《Swift 源码缩进被全仓压平成 1 空格》（新工单，`docs/issue-swift-source-indent-2026-09-13.md`）**：
  本格改 `Interpreter.swift` 时出现无法解释的空白变更 ⇒ 量缩进直方图确认是**全仓性历史残留**
  （可回溯到建仓首提交 `d96d0c1`，四个旧文件当时即 100% 压平；`HIRExecutor.swift` 首提交 0%）。
  **排期 P4 之后**（`D-P2-9`，用户裁决）。本格只落 `executeFor` 整函数体（裁 A）。
  ⚠️ **连带教训**：我改前**未量文件缩进**，违反手则 §2 既有规则（**该条第二次失效**）⇒ 已把
  「`git diff --stat` 与 `git diff -w --stat` **行数必须相等**」写为机械复查条。

**未做**：未改 AST / LLVM 任一侧实现；未动契约与节点集；未收窄探针 `GAP_HIR_ENGINE` 判据
（该计数器收窄时机仍为上交给决策点）；未修缩进工单（排期 P4 后）；未 push。

### 8.4 G6 枚举 · Optional · Result · try（P2a 第 4 格，2026-09-14 **重放交付**，分支 `agent/pini-dev/hir-p2a-g6-enums-replay`）

> **本格是重放，不是首次实现。** 原交付 = 归档提交 `647b218`（合并点 `8089c0b`），其父是**旧 G1 的
> 合并点 `3f98079`**；main 随后被硬回退至 `9d9ab4e`，该交付离开主线。回退**因由是程序性的**
> （锚点由用户选定、回漂移整备期回稳定点），**并非因技术缺陷被丢弃** ⇒ 归档件可信、按**复用**处置。
> 勘测五条判据（回退因由 / 逐文件 `git apply --check` / 三方合并定冲突面 / 符号层验无实依赖 /
> 契约是否变过）的实测见当日记忆日志；结论 = **可执行代码零冲突**（冲突全在文件头 docstring）。
> ⇒ **本节读数全部为本格在重放基准上重测**，归档自己的读数（`OK 38→49` / 全量 `1249` /
> 分支名 `hir-p2a-g6-enums`）**一律不沿用**；凡与归档不一致处，**本节的数即当前数**。

**范围**：格内 **6 节点**，**无跨格依赖** —— 与 G1（§8.3，需借 G7 的 `stringConcat`）不同，
本格两个「夹具撞到别的节点」的情形（`testDiffSlice` 撞 `optionalConstruct`、`testDiffValueFormat` 撞
`optionalGet`）**都在本格节点面内**，故**不产生**新的 `D-P2-*` 决策，只需按 `D-P2-5`「不留验证空档」
随格实现。这是分格时「按节点分族、夹具按能力组合」在**同格内部**的一次兑现。

**节点面（6）**：

| 节点 | 实现要点 |
|---|---|
| `resultConstruct` | 转发 `Interpreter.makeResult` ⇒ ok/err 值构造**单源**。err 载荷在 LLVM 侧是一个类型擦除的机器字（`LR-12`），本侧绑**真实载荷**——已登记的 ABI 边界（打印错误绑定在 LLVM 侧 fail-loud `E6-004`），不是分歧 |
| `optionalConstruct` | Optional 的运行时形态就是 `some` / `none` 两用例（无 `parentEnum`）。`isSome` 却无载荷 ⇒ **fail-loud**（不静默造值） |
| `optionalGet` | 规则提为 `Interpreter.builtinGet`（**static 单源**）：负索引尾部计数 + 字典键相等匹配 + 越界落点。解释器的 `.get` / `.getUnchecked` 成员块改为调用它，私有方法 `uncheckedOrNone` **并入该单源**（3 处调用点 → 1） |
| `enumConstruct` | 关联值名取**声明**（`HIREnumCase.paramNames`），与解释器构造器的 `fv.params.map { $0.name }` 同源同序；查不到声明 ⇒ **fail-loud**（不静默造空载荷） |
| `tryStmt` | operand 必为 `Result`（否则 `typeMismatch`）；ok → 写 `okTarget`；err → 新环境绑 `errorVar` 后跑 handler。handler 语句**就地跑、不另起块**，故 `return` / `break` / `continue` 以信号自然冒泡，`pass` 只是结束语句（解释器 `tryExpression` 同形） |
| `matchStmt` | 命中判定提为 `Interpreter.matchArmMatches`（**static 单源**，字面量按值 / `_` 通配 / case 名）；每臂一个 case 环境 + `executeBlock`（臂内 defer 在**臂末** LIFO）；未命中尾部规则照抄（见结构发现二） |

**结构发现一：「声明处的一次初始化」是语言里客观存在的第三种写，`Environment` 之前没有 API 表达它。**
降载器把 `let x = try f() else e: ...` 拆成 `allocVar(x, initializer: nil)` + `tryStmt(okTarget: x)` ⇒
ok 臂必须写进**已经声明**的槽。两条现成 API 都不对：`assign` 会被「`let` 不可变」拒绝（**合法程序被拒**），
`define` 则覆盖且需重造可变性（可能把 `let` 悄悄变 `var`）。⇒ 新增 `Environment.initialize(name:value:)`：
不做可变性检查、**保留原可变性**。它命名的不是「更宽松的 `assign`」，而是**声明处初始化**。
变异 M6（`initialize` → `assign`）实测红 `corpus` ⇒ 该区分被语料门控，不是纸面洁癖。

**结构发现二：`match` 的「怎么命中」与「未命中怎么办」是两件事，后者由值类型决定、不由静态类型决定。**
命中判定可直接落在值上（字面量 / `_` / case 名），故三通道共用一份 `matchArmMatches`；
而未命中的尾部规则照抄解释器只有一条：**运行时值是枚举值 ⇒ 抛 `matchNotExhaustive`，否则静默落空**。
这一条**统一覆盖三个臂族**（Optional / 枚举 / 裸值）⇒ 引擎**不读** `scrutineeType`：静态类型的工作在
降载期已做完（选哪个臂族），在此再分派一次就是第二个可能不一致的判定源。
`testDiffMultidimArray` 是这条静默规则的语料证据——它的 scrutinee 是**裸下标读**，`case some(row)` 臂永不命中。
另有一处**订正**：`match` 穷尽性是**类型检查器**职责（`E3-007`，静态拒绝），引擎只承担**运行时未命中**处置。

**结构发现三：同一份语义写两遍的代价是实测出来的，不是假设的。**
本格提了**两个** static 单源（`matchArmMatches` / `builtinGet`），都属「解释器里已经有了、HIR 需要复用」。
`builtinGet` 的提取还**净删**了一个私有方法（`uncheckedOrNone`）⇒ 单源化不等于加代码。
两个单源的**被打过靶的分支**均有变异轮次证明其被门控（M1b 打 `matchArmMatches` 的字面量值比较、M2 打通配、
M9 打 `builtinGet` 的越界落点）；**未被单独打靶的分支、以及 M1 这个反例见文末「变异反证」**——账写窄，不复述。

**判据缺口补齐 6 项**（动手前**无任何断言**）：裸值字面量 match 的**值分派**与 `case _` **通配兜底** ·
臂内 `defer` 在**臂末** LIFO · try handler 以 `pass` 终止（**语句位**；表达式位被降载器拒，两半的分界此前无断言）·
`resultConstruct` **节点级**行为与 **`Result` 作 scrutinee** 的 match（无任何夹具）·
枚举未命中 ⇒ `matchNotExhaustive`（**源不可达**，须以节点构造）· 裸值未命中 ⇒ **静默**（方向相反，同样源不可达）。

**重放落盘与结构自检**：三方合并（`git merge-file -p <新基准> <旧前驱> <归档版>`）解 2 处冲突，
**全在 `HIRExecutor.swift` 的文件头 docstring** —— ①「已实现节点清单」取**新基准骨架 + 并入本格子句**；
②「边界声明清单」取**两侧并集**（G1 的 `panicStmt` 条 + 本格 `try` 类型擦除 `E6-004` 条 + `match` 穷尽性条）。
`HIRExecutorTests.swift` 亦 2 处冲突，按「双方各自追加用例 ⇒ 取并集」处置（**已删的 2 个旧 G1 用例不取回**，
两处用例名无撞车）。合并后自检：**0 残留标记 · 大括号平衡 · 恰 6 个本格节点退出 fail-loud 表**。
⚠️ 最后一条要数**打靶点**而不是**词频**：裸 `grep -c notImplemented` 会把函数定义与注释里的一处复述
一起数进去（实测得 25），而 `notImplemented("<node>")` 调用形态实测 **29 → 23**，
前/后差集**恰好等于本格六节点名、反方向为空** —— 差集比计数更强，它同时证明「没有多退出、也没有少退出」。

| 面 | 前 | 后 |
|---|---|---|
| HIR 探针（**全量 6 根 / 308 夹具**） | `OK 137` · `TODO 112` · `GAP_HIR_ENGINE 14` · `GAP_EXEC 3` · `FLIP BLOCKERS 17` | **`OK 181` · `TODO 62` · `GAP_HIR_ENGINE 20` · `GAP_EXEC 3` · `FLIP BLOCKERS 23`** |
| HIR 探针（**HIRTests 单根 / 74 夹具**，台账可比口径） | `OK 38` / `TODO 32` / `GAP_HIR_ENGINE 4` | **`OK 49` / `TODO 21` / `GAP_HIR_ENGINE 4`** |
| `TODO` 按节点聚合（**单根口径**） | 32 夹具 / **16 节点** | 21 夹具 / **11 节点**（`construct` 9 · `closureLiteral` 3 · 其余 **9 个各 1**）；**G6 六节点全部从清单消失** |
| `TODO` 按节点聚合（**全量口径**） | 141 夹具 / 22 节点（pre-G1） | 62 夹具 / **13 节点** |
| 逐夹具判定变化 | —— | **79 个 = G1 面 29 + 本格面 50**，**零未归因**；余 229 个零变化 |
| `CHANGE_*` / `GAP_BEHAVIOR` | 0 | **0** |
| 全量回归 | 1246 / 3 skipped / 0 + 45 | **1251 / 3 skipped / 0 failures（0 unexpected）+ swift-testing 45**（+5） |
| 契约核验 | `clean` 60/60 | `clean` 60/60（三锚点 llvm / printer / interp-hir **各 60/60**） |
| 门禁 | —— | comment-lint L1–L6 全绿；doc-links **525** 引用通过；`hir-contract-check` clean |

**夹具面对账（第 1 步实证价值，重放复验）**：动手前基线「首缺口属 G6 六节点」的夹具恰为 **11 个**
（`enumConstruct` 3 · `tryStmt` 3 · `matchStmt` 2 · `optionalConstruct` 2 · `optionalGet` 1 = 11）——
**无一遗漏、无一多出**，与归档清单**逐字重合**；复扫后 74 夹具里**只有这 11 个判定变化**（另加
`resultConstruct` **零夹具**首缺口：被 `tryStmt` 遮蔽 ⇒ 转由节点级用例覆盖，见上「判据缺口补齐」第 4 项）。
两条跨格线索按 `D-P2-5` 落定：① `testDiffSlice` 撞 `optionalConstruct`（同型于 G1 的 `stringConcat`，
但落在**本格内**）；② `testDiffValueFormat` 同时覆盖 `optionalGet` 的**命中与未命中两支**
（`w.get(1)` → `some(2)`、`w.get(9)` → `none`）。

**全量面 Δ 的归因（逐夹具，不看总数）**：`OK +44` · `TODO −50` · `GAP_HIR_ENGINE +6`，三者自洽
（50 个离场夹具里 44 转 `OK`、6 转阻塞槽）。相对 **pre-G1** 冻结基线共 79 处变化，
按**基线 `note` 列的首缺口节点名**归因 = **G1 面 29 + 本格面 50 = 79**，**未归因 0 处**；
夹具集合**零增删**（`仅在基线 0 / 仅在本格 0`），`sum(各 verdict) = 308` 两侧成立。
⇒ 与 G1 收口的记账**严格相加**（G1 的 28 TODO→OK + 本格 44 = 72 = 109→181 ✓）。

**+5 用例逐条对账**（全在本分支，全为 `HIRExecutorTests`）：
`.testBareScrutineeMatchDispatchesOnLiteralsAndWildcard` ·
`.testDeferInsideAMatchArmRunsAtArmExit` · `.testTryHandlerMayEndInPassAtStatementPosition` ·
`.testResultConstructorValueDispatchesThroughMatch`（节点构造：`Result` 值 + `Result` 作 scrutinee）·
`.testMatchFallThroughIsLoudForEnumsAndSilentForBareValues`（一条用例钉住**两个方向相反**的尾部规则）。
另：`inRangeFixtures` **+11**（全部为实测转绿者，逐名核对）、`statementGaps` **−2**（`tryStmt` / `matchStmt` 退场，余 `fieldStore`）。

**阻塞槽的 +6 已归因，且经逐字复验为假阳性**：新增 7 个阻塞面 = 本格 6 个（`OptionalTests` 六个夹具）
+ G1 遗留 1 个（`testBreakCollectionReleasesIRContract`）。**全部 20 个 `GAP_HIR_ENGINE`** 的机制由探针
rule 8 明载：「`interp-hir` 未失败但往 stderr 写了话」——`run` 打印 `E7-001` 语义警告而 `run-llvm` 吞掉，
于是 `bool(l_err) != bool(h_err)` 使 rule 5 的 parity 判不成立，落进阻塞槽。
⚠️ 探针只记 stdout **长度**，而「长度相同」不等于「字节相同」⇒ 本格对新增的 7 个面**另行逐字复验**：
`rc(l,h,a) = 0/0/0`、三条臂 stdout **逐字节一致（7/7）**，且 `E7-001` 同一段文本在 **`interp-ast` 冻结参照臂上
同样出现** ⇒ 该告警与 HIR 实现无关，是**既有**的两通道诊断面差异。
⇒ **实质分歧 0**；`FLIP BLOCKERS` 的绝对数增大是「**每实现一个节点，这层屏蔽就薄一分**」的第 N 个实例，
**非本格引入的缺陷**（机制与收窄时机登记在 `docs/issue-diagnostic-channel-parity-2026-09-12.md`，路由 P3）。

**变异反证（两级：重放复跑归档的 2 基线 + 12 轮打靶；器械 `/tmp/g6-replay-mutation-falsify.py`，
日志 `/tmp/g6-replay-mutation-out.txt`）**

`L0` 未变异基线 **8/8 全绿** ⇒ 前置闸门成立；`L1`（`git stash push -- Sources/`：整族关闭、测试留在树上）
**6/6 族用例全红、两对照恒绿** ⇒ 那 11 个夹具的转绿确系本格 `Sources/` 改动所致，不是测试侧造绿。
每轮还原均 md5 对账通过；**全轮结束后另做一次独立复核**：4 个文件 md5 与变异前备份**逐字节一致**、
`git diff` 补丁 md5 一致、`git stash list` 为空 ⇒ **13 次 `restore OK` / 0 MISMATCH**。

| 轮 | 打掉的规则 | 观测 | 红者 |
|---|---|---|---|
| M1 | 字面量臂尾部 `return false`→`true`（**异类型**字面量臂恒真） | **否** | ——（缺陷一） |
| M1b | `.int` 字面量分支恒真（**同类型**字面量臂对任意值恒真） | 是 | `fall` |
| M2 | `case _` 永不成真 | 是 | `corpus` · **`slice`**（缺陷二） |
| M3 | 臂体不另起块（`executeBlock`→`executeStatements`） | 是 | `armdefer` |
| M4 | 载荷绑定倒序（`reversed()[index]`） | 是 | `corpus` |
| M5 | try 处 ok/err 互换 | 是 | `trypass` · `corpus` |
| M6 | ok 槽经 `assign` 而非 `initialize` | 是 | `corpus` |
| M7 | `resultConstruct` 恒造 ok | 是 | `trypass` · `corpus` |
| M8 | `optionalConstruct` 的 none → `some(null)` | 是 | `corpus` |
| M9 | `optionalGet` 去掉边界检查 | 是 | `corpus` |
| M10 | 枚举未命中不再响亮 | 是 | `fall` |
| M11 | 裸值未命中改为响亮（**方向相反**的规则） | 是 | `fall` · `corpus` |

不变量：① `L1` 全族红 ✅；② 每轮至少一项非对照红 —— **11/12**（M1 例外）；③ 两对照恒绿 —— **11/12**（M2 例外）。
⇒ **重放复跑与归档读数逐字一致**（同一套变异、同一组用例、同样的两处例外）。

**缺陷一（判据盲区 + 器械的结构性上限；已实测，归 P3）：M1 打靶不可观测，且原因不止「语料少一个夹具」。**

① **语料无「异类型字面量臂」**：74 夹具中 `case <字面量>:` 零命中；手写 `fall` 的裸值半边是
`intConst(4)` vs `literal: .int(1)`（**同类型、值不等**），走不到被变异的尾部 ⇒ M1 在本仓**无靶点**。

② **更根本：`matchArmMatches` 是两条解释器通道共用的谓词，而单测 parity 只比这两条通道。**
`HIRExecutorTests` 的 `assertParity` = `XCTAssertEqual(hir, ast)`，**不接 LLVM 通道**；
共用代码的变异在两条通道里**同时生效、相互抵消** ⇒ **二通道 parity 结构上看不见这一类变异**。

⇒ 结论：**「两通道共用谓词」这类变异只能靠 ①绝对断言（`fall` 的静默断言正是由此观测到 M1b）或
②三通道探针**；单测 parity 不足以证伪它们。归属 **P3（判据升级）**，本格只登记不修。
（归档曾以一份 6 行、`pini check` rc=0 的临时夹具走三通道探针取证判 `CHANGE_OTHER` ⇒ 第三通道是唯一见证者；
该取证件**未入仓**，本格**不重做该取证**——见「未做」条。）

**缺陷二（对照选错，机制已定）：`slice` 不是有效对照。**
M2 让它红了，而这不是对照失效造成的假红 —— 机制 = **同一个内建方法，两通道走不同路线**：
AST 通道的 `slice` 走 **Pini 标准库**（`Common/StdlibPini.swift`，体内就是 `match a: case none: / case _:`），
HIR 通道走**原生 `.sliceCall` 节点**（`HIRLowerer`）⇒ 共用谓词的变异在此**可被见证**，
故 `slice` 在 M2 轮实为「第二个可观测者」；`corpus` 红的是同一机制的 `testDiffSlice`。
教训（供后续格）：**对照必须与变异面正交** —— 选不触碰 match / optional / try / 字面量的纯算术 parity 用例；
`gaps` 12 轮恒绿，合格。

**单源门控的账要写窄**：只有**被打过靶的分支**才可称「由测量门控」——
`matchArmMatches` 的字面量值比较（M1b ✅）· `case _` 通配（M2 ✅）· `builtinGet` 的越界落点（M9 ✅）。
**未单独打靶者**：`matchArmMatches` 的 case 名比较（无轮次）· `builtinGet` 的负索引与字典键相等（无轮次）·
**异类型尾部（M1 ❌ 结构性不可见）**。⇒ 上述未打靶项并入 P3 的判据缺口清单，本格**不补轮次**（规模控制）。

**重放专有的两处口径事故（如实登记，非缺陷但影响证据链）**

① **基线 TSV 被覆盖**：探针明细**恒写死** `/tmp/hir-parity-sweep.tsv`（无 `--out`），而单根 `--filter`
探针与全量探针**共用同一路径** ⇒ 本格动手前那一次单根基线探针把**上一格（G1 收口）留下的全量 308 行
TSV 静默覆盖**。处置 = 回退到**更早一格**的冻结全量基线（`819bac2`），并**按基线 `note` 列的首缺口
节点名逐夹具归因**（上表 79 = 29 + 50 即此法所得）。**已验证该法可信**：把 early 全量基线里
`HIRTests` 子集抽出来是 `OK 34 / TODO 36 / GAP 4`，与 G1 记账的**单根读数逐字相等**
⇒ **子集抽取 ≡ 单根探针**（夹具独立执行，互不影响），故本格**不再补跑单根**，单根读数直接取自全量产物。
已把「跑完立刻改名冻结」写进收口技能。

② **重放基准已变**：归档件的父是**旧 G1 合并点 `3f98079`**，而本格基准是**新 G1 的合并点 `d92f982`**
⇒ 归档的 `git apply --check` 结论**不可迁移**，两处 docstring 冲突即由此而来（已按定式解开）。

**门禁插曲（零语义变更，重放复现）**：本格往 `inRangeFixtures` 上方写的说明段里复述了探针判定名
`HIR_ENGINE_TODO`，被 comment-lint **L5「裸待办」**拦下。原因是 L5 的 pattern 与 L1–L4 不同 ——
**它没有注释锚点**，在 `.swift` / `.pini` 的任意行上匹配 `TODO|FIXME|HACK|XXX`；
该判定名本来只活在 Python 工具里（不被扫），写进 Swift 注释即命中。处置 = 改散文描述
（"engine has not implemented this node yet"），复跑 L1–L6 全绿。

**替上两格补的账（2026-09-14，共 4 处）**：G1 收口时**只往主计划 §13 追加了本格条目**，
全篇的「下一格」指针**一处未扫** ⇒ 四处陈旧（③ 的本件 §8.2 那条，G1 收口改过一条同型的却漏了它；
④ 是 G2 收口的同型遗漏）：
① 主计划载体**顶部「状态」行**仍写「下一格 = P2a 第三格（G1 控制流）」（与 §13 里的「下一格 = G6」互相矛盾）；
② 本件**顶部「状态」行**仍写「已交付 3 格 / 下一格 = G6」；③ 本件 **§8.2 末尾**仍写「下一格 = G1」；
④ 主计划 **§13 的 G4 条目末尾**仍写「下一格 = G2」。
四处均已于本格订正为当前值，并在主计划顶部显式留痕。**教训**：收口回填**不是只写新条目**，
「下一格 / 已交付格数」这类**状态指针散落在多份载体的多处**，必须用 `grep -n '下一格 = '` **全篇扫**再逐条改；
已写进收口技能（§3 plan 回填）。

**未做**：未改 AST / LLVM 侧实现（缺陷一只登记不修）；未补语料夹具（归档的取证件不入仓，本格不重做该取证）；
未补变异轮次（未打靶分支转 P3）；未动契约节点集；未收窄探针 `GAP_HIR_ENGINE` 判据
（该计数器收窄时机仍为上交给决策点）；未修 G6 之外任何节点；未 push。
⇒ ~~**下一格 = P2a 第五格（G5 具名类型与字段，3 缺口：`construct` / `fieldGet` / `fieldStore`）**~~
⇒ **已点名并交付（2026-09-14），见 §8.5**。

### 8.5 G5 具名类型与字段（P2a 第 5 格，2026-09-14，分支 `agent/pini-dev/hir-p2a-g5-named-types`）

> **本格不是重放。** 归档草案 `86fdafd`（父 = `8089c0b`）是 **TDD 红灯态**：测试按完成态写、
> 必然红，而 dispatch **三行原样未接线**（注册表差集实测：三份 `notImplemented` 打靶点各 23 个、
> 双向差集皆空）⇒ **没有「已交付的东西」可重放**，只有**素材可复用**。
> 与 G6（§8.4，归档=完整交付、工作=复现+重测）**质上不同**：G5 的工作 = **复用素材 + 补完 + 全流程验证**。
> 归档分支已改名 `archive/g5-parked-draft`（原名 `…-g5-named-types` 名不副实，本格去掉 `-replay` 后缀）。
> 归档自我声明的两处**不实**已复核订正，见本节末「归档声明复核」。

**范围**：格内 **3 节点**（`construct` / `fieldGet` / `fieldStore`，契约 §2.26/28 + §3.15）。
**但实测夹具面 = 30 个，远大于规划的 3 缺口** ⇒ 引出下面两条范围订正。

**范围订正一（`D-P2-8` 候选）：格内**必须**扩入「类型方法解析」——这是本格最大的结构性发现。**
按五步模板第 1 步实测 30 个夹具的**能力需求**：**21/30 需要类型方法调用**。机制 = 方法**不是**模块级函数，
降载器把 `接收者.方法(…)` 编成 `call(方法__类型, [接收者, …])`，被调者名活在**一张本引擎没有的表**里
⇒ 不扩入则在格内**结构性无法转绿**。这是与 G1 的 `stringConcat` **同型**的**范围订正**：
节点清单**没错**，被低估的是**可达性**。表按**降载后的名字**建，**不在本侧重新 mangle**
（泛型方法活在特化名下，重导即第二份会漂移的真相源）。

**范围订正二（本格**上交**的取舍）：裸内建 callee **不解析**，代价经实测登记并已立单。**
按上述测定，其余 **2/30 需要裸内建**（`sqrt`），故曾评估「引入受限委托」以覆盖它们。
**裁决 = 不做**，四条依据：① 类型方法表 21/30 **必需**，而委托只值 2/30；
② **风险不对称** —— 委托会让**内建 IO 提前在 HIR 通道可跑**，而 IO 语义**尚未裁齐两侧**（G9 前置有裁决格）；
③ **可逆性** —— 纯增量，G7/G3 再加成本一样、不返工；
④ **单源**：在引擎里重写 `sqrt` 会是它的第二份定义。
⇒ 那 2 个夹具**不解析**，**归属缺口已立独立工单**
（`docs/issue-hir-builtin-callee-unowned-2026-09-14.md`）：本项是**被调者解析规则**而**非节点族**，
九格按节点族切 ⇒ **无一格天然拥有它**，故**不塞给任何一格**，留作独立边界待裁。

⚠️ **代价比开工预测更糟（如实登记）**：开工时预期这 2 个夹具「仍停在待办列表」。实测是它们
**从待办列表向上迁移成 `GAP_EXEC` 翻转阻塞**（`construct` 通了 ⇒ 夹具走得更远、死在 `call` 节点），
`FLIP BLOCKERS` 由此 **23 → 25**。机制与既有 `E7-001` 假阳性族**不同**：本项是**实质失败**（`rc` 非零）。

| 面 | 前（G6 收口 `b26c797`） | 后（本格 `d8c7e7f`） |
|---|---|---|
| `notImplemented` 打靶点 | 23 | **20**（双向差集 = **恰好三个节点名**，无反向退出） |
| 全量探针 | `OK 181` / `TODO 62` / `GAP_EXEC 3` / `BLOCKERS 23` | **`OK 208`** / **`TODO 33`** / **`GAP_EXEC 5`** / **`BLOCKERS 25`** |
| 逐夹具对账 | — | **29 处迁移全部归因，0 未归因**；分母 308=308、仅前/仅后皆 0 |
| 全量回归 | 1251 / 3 skipped / 0 failed + 45 | **1252 / 3 / 0 + 45** |
| 契约核验 | `clean` | **`clean`**（三锚点各 **60/60**） |

29 处迁移 = **27 个 `HIR_ENGINE_TODO → OK`**（本格交付）+ **2 个 `HIR_ENGINE_TODO → GAP_EXEC`**（上述代价）。
阻塞槽身份另核：**新增 2 个面孔、0 个离去** —— 即「+2」全部是这两个夹具，**无既有阻塞被掩盖成绿**。

**本格夹具面（四根，实测 30 个，全部首缺口 `construct`；`fieldGet`/`fieldStore` 首缺口各 0 = 被遮蔽）**：
`IRExecutionTests` 11 · 差分 `HIRTests` 9 · `examples` 6 · `IRPrintGoldenTests` 4。

**变异反证（两级 + 对照；器械 `/tmp/g5-mutation.py`，零仓库污染）**
**先提交后变异**（家法：变异实验先提交再做；`d8c7e7f` 为基线，文档回填**另提交** —— §8.5 必须记录变异结果）。
器械四条机制：锚点唯一性预检（三锚点实测各 1）· 墙钟上限 300s（超时记 `HANG` 而非整轮崩）·
**每轮独立 md5 还原校验**（+ `os.utime` 推 mtime，防 llbuild 拿变异版缓存回答案）· **失败原因随红一起抓**。

| 轮次 | 红 | 归因理由（实测原文） |
|---|---|---|
| **L0 对照**（不变异） | **0** | 基线全绿 |
| **L1 整族禁用**（文件回退到 `b26c797`） | **3** | corpus 报 `node 'construct'`（**首个撞上**）/ unreachable 报 `node 'fieldGet'` |
| **L2a `construct` 禁** | 3 | 三个用例**都**报 `node 'construct'` ✅ |
| **L2b `fieldGet` 禁** | 3 | 三个用例**都**报 `node 'fieldGet'` ✅ |
| **L2c `fieldStore` 禁** | 3 | 报 `node 'fieldStore'` ✅；unreachable **红在第二个探针**（「非具名接收者的写」）——正是覆盖 `fieldStore` 的那个 ✅ |

**四轮判定全对**：覆盖该族的 3 个用例全红、**其余 22 个每轮全绿**（无越界红 ⇒ 变异不扰动无关判据）、
每轮理由**准确点名被禁节点**、每轮还原后 md5 与冻结基线**逐字节一致**；跑完复核工作树与 `d8c7e7f`
**逐字节一致**（`git diff HEAD` 对 Sources/Tests 为空）。

⚠️ **判据局限（如实登记，不装作已闭合）**：三个单节点变异**红集合完全相同** —— 因为那 3 个用例
**各自同时触及三个节点**（1 个语料遍历型 + 2 个手写复合探针）⇒ **光看红/绿集合会误判「三节点无法区分」**；
真正的区分力**只在失败原因文本里**。更深一层的「节点级判别」需换仪器（把变异引擎重建进探针二进制、
看**首缺口节点名**分布），**属可选加强、超出两级判据的要求** ⇒ 本格**不做**（规模控制），只登记。
L1 另有附带收获：它**操作性地演示了「首缺口遮蔽」模型** —— 同一用例在整族禁用时报 `construct`、
在单禁 `fieldGet` 时报 `fieldGet`，使「首个撞上的节点遮住后面的」从推断变为**可复现现象**。

**归档声明复核（三类声明各一实证，本件第三类）**：归档草案对本格的自我声明有**两处不实**。
① **docstring 声称「具名族已实现」** —— 实测 dispatch 三行原样未接线（差集空），是**凭空声明**；
处置 = 在 `HIRExecutor` 文件头按**如实描述**改写（本格子句 + 范围订正说明）。
② **声称 `copyIfStruct` 洞「Filed as a defect with its own ticket」** —— `docs/` 下**零工单命中**，是**假声明**；
处置 = **真正立案** `docs/issue-hir-struct-copy-missing-2026-09-14.md`，并把该处引用改为真实指向。
③ **夹具清单只覆盖整体面的 30%**：注释称「These nine are **exactly** the fixtures whose first gap was
`construct`」—— 该句在**语境内（只算差分夹具）没说错**（差分层恰 9 个），但**作为整体面只覆盖 30%**
（实测 30 个）。⇒ 教训：**归档自己给的夹具清单只能当线索，不能当边界**，本格按**实测**取 30。
（三类声明的另两个实证见 §8.3 门控声明、§8.4 与主计划；G5 一类属**本件**。）

**顺带处置的三项（零语义变更）**：
① **测试文件解冲突时删去归档的复合用例** `testEscapingControlFlowAndPanicTrapStayLoud` ——
它与 ours 中 G1 重放新增的两个**更精确**用例重复且**更弱**（其 break 半边正是 G1 变异轮证明
「对禁用骨架也通过」的弱断言形态：throw + 无输出，骨架节点同时满足两者）；
panic 半边的「不继续执行」则由**结构**保证（`run` 抛出后不可能有后续语句执行）。理由留在说明段。
② **`statementGaps` 表删除而非留空**：其最后一项是 `fieldStore`（本格实现），而**空表循环断言虚无** ——
正是本文件存在的意义所要避免的失败模式；该侧改由「dispatch 无 `default:` ⇒ 缺 case 即编译错」等四条支撑。
③ **`inRangeFixtures` 白名单净增 1**：入 8 个首缺口为 `construct` 的夹具，**出** `testDiffStructValue`
（它现在停在无主的内建 callee 上，留在名单里就是该名单存在的意义所要防的**虚假声明**）。

**未做**：未修非阻塞缺陷（`copyIfStruct` 洞、内建 callee 归属均**只立案不修**）；
未改探针阻塞/缺口计数器判据（**收窄时机仍为上交给决策点**）；未动契约节点集；
未改 AST / LLVM 侧实现；未补语料夹具；未做「节点级变异判别」的可选加强；未 push。

## 9. 决策记录

| 编号 | 决策点 | 裁决（2026-09-13，用户） |
|---|---|---|
| **D-P2-1** | 分歧面排期 | **后置为 P2b**，前置 = 两侧裁齐（既有登记，无需新裁决） |
| **D-P2-2** | 族边界 | **以契约 §2/§3 分节为准** |
| **D-P2-3** | 第一格 | **G4 集合与下标的容器侧** |
| D-P2-4 | P2 判据形态 | **三态**（`OK` / `CHANGE_*` / 阻塞槽）；分层读数，不合并成单一数字（§2.1–2.2） |
| **D-P2-5** | G4 的 `lenCall`/`sliceCall` 是否随其 `String` 侧后置 | **不后置**：两节点在 P2a **整节点**实现（镜像解释器 = 契约的 grapheme 语义），其 `String` 侧分歧仍作为**已登记的 B 组差异**保留，P2a 验收对这两节点在非 ASCII 语料上记 `CHANGE_*`（D-P2-3 的「容器侧」由此**扩展为整族 7 节点**） |
| **D-P2-6** | G2 的范围：格内两节点之外，F1/F2 两个既有缺陷是否随格修 | **都修，扩为「含标签模型的整个元组族」**（F1 执行侧 `call` 丢返回标签 / F2 降载侧拒绝注解标签绑定与返回类型标签），接受更大范围及其额外的变异证伪要求（实录 §8.2） |
| **D-P2-7** | G1 的缺口数是 5 还是 6（`stringConcat` 归属） | **格内范围判定（非用户裁决）：取 6**。纳入理由 = **夹具依赖**（defer 夹具需字符串拼接构造期望输出），**非契约分类**（契约实归 §2.9「字符串与内建」#41）。**偏离**规划表 §1.1（G1 记 5 / `stringConcat` 列 G7）⇒ 账目后果 P2a 26→27、P2b 18→17，**已登记待确认**（实录 §8.3） |
| **D-P2-8** | 变异反证暴露的弱判据（用例在全部 6 次变异下均不红）怎么处置 | **就地补强断言并复验**（加「不得报 not implemented」断言），不接受「红因正确即放过」（实录 §8.3） |
| **D-P2-9** | 全仓缩进压平（本格连带发现） | **立工单 + 排期 P4 之后**（整仓重排须冻结其他改动）；本格只落 `executeFor` 整函数体 8 空格（实录 §8.3，工单 `docs/issue-swift-source-indent-2026-09-13.md`） |

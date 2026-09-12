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
- **下一步 = P2a 第二格（G2 元组：`tupleConstruct` `tupleIndexGet`），待点名**。
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

## 9. 决策记录

| 编号 | 决策点 | 裁决（2026-09-13，用户） |
|---|---|---|
| **D-P2-1** | 分歧面排期 | **后置为 P2b**，前置 = 两侧裁齐（既有登记，无需新裁决） |
| **D-P2-2** | 族边界 | **以契约 §2/§3 分节为准** |
| **D-P2-3** | 第一格 | **G4 集合与下标的容器侧** |
| D-P2-4 | P2 判据形态 | **三态**（`OK` / `CHANGE_*` / 阻塞槽）；分层读数，不合并成单一数字（§2.1–2.2） |
| **D-P2-5** | G4 的 `lenCall`/`sliceCall` 是否随其 `String` 侧后置 | **不后置**：两节点在 P2a **整节点**实现（镜像解释器 = 契约的 grapheme 语义），其 `String` 侧分歧仍作为**已登记的 B 组差异**保留，P2a 验收对这两节点在非 ASCII 语料上记 `CHANGE_*`（D-P2-3 的「容器侧」由此**扩展为整族 7 节点**） |

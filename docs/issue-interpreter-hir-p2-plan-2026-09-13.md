# Issue：解释器统一 HIR —— P2（分格实现）执行规划

- 状态：**P2a 已全部交付并通过整体验收 —— 六格 27 缺口清零**（G4 集合与下标的 7 节点 · G2 元组族 ·
  G1 控制流 6 节点 · **G6 枚举 · Optional · Result · try 6 节点（2026-09-14 重放交付）** ·
  **G5 具名类型与字段 3 节点（2026-09-14）** · **G3 闭包与函数值 3 节点（2026-09-14）**）；
  ✅ **P2a 收尾全扫已完成（2026-09-14）**：整体验收判据 `J1`–`J4` 全部通过（零孤儿 / 闭合账目 27 /
  零未归属 / 契约 `clean`），剩余面**零未归因**，实录见 §10；
  ⇒ 下一步 = **P2b 三格（G7 / G8 / G9）**，
  前置 = 四张裁决格两侧裁齐（IO 语义 / `stringSplit` / 字符串字节语义 / 取址；
  ⚠️ **四张前置的登记形态有三种，检查项见 §10.4 —— 不可只数工单文件**）。
  ✅ **P2b 三格已全部交付（2026-09-14）**：**G7 ✅**（§8.7）· **G8 ✅**（§8.8）· **G9 ✅**（§8.9，
  首次走通「前置格先行」）⇒ **打靶点 3 → 0，P2 九格无余量**。
  ✅ **`stringSplit` 格已交付（2026-09-15）** —— 四张前置格中第二张落地（IO 语义格是第一张；**窄读：只对齐空 token**），
  实录见本件 §8.10；**其「分隔符语义」另两处偏离属新发现、已另立新单**（见 §8.10 与 §5 拆项段）。
  ⚠️ **本行滞后了三格，由 `stringSplit` 格收口时一并订正（代 G7 / G8 / G9 三格补账）** ——
  三格收口均未回头刷新本顶部行，故它一度停在「下一步 = P2b」。
  规划轮（2026-09-13 早些时候）**只读勘测 + 落盘规划，未改任何源码**；
  G4 实录见 §8.1（范围订正 `D-P2-5`）· G2 见 §8.2（范围 `D-P2-6`）· G1 见 §8.3 ·
  **G6 见 §8.4（重放）** · **G5 见 §8.5（两次范围订正：类型方法解析入格 / 内建 callee 立单）** ·
  **G3 见 §8.6（一条判据认识订正：遮蔽是相对已实现节点集的）** ·
  **整体验收见 §10（含账目改定 27/17）**。
  ⚠️ 本行与主计划载体的同型指针此前在 G1 收口时**漏改**，已由 G6 重放批一并订正（详见 §8.4 末条）；
  自此每格收口按 `grep -n '下一格 = '` **全篇扫**复核（G5 / G3 收口均未再发现新漏项）。
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
| **G1 控制流** | §3.5/8/11/12/13 | `forInStmt` `deferStmt` `breakStmt` `continueStmt` `panicStmt` `stringConcat` | 6 | 无 |
| **G2 元组** | §2.24/25 | `tupleConstruct` `tupleIndexGet` | 2 | 无 |
| **G3 闭包与函数值** | §2.11/12/13 | `closureLiteral` `functionValue` `indirectCall` | 3 | 无 |
| **G4 集合与下标** | §2.18–23 + §3.10 | `arrayLiteral` `dictLiteral` `setLiteral` `subscriptGet` `subscriptStore` `lenCall` `sliceCall` | 7 | **`lenCall`/`sliceCall` 的 `String` 侧**（B 组） |
| **G5 具名类型与字段** | §2.26/28 + §3.15 | `construct` `fieldGet` `fieldStore` | 3 | 无 |
| **G6 枚举 · Optional · Result · try** | §2.15/16/17/27 + §3.9/14 | `resultConstruct` `optionalConstruct` `optionalGet` `enumConstruct` `tryStmt` `matchStmt` | 6 | 无 |
| **G7 字符串与内建** | §2.9 + §2.14/35–42 | `stringCase` `stringContains` `stringSubstring` `stringSplit` `arrayJoin` `interpString` `isAsciiDigit` `printMulti` `assertCall` | 9 | **B 组 4 项 + A 组 1 项（`split`）** |
| **G8 指针与 LazyRef** | §2.7/2.10 | `pointerLoad` `pointerStore` `addressOfVar` `lazyRefConstruct` `lazyRefValue` | 5 | **`addressOfVar`（A/D1）** |
| **G9 IO** | §2.8 | `fileWrite` `fileRead` `readLine` | 3 | **A 组 3 项全部** |

> 契约把**元组**归「集合」（§2.5）、把 **IO** 与 **LazyRef** 各自独立成节（§2.8 / §2.10）；
> 主计划 §7 手写的九格曾把元组归「函数与调用」、IO 并入字符串格。**本件以契约为准**（D-P2-2）。

**账目确认（2026-09-14 P2a 收尾全扫，实测闭合 ⇒ 本表已改数）**：G1 行 **5 → 6**（`stringConcat` 由
`D-P2-7` 从 G7 移入）、G7 行 **10 → 9**（同上扣除）；批次总数随之 **P2a 26 → 27 / P2b 18 → 17**，
**标题里的 44 不变**（44 = 27 + 17）。依据 = 两条独立实测（判据 `J1`/`J2`，脚本
`/tmp/p2a-closeout-check.py`，过程见 §10）：
① **零孤儿** —— 当前 17 个 `notImplemented` 打靶点**全部**属于 G7/G8/G9，无一例外；
② **闭合账目** —— 逐格实现的打靶点减少数 `G4(−7) G2(−2) G1(−6) G6(−6) G5(−3) G3(−3)` 之和
= **27** = 实测总减少（44 → 17）⇒ **P2a 缺口实为 27**。
⇒ 结论：本表此前的 26/18/5/10 **是旧条目分解的残留**（`D-P2-5` 只修了 G4 那一处，
未回改 G1/G7 行），而非另一种合理口径。

**账目更新（2026-09-14 G7 交付后，实测闭合 ⇒ P2b 由 17 改 8）**：G7 行 **9 → 0**（九项全交付，实录 §8.7）；
**P2b 17 → 8**（= G8 5 + G9 3），**总账 44 = 27（P2a 已交付）+ 8（P2b 未交付）+ 9（G7 已交付）不变**。
依据 = 打靶点口径实测：**17 → 8**，且剩余 8 项逐条落名 —— `pointerLoad` `pointerStore` `addressOfVar`
`lazyRefConstruct` `lazyRefValue`（G8）；`fileRead` `fileWrite` `readLine`（G9），**与上表两行完全重合**。
⚠️ **本表上方段落里的「当前 17 个 `notImplemented` 打靶点」是从 P2a 收尾时点看去的读数**，G7 交付后应读 8；
保留原文不改，以免抹掉当时那次对账的证据链（读数一律现测，见 §11）。

**账目更新（2026-09-14 G8 交付后，实测闭合 ⇒ P2b 由 8 改 3）**：G8 行 **5 → 0**（五项全交付，实录 §8.8）；
**P2b 8 → 3**（= G9 3），**总账 44 = 27（P2a 已交付）+ 9（G7 已交付）+ 5（G8 已交付）+ 3（P2b 未交付）**。
依据 = 打靶点口径实测：**8 → 3**，剩余 3 项逐条落名 —— `fileWrite` / `fileRead` / `readLine`（**全部属 G9**），
与上表 G9 行完全重合（判据 `J1` 零孤儿成立）。**闭合账目**（逐夹具）：`OK 236 → 241`（**+5** = 3 份既有夹具
`HIR_ENGINE_TODO → OK` + 2 份新夹具全 `OK`）、`HIR_ENGINE_TODO 9 → 6`（**−3**，**全部**入 `OK`，无余项、
无外移）、其余四类 Δ **全 0**、**`FLIP BLOCKERS 27 → 27`（零新增阻塞）**；夹具面 314 → **316**。
⇒ 至此**三大格只剩 G9 一张**，且 G9 三项**全部**是 §10.4 的「IO 语义格」前置面 ——
**P2b 的剩余体量已全部压在待裁的前置格上**（见 §10.4 开工检查项）。

**账目更新（2026-09-14 G9 交付后，实测闭合 ⇒ P2b 由 3 改 0，三格全交付）**：G9 行 **3 → 0**（三项全交付，实录 §8.9）；
**P2b 3 → 0**，**总账 44 = 27（P2a）+ 9（G7）+ 5（G8）+ 3（G9）= 44，全部交付**。
依据 = 打靶点口径实测：**3 → 0**，且 **`Sources/` 全树已无 `notImplemented` 引用** —— 判据 `J1` 零孤儿由
「17 个打靶点全部落在 P2b 三格」**加强为「已无孤儿可落」**。
**闭合账目**（逐夹具）：`OK 241 → 249`（**+8** = 5 份既有夹具 `HIR_ENGINE_TODO → OK` + 本格 3 份新夹具全 `OK`）、
`HIR_ENGINE_TODO 6 → 0`（**−6**：5 入 `OK`、1 入 `OK_HARNESS`，**无余项、无外移**）、
`OK_HARNESS 3 → 4`（**+1** = 上一句那 1 份，即 `testDiffIoProgramBase`）、
其余四类（`PACKAGE_MEMBER` / `FRONTEND_FAIL` / `GAP_EXEC` / `GAP_HIR_ENGINE`）Δ **全 0**、
**`FLIP BLOCKERS 27 → 27`（零新增、零消失）**；夹具面 316 → **319**（+3 = 本格新夹具）。
⚠️ 本格是 P2b 里唯一「**前置格先行**」的一格：三项全部压在 IO 语义格里 ⇒ 两格**连做**、同分支两提交、各自独立验收（§11）。
⚠️ 本表上方每段的「当前读数」都是**各自时点**的读数，一律保留原文 —— 读数现测，见 §11 开头的口径约定。

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

### P2a —— 无分歧面（27 缺口，先行）

G1 控制流(6) · G2 元组(2) · G3 闭包与函数值(3) · G5 具名类型与字段(3) · G6 枚举族(6) ·
**G4 整族(7)**（`arrayLiteral` `dictLiteral` `setLiteral` `subscriptGet` `subscriptStore`
`lenCall` `sliceCall`）

> ⚠️ **本节条目曾与它自己的批次总数脱节**（2026-09-13 实测）：原文把 G4 写成「容器侧(5)」、
> 把 `lenCall`/`sliceCall` 列入 P2b，逐项相加得 **24 / 20**，而两次标题写的总数是 **26 / 18**。
> **总数才是对的**（5+2+3+3+6+**7** = 26；10+5+3 = 18），条目分解是旧的。
> **`D-P2-5` 取总数**：G4 整族在 P2a 交付，`lenCall`/`sliceCall` 不随字符串侧后置。
> 教训与 §1.1 末注同源：**手写清单会与它的汇总数脱节 ⇒ 开工前重算，别信条目。**
>
> ⚠️⚠️ **后续（2026-09-14 P2a 收尾全扫）：上面那条「取总数」本身也有边界 —— 总数后来自己漂了。**
> `D-P2-5` 只改了 G4 那一处（把 7 节点收回 P2a），**没有回改 G1 行 5 与 G7 行 10**
> ⇒ 「总数」与新条目**在当时就不再自洽**，只是没人重算。随后 `D-P2-7` 又把 `stringConcat`
> 从 G7 移入 G1，漂移再叠一层。本单元按两条实测判据（`J1` 零孤儿 / `J2` 闭合账目）把数**改定为
> 27 / 17**（过程见 §10）。
> ⇒ **真正可靠的不是「条目」也不是「总数」，而是「闭合账目」** —— 即
> **逐格实现的缺口减少数之和，必须等于「起点打靶点数 − 终点打靶点数」**。这条等式两侧都由
> 源码与提交实测，**没有一处来自手写清单**；它一旦成立，清单就不再是承重结构。
> ⇒ **纪律**：**凡「格号 → 缺口清单 → 批次总数」这类三层手写账，开工前重算的不是某一层，
> 而是那条闭合等式**；等式不成立时，先查哪一层被改过而另两层没跟。

**验收**：该格夹具 `HIR_ENGINE_TODO → OK`（三通道逐字等值）+ 全量回归 + 变异反证两级。
**例外（B 组）**：`lenCall`/`sliceCall` 的 `String` 侧是**已登记的** B 组差异（契约要求改的是 LLVM 侧）
⇒ 按契约实现只会落 `CHANGE_*` 槽（非阻塞、也不转 `OK`）；故这两节点在**含非 ASCII 的语料**上验收
须判 `CHANGE_*`。本批的 73 个差分夹具全为 ASCII，实测三臂一致 ⇒ G4 这两节点仍记 `OK`。

### P2b —— 分歧面（17 缺口，后置）

G7 字符串与内建(9) · G8 指针与 LazyRef(5) · G9 IO(3)

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
- ~~**下一步 = P2a 第六格（G3 闭包与函数值，3 缺口：`closureLiteral` / `functionValue` / `indirectCall`），待点名**~~
  ⇒ **已点名并交付（2026-09-14）**，实录见 §8.6。**本格不是重放**（本格无归档草案）⇒ 工作 = 从契约与
  镜像源直接实现 + 全流程验证。格内一条**判据认识订正**（非缺陷）：`indirectCall` 在实现前**从未作为任何
  夹具的首缺口出现**，曾据此推断「结构所致、永不出现」；变异轮**推翻**该推断 —— 遮蔽是**相对于已实现
  节点集**的，不是程序的固有属性（见 §8.6）。
- ✅ **P2a 六格全部交付完毕**（G4 ✅ / G2 ✅ / G1 ✅ / G6 ✅ / G5 ✅ / **G3 ✅**）⇒ **P2a 无余量**。
  下一步 = **P2a 收尾全扫**（六格交付后的整体面对账）→ **P2b 三格（G7 / G8 / G9）**，
  前置 = 四张裁决格两侧裁齐（IO 语义 / `stringSplit` / 字符串字节语义 / 取址）。
  ⇒ **以上已全部完成**：**P2a 收尾全扫 ✅（§10）**；**P2b 三格 ✅** —— **G7 ✅**（实录 §8.7）、
  **G8 ✅**（§8.8）、**G9 ✅**（**收尾格**，§8.9），其中 G9 **首次走通「前置格先行」**：
  其前置的 **IO 语义格与 G9 本格同分支两提交连做、各自独立验收**（规划与裁定见 §11）。
  ⇒ **P2b 至此清空，打靶点 0**（`Sources/` 全树无 `notImplemented` 引用）。
- **下一步 = P3**（需点名）。⚠️ **四张前置格里已做掉两张**（IO 语义格 ✅ 2026-09-14 ·
  **`stringSplit` 格 ✅ 2026-09-15，窄读：只对齐空 token**），其余两张**仍在册未做**
  （与 P2b 无关、不阻塞 P3 之外的面）：**字符串字节语义格**
  （B 组 6 项 → 实测未复现 `arrayJoin` ⇒ 待裁后应减为 5）· **取址格**（`addressOfVar` 快照 → 真引用）。
  ⚠️ **`stringSplit` 的「分隔符语义」不在该格内、已另立新单**（LLVM 侧 `@strtok` ⇒ 分隔符按
  **字符集**解释 + 空分隔符无守卫；待 spec §1.3 裁「子串还是字符集」）—— 见 §8.10 末段。
  更后面：`P0d`（Char 落地）· 字符字面量 `'c'` 格 · 并发 / CPS 格（R2）—— 全景见 §10.4 与本件末。
  ⚠️ **格号不变、面在漂（本件累计三处，逐条见 §8.3 / §8.5 / §8.6）**：`stringConcat` 随 G1 交付
  （`D-P2-7`）⇒ G7 从 10 项扣除；G5 使 `GAP_EXEC` 净增 2（内建 callee 无主）；
  G3 使 `HIR_ENGINE_TODO` 净减 9。**§1.1/§3 的旧数已在 P2a 收尾全扫中正式改定**
  （5→6 / 10→9 / 26→27 / 18→17，依据 = 判据 `J1`/`J2` 的实测闭合，见 §1.1 账目确认与 §10）。
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

**由此产生的账目后果（登记 → 已确认）**：`stringConcat` 自 G7 移入 G1 后，
**P2a 26 → 27 缺口、P2b 18 → 17 缺口**（总 44 不变）。本件**不自行改写** §1.1/§3 的既有数字
（该两处已有「条目分解与总数脱节」的前科，教训见 §3 的 ⚠️），仅在此登记该回归项，待点名下格时一并厘清。
✅ **已厘清（2026-09-14，P2a 收尾全扫）**：§1.1 的 5→6 / 10→9 已按判据 `J1`/`J2` **正式落表**，
27/17 成为定数（见 §1.1 与 §10）；本行「待确认」状态解除。

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

### 8.6 G3 闭包与函数值（P2a 第 6 格，2026-09-14，分支 `agent/pini-dev/hir-p2a-g3-closures`）

> **本格不是重放，也不是补完** —— 归档面无本格任何提交（`G3` 在 main 硬回退窗口之外）
> ⇒ 工作 = **从契约与镜像源直接实现 + 全流程验证**。这是 P2a 六格里唯一**三态皆无**的一格。
> ⚠️ **分支名教训**：`agent/pini-dev/hir-p2a-g5-named-types` 与 `…-g6-enums` 都曾被**归档旧交付占用**
> ⇒ 本格与 G1 一样**另取后缀**（`-closures`），并在建分支前用 `git for-each-ref` 实测占位。

**范围**：格内 **3 节点**（`closureLiteral` §2.13 / `functionValue` §2.12 / `indirectCall` §2.11，
契约 §2.3 一并管辖），**分歧面「无」**（§1.1 原判成立，实测未出现任何 `CHANGE_*`/`GAP_UNKNOWN`）。

**判据认识订正（本格唯一一条，非缺陷）——「首缺口遮蔽」是相对于已实现节点集的。**

格内开工勘测发现：`indirectCall` **从未作为任何夹具的首缺口出现**（前后两次全量扫均如此），
由此曾写成「结构所致、`indirectCall` 永不出现在未实现列表里」并**写进了测试文件的说明注释**。
**变异轮 M4 推翻该结论**：单独禁用 `indirectCall` 后，**全部 8 个夹具都以 `indirectCall` 为首缺口报出**。
⇒ 正确表述 = **遮蔽是相对于「当前已实现节点集」的，不是程序的固有属性**；
「某节点从不作为首缺口出现」在**任何给定的实现状态下**才成立，**该状态一旦改变，结论随之失效**。
测试注释已按此**如实订正**（原稿的绝对化表述已删）。这条订正的价值在**方法层**：
它说明**「未实现列表里没有某节点」不能反推「该节点无夹具覆盖」**，而 §1.2 早记的
「首缺口分布 ≠ 夹具覆盖」**在新维度上再次成立**（那里是「被遮蔽」，这里是「被遮蔽且结论会被实现状态翻转」）。

**实测夹具面（第 1 步，按模板重测，不拿上一格清单做加减）**：**8 个唯一夹具**（去重后）——
`examples` 4（`closures.pini` 20 行 / `higher-order.pini` 9 行 / `lambda.pini` 3 行 / `lambda-typed.pini` 7 行）
\+ 差分 `HIRTests` 4（与上述 4 份**逐字节同源**：md5 两两一致）
\+ `IRExecutionTests/testHigherOrderFunctionValue_LLI.pini`（本根独有）。
**首缺口分布（实现前）**：`closureLiteral` 5 · `functionValue` 3 · `indirectCall` **0**（即上面那条订正的由来）。

| 面 | 前（G5 收口 `d8c7e7f`） | 后（本格） |
|---|---|---|
| `notImplemented` 打靶点 | 20 | **17**（双向差集 = **恰好三个节点名**，无反向退出） |
| 全量探针（6 根 / 308 夹具） | `OK 208` / `TODO 33` / `GAP_EXEC 5` / `GAP_HIR_ENGINE 20` | **`OK 217`** / **`TODO 24`** / `GAP_EXEC 5` / `GAP_HIR_ENGINE 20` |
| 未实现节点集（探针观测） | 12 | **10**（退出 = `closureLiteral` / `functionValue`；`indirectCall` 本就被前两者遮蔽、从未单独出现） |
| 逐夹具对账 | — | **9 处迁移全部归因、0 未归因**；分母 308=308、仅前/仅后皆 **0** |
| 全量回归 | 1252 / 3 skipped / 0 failed + 45 | **1256 / 3 / 0 + 45**（+4 = 本格四个新用例） |
| 族内测试 | `HIRExecutorTests` 25 | **29** / 0 failed；`HIRDifferentialTests` **78** / 0 failed（两族合并 **107 / 0**） |
| 契约核验 | `clean` | **`clean`**（三锚点各 **60/60**） |

9 处迁移 = **9 个 `HIR_ENGINE_TODO → OK`**（`h_rc` 1→0、`h_len` 0→与 `a_len` 相等：
`20/3/7/9/20/3/7/9`）。**0 `behaviour changes` · 0 非终结 · 0 进程泄漏 · 0 残留 `.ll`**。
另做**逃逸闭包探针**（`造加法器` 返回带 `capture` 的匿名 `func`，调用点另有同名 `base`）：
三通道**均输出 `15` 而非 `1005`** ⇒ 「闭包看**创建点**环境」这一语义在**返回之后仍然成立**（帧已退出）。

**实现要点（单源化是本格的主要手法）**：
① 值层**直接复用** `Value.function(FunctionValue)`（其 `closure: Environment` 本就是**共享引用**，
故 `capture` 列表**刻意不用** —— 它就是 no-op，用它会造第二份真相源）；
② `HIRExecutor` 原 `call(_:args:)` 的**全部逻辑**（arity 检查 / `callDepth` 守护 / `Environment(enclosing:)` /
defer 作用域 / `executeStatements` / return 标签展开）**上提**为 `invoke(_:parent:args:)`，
把**父环境改为参数**；`call` 退化为 `invoke(…, parent: globalEnv, …)` 的薄包装 ⇒
**直调与间接调走同一条路径**，不存在「两处各写一遍调用语义」的漂移面。
③ `FunctionValue.body` 是 AST `Block?`、**装不下** `[HIRStmt]` ⇒ 体按**侧表**承载
（`HIRCallableBody{paramNames, body, returnLabels}` + `[ObjectIdentifier: HIRCallableBody]`，
键 = `ObjectIdentifier(FunctionValue)`，与 `Value.==` 对函数值取 `===` 一致）。
**为何按对象身份而非名字**：闭包无独立名字（parser 给每个匿名 `func` 名 `<anon>`）⇒ 按名索引会**互相覆盖**。
`functionValue`（具名函数作值）取 `globalEnv` 为闭包（具名函数是模块级；spec 的
「顶层裸函数」定位见下条），`closureLiteral` 取 `currentEnv`（镜像 `Interpreter.swift` 的 `closure: currentEnv`）。

**变异反证（两级六轮；器械 `/tmp/g3-mutation.py` + `-m6.py`，零仓库污染）**
器械四条机制：锚点唯一性预检 · 墙钟上限（防挂）· **每轮独立 md5 还原对账** ·
**失败原因随红一起抓**。⚠️ 器械首版有**两处缺陷且一度污染工作树**，已当场诊断并订正，见下「记缺陷」①。

| 轮次 | 变异 | 红夹具 | XCTest 失败 | 性质 |
|---|---|---|---|---|
| **M1** | 整个 G3 块回退为 3 个打靶点（整族禁用） | **8** | 4 | 族级 |
| **M2** | 只禁 `closureLiteral` | **8** | 3 | 节点级 |
| **M3** | 只禁 `functionValue` | **4** | 1 | 节点级 |
| **M4** | 只禁 `indirectCall` | **8** | 4 | 节点级 + **推翻遮蔽结论** |
| **M5** | 闭包父环境退回 `globalEnv` | **2**（`closures` + `testDiffClosures`，`GAP_EXEC`） | 3 | **语义级（本格唯一缺口处）** |
| **M6** | 侧表键退化为 `ObjectIdentifier(HIRExecutor.self)` | **2**（`GAP_BEHAVIOR`） | 2 | **身份键规则** |

**六轮的区分力论证（本格判据强度的核心）**：
- **M5 最有价值**：它只对**含 `capture` 的**夹具生效（`lambda` / `higher-order` **全绿**）
  ⇒ 证明手写用例 `testAClosureSeesItsCreatingEnvironmentNotItsCallSite` 与
  `testACaptureIsAReferenceNotASnapshot` **对「创建点环境」有独立区分力**（这正是本格**唯一的实现风险点**）。
- **M6 证明「按对象身份索引」不是任意选择**：键退化后 `testTwoClosuresDoNotShareOneBody` 转红
  ⇒ 该规则**有判据**（若照名字索引，两个匿名闭包会互相覆盖而没有测试会红 —— 那是**假绿**）。
- **M2/M4 都是 8 红**（全夹具）而 **M3 只 4 红** —— 与**首缺口分布**一致（`closureLiteral` 5 + `functionValue` 3
  ⇒ 禁前者命中全部 8、禁后者命中 3+1）；红集合**不等**恰恰说明三节点**可分辨**，
  与 G5「三节点红集合完全相同」的局限**相反**（§8.5）：本格夹具面**分层清晰**（各夹具只撞一个节点）。
- 每轮**还原后 md5 与冻结基线逐字节一致**；跑完复核工作树与 `23b5bc0` **逐字节一致**。

**记缺陷（本格）**
① ⚠️ **器械侧（已当场修，不入册）**：变异脚本首版两处缺陷 —— (a) 构建成功判据写成
`"Build complete!" in out`，而 Swift 实际输出 `Build of product 'pini' complete!` ⇒ **每轮误判失败并
`continue`**，5 轮全报「0 红」而**跳过还原**；(b) 由 (a) 导致的 `continue` 使**工作树留下一轮变异未还原**。
**当场处置** = 诊断 → 手工还原该处 → `grep` 核实无残留 → **重写脚本**（判据改
`popen returncode`、还原放进 `finally` 含外层、加「变异必须改变 md5」自检、加「TSV 缺失」显式报错
而非静默 `continue`）。**教训**：**「变异全绿」与「变异根本没生效」在读数上同形** ⇒
判据里必须有一条**独立**的「变异确实生效」自检。
② **无新增工单** —— 与 G5（两条：`copyIfStruct` 洞 / 内建 callee 无主）不同，本格**未发现需立案的缺陷**：
`captureMarker` 原就是 no-op（无需改）；`indirectCall` 遮蔽为**判据认识**问题、已在测试注释**就地订正**；
逃逸闭包语义**三通道一致**（无缺陷）。同题工单检索（`closure|functionValue|indirectCall|higher-order`）
命中的 5 份**均为计划/审计件**，无既存同题工单。
③ **一次性探针的负结果如实登记**：**嵌套具名函数声明不受支持**（函数体内写 `inner|func(…)` 报
E2-006 `invalid expression`，三通道一致）。经查 **spec 既定**（`名称|func` 是**顶层裸函数**构造，
`top-level-decl` 只含 import/export；类型体内亦禁止函数声明）⇒ **非缺陷、不立案**；
记在此处只为**免除下一次重复勘测**。

**顺带处置（零语义变更）**：`expressionGaps` 表**删除** `closureLiteral` 项（实现后该断言必红），
并在同处补说明「删了为何仍算覆盖」；`inRangeFixtures` 白名单**净增 4**（四份 G3 夹具），
其注释按上述 M4 结论**订正**（原稿的绝对化表述已删）。

**未做**：未修非阻塞缺陷（本格**无新缺陷**；既有 `copyIfStruct` 洞 / 内建 callee 归属**仍只立案不修**）；
未改探针阻塞/缺口计数器判据（**收窄时机仍为上交给决策点**）；未动契约节点集；
未改 AST / LLVM 侧实现（LLVM 侧三节点**本就已完整实现**，本格零改动）；
未补语料夹具；未做「节点级变异判别」的可选加强；未 push。

### 8.7 G7 字符串与内建（P2b 第 1 格，2026-09-14，分支 `agent/pini-dev/hir-p2b-g7-strings`）

> **本格是 P2b 的第一格，也是第一次执行「分歧面」单元。** 与 P2a 六格的最大差别不在规模，而在
> **判据的可达性**：九节点里有的照契约实现即落 `OK`，有的（B 组）照契约实现**也落不进 `OK`** ——
> 契约要求改的是 LLVM 侧。这一区分在 §2.2 已立，本格是它的首次执行，实测结果见 ④。

**① 起点实测（五步第 1 步，不拿上一格清单做加减）**

独立重跑全量探针，产物 `/tmp/g7-before.tsv` 与冻结件 `/tmp/g3-post-full.tsv` **md5 逐字节一致**
（`ee91b12fafd80edaa177786dba68d58b`）⇒ 冻结件有效、结论可复现。本格基准：**308 夹具**，
`OK 217` / `HIR_ENGINE_TODO 24` / `GAP_EXEC 5` / `FLIP BLOCKERS 25`；打靶点（`throw notImplemented`）
**17**，其中 G7 占 **9**。

**② 夹具面（五步第 2 步）—— 实测与原估有一处实质差异，且发现两处零覆盖**

- 新建 4 个**单节点**夹具：`testDiffStringCase` / `testDiffStringContains` / `testDiffStringSubstring` /
  `testDiffStringSplit`。各恰一种算子（实测 `upper`×3 `lower`×3 / `contains`×8 / `substring`×5 / `split`×4，
  四者互不叠）。
- 一项已可达：`interpString` ← `testDiffLexical`；`arrayJoin` ← `testDiffArrayJoin`（5 处 `join`）；
  `isAsciiDigit` ← `testDiffIsAsciiDigit`（3 处）—— ⚠️ 后者是**自由函数形式** `is_ascii_digit(s)`，
  不是方法调用；按 `.is_ascii_digit(` 检索会得到零命中并**误判为无覆盖**（本格实测踩到）。
- ⚠️ **两项零覆盖（本格最重要的发现）**：`printMulti` 与 `assertCall`。前者仅由 **≥2 参** `print` 下沉
  （单参走 `printCall`），而全差分语料**每一条都是单参**；后者全差分语料**一次都没调用** `assert`。
  二者此前唯一的证据是 `expressionGaps` 里那两条**合成单节点探针** —— 也就是本格为实现而必须删掉的条目。
  ⇒ **「删除探针」与「建立覆盖」是两件不同的事**：若只删不补，红变绿的同时**判据被悄悄抽空**
  （探针「误报」换成静默「看起来像覆盖」）。已补 `testDiffPrintMultiArgs` + `testDiffPassingAssert`
  两份夹具，并把 `assertCall` 的失败态放到 Swift 侧手写用例（下述）。

**③ 实现（五步第 3 步）**

九个打靶点替换为**镜像解释器**的实现（`HIRExecutor.swift`，约 +230 行），并提两个私有 helper
（`requireString` / `requireInt`）。语义决定：
- `stringSubstring` 按**契约 §2.38** 取 `(start, end)`；节点侧枚举标签写作 `length` 是**误导侧**，照契约；
- `stringSplit` 按**契约 §2.39 A4**：**跳过空 token**、空分隔符 → 逐 grapheme；
- `printMulti` 分隔符取**空格**、`outputSink` 收**内容不含换行**（与解释器 `args.map { stringify($0) }
  .joined(separator: " ")` 同源同形）；
- **刻意不动解释器侧**：`stringSplit` 的空 token 语义在语言 spec 尚未钉死，且其对齐载体
  （`stringSplit` 格）**已在册待排期** ⇒ 按「不顺手改」纪律，解释器侧留给该格，本格只在 HIR 侧照契约实现。

**④ 验证（五步第 4 步）—— 闭合账目（逐夹具，非总数）**

| 判定 | before | after | Δ | 归因 |
|---|---|---|---|---|
| `OK` | 217 | 236 | **+19** | 13 份既有夹具 `HIR_ENGINE_TODO → OK` + 6 份新夹具全 `OK` |
| `HIR_ENGINE_TODO` | 24 | 9 | **−15** | 13 → `OK`，2 → `GAP_EXEC`（见下） |
| `GAP_EXEC` | 5 | 7 | **+2** | `testDiffStdlib` + `examples/stdlib.pini`，**由缺口外移，非本格引入** |
| 其余五类（`FRONTEND_FAIL` / `GAP_HIR_ENGINE` / `OK_HARNESS` / `PACKAGE_MEMBER` / `FLIP BLOCKERS` 的分项） | — | — | **全部 0** | — |

**闭合等式成立**：离开 `HIR_ENGINE_TODO` 的 15 份 = 13 入 `OK` + 2 入 `GAP_EXEC`，无余项、无失衡。
夹具面 308 → **314**（+6：4 份字符串 + 2 份补覆盖）= 300 pre-existing unchanged + 6 new + ... 逐条可对上，
无夹具消失。**打靶点 17 → 8**，剩余 8 = G8 五项（`pointerLoad` `pointerStore` `addressOfVar`
`lazyRefConstruct` `lazyRefValue`）+ G9 三项（`fileRead` `fileWrite` `readLine`），**与 P2b 定义完全重合**。

**`J1` 零孤儿**：剩余 9 份 `HIR_ENGINE_TODO` 夹具命名的 4 个节点（`fileWrite` 3 / `lazyRefConstruct` 3 /
`readLine` 2 / `fileRead` 1）**全部属 P2b**。
**`J4` 契约恒定**：`hir-contract-check.py` 仍 `clean`，`llvm` / `printer` / `interp-hir` 三锚点 **60/60**。

**⑤ 阻塞槽复核（`FLIP BLOCKERS` 25 → 27）**

20 个 `GAP_HIR_ENGINE` **零变动**（仍全部为 `E7-001` 假阳性）⇒ 本格**未新增**该类槽，无需新的逐字复验。
新增的 2 个在 `GAP_EXEC` 侧，错误码 **`E5-006`（invalidOperation）**，即**「裸内建 callee 无主」**：
`testDiffStdlib` / `examples/stdlib.pini` 的字符串部分**实测正确输出**（`HELLO, WORLD` / `hello, world` /
`Hello` / `[Hello,  World]` / `a-b-c`）后才死在 `abs`。该迁移（`HIR_ENGINE_TODO → GAP_EXEC`，`E5-006`）
**已被既有工单 `docs/issue-hir-builtin-callee-unowned-2026-09-14.md` 明文预言**，且该单已裁决
**不排期、不并入 G7** ⇒ **本格零新增缺陷**。
⚠️ 口径提醒：该单自记 `FLIP BLOCKERS 23 → 25`，本格实测 `25 → 27` —— **绝对数在不同快照间会漂，
可对账的是增量（都是 +2）**（与 §11 的「总数自己也会漂」同型）。

**顺带处置（零语义变更）**

- `expressionGaps` 表**删除** `printMulti` / `stringCase` / `interpString` 三条（实现后该断言必红，
  首次全量回归的 4 个失败**全部出自这一个测试**），并在同处补说明「删了为何仍算覆盖」+ 记录零覆盖发现；
- `inRangeFixtures` 白名单**净增 9**（4 份字符串 + `testDiffArrayJoin` / `testDiffIsAsciiDigit` /
  `testDiffLexical` + 2 份补覆盖），并就地记下**搁置**的 `testDiffStdlib` / `examples/stdlib.pini`
  与搁置理由（同样是内建 callee 归属）；
- 新增 `HIRExecutorTests.testAssertCallFailureIsAssertionFailedNotAGap`：断言失败态是
  `RuntimeError.assertionFailed`、携带源码消息、**且不是 `notImplemented`**（后者是弱判据的反面 ——
  「未实现」也抛错，只断言「抛了」等于没断言，`D-P2-8` 同型）。

**两条范围声明（写成范围，不写成遗漏）**

- `testDiffPassingAssert` **只覆盖通过态**：失败态在 LLVM 臂会 abort，而 `assertParity` 要求 `lli` 退出 0
  ⇒ 该半**结构性地**放不进差分语料，归 Swift 手写用例（与 G3「夹具覆盖不了的那条规则由手写用例钉」同型）。
- `testDiffMultiArgPrint` **只取标量操作数**：多参 print 里的**聚合值**是 LLVM 臂的**已关闭设计边界**
  （`emitPrintMulti` 对 `hasNoScalarRendering` 的类型直接 `bk_panic` + `unreachable`），
  有归档件 `docs/spec/issue/archive/issue-hir-aggregate-value-print-2026-09-10.md` ⇒ **非缺陷、不立单**。
  本格为此做了二分实测（String+I32 / Bool / F64 均通，`[1, 2]` 触 `lli` abort）后才定为范围。

**本格未做**：未修任何非阻塞缺陷；未改探针的阻塞/缺口计数器判据（**收窄时机仍为上交给决策点**）；
未动契约节点集；未改 AST 侧实现；未动 LLVM 侧（本格零 LLVM 改动）；未 push。
**本格新发现（只登记不修）**：`ConcurrencyTests.testConcurrentTasksOverlapInTime` 的墙钟断言
（阈值 0.11 s）在**全量并行负载**下实测 0.112 s 而红，**单独复跑 35/35 全绿** ⇒ 时序脆弱，与本格无关，
立单 `docs/issue-concurrency-timing-test-fragile-2026-09-14.md`。

### 8.8 G8 指针与 LazyRef（P2b 第 2 格，2026-09-14，分支 `agent/pini-dev/hir-p2b-g8-pointer-lazyref`）

> **本格的取向由用户裁决为「把阻塞疏通」**：**不接受因阻塞而缩小交付范围** ⇒ 五节点全做，
> 并对两处「照契约做会落阻塞」的语义**取镜像解释器口径**，把真正的对齐留给对应的前置格。
> 这是与 G7 最大的差别：**G7 的阻塞来自别人**（无主 callee，本格无法修），**本格的阻塞来自自己**
> （口径选择）—— 后者可以被范围声明消解，前者不可以。

**① 起点实测（五步第 1 步，不拿上一格清单做加减）**

重跑全量探针，得本格基准：**314 夹具**，`OK 236` / `HIR_ENGINE_TODO 9` / `GAP_EXEC 7` /
`GAP_HIR_ENGINE 20` / `FRONTEND_FAIL 12` / `PACKAGE_MEMBER 27` / `OK_HARNESS 3`；`FLIP BLOCKERS 27`。
**打靶点 8**（G8 五 + G9 三）。

⚠️ **本节记一次器械侧翻车（可复用的判据纪律）**：本格起初拿 `/tmp/g3-post-full.tsv` 当冻结件对账，
得 md5 不一致（`b36de334…` vs `eec582ef…`）。查因 ⇒ **那份备份其实是 G7 之前的残留**
（其中 `stringSplit` 仍是 `HIR_ENGINE_TODO`、`testDiffStringSplit` 仍是 TODO），三处 diff **恰好都是
G7 的交付效果**。⇒ **冻结件不能只认 mtime，必须与 `state-readings.json` 的记录对账**；
本次实测与 `hir_probe` 条逐槽吻合 ⇒ **以本次实测为有效基线**，旧备份作废。

**② 夹具面（五步第 2 步）—— 最重要的结构性发现：指针三节点此前零可达夹具**

- **LazyRef 半已可达**：3 份（`testDiffLazyRef` / `testLazyRefValueTripleBackendsAgree` / `examples/lazyref.pini`）。
- **指针半零可达**：G8 三个指针节点（`pointerLoad` `pointerStore` `addressOfVar`）**此前没有任何夹具到达过**。
  唯二两个「看起来是见证者」的 `examples/ffi.pini` / `examples/struct.pini` **都死在 `E5-006`
  （裸内建 callee 无主）**：`struct.pini` 打印完前两行后死在 `sqrt`；`ffi.pini` 第一句 `unsafe malloc(64)`
  就死，`store` / `load` / `&x` **一次都没走到**。⇒ 见「本格新发现」第 1 条的**归属订正**。
- **降载侧可达性实测确认**（否则新夹具写不出来）：`load` / `store` / `&x` 在
  `HIRLowerer.swift:2297/2313/2645` 成**专节点**（不经被调者解析），`.unsafe` 降载透明（`:2622-2626`）。
- ⇒ 新写 2 份夹具：`testDiffPointerLoad.pini`（`var x: I64 = 7` / `var px = unsafe &x` /
  `print(unsafe load(px))`）与 `testDiffPointerStore.pini`（+ `unsafe store(px, 42)` + 再次 `load`）。
  **这是本格唯一能到达节点的链路** —— 绕开了无主 callee。

**③ 实现（五步第 3 步）—— 镜像解释器，且以「单源化」为主要手法**

五处打靶点替换为完整实现（`HIRExecutor.swift`，+111 行）。两处单源化：

- **`Interpreter.snapshotPointer` / `decodePointer` / `encode` 由 `private func` 提为 `static func`**
  （internal），供 `HIRExecutor` 直接复用 ⇒ 指针语义**只有一份源**，HIR 侧不另写一套；（4 个原调用点
  `self.` → `Self.`）
- **把间接调用臂里内联的「侧表查找 + 父环境取 `function.closure`」提为 `callFunctionValue(_:args:)`**
  ⇒ `indirectCall`（G3 已交付）与 `lazyRefValue` 的**首次求值共用同一条调用路径**，函数值不再有第二条调用语义。

**为什么 `addressOfVar` 取「快照」而不是契约写的「真引用」**（本格唯一的语义取舍，机理已查明）：
`Environment.Binding` 是 `[[String: Binding]]` 里的**值类型**（`Environment.swift:4-9`，`assign` 每次重建
Binding）⇒ **没有稳定存储槽**，真引用需要**装箱改造**，而该类型是 **AST / HIR 共用**的；
更要紧的是：**照契约做真引用会把判据从非阻塞翻成阻塞** —— HIR 侧真引用 ≠ AST 侧快照 ⇒ 落 `GAP_UNKNOWN`
= `FLIP BLOCKER`。⇒ 属**止损范畴**，留给已在册的**取址格**（§10.4 第四行）。同理 `pointerLoad` 的 `*U8`
按 `Int8` 解码（`Interpreter.decodePointer` 对 `I8`/`U8` 同一路；契约 §2.29 自标该组为半语义）⇒
**不背离冻结参照**。

**④ 验证（五步第 4 步）—— 闭合账目（逐夹具，非总数）**

| 判定 | before | after | Δ | 归因 |
|---|---|---|---|---|
| `OK` | 236 | 241 | **+5** | 3 份既有夹具 `HIR_ENGINE_TODO → OK` + 2 份新夹具全 `OK` |
| `HIR_ENGINE_TODO` | 9 | 6 | **−3** | 3 份**全部**入 `OK`，无余项、无外移 |
| `FLIP BLOCKERS` | 27 | 27 | **0** | ⭐ **零新增阻塞 —— 这正是用户所要求的「疏通」的度量** |
| 其余四类（`GAP_EXEC` / `GAP_HIR_ENGINE` / `FRONTEND_FAIL` / `OK_HARNESS` / `PACKAGE_MEMBER`） | — | — | **全部 0** | — |

**闭合等式成立**：离开 `HIR_ENGINE_TODO` 的 3 份 == 入 `OK` 的 3 份（既有夹具口径），无余项。
夹具面 314 → **316**。**打靶点 8 → 3**，剩余 3 = `fileWrite` / `fileRead` / `readLine`（**全部属 G9**）。
**`J1` 零孤儿**成立。**`J4` 契约恒定**：`hir-contract-check.py` 仍 `clean`，三锚点 **60/60**。

**全量回归**：`HIR(Executor|Differential)Tests` **116 tests / 0 failures**；
全量 **1265 tests / 3 skipped / 0 failures**（G7 基线 1263，**+2 = 两份新差分用例**，已对账）；
swift-testing 45 tests / 14 suites 通过；`comment-lint L1–L6 全绿`。

**⑤ 变异反证两级（五步第 5 步，脚本 `/tmp/g8-mutation.py`，6 轮）**

| 轮 | 变异面 | `OK` / `TODO` | moved | 判据 |
|---|---|---|---|---|
| 基线 | — | 241 / 6 | — | — |
| **家族级**（5 节点齐禁） | 5 | **236** / 11 | **5** | ✅ **`OK` 精确回退到 236 = G8 前基线**；多出的 2 条 TODO 正是**两份新夹具**（基线中不存在）⇒ 归因闭合 |
| `pointerLoad` | 1 | 239 / 8 | 2 | 与 store 夹具共享（store 夹具内含 `load` 读回） |
| `pointerStore` | 1 | 240 / 7 | **1** | ✅ **唯一可分离者**：只红 `testDiffPointerStore.pini`，不外溢 |
| `addressOfVar` | 1 | 239 / 8 | 2 | 与 `pointerLoad` 同集合 ⇒ **共享面，不可分离** |
| `lazyRefConstruct` | 1 | 238 / 9 | 3 | 3 份 LazyRef 夹具 |
| `lazyRefValue` | 1 | 238 / 9 | 3 | 同上（一对共享） |

- **六轮其余五槽（`GAP_HIR_ENGINE` 20 / `FRONTEND_FAIL` 12 / `GAP_EXEC` 7 / `OK_HARNESS` 3 /
  `PACKAGE_MEMBER` 27）Δ 全 0** ⇒ **变异不外溢**（这正是单节点级「只红对应夹具」的可测形式）。
- **自检**：六轮 md5 依次 `56329fd7` / `5135f9ec` / `3afd6b32` / `39a9acbb` / `e31466dd` / `45ba8a41`，
  **均 ≠ 原 md5** ⇒ 「变异确实生效」自检通过（否则「全绿」与「没生效」同形）。
- **还原**：`finally` 内还原 + 实测 `md5 073c05d8960ae4eabf3c1a0cfbcaf012`（**byte-identical**）。
- **不可分离性是被实测的、不是被假设的**：脚本**先打印 red set 再下结论**（`&x` 必须先产出指针，
  `load`/`store` 才有对象）⇒ 「这两者无法靠红集分开」是可测量的断言，而非默认前提。

**两条范围声明（写成范围，不写成遗漏）**

- **指针夹具范围 = 标量 `I64`，且写穿指针后不再读*变量***。两条限制是**同一条边界的两面**：
  AST 臂快照 vs LLVM 臂可能真引用，**只有**在写穿后读*变量*时才分歧；窄元素类型同理（快照路径从**值**
  推元素类型、降载侧从**声明**推，只在声明宽度窄于值宽度时才分歧）。⇒ 收窄是为了**量指针节点**，
  而不是量「快照 / 真引用」分歧 —— 后者属取址格。
- **`addressOfVar` 的半语义不进本格判据**：见 ③，真引用口径属取址格。

**本格未做**：未碰**取址格** / 未改 `Environment` 装箱 / 未动解释器行为与 LLVM 侧（本格零 LLVM 改动）·
未修 `E5-006` 无主 callee · 未改契约节点集 · 未改探针的阻塞 / 缺口计数器判据（**收窄时机仍为上交给
决策点**）· 未收窄 `GAP_HIR_ENGINE` 口径 · 未 push。

**本格新发现（只登记不修）**

1. **归属订正（非缺陷）**：§10.3 把 2 个 `GAP_EXEC` 记为「**G8 指针/取址面**」= **误归属**。实测两者
   错误码均为 **`E5-006`（裸内建 callee 无主）**，**到不了指针节点**；`struct.pini` 已被既有工单
   `docs/issue-hir-builtin-callee-unowned-2026-09-14.md` 明文列入 ⇒ **非缺陷、不新立单**，只需订正 §10.3
   （**订正已随本格落地**）。
2. **G8 指针半是「零覆盖」而非「低覆盖」**：与 G7 的 `printMulti` / `assertCall` 同族（**「删除探针」≠
   「建立覆盖」**），但更强 —— 那两个是**删掉探针后**才无覆盖，这三个是**从来没有过**可达夹具。
   二者合起来提示一条开工检查项：**逐节点追问「到底有什么可达它」，而不是相信节点在契约里的存在感**。

### 8.9 G9 IO（P2b 第 3 格，也是收尾格，2026-09-14，分支 `agent/pini-dev/hir-io-semantics-g9`）

> **本格是 P2b 里唯一「前置格先行」的一格**：三项**全部**压在 `ADR-034` D3/D4 的 A 组分歧面上
> ⇒ 必须先做 IO 语义格（改解释器，交付 `3187915` + `0af37b3`）再做 G9。三条理由见 §11.1，
> 其中第三条（**判据结构性失明**）是本批实测带出的：既有 IO 夹具**全部**落在「分歧不可观测」的
> 切片上 ⇒ 若先做 G9，三项的**变异反证会全绿而实为假绿**。⇒ 两格同一分支、两个独立提交、各自独立验收。
> **用户裁定两处**：**上限照裁复刻**（接受「已知缺陷固化到两侧」，上限合理性另案）· **EOF 并入格 1 一并钉死**；
> 本格另得一项裁定 —— **「补基准管道，做满 6/6」**（见 ③ 末）。

**① 起点实测（五步第 1 步，不拿上一格清单做加减）**

格 2 起点 = 格 1 收口后的同一棵树：**316 夹具**，`OK 241` / `PACKAGE_MEMBER 27` / `GAP_HIR_ENGINE 20` /
`FRONTEND_FAIL 12` / `GAP_EXEC 7` / `HIR_ENGINE_TODO 6` / `OK_HARNESS 3`；**`FLIP BLOCKERS 27`**。
**打靶点 3**（`fileWrite` / `fileRead` / `readLine`），与探针「3 node(s)」逐槽吻合。
基线冻结件 `/tmp/g9-pre-0af37b3.tsv`，md5 `deded45796d0f5b1fe18c710e911463b`（与格 1 的收尾产物同内容）。

⚠️ **读数记录口径**：探针默认输出路径**每次运行都会覆盖** ⇒ 跑完立即另存改名（G6 曾因此静默丢失一份全量基线）。

**② 夹具面（五步第 2 步）—— 6 份探针面，三处可观测性缺口**

探针面 6 份，每份一个首缺口：`testDiffIoFile` / `testWriteReadFileViaLLI` / `examples/io.pini` → `fileWrite`；
`testDiffReadLine` / `testReadLineViaLLI` → `readLine`；`testDiffIoProgramBase` → `fileRead`。
另 2 份（`examples/selfhost/src/main.pini`、`corpus_tests.pini`）三臂 `rc` 全 1 ⇒ `PACKAGE_MEMBER`，不属本格面。

**三处可观测性缺口**（与格 1 的「判据失明」同源，但这次是**本格自己要解决的问题**）：

| 夹具 | 语义 | 为何不可观测 |
|---|---|---|
| 三份 `fileWrite` 夹具 | 返回整型码 | 一律**裸语句**调用 ⇒ 返回值被丢弃，`.null` 与整型码**同形** |
| `testDiffReadLine` / `testReadLineViaLLI` | 行终止符不剥离 | stdin 注入 `"hello_stdin"`，**无换行** ⇒ 剥 / 不剥**同形** |
| 全部 `readFile` 夹具 | 64 KiB 截断 | 读的文件**全在远低于上限**处 ⇒ 截 / 不截**同形** |

⇒ **补三份有区分力夹具**（差分面 `HIRDifferentialTests/`，探针 6 根之一 ⇒ 一份夹具同时进两个面）：

| 新夹具 | 观测什么 | 期望（绝对断言） | 无区分力时的读数 |
|---|---|---|---|
| `testDiffWriteFileCode.pini` | `writeFile` 的结果码 + 回读长度 | `"0\n7\n"` | 非整型返回值 ⇒ 类型错误或异值 |
| `testDiffReadLineKeepsTerminator.pini` | `len(readLine())`，stdin = `"hello\n"` | `"6\n"` | 剥离 ⇒ `"5\n"` |
| `testDiffReadFileTruncates.pini` | 自建 131072 字节文件后 `len(readFile(...))` | `"65536\n"` | 不截断 ⇒ `"131072\n"` |

**四条夹具设计约束（都是实测逼出来的，不是风格偏好）**

- **只印长度，不印内容**：两个差分捕获点都是「先绑管道、待程序结束才排空」，容量恰 **64 KiB**、
  与 `readFile` 上限同值 ⇒ 把超限内容打出来会在**两条通道同时死锁**（§11.8；格 1 为此损失一轮全量）。
- **大文件自己造，13 次倍增**：`big = big + big` 从 16 字节起倍增 13 次 = 131072 字节，
  一趟线性拷贝；写成逐段拼接则是二次构建。**不依赖任何外部资源** ⇒ 探针裸跑亦自洽。
- **夹具必须探针自洽**：探针的 `scratch_copy` 只复制同目录 `.pini`
  ⇒ 凡依赖外部资源的夹具在探针面**结构性**缺资源（见「新发现」第 1 条）。
- **接线 XCTest 前先手工三臂验一遍**：三份夹具各跑 `run:ast` / `run:hir` / `run-llvm`（F2 另跑换行与 EOF 两态），
  全部命中期望值后才接线 —— 避免「测试红了才发现夹具本身写错」。

**③ 实现（五步第 3 步）—— 镜像解释器，共享单源、删掉失效机制**

`HIRExecutor.swift` 三处打靶点替换为完整实现（+44 行），逐臂镜像解释器**照格 1 落地后的新语义**：

- **`Interpreter.resolveIOPath` 提为 `static func resolveIOPath(_:programBase:)`**（实例包装保留，
  两个既有调用点零改动）⇒ **IO 路径解析只有一份源**。两引擎各解析一次同一个裸相对路径，
  正是它们能**静默读到两个不同文件**的地方（不报错、只是读错）。
- **上限一律取 `IOLimits`**，不在 HIR 侧重述数字（第二份数字就是漂移的起点）。
- **`HIRExecutor` 新增 `programBase`**（**默认 `nil`** ⇒ 既有约 20 处 `HIRExecutor()` 调用点不受影响），
  CLI 两条通道传**同一个值**。**这是用户裁定「补基准管道，做满 6/6」的落地**：先前 `HIRExecutor`
  结构上没有基准 ⇒ `testDiffIoProgramBase` 的考点（路径基准）在 HIR 侧未接线，镜像解释器就必然要补。
- **删 `notImplemented(_:)`**：补完三臂后**零引用**（G6 有「净删私有方法」先例）。
- **`HIRExecutorTests` 的缺口漂移段整段删除**（`expressionGaps` 表 + `assertGapSpeaks` +
  `testUnimplementedExpressionNodesFailLoudAndNameTheNode`）：两张 gap 表都已消化完，**空表循环会假绿**。
  保留 `:530` 的 `XCTAssertFalse(text.contains("not implemented"))` 防回归断言。

**④ 验证（五步第 4 步）—— 闭合账目（逐夹具，非总数）**

| 判定 | before | after | Δ | 归因 |
|---|---|---|---|---|
| `OK` | 241 | 249 | **+8** | 5 份既有夹具 `HIR_ENGINE_TODO → OK` + **3 份本格新夹具全 `OK`** |
| `HIR_ENGINE_TODO` | 6 | **0** | **−6** | 5 入 `OK`、1 入 `OK_HARNESS`，**无余项、无外移** |
| `OK_HARNESS` | 3 | 4 | **+1** | = 上句那 1 份（`testDiffIoProgramBase`，见「新发现」第 1 条） |
| **`FLIP BLOCKERS`** | 27 | **27** | **0** | ⭐ **零新增、零消失** —— 阻塞槽集合**逐元素相同**，不只是数量相同 |
| 其余四类（`PACKAGE_MEMBER` / `FRONTEND_FAIL` / `GAP_EXEC` / `GAP_HIR_ENGINE`） | — | — | **全部 0** | — |

**闭合等式成立**：离开 `HIR_ENGINE_TODO` 的 6 份 == 入 `OK` 的 5 份 + 入 `OK_HARNESS` 的 1 份，无余项。
夹具面 316 → **319**（+3 = 本格新夹具）。**打靶点 3 → 0**，`Sources/` 全树无 `notImplemented` 引用
⇒ **判据 `J1` 由「零孤儿」加强为「无孤儿可落」**。

**变化行归因**：逐列对账共 **6 行变化**，**全部只动 `h_*` 列**（`l_rc` / `a_rc` / `l_len` / `a_len` 一列未动）
⇒ 本格位移**全部落在 HIR 执行引擎**，与格 1（位移全落在解释器与 LLVM 侧、HIR 一行未动）恰好互补。

**全量回归**：**1269 tests / 3 skipped / 0 failures**（格 1 基线 1267，**−1 +3**：删掉的 gap 表用例 1 个、
新增差分用例 3 个，已对账）；swift-testing **45 tests / 14 suites** 通过；
`hir-contract-check.py` 仍 **`clean`**（三锚点 **60/60** = 判据 `J4`）；门禁四项（doc-links 576 引用 ·
comment-lint L1–L6 · evidence-sweep `check ok` · 契约 `clean`）全绿。

**⑤ 变异反证两级（五步第 5 步，脚本 `/tmp/g9-mutation.py`，4 轮）**

| 轮 | 变异面 | `OK` / `OK_HARNESS` / `TODO` | moved | 判据 |
|---|---|---|---|---|
| 基线（实现态） | — | 249 / 4 / 0 | — | — |
| **家族级**（3 节点齐禁 = `Sources/` 三文件精确回退 `HEAD`） | 3 | **241** / **3** / **9** | 9 | ✅ **`OK` 精确回退到 241 = 格 2 前基线**；多出的 3 条 `TODO` 正是**本格三份新夹具**（基线中不存在）⇒ 归因闭合，**同时反证新夹具确实踩在这三个节点上** |
| `fileWrite` 单禁 | 1 | 244 / 4 / 5 | 5 | 与 `fileRead` **共享**5 份中的 4 份（`testDiffReadFileTruncates` / `testDiffWriteFileCode` 两者都用）⇒ **不可分离** |
| `fileRead` 单禁 | 1 | 244 / 3 / 6 | 6 | 同上共享面 + `testDiffIoProgramBase` |
| `readLine` 单禁 | 1 | 246 / 4 / 3 | **3** | ✅ **唯一完全可分离者**：只红 3 份 readLine 夹具，不外溢 |

- **四轮其余四槽（`PACKAGE_MEMBER` 27 / `FRONTEND_FAIL` 12 / `GAP_EXEC` 7 / `GAP_HIR_ENGINE` 20）
  Δ 全 0**，且 **`FLIP BLOCKERS` 恒 27** ⇒ **变异不外溢**。
- **四轮 `l_*` / `a_*` 列零移动**（统计上「动了 l_/a_ 列的行: 0」）⇒ 变异**只作用在 h 臂**，
  与 ④ 的「位移全部落在 h 列」互为佐证。
- **自检**：每轮变异后 `HIRExecutor.swift` 的 md5 均 **≠** 原值 `10f34ef26e7f819f5d010f40842ab9fd`
  ⇒ 「变异确实生效」自检通过（否则「全绿」与「没生效」同形）。
- **还原**：`finally` 内还原三文件，md5 逐字节一致（`10f34ef2…` / `608964b1…` / `f0e004f4…`），末次重建通过。
- **不可分离性是被实测的、不是被假设的**：脚本**先打印 red set 再下结论** ⇒ 「`fileWrite` 与 `fileRead`
  无法靠红集分开」是可测量的断言，而非默认前提（同 G8 对 `&x` 的做法）。

⚠️ **一次器械侧返工（可复用）**：本脚本首版只替换了 arm 的**头部行**，臂体仍引用 `pathExpr` / `contentExpr`
⇒ 三个 `cannot find in scope` 编译错误、构建失败（无任何读数）。**改法是整臂替换**（从 `case` 头到下一个
`case` 或 8 空格 `}`），并把「构建成功」判据定为**进程退出码**而非抓输出里的 `error:` 子串。

**范围声明（写成范围，不写成遗漏）**

- **本格不碰「路径基准」本身**：补 `programBase` 是**把既有基准接到 HIR 引擎**（对齐解释器与发射器的既有口径），
  **不是**裁决基准规则 —— 后者是 AOT 模型依赖，属判准的第三类边界（止损 7、§11.6）。
- **本格不改 IO 上限**：三项上限值照契约复刻，上限本身的合理性另案
  `docs/issue-io-limit-from-emitter-2026-09-12.md`。

**本格未做**：未改解释器行为（**零**解释器行为改动；改动仅为 `resolveIOPath` 的**提取**）· 未改 LLVM 侧 ·
未改契约节点集 · 未收窄探针的阻塞 / 缺口计数器判据（**收窄时机仍为上交给决策点**）· 未做
`stringSplit` 格 / 字符串字节语义格 / 取址格 · 未 push。

**本格新发现（只登记不修）**

1. **`testDiffIoProgramBase` 的探针归类从 `HIR_ENGINE_TODO` 迁到 `OK_HARNESS`，机制已查明，非缺陷**：
   探针的 `scratch_copy` **只复制同目录 `.pini`** ⇒ 该夹具依赖的 `res.txt` **不随行** ⇒ 在探针的独立通道里
   **必然缺资源**：`a_rc=1`（解释器抛 `E5-006`）、`h_rc=1`（同错）、`l_rc=0`（`run-llvm` **忽略 lli 退出状态**，
   错误只进 stderr）。⇒ 命中判据 5（stdout 同为空 **且** 两臂 stderr 同「响」）⇒ `OK_HARNESS`
   （「独立通道判不了它」的诚实归类），**不入 `FLIP BLOCKERS`**。
   ⚠️ **其真实考点（路径基准）由 XCTest 守、探针面结构性判不了**：`testDiffIoProgramBase()` 自建
   **基准目录 + CWD 干扰目录**（同名 `res.txt` 内容不同）并作**绝对断言**，另断言 `out.txt` 落在基准、不在 CWD。
   ⇒ 这是「**同一份夹具在两个面上的可判性不同**」的又一例，与 §11.3(b)「`IOTests` 不在探针 6 根内」同族。
2. **两引擎对非 String 实参的报错文案不同**：`HIRExecutor.requireString` 用英文（`"\(what) expects a String operand"`），
   解释器用中文（`"writeFile 的参数必须是 (路径: String, 内容: String)"`）。仅**错误路径**、stdout 不可见、
   探针不覆盖 ⇒ **登记不修**（属 G7 起的既有形态，非本格引入；对齐错误文案不在任何格的判据内）。
3. **`fileWrite` / `fileRead` 的红集不可分离是结构事实而非夹具缺陷**：`testDiffReadFileTruncates` 与
   `testDiffWriteFileCode` **同时**使用两者（先写后读）⇒ 单禁任一个都会红同一批。**修法不在此处**：
   要分离就得让夹具只用一个节点，而那会牺牲它们本来要观测的东西（见 ②）。

### 8.10 `stringSplit` 格（P2 前置格第 3 张，2026-09-15，分支 `agent/pini-dev/hir-stringsplit-grid`）

> **本格不是 P2 的格，是一张在册的「前置格」**（户口见主计划 §5 拆项段；`§10.4` 指明其登记形态 =
> **计划内拆项声明**、**不给它另立工单**）。它做掉之后，四张前置格还剩**字符串字节语义格**与**取址格**。
> **用户三项裁定（2026-09-15）**：**① 对齐口径 = 窄读 —— 只对齐空 token**（本节点另两处偏离
> 「登记不修」）· **② 语料落点 = 扩展既有 `testDiffStringSplit.pini`**（不新增差分用例，
> 并重写其已过时的注记）· **③ 判据 = 只做三通道 parity**（**不**在 XCTest 侧补绝对断言）。

**① 起点实测（不拿上一格清单做加减）**

树在 `60b5fa1` 处**干净**（仅本格两文件；`git status --porcelain` 空）。探针二进制 md5
`7bfae35d7202f48548a48436d026f6af`，**与 `state-readings.json` 的冻结 P2b 读数逐字节相同**
⇒ 基准**直接可比**（按记录的教训：可比性判据是 **md5**，不是 mtime）。
**打靶点 = 0**（权威源 = `throw notImplemented("<node>")` 调用形态；`Sources/` 全树无残留）。
全量基线 = `state-readings.json` 的 `hir_probe` 条：**319 夹具**，`OK 249` / `OK_HARNESS 4` /
`PACKAGE_MEMBER 27` / `FRONTEND_FAIL 12` / `GAP_EXEC 7` / `GAP_HIR_ENGINE 20` / `HIR_ENGINE_TODO 0`，
**`FLIP BLOCKERS 27`**。

**② 夹具面实测（本格的覆盖只有一份，另两份是下游回归探测器）**

| 夹具 | verdict | 三臂长度 | 本格面归属 |
|---|---|---|---|
| `HIRDifferentialTests/testDiffStringSplit.pini` | **`OK`** | 47/47/47 | ✅ **本格唯一的真覆盖**（点名 `split`、恰一个被测算子） |
| `HIRDifferentialTests/testDiffStdlib.pini` | `GAP_EXEC` | 82/59/82 | ⚠️ **不是本格面**：三臂**都跑完了 `split` 那一行**（同为 `[Hello,  World]`），死在**下一条语句** `abs(-42)`（`unary operator 'abs' has no interpreter counterpart`）⇒ 其长度是 **`split` 下游的逐字节回归探测器** |
| `examples/stdlib.pini` | `GAP_EXEC` | 82/59/82 | 同上 |

⇒ **红基线（本格起点，三通道实测）** —— 走查两个通道臂在空 token 与分隔符形态上的分歧：

| 输入 | `interp-ast` | `interp-hir` | `llvm-hir` |
|---|---|---|---|
| `"a,,b"` / `",a"` / `"a,"` / `",,"` / `""` | **3 / 2 / 2 / 3 / 1** | 2 / 1 / 1 / 0 / 0 | 2 / 1 / 1 / 0 / 0 |
| `"abc".split("")` | 3 | 3 | **1** ⚠️ 本格未裁 |
| `"a:b".split("::")` | 1 | 1 | **2** ⚠️ 本格未裁 |
| `"ab".split("abc")` | 1 | 1 | **0** ⚠️ 本格未裁 |

⚠️ **两条从红基线推出的认识**（都影响了本格的实现方式与范围）：
- **`interp-hir` ≡ `llvm-hir` 在全部用例上成立** ⇒ 对齐目标**无歧义**，**只有 AST 侧需要动**；
  这使「窄读」成为**低风险**选择（改一处、两臂不动）。
- **`print(arr)` 对「0 元素」与「1 元素且该元素为 `""`」渲染相同**（都是 `[]`）⇒
  语料**必须同时打印 `len`**，否则该分歧在夹具里**不可观测**。这正是它长期未被发现的机制。

**③ 实现（镜像解释器，不造第二份语义源）**

改 `Sources/PiniCore/Common/StdlibPini.swift` 的下沉 Pini `split`：两处无条件的
`parts = parts.append(cur)` 各加 `if len(cur) > 0:` 守卫（一处命中分支、一处收尾）。
**净改动 = 2 行守卫 + 注释**，语义源仍是那一份下沉实现（AST 通道经它；HIR 通道的
`HIRExecutor.case .stringSplit` 早已按契约实现 ⇒ 本格**不改 HIR 侧**）。
⚠️ **注释写窄**：注释明确记「**另两处偏离不在本格范围内、已在各自格上登记**」，
以防后来的读者把 `strtok` 语义当作本格漏做。

**④ 验证（闭合账目 + 全量回归 + 契约核验）**

- **全量回归**：`Executed 1269 tests, with 3 tests skipped and 0 failures (0 unexpected)` +
  swift-testing `45 tests in 14 suites passed`，`EXIT=0` ⇒ 与 P2b 收口基线**逐项一致**（1269/3/0）。
- **探针全量刷新**（6 根 / **319** 夹具，`env -u PYTHONPATH`，36s，`process leaks 0`）：
  `OK 249` / `OK_HARNESS 4` / `PACKAGE_MEMBER 27` / `FRONTEND_FAIL 12` / `GAP_EXEC 7` /
  `GAP_HIR_ENGINE 20`，**`FLIP BLOCKERS 27`** ⇒ **与基线逐槽 Δ 0**（**阻塞槽零新增**）。
  产物冻结为 `/tmp/ss-sweep-final.tsv`（md5 `9981413b8878c814b82819c9f6d4c81e`）。
- **逐夹具差集**（不数总数）：319 vs 319，**双向「仅在前 / 仅在后」均为空**；
  逐夹具字段 diff **恰 1 处** —— `testDiffStringSplit.pini` 的三臂长度 `47 → 78`
  （= 夹具自身新增 31 字节；**verdict 未变、三臂仍逐字节一致**）；verdict 分布**逐槽 Δ 0**。
- **三通道逐字节**（本格真正的判据，`/tmp/ss-3ch.sh`）：六个空 token 用例上三臂 md5 **全等**
  （`beba8cac1b02985ddc336eb62ed5f18f`、40 字节），`rc` 全 0；其中 `"".split(",")` 的段数
  `1 → 0` —— **只经 `len` 可见**（见 ② 第二条认识）。

**⑤ 变异反证两级（⚠️ 本格的最大产出是这一节）**

| 变异 | **探针面**（`llvm-hir` ⇄ `interp-hir`） | **XCTest 面（全量 1269）** |
|---|---|---|
| **① 整族禁用**（回退到本格前实现） | **`OK`**（长度 78/78/**88**，verdict **不变**）⇒ **真分歧判绿** ❌ | **2 failures**（`testDiffStringSplit` + `testCorpusFixturesAgreeWithTheInterpreter`）✅ |
| **② 单节点禁用**（HIR 引擎的 `stringSplit`） | **`GAP_EXEC`**，**1** 夹具、**0 溢出**（85 内）✅ | **1 failure**（同上后者）✅ |

- **红集合零溢出**：变异 ① 恰 2 红 / 1269；变异 ② 恰 1 红 / 1269。
  探针面变异 ① 的「回退」是**逐字节可对账**的：AST 臂精确回到本格前红基线（3/2/2/3/1/2），
  而 `interp-hir` / `llvm-hir` 两臂的输出 md5 与本格绿**完全相同**（`beba8cac…`）
  ⇒ **本格的净效果恰是空 token 对齐这一件事**，无附带改动。
- **三条硬要求**：① **锚点唯一性预检**通过（`src.count(old) == 1`）；
  ② **「变异确实生效」自检** —— 首版我用**二进制 md5** 当证人，**该判据当场被证伪**：
  同一源码在**不同增量构建谱系**下产出不同二进制（实测：只重编 `StdlibPini.swift` → `078a3da8…`，
  只重编 `HIRExecutor.swift` → `a646d2f5…`；两次强制重链则稳定同 md5 ⇒ **构建是确定性的、
  但二进制依赖增量历史**）。⇒ **改用源码 md5 当证人**（两份文件逐轮比对，均变）；
  ③ **`finally` 还原 + 逐字节对账** —— 还原后两文件 md5 与备份全等、`git diff HEAD -- <被变异文件>` **为空**，
  重建后三通道复现 `beba8cac…`。
- **⚠️ 一个新机制（本格实测，已另挂判据类工单）**：**三通道被切成三条「一次只覆盖一对」的边** ——
  探针覆盖 `llvm⇄hir`（规则 5 的 `OK` **只比 `l_out == h_out`、不含 `a_out`**，而探针文档把 `OK`
  写作「all three agree」⇒ **文档与实现不符**）；`HIRDifferentialTests` 覆盖 `ast⇄llvm`（它比的是
  AST 解释器 vs LLVM **管线**，**不经过 HIR 解释器** ⇒ 对本格变异 ② 完全失明）；
  覆盖 `hir⇄ast` 的是**另一个**用例（`HIRExecutorTests.testCorpusFixturesAgreeWithTheInterpreter`，语料遍历型）。
  三条边恰好凑齐三个通道对的全图 ⇒ **并集完备、单条不完备** ⇒
  **「探针绿」与「测试绿」不可互相替代，两处都看才算判据**。完整表与修正方向见
  `docs/issue-diagnostic-channel-parity-2026-09-12.md`（**单源**，本处不复制）。
  ⚠️ **过程留档**：我起初只跑差分套件、见 0 failures，便写成「XCTest 面对 HIR 节点缺口失明」，
  **随后跑全量测试当场推翻**。⇒ **「跑过某个子集」不能升级为「知道该面的覆盖面」**。

**本格新发现（只登记不修）**

1. **`stringSplit` 的「分隔符语义」两处偏离 + 空分隔符无守卫** —— 根因在 LLVM 侧
   `IREmitter.emitStringSplit` 用两趟 `@strtok`（分隔符按 libc **字符集**解释），
   且无空分隔符守卫。**既不在 §2.39 A4 的裁决范围内、也无在册对齐格** ⇒
   **另立新单** `docs/issue-hir-stringsplit-delimiter-semantics-2026-09-15.md`（登记不修，
   待 spec §1.3 裁「分隔符 = 子串还是字符集」）。**本格未顺手修**（`D2` 两项条件不同时满足 + §1.3 优先）。
   ⚠️ **不违反 `§10.4`**：那条禁止的是给 **`stringSplit` 格本身**造第二个状态源；本单的对象是
   **另一件事**（分隔符语义裁决）。**另注**：B 组工单**明文排除 `split`**（§8.7 ③ 之后的归类订正）
   ⇒ 也不是它的载体。
2. **判据结构性失明的第二形态**（见 ⑤ 末条）—— 已挂 `docs/issue-diagnostic-channel-parity-2026-09-12.md`。
3. **探针 `OK` 的文档/实现不符**（同一处）：verdict 说明写「all three agree」，实现只比两实臂。
   ⇒ **须改一处**（改实现纳入 `a_out`，或订正注释）；若纳入，还须新裁「参照臂本身偏离」的独立槽位
   —— 本格变异 ① 实测中 `a_out` **正是偏离的一方**（参照臂**并非天然正确**）。

**范围声明（写成范围，不写成遗漏）**

- **本格只做契约已裁的那一项**（空 token）。**未改分隔符语义**、**未改 LLVM 侧**、**未改 HIR 侧**、
  **未改契约**（条目 39 的 §2.39 语义未扩写，只更新其**状态**）。
- **未在 XCTest 侧补绝对断言**（用户裁定 ③）：本格判据 = 三通道 parity；夹具已有的
  `len` 印刷提供了区分力，不另加断言。

**本格未做**：未改 HIR / LLVM 侧 · 未改契约语义 · 未收窄探针计数器（仍为上交给决策点）·
未做字符串字节语义格 / 取址格 · 未新增差分夹具文件 · 未 push。

## 9. 决策记录

| 编号 | 决策点 | 裁决（2026-09-13，用户） |
|---|---|---|
| **D-P2-1** | 分歧面排期 | **后置为 P2b**，前置 = 两侧裁齐（既有登记，无需新裁决） |
| **D-P2-2** | 族边界 | **以契约 §2/§3 分节为准** |
| **D-P2-3** | 第一格 | **G4 集合与下标的容器侧** |
| D-P2-4 | P2 判据形态 | **三态**（`OK` / `CHANGE_*` / 阻塞槽）；分层读数，不合并成单一数字（§2.1–2.2） |
| **D-P2-5** | G4 的 `lenCall`/`sliceCall` 是否随其 `String` 侧后置 | **不后置**：两节点在 P2a **整节点**实现（镜像解释器 = 契约的 grapheme 语义），其 `String` 侧分歧仍作为**已登记的 B 组差异**保留，P2a 验收对这两节点在非 ASCII 语料上记 `CHANGE_*`（D-P2-3 的「容器侧」由此**扩展为整族 7 节点**） |
| **D-P2-6** | G2 的范围：格内两节点之外，F1/F2 两个既有缺陷是否随格修 | **都修，扩为「含标签模型的整个元组族」**（F1 执行侧 `call` 丢返回标签 / F2 降载侧拒绝注解标签绑定与返回类型标签），接受更大范围及其额外的变异证伪要求（实录 §8.2） |
| **D-P2-7** | G1 的缺口数是 5 还是 6（`stringConcat` 归属） | **格内范围判定（非用户裁决）：取 6**。纳入理由 = **夹具依赖**（defer 夹具需字符串拼接构造期望输出），**非契约分类**（契约实归 §2.9「字符串与内建」#41）。**偏离**规划表 §1.1（G1 记 5 / `stringConcat` 列 G7）⇒ 账目后果 P2a 26→27、P2b 18→17。✅ **已于 P2a 收尾全扫正式确认并落表**（§1.1 改数 5→6 / 10→9，依据 = 判据 `J1`/`J2`；原「待确认」状态解除，见 §10） |
| **D-P2-8** | 变异反证暴露的弱判据（用例在全部 6 次变异下均不红）怎么处置 | **就地补强断言并复验**（加「不得报 not implemented」断言），不接受「红因正确即放过」（实录 §8.3） |
| **D-P2-9** | 全仓缩进压平（本格连带发现） | **立工单 + 排期 P4 之后**（整仓重排须冻结其他改动）；本格只落 `executeFor` 整函数体 8 空格（实录 §8.3，工单 `docs/issue-swift-source-indent-2026-09-13.md`） |
| D-P2-10 | G7 的 `stringSplit` 空 token 语义：HIR 侧照契约实现后，是否顺手把解释器侧一并对齐 | **不顺手改**（**格内范围判定，非用户裁决**）：解释器侧的对齐载体 = 已在册待排期的 **`stringSplit` 格**，且语言 spec 未钉该语义 ⇒ 留在该格，本格只在 HIR 侧照契约 §2.39 A4 实现（实录 §8.7 ③） |
| D-P2-11 | G7 的实现批次划分（原拟「批 1 五项无分歧 / 批 2 三项 B 组」） | **不拆批，一次落齐**（**格内范围判定**）：实测九节点同属一条编辑面、构建一次通过，拆批只增往返而无判据收益；且「B 组需另批」的前提不成立 —— B 组的分歧**不在 HIR 侧**（契约要求改的是 LLVM 侧），本节无待裁项（实录 §8.7 ④） |
| **D-P2-12** | G8 的 `addressOfVar` 口径：镜像解释器（**快照**）还是契约写的**真引用** | **取镜像解释器（快照）** —— **取向由用户裁决**（「把阻塞疏通」）：真引用须把 `Environment.Binding` 装箱（该类型是 `[[String: Binding]]` 里的值类型、`assign` 每次重建 ⇒ 无稳定存储槽），且它 **AST / HIR 共用**；更要紧的是**照契约做真引用会把判据从非阻塞翻成 `GAP_UNKNOWN` = `FLIP BLOCKER`** ⇒ 属**止损范畴**，留给已在册的**取址格**（实录 §8.8 ③/⑤） |
| **D-P2-13** | G8 的 `pointerLoad` 对 `*U8` 的符号性 | **取镜像解释器**（与 `I8` 同按 `Int8` 解码）：`Interpreter.decodePointer` 本就同一路，契约 §2.29 自标该组为**半语义** ⇒ 不背离冻结参照；**格内范围判定**（实录 §8.8 ③） |
| **D-P2-14** | G8 指针面既无夹具又无可达路径，怎么开工 | **从零新写夹具**（`&x` + `load` / `store`）：指针三节点**此前零可达夹具**，唯二两个见证者（`examples/ffi.pini` / `examples/struct.pini`）都死在 `E5-006`（无主 callee）而**到不了节点**；降载侧实测三者成**专节点**（不经被调者解析）、`.unsafe` 降载透明 ⇒ 可写到可达。**格内范围判定**（实录 §8.8 ②） |
| **D-P2-15** | G8 夹具的收窄（标量 `I64` only / 写穿后不读变量） | **保持收窄**：两条限制是**同一条边界的两面** —— AST 臂快照 vs LLVM 臂可能真引用，**只有**在写穿指针后再读*变量*时才分歧；窄元素类型同理。⇒ 收窄是为了**量指针节点**，不是量「快照 / 真引用」分歧（后者属取址格）。**格内范围判定**（实录 §8.8 ③） |
| **D-P2-16** | G9 的夹具面含 `testDiffIoProgramBase`（考点 = **路径基准**），而 §11.6 已裁「不碰路径基准」；且 `HIRExecutor` **结构上没有** `programBase` ⇒ 镜像解释器就必然要对非前缀相对路径做基准解析。怎么处置？ | **补基准管道，做满 6/6** —— **取向由用户裁决**：给 `HIRExecutor` 加 `programBase`（**默认 `nil`**，既有调用点不受影响），CLI **两条通道传同一个值**。理由：这不是**裁决**基准规则，而是**把既有基准接到 HIR 引擎**（对齐解释器与发射器已有的同一口径）；反之若绕开，同一程序会在两条通道上**静默读到两个不同文件**——不报错，只是读错。⇒ 6 份夹具**全部**可判，无一被排除（实录 §8.9 ③） |
| **D-P2-17** | G9 的三份新夹具放哪一面（差分面 `HIRDifferentialTests/` vs `IOTests/`） | **放差分面**（**格内范围判定**）：`IOTests/` **不在探针的 6 根内**（§11.3(b)）⇒ 放那里只进全量测试一面；差分面是探针 6 根之一 ⇒ **一份夹具同时进两个面**。代价 = 必须满足探针的自洽性约束（不依赖外部资源、只印长度不印内容，见 §8.9 ②） |

## 10. P2a 整体验收（收尾全扫，2026-09-14）

> **本单元性质**：**不是新格** —— P2a 六格已全部交付（§8.1–§8.6）。本件此前只定义了**每格**判据（§4），
> 本单元新立**批次整体**判据并执行，把「P2a 做完了」从口头声明变成**可复跑的对账**。
> **不重跑验证**：G3 收口（`1bb36b9`）的全量探针产物与当前树**同树逐字节一致**、读数 0.0 天新鲜 ⇒ 引用即可，
> 重跑无增量（`J2` 本身会把「树变过」暴露出来：它比的是提交与源码，不是缓存）。

### 10.1 整体验收判据（`J1`–`J4`，本单元新立）

| 判据 | 内容 | 为什么需要它 |
|---|---|---|
| **`J1` 零孤儿** | 当前**每一个**未实现节点都必须属于 P2b 三格之一 | 防「P2a 里还有没做完、也没被派给 P2b 的项」——只能查**打靶点集合**（源码），**不能查探针 TODO 列表**（被遮蔽的节点不在那里） |
| **`J2` 闭合账目** | 逐格实现的**打靶点减少数之和** == 实测总减少量 | 手写清单会漂（本件已两度实证）；该等式两侧都由**提交与源码**实测，是唯一不依赖清单的判据 |
| **`J3` 有归属** | 每一个非 `OK` 夹具都必须落进**预定义归属类**之一 | 防「有夹具红了但说不清是谁的责任」；归属类**先定义后匹配**，不允许事后解释 |
| **`J4` 契约恒定** | `tools/hir-contract-check.py` 仍 `clean`（三锚点 60/60） | P2 只增实现不增节点 ⇒ 该读数**应恒定**，变动即意外（§4 第 2 条） |

判据执行器：`/tmp/p2a-closeout-check.py`（**不入仓** —— 它是**本单元**的验收器械，
不是常驻工具；`J4` 由既有契约脚本承担）。**命令**：
`env -u PYTHONPATH python3 /tmp/p2a-closeout-check.py`（仓库根）。

### 10.2 判据结果（全部通过）

**`J1` 零孤儿** —— 当前打靶点 **17** 个，**不属于 P2b 三格的 = 0**：

| 格 | 节点数 | 节点 |
|---|---|---|
| **G7** | **9** | `stringCase` `stringContains` `stringSubstring` `stringSplit` `arrayJoin` `interpString` `isAsciiDigit` `printMulti` `assertCall` |
| **G8** | **5** | `pointerLoad` `pointerStore` `addressOfVar` `lazyRefConstruct` `lazyRefValue` |
| **G9** | **3** | `fileWrite` `fileRead` `readLine` |

> ⚠️ **本判据的价值恰恰在于它查的不是探针输出**：探针的 `HIR_ENGINE_TODO` 表只列**10 个**节点
> （其中 `indirectCall` 这类**被遮蔽的节点根本不出现**）。若照探针列表对账，会漏 7 个节点而无从察觉。

**`J2` 闭合账目** —— 等式成立：

```
逐格:  G4(−7) → G2(−2) → G1(−6) → G6(−6) → G5(−3) → G3(−3)   ⇒ Δ 合计 27
实测:  起点 44 打靶点 → 终点 17                                 ⇒ 总减少 27
       Δ 合计 == 实测总减少  ✅        Δ 合计 == P2a 缺口 27  ✅
```

⇒ **P2a 缺口数由实测定为 27**（此前表记 26），§1.1 与 §3 已据此改数。

**`J3` 有归属** —— **未归属 = 0**。全部 308 夹具的分类：

| 数 | 归属类 |
|---|---|
| 247 | 非失败分类（`OK` 217 / `PACKAGE_MEMBER` 27 / `OK_HARNESS` 3） |
| **20** | **`E7-001` 假阳性**（阻塞槽，但三臂 `rc` 全 0、stdout 逐字一致 ⇒ **实质分歧 0**） |
| 16 + 5 + 3 | **P2b 三格**（G7 / G9 / G8 的首缺口夹具） |
| 11 | 并发 / async（§6 不做范围，`FRONTEND_FAIL`） |
| 2 | 内建数学（旧有，`GAP_EXEC`） |
| 2 | ~~G8 指针/取址（P2b 面）~~ ⇒ **`E5-006` 无主 callee**（`examples/ffi.pini` / `examples/struct.pini`，**到不了指针节点**；订正见 §10.3 订正块） |
| 1 | 刻意 unsupported（探针负例） |
| 1 | G5 内建 callee 无主（`GAP_EXEC`，已立单） |

**自动交叉验证**：阻塞槽身份拆分 = `E7-001` **20** + 实质 **5**
（**~~内建数学 2 + G8 指针 2 + 内建 callee 1~~ ⇒ 订正：5 个全部为 `E5-006` 无主 callee**，
见 §10.3 订正块；**算术不受影响**）
= **25** = 探针报的 `FLIP BLOCKERS 25`（手工目视换成脚本对账）。

**`J4` 契约恒定** —— `clean`；三锚点各 **60/60**；44 expr + 16 stmt = 60 条目、60 case、10 引用已核。

### 10.3 剩余面归因表（六格交付后「还剩什么、各自归谁」）

| 面 | 数 | 归属 | 性质 |
|---|---|---|---|
| `HIR_ENGINE_TODO` | **24 夹具 / 10 节点** | **P2b（G7/G8/G9）** | 工作清单，非阻塞 |
| `GAP_HIR_ENGINE` | **20** | `E7-001` **假阳性族** | 计数器过宽的既有登记项（收窄时机仍待裁） |
| `GAP_EXEC` | **5** | ~~2 内建数学 / 2 G8 指针 / 1 G5 内建 callee~~ ⇒ **订正：5 个全部同属一条规则（`E5-006` 裸内建 callee 无主），不属任何格** | **实质失败**，归属 = 既有工单 `docs/issue-hir-builtin-callee-unowned-2026-09-14.md` |
| `FRONTEND_FAIL` | **12** | 11 并发-async + 1 刻意 unsupported | **§6 不做范围**，与 HIR 无关 |
| 其余 | 247 | —— | `OK` / `PACKAGE_MEMBER` / `OK_HARNESS` |
| **合计** | **308** | —— | ⚠️ **分母为 P2a 收尾时点值**（本表整表都是那个时点的读数，不是当前值）；当前读数见 §8.8 ④ / §1.1 |

**零 `behaviour changes` · 零非终结夹具 · 零进程泄漏 · 零残留 `.ll`。**

> ⚠️ **订正（2026-09-14 G8 交付后实测）—— 本表 `GAP_EXEC` 行的归属拆解是误归属。**
> 实测当前 **7 个 `GAP_EXEC` 的错误码全部是 `E5-006`**，即**同一条规则**（裸内建 callee 无主），
> **不是三个不同的面**。P2a 时点的 5 个是这 7 个的子集，逐条对得上：
> `IRExecutionTests/testBuiltinMath{Floats,Integers}ViaLLI`（原记「2 内建数学」）+
> `examples/ffi` + `examples/struct`（原记「2 G8 指针」）+
> `HIRDifferentialTests/testDiffStructValue`（原记「1 G5 内建 callee」）。
> 原三处标签描述的是**夹具主题**或**撞击点所属仓区**，而本表列头问的是「**各自归谁**」——
> 二者不是一回事。
> **为什么必须订正（不是措辞问题）**：把 `examples/ffi.pini` / `examples/struct.pini` 记为「G8 指针面」，
> 会让 G8 看起来**自有失败面**，从而污染「G8 是否疏通」的判据。G8 交付时逐条实测：
> `struct.pini` 打印完前两行后死在 `sqrt`；`ffi.pini` **第一句** `unsafe malloc(64)` 就死 ——
> 两者**一次都没走到** `store` / `load` / `&x`。⇒ **G8 交付前后这 5 个 `GAP_EXEC` 一个都不该动**，
> 实测也确实是 **Δ 0**（§8.8 ④）。
> **同型提醒**：本表整表都是 **P2a 收尾时点**的读数，**不可当当前值引用**（§11「总数自己也会漂」条）。

### 10.4 P2b 前置：**四张裁决格，登记形态有三种**（⚠️ 不可只数工单文件）

| 前置格 | 登记形态 | 载体 |
|---|---|---|
| 字符串字节语义格 | **独立工单** | `docs/issue-hir-string-slice-byte-based-2026-09-11.md`（Open） |
| IO 语义格 | **计划内拆项声明**（无独立工单） | 主计划 §5 止损块（`ADR-034` D4 拆项：`readLine` + `fileRead` + `fileWrite`） |
| `stringSplit` 格 | **计划内拆项声明**（无独立工单） | 同上（1 项） |
| 取址格 | **契约内登记** | `docs/spec/hir-contract.md` §6（A/D1） |

⇒ **P2b 开工检查项（本单元新立，按形态而非按工单数）**：开工前逐格确认
**① 该形态的载体是否仍在册且 Open；② 两侧（AST / LLVM）是否已裁齐** ——
**不要用「`docs/issue-*.md` 里有几个文件」当判据**（四张前置里只有一张有独立工单，
照文件数会得出「三张前置不存在」的**假阴性**）。
⇒ **不做**：不给 IO 语义格 / `stringSplit` 格另立工单（它们**已有户口**，
重复登记会让「同一件事有两个状态源」—— 与 `ADR-034` 的单源口径相悖）。

### 10.5 本单元未做

未重跑全量验证（读数同树、0.0 天新鲜，重跑无增量）· 不做 P2b 任何实现 ·
未碰契约与节点集 · 未改 AST / LLVM 侧 · **未修任何缺陷**（只归因登记）· 未收窄探针计数器 · 未 push。

---

## 11. P2b 收尾批（IO 语义格 → G9）：规划与本步实测（2026-09-14）

> 本批 = **两格连做**：先 **IO 语义格**（改解释器，对齐契约已裁的三项 IO 语义），
> 再 **G9**（HIR 实现三节点）。分支 `agent/pini-dev/hir-io-semantics-g9`（基点 `3a11cbf`）。
> **用户三项裁定（2026-09-14）**：**上限照裁复刻**（接受「已知缺陷固化到两侧」这一代价，
> 上限合理性另案）· **EOF 并入本格一并钉死** · **两格连做**（同分支、两个独立提交、各自独立验收）。

### 11.1 为什么 IO 语义格必须先于 G9（三条理由，第三条为本批新发现）

1. **语义源冲突**：HIR 铁律 = 镜像解释器（不造第二份语义源）；而契约已裁「统一到 LLVM 侧」、
   偏离方是解释器（三项实测确认未改）⇒ 先做 G9 只能二选一，两条都错：
   照当前解释器 ⇒ 复刻**待弃**语义、**返工**；照契约 ⇒ 两侧仍不一致 ⇒ 直接落 `FLIP BLOCKER`（§2.2 机制）。
2. **顺序本身即修复**：先改解释器 ⇒ 两侧语义同一 ⇒ 才能补出**有区分力**的夹具并让它们两侧都绿。
3. ⭐ **判据结构性失明（本批实测，见 §11.3）**：现有**全部** IO 夹具都落在「分歧不可观测」的切片上
   ⇒ 若先做 G9，三项的**变异反证会全绿而实为假绿**（同「裸 `break` 用例」那一族的机制）。

### 11.2 S0 起点实测（2026-09-14，可复现）

| 项 | 实测值 | 对账结论 |
|---|---|---|
| 打靶点（权威源 = 源码**调用形态**，非词频） | **3**：`fileWrite` / `fileRead` / `readLine` | 与 `state-readings.json` 一致 |
| 探针全量基线 | 316 夹具：`OK 241` / `PACKAGE_MEMBER 27` / `GAP_HIR_ENGINE 20` / `FRONTEND_FAIL 12` / `GAP_EXEC 7` / `HIR_ENGINE_TODO 6` / `OK_HARNESS 3`；**FLIP BLOCKERS 27**（= 20 + 7） | 与 G8 收口条**逐槽吻合** |
| 基线冻结 | 探针产物另存为 `g9-pre-full-3a11cbf.tsv`，md5 `516a9d0e0626b78bcb85dd8111c5490b` | 探针默认路径**每次运行都会覆盖** ⇒ 跑完立即冻结改名（G6 曾因此静默丢失一份全量基线） |
| 二进制同态 | 二进制报出的未实现节点集 = `{fileRead, fileWrite, readLine}`，**恰等于**源码打靶点集（反向差集为空） | ⇒ 二进制与当前源码树**同态**，本步读数有效 |
| 全量测试基线 | 1265 tests / 3 skipped / 0 failures（at `f44bf70`） | 本步未重跑（读数同树、0.0 天新鲜；全量只在收口批跑） |

### 11.3 S1 夹具面实测（⚠️ 两处覆盖盲区）

**(a) 探针面 6 份 —— 「三项差异」6/6 全部不可观测**：

| 夹具 | 首缺口 | 为何不可观测 |
|---|---|---|
| `HIRDifferentialTests/testDiffReadLine.pini` | `readLine` | stdin 注入 `"hello_stdin"`，**无行终止符** ⇒ 剥 / 不剥**同形** |
| `IRExecutionTests/testReadLineViaLLI.pini` | `readLine` | 同上（无换行） |
| `HIRDifferentialTests/testDiffIoFile.pini` | `fileWrite` | `writeFile` 为**裸语句**、返回值未使用 ⇒ `.null` vs 整型码**同形** |
| `IRExecutionTests/testWriteReadFileViaLLI.pini` | `fileWrite` | 同上裸语句；读回的**内容短** ⇒ 上限**同形** |
| `HIRDifferentialTests/testDiffIoProgramBase.pini` | `fileRead` | 断言只比 stdout；`writeFile` 亦为裸语句；文件短 |
| `examples/io.pini` | `fileWrite` | 裸语句；`readLine` 为**注释态** |

**(b) 探针面外：`Tests/PiniTests/IOTests` 不在探针的 6 根内**
（根集见 `tools/hir-parity-probe.py`）⇒ 该目录的夹具对探针**结构性不可见**，
只有全量测试能守。而**两个可观测者恰在此目录**：
`testReadLine`（断言 `"world\n"`，不剥换行后应为 `"world\n\n"`）与
`testReadLineEOF`（EOF ⇒ 空串，断言 `"\n"`）。
⇒ **受害面必须靠全量测试守；探针读数不能代替它**（判据的粒度决定它看不见什么）。

### 11.4 `readLine` 在 EOF 处的语义（外部调研 → 裁定）

- **表达分三派**（16 种语言）：**空值派**（Swift `String?` → nil · Kotlin null ·
  Java `BufferedReader` null · C# null · Ruby nil · Perl undef · Rust `lines()` → None ·
  C `fgets` → NULL）· **空串派**（仅 Python `f.readline()` / `sys.stdin.readline()`）·
  **异常派**（Python `input()` EOFError · Ada `End_Error` · Java `Scanner` NoSuchElementException）；
  另有**计数派**（Rust `read_line` → `Ok(0)` · Go `ReadString` → `(部分数据, io.EOF)`）。
- ⭐ **Python 空串派成立的前提**（其官方文档原话）：**行终止符保留在返回值里** ⇒
  「空行 = `'\n'`、EOF = `''`」**不同形**；**剥掉换行则退化为歧义**（该 API 的经典坑）。
- ⭐⭐ **本格要做的改造（契约已裁「行终止符不剥离」）恰好补上了这个前提**：

  | 状态 | 空行 | EOF | 可区分？ |
  |---|---|---|---|
  | 现状（剥换行） | `""` | `""` | ❌ 歧义 |
  | 改造后（不剥） | `"\n"` | `""` | ✅ 无歧义 |

  ⇒ Pini 与 Python 模型**同构**，空串**唯一指示** EOF。这不是巧合，是同一设计。
- **LLVM 侧现状不是「另一种语义」而是 UB**：`IREmitter` 的 `readLine` 发射直接把 `fgets`
  返回的 `i8*` 交出，NULL 亦照走 `%s` ⇒ **没有可统一之物** ⇒ 判准在**本点上不适用**
  （其「一侧无定义」边界）⇒ 按最佳实践另定，并在契约写明。
- **裁定（2026-09-14）：并入本格一并钉死** —— 契约补写 EOF 语义 + LLVM 侧加 NULL 守卫
  （NULL → 空串）；解释器侧**不动**（现状即正确）。
- **代价实测很小**：一处 emitter 守卫；`readLine` **不在 golden IR 覆盖内**
  （实测无任何 golden / `.ll` 文件含 `fgets`）⇒ **不动 golden**。

### 11.5 计划（两格步骤）

**格 1 · IO 语义格**：
S0 起点实测 ✅ → S1 夹具面实测 ✅ →
**S2** 改解释器三项（`readLine` 不剥 + 256 B 上限 · `readFile` 64 KiB 静默截断 ·
`writeFile` 返整型码）+ **两处尺寸常量单源化**（256 / 65536 与 emitter 共享，避免两个数字各自漂）✅ →
**S3** LLVM 侧 EOF 守卫 ✅ → **S4** 受害测试同步 ✅ →
**S5** spec §1.3 落地（写 `docs/CHANGELOG.md` 迁移说明 —— 实测**目前零记载**；
契约 A 组三项状态「须改」→「已对齐」；补写 EOF 语义）✅ →
**S6** 验证（全量 + 三通道 + 契约 `clean`）✅ → **S7** 证据登记 + 提交。

S6 三项实测（2026-09-14，二进制 md5 `038844789ce20435ef2c161a31998bd9`）：
全量 **1267 tests / 3 skipped / 0 failures**（G8 基线 1265，+2 = 本格新增两测试）·
契约 `clean`（三锚点 60/60）· 三通道全量重跑 **316 夹具、verdict 零漂移**
（`OK` 241 / `PACKAGE_MEMBER` 27 / `GAP_HIR_ENGINE` 20 / `FRONTEND_FAIL` 12 / `GAP_EXEC` 7 /
`HIR_ENGINE_TODO` 6 / `OK_HARNESS` 3，`FLIP BLOCKERS` 27 持稳、进程残留 0），
逐列对账后全表**仅 2 行 1 列**变化 —— `testReadLineViaLLI` 与 `testDiffReadLine` 的 `l_len`
**7 → 1**，即 LLVM 臂从打印 `(null)`（7 字节）改为空串换行，与冻结参照臂的 `a_len=1` 对齐；
两行的 `h_rc=1`（`readLine` 未实现）**未变** ⇒ 格 2 的 G9 面未被本格动过。

**格 2 · G9**：S0 起点实测 ✅ → S1 夹具面实测 + **补有区分力的夹具**（三份，先手工三臂验再接线）✅ →
S2 实现三节点（镜像解释器，照格 1 落地后的新语义；含 `programBase` 补管道 = `D-P2-16`）✅ →
S3 验证（族转绿 + **闭合账目** + 全量回归 + 契约 `clean`）✅ → S4 **变异反证两级**（4 轮）✅ → S5 收口批 ✅。

S3 / S4 实测（2026-09-14，G9 提交 `7c8df33`，承格 1 的 `3187915` + `0af37b3`）：

- **打靶点 3 → 0**：`Sources/` 全树已无 `notImplemented` 引用 ⇒ 判据 `J1` 由「零孤儿」加强为「无孤儿可落」。
- **闭合账目**：`OK 241 → 249`（+8 = 5 份既有夹具 + 3 份新夹具）、`HIR_ENGINE_TODO 6 → 0`
  （5 入 `OK`、**1 入 `OK_HARNESS`**，无余项、无外移）、`OK_HARNESS 3 → 4`、其余四类 Δ 全 0、
  ⭐ **`FLIP BLOCKERS 27 → 27`（零新增、零消失 —— 集合逐元素相同）**；夹具面 316 → **319**。
- **逐列对账 6 行变化，全部只动 `h_*` 列**（`l_*` / `a_*` 零移动）⇒ 位移全落在 HIR 执行引擎，
  与格 1（位移全落在解释器 / LLVM、HIR 一行未动）**恰好互补**。
- **全量 1269 tests / 3 skipped / 0 failures**（格 1 基线 1267，−1 删掉的 gap 表用例 +3 新差分用例）；
  swift-testing 45 / 14；契约 `clean`（三锚点 60/60）；门禁四项全绿。
- **变异反证两级 4 轮**：家族级（三文件精确回退 `HEAD`）⇒ `OK` **精确回退到 241 = 格 2 前基线**，
  多出的 **3 条 `TODO` 正是本格三份新夹具** ⇒ 归因闭合、且反证新夹具确实踩在三个节点上；
  单节点级只有 `readLine` **完全可分离**（3 份，不外溢），`fileWrite` / `fileRead` 共享红集（实测、非假设）；
  **四轮其余四槽 Δ 全 0 + `BLOCKERS` 恒 27 + `l_*`/`a_*` 零移动**；md5 自检 + `finally` 还原 byte-identical。
- **一处器械侧返工**：变异脚本首版只换 arm 头行 ⇒ 臂体引用的绑定变量失作用域、构建失败（零读数）；
  改为**整臂替换**并把「构建成功」判据定为进程退出码（详见 §8.9 ⑤）。
- **本格零新增缺陷、未立新工单**；三条「只登记不修」（探针归类迁移 / 错误文案差异 / 红集不可分离）
  见 §8.9 末。

**本批（IO 语义格 + G9）验收判据全部达成**：打靶点 **3 → 0** · P2b 三格全绿（**17 缺口消化完**）·
闭合账目成立 · 阻塞槽**零新增** · 全量 0 失败 + 契约 `clean` + 探针零进程残留。

### 11.8 格 2 开工检查项（由格 1 实证带出）

**差分 harness 的两个 stdout 捕获点都有「先绑管道、待程序结束才排空」的定长管道，
容量 = macOS 的 64 KiB，恰与本格对齐的 `readFile` 上限同值** ⇒ 夹具若把超限内容
**打印出来**断言，会在**两条通道同时死锁**（本次实测症状：测试挂住、测试日志因块缓冲
停在上一行不动、采样栈叶子停在 `fwrite`→`__write_nocancel`）。两处：`IOTests.runProgram`、
`HIRDifferentialTests.runNewPipeline` 与 `runInterpreter`。
**格 2 写法**：要断言大输出的**长度**就用 `len(...)`，不要把内容打出来（格 1 的
`testReadFileLen` 即此形态）。`IOTests.runProgram` 已就地写入该注记；差分侧留待格 2 自行补。

**本批验收判据**：打靶点 **3 → 0** · P2b 三格全绿（**17 缺口消化完**）· 闭合账目成立 ·
阻塞槽**零新增** · 全量 0 失败 + 契约 `clean` + 探针零进程残留。

### 11.6 不做范围（本批）

> ⚠️ **本条首句已被同批的用户裁决收窄**（2026-09-14，`D-P2-16`）：原裁「不碰**路径基准**」在
> **夹具面**上让位于「补基准管道，做满 6/6」—— 但注意**收窄的是范围、不是规则**：本批**没有裁决
> 基准规则本身**（基准解析口径仍以解释器与发射器既有口径为准），只是**把既有基准接到 HIR 引擎**
> （`HIRExecutor` 新增 `programBase`、CLI 两通道传同一个值），AOT 模型依赖的第三类边界仍不碰。
> 其余各项（IO 上限合理性 / 三张裁决格 / `fileWrite` 返回类型设计）**照原裁不动**。见 §9 `D-P2-16`。

不碰**路径基准**的**规则**（AOT 模型依赖，属判准的第三类边界，停损 7）· 不裁决 **IO 上限本身的合理性**
（另案 `docs/issue-io-limit-from-emitter-2026-09-12.md`；本格**只做对齐**）·
不做 `stringSplit` 格 / 字符串字节语义格 / 取址格 · 不重新设计 `fileWrite` 的返回类型 · 未 push。

### 11.7 本步未做

未改任何源码 · 未碰契约 · 未跑全量（读数新鲜）· 未提交（本节与实现同批提交）。

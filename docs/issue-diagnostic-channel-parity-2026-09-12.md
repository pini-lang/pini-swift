# Issue：语义警告只在解释器通道产生（LLVM 通道静默）

- 状态：**Open（2026-09-12 立案；M6b 翻转批冒烟时实测发现，未裁决处置方向）**
  - **2026-09-13 补记**：本单预言的「假阻塞」**已实测出现 4 例**（`FLIP BLOCKERS 4`），
    屏蔽不再存在；计数器的收窄时机成为决策点，见 §「对探针判据的后果」末段。
- 发现渠道：M6b 翻转批 b4/b5 冒烟——8 个样例做三通道 stdout 对比时，发现解释器额外向
  **stderr** 输出语义警告，而 LLVM 通道（`run-llvm` / `compile` / `emit`）不输出。
- 归属：诊断通道（诊断面），非代码生成面。

## 现象（实测，本轮现跑）

| 通道 | stdout | stderr |
|---|---|---|
| `pini run examples/slice.pini` | `[20, 30]` / `[10, 20]` / `[40, 50]` | `Warning: 语义警告 [E7-001]` + `  at examples/slice.pini:32:5` |
| `pini run-llvm examples/slice.pini` | 同上（逐字一致） | **空** |

对照：`examples/cow.pini` 两通道 stderr 均为空（即差异只在**会触发警告的程序**上显现）。

## 判据边界（避免误判为「输出不一致」）

- 本项**不涉及 stdout 等价性**：三通道 stdout 逐字一致，已实测。
- 本项涉及的是**同一份程序在不同执行通道下「看到的诊断」不同**。
- 副作用已知：把 stderr 并入比较的对比脚本会产生**假差异**（本轮冒烟踩过一次：`2>&1` 使
  `slice` / `object` 被判为 DIFF，改为只比 stdout 后 8/8 一致）。对比脚本应显式指定比较通道。

## 成因（未深查，属立项时的方向输入）

语义警告（`E7-001` 等）由检查/语义阶段的诊断产生；解释器通道在运行前持有这些诊断并输出，
LLVM 通道当前不转发。具体转发点与 `DiagnosticProviding` 的接线方式待立项时展开。

## 处置选项（未裁决）

- **A**：LLVM 通道补齐同类警告——需要在 codegen 前后把诊断产物输出到 stderr（与解释器同规则）。
- **B**：解释器把语义警告降级为「仅显式开关下输出」——把两个通道都收成静默。
- **C**：文档登记为已知差异，不改行为（当前状态即此，但未登记）。

## 对探针判据的后果（P1-4 登记，2026-09-12；本单的实际代价升级）

P1-4「探针扩三实通道」在 `tools/hir-parity-probe.py` 新增判据
`GAP_HIR_ENGINE`（替换此前**已死**的 `GAP_IR` 槽位），语义 = 「`interp-hir` 退出码为 0
但 stderr 非空」，且**计入 `FLIP BLOCKERS`**。它与本单的通道奇偶**叠加**后产生一条
**假阻塞**路径：

| 条件 | 实测依据 |
|---|---|
| `run-llvm` 对会触发警告的程序**静默**（stderr 0 字节） | 本轮实测：`pini run-llvm <会报 E7-001 的夹具>` → rc=0、stdout 正确、**stderr 0 字节** |
| `run`（两引擎）**打印**同一警告到 stderr | 同上夹具 `run` → stderr 有 `Warning: 语义警告 [E7-001]` |
| 探针的 `classify` 用「两臂 stderr **有无**是否相同」做 tie-break | 规则 5：`bool(l_err.strip()) == bool(h_err.strip())` |
| ⇒ 该 tie-break 失配 → 落到 `GAP_HIR_ENGINE` | 规则 6 要求 `h_rc != 0`（此处为 0）、规则 7 要求 `l_err` 非空（此处为空）⇒ 命中规则 8 |

即：一个 **HIR 侧仅有一条（且很可能是假阳性）警告、执行完全正确**的夹具，
会被登记为**翻转阻塞**。`E7-001` 的假阳性面见
`docs/spec/issue/archive/issue-e7-001-false-unused-warning-2026-09-12.md`（成员调用接收者不计入使用），
而成员调用是常见形态 ⇒ 这条路径不罕见。

**当前不再不可达（2026-09-13 实测证伪，LR-4 P2a G2 取得）**：立案时以
`--root Tests/PiniTests/CodeGen/HIRTests`（73 夹具）全量 sweep 得 `FLIP BLOCKERS 0`，
并记为「带该形态的夹具全部**更早**被『节点未实现』拦下（`arrayLiteral` / `stringCase` /
`arrayJoin` …，即 P2 工作清单）⇒ **P2 每实现一个节点，这层屏蔽就薄一分**」。
G2（元组族）实现 `tupleConstruct` 后**屏蔽确实薄穿了一层**，预言命中：

```
OK 34 / HIR_ENGINE_TODO 36 / GAP_HIR_ENGINE 4 / FLIP BLOCKERS 4
```

四个具名夹具（三者 `l_rc=0 / h_rc=0 / a_rc=0`，**stdout 逐字一致**，`note` 均为
`Warning: 语义警告 [E7-001]`）：

| 夹具 | 三臂 rc | 差异面 |
|---|---|---|
| `testDiffMultiReturnAddAndSub` | 0 / 0 / 0 | 仅 stderr |
| `testDiffMultiReturnSwap` | 0 / 0 / 0 | 仅 stderr |
| `testDiffTupleConstruct` | 0 / 0 / 0 | 仅 stderr |
| `testDiffTupleConstructClang` | 0 / 0 / 0 | 仅 stderr |

按本单第 5 节的既有结论（`rc == 0` 时 stderr 的内容**不构成缺陷证据**），这四个是
**判据产物、不是缺陷**：计数里它们是 `FLIP BLOCKERS`，实质上**没有任何一条三通道行为分歧**。
⇒ 「P2a 的 `FLIP BLOCKERS 0`」在**实质**上仍成立（分歧数为 0），**不成立的是那个计数器**。
该计数器何时收窄（本单即改 / 按既有路由留 P3），已作为决策点上交，未在本格自行改动。

**判据修正方向（供 P3 判据升级格取材，本单不实施）**：`rc == 0` 时 stderr 的内容
**不构成缺陷证据**（警告是前端的非致命通道，且两条解释器臂共用前端 ⇒ 警告本就该两边都有）。
可选的收窄：把该槽位的门槛从「stderr 非空」改为「HIR 臂**失败**」——但那会与规则 6
（`GAP_EXEC`）重合而重新变成死规则，故正确处置是**删除该槽位**或**改判为非阻塞观察**
（保留按消息聚合的可见性，但不进阻塞计数）。**该决策需与已登记的「`GAP_IR` 槽位早已死」
一并裁**，同属 P3 判据升级格。

## 不做范围

本单不修。M6b 翻转批刚收口，诊断通道对齐未列入当前批；启动需点名。
## 判据结构性失明的**第二形态**：三通道被切成「每条器械只覆盖一对」的并集（2026-09-15 实测）

> 本节由 `stringSplit` 格（LR-4，P2b 之后的实现对齐格）的 **⑤ 变异反证**实测产出。
> 与上文「对探针判据的后果」同族，但**受害对象不同**：上文是**计数器虚高**（假阻塞），
> 本节是**真分歧被判绿**（假绿）。

### 现象一：探针的 `OK` 槽位不收参照臂，且文档与实现不符

`tools/hir-parity-probe.py` 规则 5 写成：

```
if l_out == h_out and bool(l_err.strip()) == bool(h_err.strip()):
```

—— 即 `OK` 只要求 **`l_out == h_out`（`llvm-hir` vs `interp-hir`）**，
**`a_out`（`interp-ast`，冻结参照臂）不参与**（`a_out` 只在规则 8 之后的
`CHANGE_F64` / `CHANGE_OTHER` / `GAP_BEHAVIOR` 兜底里出现）。
而探针自身的 verdict 说明把 `OK` 写作 **「all three agree」** ⇒ **文档与实现不符**（本项须改一处）。

### 现象二：两条「两面器械」的通道对恰好互补，但各自单独都不完备

变异反证的两级在**两个面**上都实测了一遍（`stringSplit` 格单格，语料
`Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/testDiffStringSplit.pini`）：

| 器械（覆盖面） | 比较的通道对 | **变异 A**：把解释器侧实现回退到本格之前 | **变异 B**：单独禁用 HIR 引擎的 `stringSplit` 节点 |
|---|---|---|---|
| 探针 `hir-parity-probe.py`（6 根 / 319 夹具） | `llvm-hir` ⇄ `interp-hir`（**缺 `interp-ast`**） | ❌ **`OK`**（长度 78/78/**88**，verdict **不变**）⇒ 真分歧判绿 | ✅ `GAP_EXEC`（**1** 夹具，**0 溢出** / 85） |
| XCTest `HIRDifferentialTests`（89 例） | `interp-ast` ⇄ **LLVM 管线**（**缺 `interp-hir`**） | ✅ red（`testDiffStringSplit`，`EXIT=1`） | ❌ **89 tests / 0 failures** |
| XCTest `HIRExecutorTests.testCorpusFixturesAgreeWithTheInterpreter` | `interp-hir` ⇄ `interp-ast`（**缺 `llvm-hir`**） | ✅ red | ✅ red |
| XCTest **全量**（1269 例） | 三者并集 | ✅ **2 failures** | ✅ **1 failure** |

（两个变异的红集合均**零溢出**：变异 A = 1269 里恰 2 红，变异 B = 恰 1 红。）

### 结论（本节的实质，三条）

1. **三通道没有被任何一个器械整体覆盖**，而是被切成三条「一次只覆盖一对」的边 ——
   `llvm⇄hir`（探针）· `ast⇄llvm`（差分套件）· `hir⇄ast`（语料用例）。
   三条边恰好凑齐三个通道对的**全图** ⇒ **并集完备，单条不完备**。
   ⇒ **「探针绿」与「测试绿」不可互相替代，两处都看才算判据。**
2. **`HIRDifferentialTests` 这一条边对 HIR 引擎缺口完全失明** ——
   它比的是 AST 解释器 vs LLVM **管线**，**根本不经过 HIR 解释器**；
   覆盖 HIR 引擎的是**另一个**用例（语料遍历型的 `testCorpusFixturesAgreeWithTheInterpreter`）。
   ⇒ **不可把「某个套件绿」当成「该面已覆盖」**：套件名（`HIRDifferentialTests`）会给人
   「HIR 已被差分覆盖」的错觉。
3. ⚠️ **过程留档（本节的第一个结论是订正后的）**：我起初只跑了差分套件、见到 0 failures，
   便写成「XCTest 面对 HIR 节点缺口失明」，**随后跑全量测试当场推翻**（全量在变异 B 下 1 failure）。
   ⇒ **「跑过某个子集」不能升级为「知道该面的覆盖面」**；覆盖面要**按通道对逐条追问**，
   不能按套件名猜。

### 供 P3 判据升级格取材的修正方向（本单不实施）

1. **探针规则 5 与文档注释必须改一处**：纳入 `a_out`（与「all three agree」一致），
   或订正注释（承认这是「两实臂一致」而非「三臂一致」）。
2. 若纳入 `a_out`，须同时裁 **「参照臂本身偏离」** 的处置 —— 本次变异 A 实测中
   `a_out` **正是偏离的一方**（AST 臂保留了空段、HIR 臂与 LLVM 臂一致），
   ⇒ **参照臂不是天然正确**，硬比会把「参照臂对、另两臂错」与「参照臂错、另两臂对」
   压成同一个红，故需要一个**独立槽位**而不是塞进 `OK`。
3. 三条边的**并集**应固化为**单一可复跑的判据**（避免依赖「记得两处都跑」这一人工纪律）。

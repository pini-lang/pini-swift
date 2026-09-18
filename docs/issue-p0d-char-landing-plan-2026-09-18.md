# `P0d`（`Char` 类型落地）计划 —— 分批、判据、止损与不做范围

> **批**：`P0d` **规划**（本件是规划，不是批次；本体开工须**另行点名**）
> **分支**：`agent/pini-dev/p0d-char-plan`｜**日期**：2026-09-18｜**状态**：规划已出，**未开工**
> **授权**：`auth-7`（范围 = 交付本计划件；**不含**本体开工）
> **上游裁决**：`docs/spec/adr/adr-033-char-type.md`（D1/D2/D3 已裁 2026-09-12）·
> `D-P4-36`（排期：本体在 `LR-4` 之后）· 本件 §7（2026-09-18 用户三项裁定）
> ⛔ **本件不动源码、不动规范、不排期、不建本体分支。**

---

## 1. 事实基础（全部 2026-09-18 实测；数字带测法）

| # | 面 | 实测 | 测法 / 位置 |
|---|---|---|---|
| 1 | `Value` 枚举 | **17 个 case**，无 `char` | 枚举体逐行数（`Sources/PiniCore/Interpreter/Value.swift:298`） |
| 2 | `HIRType` 枚举 | **19 个 case**，无 `char` | 枚举体 `:19` 起至闭括号 `:166` 内 `case ` 行数（`Sources/PiniCore/HIR/HIRNode.swift`） |
| 3 | `TypeAnnotation` | **5 个 case**（`simple` / `tuple` / `generic` / `function` / `pointer`），无 `char` | `Sources/PiniCore/AST/Types/Type.swift:31` |
| 4 | 六个谓词签名 | 全部以 `String` 为参；`chars` 返回 `Array<String>` | `Sources/PiniCore/Common/BuiltinRegistry.swift:87–101` |
| 5 | `chars` 返回类型**硬编码两处** | 声明处 + 降载表 | `Sources/PiniCore/Common/BuiltinRegistry.swift:93` 与 `Sources/PiniCore/HIR/HIRLowerer.swift:2872`（`resultType = .array(element: .string)`） |
| 6 | 字符内建派发表**只有 5 个名字** | `chars` / `chr` / `ord` / `is_letter` / `is_number` | `Sources/PiniCore/Runtime/RuntimeOps.swift:805`。⚠️ **`is_ascii_digit` 不在这张表** ⇒ 六谓词跨的**不止一张派发表** |
| 7 | `s[i]` 的返回站点 | `return .string(String(s[cidx]))` | `Sources/PiniCore/Interpreter/SubscriptStrategies.swift:58`（分派注册见同文件 `:47`） |
| 8 | LLVM 端 grapheme 通道 | `bk_string_grapheme_*` **全仓零命中** | 全 `Sources/` 检索 ⇒ **未落地** |
| 9 | **switch 穷尽性扩散面** | `case .string:` 共 **16 处 / 6 个文件** | `IREmitter` 7 · `HIRLowerer` 4 · `RuntimeOps` 2 · `ProgramRunner` 1 · `SubscriptStrategies` 1 · `HIRNode` 1。⚠️ **该数混合 `Value` 与 `HIRType` 两个枚举** ⇒ **已由 `A` 阶段逐处分解，见 §11.1** |
| 10 | 影响面载体 | ~~命中 **18 份**~~ | ⚠️ **本数已由 `A` 阶段推翻** ⇒ **见 §11.2**（18 的构成是 14 份语料 + **4 个假阳性**，且**漏掉了 selfhost**） |
| 11 | 契约核验的计数口径 | **只解析契约 §2/§3**，只数 `HIRExpr` / `HIRStmt` 的 case | `tools/hir-contract-check.py:73–79` 与 `:103–106` ⇒ **`HIRType` 加 case 不进入该计数** |
| 12 | 契约 §4.1 现状态 | **显式延后**（`LR-4` 收口时登记） | `docs/spec/hir-contract.md:223` |
| 13 | spec 现役登记 | `G45` 记字符谓词签名 `String -> Bool`、`chars` 为 `String -> Array<String>`；**并记 LLVM 端 `is_letter`/`is_number`/`chars` 为「显式 unsupported（`E6-002`）」** | `docs/spec/pini-spec-v0.md:485` 与 `:517` |
| 14 | `ord` / `chr` 的规范登记 | **spec 全篇零命中** | 实现侧 `BuiltinRegistry` 已声明（`.char` 组），规范侧无条目 |

---

## 2. 与实测不符的登记 —— **施工前必须逐条订正，否则会照抄出错的判据**

四条「照登记做会做错」的：

1. **「契约计数 61 → 62」不成立**。`docs/issue-p0d-char-scheduling-2026-09-17.md` §2 约束 1 写
   「`HIRType` 加一个 case ⇒ 契约 §1 同步、计数 61 → 62、三锚点同步」。
   实测（事实 11）：核验脚本**只读 §2/§3**，而 `char` 是**类型层**（§1）条目 ⇒ **它根本不进那个计数**。
   那个 61 → 62 是 `join` 与 `detachStmt` 造成的，**已经发生过**（契约 §0.4）。
   ⇒ **正确判据**：本格交付后核验仍应为 `clean 62/62`，**变的是契约 §1 的表述与 §4.1 的状态**。
   ⚠️ 这句若照抄，会把「计数该变而没变」读成失败，或反过来把「计数没变」读成漏改。

2. **`reference` 里 `Char` 的语义与 `ADR-033 D1` 正面冲突**。`docs/spec/pini-reference-v0.md:368`
   把 `Char` 登记为「**Unicode 标量值**，0 到 0x10FFFF」（= 单码点），而 `ADR-033 D1` 裁的是
   **extended grapheme cluster**（用户感知的一个字符，长度无上界），且 `ADR-019 D1` 明文
   「**不采用 Unicode scalar** 或 UTF-8 byte 模型」。⇒ 二者不可同时为真。

3. **`reference` 另有两处 `CChar` 旧义的残留**：`:738` 把 `Char` 列入「Raw 自动实现」的标量组
   （= 可作 C 互操作标量），`:2541` 在 FFI 排除表里写 `| Char | C char 符号性由实现定义 |`。
   ⇒ 这两处指的其实是改名后的 `CChar`；且 `:738` 与 `docs/spec/pini-spec-v0.md:409`
   （「**`Char` 不进入 FFI 标量集**」）**互相矛盾**。
   ⇒ `ADR-033 D2` 要修的「一名两义」，**在文档侧同样存在**，不能只改实现侧的 3 处代码。

4. **本格把一格「显式 unsupported」变成「supported」**。spec `G45` 现役登记说 LLVM 端
   `is_letter` / `is_number` / `chars` 是显式 unsupported（`E6-002`，理由「Unicode 语义需运行时表 /
   grapheme 切分」）。⇒ `P0d` **不是纯类型添加**，它同时是一次**能力扩张**，spec 该行状态须改。

另有两条**数字待定**（不是错误，是口径要定）：

5. **契约 §1 标题写「`HIRType`，20 case」，实测 19**（事实 2）。落地时要改这一行 ⇒ **先定谁对**。
6. **`ADR-033` §2 记 `Value` 为「20 case」，实测 17**（事实 1）。该表是 2026-09-12 时点读数，
   已漂；落地以实测为准，并在契约 / 本件留下新读数。

---

## 3. 分批（五阶段 + 收口；按「载体的主人」切，不按工作量）

> ⚠️ 阶段之间**有硬顺序**：`A → B → C → D → E`。`B` 未完成不得进 `C`
> —— 规范先行、**实现不得先于登记**（`charter.md` 与 `ADR-033` 的治理纪律）。

### `P0d-A` · 影响面与扩散点逐处清点（**只读**，可先行）

产出四张表，**每张逐条具名**：

1. **16 处 `case .string:` 逐处判归属** —— 属 `Value` 的 switch / 属 `HIRType` 的 switch / 两者兼有。
   ⚠️ 事实 9 的 16 是**混合上界**；本步要把它拆成「本格真正要动的处数」。
2. **18 份影响面载体逐份判后果** —— 类型变更后它会不会编译失败 / 断言失败 / 语义漂移。
3. **selfhost 两文件的调用点逐处列出**（2968 行里哪些行依赖 `chars` 与谓词的 `String` 语义）。
   ⚠️ selfhost 是**嵌套独立仓**；本格若使其不可编译，**代价要单独上报**。
4. **LLVM 端现值实测** —— `s[i]` / `chars` 在 LLVM 臂上到底是 `fail-loud` 还是**静默降级**
   （后者会违反 `ADR-019 D1` 的边界纪律，属须立案的缺陷，不属本格）。

### `P0d-B` · 规范与契约治理（走 `spec §1.3` 五步）

1. **提议 + 影响评估**（五步之 1、2）：动机、影响面、是否破坏性、受影响构造的稳定性级别。
2. **`spec` 登记 `Char` 类型**（第 3 步）：在类型面与 §3 台账各落一条（现状：spec 只在 §2.7 说
   「`Char` 保留为一般语言类型」，**从未定义它的语义**）。
3. **订正 spec `G45`** 的 LLVM unsupported 表述（见 §2 第 4 条）。
4. **`reference` 三行同批订正**（`:368` / `:738` / `:2541`）—— **依 2026-09-18 用户裁定**。
   ⚠️ 纪律：`spec §1.3` 第 4 步的「回写」条款规定**语言参考不得成为改动入口**
   （「不得只在语言参考里改」）⇒ 本项必须**从 spec 入口进入**，reference 只承接沉降。
5. **登记 `ord` / `chr`**（现状：实现有、规范无）。
6. **契约**：§1 标题计数订正（§2 第 5 条）+ §4.1 由「显式延后」转「已落地」。

### `P0d-C` · 三处类型表示 + 扩散点（**同批交付**）

`Value` / `HIRType` / `TypeAnnotation` 各加 `char` case，**并在同一次提交内**改完 `A` 阶段清出的
全部穷尽性分派点。⚠️ `ADR-040` 已实测过：契约行 / enum case / 三锚点**任何一处单独落地，
中途态都是红的** ⇒ 不允许拆成「先加 case、日后再接线」。

### `P0d-D` · 签名与返回类型迁移

六谓词签名 + `chars` 的两处硬编码返回类型（事实 5）+ `s[i]` 的返回站点（事实 7）。
⚠️ **`ord` / `chr` 的读法待裁**：`ADR-033 D4` 第 2 类字面写「六处谓词签名 `String` → `Char`」，
但同节又保留「`ord` 取首 Unicode scalar、**空串哨兵 `-1`**、`chr` 越界返回空串」的既有裁决
⇒ 「空串」这一输入在 `Char` 参数下**不可表达**。两项的取舍见 §9。

### `P0d-E` · 收口

契约核验（**口径见 §4 第 1 条**）· 全量回归逐条集合 · 探针零位移 · 夹具面（含 selfhost）·
证据表登记 · 相关工单状态刷新 · 元仓读数刷新。

---

## 4. 判据（每阶段可测形式）

1. **契约核验**：交付后仍须 `clean 62/62`。⚠️ **口径先定再跑** —— 它数的是表达式+语句节点
   （事实 11），`char` 是类型层条目，**不进入该计数** ⇒ 「计数不变」是**预期**，不是漏改。
   要变的判据是**文本层**：契约 §1 标题的 case 数 + §1 表格新增 `char` 行 + §4.1 状态。
2. **全量回归**：与父提交基线**逐条集合**比对，报 `fixed / new / still` 三个数，**不只比总数**
   （总数相同可以是此消彼长）。
3. **探针**：现行口径为**两执行通道 + 一个诊断来源器械**（成文见
   `docs/issue-interpreter-hir-plan-2026-09-12.md` §8.1），对账须**逐夹具差集**且 Δ 全 0 或逐条说明。
4. **三处枚举穷尽性**：编译器不再报 `switch must be exhaustive` —— 这是 `C` 阶段最直接的形态判据。
   ⛔ **但本判据经 `A` 阶段实测只对 2 / 16 处有效**（14 处带 `default:`）⇒ **必须配第二条判据**，
   见 §11.3。**不得单独使用它**（它会给出「全绿」而覆盖不到 14 处静默路径）。
5. **每条「转绿」都要实测 CLI 面**：测试面绿 ≠ 用户可见入口可用（测试 helper 常绕过检查器）。
6. **中间态**：因 LLVM 端拆格（§7 第 3 项），本格交付后 LLVM 臂**仍应显式拒绝** `chars` / 谓词；
   该状态须**在 spec 写明为已登记的中间态**，否则会读成「实现漏了」。

---

## 5. 止损点

1. **`ADR-033` 自带的止损条款**（其 Consequences 末条）：若实施中发现迁移面**显著超出** `D4` 三类清单
   （例如波及序列化 / DAP / 字典 key 哈希 / FFI thunk）⇒ **立即停并重新拆项**，不把扩散项塞进同一批。
   ⇒ `A` 阶段第 1、2 张表就是这条止损的**触发判据**。
2. **三处类型表示 + 契约 + 锚点必须同批**（`ADR-040` 先例）。
3. **selfhost 若不可编译**：停下上报代价，不在本格内顺手改自举语料（它是嵌套仓 + 另一条授权线）。
4. **`reference` 冲突若无法从 spec 入口一次说清**：停下重新评估，不就地改 reference（违反五步流程）。

---

## 6. 不做范围

- **字符字面量 `'c'`** —— `ADR-033 D3` 已裁**拆格**，排 `P0d` 之后（涉 lexer/parser 单引号消歧）。
- **字符语义六处对齐**（`len` 码点 / 切片 / `substring` 字节面）—— 自有载体
  `docs/issue-hir-string-slice-byte-based-2026-09-11.md`，`ADR-033` 明文「不由 `P0d` 承担」。
- **`CChar` 面不可运行（死面）** —— 自有在册单 `docs/issue-ffi-char-rename-cchar-2026-09-12.md`。
- **`Value` / `HIRType` 的表示优化（`ADR-033 D1` 的方案 B）** —— 触发条件是 bench 证据，非本格。
- ⛔ **LLVM 端 grapheme shim（`bk_string_grapheme_*`）** —— **2026-09-18 新裁：拆格，后置**（见 §7）。
- 不顺手归档任何工单（归档属工单治理循环，批次收口不顺手做 `git mv`）。

---

## 7. 本批的三项裁定（2026-09-18，用户）

| # | 待决项 | 裁定 | 后果 / 落点 |
|---|---|---|---|
| 1 | 授权范围 | **发授权，先出完整计划件** | 落 `auth-7`（范围 = 本件）；**本体开工须另行点名**（排期 ≠ 授权，主计划 §7 已注） |
| 2 | `reference` 的三行冲突 | **`P0d` 同批订正** | 落 `P0d-B` 第 4 项；**必须从 spec 入口进**（`spec §1.3` 第 4 步禁止只在 reference 里改） |
| 3 | LLVM 端 grapheme 支持 | **拆格：类型先行，shim 后置** | ⇒ 须**新立一格**（暂名「LLVM 端 grapheme shim」）。⚠️ **两项连带义务**：① 本格交付后 LLVM 臂仍显式 unsupported ⇒ 必须在 spec 写明这是**已登记的中间态**；② 新格须登记排期与载体，否则它会成为下一个「已裁未排期」的悬挂格 |

---

## 8. 开工前检查清单（供开工那一批照章核对）

**状态更新（2026-09-18 `A` 阶段后）**：

- [x] **开工授权**：用户 2026-09-18 点名「`P0d` 本体开工」⇒ 落 `auth-8`（范围 = 本体五阶段）。
- [x] **`A` 阶段四张表已出** ⇒ §11.1（扩散点 13 `HIRType` / 3 `Value`）· §11.2（影响面 15 份）·
      §11.4（LLVM 现值 8 项）· §11.5（selfhost 8 处调用点）。
- [ ] **契约 §1 的 19 vs 20、`ADR-033` 的 17 vs 20** 两处数字**待定**（§2 第 5、6 条）——
      不挡 `A`/`B`，但 `C` 阶段改契约 §1 标题前**必须先定**。
- [ ] **`ord` / `chr` 的签名读法待裁**（§9 待裁 1）—— **`D` 阶段开工前必须定**。
- [ ] **`reference` 订正的形状待裁**（§9 待裁 2）—— **`B` 阶段开工前必须定**。
- [ ] **`s[i]` 的 LLVM 侧字节分歧归属待裁**（由 §11.4 实测引出）—— 决定本格范围。
- [ ] **新格（LLVM shim）的排期与载体**尚未登记（§7 第 3 项连带义务 ②）。
- [x] **起点基线**：`bf419a3`（本格分支 `agent/pini-dev/p0d-char-landing` 的基点）。
      全量回归与探针的**本格基准**按 §4 第 2、3 条**现跑取**，不拿上一批清单做加减。

---

## 9. 待裁（留给本体开工那一批）

1. **`ord` / `chr` 的签名怎么落**：`ADR-033 D4` 字面写「六处谓词 `String` → `Char`」，
   但同节保留「`ord` 空串哨兵 `-1`」⇒ 空串输入在 `Char` 参数下不可表达。
   三条候选：① 与其余四个一致改 `Char`、空串哨兵条款作废；② `ord`/`chr` 维持 `String` 面，
   `D4` 的「六处」改为「四处」；③ `ord` 参数取 `Char`、`chr` 返回 `Char`，另立空串语义。
2. **`reference` 订正的形状**：`:368` 是删行、还是改写为「grapheme 字符」并补判据；
   `:738` 与 `:2541` 是改名为 `CChar` 还是整行删除（`spec §1.3` 第 4 步要求**信息量只增不减**）。

---

## 10. 本件的位置

- 排期与三选项的来源：`docs/issue-p0d-char-scheduling-2026-09-17.md`（**其 §2 约束 1 的计数表述须按本件 §2 第 1 条订正**）。
- 里程碑位置与「排期 ≠ 授权」：`docs/issue-interpreter-hir-plan-2026-09-12.md` §7。
- `char` 预留位的登记处：`docs/spec/hir-contract.md` §4.1。
- `LR-4` 的收口声明（本格的前置已全部兑现）：`docs/issue-lr4-p5-closeout-plan-2026-09-18.md`。

---

## 11. `A` 阶段实录（2026-09-18，**只读**）

> 本阶段按 §3 定义**不动源码**。产物 = 四张表 + 对 §1 / §4 的三处自我订正。
> **分支**：`agent/pini-dev/p0d-char-landing`（A 阶段与后续阶段同一分支）。

### 11.1 扩散点逐处分解（订正 §1 事实 9）

16 处 `case .string:` 逐处判归属与**穷尽性**（判法：从 `switch` 起括号出发按大括号深度扫，
只看深度 1 的 `default:`）：

| # | 位置 | 所属枚举 | 穷尽性 | `default` 的行为 |
|---|---|---|---|---|
| 1 | `Sources/PiniCore/HIR/HIRNode.swift:89` | `HIRType` | **穷尽 ✅** | —（`llvmSpelling`） |
| 2 | `Sources/PiniCore/Runtime/RuntimeOps.swift:354` | `Value` | **穷尽 ✅** | —（类型名映射） |
| 3 | `Sources/PiniCore/Interpreter/SubscriptStrategies.swift:79` | `Value` | 有 `default` ⚠️ | `return nil` |
| 4 | `Sources/PiniCore/Runtime/RuntimeOps.swift:705` | `Value` | 有 `default` ⚠️ | 返回 `"其它"` |
| 5 | `Sources/PiniCore/HIR/HIRLowerer.swift:2309` | `HIRType` | 有 `default` ⚠️ | `throw unsupported(...)` |
| 6 | `Sources/PiniCore/HIR/HIRLowerer.swift:2323` | `HIRType` | 有 `default` ⚠️ | `indexExpectation = nil` |
| 7 | `Sources/PiniCore/HIR/HIRLowerer.swift:3926` | `HIRType` | 有 `default` ⚠️ | `return nil` |
| 8 | `Sources/PiniCore/HIR/HIRLowerer.swift:4123` | `HIRType` | 有 `default` ⚠️ | 同 #6 族 |
| 9 | `Sources/PiniCore/Run/ProgramRunner.swift:259` | `HIRType` | 有 `default` ⚠️ | **`return .null`** ⛔ |
| 10 | `Sources/PiniCore/CodeGen/IREmitter.swift:2024` | `HIRType` | 有 `default` ⚠️ | `fatalError(...)` |
| 11 | `Sources/PiniCore/CodeGen/IREmitter.swift:2041` | `HIRType` | 有 `default` ⚠️ | 拼写兜底 |
| 12 | `Sources/PiniCore/CodeGen/IREmitter.swift:2195` | `HIRType` | 有 `default` ⚠️ | —（`stringSlice`） |
| 13 | `Sources/PiniCore/CodeGen/IREmitter.swift:2484` | `HIRType` | 有 `default` ⚠️ | —（LazyRef 元素 ABI） |
| 14 | `Sources/PiniCore/CodeGen/IREmitter.swift:2634` | `HIRType` | 有 `default` ⚠️ | —（`len` 分派） |
| 15 | `Sources/PiniCore/CodeGen/IREmitter.swift:3823` | `HIRType` | 有 `default` ⚠️ | — |
| 16 | `Sources/PiniCore/CodeGen/IREmitter.swift:3850` | `HIRType` | 有 `default` ⚠️ | — |

**汇总**：`HIRType` 侧 **13 处**（含无 default 的 1 处）· `Value` 侧 **3 处**（含无 default 的 1 处）·
**14 处带 `default`、仅 2 处穷尽**。

⛔ **最危险的一处是 #9**：`ProgramRunner.zeroValue(forTestParam:)` 对未知类型 `default: return .null`。
`char` 落进去会**静默得到 `null` 作零值**（正确值应是「空字符」）——**不报错、不 fail-loud**。
该函数是 R4 参数注入的零值源，注释明文写「两引擎必须一致」⇒ 静默错值会**同时污染两臂**。

### 11.2 影响面载体（订正 §1 事实 10）

**正确的数 = 15 份 `.pini` 载体**（14 份在 `Tests/PiniTests/` + 1 份 selfhost
`examples/selfhost/src/lexer/lexer.pini`）；**Swift 测试 0 份**。

⚠️ 原登记「18 份」的构成是错的，两处原因：

1. **4 份是假阳性**：`PassTests.swift` · `BacktickEscapeTests.swift` · `LexerTests.swift` ·
   `LexerCrosslineTests.swift` 的命中**全是 `keyword(` 的子串**（`is_letter\(` 等模式里的
   **`ord\(` 命中 `keyword(`**）—— 它们与字符面**无关**。
2. **漏了 selfhost**：`.gitignore` 含 `/examples/selfhost`（嵌套独立仓）⇒ **遍历 `examples/` 时被跳过**，
   只有**显式给路径**或加 `--no-ignore` 才搜得到。

### 11.3 判据 4 的弱点与补强（订正 §4 判据 4）

因 14 / 16 处带 `default:`，**「编译器不报穷尽性错误」这条判据只覆盖 2 处**
⇒ 若单用它，`C` 阶段会**报全绿而 14 处静默路径未受检**。

**补强（`C` 阶段必须配的第二条判据）**：以 §11.1 表为**逐处清单**，要求
① **清单每一行都有对应改动**（逐行勾，机械可核）；② 对**必须拒绝**的处（LLVM 侧、`ProgramRunner` 零值）
额外断言**行为**（fail-loud 或给对值），不能只断言「编译过」。

### 11.4 LLVM 端现值（`A4` 的答案，**实测，与登记不符**）

测法：`.build/debug/pini run` / `run-llvm` 各跑一份探针，**rc 不走管道**（落盘再读）。
字符串用 `"𝐀𝐁"`（**8 字节 / 2 grapheme**）。

| 面 | 解释器/HIR 臂 | LLVM 臂 | 两臂一致？ | `run-llvm` rc |
|---|---|---|---|---|
| `len(s)` | `2` | `2` | ✅ | 0 |
| `s[0]`（下标） | `𝐀` | `�`（**一个字节**） | ❌ **静默不一致** | 0 |
| `chars(s)` | `[𝐀, 𝐁]` | IR 调 `@chars` → **未定义符号** | ❌ | **0** |
| `is_letter("a")` | `true` | IR 调 `@is_letter` → 未定义符号 | ❌ | **0** |
| `is_number("3")` | `true` | IR 调 `@is_number` → 未定义符号 | ❌ | **0** |
| `is_ascii_digit("7")` | `true` | `true` | ✅ | 0 |
| `ord("A")` | `65` | IR 调 `@ord` → 未定义符号 | ❌ | **0** |
| `chr(65)` | `A` | IR 调 `@chr` → 未定义符号 | ❌ | **0** |

**两条读数上的要点**：

1. **`len` 是好的**（两臂都按 grapheme 计数，用的是 `emitStringCharCount`，不是字节路径）
   ⇒ §2 引的 `ADR-033` 「`lenCall` 码点 ❌」**已不成立**。⚠️ 该结论**必须用运行时来源验**：
   首测用字面量 `len("𝐀𝐁")` 得 2，但字面量可能被**常量折叠**（那样测的是解释器）；
   改用 `readFile` 读入同内容再做，仍得 2 ⇒ 结论站得住。
2. **登记的 `E6-002`「显式 unsupported」与实测不符**：实测不是一条具名诊断，而是
   **发射调用未定义符号的 IR + `rc=0`** ⇒ 属**静默坏产物**形态。
   ⚠️ **该形态已由在册工单覆盖，本格不新立案**：
   `docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md`（`rc=0` 那半）与
   `docs/issue-hir-string-slice-byte-based-2026-09-11.md`（字节切片那半）。
   ⇒ 本格的责任只是**把 spec `G45` 的过期表述改对**（§3 的 `P0d-B`），**不修这两处行为**。

### 11.5 selfhost 调用点（`A3` 的答案）

`examples/selfhost/src/lexer/lexer.pini` **8 处代码调用点**（另 1 处出现在**注释**里）：

| 行 | 调用 | 对 `Char` 迁移的敏感度 |
|---|---|---|
| 144 | `chr(48 + x % 10)` | 返回类型 `String` → `Char` 会**改变拼接语义** |
| 155 · 681 · 692 · 882 | `ord(...)` | 参数类型变更，见 §9 待裁 1 |
| 500 | `is_ascii_digit(c)` | 参数类型变更 |
| 504 | `is_letter(c)` | 参数类型变更 |
| 515 | `is_number(c)` | 参数类型变更 |
| 771 | `chars(src)` | 元素类型 `Array<String>` → `Array<Char>`，与 144 的拼接**下游相扣** |

`examples/selfhost/src/parser/parser.pini`：**0 处**（原命中的 6 行全是 `keyword(` 假阳性）。
⚠️ selfhost 是**嵌套独立仓**（`.gitignore` 屏蔽）⇒ 它**不在本仓历史内**；本格若使其不可编译，
代价须单独上报（§5 止损 3）。

### 11.6 本阶段的三处测量陷阱（**写器械/读数时必守**）

1. **`ord\(` 命中 `keyword(`** —— 子串碰撞，一次污染了影响面清单（4 个假阳性）与 selfhost 调用点
   （6 个假阳性）。⇒ 检索内建名**必须带词边界或排除 `keyword`**。
2. **`.gitignore` 的 `/examples/selfhost` 会让遍历静默跳过它** —— 显式给路径或 `--no-ignore` 才搜得到。
   ⇒ **影响面普查若只写 `examples/`，会得到「selfhost 零命中」的假结论**（本格首测即如此）。
3. **`PIPESTATUS` 是 bash 语法，本机是 zsh**（应为 `$pipestatus`）⇒ 我首轮的 `rc=` 全是**空值**，
   而空值**看起来像「没有错误」**。⇒ **判退出码一律不走管道**（落盘再读）。

---

## 12. `B` / `C` 阶段实录（2026-09-18）

**分支** `agent/pini-dev/p0d-char-landing`｜`B` = `42f902e` · `C` 部分一 = `22efd6d` · `C` 部分二 = `abe0f75`

### 12.1 `B` 阶段：规范与契约（**四处登记订正，全部实测**）

| 处 | 原登记 | 实测 / 订正 |
|---|---|---|
| `spec G45` | LLVM 端 `is_letter`/`is_number`/`chars` **显式 unsupported（`E6-002`）** | ⛔ **机制已不存在** —— 实测 `E6-002` 在 `Sources/` **零触发点**（只余诊断消息表条目），`IREmitter` 自陈「no unsupported paths」⇒ 现行行为是**发射调用未定义运行时符号的 IR** |
| `spec` 内建清单 | **29 个** | **33 个**（`BuiltinRegistry.decls` 逐组实测：char 6 · io 5）⇒ 漏登 `ord`/`chr`/`moduleRoot`/`argv` 四个 |
| `reference:368` | `Char` = **Unicode 标量值**，0–0x10FFFF | 与 `ADR-019 D1`（grapheme）**正面冲突** ⇒ 改写为字素簇并补判据与溯源 |
| `reference:738` | 允许表里列 `Char` | 改 `CChar`（该处指改名后的那个，与 spec `§2.7` 一致） |
| `reference:2541` | **禁止**表里列 `Char`，理由「C `char` 符号性由实现定义」 | ⚠️ **未按「改名」裁定执行** —— 该行在**禁止**表内，改名会把 `CChar` 写成禁用、与 `§2.7` 的 `G65` 增补相反。⇒ 保留 `Char` 禁用、**订正理由**为「字素簇无定长 C 表示」。**这是对用户裁定的一处有意偏离，已在提交信息与 `§7` 注明** |

**新立缺口 `G67`**（`Char` 类型落地）+ **契约 `§1` 新增 `char` 行** + `§4.1` 由「显式延后」转「已兑现」
+ `§4` 节标题改「两条均已兑现」+ `§6` 汇总表 `char` 行改状态。

⚠️ **两处替前批补的账**：① `§6` 汇总表里 `HIRNode.swift` 头部那条 `P5` **已改源码却漏改汇总行** ⇒ 本批补；
② 契档 `§1` 标题原写「20 case」而实现实为 **19**（既存差异）⇒ 兑现后实现为 20，**标题与实现就此一致**。

### 12.2 `C` 阶段：类型层 + 扩散点（**两处对 `ADR-033 D4` 的实测修正**）

**修正一：`TypeAnnotation` 不需要 `char` case。** `D4` 第 1 类列「三处类型表示」，
但实测内建标量（`String`/`I32`/…）**全部**以 `.simple(name:)` 承载 ⇒ 给 `Char` 单独一个 case
会把它变成**唯一有专属形态的标量**、新增 Parser 路径、并加宽所有 annotation 的 switch。
⇒ **改的是「名字归一化点」**（`HIRType.init?(from annotation:)`），**不是加 case**。
**两处表示，不是三处。**

**修正二：编译器只抓得到 4 处，另 12 处静默。** 逐轮构建实测：加 `char` 后仅
`HIRNode.isNumeric` · `RuntimeOps.describeValueKind` · `RuntimeOps.stringifyValue` ·
`IREmitter.hasNoScalarRendering` 四处报穷尽性错；其余站点**照常编译**（因带 `default:`）。
⇒ **`A` 阶段那张 §11.1 表才是本格的清单，编译器不是。**

**应用的规则（机械、可复核）**：`Char` **搭 `String` 的车** —— 表示同构 ⇒ 发射器每一处取与 `string` 相同的答案
（同 `i8*` 拼写、同 raw-ptr 装箱 tag、字符串片与打印同样处理）。两处并入 `string` 臂；
一处去重守卫因此**在两类型间共享同一个包装器**（同 ABI 的正当结果，非巧合）。

**唯一不循此规则的站点 = `ProgramRunner.zeroValue(forTestParam:)`**（`A` 判定的最危险处）：
显式写成 `.char → .null`（**不发明零值**：语言无「空字符」，注入任何值都会违反「恰含 1 个字素」的
不变式，且该函数**两臂共用**）⇒ **另立工单** `docs/issue-char-test-param-zero-value-2026-09-18.md`（登记不修）。

### 12.3 判据读数

| 判据 | 读数 |
|---|---|
| 构建 | ✅ 通过（`Build complete`，增量 2.4–3.9s） |
| **全量回归（两轮各一次，对父提交基线逐条比对）** | **42 = 42，集合相等**；新增红 **0** · 转绿 **0** · 仍红 42 |
| 契约核验 | `clean 62/62`（三锚点）—— **`char` 不进 §2/§3 计数，这是预期**（计划 §2 第 1 条） |
| 注释 lint | 六项全绿 |
| 文档链接 | 通过（1229 → 1233 引用） |
| 证据表 | schema 通过 |

⚠️ **口径订正**：基线我**实测**得 **42 个失败方法**；此前批次记录流通的是「**56 条断言**」。
⇒ **两个单位不可互换**（方法数 vs 断言数）。本格全程以「逐条集合」而非总数作判据。

### 12.4 一处过程质量问题（如实登记，**同一形态三次**）

本批我在改写单行时，**三次**把相邻行从 `old_string` 里漏掉、从而把该行删除：

| # | 位置 | 后果 |
|---|---|---|
| 1 | `spec` 台账 `G62` 行 | **删掉了整条 `G62`**，靠 `G` 号完整性核对发现并补回 |
| 2 | `spec §5.1` 索引表 `§3.2 指针算术` 行 | 删除，靠逐行核对发现并补回 |
| 3 | `RuntimeOps.valueKindName` 的 `case .rawPointer` 行 | 删除，紧接着发现并补回 |

⇒ **判据**：`old_string` 取单行时，**替换文本必须显式包含其全部相邻行**
（前一行与后一行都要出现在 `new_string` 里），改完立刻核对「删除行数 == 有意改写行数」。
三次都由**事后核对**兜住，**没有任何一次进入提交** —— 但这属**流程缺陷、不是运气**，已写进技能。



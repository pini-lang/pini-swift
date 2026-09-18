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
| 9 | **switch 穷尽性扩散面** | `case .string:` 共 **16 处 / 6 个文件** | `IREmitter` 7 · `HIRLowerer` 4 · `RuntimeOps` 2 · `ProgramRunner` 1 · `SubscriptStrategies` 1 · `HIRNode` 1。⚠️ **该数混合 `Value` 与 `HIRType` 两个枚举，是上界、不是 `HIRType` 专属面**（A 阶段要逐处分辨） |
| 10 | 影响面载体 | 命中 **18 份** | `chars(` + 五个谓词；含 selfhost 自举语料 `examples/selfhost/src/lexer/lexer.pini`（1375 行）与 `examples/selfhost/src/parser/parser.pini`（1593 行） |
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

- [ ] `auth-7` 之外**是否另有覆盖本体开工的 active 授权**（否则先补点名）。
- [ ] `A` 阶段四张表已出（尤其**扩散点的 `HIRType` 专属处数**）—— 它是 §5 止损 1 的判据。
- [ ] 契约 §1 的 19 vs 20、`ADR-033` 的 17 vs 20 两处数字**已定**（§2 第 5、6 条）。
- [ ] `ord` / `chr` 的签名读法**已裁**（§9）。
- [ ] 新格（LLVM shim）**已有排期与载体**（§7 第 3 项连带义务 ②）。
- [ ] 起点基线：全量回归与探针的**本格基准**是现跑还是沿用，须写明（不拿上一批清单做加减）。

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

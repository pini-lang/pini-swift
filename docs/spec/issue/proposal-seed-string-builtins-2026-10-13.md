# 提案：seed 字符串内建补齐（trimLeft / trimRight / indexOf）—— H2 批

> **状态**：**已裁决 · 实施中**（2026-10-13 用户裁定：D1 成员方法 · D2 只剥 ASCII 空格 · D3 字素单位 · D6 判别式挂语料；D5 原「归组」问题在成员形态下消解，余一项 inTrait 归属随讨论定）。
> **提案日期**：2026-10-13（同日裁决）。
> **上级载体**：`pini-bootstrap/docs/plan-host-side-derivation.md`（批 H · H2 行）；语言面变更走 `../pini-spec-v0.md` §1.3 变更治理流程。
> **读法**：只记结论与依据，不复制推演过程；实施读数随批回填（件末§9）。文件与符号定位为准，行号为软证据。

---

## 1. 动机

- **性能**：语料判据的 trim/查找今天只能逐字符循环——双层解释下约 0.1 秒/调用（规划件登记的两则实测：11 分钟微基准 · 100 行两法 8.8 s）。内建化后该面降至原生调用级。
- **歧义归一**：`indexOf` 在 **5 份层语料**各有一份同语义本地实现（`parser-shape` / `common-shape` / `subset-shape` / `type-coverage-shape` / `desugar-shape`）——同一规则五处书写即漂移本体；trim 族在语料里以 `leadingSpaces` 等手写循环存在（H3 的 wellformedBad 重写等着用）。
- **归属已裁**：派生/抽取/内建 = 宿主能力（2026-10-12 用户裁定「不计成本」）；自举侧语料只留判据本体（断言）。

## 2. 形态裁定（已裁决：成员方法）

**裁定形态（用户 2026-10-13）**——与既有字符串成员面同族的**成员方法**：

```
s.trimLeft() -> String          ; 剥离前导空格
s.trimRight() -> String         ; 剥离尾随空格
s.indexOf(needle) -> I32        ; needle 首现位置
```

与既有成员面（`contains` / `substring` / `split` / `upper` / `lower`，登记于 `BuiltinRegistry.memberMethods`）同一张表、同一条派发链。**与自由函数方案的关键差异（如实登记，均为代价侧）**：

1. **语料调用点改写**：5 份语料约 10 处 `indexOf(x, "|",)` ⇒ `x.indexOf("|",)`；5 份本地定义仍须删（否则成死代码，且新内建在自举侧无判据面）。
2. **符号表碰撞问题消解**：宿主 `registerBuiltins` 只把 `decls`（自由函数）注册进符号表，成员方法走成员调用路径、不经符号表查找 ⇒ 无 `redeclaredSymbol` 风险（原自由函数方案的最大硬约束在此形态下不存在）。
3. **自举落点迁移分发**：从 `irLowerCall` 自由名字分发改为 `irStringMethod` 成员分发，且需**新 IR 节点**（`src/ir/ir.pini` 与宿主 `IRNode.swift` 各 +3 用例）——面比自由函数方案大，但换来了与 `contains`/`substring`/`split` 完全同构的链路。
4. **必需集 guard 不覆盖成员面**：`tools/check-common.sh` 判据⑤-b 的调用形态 grep 排除点号调用（`[^.a-zA-Z0-9_]name(`）⇒ 成员内建不在其域；成员面的守 = 宿主单测 + 语料判别式 + type 九道（回归网）。

## 3. 语义规格草案（条款内容 · D2/D3 已裁）

本批要钉进语言规范件的条款正文草案（稳定性 Provisional；纯增量，不改变任何既有构造语义）。**本条款是规范件第一个内建成员条款**（无先例句式；SIG 派生视图条款只管视图、不管内建），记号用法在条款内自定：

```
trimLeft  : (String) -> String        ; 成员 s.trimLeft()
trimRight : (String) -> String        ; 成员 s.trimRight()
indexOf   : (String, String) -> I32   ; 成员 s.indexOf(needle)
```

| 内建 | 语义（要点） | 边界（钉死） |
|---|---|---|
| `trimLeft` | 剥离**前导**空格 | ⛔ 只剥 ASCII 空格 U+0020——**不含 tab 及其他空白**（与树渲染约定 `leadingSpaces` 一致）；空串 ⇒ 空串；全空格 ⇒ 空串 |
| `trimRight` | 剥离**尾随**空格 | 同上 |
| `indexOf` | `needle` 在 `s` 中的**首现位置** | 单位 = **字素**（与 `len`/`substring`/`slice` 同模型——字符模型 = Grapheme Cluster）；`needle` 为空 ⇒ 0；未找到 ⇒ −1 |

**同口径证明（切换正确性判据）**：5 份本地实现皆经 `len`/`substring` 书写 ⇒ 天然字素口径；内建按同口径实现 ⇒ **切换后语料既有读数必须逐字节不变**。这条同时是验收判据（§5）。

**影响评估（§1.3 第 2 步 · 如实登记）**：纯增量——无既有构造的语义变化；成员名为 String 新增三个名字。⚠️ 一项开工时实测：用户若可对 String 写扩展块且与新内建同名，按 §4.7「后声明覆盖」规则处置——该形态今日无判据，票内登记（§6）。

## 4. 实施步骤（六组 · 依序）

### S0 开工前置

1. 两仓各切分支：宿主仓 `agent/pini-dev/h2-string-builtins`；自举仓同名。身份按 `pini-swift/GIT_WORKFLOW.md` 注册表（`agent:pini-dev`）。
2. **H 前基线**：自举仓 `check-all` 全量跑一次。读数应与 H1 完工登记的 H 后读数一致（42 道门禁 / 非绿 4 道 / 预期非绿清单 4 条双向一致）；不一致先归因再开工。

### S1 规范件（语言面变更 · `pini-swift/docs/spec/`）

1. `../pini-spec-v0.md` 新增 §2.10「字符串内建（trimLeft / trimRight / indexOf）」：§3 草案全文入条（签名 / 语义 / 边界 / 单位 / 影响段）；位置照 §2.9（结构串派生视图）先例，稳定性 Provisional。
2. 证据登记：`../evidence-table.toml` 按 §1.3 第 5 步登记（符号定位为主）。
3. `docs/spec/CHANGELOG.md`（语言级）记里程碑条。
4. ⚠️ 语言参考**不随本批递交**（§1.3 递交条件三条：定级 Provisional ✓、实现侧有证据——本批落地后才满足、无未裁决张力）。先例：H1 的 SIG 条款亦延后递交。

### S2 宿主实现（`pini-swift` · 九处）

| # | 文件（符号定位） | 动作 |
|---|---|---|
| 1 | `Sources/PiniCore/Common/BuiltinRegistry.swift` · `memberMethods` | +3 条 `MemberDecl`（`typeName: "String"`）。**inTrait 建议 `false`**（扩展面——同 `substring`/`split`/`upper`/`lower`；⛔ 不迫使实现 collection 特征的用户类型提供；`inTrait: true` 的 D1 最小集是 contains/slice/join/append/pop）。此项即 D5 余项 |
| 2 | `Sources/PiniCore/IR/IRNode.swift` · IR 表达式用例区（`stringContains`/`stringSubstring`/`stringSplit` 同区） | +3 用例：`stringTrimLeft(receiver:)` / `stringTrimRight(receiver:)` / `stringIndexOf(receiver:needle:)` |
| 3 | `Sources/PiniCore/IR/IRLowerer.swift` · `lowerStringMethod` | +3 case（arity 检查 + 参数降载 + 类型标注，同 `contains`/`substring` 形态；`default` 分支的越界错误信息自动覆盖新名） |
| 4 | `Sources/PiniCore/Interpreter/IRExecutor.swift` · `.stringContains`/`.stringSubstring` 用例区 | +3 用例：字素口径——trim 两件借 `GraphemeCursor` 定位首尾非空格界再 slice；indexOf 借 `.stringContains` 的字素扫描思路返首现位置（未找到 −1、空 needle 0） |
| 5 | `Sources/PiniCore/CodeGen/IREmitter.swift` · `.stringContains` 用例区 + declare 区 | +3 用例：发射 `@bk_string_trim_left` / `@bk_string_trim_right` / `@bk_string_index_of`；置 `usesStringShims`；declare 区补三行（漏 declare ⇒ clang 报 undefined value，既有教训） |
| 6 | `Sources/PiniRuntime/PiniRuntime.swift` | +3 个 `@_cdecl` shim（命名随 `bk_string_*` 族）：字素口径；分配契约 = strdup、调用方释放（同 `bk_cstr`/`bk_read_file`）；`index_of` 返 i32 |
| 7 | `Sources/PiniCore/Type/TypeChecker.swift` · `registerBuiltinTypes` | **零改动**——实测该处循环 `memberMethods` 派生 `defineMethod`（成员表即类型层签名单一事实源）；须验证调用点类型贯通 |
| 8 | `Tests/PiniTests/StringBuiltinTests.swift`（新套件，仿 `SignatureSerializationTests` / `ListDirBuiltinTests` 形态） | 三内建逐条判别式 + 边界（空串 / 全空格 / 无空格 / 首尾混合 / 未找到 / 空 needle / 多字素串）+ **三腿锁步**（解释器 / `lli`-JIT / `clang`-AOT，承 `RuntimeBackendTests` 精神） |
| 9 | `Sources/PiniCore/Common/Version.swift` + `docs/CHANGELOG.md` + `docs/spec/ir-contract.md` | bump 0.56.0；CHANGELOG 条照 H1 先例（非破坏性、纯增量 + 影响段如实写）；**ir-contract.md 登记 3 个新 IR 节点的语义**（IR 契约是 IR 节点语义的权威处——两侧后端都不是定义处） |

### S3 自举同面（`pini-bootstrap` · 五处；语言面扩张 = 三处实现的同步义务）

| # | 文件（符号定位） | 动作 |
|---|---|---|
| 1 | `src/ir/ir.pini` · IR 节点区（`irStringContains`/`irStringSubstring`/`irStringSplit` 同区） | +3 节点：`irStringTrimLeft(receiver: IRExpr,)` / `irStringTrimRight(receiver: IRExpr,)` / `irStringIndexOf(receiver: IRExpr, needle: IRExpr,)` |
| 2 | `src/ir/lower.pini` · `irStringMethod` | +3 分支（同 `contains`/`substring`/`split` 形态：arity 检查 + `irLowerExpr` 参数 + 返回新节点；未知名走既有 `ir-skip: unknownStringMethod`） |
| 3 | `src/interpreter/exec.pini` · `irStringContains` 用例区 | +3 节点用例（字素口径；本仓解释器即语料的执行面——`ivTestFile` = parse → `irLowerModule` → `ivRunTests`，实测不过类型层） |
| 4 | `src/codegen/emit.pini` · 成员分发（`mname == "contains"` 同形态）+ `inferTypeName` 成员分支 | +3 分发（发射对宿主侧新 shim 的调用、置 `usedStringShims`）+ 类型推断分支（trim 两件 → `String`；indexOf → `I32`） |
| 5 | `src/codegen/emit-ir.pini` · IR 文本渲染（`irStringSubstring`/`irStringSplit` 同区） | +3 渲染 |

**零改动件（实测确认）**：`src/common/common.pini`（自由内建表不涉成员面）· `src/semantic/analyzer.pini`（成员调用只查接收者，`requireDefined` 的 builtin 检查只覆盖自由函数名）· `src/type/`（语料路径不过类型层；类型层今日不建模内建成员——见§6 遗留）· `tools/check-common.sh`（⑤ 双向对账只覆盖两张自由内建表；必需集 grep 排除点号调用 ⇒ 成员面不在其域）。

### S4 语料切换与判别式（`pini-bootstrap/tests/layer/`）

1. **删 5 份本地 `indexOf` 定义 + 改写约 10 处调用点为成员形态**：
   - `parser-shape.pini`：`indexOf(li, "|",)` / `indexOf(rest, "|",)` ⇒ `li.indexOf("|",)` / `rest.indexOf("|",)`
   - `common-shape.pini`：`indexOf(reloadRest, "|",)` ⇒ `reloadRest.indexOf("|",)`
   - `subset-shape.pini`：`indexOf(t, "|",)` ×2 ⇒ `t.indexOf("|",)`
   - `type-coverage-shape.pini`：`indexOf(t, "|",)` ⇒ `t.indexOf("|",)`
   - `desugar-shape.pini`：`beforeFirst`/`afterFirst` 内 `indexOf(s, sep,)` ⇒ `s.indexOf(sep,)`
2. **切换正确性**：改后语料报告与改前逐字节相同（内建与本地实现同口径）；不同即归因，⛔ 不改期望凑绿。
3. **trim/indexOf 判别式（D6 裁：挂 `common-shape.pini`）**：新增 `|test` 函数（断言形态照本件既有 `assert(条件, 消息)` 写法）——trim 两件各一组（全空格 / 无空格 / 首尾混合 / 多字素串），indexOf 一组（空 needle ⇒ 0 / 未找到 ⇒ −1 / 首·中·末位置 / 多字素单位）。经 `check-layer-corpora.sh` 的 common 行驱动（`pini run . test`，种子即宿主产物）。⚠️ 判别式写在测试体，⛔ 不进 TOML 读取热循环（本件热路径硬约束只管循环内；测试体断言照旧）。
4. **覆盖矩阵（如实登记）**：

| 实现面 | 判据面 |
|---|---|
| 宿主全链（成员表 / 类型 / 降载 / 解释器 / 发射器 / shim） | `StringBuiltinTests` 三腿锁步 |
| 自举 lower + exec | 语料判别式（`pini run . test` 驱动） |
| 自举 emit + emit-ir | **本批无判据面**（src 无用法；codegen 族门禁属对齐批）⇒ 遗留，触发条件 = src 首次采纳 或 codegen 夹具入格（§6） |
| 自举类型层 | 不涉及（语料路径不过类型层；类型门夹具本批不用新内建） |

### S5 种子与版本

1. 宿主 release 构建 ⇒ 产物放置 `.tools/`（手动）⇒ `tools/check-seed.sh` 取新内容键 ⇒ 填 `tools/seed-manifest.toml` 键行（成因 = 换种子 + 本仓源件改动，两者皆预期）⇒ 复跑绿。
2. 原生臂随 srcstamp 自动重建；新内建不扰动既有发射 ⇒ 重建产物与批前逐字节相同（列为验收读数）。

### S6 回归与验收

1. **type 九道**（`check-type-decl` / `-closures` / `-expressions` / `-ffi` / `-generics` / `-seams` / `-state` / `-statements` / `-visibility`）现绿当回归网——自举类型层本批零改动，九道全绿是底线。
2. **check-all 全量 ×2**：H 前（S0 基线）与 H 后双跑达成；H 后读数须与基线相同或更干净（预期非绿 4 条形态照旧）。
3. **变异反证 3 条**（每内建一条，宿主单测层）：`trimLeft` 改成连 tab 一起剥 ⇒「tab 不剥」判别式红；`indexOf` 空 needle 改返 −1 ⇒ 该判别式红；`indexOf` 单位改字节 ⇒ 多字素判别式红。

## 5. 验收判据（逐条过，缺一不合格）

1. 规范件 §2.10 立条，三内建签名/语义/边界/单位逐条钉死；ir-contract.md 三个新 IR 节点语义登记在案。
2. 宿主：`StringBuiltinTests` 全绿（含三腿锁步）；`swift test` 全量绿。
3. 语料：5 份本地定义删除 + 调用点改写后，`check-layer-corpora.sh` 驱动各入口读数与改前逐字节一致；trim/indexOf 判别式绿。
4. 种子：`check-seed.sh` 绿（新键已登记 manifest）；原生臂重建产物与批前逐字节相同。
5. `check-all` ×2 达成，H 后读数不低于基线。

## 6. 代价、风险与遗留（如实登记）

- **自举发射器无判据面（本批最大遗留）**：`emit.pini`/`emit-ir.pini` 的新分支只有 src 采纳新内建后才被 arm 构建/codegen 夹具覆盖；本批语料判别式只覆盖 lower + exec。处置：登记遗留 + 触发条件；⛔ 不为覆盖而强扩面（codegen 族门禁现状属对齐批，强接即红）。
- **自举类型层不建模内建成员**：`tyCheckBuiltinMemberExistence` 对 String/Array 未登记成员判 `unknownMember`——语料路径不过类型层故无影响；但类型门夹具若用新内建会红。本批不碰（无需求）；如未来类型门要覆盖成员面，须先在自举类型环境建成员表（独立小批）。
- **用户对 String 写同名扩展块的形态未实测**：按 §4.7 后声明覆盖规则预期处置，开工时实测登记。
- **IR 节点新增面**：两侧 IR 各 +3 用例 ⇒ ir-contract.md 必须同批登记（IR 契约是语义权威处；漏登记 = 两侧实现各写一份语义）。
- **三处实现同步义务**：宿主（表/降载/解释器/发射器/shim 五处一链）+ 自举（节点/降载/解释器/发射器/渲染五处一链）语义漂移 ⇒ 由语料判别式（同口径读数不变）+ 宿主三腿锁步 + type 九道守。

## 7. 解锁与不在本批范围

**解锁**：H3 的 wellformedBad 用 trim 内建重写（规划件 §3）；全语料热循环调用数降 5–10×（规划件 §2.4）。

**不在本批**：replace/regex 类内建（规划件明文 ⛔）· wellformedBad 语料改写（H3）· awk 抽取删除（随退役批点名）· 语言参考递交（延后，§1 步 4）· 自举类型层成员表（§6 遗留，独立小批）· 对齐批（批 6）独立推进不受本批影响。

## 8. 裁决记录（2026-10-13 · 用户）

| # | 决策 | 结论 | 依据 |
|---|---|---|---|
| D1 | 内建形态 | **成员方法**（`s.trimLeft()` / `s.indexOf(needle)`） | 用户裁定；与既有字符串成员面同族（§2） |
| D2 | trim 空白口径 | **只 ASCII 空格**（不含 tab） | 用户确认；与树渲染约定一致，语料零漂 |
| D3 | indexOf 计数单位 | **字素** | 用户确认；与 `len`/`substring` 同模型、与 5 份本地实现同口径 |
| D5 | 内建归组 | 原问题在成员形态下**消解**（成员表无组概念）；余项 = `inTrait` 归属，**建议 false**（扩展面） | 随讨论定 |
| D6 | trim 判别式落点 | **挂 `common-shape.pini` 语料**（本人裁决） | 自举 lower+exec 当批有判据面；宿主侧由三腿单测覆盖；发射面遗留如实登记（§6） |

## 9. 实施回填（执行时填写）

- H 前基线读数：**42 道 / 非绿 5 / 清单 4 条双向一致**。第 5 道 = `check-common` 判据③版本锚
  （宿主已 bump 0.56.0、自举层还是 0.55.0）——**在途改动所致，非回归**，S5 随 `common.pini` 版本
  字面量同步后消（已验：`check-common` 复跑全绿）。另记一次**假红**：首跑漏设 `PINI_HOST_REPO`
  （host-resolve.sh 唯一手段、刻意不猜）⇒ 非绿 16 道，带变量重跑即回到 5。
- 宿主单测读数（通过数 / 三腿 / 变异反证 3 条各打中）：**214 测试 / 32 套件全通过**（28 known
  issues 为既有响亮跳过）；三腿（进程内解释器 / CLI `run` / CLI `run-llvm`）齐绿。变异反证
  **3/3 打中**：M1「trimLeft 连 tab 一起剥」红、M2「空 needle 返 −1」红、M3「indexOf 改字节单位」红。
  ⚠️ 教训：M2/M3 首次用 `--filter` 跑时**返回假绿**（llbuild 增量陈旧命中）⇒ 改全量跑即红。
- 语料切换前后逐字节比对读数：**一致**（8 行语料全绿），唯一差异 = `common-shape` 5→6（新判别式）。
- 种子新内容键：**`c5c22cdfc0d668f328304228ec7b879a98d4f4d80eacb133c1d1148b6532dabf`**（同批第二次换键：
  `exec.pini` 三处实现由循环内逐字符 `substring` 改为 `split("")` 一次成数组，见下）。
- H 后 check-all 读数（42 道 / 非绿 n / 清单双向一致）：**42 道 / 非绿 4 / 清单 4 条双向一致** ——
  = H1 完工形态（基线那第 5 道在途版本锚已随 S5 消）。中间曾出现 3 道新红，逐道归因并处置：
  ① `check-ir-lower` 判据② —— 自举侧契约切片清单（内嵌 SLICE_TABLE + SLICE_MAP 三侧对账）未登记
  三个新节点 ⇒ 登记后绿；② `check-cg-leg-partition` —— 三个新发射函数被分类器判 FUSED 而未入
  登记册 ⇒ 按既有 `emitContainsCall` 同例登三行后绿（FUSED 159→162）；③ `check-charmodel` 判据⑤
  —— 我在 `exec.pini` 写的三处循环内逐字符 `substring` 属新的 O(n²) 扫描点 ⇒ 按台账自身建议的
  **第一种处置**改为「一次成数组」（与既有 `contains` 同形：`split("")` + O(1) 索引）⇒ 扫描点
  94 ⇄ 面册 94 双向一致、**台账零改动**，charmodel 回到基线态（判据②-b 无法判定，与 H 前同形）。

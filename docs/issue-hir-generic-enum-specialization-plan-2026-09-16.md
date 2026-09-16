# G-2d 规划：泛型枚举用例构造（限定为准 · 裸名为糖）

> **批**：`P4-γ` 子批 `G-2d` **前置规划**（**纯规划，不含实现**）｜**日期**：2026-09-16｜**状态**：**待点名开工**
> **用户裁决（2026-09-16）**：形态取 **C** —— **限定形态为准、裸名形态为糖**。
> **上游**：在册工单 `docs/issue-hir-generic-enum-specialization-2026-09-16.md`（本件订正其两处成本表述，见 §7）
> **批表**：`docs/issue-hir-p4-gamma-plan-2026-09-16.md` §2.2 的 `G-2d` 行 · **执行记录**：`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-2d ❌ 未交付` 行
> **判据基线**：`G-2` 收口 **75** failures（`main` = `4fc89b3`，130 类逐类单跑）
> ⚠️ **本件不建实现、每阶段须单独点名**；本批已按仓规先建交付分支 `agent/pini-dev/p4-gamma-g2d-plan`。

---

## 0. 一句话

`G-2d` **不是**「照结构体那条特化路抄一遍」。读码实测：**类型层已经做完**、**`match` 与执行器一行都不用改**，
缺的只有**降载层的三个中间站**（用例名→父枚举 · 产出特化枚举体 · 注册进两张表）。
但用户选定的 **C** 带出一件**必须先走规范变更治理**的事：语言面从未定义「泛型枚举的显式类型实参挂在哪」。
且「限定形态」在解析层有三种候选拼写，**代价相差一个数量级** —— 这是本批唯一需要再裁的点。

---

## 1. 事实基础（全部读码实测，`4fc89b3`；行号即锚点）

### 1.1 待转绿的 5 条红里，**只有 3 条属本批**

| 用例 | 夹具 | 期望 | 属本批 |
|---|---|---|---|
| `testGenericEnumConstructionAndMatch` | `ok<I32, String>(42)` → `42` | 特化 | ✅ |
| `testGenericEnumErrBranch` | `err<I32, String>("boom")` → `boom` | 特化 | ✅ |
| `testGenericEnumDistinctSpecializations` | `满<I32>(5)` + `空<String>()` → `5` / `none` | 特化 | ✅ |
| `testGenericEnumArgumentCountMismatch` | `ok<I32>(42)`（少一个实参） | **运行期** `RuntimeError`（文案「实参个数不符」） | ❌ **错误通道** |
| `testUndefinedGenericTypeStillThrows` | `不存在<I32>()` | **运行期** `RuntimeError` | ❌ **错误通道** |

后两条的成因是 `G-2` 暴露的头号议题（静态降载层在编译期拒了测试期望的运行期错误），
已单独立案 `docs/issue-hir-static-rejection-vs-runtime-error-2026-09-16.md`。
「实参个数不符」这句文案实测由**旧解释器**在运行期产生（`Sources/PiniCore/Interpreter/Interpreter.swift:1614`）。

⇒ **本批承诺 = 3 条转绿**，不承诺 5 条。这一条必须写进验收，否则收口时会被读成「缺口 2 条」。

### 1.2 从源码到执行的五站：**两站已有、三站缺**

| # | 站 | 位置 | 现状 |
|---|---|---|---|
| 1 | 解析 `ok<I32, String>(42)` → `.genericConstruct(typeName: "ok", typeArgs: [I32, String], arguments: [42])` | `Sources/PiniCore/AST/Expressions/Expression.swift:60` | ✅ 已有（解析器前瞻判定） |
| 2 | **用例名 → 父枚举** | 类型层有 `enumCaseToParent` / `caseParentMulti`（`Sources/PiniCore/Type/TypeEnvironment.swift:418-421`）；**降载层不持有类型环境** | ❌ 缺 |
| 3 | **产出特化枚举体**（载荷类型 `T→I32`、`E→String`） | 类型层已有 `lookupSpecializedEnumCase(typeName:typeArgs:caseName:)`，**连类型替换都做完**（`TypeEnvironment.swift:428-443`） | ❌ 缺（降载层侧） |
| 4 | **注册进降载层的 `enums` 与 `userTypes` 两张表** | 结构体那条路的先例 = 特化体塞进 `nominals`（`Sources/PiniCore/HIR/HIRLowerer.swift:358-380`）；枚举走 `enums` + `userTypes`（同件 `:386-428`） | ❌ 缺 |
| 5 | `enumConstruct` 节点 → `match` 分派 → 执行器 | 节点已存在（`Sources/PiniCore/HIR/HIRNode.swift:259`）；`lowerMatch` 的 `.enumeration(let enumName)` 分支**按名字**查 `context.enums[enumName]`（`HIRLowerer.swift:3656`）；执行器 `matchStmt` **刻意不读 `scrutineeType`**、按值比对（`Sources/PiniCore/Interpreter/HIRExecutor.swift:1610-1615`） | ✅ **一行都不用改** |

### 1.3 三条硬约束（决定了设计只能这么走）

1. **`HIRType` 不带类型实参**：只有 `nominal(name:isObject:)` 与 `enumeration(name:)` 两个名字形态
   （`HIRNode.swift:52-55`）⇒ 特化只能**内化进名字**（`结果_I32_String`），
   命名沿用既有 `specializedSourceName` 约定（`HIRLowerer.swift:60`，结构体在用 `盒_I32`）。
   ⇒ **这不是新机制，是既有约定**。
2. **`dotCaseRef` 只带名字**（`Expression.swift:80-82`）⇒ 点号形态**无法携带类型实参**。
3. **降载层已有点号用例构造路径**：`.ok(42)` → `.dotCaseRef("ok")` → `resolveEnumCase` →
   `lowerEnumCaseConstructor`（`HIRLowerer.swift:2444-2448`）⇒ 非泛型枚举的构造路径是通的，
   泛型枚举要在**同一条路上**补「先按实参特化」。

### 1.4 解析层：三种候选「限定」拼写的实测形状

⚠️ 本条是**读码推断，未跑构建实测**（见 §8）。三种拼写代价不同：

| 拼写 | 解析产出 | 代价 |
|---|---|---|
| **S1** `结果<I32, String>.ok(42)` | `member(base: genericConstruct(结果, [args], arguments: []), "ok")` 再被调用后缀包裹（依据：`Sources/PiniCore/Parser/Parser.swift:2885` 注释 ——「若 `>` 后跟 `.`，先构造无参 `genericConstruct`，后续由 `parsePrimarySuffix` 处理成员访问」） | **只改降载层**：把「无参 `genericConstruct` 作成员基」解释为「带实参的枚举类型引用」。**不新增节点、不改解析器** |
| **S2** `结果.ok<I32, String>(42)` | 需要「成员名带类型实参」的解析支持 | 改解析器 + 新节点字段 |
| **S3** `.ok<I32, String>(42)` | 需要 `dotCaseRef` 长出 `typeArgs` 字段 | 改节点 + 改解析器 + 改全部 `dotCaseRef` 消费点 |

⇒ **建议取 S1**：它是唯一不动解析器与新节点的形态，且「类型实参挂在枚举名上」正好让
类型层现有的**按枚举名**校验 `genericEnumParamCount(name:)`（`Sources/PiniCore/Type/TypeChecker.swift:1940`）
**免费生效** —— 实参个数校验从运行期回到静态层，这正是 §1.1 那两条错误通道红的成因之一。
（S1 仍不能单独解决那两条：它们要求的是**运行期**报错，而静态层会先拒。）

### 1.5 成本：一处会被放大 42 倍

`precollectGenericUses` 的四个重载合计穿 `genericStructTemplates` **42 处**
（`HIRLowerer.swift:665/711/725/787` 四个签名）。
⇒ **加第三张模板表若按「再加一个参数」做，就是再铺 42 处**。
建议改为传**一个准备好的结构体**（模板三张表 + `state`），单点改一次类型、各站点不增参数。

---

## 2. 分阶段（**每阶段须单独点名**）

依赖顺序：**S0 → S1 → S2**。三者**不得合并**：S0 是语言面登记（治理），S1 是实现，S2 是判据收口。

| 阶段 | 名称 | 内容 | 判据 |
|---|---|---|---|
| **S0** | **语言面登记**（走规范变更治理流程） | ① **提议**：泛型枚举用例构造的两种形态与优先级；② **影响评估**：触及 §1.4 的三种候选拼写、`ADR-026 D1` 三档解析顺序、`ADR-023` 对点式限定的既往决定；③ **登记**：新建 ADR（或挂 `ADR-026`）＋规范缺口台账（如适用）；④ **落地**：规范 EBNF 注＋语言参考的「枚举声明」「泛型」两章补构造形态＋`CHANGELOG` 迁移说明（若有用户可见变更）；⑤ **证据登记** `E-0xx`（符号级过筛 + FRESH 时间戳） | 五个落点齐备且**先于** S1 任何代码改动；**实现不得先于登记** |
| **S1** | **降载层三站** | ① 收集 `genericEnumTemplates`（`!ed.genericParams.isEmpty` 的枚举）＋ 用例名→模板索引；② 穿参改为传结构体（§1.5）；③ `.genericConstruct` 站点：解析父枚举（**限定形态直接给出；裸名落 D1 三档**）→ 建特化体（载荷类型替换）→ 注册进 `enums` + `userTypes`；④ 构造发射改为 `enumConstruct(enumName: 特化名, …)`；⑤ `lowerMatch` / 执行器**不动** | ① 3 条指定用例转绿（逐条点名）；② **无新增红**（与 75 逐条两方向比对）；③ 探针 319 夹具逐夹具 `cmp` **零位移**；④ **契约节点计数不变**（44 + 16）；⑤ 编译 0 error |
| **S2** | **判据与收口**（若不单独点名则并入 S1 收口） | 全量两方向回归 + 探针 + 执行覆盖对账 + 计划件回填 + 工单维护 + `--no-ff` 合并 | 默认(HIR) 与 `PINI_INTERP_ENGINE=ast` 两方向**失败集合逐项相同**；执行覆盖 vs 基线 130 类；`DID_NOT_RUN` 单列 |

---

## 3. 验证点（每阶段必跑，缺一不可）

1. **编译**：`TMPDIR=/tmp swift build --disable-sandbox` 0 error（⚠️ `TMPDIR` 是必需的；后台拿不到沙箱豁免 ⇒ 前台跑）。
2. **目标用例逐条点名**：`--filter GenericEnumTests` / `GenericRuntimeTests`，逐方法报转绿/仍红，
   **不用「标记点消失数」代替「用例转绿数」**。
3. **全量两方向**：默认(HIR) 与 `PINI_INTERP_ENGINE=ast` 的失败集合**必须逐项相同**
   （本批只动 HIR 侧 ⇒ `ast` 方向应零位移 —— 这是「没碰旧引擎」的证人）。**先报「执行类数 vs 基线 130」**。
4. **探针**：`TMPDIR=/tmp python3 tools/hir-parity-probe.py --out /tmp/g2d-probe.tsv`，与冻结件逐夹具 `cmp`。
   **本批不新增夹具**（新增会动分母 319，使既有冻结件失去同语料前提）。
5. **契约面**：`python3 tools/hir-contract-check.py` —— 计数必须仍是 44 expr + 16 stmt。
6. **LLVM 侧**（实测项，非承诺）：`pini emit` 对新特化名义名的接受度。
   ⚠️ 已知同型风险：LLVM 侧「已实现面」小于降载层「接受面」时会 **rc=0 却产出引用未定义符号的 IR**
   （`docs/issue-hir-argv-llvm-runtime-surface-2026-09-16.md` §8）⇒ 须实测，不得推断。

---

## 4. 止损点

1. **S1 若 S1 拼写（`结果<I32, String>.ok(42)`）在解析层实测不成立** ⇒ **停，回报**，不擅自扩解析器或改节点。
2. **转绿 < 3 条** ⇒ 停，说明还有更早的遮蔽层（沿用 `P4-1a` 的「首缺口遮蔽」教训）。
3. **若本批需要改动契约节点计数（60）** ⇒ 停，先走**规范变更治理流程**（与 `P4-γ` 规划同一止损线）。
4. **单批回归 >5 失败且 >1 小时无收敛** ⇒ 停（沿用 `ADR-031` §4 口径）。
5. **S0 未完成而 S1 被点名** ⇒ 拒绝开工并回报（治理顺序硬约束）。

---

## 5. 不做范围

- **不做**另 2 条错误通道用例（归在册议题，本批做完它们**预期仍红**，属**已知**、不属缺口）。
- **不修** `run-llvm`、测试基建 SIGPIPE / `SuspendRuntimeTests` 偶发崩溃、REPL 声明识别等在册缺陷。
- **不动** `Sources/PiniCore/Interpreter/Interpreter.swift`（旧引擎坐标不动；本批只让 HIR 侧追上）。
- **不改**契约节点计数与 `HIRType` 的既有形态（新增 `enumeration` 的类型实参形态**不在本批**）。
- **不新增夹具**（冻结件同语料前提）。
- **不动**规范与语言参考的正文 —— **除 S0 点名的那次登记**。
- **不把本规划当成开工授权**：S0 / S1 / S2 须分别点名。

---

## 6. 工单维护（本批收口时执行，**不在规划内动**）

订正在册工单 `docs/issue-hir-generic-enum-specialization-2026-09-16.md` 的两处成本表述：

| 原文 | 实测订正 |
|---|---|
| 「缺的是**一整个特化族**……与 `registerStructSpecialization` 同形，但**多一条 `match` 分派链**」 | **偏重**：类型层已有同功能件（§1.2 第 2/3 站）；`match` 分派链**不成立** —— `lowerMatch` 的 `.enumeration(name:)` 分支按名字通用、执行器更刻意不读 `scrutineeType`（§1.2 第 5 站） |
| 「受影响的用例：`GenericEnumTests` 4 条 · `GenericRuntimeTests` 1 条」（未区分性质） | **补一句**：其中 2 条属**错误通道**议题、不属本批（§1.1） |

---

## 7. 复现方式（勘测本规划所依据的量）

```sh
# 特化状态的既有两族（无枚举族）
sed -n '45,60p' Sources/PiniCore/HIR/HIRLowerer.swift

# 类型层已完成的泛型枚举件
sed -n '400,444p' Sources/PiniCore/Type/TypeEnvironment.swift

# 降载层的枚举注册 + 载荷解析失败点
sed -n '382,428p' Sources/PiniCore/HIR/HIRLowerer.swift

# match 分派按名字通用 / 执行器不读 scrutineeType
sed -n '3650,3662p' Sources/PiniCore/HIR/HIRLowerer.swift
sed -n '1610,1616p' Sources/PiniCore/Interpreter/HIRExecutor.swift

# 穿参面（42 处）
grep -c genericStructTemplates Sources/PiniCore/HIR/HIRLowerer.swift   # 用 rg，勿用本机 grep 存根

# 待转绿的 5 条夹具
for f in Tests/PiniTests/GenericEnumTests/*.pini Tests/PiniTests/GenericRuntimeTests/*.pini; do echo "--- $f"; cat "$f"; done
```

---

## 8. 未实测项（**诚实标注**）

1. **§1.4 的三种限定拼写形状是读码推断**（依据 `Parser.swift:2885` 的注释与 `parsePrimarySuffix` 逻辑），
   **未跑构建验证**。⇒ S1 的**第一步**必须是实测这三种拼写的解析产出（也是止损点 1 的观察点）。
2. **未复核 `GenericEnumTests` 4 红的当次失败文本**：引用的是 `G-2` 执行记录件与工单的实测结论，不是本次现跑。
3. **LLVM 侧对新特化名义名的接受度未测**（§3 第 6 条已列为验证点）。
4. **S0 的落点清单（ADR 新建还是挂 `ADR-026`）未预判** —— 属 S0 的提议内容，须与影响评估一并裁。

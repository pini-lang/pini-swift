# Issue：FFI 单字节 `Char` 改名 `CChar`（腾出 `Char` 名给 grapheme）

- 状态：**Open —— 主题已转移**。① **原主题「腾出 `Char` 名」已实施（2026-09-17）**；
  ② **现行主题 = 「`CChar` 面不可运行」**（`*CChar` 过检查器，但两台引擎都解析不出元素类型，
  见文末 §A.2）⇒ ⚠️ **可归档条件 = 无，维持 Open**。
- 排期依据：`D-P4-36`（`P0d` 取「C 先行 + 本体取 B」⇒ **前置腾名现在做**）
- ⚠️ **本单的实施结果与原计划不同**（原「处置 3」不可达，已改判），**实施实录见本文末**
- ⚠️ **别把「已实施」读作「可归档」**：头部旧行只写了实施动作完成，未写主题转移 ——
  2026-09-18 工单巡查批据文末原话订正（原话：「本单**可归档条件** = 无（仍有 A.2 的死面未处置
  ⇒ **维持 Open**，但主题已从『腾名』转为『`CChar` 面不可运行』）」）。
- 层级：**宿主级** —— 实施 `ADR-033 D2` 的**语言级已裁决策**（契约变更本身已经 `ADR-033` 治理），
  本工单只承载 pini-swift 侧落地。层级判据见 `ADR-024 D6`；目录约定见 `docs/README.md`。
- 发现来源：P0c 复审期间的命名冲突勘查
  （见 `docs/spec/issue/archive/issue-interpreter-hir-gap-audit-2026-09-12.md` §5.5）
- 关联：`docs/spec/adr/adr-033-char-type.md`（**D2 裁决来源**）；
  `docs/spec/pini-spec-v0.md` §2.7（FFI 白名单：「`Char` 不进入 FFI 标量集」）；
  `docs/issue-interpreter-hir-plan-2026-09-12.md`（**P0d 前置于本工单** —— 须先腾名才能引入 grapheme `Char`）

## 问题：`Char` 一名两义，且现有义本就与 spec 冲突

| 面 | `Char` 的语义 | 状态 |
|---|---|---|
| 语言（`ADR-019 D1` / `ADR-033`） | **grapheme 字符**（用户感知的「一个字符」） | 待引入（P0d） |
| 现状实现 | **C 单字节**（`*Char` 指针元素，按 `UInt8` 编解码） | 已存在 |

两条独立问题叠加：

1. **一名两义**：`ADR-033` 要引入 grapheme `Char`，与既有 FFI `Char` 撞名。
2. **既有 FFI `Char` 本就偏离 spec**：`docs/spec/pini-spec-v0.md` §2.7 明文
   「**`Char` 不进入 FFI 标量集**：C `char` 符号性由实现定义，字节缓冲统一用 `I8`/`U8`；
   `Char` 保留为**一般语言类型**，不出现在 FFI 签名」——即实现自造了规范明确排除的用法。

⇒ 改名同时解决两件事：**腾出名字** + **让 `Char` 回归 spec 已声明的「一般语言类型」定位**。

## 实测影响面（2026-09-12，全仓检索；⚠️ **2026-09-17 订正位置**）

**极小 —— 共 3 处代码 + 1 处注释；零语料、零测试。**

> ⚠️ **2026-09-17 实测订正：下表两处位置已漂** —— `Interpreter.swift` 的 675 / 717 两行
> **已随 `P1-2` 的值层提取移到 `Sources/PiniCore/Runtime/RuntimeOps.swift`**（`case "Char"` 的 load/store），
> 且 **`Interpreter.swift` 现全仓零 `Char` 命中**。⇒ 连带一个好消息：
> **本单不再命中 AST 走查冻结面**（`tools/ast-walk-freeze-check.py` 管 `Interpreter.swift` 与
> `SuspendEvaluator.swift` 两个文件）—— 旧清单若照抄，会误以为要打 `[ast-walk]` 标记。
> 下表按**改名前实测**重列（4 处，位置为 2026-09-17 现址）。

| 位置 | 内容 |
|---|---|
| `Sources/PiniCore/Type/TypeChecker.swift:1111` | `isCScalarType` 集合含 `"Char"` |
| `Sources/PiniCore/Type/TypeChecker.swift:1177` | 注释「顶层 FFI 签名白名单（C 兼容标量，含 Char；…）」 |
| `Sources/PiniCore/Runtime/RuntimeOps.swift:318`（**原 `Interpreter.swift:675`，已漂**） | `case "Char": return .int(Int(rp.pointer.load(as: UInt8.self)))` |
| `Sources/PiniCore/Runtime/RuntimeOps.swift:397`（**原 `Interpreter.swift:717`，已漂**） | `case "Char": ptr.storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)` |

**「零使用方」的实证**（决定本工单为零回归）：

- `examples/**`、`Tests/**` 内 `*Char` / `: Char` / `-> Char` **全仓检索无命中**（仅文档命中）
  ⇒ **改名不破坏任何既有程序**。
- `Tests/` 内 `\bChar\b` **零命中** ⇒ **不改任何测试**。
- `Sources/` 内 `\bChar\b` 仅上述 4 处（含 1 条注释）⇒ **实现面改动封闭**。

## 附带发现（本工单登记，不解决）

- **CodeGen 侧无 `Char` 处理**：`Sources/PiniCore/CodeGen/` 内 `\bChar\b` **零命中** ⇒
  LLVM 侧遇到 `*Char` / `Char` 类型注解时的行为**未经验证**（可能被通用指针路径吸收，
  也可能静默降级）。**须先设计探针再判定**，本工单不预设结论
  ——「没搜到」不等于「没实现」（方法教训见 `docs/spec/issue/archive/issue-interpreter-hir-gap-audit-2026-09-12.md`）。
- **覆盖缺口**：该类型「有类型检查器支持、零语料覆盖」，与「能力矩阵语料数 59 vs 实测 78」
  同族。属覆盖问题，**不由本工单承担**（本工单只补 1 例冒烟，见处置 3）。

## 处置（**2026-09-17 已实施 1 / 2 / 4；3 改判** —— 见文末实录）

1. ✅ **改名落地（3 处代码）**：`isCScalarType` 的 `"Char"` → `"CChar"`；
   `Interpreter` 两个 `case "Char"` → `case "CChar"`；同步订正 `TypeChecker.swift:1177` 注释。
2. ✅ **spec §2.7 增补一条**：`CChar` 作为「C 单字节字符」的显式名字进入标量集（与 `I8`/`U8` 互转，
   编解码行为**不变**）。原条款「`Char` 保留为一般语言类型、不出现在 FFI 签名」**保持不变**
   —— 改名后这句才**首次为真**。⚠️ 该增补属对 spec 的修订，须走 **spec §1.3** 治理流程
   （提议 → 影响评估 → 登记 → 落地 → 证据登记）。
3. ⚠️ **改判（2026-09-17）**：原计划「加 ≥1 例 `*CChar` 指针读写语料」**不可达** —— 实测该面**在两台引擎上都跑不动**（见文末实录 §A.2），既无「正向运行」可写，也无「负向拒绝」可写（检查器对 `*Char` / `*CChar` **都放行**）。改为**在规范与台账里写清「该面今日不可运行」**，不制造一条必然失败的语料。
4. ✅ **验证**：全量测试零回归（预期零回归——无既有使用方）；`comment-lint` L6 通过
   （注意 `CChar` 不是 ADR ID，不影响 L6）。

## 已评估的备选：直接退役而非改名（**不采纳**，记录依据）

**备选 (b)**：既然 spec §2.7 已定「字节缓冲统一用 `I8`/`U8`」，且**零语料使用**，
可**删掉** `Char` 的 C 标量待遇，即本工单 3 处代码改为删除，`*Char` 一律写 `*U8`。

**不采纳的理由**（供日后回溯，避免重复讨论）：

1. **不省工作量**：两条路线都要动同样 3 处代码；退役并不比改名小。
2. **丢失语义表达力**：`CChar` 承载「这是 **C 的** `char`」这一概念——其符号性由实现定义，
   与 `U8` 语义有细微差别（这正是 spec §2.7 原注「避免 ABI 符号性歧义」所指的同一个问题域）。
   保留名字使该差别**可被显式表达**，而非被 `U8` 掩盖。
3. **已裁决策不因「更小」翻案**：`ADR-033 D2` 的裁决理由是语义性的（与 C 的 `char` 字面对应），
   不是成本性的。若仅因成本更低就推翻已裁决策，会削弱治理的可预期性。

## 估工关键未知项

- CodeGen 侧 `Char` 的实际行为（见「附带发现」）。两条路线**都**需要它，故不影响本工单估工；
  但若探针发现 CodeGen 侧**已**支持 `Char`（即非死面），则处置 1 需同步改 CodeGen 的对应分派
  —— 届时**停工重估**，不把新面塞进本工单。


---

## 实施实录（2026-09-17）

**批**：`P0d` 的**前置**（`D-P4-36` 取「C 先行」）｜**分支**：`agent/pini-dev/p0d-char-rename`

### A. 改了什么

| 处 | 文件 | 改动 |
|---|---|---|
| ① | `Sources/PiniCore/Type/TypeChecker.swift` | `isCScalarType` 的 `"Char"` → `"CChar"`（+ 说明注释） |
| ② | `Sources/PiniCore/Type/TypeChecker.swift` | `ffiTopLevelScalars` 的注释**订正**：原写「含 Char」，而该集合**本就不含** `Char`，也不含 `CChar` |
| ③ | `Sources/PiniCore/Runtime/RuntimeOps.swift` | 两处 `case "Char":` → `case "CChar":`（load / store），并注明该解码今日**不可达** |

⚠️ **未动冻结面**：`Interpreter.swift` / `SuspendEvaluator.swift` 实测**零 `Char` 命中** ⇒ 本批不触发 `[ast-walk]` 门禁（旧清单会误判，见上「订正位置」）。

### A.1 ⭐ 本批最重要的一条实测：**改名是行为中性的**

**原工单假定**：`isCScalarType` 含 `"Char"` ⇒ 实现「自造了规范明确排除的用法」（C 兼容指针目标接受 `Char`）。

**2026-09-17 实测**：**这个假定不成立** —— 该成员性是**惰性的**。理由（符号级）：

```swift
// TypeChecker.swift：cCompatibilityFailure(in:visiting:)
case .simple(let name, _):
    if referenceTypeNames.contains(name) { return name }
    if isCScalarType(name) { return nil }
    guard let fields = typeFieldsByName[name] else { return nil }   // ← 未知类型保守放行
```

`Char` **既非引用类型、又非已知结构体** ⇒ `isCScalarType` 返回 `true` 或 `false` **都落到同一个放行分支**。
⇒ **改名的可观察效果为零**。实测佐证（两侧同一批探针语料）：

| 输入 | 改名前 | 改名后 |
|---|---|---|
| `f2(p: *Char,) -> (U64,)` | `check` **通过** | `check` **通过**（不再有 `Char` 特权） |
| `f2(p: *CChar,) -> (U64,)` | `check` **通过**（未知名放行） | `check` **通过** |
| `*计数器`（结构体） | 拒绝（`C 兼容`） | 拒绝（**不变**） |
| 既有 `*U8` FFI 例程 | 通过 | 通过 |

⇒ 本批的**价值不在行为变化**，而在两条：① **名腾出来**（`Char` 从实现文本里消失，给 `P0d` 的 grapheme 字符留名）；
② 规范 §2.7 那句话**首次对实现也成立**（详见 A.3）。

### A.2 ⚠️ 一处**死面**（本批探明，登记不修）

`CChar`（原 `Char`）**只到达类型检查器**：`*CChar` 通过 `pini check`，但**两台引擎都解析不出该元素类型**：

| 引擎 | `*Char` / `*CChar` 的 foreign 声明 |
|---|---|
| `interp-ast` | `E5-017` 运行期错 |
| `interp-hir` | `E6-004 unsupported feature 'parameter … of foreign … lacks a resolvable type'` |
| `llvm` | 同一条 `E6-004` |

⇒ **该面今日不可运行**（也因此 `RuntimeOps` 那两处解码**不可达**）。这解释了为什么「补正向覆盖」不可达（§处置 3 改判）。
⚠️ 与工单原「附带发现」的关系：那里写「CodeGen 侧零 `Char` 命中，须先设计探针再判定」—— 本批**设计并跑了探针**，答案是「非死代码路径不存在，且上游两层就已拒绝」。

### A.3 spec §2.7 的增补与它带出的**第二个义项**

按 `§1.3` 增补一条 `CChar` 条款（`docs/spec/pini-spec-v0.md` §2.7；台账 **`G65`**）。⚠️ 增补时发现 **`CChar` 在规范内已有另一个义项**：§2.7 的 **thunk 映射表**里 `CChar` 指的是**宿主 Swift 的 `CChar`**（`I8` 的 C 侧对应类型）。⇒ **同一 token 在一节内指两物**，与 `ADR-033 D2` 要修的那个「一名两义」**同族**。已在增补条款里就地写明分辨方式（并**未**改动 thunk 表 —— 那是另一处，不在本单范围）。

### A.4 判据（全部实测）

| 判据 | 读数 |
|---|---|
| 构建 | 通过（无新告警） |
| **全量回归**（默认方向，3 块） | **64 → 64，逐条集合相等**（转绿 0 / 新增红 0 / 仍红 64） |
| `PINI_INTERP_ENGINE=ast` 方向 | **逐条相同** |
| 契约 | `clean`（**62/62** × 三锚点；本批未触 HIR） |
| 探针 | **320** 夹具 · 逐槽相等 · 逐夹具**零位移（0/320）** · `FLIP BLOCKERS 0` |
| 检查器行为（本批直接探针） | 见 §A.1 表：**改名前后接受性完全相同** |

### A.5 一处过程事故（如实登记）

写 `docs/spec/pini-spec-v0.md` 时，我用了 `io.open(p,"w").write(io.open(p).read().replace(...))`
—— **`"w"` 先被求值并截断文件**，内层 `read()` 于是读到**空内容**，**规范文件被写空**。
**处置**：`git checkout -- <该文件>` 从 `HEAD` 恢复，逐项验真（1556 行 / 174437 字节 / `G64` 在位 /
文档链接引用数 **954** 回到原值）；随后改为**先读后写**并**写入后立刻回读校验**（本次 +961 chars、
`G64`/`G63` 均在位、差量只在 §2.7 与 §3 两处）。
⚠️ **该事故与 `ADR-040` §5.1 记的那条判据纪律同族**：**「写」与「读」都不得只看命令/返回值，
必须校验内容**。另：我第一次的完整性断言写成了**字节数**（CJK 文件字符数 ≈ 10.4 万），
断言在写入前触发 ⇒ 无损；这说明**阈值也要按实际口径定**。

### A.6 未做

- **不修** `CChar` 的死面（实现 FFI 元素类型解析）—— 属新能力，不在「腾名」范围。
- **不改** spec §2.7 的 thunk 映射表（`CChar` 的宿主义项见 A.3）。
- **不删** `RuntimeOps` 的两处解码（不可达但语义正确，见 A.2）。
- **不动** `ffiTopLevelScalars` 的集合内容（它事实上不是白名单，加名是空承诺；只订正注释）。
- 不排 `P0d` 本体（`D-P4-36` 已定：排在 `LR-4` 之后）· 不 push。

**下一步**：`P0d` 本体待 `LR-4` 之后；本单**可归档条件** = 无（仍有 A.2 的死面未处置 ⇒ **维持 Open**，
但主题已从「腾名」转为「`CChar` 面不可运行」）。

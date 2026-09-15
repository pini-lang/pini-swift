# Issue：FFI 单字节 `Char` 改名 `CChar`（腾出 `Char` 名给 grapheme）

- 状态：**Open（2026-09-12 立案；未实施）**
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

## 实测影响面（2026-09-12，全仓检索）

**极小 —— 共 3 处代码 + 1 处注释；零语料、零测试。**

| 位置 | 内容 |
|---|---|
| `Sources/PiniCore/Type/TypeChecker.swift:1111` | `isCScalarType` 集合含 `"Char"` |
| `Sources/PiniCore/Type/TypeChecker.swift:1177` | 注释「顶层 FFI 签名白名单（C 兼容标量，含 Char；…）」 |
| `Sources/PiniCore/Interpreter/Interpreter.swift:675` | `case "Char": return .int(Int(rp.pointer.load(as: UInt8.self)))` |
| `Sources/PiniCore/Interpreter/Interpreter.swift:717` | `case "Char": ptr.storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)` |

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

## 处置（未实施）

1. **改名落地（3 处代码）**：`isCScalarType` 的 `"Char"` → `"CChar"`；
   `Interpreter` 两个 `case "Char"` → `case "CChar"`；同步订正 `TypeChecker.swift:1177` 注释。
2. **spec §2.7 增补一行**：`CChar` 作为「C 单字节字符」的显式名字进入标量集（与 `I8`/`U8` 互转，
   编解码行为**不变**）。原条款「`Char` 保留为一般语言类型、不出现在 FFI 签名」**保持不变**
   —— 改名后这句才**首次为真**。⚠️ 该增补属对 spec 的修订，须走 **spec §1.3** 治理流程
   （提议 → 影响评估 → 登记 → 落地 → 证据登记）。
3. **补覆盖**：改名后加 ≥1 例 `*CChar` 指针读写语料（当前零覆盖 ⇒ 不改名的话连改完仍是零覆盖）。
4. **验证**：全量测试零回归（预期零回归——无既有使用方）；`comment-lint` L6 通过
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

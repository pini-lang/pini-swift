# ADR-033: Char 类型引入——grapheme 标量与 FFI 命名腾挪
（Char Type Introduction: Grapheme Scalar and FFI Name Reclamation）

## Status

**Proposed（草案，2026-09-12）** —— 待裁决项见文末「待裁决」节。

本 ADR 落实 `ADR-019 D2` 的**第二阶段**（其原文：「真 `Char` 标量类型 + 字符字面量 `'c'`
为远期独立 RFC」）。它不是新增需求，而是**偿还一笔因架构变更而到期的债**（见 Context §1）。

## Context

### 1. 为什么是现在：ADR-019 D1 的一条边界因架构变更而失效

`ADR-019`（Accepted 2026-08-29，`docs/spec/adr/adr-019-unicode-char-model.md`）做出两项相关决策：

- **D1**：字符模型 = **Grapheme Cluster**（钉住），明文「**不采用 Unicode scalar 或 UTF-8
  byte 模型**」；并给出边界：「LLVM 端字符串下标/谓词**在补齐前保持显式 unsupported**，
  **不得静默给出与解释器不一致的结果**」。
- **D2**：**不引入 `Char` 类型**（两阶段，可逆）。谓词签名统一 `(String,) -> (Bool,)`，
  `s[i]` 返回单字符 String；理由为「迁移面（AST/类型层/解释器/LLVM/序列化）
  当前不值得为 lexer 闭环预付」。

D1 的边界条款成立的前提是**单后端心态**：解释器是主路径，LLVM 端可以「挂着 unsupported」。
**HIR 统合（LR-4）与 M6b 翻转改变了这个前提**：LLVM 升为与解释器并列的一等后端，
HIR 成为两侧共用枢纽，而枢纽契约要求两侧按同一语义实现。于是：

- 「LLVM 端 unsupported」不再是可接受的降级；
- 实测显示 LLVM 端**并未**保持 unsupported，而是**静默给出了不一致结果**（违反 D1 边界）；
- D2 第一阶段（「用 String 充当字符」）的代价随之暴露：**六处消费点各自解释「字符」**。

⇒ 故本 ADR 处理的是 D2 的**第二阶段**。

### 2. 现状实测（E1/E3，2026-09-12）

| 面 | 实测 | 位置 |
|---|---|---|
| 三处类型表示均无 `char` | `Value` 20 case / `HIRType` 20 case / `TypeAnnotation` 5 case（`Char` 仅作 `.simple(name:"Char")` 字符串） | `Sources/PiniCore/Interpreter/Value.swift`、`Sources/PiniCore/HIR/HIRNode.swift`、`Sources/PiniCore/AST/Types/Type.swift` |
| 六个谓词签名全用 `String` | `is_letter` / `is_ascii_digit` / `is_number` / `chars` / `ord` / `chr` | `Sources/PiniCore/Common/BuiltinRegistry.swift` |
| `chars` 元素类型为 `String` | `chars(String) -> Array<String>` | 同上 |
| `s[i]` 返回 `String` | `return .string(String(s[cidx]))`（ADR-028 后为 panic 通道） | `Sources/PiniCore/Interpreter/SubscriptStrategies.swift` |
| **`Char` 名已被 FFI 单字节占用** | `isCScalarType` 列为 C 标量；`load`/`store` 按 `UInt8` 读写 | `Sources/PiniCore/Type/TypeChecker.swift`、`Sources/PiniCore/Interpreter/Interpreter.swift` |
| 两侧字符模型偏离 D1 | 解释器 grapheme **✅** ／ `lenCall` 码点 **❌** ／ 切片与 `substring` 字节 **❌** | `Sources/PiniCore/CodeGen/IREmitter.swift`（`emitStringCharCount` / `emitStringByteLength` / `emitExpr` 的 `stringSubstring`） |

**命名冲突（本 ADR 的先决问题）**：现有 `Char` 的语义是 **C 的单字节 char**，
而本 ADR 要引入的 `Char` 是 **Unicode grapheme 字符** —— **同名两义**。
且 `docs/spec/pini-spec-v0.md` §FFI 白名单明文「**`Char` 不进入 FFI 标量集**……
字节缓冲统一用 `I8`/`U8`」，故现有实现与该裁定冲突。本条在本 ADR 内一并处置（见 D2）。

### 3. 行业调研：字符类型的硬件表示（2026-09-12）

| 语言 | 类型 | 表示 / 大小 | 语义 | grapheme？ |
|---|---|---|---|---|
| **Swift** | `Character` | 与 `String` 同构（tagged union，16 B） | **extended grapheme cluster** | **✅ 唯一** |
| Swift | `Unicode.Scalar` | `UInt32` wrapper，4 B | 单码点 | — |
| Rust | `char` | `u32`，4 B | Unicode scalar value | ❌ 明确拒绝 |
| Go | `rune` | `int32` 别名，4 B | 码点（可为非法值） | ❌ |
| .NET | `char` / `Rune` | 2 B（UTF-16 码元）/ 4 B（scalar） | 码元 / scalar | ❌（grapheme 走 `StringInfo` 工具类） |
| Java | `char` | 2 B | UTF-16 码元 | ❌ |

**两条决定性事实**：

1. **grapheme 长度无上界**。官方最长 RGI emoji ZWJ 序列为 **10 码点 / 35 字节**
   （man+skin, ZWJ, heart, ZWJ, kiss, ZWJ, man+skin）；Unicode 的 Stream-Safe Text Format
   建议每 chunk ≤ 32 字符 / ≤ 128 字节，但那是**建议而非上界** —— 组合字符数量无上限。
   ⇒ **任何 inline 优化都必须带溢出路径**，不存在「足够大的定长 buffer」。
2. **Swift 敢做 grapheme 的前提是「表不进语言」**。Rust 明确拒绝的理由是
   （原文语义）「表会让 Hello World 变成几 MB 的二进制，要用 grapheme 请用外部 crate」；
   Swift 的做法是把 Unicode 服务放在 OS 层。**Pini 的 `ADR-019 D4` 已定「UCD 数据表
   只住 runtime（宿主），语言侧零 Unicode 表」**，与该前提同构
   ⇒ **Pini 走 grapheme 路线在架构上是成立的**（这正是本 ADR 可行的基础）。

### 4. Swift 的权威做法（同一宿主语言）

早期官方源码（`stdlib/public/core/Character.swift`）：

```swift
internal enum Representation {
    case smallUTF16(Builtin.Int63)      // 单字内联：UTF-16 表示 ≤ 63 位
    case large(_StringBuffer._Storage)  // 溢出：指向堆 buffer
}
```

源码注释原文：「Fundamentally, it is just a String, but it is optimized for the common case
where the UTF-16 representation fits in 63 bits. The remaining bit is used to discriminate
between small and large representations.」

现代版：`struct Character { var _str: String }`。官方文档原文：
**「a Character is stored exactly the same way as a String!」**

⇒ Swift 的答案是：**`Char` 与 `String` 表示层同构；不变式（只含 1 个 grapheme）
由类型系统保证，而非表示层**。

## Decision

（草案：下列决策项中 **D2 已由用户裁决（2026-09-12）**，其余待裁。）

### D1【待裁】`Char` 的运行时表示

| 方案 | 表示 | 硬件特征 | 新 ABI | 与现状的性能差 | 判断 |
|---|---|---|---|---|---|
| **A 与 `String` 同构（newtype）** | 复用 `String` 表示（LLVM 侧 `ptr`） | 与 `String` 同等（可能堆分配） | **零** | **零回归**（现状 `s[i]` 已返回 `.string`） | **推荐** |
| B 单字 tagged union | `{ inline ≤15 B ; ptr overflow }`，16 B 值类型 | 定长、可内联、常见情形免堆 | **大**（新 16 B 值类型须穿透数组/结构体/字典/参数/返回） | 须先给 `String` 加 small-string 优化 | 长期路线 |
| C 4 字节码点 | `i32` | 最廉价、O(1)、免堆 | 小 | 无 | **违反 `ADR-019 D1`，排除** |

**推荐 A 的理由**：

1. **与权威一致**：Swift（同一宿主语言）的 `Character` 就是「a String under the covers」。
2. **零新 ABI**：`Char` 的 LLVM 表示 = `String` 的表示（`ptr`），无需新值类型穿透
   聚合、ABI 与 runtime shim 边界。
3. **零性能回归（关键）**：现状 `s[i]` **已经**在分配一个单字符 String
   （`Sources/PiniCore/Interpreter/SubscriptStrategies.swift`）。方案 A 不引入任何新的分配 ——
   它只是**给这个既有行为一个类型**。
4. **不变式归属正确**：`Char` 只含 1 个 grapheme 由 `TypeChecker` 保证
   （构造点：`s[i]`、`chars`、`chr`、字面量），与 Swift 同构；表示层不设防。
5. **与 `ADR-019 D2` 的「迁移面收敛在两处」自估方向一致**（实测见 D4，共 3+6+2 处，仍属小面）。

**方案 A 的代价（诚实登记）**：每个 `Char` 值有一次堆分配，`Char` **不是「廉价标量」**。
这不是本 ADR 引入的回归（现状已如此）；其优化路径（方案 B）的前提是先给 `String` 加
small-string 优化 —— 那属 String 存储模型变更，**超出本 ADR 范围**，登记为后续优化路线
（触发条件：bench 证据表明 grapheme 逐字符场景成为瓶颈；与 `ADR-019` Consequences 已登记的
「grapheme 索引 O(i)」缺口同族）。

### D2【已裁 2026-09-12】FFI 的 `Char` 改名为 `CChar`

用户裁决：现有 FFI 单字节 `Char` **改名 `CChar`**，`Char` 之名腾给 grapheme 类型。

- 理由：`CChar` 与 C 的 `char` 字面对应；同时回归 `docs/spec/pini-spec-v0.md` FFI 白名单的
  意图（字节缓冲用 `I8`/`U8`，不占用 `Char`）。
- 落点：`Sources/PiniCore/Type/TypeChecker.swift`（`isCScalarType`）、
  `Sources/PiniCore/Interpreter/Interpreter.swift`（指针 `load`/`store` 分派）。

### D3【待裁】字符字面量 `'c'` 的阶段归属

`ADR-019 D2` 把「真 `Char` 标量类型 **+** 字符字面量 `'c'`」列为同一 RFC。需裁决：

- **同批**：类型立即有构造语法，`Char` 可被直接写出；代价是 lexer/parser 改动增大。
- **拆格**：类型先落地（`s[i]` / `chars` / `chr` 已是构造点，已够 lexer 闭环），字面量后续。

**影响面提示**：`'c'` 与 `String` 的双引号区分、转义规则、以及 `'ab'` 应如何报错。

### D4 迁移面（实测清单，三类）

| # | 面 | 现状 → 目标 |
|---|---|---|
| 1 | 三处类型表示 | `Value` / `HIRType` / `TypeAnnotation` 各加 `char` case |
| 2 | 六个谓词签名 | `is_letter` / `is_ascii_digit` / `is_number` / `chars` / `ord` / `chr`：`String` → `Char` |
| 3 | 两处返回类型 | `s[i]`：`.string` → `.char`；`chars` 元素：`Array<String>` → `Array<Char>` |

`ord` / `chr` 的边界行为（`ord` 取首 Unicode scalar、空串哨兵 `-1`、`chr` 越界返回空串）
按 `ADR-019` 既有裁决保持不变，本 ADR 不改变。

### D5 LLVM 端 grapheme 分段走 runtime shim

`Char` 落地后 LLVM 端需要 grapheme 边界判定（`s[i]` / `len` / `chars`）。
按 `ADR-019 D4`「UCD 表只住 runtime」与 `docs/spec/pini-spec-v0.md` §3.2 的
单一 `@bk_*` C-ABI 边界，**LLVM 端只调用 runtime shim，不在 LLVM IR 内实现 UAX#29**。

⇒ 工程量从「在 IR 里实现 Unicode」降为「加若干 `bk_string_grapheme_*` shim」。

## Consequences

**变容易**：`s[i]` / `chars` / 谓词有了明确类型；「字符」的定义从六处消费点收敛到
`Char` 一处；LLVM 端「静默不一致」被类型层面的契约取代。

**变难 / 挂账**：

1. `Char` 每值一次堆分配（方案 A），优化路径依赖 String small-string 优化（见 D1）。
2. 三处类型表示加 case 会触发 Swift `switch` 穷尽性检查的扩散；实际扩散点须在实施时逐处清点。
3. LLVM 端 shim 补齐前，`Char` 相关路径**仍不得静默降级**（沿用 `ADR-019 D1` 边界的纪律）。

**止损**：若实施中发现迁移面显著超出 D4 清单（例如波及序列化 / DAP / 字典 key 哈希 /
FFI thunk），**立即停并重新拆项**，不把扩散项塞进同一批。

## 待裁决

| # | 项 | 说明 |
|---|---|---|
| 1 | **D1 表示方案**（A 推荐 / B / C） | C 违反 `ADR-019 D1`；A 与 B 的取舍见上 |
| 2 | **D3 字面量阶段** | 同批 / 拆格 |
| 3 | 本 ADR 是否随裁决转 `Accepted` | 并回填 `ADR-019 D2` 的「已实施」状态 |

## 引用

- `docs/spec/adr/adr-019-unicode-char-model.md` —— D1 grapheme 钉住 / D2 两阶段 / D4 零表三层对齐
- `docs/spec/adr/adr-028-subscript-safety-channels.md` —— `s[i]` panic 通道（`ADR-019 D2` 事实漂移来源）
- `docs/spec/pini-spec-v0.md` —— FFI 白名单（`Char` 不进标量集）、§3.2 单一 `@bk_*` ABI 边界
- `docs/issue-interpreter-hir-plan-2026-09-12.md` —— LR-4 执行计划（本 ADR 为其 P0b 规范产出的前置）
- `docs/issue-interpreter-hir-gap-audit-2026-09-12.md` —— P0 审计与 E3 实测

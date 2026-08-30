# ADR-019: Unicode 字符模型与字符谓词集（Grapheme Model & Char Predicates）

## Status

Accepted（2026-08-29）

## Context

自举 lexer（`pini/src/lexer/lexer.pini`）需要可靠的字符判定以实现 spec §A.1.1 的 `IDENT` 词法类（`[\p{L}_][\p{L}\p{N}_]*`）。现状：

1. **G45 只落了一半**：`is_letter`（UCD `\p{L}`，`String -> Bool`）已落地，但仅覆盖解释器端与类型层——LLVM CodeGen 端（`BuiltinsEmitter`）无对应实现。
2. **spec/宿主漂移**：宿主 `Lexer.readIdentifier` 用 `Character.isNumber` 做 IDENT 续字符判定，它基于 Unicode numeric property，比 spec EBNF 的 `\p{N}` **更宽**——`三.isNumber == true`（`三` 的 general category 是 `Lo` 不是 `N`）。即宿主接受 `var 三 = 1`，spec EBNF 不允许，二者必有一错。
3. **自举 lexer 无法词法化中文输入**：`lexer.pini` 的 `isAlpha/isDigit/isAlnum` 是 ASCII 硬编码字符串表比对，`examples/package-demo/_私密文件.pini` 等含中文标识符的语料无法通过对拍（`diff_tokens.sh`）。
4. **语言无 `Char` 类型**：`s[i]` 返回 `Optional<String>`（单个 grapheme cluster），`len(s)` 为 grapheme 数（`SubscriptStrategies.swift` 字符串下标策略）。spec 已为 `Char` 预留「一般语言类型、排除出 FFI 标量集」的位置但未落地。
5. 字面量与标识符使用了**两个不同的「数字」概念**：`INT ::= [0-9]+`（ASCII）与 IDENT 续字符 `\p{N}`（UCD），不能共用一个谓词。

## Decision

以下 5 项决策构成字符判定子系统的基线（与 ADR-018 自举契约衔接）。

### D1: 字符模型 = Grapheme Cluster（维持现状，钉住）

`s[i]` 的「一个字符」是用户感知的 grapheme cluster；`len` 为 grapheme 数。不采用 Unicode scalar 或 UTF-8 byte 模型。

**理由**：① 与宿主（Swift `Character`）一致，零迁移；② `\p{L}`/`\p{N}` 判定在 grapheme 上与 EBNF 语义严格对应；③ Swift `String ==` 的 canonical-equivalence 使标识符比较对 NFC/NFD 归一化形式免疫——「同形异码」标识符不会裂成两个符号（正向红利，显式钉住）；④ scalar 模型会把 `é`（组合形式）拆成两个「字符」，对中文命名语言不可接受。

**边界**：LLVM 端字符串下标/谓词在补齐前保持显式 unsupported（与 FFI Phase 2a 同策略），不得静默给出与解释器不一致的结果。

### D2: 不引入 `Char` 类型（两阶段，可逆）

当前阶段谓词签名统一为 `(String,) -> (Bool,)`，`s[i]` 继续返回 `Optional<String>`。真 `Char` 标量类型 + 字符字面量 `'c'` 为远期独立 RFC——其迁移面（AST/类型层/解释器/LLVM/序列化）当前不值得为 lexer 闭环预付。本决策可逆：迁移面收敛在谓词签名与 `s[i]` 返回类型两处。

### D3: spec §A.1.1 IDENT 续字符放宽为 Unicode numeric property（裁决漂移）

`IDENT` 续字符集由 `\p{N}` 放宽为「Unicode numeric property 字符（Numeric_Type ≠ None，即宿主 `Character.isNumber` 语义）」，严格超集 `\p{N}`——含 `三`/`万` 等带数值的 `Lo` 类汉字。**INT 字面量仍严格限 `[0-9]`**，不受此放宽影响。

**理由**：中文数字出现在标识符中对中文命名语言是特性而非缺陷；宿主行为保持不变（零迁移）；放宽比收紧的破坏面小。此为 spec 语义放宽，按 §1.3 登记（Provisional，随 v0.x 迁移说明发布）。

### D4: 谓词集（lexer 最小闭包，三层对齐）

| 谓词 | 语义 | 用途 | 状态 |
|------|------|------|------|
| `is_letter(s)` | UCD `\p{L}` | IDENT 首字符（与 `_` 组合） | 已落（G45），LLVM 端待补 |
| `is_ascii_digit(s)` | ASCII `[0-9]` | 数字字面量扫描 | 本次新增 |
| `is_number(s)` | Unicode numeric property | IDENT 续字符（与 `\p{L}`、`_` 组合） | 本次新增 |

**分层铁律**：UCD 数据表只住 runtime（宿主），语言侧（自举 lexer 等）零 Unicode 表、只调谓词。谓词实现须三层对齐：`Interpreter.registerBuiltins`（运行时）、`TypeChecker`（静态签名）、`BuiltinsEmitter`（LLVM 端，未补齐前显式 unsupported）。

### D5: 与 ADR-018 D3/P3 的关系澄清

ADR-018 要求编译器自身代码全英文零中文标识符；本 ADR 管的是**输入字符集**（被词法化的用户代码），二者正交不冲突。自举 lexer 源码命名仍遵循 ADR-018 G4（英文 snake_case）。

## Consequences

**变容易**：自举 lexer 可词法化中文标识符输入，`diff_tokens.sh` 对拍对全部 `examples/`（含中文命名文件）可收敛；spec/宿主 `isNumber` 漂移消除；字符判定有了单一事实源（三个谓词），新增实现端只需对齐谓词。

**变难 / 挂账**：① spec 语义面放宽（`\p{N}` → numeric property），EBNF 表述精确度略降；② grapheme 索引下标为 O(i)，自举 lexer 主循环暂为 O(n²)——登记缺口，优化路径为字符数组预切（纯语言内解法）或 runtime 提供批量分类内建，均待 bench 证据支持后立项；③ LLVM 端三个谓词均待补齐，在补齐前 CodeGen 路径不得声称支持字符判定。

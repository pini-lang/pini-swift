# Issue: Unicode 字符判定与自举 lexer 词法化收敛（2026-08-29）

> **决策依据**：ADR-019（`docs/adr/adr-019-unicode-char-model.md`）。
> **前置**：G45 `is_letter`（v0.49.0，issue-lexer-gaps-2026-08-28 P1-A）；ADR-018 自举契约（L0 差分门禁 `diff_tokens.sh`）。
> **类型**：规范变更（§1.3，Provisional 语义放宽）+ 实现缺口闭环。

## 1. 背景与动机

自举 lexer（`pini/src/lexer/lexer.pini`）的字符判定为 ASCII 硬编码（`isAlpha/isDigit/isAlnum` 字符串表比对），无法词法化含中文标识符的语料（如 `examples/package-demo/_私密文件.pini`），L0 差分门禁对全部 `examples/` 不可收敛。同时存在两处一致性缺口：宿主 `Lexer.readIdentifier` 的 `Character.isNumber` 与 spec EBNF `\p{N}` 漂移（`三.isNumber == true` 而 `三 ∉ \p{N}`）；`is_letter` 仅覆盖解释器端，LLVM CodeGen 端缺失。

## 2. 规范变更（ADR-019 D3）

spec §A.1.1 `IDENT` 续字符集由 `\p{N}` 放宽为「Unicode numeric property 字符（Numeric_Type ≠ None）」，严格超集 `\p{N}`。EBNF 拟修订：

```ebnf
IDENT        ::= ID_START ID_CONTINUE*;
ID_START     ::= [\p{L}_];
ID_CONTINUE  ::= ID_START | NUMERIC;
NUMERIC      ::= (* Unicode numeric property 字符（Numeric_Type ≠ None），
                  即宿主 Character.isNumber 语义；严格超集 \p{N}——
                  含 三/万 等 Lo 类带数值汉字 *);
```

`INT ::= [0-9]+ | ...` **不变**（数字字面量严格 ASCII）。v0.x 发布时附迁移说明：`½`/`Ⅻ`（No 类）等此前 EBNF 不允许的字符进入合法标识符续字符集。

## 3. 谓词集与三层落点（ADR-019 D4）

| 谓词 | 语义 | Interpreter | TypeChecker | BuiltinsEmitter (LLVM) |
|------|------|-------------|-------------|------------------------|
| `is_letter` | `\p{L}` | ✅（G45） | ✅ | ✗ 挂账 |
| `is_ascii_digit` | `[0-9]` | 本次 | 本次 | ✗ 挂账 |
| `is_number` | numeric property | 本次 | 本次 | ✗ 挂账 |

## 4. 落地清单

- [x] **P1 宿主**：新增 `is_ascii_digit` / `is_number`（Interpreter register + dispatch、TypeChecker 签名、SemanticAnalyzer 内建清单三层对齐）；`Lexer.readIdentifier` 注释挂 ADR-019 锚点（行为不变，spec 已放宽对齐）。（2026-08-29 完成）
- [x] **P1 宿主测试**：`BuiltinFunctionTests` 增 4 用例（`testIsAsciiDigitAcceptsDigits` / `testIsAsciiDigitRejectsNonDigits` / `testIsNumberAcceptsNumericProperty` / `testIsNumberRejectsNonNumeric`），镜像 G45 `is_letter` 惯例；24/24 全绿。（2026-08-29 完成）
- [x] **P2 自举**：`lexer.pini` 删除 ASCII 硬编码判定，`isDigit→is_ascii_digit`、`isAlpha→is_letter|_`、`isAlnum→isAlpha|is_number`（对齐新 IDENT 语义）。（2026-08-29 完成）
- [x] **P2 对拍**：中文标识符语料（`var 圆形`、`_私密`、`三万`、`混合x1` 等，47 行 token 流）MATCH；自举 `lexer_tests.pini` 8/8 通过。默认语料仅剩 1 处**既有**差异（22:1 `Self`：宿主 keyword vs 自举 identifier）——属 spec G50「Self→own 更名」宿主未跟进的关键字集漂移，与本 issue 正交，另立工单。（2026-08-29 完成）
- [x] **P3 spec 正文**：§A.1.1 EBNF 修订（ID_START/ID_CONTINUE/NUMERIC，挂 ADR-019 D3）完成；§3 G50 行实现状态更新为「已定义且已实现」。（2026-08-29 完成）
- [x] **P3 追加：G50 `Self`→`own` 宿主随动**（上项对拍发现的既有漂移）：`Token.Keyword.own`（`Self` 降级普通标识符）、Parser 四触点（isSelfMethodStart/parsePrimaryAtom/parseTypeAnnotation/parseIdentifier）、`TypeChecker.replaceSelf` 匹配 "own"、TraitConstraintTests/MethodSelfModifierTests 迁移；spec §3 G50 行与证据表 E-035/036/052/053 按刷新协议更新。全量 1017 XCTest + 44 SwiftTesting **0 失败**；默认语料 MATCH（272 行）、中文语料 MATCH（47 行）。（2026-08-29 完成）
- [x] **P3 追加：字符判定性能闭环**（2026-08-29 完成，经 ADR-020 路线）：① `chars` 内建（grapheme 预切，String -> Array\<String\>，三层登记于 `BuiltinRegistry`）消除下标 O(i)；② 自举 lexer 输出改「数组 append + 末尾 join」（ADR-020 D5 惯用法）消除累积拼接；bench：n=400 语料 18.5s→3.7s，423KB 大语料从 >300s 被杀降至 99s 可完成，diff_tokens 双语料 MATCH。残余超线性项（`Array.append` 的 O(k) 拷贝）已登记 **G53**（post-bootstrap，须 bench 立项）。
- [ ] **P3 挂账（余项）**：LLVM 端四内建补齐（`is_letter`/`is_ascii_digit`/`is_number`/`chars`）；G53 可变数组机制（post-bootstrap）。

## 5. 验收标准

1. `swift test --filter BuiltinFunctionTests` 全绿（新增 4 用例 + 既有 `is_letter` 用例）。
2. `tools/diff_tokens.sh examples/lex_corpus.pini` → MATCH。
3. 新增中文标识符语料（`var 圆形 = 1`、`_私密` 等）对拍 MATCH。
4. spec §A.1.1 修订与 ADR-019、本 issue 三者互相引用一致。

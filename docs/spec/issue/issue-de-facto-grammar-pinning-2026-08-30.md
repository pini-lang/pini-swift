# S5/S6 探针 Type-B findings：表达式/语句文法的 de-facto 面钉定清单

- 状态：Proposed（2026-08-30，自举 parser S5/S6 探针产出；四项均为「宿主已实现但 spec 未钉定」的规范面）
- 依据：自举侧以「镜像宿主实测行为」方式实现了表达式/语句解析（selfhost `src/parser/parser.pini`），过程中逐项确认了以下只在宿主**代码**中存在的语义。S9 差分门禁将以此为权威参考——它们需要 spec 钉定或宿主显式声明保留原因。

## F1 算符 → opText 映射表（17 项，事实钉定请求）

源算符到 AST 投影文本的映射只存在于 `BinaryOperator`/`UnaryOperator` 枚举 + CLI 投影代码：

| 源算符 | opText | | 源算符 | opText |
|---|---|---|---|---|
| `+` | plus | | `==` | equal |
| `-`（二元） | minus | | `!=` | notEqual |
| `*` | multiply | | `<` | lessThan |
| `/` | divide | | `>` | greaterThan |
| `%` | modulo | | `<=` | lessThanOrEqual |
| `&&` | **and** | | `>=` | greaterThanOrEqual |
| `\|\|` | **or** | | `&` | bitwiseAnd |
| `^`（二元） | bitwiseXor | | `<<` | leftShift |
| `>>` | rightShift | | | |

一元：`!`→not、`-`→minus、`+`→plus、`~`→bitwiseNot、`++`→increment、`--`→decrement。

**请求**：spec（§A.1.2 / §A.2.5 或投影主题）钉定该表为投影权威文本。自举实现已按此表对齐（selfhost `parser.pini` + `format.pini`）。

## F2 BinaryOperator 枚举的冗余/死面（清理提案）

- `and`/`or` 与 `logicalAnd`/`logicalOr` **双套并存**：`&&`/`||` 解析为 `and`/`or`，`logicalAnd`/`logicalOr` 当前不可达；
- `assign`/`plusAssign`/…/`rightShiftAssign` 共 10 个赋值算符 case 在表达式位不可达——宿主 `parseAssignment` 直落 `parseOr`（赋值是语句级，Statement.assign 承载）；
- `power` 当前不可达。

**请求**：钉定各 case 的活/死状态——删除死 case，或注明保留原因（如为 L1b 的表达式级赋值预留）。

## F3 前缀 `++`/`--` 的求值语义未钉（提案）

宿主 parseUnary 将前缀 `++`/`--` 解析为 `UnaryOperator.increment/decrement` 进 AST，但其求值语义未在任何 spec 条款出现：表达式值是自增前还是自增后？是否允许作用于对象字段/下标？与语句级 `i = i + 1` 惯用法的关系？

**请求**：钉定语义（或声明 Experimental/禁止）。

## F4 tuple-or-paren 消歧规则（事实钉定请求）

`( ... )` 的形态规则只活在 `parseTupleOrParen`：

1. `()` → 空元组；
2. 单元素**无标签** `(e)` → 解包为 e 本身；
3. 单元素**带标签** `(a: e)`（无尾逗号）→ 仍为元组；
4. 多元素（含尾逗号容忍）→ 元组；元素标签由 `IDENT :` 前瞻判定。

**请求**：spec 表达式主题钉定该四条（自举已按此实现并测试覆盖）。

## 同批记录（非缺口）

- 测试纪律：类型类测试 harness 必须先 check 再 run——空转 harness 会把缺陷变成假绿（G-P8 重开实证，见 remediation issue 附录 F）。

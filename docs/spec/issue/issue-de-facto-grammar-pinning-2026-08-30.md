# S5/S6 探针 Type-B findings：表达式/语句文法的 de-facto 面钉定清单

- 状态：Proposed（2026-08-30，自举 parser S5/S6 探针产出；五项均为「宿主已实现但 spec 未钉定」的规范面；F5 由 S9 差分门禁阶段的用户质疑引出）
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

## F5 EBNF 缺少「缩进敏感块文法」维度（spec 维护提案）

`|own` 本身并未漏维护（`method-decl ::= IDENT ['|' 'self' | '|' 'own'] ...`，§723；
规则 3.14 亦明列扩展块只允许 `|self`/`|own`；宿主实测亦拒绝 `m|self|own()`）。
真正缺位的是**块结构维度**：

1. EBNF 无 `INDENT`/`DEDENT`/空行记号，`method-body ::= { method-decl }`（§708）以
   平铺序列表达块——**边界语义无法在 EBNF 内表达**；
2. 于是「扩展块体」的两种宿主合法写法及其闭块规则只能靠散文（§2「块边界由下一个
   顶级声明隐式关闭」）与宿主实现承载：
   - **缩进体**：由 DEDENT 闭合（空行不闭合）；
   - **顶格体**（`examples/object.pini` 风格）：由下一个非 `|self`/`|own` 行闭合；
3. 同为顶格块的**结构体字段块**（顶格/缩进两种写法、空行闭块）亦只有散文、无产生式。

**实测证据**（S9 差分门禁阶段采集）：

```
# 缩进体：dedent 闭合，空行不闭合
{{t}}
    m|own() -> ()
        return

    n|self() -> ()
        return
# → 两个方法同属一个扩展块

# 顶格体：遇非 |self/|own 行闭合
{{t}}
m|self|own() -> ()      # 宿主拒绝：扩展块内只允许方法声明（修饰符二选一）
n|own() -> ()
    return
```

**请求**：① EBNF 引入缩进记号（如 `block ::= INDENT { item } DEDENT`）或在语法章显式
声明「EBNF 不描述缩进、块边界另章规定」；② 明列顶格块与缩进块两种合法写法及各自闭块
规则；③ 以宿主示例（`examples/object.pini`）反向校验 spec，双向一致。

**影响**：不钉定则任何第三方实现（含自举 parser）都只能从宿主实现反推块边界——S9
差分门禁的权威参考面存在不可核对的部分。

## F6 宿主 CLI 不向 `main` 透传 argv（宿主功能需求）

自举编译器需要接受输入路径（否则它无法编译任何指定文件）。当前宿主 CLI 无 argv 透传
（`pini run <module>` 之外的参数无通路），也无 `argv`/`env` 内建可读取进程参数——
S10 的驱动只能经「暂存通道」（门禁脚本把源写到 `/tmp/pini_in.pini`、把 pass 名写到
`/tmp/pini_cmd.txt`，驱动读这两个文件）获得输入。

这是在宿主能力缺失下的工具约定（驱动与其门禁之间），**不是语言语义**，一旦宿主支持
argv 即废弃。

**请求**：宿主提供其一——① `pini run <module> -- <args...>` 把 `--` 之后的参数交给
`main`（`main|func(argv: [String],)` 形态）；② 或 `argv()` / `env(name:)` 内建。

**影响**：不落地则自举编译器永远无法以命令行方式被调用（dogfood 的前提）。

## 同批记录（非缺口）

- 测试纪律：类型类测试 harness 必须先 check 再 run——空转 harness 会把缺陷变成假绿（G-P8 重开实证，见 remediation issue 附录 F）。
- 语料范围纪律：门禁语料只放「切片模型已覆盖」的形态。S10 解锁「任意语料可跑门禁」后，
  立即暴露 `host-gap-corpus.pini` 里的 enum 声明（G-P5/G-P6 载体）属 L1b 未覆盖形态——
  差异并非缺陷，而是「尚未实现」。这些片段已剥离到 `examples/l1b-shapes.pini` 存档。

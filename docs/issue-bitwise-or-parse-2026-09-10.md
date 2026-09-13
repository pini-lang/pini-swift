# Issue：单竖线 `|` 位或表达式无解析通道（规范内部自相矛盾）

- 状态：**Open（2026-09-10 立案；需 spec §1.3 决策，未决策前不动源码）**
- 发现来源：LLVM 重写 M5 G15 格（compound-assign 语料差分 fixture 编写时踩中，
  原记录为「宿主级解析器缺陷」）
- 关联：spec §A.1.2（词法记号表）/ §A.2.5（表达式层 5）/ §A.4 规则 3.13；
  同族工单 `docs/spec/issue/archive/issue-binop-dead-cases-2026-09-04.md`（运算符面收敛）

## 复现（实测，2026-09-10）

| 探针 | 结果 |
|---|---|
| `print(a \| b)` | ❌ Parse Error [E2-001] `expected ), got \|`（列位指向 `\|`） |
| `a \| 3`（语句位） | ❌ Parse Error [E2-006] `invalid expression: 无效的表达式` |
| `a \|= 3` | ✅ 正常（a=12, b=3 → 15；LLVM 与解释器一致） |
| `t \|\| f` | ✅ 正常 |
| `a & b` / `a ^ b` / `a << 1` / `a >> 1` | ✅ 正常 |

`pini tokens` 实测：`|` 恒词法化为 `pipe`（例：`1:5 pipe |`）——无独立位或记号。

## 根因（符号级）

1. `Token` 枚举**无** `bitwiseOr` case：`Sources/PiniCore/Lexer/Token.swift` 中
   `logicalOr` = `||`、`pipe` = `|`、`orAssign` = `|=`；而 `BinaryOperator.bitwiseOr`
   存在于 `Sources/PiniCore/AST/Expressions/BinaryExpr.swift`。
2. `Parser.isBitwiseOperator()` / `Parser.getBitwiseOperator()`（层 5）只列
   `bitwiseAnd` / `bitwiseXor` / `leftShift` / `rightShift`——**位或缺位**，
   故表达式中缀位无入口。
3. `Parser` 已有 `.orAssign → .bitwiseOr` 映射，故复合赋值可用；`pipe` 记号被
   声明位修饰独占消费（`main|func`、`|test`、`|unsafe`、标签 `标签|while`）。

## 规范侧现状（本工单的真正动因：spec 自相矛盾）

| 位置 | 内容 | 与实现 |
|---|---|---|
| §A.2.5 `bitwise-expr ::= term { ('&' \| '\|' \| '^' \| '<<' \| '>>') term }` | 位或**在**产生式内 | 超售 |
| §A.1.2 记号表 `'\|' : 按位或（表达式） / 声明修饰分隔符（行首/声明）` | 双义并陈 | 超售 |
| §A.1.2 记号转换表 | 只列 `'&'→bitwiseAnd '^'→bitwiseXor '<<'->leftShift '>>'->rightShift`——**无 `'\|'` 行** | 与上一行自相矛盾 |
| 同节已记事句「bitwise-or 仅经复合赋值 `\|=` 去糖得到（去糖后 opText 为 bitwiseOr）」 | 承认缺位 | 与产生式矛盾 |
| §A.4 规则 3.13 | 「若 `'\|'` 后是其他 token → 回退为按位或表达式」 | 实现走报错，未回退 |

即：spec 的**产生式与消歧规则**承认 `a | b`，**记号表与实现**只有 `|=`。
属语言级欠定义，不是单纯实现缺陷。

## 影响

- 表达式中缀位或不可用；`|=` 可用而 `|` 不可用，形态极不对称（用户可见行为缺口）。
- 自举 parser 语料与 G15 差分 fixture 均须绕开（fixture 已就地注记）。
- `&` 已用语法位置消歧先例（前缀取地址 `unsafe &x` vs 中缀按位与，`Parser.parseUnary`
  已实现）——单竖线的「声明分隔符 vs 位或」同型消歧有现成范式可循。

## 处置请求（待裁决，先决策后实施）

决策点二选一，两者都必须过 spec §1.3 治理序（提议 → 影响评估 → 登记 → 落地 → 证据）：

- **A（补通道）**：加位或记号（新增 `bitwiseOr` case 或复用 `pipe`）+ 层 5 入口
  （`isBitwiseOperator` / `getBitwiseOperator`）+ 行首/声明位消歧；spec 三处同步
  （记号转换表补 `'|'` 行、规则 3.13 保持、记事句撤回）。
- **B（收敛规范）**：维持现状（`|=` 为唯一通道），spec 删 `bitwise-expr` 产生式中的
  `'|'`、删记号表「按位或（表达式）」义、规则 3.13 的「回退为按位或表达式」改写，
  并把「仅经 `|=` 去糖」的记事句升为正条。

## 不做范围（立案批）

- 不改 `Sources/` 任何源码（未决策）；不新增探针入库；不动 EBNF 正文。
- 本格（G15）不为它增补差分 fixture——`testDiffBitwiseCompound.pini` 已以注释标记
  缺位并绕开该行，待本工单裁决后再补。

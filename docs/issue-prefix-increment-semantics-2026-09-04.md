# Issue：前缀 `++`/`--` 求值语义钉定与三处宿主缺陷修复（F3）

- 状态：**Open（2026-09-04 自 `docs/spec/issue/archive/issue-de-facto-grammar-pinning-2026-08-30.md` F3 立案转入）**
- 来源：自举 parser S5/S6 探针产出；2026-08-31 宿主实测（`pini run` 探针）
- 关联：`docs/Pini草稿.md` 算术运算符表（草稿意图）；spec §A.3 一元算符层

## 缺陷描述（宿主实测，2026-08-31）

| 形态 | 实测结果 | 是否符合「前自增」意图 |
|---|---|---|
| `var m = ++n`（n=5） | `m=6`，**`n=5`**（表达式位**不写回**） | ✗ |
| `++n` 作语句 | `n=6`（写回） | ✓ |
| `++o.x`（成员目标，x=3，语句位） | **`3`**（**不写回**） | ✗ |
| `++1`（字面量目标） | `2`，**不报错** | ✗ |
| `--n`（表达式位，n=5） | `m=4`，`n=5` | ✗ |
| `n++`（后缀） | E2-006 拒 | ✓（草稿无后缀） |

即：**同一算符在语句位与表达式位语义不一致、成员/下标目标不写回、不可赋值目标不报错**。

## 请求（原 F3 请求）

1. spec 钉定：`++`/`--` 为前缀一元自增/自减；仅作用于**可赋值目标**（变量 / 成员 / 下标）；
   语义 = 读-改-写回，表达式值取改写后值；无后缀形态；
2. 宿主缺陷随钉定修复：①表达式位不写回；②成员/下标目标不写回；③不可赋值目标不报错。

## DoD

- 三处缺陷各有失败先行测试（修复前红、修复后绿）；
- spec §A.3 载明语义；
- CHANGELOG 迁移说明（行为变更：表达式位写回）。

## 验收记录（2026-09-04 批 A）

- spec：§A 前缀 `++`/`--` 注记更新为「已对齐」（去「三处偏离登记待修」段）。
- 宿主：`Interpreter.evaluateIncDec` 统一语句位/表达式位读-改-写回（`runExpressionStatement` 标识符特例写回移除，防双写）；`TypeChecker` 静态拒绝不可赋值目标（spec「编译错误」）。
- 探针实测：`var m = ++n` → m=6 且 **n=6**（旧缺陷 n=5 修复）；`++o.x` → 4；`--arr[0]` → 6；`++1` → 静态 mismatch。
- 测试：testUnaryIncDecExpressionWriteback / testUnaryIncDecMemberSubscriptWriteback（InterpreterTests）+ testCheckIncDecLiteralTargetRejected / testCheckIncDecIdentifierTargetAccepted（TypeCheckerTests）。
- CHANGELOG 迁移说明随批 A 提交。

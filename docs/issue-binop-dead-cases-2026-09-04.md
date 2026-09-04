# Issue：BinaryOperator 枚举死面清理与 assign 族语句级语义钉定（F2）

- 状态：**Open（2026-09-04 自 `docs/spec/issue/archive/issue-de-facto-grammar-pinning-2026-08-30.md` F2 立案转入）**
- 来源：自举 parser S5/S6 探针产出；2026-08-31 实测修正（逐 case 统计构造点）
- 关联：ADR-020（BuiltinRegistry 契约先例——死面清理同属「宿主面收敛」）；spec §A.1.2 / §A.2.5

## 缺陷描述

`BinaryOperator` 枚举存在两类不可达 case：

| 分类 | case | 实测证据 |
|---|---|---|
| **AST 死面** | `logicalAnd` / `logicalOr` | 解析器在 and/or 层构造的是 `.and` / `.or`；`.logicalAnd`/`.logicalOr` 节点**永不被构造**（CodeGen 有分支但不可达） |
| **完全死面** | `power` | 无词法记号、无解析产生式；仅 CodeGen/类型层有分支 |

`assign` + 9 个复合赋值 case **不是死面**（`parseAssignment` 消费并去糖为普通二元），
但该「仅语句级复合赋值、去糖为目标 = 目标 op 值」的语义只在实现中，spec 未钉定。

## 请求（原 F2 请求①②）

1. 删除 `logicalAnd` / `logicalOr` / `power` 三 case，或为各自注明保留原因；
2. spec 钉定 `assign` 族为「仅语句级复合赋值，去糖 = 目标 = 目标 op 值」。

## DoD

- 死面处置落地（删或注记），全量测试 GREEN；
- spec 载明 assign 族语句级语义；
- 自举 parser 差分门禁维持 MATCH。

## 验收记录（2026-09-04 批 A）

- 宿主：`BinaryOperator` 删除 `logicalAnd` / `logicalOr` / `power` 三个死面 case；`ExprEmitter` / `TypeInference` / `TypeChecker` 对应分支与常量折叠注释同步清理；Tests 侧零引用（删除前实测）。
- spec：规则 3.11 扩展——assign 族「仅语句级」钉定 + 死面删除记录。
- 构建 + 全量测试通过（死面不可达性实证：删除无任何行为变化）。

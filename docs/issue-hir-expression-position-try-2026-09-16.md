# `try-else` 出现在表达式位，HIR 无前导语句上提机制

> 状态：**Open**（2026-09-16 立案；**只登记不修**）
> 发现于：`G-2e` 勘测。它是该子批**未交付的 3 条**。
> 上游：`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-2e` 行。

## 1. 现象（实测，2026-09-16，`main` = `3a7bde7`）

```pini
main|func() -> ():
    print(^ok(7))                          # ^ 脱糖到 try-else
    print(try ok(5) else e: return)        # 显式写法
    return
```

| 命令 | 结果 |
|---|---|
| 默认（HIR） | **rc≠0**：`try-else is only supported as a statement or a variable initializer this grid` |

`return ^err(9)`（`testCaretErrReturnsFromFunction`）同族，且**叠了第二道门**：
handler 的 `return err` 命中「裸错误绑定出栈」的已登记语义洞
（`returning a bare error binding … gated this grid`）。

**受影响的用例**（实测计数）：`ResultUnwrapTests` 与 `TryExceptTests` 共 **3 条**
（另有若干条先死在更早的降载点上，本单只计**当前实测**的这 3 条）。

## 2. 符号级根因（实测，非推断）

1. **HIR 没有带副作用的表达式节点** —— `tryStmt` 是**语句**，其 ok 路径的结果只能写到
   `okTarget`（一个已声明的变量名）。
2. 现有的两处表达式位特化是**逐点写死的**，不是通用机制：
   `lowerVarDecl`（`let x = try f() else …` ⇒ 展开为 `allocVar(x, init:nil)` + `tryStmt(okTarget:x)`）
   与 `lowerStatement` 的语句位 try。
3. ⇒ 要让 `print(<含 try 的表达式>)` 成立，必须在**使用它的语句之前**插入 `tryStmt`，
   而 `lowerExpr` 的签名（返回单个节点）**表达不了「我附带一条前置语句」**。
4. ⚠️ **难点不在加字段，而在放置位置正确**：`lowerBlock` 逐个语句降载，而 `if`/`while` 的体
   **递归调用** `lowerBlock` ⇒ 一个朴素的「上下文前置队列」会让前置语句落进**内层块**（被条件执行）。
   正确做法需要按**求值序**定位插入点（或让 `lowerExpr` 返回「节点 + 前置语句」）。

## 3. 为什么不在 `G-2` 内做

这是**降载架构**的改动（表达式与语句的边界），不是守卫放宽。
且它的收益面很小（3 条），而回归风险面很大（所有表达式降载路径）。
⇒ 单独立项；宜与「`ResultUnwrapTests` 一族」同批处置。

⚠️ 与之相邻但**不同**的一条：`print(e)`（`e` 为 handler 的错误绑定）走的是
「err 槽类型擦除」的 LLVM Result ABI 门，**不归本单**。

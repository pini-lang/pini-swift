# `ok(...)` / `err(...)` 在没有期望类型的位上无法降载（`match` 检体位实测）

> 状态：**Open**（2026-09-17 立案；**只登记不修**）
> 发现于：`G-3b`（L2 异步体 `Result` 上下文）。它**不是**该批的对象，而是该批把 return 位
> 判绿之后**剩下的最后一条** —— 此前它与 return 位**共用同一句报文**，故一直被混在同一个计数里。
> 上游：`docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md` §11.2。

## 1. 现象（实测，2026-09-17，`G-3b` 批）

夹具：`Tests/PiniTests/CPSDifferentialTests/testDiffMatchJoinInBody.pini`

```pini
child|func() => (I32,):
    sleep(10)
    return ok(7)

main|func() => (I32,):
    match ok(1):          ; ← 检体位的 ok(...)
        case ok(v):
            var r = await child()
            print(v, r)
        case err(e):
            print("err")
    return ok(0)
```

| 通道 | 结果 |
|---|---|
| `PINI_INTERP_ENGINE=ast pini run <夹具>` | rc=0（检体位 `ok(1)` 运行期成立） |
| `pini run <夹具>`（默认 `hir`） | **rc=1**，`E6-004` — `unsupported feature ''ok' construction requires a Result-typed context this grid'` |

## 2. 为什么它是**另一个位置**、而不是 `G-3b` 的漏项

`G-3b` 修的是**异步体 `return` 位**的期望类型（前端 `bodyReturns` 早已钉住该位必须是 `Result`）。
本条的位是 **`match` 的检体（scrutinee）**：那里**没有任何期望类型**可传。

降载层那句 `'(ok|err)' construction requires a Result-typed context this grid` 是**同一个打靶点**
（`Sources/PiniCore/HIR/HIRLowerer.swift` 的 `ok`/`err` 分支）发出的 ⇒
**一个报文承载了两个位置**，`G-3b` 之前的分母（60）里混着它。
⇒ 因此**「报文计数」不能当「位置计数」用**：`G-3b` 实测 60 → 1，归零的是 return 位那 59 条。

## 3. 影响面

- **判据面**：实测 **1 条**夹具（8 目录 83 夹具的全扫）。⚠️ **其他无期望类型的位置未测**
  （如把 `ok(...)` 直接作为另一函数的实参）—— 本条不替它们下结论。
- **用户可见**：写 `match ok(1):` 的程序在 HIR 侧不可运行。这是**极边缘**的写法
  （正常写法是 `match wait f():`），实测量为 1 条，故严重度低。
- **翻转口径**：属「静态层比 AST 更严」的一类。若裁定「必须支持」，则需给出类型来源；
  若裁定「可拒」，则须像 `G-3b` 那样把口径**写进规范**（与乙组 `D2` 同族）。

## 4. 处置选项（**未裁**；未决策前不动源码）

- **路径 A · 从 match 臂反推**：`case ok(v)` / `case err(e)` 的模式已经给出了 ok 载荷类型的
  约束 ⇒ 可先扫臂、再以推得的 `Result` 类型回头降载检体。代价：`match` 降载要**两趟**，
  且歧义时（臂只写 `case _:`）仍无解。
- **路径 B · 要求显式标注**：不接受无上下文的 `ok(...)`，报一条**能读懂**的错，
  并给出改法（`var r: ^I32 = ok(1)` 或直接 `match` 一个 `Result` 变量）。
  代价：这是一条**语言面口径**，按治理纪律要**先登记后实现**（走 `spec §1.3`）；
  收益：与「HIR 是静态类型化树」的定位一致。

## 5. 不做范围

- **未裁前不动源码**（本单只登记）。
- 不把本条并入 `G-3b`（该批按「异步体 return 位」如实收口，见其 §11.2）。
- 不顺手给其他无期望类型的位补上下文（未测面）。
# Issue：HIR 拒绝 defer 块形式（`defer:` + 多语句块）

- 状态：**Open（2026-09-11 立案；M6c 横切项 X4 新发现，未实施）**
- 发现来源：M6c 收尾批立案（该形态**无夹具覆盖**，属分母外新发现）
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（M6c 的 C1 格 = defer 降级）、
  `docs/spec/pini-spec-v0.md`（defer 双形态定义）

## 现象（三通道实测）

```
main|func() -> ():
    defer:
        print("first")
        print("second")
    print("body")
    return
```

| 通道 | 结果 |
|---|---|
| 解释器 | `body` / `first` / `second` |
| 旧后端 | `body` / `first` / `second` |
| **HIR** | **rc=1，`Error: IRGen Error [E6-004]`** |

单行形态（`defer print("bye")`）在 HIR 下正常——C1 格修的就是这条路径（含
`return` / `break` / `continue` 的 LIFO 顺序）。**块形式是同一能力的另一形态，未随 C1 覆盖。**

## 规范语义

`defer:` 的块体作为**一个** defer 项入 defer 栈，块内语句按书写序执行，跨项仍为 LIFO。
即上面程序的输出是 `body` 之后先 `first` 再 `second`——解释器与旧后端均如此。

## 根因（已定位）

- AST 的 defer 节点只承载**一个**语句：
  `case deferStatement(statement: Statement, location: SourceLocation)`；
  块形式在解析后包成一个 `scopedBlock` 语句。
- `HIRLowerer` 的 defer 降级只有一条路径：
  `.deferStmt(body: try lowerStatement(wrapped, into: &context))`——
  它把包进来的 `scopedBlock` 原样交给 `lowerStatement`。
- `lowerStatement` **没有 `scopedBlock` 分支**（该名字只出现在错误描述助手里，
  即「给一条它处理不了的语句取个名字」），于是落 default 抛
  `unsupported(...)` → 表面为 `E6-004`。

## 影响

- HIR 通道**拒跑**含块形式 defer 的程序；解释器与旧后端都正常。
- 翻转后该形态在 LLVM 侧不可用 → 能力下降，且是**显式拒绝**（fail-loud，
  不是静默错码），故不构成静默风险。
- 与 C1 的关系：C1 已让 defer 在 HIR 下具备正确的时序语义，本项是**形态覆盖缺口**，
  不是语义缺口。

## 建议处置（未决）

1. 在 `lowerStatement` 增 `scopedBlock` 分支，降级为顺序语句序列；
   同时确认 `deferStmt` 的 body 能否承载多语句——若 HIR 侧 defer 体按单语句
   建模，则需放宽为语句数组（触 HIR 节点形状，是本项估工的关键未知项）。
2. 补夹具（块形式 + `return` / `break` / `continue` 路径），使该形态进入分母。

规模估计：若只需在降级期把 `scopedBlock` 展开、且 `deferStmt` 的 body 已是
可容纳序列的形状，则属小改动；若需改 HIR 节点形状，则与 C2 同量级。

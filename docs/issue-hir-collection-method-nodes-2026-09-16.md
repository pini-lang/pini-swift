# 集合方法 `append` / `last` / `pop` 在 HIR 无节点可落

> 状态：**Open**（2026-09-16 立案；**只登记不修**）
> 发现于：`G-2b` 勘测。它是该子批**未交付的那一半**。
> 上游：`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-2b` 行。

## 1. 现象（实测，2026-09-16，`main` = `2d49c1f`）

```pini
main|func() -> ():
    var a = [1, 2, 3]
    var b = a.append(4)      # 也应支持 a.last() / var (b, top) = a.pop()
    print(a)
    print(b)
    return
```

| 命令 | 结果 |
|---|---|
| 默认（HIR） | **rc≠0**：`HIR lowering error: method 'append' calls are later grids` |

`last` / `pop` 同形（各自报同名错误）。这三条是「降载层最后的兜底分支」接住的，
即：**不是忘了实现，而是没有可以降到的节点**。

**受影响的用例**（实测计数）：`CollectionsTests` 3 条（`append` ×1、`last` ×2 兼 `pop`）·
`ArrayElementAnnotationTests` 1 条 · `CrossFileRuntimeTests` 2 条 · 共 **6 条**。

## 2. 符号级根因（实测，非推断）

1. `HIRExpr` 的 44 个节点里，数组族只有 `arrayLiteral` · `subscriptGet` · `lenCall` ·
   `optionalGet` · `sliceCall` · `arrayJoin`——**没有**「追加」「取尾」「弹出」。
2. `HIRStmt` 的 16 个语句节点同样没有对应写入位。
3. ⇒ 三条方法**无法在不新增节点的前提下表达**；`a.append(x)` 是「新数组」而 `a.pop()` 返回元组，
   都不能靠既有节点拼装（数组字面量无展开语法）。
4. ⚠️ **不是契约漏登**：契约的计数基线是 `44 + 16 = 60`，且「节点一经落地不得随实现漂移」
   （`ADR-034 D5`）⇒ 新增节点走 `docs/spec/pini-spec-v0.md` §1.3 五步治理，**不属于 `G-2` 的范围**
   （规划 §6 明列「不改契约计数」）。

## 3. 影响与选项（供后续裁决）

| 选项 | 代价 |
|---|---|
| A 新增三个节点（`arrayAppend` / `arrayLast` / `arrayPop`）| 契约 §2/§3 条目 + 三后端锚点（执行器 / 发射器 / 打印器）+ `hir-contract-check.py` 的计数基线同步 ⇒ 一次契约变更 + 三处实现 |
| B 用一个通用「内建方法调用」节点承载（receiver + 方法名 + 实参）| 计 1 个节点，但把「按名分派」放进语义层，与 `characterBuiltins` 那张表的做法同族；代价是节点语义变宽，契约条目要写清允许的名单 |
| C 不实现，`append`/`last`/`pop` 随走查退役 | 语言能力回退（三者在 `Interpreter` 侧是活着的），需 release note 明示 —— 与 `G-3` 的 `R1/R2` 同族问题 |

⚠️ **本单不预设选项**：它同时是 `G-3` 那条「保能力还是弃能力」判断的一个子问题，宜与 `R1/R2` 同批裁。

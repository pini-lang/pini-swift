# 字典 `.get` 的 IR 生成非法（IREmitter），且被 `run-llvm` 丢弃退出码掩成非阻塞

> 状态：**Open**（2026-09-17 立案；**只登记不修**）
> 发现于：**CG 批**（`docs/hir-criteria-gap-ledger.md` 五条待处置）—— 为第 12 条的「`builtinGet` 字典键相等」分支**造靶点**时实测。
> 上游：`docs/hir-criteria-gap-ledger.md` §8.3。

## 1. 现象（实测，2026-09-17，`main` = `f2f63fc`）

一个只用字典 `.get` 的极短程序：

```
main|func() -> ():
    var ages = ["Alice" = 30, "Bob" = 25]
    print(ages.get("Alice"))
    print(ages.get("Bob"))
    print(ages.get("ZZZ"))
    return
```

三通道实测（`tools/three-channel.py`）：

| 通道 | rc | stdout | stderr |
|---|---|---|---|
| `interp-ast` | 0 | `some(30)\nsome(25)\nnone\n` | 空 |
| `interp-hir` | 0 | `some(30)\nsome(25)\nnone\n` | 空 |
| `llvm-hir`（`pini run-llvm`） | **0** | **空** | `lli: error: '%t14' defined with type 'ptr' but expected 'i32'` |

⇒ 两条解释器臂**一致且正确**；**`IREmitter` 产出的 IR 通不过 `lli` 的校验**。

## 2. 为什么它到现在才被发现

探针把该夹具判成 **`HARNESS_DEPENDENT`（非阻塞槽）而不是阻塞**，因为 `run-llvm` 报 `rc=0` ——
它**丢弃了 `lli` 的退出码**。这不是新缺陷，而是在册工单
`docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md` 所描述的掩盖形态**再次生效**。

第二重原因：**探针六根语料里此前没有任何字典 `.get` 用例** —— 所有可见的 `.get(` 都是
数组/字符串的整数索引。没有夹具 ⇒ 没有靶点 ⇒ 这个 IR 缺陷在语料里**不可见**。
（这正是台账 CG-10 的同型形态：不是「结构不可构造」，而是「语料未覆盖」。）

## 3. 根因方向（**未定位**，仅记录观察）

报错点：`%t14` 被定义为 `ptr` 却按 `i32` 使用。字典键是**任意值**（字符串/整数…），
而数组/字符串下标是整数索引 —— `RuntimeOps.builtinGet` 显式按**接收者类型分流**（源码注释记了
「批 2 遗留缺陷，批 3 取证发现」）。⇒ 疑点在 **emitter 对「键」与「索引」的类型分派**，
与 `Value.dictionary` 的 IR 表示。**未读码确认**，不得据此下手。

## 4. 影响

- **用户可见**：`pini run-llvm` / `pini compile` 对使用字典 `.get` 的程序**静默给出空输出**（rc=0），
  而解释器两侧都正确 ⇒ 一个「后端不一致」且**不报错**的形态。
- **判据可见**：`ast⇄llvm` 边由 `HIRDifferentialTests` 覆盖，但那批夹具不含字典 `.get`
  ⇒ 该边**对这一形态失明**；`hir⇄llvm` 边（探针）把它判为**非阻塞**。
- ⇒ 台账 **CG-12 的「字典键相等」分支因此暂缺见证**（独立臂不可用），本批只能记为**部分处置**。

## 5. 不做范围

- 本单**不修** `IREmitter`，也不修 `run-llvm` 的退出码转发（后者是**另一张**在册工单）。
- 不把该候选夹具入仓：它会让探针分母再抬一位，却**换不到**任何见证（独立臂跑不动）。
  ⇒ 夹具内容与实测记录留在本单与台账 §8.3，待 emitter 修好后再入仓。
- 本单不改变 CG-12 的归属，也不触发新的批次。

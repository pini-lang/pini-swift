# Issue：HIR 引擎未应用 struct 值拷贝规则（`copyIfStruct` 在绑定点缺失）

- 状态：**Open（2026-09-14 立案；LR-4 P2a G5 收口登记，不阻塞本格）**
- 发现渠道：G5（具名类型与字段）实现期。**归档版 `86fdafd` 的 docstring 已声称本项「Filed as a defect
  with its own ticket」，但实测 `docs/` 下无任何相关工单** ⇒ 本单是**把该声明真正兑现**，并订正该处表述。
  （归档只留声明、未留工单，属「归档自我声明必须复核」的第三个实证，见 G5 细目件实录。）
- 归属：**语言语义的实现面**（值类型 vs 引用类型的拷贝语义）。**非裁决项** —— 语义本身由解释器
  既有的 `Interpreter.copyIfStruct` 单方定义，本单只是「引擎尚未复刻」。
- 关联：
  - `docs/issue-interpreter-hir-plan-2026-09-12.md`（LR-4 逐格实录）；
  - `docs/issue-interpreter-hir-p2-plan-2026-09-13.md` §8.5（G5 实录，本单的来源格）；
  - P4（删除 AST 走查）—— **本单是它的前置**：现在 AST 通道承担着 struct 拷贝，
    P4 之后 HIR 独占，本洞即成为真实用户可见缺陷。

## 现象

`Interpreter.copyIfStruct` 是 `Interpreter` 的**实例方法**，HIR 执行引擎在下列**绑定点与写入点**
均未应用该规则：

| 落点 | 应有行为 | 现状 |
|---|---|---|
| `allocVar` | 把 struct 值绑进新槽时深拷贝 | ❌ 未应用 |
| `storeVar` | 赋值给 struct 槽时深拷贝 | ❌ 未应用 |
| `fieldStore` | 把 struct 存入字段时深拷贝 | ❌ 未应用 |
| `subscriptStore` | 把 struct 存入容器时深拷贝 | ❌ 未应用 |

⇒ HIR 通道下 `var b = a`（`a` 为 struct）会让 `b` 与 `a` **共享底层存储**，
而语言语义要求**拷贝**。修改 `b.x` 会连带改到 `a.x` —— 这是**静默的错误结果**，
不是显式分叉。

## 为什么 G5 才暴露、且现在仍不阻塞

- **G5 之前 struct 根本不可达**：引擎里没有任何节点能造出 struct 值（`construct` 未实现）
  ⇒ 该差异是**休眠**的，无可观测后果。
- **G5 让 struct 可达** ⇒ 差异从休眠变为**真实**。
- **但今日无可观测后果**：**没有任何夹具把 struct 值存进另一个槽**（实测全量语料 +
  73 个差分夹具均无该形状）⇒ 两通道的可观测输出**均不动**。
- ⇒ 本格**不实现**（实现即「无验证的改动」），**只立案**。

## 为什么不能靠单测 parity 挡住

本项**恰好是**「两通道共用代码」之外的**同型盲区**：`copyIfStruct` 是解释器的实例方法，
而 `HIRExecutorTests.assertParity` 只比 `hir` vs `ast` 两条通道。**若将来在两条通道里
都漏掉拷贝，两者会一致地错** ⇒ parity 恒绿而结果错。

⇒ 覆盖本项需要 **①绝对断言**（断言 `a` 未被 `b` 的写入影响）或 **②三通道探针**。
本格的手写用例 `testObjectAliasingThroughASecondBindingAndAPlainVariableBase` 正是
**按此形状**写的 —— 但它**刻意用 object（引用类型）**，因为引用类型下「别名成立」是**正确的**，
可以直接钉死；而 struct 半边若断言，就会**钉住一个已知错误答案**，比不测更糟
（归档 docstring 已记此理由，本格沿用）。

## 处置建议（不排期）

1. **优先级随 P4 抬升**：P4 删除 AST 走查后本洞变为用户可见 ⇒ **P4 前置**。
2. 实现时应**复用** `Interpreter.copyIfStruct` 而非另写一份（单源原则）；
   若因它是实例方法而不便复用，则**提到 static 单源**，与 G6 的
   `matchArmMatches` / `builtinGet` 同一处置。
3. 落地时必须**同时**补夹具（struct 存进另一槽的差分夹具），
   否则仍是「无验证的改动」——这正是本格不做的原因。

## 未做（本格边界）

- 未改任何实现（只立案）。
- 未补夹具（本格范围外；补夹具即要求先实现，两者须同批）。
- 未动 `Interpreter.copyIfStruct` 本体（不改既有单源）。

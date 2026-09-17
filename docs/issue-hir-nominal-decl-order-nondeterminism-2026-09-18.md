# Issue：`HIRModule` 的**声明顺序非确定**（同输入跨进程可变 —— 名义清单与函数尾段两处）

> **日期**：2026-09-18｜**状态**：**Open**（只登记不修）
> **发现于**：格 `G-5`（D 类参照臂改造）—— 新写的降载层摘要器械**两次运行对不上**
> **性质**：**既有缺陷被新器械揭开**，不是 `G-5` 引入的
> **归属**：待裁（`LR-4` 内某批 / 立案后单独排）

## 1. 现象（实测：**两处**，同源同族）

`G-5` 新增的降载层摘要器械对同一份夹具连续两次运行，得到**两棵不同的降载树**。
修掉第一处之后第二处才露出来 —— 两处同族（都来自字典遍历），**必须一起记**。

### 1.1 名义清单（先发现）

夹具 `testDiffGenericStruct`：

```
运行 A（捕获轮）：type 盒_I32 …  → type 盒_String …
运行 B（测试轮）：type 盒_String … → type 盒_I32 …
```

### 1.2 函数清单的**尾段**（修掉 1.1 后才暴露）

夹具 `testDiffGenericFunc`：

```
运行 C：… func 身份_String … → func 身份_I32 …
运行 D：… func 身份_I32 …   → func 身份_String …
```

⇒ 泛型特化生成的**函数**按同一字典顺序追加到 `functions` 尾部。

两处的语句序列、函数体、形参类型**逐字符相同**，**只有排列**不同。
⇒ 这是**顺序**问题、不是内容问题：同一份源码、同一二进制、同一台机器。

## 2. 根因（符号级）

| 位置 | 形态 |
|---|---|
| `Sources/PiniCore/HIR/HIRLowerer.swift:427` | `var enums: [String: HIREnumDecl] = [:]` —— **字典** |
| 同件 `:691` | `return HIRModule(functions: functions, types: typeDecls, enums: Array(enums.values), foreigns: foreigns)` |
| 同件 `:611` / `:619` / `:629` | `var typeDecls: [HIRTypeDecl] = []`，由「非泛型名义声明循环 → 对象名义声明循环」两个循环 `.append` |
| 同件 `:642`–`:651` | **G10 特化实例**再 `.append`（`盒_I32` / `盒_String` 正是这一路） |
| 同件 `:655`–`:657` | `functions.append(contentsOf: traitDefaultsCollector.functions)` —— 另一处集合式追加 |
| **函数特化** | `functions` **尾段**由泛型特化收集器追加（`身份_I32` / `身份_String` 即此路）—— 顺序同样来自字典遍历 |

⇒ `Array(enums.values)` 的顺序是 **Swift 字典的迭代顺序**（受每进程哈希种子影响）；
两处特化收集同理。**都不由源码决定** ⇒ 顺序不可复现。

⚠️ **实测到的修法边界（必须一起记）**：把**名义清单**排序只解决 1.1 —— 修完再跑，`testDiffGenericFunc` **仍然红**，
因为**函数尾段**是独立的第二处。⇒ 处置时**必须连函数清单一并处理**；
本批的器械已改为**全排序**（函数 / 类型 / 枚举 / 外部块），理由逐条写在 `renderDigest` 的注释里。

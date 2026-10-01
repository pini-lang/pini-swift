# 名义箱的归属与寿命（片 A–E）—— 交付报告

> **主题**：**名义值（结构体 / 对象 / 枚举）的箱 + 闭包捕获的变量槽，都分配在创建帧里** —— 任何跨帧
> 引用即失效。本批把它改成「**堆箱 + 引用计数**」，并把值语义（四个存储点的即时深拷贝）与捕获装箱一并落地。
> **裁定**：用户 2026-10-01「按你的建议来」⇒ 采纳调研件 §9.3 的**订正后路线**（该建议在开工勘察时
> 推翻了它自己更早的「甲′」——见 §1）。
> **起点件**：`docs/spec/issue/survey-aggregate-return-2026-10-01.md`（证据 + 决策输入，已转正为施工依据）。
> ⚠️ 本件**不含**「门禁接原生臂」—— 那条的前置仍是「自举各层两路读数一致」，本批把它从 **2 层**推进到 **3 层**（§7）。

---

## 1. 洞的准确表述（起点实测，只读）

五条**外逃**探针（被调方在自帧内构造并返回，调用方先垫一次别的调用再用它）+ 四条**同帧对照**：

| 探针 | 形态 | 解释器（权威） | 原生（改动前） |
|---|---|---|---|
| A | 结构体返回 | `A 7 1110` | ⛔ `A -255950760 1110` |
| B | 结构体里套结构体 | `B 8 1110` | ⛔ `B -229641480 1110` |
| C | 对象返回 | `C 9 1110` | ⛔ `C 1 1110` |
| D | 带载荷枚举返回后 `match` | `D 2.0 1110` | ⛔ `match value matched no case` |
| E | 闭包捕获的变量随闭包外逃 | `E2 101 666` | ⛔ `E2 -255950759 666` |
| A–D **同帧对照** | 构造与使用同帧 | 与左列同值 | ✅ 全部通过 |

⇒ **通道本身是好的，失败全由跨帧造成** —— 这一条对照是本批归因成立的关键（没有它，D 会被读成
「`match` 代码生成缺陷」，那正是上一批 `rc=134` 的旧归因）。
⇒ 因此**「返回路径」一个词盖不住它**：对象与枚举在解释器里是**引用语义**（`copyIfStruct` 对它们
原样返回）⇒ 它们的箱**必须比创建帧活得久**；闭包捕获的同理（捕获的是**变量槽**）。

## 2. 模型与四片

**模型（一句话）**：**所有名义箱上堆 + 引用计数；四个值语义点即时深拷贝；闭包捕获的变量槽装箱。**

| 片 | 内容 | 落点 |
|---|---|---|
| **A · 表示与分配** | 三族名义箱**第 0 格统一为 `i32` 引用计数头**（`%object` 原本就有，`%struct`/`%enum` 本批补上；`%enum` 的用例标签顺延到第 1 格）· 分配改走 `bk_nominal_alloc(size)` | `IREmitter` 类型定义段 / `emitNominalAllocation` / 六处 GEP 偏移 / `PiniRuntime.bk_nominal_alloc` |
| **B · 寿命** | 别名点 retain · 作用域退出 release · 写前 release 旧值（**复用容器那套既有位置**）· 每类型合成释放胶水 `__release_*`（递归释放名义字段、归还容器字段、归零 `free`） | `registerReleasedHandle` 改收 `IRType` / `ensureReleaseFunction` / `emitReleaseCall` / `PiniRuntime.bk_nominal_retain|release` |
| **C · 值语义** | 四个存储点（绑定 / 赋值 / 字段存 / 返回）**即时深拷贝** · 每类型合成拷贝胶水 `__copy_struct_*` | `ensureCopyFunction` / `emitValueForStorage` |
| **D · 捕获装箱** | 被闭包捕获的变量槽**上堆**（闭包与帧共享同一个盒） | `capturedNames(in:)`（Mirror 遍历）+ `declareValueSlot` + `PiniRuntime.bk_slot_alloc` |

**两族的统一**：容器句柄（`bk_handle_*`）与名义箱（`bk_nominal_*`）走**两套 C ABI**，
但**所有权规则同一套** —— 释放点只问「这个类型要不要释放」（`releaseSymbol(for:)`），不问它是谁。

## 3. 施工中发现并修掉的三处（都不在起点件里）

1. **枚举释放胶水：空 arm ⇒ 非法 IR**（`expected instruction opcode`）。判据不能是「有没有载荷」——
   只有标量载荷的 case 生成的 arm 里一条释放也没有，而 `after` 标签前没有终结指令时 clang 整段拒绝。
   ⇒ 判据改为「**这个 case 有没有释放动作**」。
2. **枚举释放胶水：槽的判据必须按 case 自己的载荷类型**（⛔ 不是 `slotTypes`）。实测：自举 `ast` 层
   崩在 `__release_enum.TypeAnnotation → __release_enum.TypeAnnotationList(box=0x1000b06a5)`，
   而那个地址落在 `__TEXT.__const`。理由：**同一个槽在不同 case 里可以是不同类型** ——
   `TypeAnnotation` 的槽 0，`simple` 放 `String`、`tupleType` 放 `TypeAnnotationList`。
3. **无初始化式的变量槽曾被当作「有箱」释放**。`alloca` 里是垃圾，而它会被登记退出释放 ⇒
   实测（`ast` 层）`bk_nominal_release` 写在代码段上（`SIGBUS` / `KERN_PROTECTION_FAILURE`）。
   ⇒ 参与计数的类型，其无初始化式槽**清零**（`null` = 「还没有箱」，释放路径对它是无操作）。

## 4. 判据与器械（片 E）

**器械**：`examples/selfhost/tools/check-nominal-boxes.sh`（三态退出码，与本仓其余门禁一致）。
**权威 = 解释器的行为** —— 比的是**两路逐字节**，⛔ 不比「实现输出 vs 手写期望」。

**十二条判据件**（`tools/.fixtures/`）：五条外逃 + 四条同帧对照 + `aggregate-copies`（值语义四点）
+ `aggregate-shares`（共享边界：**形参共享**是裁定的可观察行为）+ `structret-escaping`（上一批留存）。

**终点读数：十二条全部两路逐字节相同**（器械绿）：

```
绿 aggregate-escape-A-struct：A 7 1110          绿 aggregate-escape-E-capture：E2 101 666
绿 aggregate-escape-B-nested：B 8 1110          绿 aggregate-sameframe-*（四条对照）
绿 aggregate-escape-C-object：C 9 1110          绿 aggregate-copies：ALLOC 1 2 / STORE 3 4 / FIELD 9 / RETURN 7
绿 aggregate-escape-D-enum：D 2.0 1110          绿 aggregate-shares：A-ASSIGN 1 2 / C-AFTER-PARAM 50 VIA 50 /
绿 structret-escaping：BEFORE 7 9                    D-AFTER-RETURN 7 / ONE 7
```

**变异反证（两级）**：

| 变异 | 读数 |
|---|---|
| M1 · 名义箱分配改回栈 `alloca` | 打红 3 条（`escape-C-object` / `escape-D-enum` / `sameframe-B-nested`）—— 主判据面转红 ✓ |
| M2 · 值语义拷贝点失效（`emitValueForStorage` 直接返回） | `aggregate-shares` 读数退回**改动前的别名形态**（`A-ASSIGN 2 2` / `D-AFTER-RETURN 9` / `ONE 11`）—— 自我印证 ✓ |

⚠️ 两处如实登记：① M1 同时打红了一条**同帧对照**（变异比「只回退分配位置」更强：它同时改了寿命模型）；
② 变异的**备份与还原**各踩了一次「脚本二次执行」—— `cp` 的目标路径被第二次执行覆盖，
导致还原后仍带变异（判据抓到了：器械仍红）。定式：**还原式变异后必须强制重建**
（`rm` 产物 + 重建），且**判据是行为探针**（emit 行数 / 器械读数），⛔ 不是 `Build complete` 回显。

## 5. 回归（如实）

| 项 | 读数 | 对照 |
|---|---|---|
| `swift test` 全量 | **rc=0 · 167 测试 / 20 套件全过**（14 known issues，与本批无关） | 与基线同值 |
| 仓内语料两路对照 | **44 / 51 逐字节相同** | **与基线同值 ⇒ 无回归**（7 条差异全是 `concurrency-*`，两路 rc 都 = 1，改动前同） |
| 未定义符号差集（最小程序 + 自举整包） | **空** | 4.zd 的判据 |

## 6. emit 规模

`pini emit examples/selfhost/src/main.pini` ⇒ **rc=0 · 4 s · 126121 行**（改动前 106510 行；
增量来自每个构造点由「1 行 `alloca`」变为「取大小 + 分配」，以及释放/拷贝胶水）。

## 7. 自举全层对照（**本批的核心推进**）

`pini run . <层>`（解释） vs **自举整包编出的原生二进制**（`emit` → clang 链接 → 运行）：

| 层 | 上一批（改动前） | 本批 | 判定 |
|---|---|---|---|
| `ast` | ✅ 逐字节相同 | ✅ 逐字节相同 | 保持 |
| `common` | ⚠️ 行数同（36/36）但**取值全空** | ✅ **逐字节相同（2376 字节）** | ⭐ **升级** |
| `type-seg7` | ✅ 逐字节相同 | ✅ 逐字节相同 | 保持 |
| `lexer` · `parser` · `parser-decl` · `desugar` · `type-seg2…5b` · `ir-lower` | ⛔ rc=139 | ⛔ rc=139 | 未变 |
| `semantic` · `type-seg6` · `ir-run` · `module` | ⛔ rc=139 / rc=134 | ⛔ rc=133 / rc=138 | 崩溃形态变（见下） |
| `type-seg1` | ⛔ rc=134（`match value matched no case`） | ⛔ rc=134（同句，另出 171 B 输出） | 未变 |

**绿层 2 → 3**，其中 `common` 从「取值全空」变为**逐字节相同** —— 它是 B 组字符语义与本批名义箱
两批改动的**合力**（`common` 的「取值全空」直因是 `len`/`s[i]` 的字符模型分歧 + 名义值跨帧）。

**剩余红层的直因（已定位，⛔ 不在本批 scope）**：`emitStringSplit` 的
`malloc(strlen(s))` + `strcpy` —— **少一字节**（NUL）。证据链：
① ASan 报 `heap-buffer-overflow: WRITE of size 85 → 84-byte region`（`makeScanner → tokenize`）；
② `git show HEAD` 的同一处**逐字相同** ⇒ **既有缺陷**，不是本批引入；
③ 手工补 8 处该 off-by-one 的 IR 后**仍不解锁** ⇒ 剩余红是**多缺陷叠加**，⛔ 不是单点。
⇒ 因此本批**不修它**（scope 外 + 修了也不够），留作下一批的起点（§9）。

## 8. 如实登记的边界（本批**未**解决）

1. **临时实参的箱会泄漏**：形参传递按**借用**（调用点不 retain、被调方不释放形参）——
   实参是临时值时（`f(点(),)`）那份箱没有释放者。⇒ 与容器现状同病，修它要动**调用约定**（另一批）。
2. **捕获槽本身不释放**：`bk_slot_alloc` 的盒寿命归闭包（`malloc` 且不 free），
   与闭包 env 同阶（env 本来就不释放）。
3. **`given` 单例盒不参与计数**：`bk_given_get` 的盒由运行时持有到进程结束，头格写 1 只是形态一致。
4. **值语义只覆盖结构体**：对象 / 枚举是引用语义（拷贝即共享），这与解释器一致，⛔ 不是缺口。
5. **递归释放的环**：与解释器同假设（值类型语义下不存在环）。

## 9. 载体

- 宿主：`Sources/PiniCore/CodeGen/IREmitter.swift` · `Sources/PiniRuntime/PiniRuntime.swift` ·
  `docs/spec/ir-contract.md`（§1 表格两行 + **新增 §1.1 值语义条款** —— 该条款此前**没有载体**）
- 自举：`tools/check-nominal-boxes.sh`（判据器械）· `tools/.fixtures/aggregate-{copies,shares}.pini`（新）
- 元仓：`auth-75`（本批）· `L4` / `L5`

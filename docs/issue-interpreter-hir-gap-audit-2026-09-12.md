# P0 审计：解释器统一 HIR 的枢纽缺口台账

- 状态：**P0 已收口（2026-09-12）** —— P0 与 P0c 的产出**全部交付**，无实质缺口；
  收口动作 = 清过期标注 + 遗留缺陷立案 + 状态回填。**全过程未改任何源码**（含测试与夹具）。
  **P0b 已交付（2026-09-12）**：本审计是 P0b 的**证据来源**，其裁决落点见
  `docs/spec/adr/adr-034-hir-contract.md`（判准与 A/B/C/D/E 组结论）与
  `docs/spec/hir-contract.md`（60 节点语义，含本审计 §5.1–§5.3 各项的契约侧表述）。
  **下一格 = P1（通道与判据基建），待点名**。
- 订正记录：P0c 复审订正 §5.3.1 / §5.5 / §7.1；P0 收口订正 §1（E3 状态）/ §5.3（标题）/
  §7（标题）/ §7.5（编号错位）。
- 关联：`docs/issue-interpreter-hir-plan-2026-09-12.md`（常驻计划载体，P0 一格）；
  `docs/issue-interpreter-hir-unification-2026-09-07.md`（立案背景）；
  `docs/issue-hir-string-slice-byte-based-2026-09-11.md`（同根因族工单，本批回答其遗留未知项）；
  `docs/spec/adr/adr-019-unicode-char-model.md`（**字符模型裁决出处——P0c 复审的关键依据**）；
  `docs/spec/adr/adr-033-char-type.md`（Char 类型引入，**Accepted 2026-09-12**）；
  `docs/spec/adr/adr-034-hir-contract.md`（**HIR 契约，Accepted 2026-09-12——本审计的裁决落点**）；
  `docs/issue-e7-001-false-unused-warning-2026-09-12.md`（收口期立案，§7.4 观察 1）
- 实施工单：`docs/issue-ffi-char-rename-cchar-2026-09-12.md`（P0d 前置，`Char` 腾名）；
  `docs/issue-io-limit-from-emitter-2026-09-12.md`（P0b 立案，§5.2 A1/A2 上限的对齐后果）
- 基线：main `361ec2c`，分支 `agent/pini-dev/hir-hub-p0`
- 台账口径：**行号为 2026-09-12 实测快照**；实现改动后一律改用符号检索重新定位，勿复用行号
- **⚠️ 读前必看**：本文件 §5.3.1 的**初稿根因结论已被 P0c 复审推翻**（初稿误判为「规范空白」，
  实为「规范已裁、实现偏离」）。请以订正块与 §7.1 现行口径为准。

---

## 1. 审计方法与证据分级

**初稿未构建**（`/tmp/pini-build` 已被系统清理，仓内 `.build` 为 09-07 陈旧副本）；
**后按授权补做一次 debug 全量构建（8.2s）并跑完 M0–M8 三通道实测** ⇒ **E3 已取得**（§7.3）。
故证据分三级，台账逐项标注来源，**不用低级证据冒充高级证据**：

| 级 | 类型 | 说明 |
|---|---|---|
| **E1** | 代码结构证据 | 读源码得出的实现形态（本批主体） |
| **E2** | 注册表 / 测试期望证据 | `BuiltinRegistry` 的声明、既有测试的断言（权威度高于实现自述） |
| **E3** | 执行实测证据 | 跑三通道拿到的实际输出 —— **已取得**，见 §7.2 / §7.3 |

判据纪律：E1/E2 冲突时以 **E2 为准**（注册表与测试表达语言意图，实现只是其中一种落地）。
本批有三处正是 E1 与 E2 冲突（§5）；E3 另**推翻了一处 E1 推算**（§7.3 的 `substring(2,100)` 自我订正）。

---

## 2. 60 节点台账

节点面实测 **44 expr + 16 stmt = 60**，与计划 §3 记载一致。
节点可从 `HIRNode.swift` 机械枚举（4 空格 `case` + 上方 `///`），台账由脚本生成、非目测。

- 「类」列 = 本轮按「语义定义在哪里」重判的分级（判据见 §3）。
- 「上游函数」列 = 该节点构造点所在的 `HIRLowerer` 函数；`resolve` 是主入口，粒度偏粗，
  **P0b 需细化为上游 AST 节点**。
- 「bk_*」列仅表示**分派分支字面量内**是否出现，实际依赖多在 `emitXxx` helper 内
  → 该列**低可信**，P0b 应改为「经由哪个 helper、helper 是否调 `bk_*`」。

| # | 节点 | 类 | 载荷 | 上游函数 | IREmitter 分派行 | 块行数 | bk_* | 备注 |
|---|---|---|---|---|---|---|---|---|
| 1 | `intConst` | 丁 | `(value: Int, type: HIRType)` | resolve | 1330 | 2 |  |  |
| 2 | `floatConst` | 丁 | `(value: Double)` | resolve | 1333 | 2 |  |  |
| 3 | `boolConst` | 丁 | `(value: Bool)` | resolve | 1336 | 2 |  |  |
| 4 | `stringConst` | 丁 | `(value: String)` | resolve | 1339 | 2 |  |  |
| 5 | `load` | 丁 | `(name: String, type: HIRType)` | resolve | 1014 | 12 | 是 |  |
| 6 | `binary` | 丁 | `(op: HIRBinaryOp, lhs: HIRExpr, rhs: HIRExpr, type: HIRType)` | resolve | 1350 | 2 |  |  |
| 7 | `unary` | 丁 | `(op: HIRUnaryOp, operand: HIRExpr, type: HIRType)` | resolve | 1353 | 20 |  |  |
| 8 | `call` | 丁 | `(function: String, arguments: [HIRExpr], returnType: HIRType?)` | traitSignatureInfo | 1374 | 19 | 是 |  |
| 9 | `printCall` | 丁 | `(argument: HIRExpr)` | resolve | 1394 | 2 |  |  |
| 10 | `resultConstruct` | 乙 | `(isOk: Bool, payload: HIRExpr, type: HIRType)` | resolve | 1409 | 16 |  | 三槽 `{ i64, T, i64 }` |
| 11 | `arrayLiteral` | 丙 | `(elements: [HIRExpr], type: HIRType)` | resolve | 1426 | 2 |  | `bk_array_*`（元素装箱） |
| 12 | `subscriptGet` | 丙 | `(container: HIRExpr, index: HIRExpr, type: HIRType)` | resolve | 1027 | 18 | 是 |  |
| 13 | `lenCall` | 丙 | `(argument: HIRExpr)` | resolve | 1432 | 2 |  | `bk_*_len` |
| 14 | `optionalGet` | 乙 | `(container: HIRExpr, index: HIRExpr, type: HIRType)` | resolve | 1435 | 2 |  | tag 检查 + 下标 panic 面 |
| 15 | `optionalConstruct` | 乙 | `(isSome: Bool, payload: HIRExpr?, type: HIRType)` | resolve | 1438 | 14 |  | `{ i64, T }`，tag 0=some / 1=none |
| 16 | `sliceCall` | 丙 | `(container: HIRExpr, start: HIRExpr, end: HIRExpr, type: HIRType)` | resolve | 1453 | 2 |  | **字节**偏移（见 §5.3） |
| 17 | `construct` | 乙 | `(type: HIRType)` | resolve | 1456 | 2 |  | `%struct.*` / `%object.*`（**refcount 头 field 0**） |
| 18 | `enumConstruct` | 乙 | `(enumName: String, caseName: String, tag: Int, payloads: [HIRExpr], payloadTypes: [HIRType])` | resolve | 1459 | 16 |  | `%enum.*`，**i32 tag field 0** + max-arity 载荷槽 |
| 19 | `fieldGet` | 乙 | `(base: HIRExpr, field: String, type: HIRType)` | resolve | 1499 | 8 |  | GEP + load（按布局） |
| 20 | `dictLiteral` | 丙 | `(entries: [HIRDictEntry], type: HIRType)` | resolve | 1476 | 2 |  | `bk_dict_*` |
| 21 | `setLiteral` | 丙 | `(elements: [HIRExpr], type: HIRType)` | resolve | 1479 | 2 |  | `bk_set_*`（有序去重） |
| 22 | `tupleConstruct` | 丁 | `(labels: [String?], elements: [HIRExpr], type: HIRType)` | resolve | 1482 | 10 |  |  |
| 23 | `tupleIndexGet` | 丁 | `(base: HIRExpr, index: Int, type: HIRType)` | resolve | 1493 | 5 |  |  |
| 24 | `closureLiteral` | 乙 | `(id: Int, paramNames: [String], paramTypes: [HIRType], returnType: HIRType?, captured: …)` | resolve | 1397 | 5 |  | fat pointer `{ ptr, ptr }` = `{ code, env }` |
| 25 | `functionValue` | 乙 | `(functionName: String, type: HIRType)` | resolve | 1403 | 2 |  | fat pointer `{ ptr, ptr }` |
| 26 | `indirectCall` | 乙 | `(callee: HIRExpr, arguments: [HIRExpr], returnType: HIRType?)` | resolve | 1406 | 2 |  | 调用协议：**首参恒为 env 指针** |
| 27 | `pointerLoad` | 乙 | `(pointer: HIRExpr, type: HIRType)` | resolve | 1577 | 2 |  | `*U8` load 符号扩展到统一 int |
| 28 | `pointerStore` | 乙 | `(pointer: HIRExpr, value: HIRExpr, type: HIRType)` | resolve | 1580 | 2 |  | 截断式 store（解释器一致） |
| 29 | `addressOfVar` | 乙 | `(name: String, type: HIRType)` | resolve | 1583 | 2 |  | alloca → `ptr` |
| 30 | `printMulti` | 甲 | `(arguments: [HIRExpr])` | resolve | 1586 | 2 |  | `emitPrintMulti`（25 行） |
| 31 | `assertCall` | 丁 | `(condition: HIRExpr, message: HIRExpr?)` | resolve | 1589 | 2 |  |  |
| 32 | `fileWrite` | 甲 | `(path: HIRExpr, content: HIRExpr)` | resolve | 1592 | 2 |  | 返回 `fclose` 的 i32 |
| 33 | `fileRead` | 甲 | `(path: HIRExpr)` | resolve | 1595 | 2 |  | `alloca [65536 x i8]` + 单次 `fread` → **64 KiB 硬上限** |
| 34 | `readLine` | 甲 | `(none)` | resolve | 1598 | 2 |  | `fgets(buf,256,stdin)` → 256 B 上限 + **不剥换行** |
| 35 | `isAsciiDigit` | 甲 | `(argument: HIRExpr)` | resolve | 1601 | 1 |  | `emitIsAsciiDigit`（12 行） |
| 36 | `stringCase` | 甲 | `(isUpper: Bool, receiver: HIRExpr)` | resolve | 1508 | 3 |  | `toupper`/`tolower` **逐字节**；解释器 = Swift `uppercased()` |
| 37 | `stringContains` | 甲 | `(receiver: HIRExpr, needle: HIRExpr)` | resolve | 1512 | 8 |  | C `strstr` **字节**匹配；解释器 = 下沉 Pini（字符级） |
| 38 | `stringSubstring` | 甲 | `(receiver: HIRExpr, start: HIRExpr, **length**: HIRExpr)` | resolve | 1521 | 19 |  | `memcpy(buf, recv+start, length)`；注册表/解释器为 `(start, **end**)` → **语义分歧**（§5.1） |
| 39 | `stringSplit` | 甲 | `(receiver: HIRExpr, delim: HIRExpr, type: HIRType)` | resolve | 1541 | 4 |  | C `strtok` 两趟，**跳过空 token**；解释器 = 下沉 Pini（保留空段） |
| 40 | `arrayJoin` | 甲 | `(receiver: HIRExpr, separator: HIRExpr)` | resolve | 1546 | 4 |  | `emitArrayJoin` |
| 41 | `stringConcat` | 甲 | `(lhs: HIRExpr, rhs: HIRExpr)` | resolve | 1551 | 16 |  | `strlen`+`strcpy`+`strcat`（malloc） |
| 42 | `interpString` | 甲 | `(parts: [HIRExpr])` | resolve | 1568 | 2 |  | `emitInterpString`（10 行） |
| 43 | `lazyRefConstruct` | 丙 | `(closure: HIRExpr, type: HIRType)` | resolve | 1571 | 2 |  | `bk_lazyref_*` |
| 44 | `lazyRefValue` | 丙 | `(handle: HIRExpr, type: HIRType)` | resolve | 1574 | 2 |  | `bk_lazyref_value` |
| 45 | `allocVar` | 丁 | `(name: String, type: HIRType, mutable: Bool, initializer: HIRExpr?)` | resolve | 543 | 12 |  |  |
| 46 | `storeVar` | 丁 | `(name: String, type: HIRType, value: HIRExpr)` | resolve | 556 | 11 |  |  |
| 47 | `ifStmt` | 丁 | `(condition: HIRExpr, thenBody: [HIRStmt], elseBody: [HIRStmt]?)` | resolve | 568 | 2 |  |  |
| 48 | `whileStmt` | 丁 | `(condition: HIRExpr, body: [HIRStmt], step: [HIRStmt]?)` | resolve | 571 | 2 |  |  |
| 49 | `forInStmt` | 丁 | `(pattern: [String], elementTypes: [HIRType], kind: HIRForIterableKind, iterable: …)` | resolve | 574 | 5 |  |  |
| 50 | `returnStmt` | 丁 | `(value: HIRExpr?)` | resolve | 580 | 18 |  |  |
| 51 | `exprStmt` | 丁 | `(HIRExpr)` | resolve | 599 | 2 |  |  |
| 52 | `deferStmt` | 丁 | `(body: [HIRStmt])` | resolve | 602 | 2 |  |  |
| 53 | `tryStmt` | 丁 | `(operand: HIRExpr, errorVar: String, handler: [HIRStmt], okTarget: String?, type: …)` | resolve | 605 | 2 |  |  |
| 54 | `subscriptStore` | 丙 | `(container: HIRExpr, index: HIRExpr, value: HIRExpr, elementType: HIRType)` | resolve | 608 | 2 |  | COW split chain 内联值语义 |
| 55 | `breakStmt` | 丁 | `(depth: Int)` | resolve | 611 | 2 |  |  |
| 56 | `continueStmt` | 丁 | `(depth: Int)` | resolve | 614 | 2 |  |  |
| 57 | `panicStmt` | 丁 | `(message: String)` | resolve | 617 | 5 | 是 | `bk_panic` + `unreachable`（fail-loud） |
| 58 | `matchStmt` | 丁 | `(scrutinee: HIRExpr, cases: [HIRMatchCase], scrutineeType: HIRType)` | resolve | 623 | 2 |  |  |
| 59 | `fieldStore` | 乙 | `(base: HIRExpr, field: String, value: HIRExpr, fieldType: HIRType)` | resolve | 626 | 8 |  | GEP + store（按布局） |
| 60 | `captureMarker` | 丁 | `(name: String)` | resolve | 635 | 3 |  |  |

---

## 3. 四分级实测对账：计划预分类 3 处需订正

计划的四分级（甲 9 / 乙 11 / 丙 9 / 丁 31）是**预分类**，本轮逐节点重判后**三档计数变化**：

| 类 | 计划 | 本轮实测 | 差异 |
|---|---|---|---|
| 甲 偶然选择 | 9 | **12** | **+3**（`stringContains` / `stringSplit` / `arrayJoin`） |
| 乙 ABI 约定 | 11 | **13** | +2（`fieldStore` / `pointerStore` 计入；`optionalGet` 计入 panic 面） |
| 丙 运行时外包 | 9 | 9 | 一致 |
| 丁 语义自足 | 31 | **26** | −5（上两档吸收） |
| 合计 | 60 | **60** | ✅ |

### 甲类为什么从 9 变 12

计划的甲类判据是「发射器为自身方便的选择被写进节点语义」。按此判据，
**`lowerStringMethod` 的六个 String 成员全在同一分派点**（`HIRLowerer` 的
`case "upper","lower","contains","substring","split"`），且发射侧一律落到 C 库函数：

| 节点 | 发射侧实现 | 是否「为发射器方便」 | 计划归类 | 本轮归类 |
|---|---|---|---|---|
| `stringCase` | `toupper`/`tolower` 字节循环 | 是 | 甲 | 甲 |
| `stringContains` | C `strstr` | **是**（未走 `bk_*`，与解释器下沉实现两套） | †未列 | **甲** |
| `stringSubstring` | `memcpy` 字节 + `start/length` | 是 | 甲 | 甲 |
| `stringSplit` | C `strtok` 两趟 | **是**（跳过空 token 是实现特性） | †未列 | **甲** |
| `arrayJoin` | `emitArrayJoin` | **是** | †未列 | **甲** |
| `stringConcat` | `strlen`+`strcpy`+`strcat` | 是 | 甲 | 甲 |

† `stringSplit` 的源码注释已自述「strtok skips empty tokens — corpus-identical with the
interpreter's sunk split」——**作者知道差异存在并判为语料内一致**。这属于「已登记的偶然选择」，
但仍应进甲类台账（它是一处**未走语言层裁决**的行为）。

> **对 P0b 的直接输入**：裁决表由 9 项扩为 **12 项**。止损 6 的分母随之变化（见 §6）。

---

## 4. 乙类后端无关性审查（WASM 约束）

乙类 13 项必须逐项标注「**后端实现约定，非语义**」，否则 WASM 端会被 LLVM 约定绑死
（计划 §3、D-B10 修订）。本轮逐项判定如下：

| # | 项 | 实现形态（E1） | 判定 | 后端无关的语义表述 |
|---|---|---|---|---|
| 1 | result 构造 | `{ i64, T, i64 }` 三槽 | **后端约定** | 「ok 载荷类型 T；错误槽类型擦除为一个机器字」 |
| 2 | optional 构造 | `{ i64, T }`，tag 0/1 | **后端约定** | 「some/none 判别 + 载荷」；tag 取值是布局细节 |
| 3 | optionalGet | tag 检查 + panic 面 | **半语义** | 「越界 → panic」是语义；**用 tag 实现**是约定 |
| 4 | enum 构造 | `%enum.*`，i32 tag field 0 | **后端约定** | 「按 case 序编号 + 载荷按 max-arity 定宽」 |
| 5 | nominal 构造（对象） | `%object.*`，**refcount 头 field 0** | **后端约定** | 「引用语义 / 对象同一性」是语义；refcount 是实现 |
| 6 | nominal 构造（值） | `%struct.*` 栈指针 | **后端约定** | 「值语义拷贝」 |
| 7 | fieldGet | GEP + load（按布局） | **后端约定** | 「按声明序取字段」 |
| 8 | fieldStore | GEP + store | **后端约定** | 同上 |
| 9 | closureLiteral | fat pointer env | **后端约定** | 「闭包捕获环境」是语义；`{ptr,ptr}` 是布局 |
| 10 | functionValue | fat pointer code | **后端约定** | 「函数是一等值」 |
| 11 | indirectCall | **首参恒为 env 指针** | **后端约定** | 「间接调用的实参表」；env 首参是调用协议细节 |
| 12 | addressOfVar | alloca → `ptr` | **后端约定** | 「取变量地址」；alloca 是实现 |
| 13 | pointerLoad / pointerStore | 按元素类型 load/store；`*U8` 符号扩展 | **半语义** | 「load 按元素类型解码」是语义；**符号扩展规则**须上提或标注为约定 |

**结论**：13 项中 **11 项纯后端约定**、**2 项半语义**（`optionalGet` 的 panic 面、
`pointerLoad` 的符号扩展）。半语义两项**必须在规范里表述为语义**，否则 WASM 端
可以合法地做出不同行为而无法判定谁对。

---

## 5. 关键发现（本批新增，计划未载）

### 5.1 【**已确认**缺陷】`String.substring` 两通道参数语义不一致

> **状态（2026-09-12）**：初稿标「候选」是**待 E3 时**的措辞。E3 已实测确认
> （**M1**：解释器 `ell` vs LLVM `ello`，见 §7.3），且已登记进
> `docs/issue-hir-string-slice-byte-based-2026-09-11.md`（其建议处置第 3 条：本项**不需语言层裁决**，
> 属 HIR 偏离注册表，可独立修）。

**证据链（E1 + E2 三重互证）**：

| 出处 | 形态 | 第二参数语义 |
|---|---|---|
| `BuiltinRegistry.swift`（**权威注册表**，E2） | `paramNames: ["start", "end"]` | **end**（绝对索引） |
| `StdlibPini.swift`（解释器下沉实现，E2） | `substring\|self(start: I32, end: I32,)` → `hi = end; while k < hi` | **end** |
| `StdlibTests.swift`（**断言**，E2） | `"hello".substring(1, 4) == "ell"` → 半开区间 `[start, end)` | **end** |
| `HIRNode.swift` 节点注释（E1） | `s.substring(start, length)` | **length** |
| `HIRLowerer.swift`（E1） | `let length = …; .stringSubstring(start:, length:)` | **length** |
| `IREmitter.swift`（E1） | `memcpy(buf, recv+start, length)`——复制 **length 个字节** | **length** |
| `HIRPrinter.swift`（E1） | 打印为 `substring(start, length)` | **length** |

**同一表达式在两通道的推算结果**（ASCII 输入，`s = "hello"`）：

| 调用 | 解释器（end 语义） | LLVM/HIR（length 语义） |
|---|---|---|
| `s.substring(0, 5)` | `hello` | `hello`（**巧合一致，start=0**） |
| `s.substring(1, 4)` | `ell` | `ello`（复制 4 字节） |
| `s.substring(2, 100)` | `llo`（夹紧） | **越界读** 100 字节（源仅 5 字节） |
| `s.substring(1, -1)` | `ell` | 空串（长度 −1 → 0） |
| `s.substring(3, 1)` | ``（空） | `l`（复制 1 字节） |

**E3 实测确认（2026-09-12，debug 构建 + 三通道）：**
`"hello".substring(1, 4)` → 解释器 **`ell`** / LLVM **`ello`** —— **分歧确认为用户可见**。
但 `substring(2, 100)` 两侧**输出一致**（均 `llo`）→ 见 §7.3 对「越界读」的订正。

**为何至今全绿 —— 双重覆盖盲区（这是本发现的核心）**：

1. **解释器侧测试只跑解释器**：`StdlibTests` 的 `runProgram` 直接
   `Interpreter()` + `interpreter.run(module:)`，**完全不经过 HIR/LLVM**。
   `testStringSubstring` 断言的是解释器行为，对 HIR 侧的语义分歧**无约束力**。
2. **差分测试的夹具恰好用 start = 0**：`HIRDifferentialTests/testDiffStdlib.pini` 与
   `examples/stdlib.pini` 都写作 `s.substring(0, 5)` —— 在 `start = 0` 时
   `length` 与 `end` 数值相同，**分歧被恒等掩盖**。

⇒ 这是一个**被语料覆盖结构性地遮蔽**的用户可见缺陷：只要用户写
`s.substring(1, 4)` 这类 start≠0 的调用，LLVM 通道就会给出与解释器不同的结果；
`length` 大于剩余长度时还会**读越界**（内存安全面）。

**与既有工单的关系**：`docs/issue-hir-string-slice-byte-based-2026-09-11.md` 已记录
「字节偏移当字符偏移用」的**同根因族**（切片路径），并留下一个**未回答的关键未知项**：

> 估工关键未知项：切片当前是否只走 HIR 侧自实现的字节路径，还是与 `substring`
> 共用同一段发射代码——共用的情形下改动面会同时覆盖两个 API。

**本批回答（E1）**：切片与 `substring` **不共用同一函数**（`sliceCall` → 切片 helper；
`stringSubstring` → `memcpy` 内联），但**共用同一根因**——两者都把「偏移」当字节用，
且都**缺少字符/字节语义的规范裁决**。若按该工单建议 2 统一到「字符」层，
**改动面必须同时覆盖 `substring`、切片、以及 `len`（已按字符）三条路径**。

> ⚠️ 本项**尚未执行实测**（E3 缺失）。推算结果出自 E1 代码阅读，虽证据链三方互证，
> 仍须按 §7 跑一次三通道确认后才可作为「用户可见」定论。

### 5.2 甲类三项真差异：逐项核实为真（E1，与计划一致）

| 项 | 发射侧实测 | 解释器侧实测 |
|---|---|---|
| `fileRead` | `alloca [65536 x i8]` + 单次 `fread(base,1,65536,h)` | `String(contentsOfFile:)` 读整文件、**无上限** |
| `fileWrite` | 返回 `fclose` 的 i32 | 返回 `.null` |
| `readLine` | `fgets(base, 256, stdin)` → **不剥换行** + 256 B 上限 | Swift `readLine()` → **剥换行** |

⇒ 计划 §5「真行为差异 3 项」**核实无误**。三项的成因也确认是「发射器为自身方便」
（`alloca` 尺寸、C 库语义），符合甲类定义。

### 5.3 计划判为「仅表述上提」的 6 项中，3 项实为真差异（E1 + **E3 已确认**）

计划把 `stringCase` / `stringSubstring` / `stringConcat` / `interpString` /
`isAsciiDigit` / `printMulti` 判为「差异在怎么实现，不在结果是什么」。逐项复核：

| 项 | 复核结论 |
|---|---|
| `stringSubstring` | ❌ **判错** —— 见 §5.1，参数语义不同，结果不同 |
| `stringCase` | ❌ **判错（实测确认差异）** —— 发射侧 `toupper` 逐字节（ASCII-only）；解释器 `uppercased()` Unicode 感知。实测 `"café".upper()`：解释器 `CAFÉ` vs LLVM **`CAFé`** |
| `stringConcat` | ✅ 成立 —— 两侧都是拼接，仅分配方式不同 |
| `interpString` | ✅ 成立（10 行 helper，纯组装） |
| `isAsciiDigit` | ✅ 成立（定义即 ASCII [0-9]，`ADR-019 D4`） |
| `printMulti` | ✅ 成立（多参打印的组装） |

**未列入甲类但同源**的两项，实测结论**一真一假**：

| 项 | 实测 | 结论 |
|---|---|---|
| `stringContains` | `"你好世界".contains("世界")` 与 `contains("好世")` **两侧均 `true/true` 一致** | ✅ **普通可写输入上不构成差异**（合法 UTF-8 的子串若对齐字素边界，字节查找与字素查找同解）。**但分解式 Unicode 下确有分歧**：接收者 `e` + U+0301、needle `e` → 解释器 `false` / LLVM **`true`**（见 §7.3 M8） |
| `stringSplit` | `"a,,b".split(",")` → 解释器 `[a, , b]`（3 段）/ LLVM **`[a, b]`（2 段）** | ❌ **实测真差异**，且 `len` 同步错（3 vs 2）。源码注释自述「corpus-identical」指的是**语料内**一致，不是语言面一致 |

### 5.3.1 【E3 新发现】`len(String)` 的「字符」定义两侧不同

`"e" + U+0301`（分解式，视觉上 `é`）实测：

| 通道 | `len(s)` | 定义 |
|---|---|---|
| 解释器 | **1** | **字素簇**（Swift `Character`） |
| HIR/LLVM | **2** | **码点**（UTF-8 解码后的 code point 数） |

对 ASCII 与 CJK（`你好世界` 两侧均 `4`）二者**恰好重合**，故此前不可见。
再加上 HIR 内部 `sliceCall` / `stringSubstring` 走的是**字节**，实际**三义并存**：

| 位置 | 偏移/长度单位 |
|---|---|
| 解释器（`len` / 切片 / 下沉下标） | **字素簇** |
| HIR `lenCall`（`emitStringCharCount`） | **码点** |
| HIR `sliceCall` / `stringSubstring` | **字节** |

> **⚠️ 订正（2026-09-12 复审，推翻本节初稿的根因结论）**
>
> 本节初稿写「**字符串「字符」的定义在语言层未裁决**……缺的是**语言层的字符模型裁决**」，
> 并据此把字符家族 5 项计入止损 6。**该结论错误，现予推翻。**
>
> **裁决早已存在**：`ADR-019 D1`（Accepted **2026-08-29**，
> `docs/spec/adr/adr-019-unicode-char-model.md`）钉定字符模型 = **Grapheme Cluster**，
> 并明文「**不采用 Unicode scalar 或 UTF-8 byte 模型**」；同文 D2 更已把
> 「真 `Char` 类型」立为远期 RFC。
>
> **正确的判据切分**：这是「**规范已裁决**（grapheme），而 HIR 侧的
> 码点 / 字节实现**偏离**了裁决」——按 §7.1 的判据表，属**实现缺陷，不计入止损 6**。
> 连带：初稿据此计入止损的字符家族各项须改判（见 §7.1 重算节）。
>
> **另一后果**：初稿曾推荐「以**码点**为统一基准」，**该方案已被 `ADR-019 D1` 明文排除**。
> 字符模型**不再有裁决余地**，后续工作转入 **`ADR-019 D2` 的第二阶段（引入 `Char` 类型）**，
> 草案见 `docs/spec/adr/adr-033-char-type.md`。
>
> **初稿出错的成因（留档）**：初稿只在**实现层**（`Interpreter` / `HIR` / `IREmitter`）
> 横向比对三义，**未回查规范层的既有裁决**——即「先看代码、后看规范」的顺序反了。
> 这与本仓既有教训同族：**同名搜索/单层取证会造出缺失与空白假结论**，
> 规范空白类结论必须先在 `docs/spec/adr/` 做阳性对照。

### 5.4 耦合面实测（E1，支撑 P4 边界）

| 面 | 实测 | 与计划对照 |
|---|---|---|
| CLI 构造点 | **6 处**（`main.swift` 809/856/966/985/1154/1194） | ✅ 一致 |
| REPL | `ReplSession.swift:92/102`，**每次求值新建 `Interpreter()`** | ✅ 一致 |
| DAP/Debugger | `private var interpreter: Interpreter?` + `outputSink` 重定向 + `debugHook` | ✅ 一致 |
| `SuspendEvaluator` | **890 行**，`extension Interpreter`，遍历 **AST**，121 处 `case .X` | ⚠️ **计划未载**（见 §6） |
| HIR 自述的「以解释器为准」 | `interpreter` 提及 HIRNode/Lowerer/Emitter = 23/36/38 次 | ✅ 印证计划 §2 |

### 5.5 【E1 新发现】`Char` 名称被 FFI 单字节占用，与 spec 冲突（P0c 登记）

`Char` **已作为类型名存在于代码中**，但其语义是 **C 的单字节 char**，而非 Unicode 字符：

| 位置 | 实测 | 语义 |
|---|---|---|
| `Sources/PiniCore/Type/TypeChecker.swift`（`isCScalarType`） | `"Char"` 被列为 **C 标量** | FFI 合法标量 |
| `Sources/PiniCore/Interpreter/Interpreter.swift`（指针 `load`） | `case "Char": return .int(Int(rp.pointer.load(as: UInt8.self)))` | **单字节读** |
| `Sources/PiniCore/Interpreter/Interpreter.swift`（指针 `store`） | `case "Char": … storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)` | **单字节写** |

而 `docs/spec/pini-spec-v0.md` 的 FFI 类型白名单明文：

> **`Char` 不进入 FFI 标量集**：C `char` 符号性由实现定义，字节缓冲统一用 `I8`/`U8`；
> `Char` 保留为**一般语言类型**，不出现在 FFI 签名。

⇒ **两处问题**：

1. **规范/实现漂移**：代码把 `Char` 当 C 标量（且是带符号性歧义的 `char`），规范明文排除 ——
   这是规范已裁、实现偏离，属**实现缺陷**（同 §7.1 的判据切分）。
2. **名称抢占（更关键）**：`ADR-019 D2` 拟引入的 `Char` 是 **grapheme 字符**，
   与现有的「FFI 单字节 `Char`」**同名两义**。若不清腾，字节语义会污染字符语义。

**处置**（用户裁决 2026-09-12）：FFI 的 `Char` **改名 `CChar`**，`Char` 之名腾给 grapheme 类型。
规范落点：`docs/spec/adr/adr-033-char-type.md` 的 D2（**Accepted 2026-09-12**）；
实施载体：**`docs/issue-ffi-char-rename-cchar-2026-09-12.md`**（**已立案 2026-09-12，未实施**）。

**实测影响面（立案时全仓检索，2026-09-12）**：**共 3 处代码 + 1 处注释；零语料、零测试**
—— `Sources/` 内 `\bChar\b` 仅 4 处（`TypeChecker.swift` ×2 含 1 注释 /
`Interpreter.swift` ×2）；`examples/**` 与 `Tests/**` 内 `*Char` / `: Char` / `-> Char` **零命中**。
⇒ **改名零回归**，且暴露一个**覆盖缺口**：该类型「有类型检查器支持、零语料覆盖」
（与「能力矩阵语料数 59 vs 实测 78」同族）。
另登记：**CodeGen 侧无 `Char` 处理**（`Sources/PiniCore/CodeGen/` 内 `\bChar\b` 零命中）
⇒ LLVM 侧行为未验证，**须设计探针再判定，不预设结论**（「没搜到」≠「没实现」）。

---

## 6. 范围边界冲突（**已裁 R2**，2026-09-12）

计划同时写着两条，而它们**不能同时成立**：

- §10 不做范围：**「并发 / CPS 不做」**（依据：`D-B4` 裁决与 `LR-13`）
- §7 P4：**「删除 AST 走查」**（`D-B3=A` 末态退役）

**冲突点（E1 实测）**：`SuspendEvaluator.swift`（890 行）是 `extension Interpreter`，
**整体建立在 AST 走查之上**（`containsJoin` 遍历 AST、`evalK` 按 AST 节点做 CPS 组合、
`callUserFunctionK` 以 CPS 执行函数体）。承载 `await` / `wait` 的用户可见能力。

⇒ 若 P4 删除 AST 走查，则 `await`/`wait` **必须**要么（a）随之一并退役、
要么（b）在 HIR 引擎上另行实现 CPS。**没有第三条路**（`D-B3` 已排除「冻结走查当第二前端」，
理由是会腐烂）。三条候选路线：

| 路线 | 内容 | 代价 |
|---|---|---|
| **R1 随走查一并退役** | 承认并发/CPS 从语言面撤出 | 用户可见能力移除，须走 spec §1.3 + ADR；与「不做」的差别是「不做」不等于「删掉」 |
| **R2 单独留下一格迁移** | P2 增一格「CPS/HIR 挂起求值」，把 `evalK` 的续体模型重建在 HIR 上 | 多一格工期；HIR 节点面需携带挂起点（`join`）信息 |
| **R3 维持双引擎** | AST 走查保留为「并发专用引擎」 | 与 `D-B3=A` 末态退役的裁决**直接冲突**，且双引擎长期并存 |

**已裁 `R2`（2026-09-12，用户裁决；登记见计划 §13）**：单独留一格把 CPS 迁到 HIR
（保住用户可见能力 + 满足单一引擎，同时不违反 `D-B3=A` 的末态退役）。
**副产物约束**：`HIRLowerer` 须为 `.join` 增加节点面 ⇒ **P0b 的节点语义须预留挂起语义**
（否则 P0b 定稿的节点清单会在 P2 的 CPS 格被打破）。代价：多一格工期。

---

## 7. 止损判定与 E3 实测（**P0 未完成面已清零**）

### 7.1 止损 6 压力重新计算

止损 6 = 「§5 裁决表 **>3 项需改用户可见行为**且无迁移窗口 → 停」。

**先做一处判据切分（否则会误判止损）**：「发现差异」不等于「需要改用户可见行为」。

| 差异的两种性质 | 处置 | 是否计入止损 6 |
|---|---|---|
| **规范未裁决**，两侧各按自己方便实现 → 要统一就必须**为语言定新语义** | 走甲类逐项裁决 + spec §1.3 | **计入**（这才是「改用户可见行为」） |
| **规范已裁决**（注册表/测试已表态），某侧实现偏离 | 属**实现缺陷**，修实现对齐规范 | **不计入**（是修 bug，不是改规范） |

按此切分重算：

| 口径 | 计入止损的真差异 | 触发？ |
|---|---|---|
| 计划原判 | 3（`readLine` / `readFile` / `writeFile`）——均属「规范未裁决」 | 否（恰在门槛内） |
| 本轮初稿（**判据错误，已推翻**） | 曾把字符家族 5 项计入，得 7 项 | ~~是~~ → 见下 |
| **本轮复审（现行口径）** | `readLine` / `fileRead` / `writeFile` / `stringSplit`（空 token 取舍）= **4** | **是（4 > 3）** |
| `stringSubstring` | **不计入** —— 注册表已定 `["start","end"]`、测试已断言 `[start,end)` ⇒ 规范**已裁决**，HIR 侧是偏离方 | 否 |
| `stringCase` / `len` / `contains` | **不计入** —— `ADR-019 D1` 已钉 grapheme 且要求「与宿主一致」，HIR 侧的码点/字节属**偏离** | 否 |

⇒ **结论（2026-09-12 复审重算后定论）**：

1. **判据订正**：初稿计入止损的字符家族 5 项中，**4 项改判为实现缺陷**。
   `ADR-019 D1`（Accepted 2026-08-29）早已钉定 grapheme 模型，故
   `stringCase` / `len` / `contains` 的差异是**实现偏离**，`stringSubstring` 亦然
   （注册表与测试已裁 `(start, end)`）。这可参见 §5.3.1 的订正块。
2. **止损 6 仍触发，但压力从 7 项降到 4 项。** 真正「规范未裁决、需改用户可见行为」的项为：

| # | 项 | 实测（§7.3） | 性质 |
|---|---|---|---|
| 1 | `readLine` | 剥换行 vs 不剥 + 256 B 上限 | IO 语义未裁 |
| 2 | `fileRead` | 无上限 vs 64 KiB | IO 语义未裁 |
| 3 | `fileWrite` | `.null` vs `fclose` i32 | IO 语义未裁 |
| 4 | `stringSplit`（空 token 取舍） | 保留空段 vs 跳过（3 段 vs 2 段） | 分隔符语义未裁 |

   合计 **4 项 > 3** → 仍按计划 §9「说明兼容面超出本项承载，应**拆项**」处置。
3. **拆项方案（据复审更新）**：
   - **IO 语义**拆为一格（第 1–3 项，同族）；
   - **`stringSplit` 空 token 取舍**：量小，随 IO 格或单列皆可；
   - **String 文本模型**：**不再需要「裁决」**（`ADR-019 D1` 已裁 grapheme），
     改为**实现对齐**；其规范产出 = `docs/spec/adr/adr-033-char-type.md`（Char 类型引入，草案）。
     这是本批最重要的一处**性质变化**：从「立新规范」变成「补实现缺口」。

> ⚠️ **止损的读法**：止损 6 触发**不等于**本项要停 —— 它的处置是「拆项」，
> 而拆项正是 P0 的产出。真正会被止损拦住的是「把 4 项塞进一批逐项裁决」。
>
> ⚠️ **本轮订正的教训**：止损判定的分母**完全取决于判据切分是否准确**。
> 初稿未回查规范层，把 4 项实现缺陷误计为裁决负担，虚增了 3 项压力（7 项 vs 真实的 4 项）。
> **判据切分必须先于止损计算**——顺序颠倒会得出错误的「压力更高」结论。

### 7.2 P0 实测项（**已执行**，见 §7.3）

| # | 待实测项 | 目的 | 判据 |
|---|---|---|---|
| M1 | `s.substring(1, 4)` 三通道 | 确认 §5.1 是否用户可见 | 解释器 `ell` vs HIR 是否 `ello` |
| M2 | `s.substring(2, 100)` | 确认越界读行为 | 崩溃 / 垃圾输出 / 恰好夹紧 |
| M3 | `"café".upper()` 两通道 | 确认 §5.3 `stringCase` 是否真差异 | 是否 `CAFÉ` vs `CAFé` |
| M4 | `"你好世界".substring(0, 2)` | 与切片同根因的再确认 | 字符 vs 字节 |
| M5 | `"a,,b".split(",")` 两通道 | 确认 `strtok` 跳空 token | 3 段 vs 2 段 |

**执行情况**：已按授权做一次 debug 全量构建（**8.2s**，机器较快；产物
`/tmp/pini-build/debug/{pini, libPiniRuntime.dylib}` 时间戳与本次一致），
跑完 M1–M5 并**追加 M6–M8 三项**（同一构建内，零额外成本）。

---

### 7.3 E3 实测记录（2026-09-12，debug 构建 + 两实通道）

命令：`pini run <fixture>`（解释器 AST 走查）vs `pini run-llvm <fixture>`（HIR → LLVM）。
**只比 stdout**（stderr 单独记录，见 §7.4 观察）；夹具在 `/tmp/p0/fx/`（不入仓）。

| # | 夹具 | 解释器 stdout | LLVM stdout | 判定 |
|---|---|---|---|---|
| **M0** | `substring(0, 5)` on `"hello"` | `hello` | `hello` | ✅ **一致**（对照项） |
| **M1** | `substring(1, 4)` on `"hello"` | `ell` | **`ello`** | ❌ **不一致——确认** |
| **M2** | `substring(2, 100)` on `"hello"` | `llo` + `END` | `llo` + `END` | ✅ 输出一致（**但见下**） |
| **M3** | `"café".upper()` / `.lower()` | `CAFÉ` / `café` | **`CAFé`** / `café` | ❌ **不一致——确认** |
| **M4** | `"你好世界"` → `substring(0,2)` / `s[1:3]` / `len` | `你好` / `好世` / `4` | **乱码** / **乱码** / `4` | ❌ **不一致——确认** |
| **M5** | `"a,,b".split(",")` | `[a, , b]` / `3` | **`[a, b]` / `2`** | ❌ **不一致——确认** |
| **M6** | `"你好世界".contains("世界")` / `("好世")` | `true` / `true` | `true` / `true` | ✅ 一致 |
| **M7** | `"hello"[1:3]` / `len` | `el` / `5` | `el` / `5` | ✅ 一致（ASCII 对照） |
| **M8** | `("e"+U+0301).contains("e")` / `len` | **`false`** / **`1`** | **`true`** / **`2`** | ❌ **不一致——确认（新）** |

**M0 的意义**：它验证了 §5.1 的「覆盖盲区」推断 —— **分歧恰在 start≠0 时出现**，
而 `start = 0` 时两义数值重合，所以既有夹具与既有测试全绿。

**对 §5.1 的一处自我订正（如实入账）**：我在审计初稿里推算
`substring(2, 100)` 会**越界读**并产出垃圾。**实测推翻了这个推算** —— 两侧输出一致
（`llo`）。原因是 `print` 按 C 串打印，在首个 NUL 处停止，掩盖了多余拷贝。
⇒ 但**代码面证据不变**（`memcpy` 的长度未夹紧到 `len - start`），
所以「M2 一致」**不能**读成「HIR 的 substring 是安全的」——
它只说明**这一形态的输出**看不出问题。**是否真有越界读，须另设计可观测探针**
（本批不做，已登记为遗留问题）。这是「不要用推算当实测」的又一个实例。

### 7.4 顺带观察（未追，仅登记）

1. **解释器对「仅经成员调用使用」的变量误报未使用警告**：M0/M1/M2/M3/M5 均报
   `Warning: 语义警告 [E7-001] 未使用的变量 's'`（而 `s` 确实被用了），
   M4/M6/M7（含 `len(s)` 或 `s[...]` 形态）**不报** → 疑为「成员调用接收者未被计为使用」。
   属诊断质量（假阳性警告），**与 HIR 无关**，未追。
2. **D19 再验证**：解释器把语义警告写 stderr，LLVM 通道**完全静默**（本次各夹具一致复现）。
   既有工单 `docs/issue-diagnostic-channel-parity-2026-09-12.md` 已覆盖，无需新立。
3. **无进程泄漏**：跑后无残留 `lli` / `pini` 进程，无残留 `.ll`。

### 7.5 工单动作（P0 + P0c + 收口，累计）

按「立案前先查同题工单」的纪律**不新立重复件**；全部动作为**只登记、不修复**。

| # | 动作 | 工单 | 说明 |
|---|---|---|---|
| 1 | **并入**（P0） | `docs/issue-hir-string-slice-byte-based-2026-09-11.md` | 本批把证据并入既有同根因族工单，并在其中**回答该工单遗留的关键未知项**（切片与 `substring` 是否共用发射代码）。工单标题所限的「切片」范围已不足以承载实测结论（实际是 `len` / 切片 / `substring` / `contains` / `split` 五处），故**扩写范围与证据而不改文件名**（改名会破坏入向引用） |
| 2 | **维护**（P0c） | 同上 | 订正被推翻的根因结论、移除「待语言层裁决」前置 |
| 3 | **新建**（P0c） | `docs/issue-ffi-char-rename-cchar-2026-09-12.md` | P0d 前置（`Char` 腾名） |
| 4 | **新建**（收口，2026-09-12） | `docs/issue-e7-001-false-unused-warning-2026-09-12.md` | §7.4 观察 1 —— **本批立案，仍不修** |
| 5 | **无需新立** | `docs/issue-diagnostic-channel-parity-2026-09-12.md` | §7.4 观察 2 已被该工单覆盖 |

**未实施任何缺陷修复** —— 按「制定计划 → 完成计划 → 记下缺陷 → 提出工单 → 维护/删除工单」的
循环推进，不把缺陷修复塞进本批。

## 8. 停止点

- **未改任何源码**（含测试与夹具）；本批产出 = 本审计文件 + 对既有工单的证据合并（§7.5）。
- 台账与探针脚本、夹具均置于 `/tmp/p0/`（`extract_nodes.py` / `locate.py` / `map2.py` /
  `helpers.py` / `ledger.py` / `bk.py` / `probe.py` / `probe2.py` / `fx/*.pini`），
  **均不入仓**（一次性审计工具；夹具形态已在 §7.3 表内以文字完整记录，可重建）。
- **构建产物**：`/tmp/pini-build/debug/`（本次重建，08:24–08:25），可复用至下次 `/tmp` 清理。
- **三项待点名事项的裁决结果（2026-09-12）**：
  1. **§7.1 拆项方案 → 判据已订正**：字符家族**不需要裁决**（`ADR-019 D1` 已裁 grapheme），
     改判为实现缺陷；甲类裁决表收窄到 **4 项**（3 项 IO 语义 + `stringSplit` 空 token 取舍）。
     规范产出载体 = `docs/spec/adr/adr-033-char-type.md`（Char 类型引入，**Accepted 2026-09-12**）。
  2. **§6 CPS / AST 走查路线 → `R2`**（用户裁决：单独留一格把 CPS 迁到 HIR）。
     ⇒ `HIRLowerer` 须为 `.join` 增加节点面，**P0b 的节点语义须预留挂起语义**。
  3. 之后进 **P0b**（HIR 规范 ADR + 节点语义 + 裁决落地）。
- **P0c 产出（2026-09-12，提交 `9234a9b`）**：本文件的 §5.3.1 / §5.5 / §7.1 订正
  + `adr-033` 草案；**未改任何源码**。
- **`ADR-033` 裁决落地（2026-09-12）**：三项已裁（表示 = **方案 A** / 字面量 **拆格** /
  转 **`Accepted`**）⇒ 本文件 §6 与 §5.5 的状态行已同步；`ADR-019` 的 D1 边界与 D2 状态已回填。
- **本批工单动作（「记下缺陷」而非「连续修复」）**：
  ① **新建** `docs/issue-ffi-char-rename-cchar-2026-09-12.md`（P0d 前置；实测零语料零测试）；
  ② **维护** `docs/issue-hir-string-slice-byte-based-2026-09-11.md`
  （订正根因结论、移除「待语言层裁决」前置、登记 `ADR-019 D1` 为权威依据）。
  **未实施任何缺陷修复** —— 按「制定计划 → 完成计划 → 记下缺陷 → 提出工单 → 维护/删除工单」的
  循环推进，不把缺陷修复塞进本批。
- **P0 收口（2026-09-12）**：本格内容产出已全部达成，无实质缺口（见 §7.2 / §7.3）。
  收口动作 = 清过期标注 + 遗留缺陷立案 + 状态回填；**仍未改任何源码**。
- 未合 main、未 push。

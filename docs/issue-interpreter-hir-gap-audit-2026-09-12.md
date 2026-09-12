# P0 审计：解释器统一 HIR 的枢纽缺口台账

- 状态：**Open（P0 批产出；只读审计 + 一次 debug 构建的三通道实测；未改任何源码）**
- 关联：`docs/issue-interpreter-hir-plan-2026-09-12.md`（常驻计划载体，P0 一格）；
  `docs/issue-interpreter-hir-unification-2026-09-07.md`（立案背景）；
  `docs/issue-hir-string-slice-byte-based-2026-09-11.md`（同根因族工单，本批回答其遗留未知项）
- 基线：main `361ec2c`，分支 `agent/pini-dev/hir-hub-p0`
- 台账口径：**行号为 2026-09-12 实测快照**；实现改动后一律改用符号检索重新定位，勿复用行号

---

## 1. 审计方法与证据分级

本轮**未构建、未跑执行**（`/tmp/pini-build` 已被系统清理，仓内 `.build` 为 09-07 陈旧副本）。
故证据分三级，台账逐项标注来源，**不用低级证据冒充高级证据**：

| 级 | 类型 | 说明 |
|---|---|---|
| **E1** | 代码结构证据 | 读源码得出的实现形态（本批主体） |
| **E2** | 注册表 / 测试期望证据 | `BuiltinRegistry` 的声明、既有测试的断言（权威度高于实现自述） |
| **E3** | 执行实测证据 | 跑三通道拿到的实际输出 —— **本批未取得**，见 §7 |

判据纪律：E1/E2 冲突时以 **E2 为准**（注册表与测试表达语言意图，实现只是其中一种落地）。
本批有三处正是 E1 与 E2 冲突（§5）。

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

### 5.1 【新缺陷候选】`String.substring` 两通道参数语义不一致

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

### 5.3 计划判为「仅表述上提」的 6 项中，至少 3 项存疑（E1，待 E3）

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
⇒ **字符串「字符」的定义在语言层未裁决，而两侧各取一义**；再加上 HIR 内部
`sliceCall` / `stringSubstring` 走的是**字节**，实际**三义并存**：

| 位置 | 偏移/长度单位 |
|---|---|
| 解释器（`len` / 切片 / 下沉下标） | **字素簇** |
| HIR `lenCall`（`emitStringCharCount`） | **码点** |
| HIR `sliceCall` / `stringSubstring` | **字节** |

这是「String 家族」问题簇的**真正根因**：缺的不是某一处对齐，而是**语言层的字符模型裁决**。

### 5.4 耦合面实测（E1，支撑 P4 边界）

| 面 | 实测 | 与计划对照 |
|---|---|---|
| CLI 构造点 | **6 处**（`main.swift` 809/856/966/985/1154/1194） | ✅ 一致 |
| REPL | `ReplSession.swift:92/102`，**每次求值新建 `Interpreter()`** | ✅ 一致 |
| DAP/Debugger | `private var interpreter: Interpreter?` + `outputSink` 重定向 + `debugHook` | ✅ 一致 |
| `SuspendEvaluator` | **890 行**，`extension Interpreter`，遍历 **AST**，121 处 `case .X` | ⚠️ **计划未载**（见 §6） |
| HIR 自述的「以解释器为准」 | `interpreter` 提及 HIRNode/Lowerer/Emitter = 23/36/38 次 | ✅ 印证计划 §2 |

---

## 6. 范围边界冲突（P4 前必须裁决）

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

**本批不裁决**，仅登记为 P0 产出。倾向 R2（保住用户可见能力 + 满足单一引擎），
但代价是多一格工期，且 `HIRLowerer` 需为 `.join` 增加节点面 —— **须用户定夺**。

---

## 7. 止损判定与 P0 未完成面

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
| 本轮 E1 新增（**规范未裁决**，待 E3 确认） | + `stringCase`（ASCII vs Unicode 大小写）+ `stringContains`（字节 vs 字符匹配）+ `stringSplit`（空 token 取舍）= 最多 **6** | **是（若 E3 确认）** |
| `stringSubstring` | **不计入** —— 注册表已定 `["start","end"]`、测试已断言 `[start,end)` ⇒ 规范**已裁决**，HIR 侧是偏离方 | 否 |

⇒ **结论（E3 实测后定论）**：

1. `stringSubstring` 的 `(start, length)` 属**实现缺陷**（注册表与测试已裁决为 `(start, end)`），
   不占用止损额度 —— 它比甲类项**更紧急**（是 bug），但**不改变甲类的裁决负担**。
2. **止损 6 已触发 —— 实测确认。** 甲类中「规范未裁决、需改用户可见行为」的项实测为：

| # | 项 | 实测（§7.3） | 需改用户可见行为？ |
|---|---|---|---|
| 1 | `readLine` | 剥换行 vs 不剥 + 256 B 上限 | 是 |
| 2 | `fileRead` | 无上限 vs 64 KiB | 是 |
| 3 | `fileWrite` | `.null` vs `fclose` i32 | 是 |
| 4 | `stringCase` | `CAFÉ` vs `CAFé` | 是 |
| 5 | `stringSplit` | 保留空段 vs 跳过（3 段 vs 2 段） | 是 |
| 6 | `len` 的字符定义 | 字素簇 vs 码点 | 是 |
| 7 | `contains`（分解式 Unicode） | `false` vs `true` | 是（窄） |

   合计 **7 项 > 3** → 按计划 §9「说明兼容面超出本项承载，应**拆项**」处置。
3. **建议的拆项（不是「逐项修」，是先立规范再对齐）**：把 **String 文本模型**整体拆为
   独立一格 —— 其内容是**一个语言层裁决**（Pini 的「字符」是字素簇、码点、还是字节？），
   裁决落定后 `len` / 切片 / `substring` / `contains` / `split` / `case` 六处的对齐
   都是**该裁决的实现落地**。这样甲类裁决表回到 3 项（第 1–3 项，均属 IO 语义）。
   落点：与既有工单 `issue-hir-string-slice-byte-based-2026-09-11.md` 合并（见 §7.4）。

> ⚠️ **止损的读法**：止损 6 触发**不等于**本项要停 —— 它的处置是「拆项」，
> 而拆项正是 P0 的产出。真正会被止损拦住的是「把 7 项塞进一批逐项裁决」。

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

## 8. 停止点

- **未改任何源码**（含测试与夹具）；本批产出 = 本审计文件 + 对既有工单的证据合并（§7.5）。
- 台账与探针脚本、夹具均置于 `/tmp/p0/`（`extract_nodes.py` / `locate.py` / `map2.py` /
  `helpers.py` / `ledger.py` / `bk.py` / `probe.py` / `probe2.py` / `fx/*.pini`），
  **均不入仓**（一次性审计工具；夹具形态已在 §7.3 表内以文字完整记录，可重建）。
- **构建产物**：`/tmp/pini-build/debug/`（本次重建，08:24–08:25），可复用至下次 `/tmp` 清理。
- **下一步待点名**：
  1. **§7.1 拆项方案** —— 是否把「String 文本模型」整体拆为独立一格（前置 = 语言层
     字符模型裁决），并把甲类裁决表收窄到 3 项 IO 语义；
  2. **§6 的 CPS / AST 走查路线**（R1 退役 / **R2 留一格迁到 HIR（我倾向）** / R3 双引擎）；
  3. 之后进 **P0b**（HIR 规范 ADR + 节点语义 + 裁决落地）。
- 未合 main、未 push。

### 7.5 与既有工单的关系（本批的工单动作）

按「立案前先查同题工单」的纪律，**不新立重复件**：本批把证据**并入**既有
`docs/issue-hir-string-slice-byte-based-2026-09-11.md`（同根因族），并在其中
**回答该工单遗留的关键未知项**（切片与 `substring` 是否共用发射代码）。
工单标题所限的「切片」范围已不足以承载实测结论（实际是 `len` / 切片 / `substring` /
`contains` / `split` 五处），故在该工单内**扩写范围与证据**而不改文件名
（改名会破坏入向引用）。

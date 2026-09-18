# HIR 节点语义契约（HIR Node Semantic Contract）

- 性质：**宿主级规范**。HIR 节点语义的**唯一权威载体**。
- 依据：`docs/spec/adr/adr-034-hir-contract.md`（ADR-034，Accepted 2026-09-12）。
- 版本：v1（2026-09-12，随 P0b 首次落地）。
- 变更：走 `pini-spec-v0.md` §1.3 五步治理；条目一经落地**不得随实现漂移**（ADR-034 D5）。

## 0. 定位与判读规则

### 0.1 权威次序（ADR-034 D1）

1. **语言面语义**（用户可见行为）以 `pini-spec-v0.md` 为准 —— 本契约**不得与之冲突**；
2. **HIR 节点语义**（后端间契约）以**本契约**为准；
3. 各后端实现（解释器 / LLVM / 未来 WASM）**与本契约一致**；**任一后端都不是定义处**。

### 0.2 本契约的表述纪律（强制）

- **语义列**只写后端无关的行为约定。**不得**出现 `bk_*`、`alloca`、`fgets`、`strtok`、
  `memcpy`、GEP、refcount 布局、fat pointer 形状等实现细节；
- 实现细节只能出现在**「LLVM 侧实现注记」**列，且其地位是「一种实现」，不是语义；
- **禁止**以 `bk_*` 行为定义语义 —— 否则等于把某一后端的实现选择升格为全体后端的义务
  （ADR-034 D1、WASM 约束）。

> **反例（本契约立此存照）**：`HIRNode.swift` 原注释写 `fileRead`「fread into a 64 KiB
> stack buffer」——把缓冲尺寸写成了节点语义。本契约的表述为「读取整文件内容；上限见
> §2.8 注记」，尺寸降为实现注记。

### 0.3 三方对照核验（P1 脚本化的对象）

```
本契约条目  ↔  HIRNode.swift 的节点集  ↔  各后端实现锚点
```

核验须能双向报缺口：**有节点无契约条目** / **有契约条目无实现锚点**（计划 §8 第 2 层判据）。

### 0.4 计数基线

**45 表达式节点 + 17 语句节点 = 62**（2026-09-12 逐个复核为 **60**；2026-09-17 **两次**增量：
① 新增 `join` 一条，走 `§1.3` / `ADR-040` ⇒ 表达式 44 → 45、合计 60 → 61；
② 新增 `detachStmt` 一条，走 `§1.3` / `ADR-042` ⇒ 语句 16 → 17、合计 61 → 62）。

> ⚠️ **两条增量的性质不同，不要当成同一件事读**：`join`（①）是**兑现一个已登记的预留位**
> （旧 §4.2 早已裁「须增加节点面」）；`detachStmt`（②）**不是** —— 它**从来没有预留位**
> （§4 预留位当时只剩 `char` 一条），是 2026-09-17 **用户新裁**「`detach` 要新节点」（`D-G3c-1`）。
> ⇒ 后者是**新增契约条目**，不是**实施既定条目**；这个区别决定了它必须先走 `§1.3` 再动代码。

> **首轮核验订正（2026-09-12，P1-1 前哨）**：首次机械对照（本契约 ↔ `HIRNode.swift` 节点集）
> 报出三处缺陷，已当场订正：
> ① **漏 `printMulti` 条目** —— 代码 44 个 `HIRExpr` case 含它，契约只列 43 条；
> ② **两条语句位指针（`tryStmt` / `matchStmt`）占用了表达式条目号** —— 致 §2 实列 45 行
>    与「44 条」声明不符；已移出编号，改为节内指针注记；
> ③ **引用静默位错** —— `pointerLoad` 的半语义引用原写作旧条目号 26，而该节点的旧条目号
>    实为 30（§6 汇总表自身写的就是 30，同一文件内两说）。
>
> 订正后条目号重排为 **1–44 连续无缺口**，节内引用随之更新：半语义两项现为 17 与 29、
> `addressOfVar` 为 31、B 组六项为 22/23/36/37/38/40（⚠️ 「六项」为 2026-09-12 当时口径；**`§2.40` 已于 2026-09-15 移出 B 组**，现行 B 组为 **5 项**，见 §2.40 与 §6）。**本条为订正记载，非新规范内容。**

## 1. 类型层（HIRType，20 case）

| 类型 | 语义（后端无关） | LLVM 侧实现注记 |
|---|---|---|
| `i32` / `i64` | 32 / 64 位有符号整数 | `i32` / `i64` |
| `u64` / `u8` | 64 / 8 位无符号整数 | 与 `i64` / `i8` 同拼写，符号性由运算承载 |
| `i8` | 8 位有符号整数 | `i8`；算术在发射期拓宽到 `i32` |
| `f64` | 64 位 IEEE-754 浮点 | `double` |
| `boolean` | 布尔 | `i1` |
| `string` | 字节串值 | `i8*` |
| `char` | **一个字素簇**（extended grapheme cluster，用户感知的「一个字符」）—— **不是**码点、**不是**字节；表示**与 `string` 同构**（`ADR-033 D1` 方案 A），「恰含 1 个字素」的不变式**由类型系统承担**、表示层不设防 | `i8*`（与 `string` 同拼写；**零新 ABI**） |
| `result(ok:)` | `Result<ok, E>`；**错误槽类型擦除** | `{ i64, ok, i64 }` — 三槽是**布局约定** |
| `array(element:)` | 有序、可重复、值语义集合 | 不透明句柄（`%bk_array*`） |
| `optional(wrapped:)` | 有/无二态容器 | `{ i64, T }` 带 tag（**tag 取值是布局约定**） |
| `nominal(name:isObject:)` | 用户具名类型；`isObject=true` 为**引用语义**、`false` 为**值语义** | `%object.*` / `%struct.*`；**refcount 头是实现** |
| `enumeration(name:)` | 用户枚举（带关联值的 tagged union） | `%enum.*`；**tag 位置与槽宽是实现** |
| `dict(key:value:)` | 键到值的映射；**键唯一** | 不透明句柄（`%bk_dict*`） |
| `set(element:)` | 唯一元素集合 | 不透明句柄（`%bk_set*`） |
| `lazyRef(element:)` | **一次求值**、共享（引用）拷贝语义的惰性引用 | 不透明句柄（`%bk_lazyref*`） |
| `tuple(labels:fieldTypes:)` | 带位置与可选标签的异质定长组 | 聚合值；**按标签序取成员** |
| `function(params:returnType:)` | 函数是一等值 | fat pointer `{ptr, ptr}`；**首参恒为 env 是调用协议** |
| `pointer(element:)` | `*T` 原始指针（FFI） | 不透明 `ptr`；**load/store 按元素类型解码**（半语义，见 §2.29） |

> **乙类纪律**（ADR-034 D3 E 组）：上表「布局约定」字样者为**后端约定**，WASM 端可另择
> 表示；标「语义」者为**必须实现的行为**。半语义两项见 §2.17（`optionalGet` 的 panic 面）
> 与 §2.29（`pointerLoad` 的符号扩展）。

## 2. 表达式节点（44 条）

> 每条的「语义」列为**规范表述**；「注记」列记差异、偏离与待办。

### 2.1 标量常量

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 1 | `intConst(value:type:)` | 整数字面量，类型由 `type` 给定 | — |
| 2 | `floatConst(value:)` | 浮点字面量（`F64`） | — |
| 3 | `boolConst(value:)` | 布尔字面量 | — |
| 4 | `stringConst(value:)` | 字符串字面量（字节串） | — |

### 2.2 变量与运算

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 5 | `load(name:type:)` | 读变量当前值；`type` 为变量**声明类型** | 不改变变量状态 |
| 6 | `binary(op:lhs:rhs:type:)` | 二元运算：算术 / 比较 / 逻辑 / 位运算（`HIRBinaryOp`）；关系运算结果为 `boolean` | 运算语义**由语言定义**，不由后端指令集定义 |
| 7 | `unary(op:operand:type:)` | 一元运算：`negate` / `logicalNot` / `abs` | `abs` 为选择式取绝对值 |

### 2.3 调用

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 8 | `call(function:arguments:returnType:)` | 调用**模块级**具名函数；`returnType=nil` 表示返回空 | 实参求值序与错误传播同语言定义 |
| 9 | `printCall(argument:)` | 内建 `print`：单标量实参，**逐字展示后随一个行终止符**，结果为空 | 值展示规则见 `pini-spec-v0.md` §2.8（**含 F64 最短往返**） |
| 10 | `printMulti(arguments:)` | 内建 `print` 多参形式：**逐参展示，以单个空格连接，末尾一个行终止符**，结果为空 | ✅ C 组：两侧字节序一致（G14 D-A=A1）；「以空格连接」是语义，拼接方式是实现 |
| 11 | `indirectCall(callee:arguments:returnType:)` | 经函数值间接调用；`callee` 为闭包 / 具名函数值 / 函数类型变量 | **调用协议**（env 首参）是约定；「函数是一等值」是语义 |
| 12 | `functionValue(functionName:type:)` | 具名顶层函数作为值使用 | 与 `closureLiteral` **共用调用协议** |
| 13 | `closureLiteral(id:paramNames:paramTypes:returnType:captures:body:type:)` | 闭包值：体 + **创建点捕获表**；捕获为**引用捕获**（与环境槽共享） | `captures` 按体内首次使用排序；未标注参数走返回标注回退（G29） |
| 14 | `assertCall(condition:message:)` | 断言：条件为假 → **运行时陷阱**并带消息 | 仅 `\|test` 块使用；差分夹具从不执行 |

### 2.4 Result 与 Optional

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 15 | `resultConstruct(isOk:payload:type:)` | `ok(v)` / `err(e)` 构造；**错误载荷类型擦除为一个机器字** | 擦除是 ABI 约定；「错误可为任意类型」是语言语义 |
| 16 | `optionalConstruct(isSome:payload:type:)` | `Optional` 构造：`isSome=false` 为 `none`（语言级 nil）；`true` 携带载荷 | 切片语法开放边界到达时为 `none` |
| 17 | `optionalGet(container:index:type:)` | **宽容读通道** `container.get(i)`：越界 → `none`；界内 → `some(v)` | ⚠️ **半语义**：越界返回 `none` 是语义；边界检查方式是约定（E 组，ADR-034 D3） |
> **语句位指针（不占编号）**：`tryStmt` 见 §3.9。

### 2.5 集合

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 18 | `arrayLiteral(elements:type:)` | 数组字面量，**元素保序** | — |
| 19 | `dictLiteral(entries:type:)` | 字典字面量，键值对预降级 | — |
| 20 | `setLiteral(elements:type:)` | 集合字面量，**元素唯一** | — |
| 21 | `subscriptGet(container:index:type:)` | **安全断言读** `c[i]`：越界（读）→ panic（`E5-005`） | 负索引尾部计数；三通道语义见 ADR-028 |
| 22 | `lenCall(argument:)` | 容器长度 | ⚠️ **B 组缺陷**：`String` 的「字符」定义两侧不同（契约 = **字素簇**，`ADR-019 D1`；LLVM 侧现为码点，**偏离**） |
| 23 | `sliceCall(container:start:end:type:)` | 切片：**负界尾部计数**，夹到 `[0, len]`，`hi < lo` 得空 | ⚠️ **B 组缺陷**：`String` 切片契约 = 字素簇；LLVM 侧现为**字节**，偏离 |
| 24 | `tupleConstruct(labels:elements:type:)` | 带标签元组构造 | — |
| 25 | `tupleIndexGet(base:index:type:)` | 元组成员读，按**字段序** | — |

### 2.6 具名类型与枚举

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 26 | `construct(type:)` | 具名类型构造；字段取**声明默认值**（无默认则零值）；对象类型的**对象同一性**（引用语义） | refcount 初值是实现 |
| 27 | `enumConstruct(enumName:caseName:tag:payloads:payloadTypes:type:)` | 枚举 case 构造；`tag` = case **声明序索引** | 载荷按值存入 tagged union |
| 28 | `fieldGet(base:field:type:)` | 具名字段读 | 按**声明序**取字段；布局是约定 |
> **语句位指针（不占编号）**：`matchStmt` 见 §3.14。

### 2.7 指针与取址

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 29 | `pointerLoad(pointer:type:)` | 经 `*T` 读元素值；**按元素类型解码** | ⚠️ **半语义**：解码是语义；`*U8` 的**符号扩展规则**须上提或标注为约定（E 组） |
| 30 | `pointerStore(pointer:value:type:)` | 经 `*T` 写值，按元素类型编码 | 窄元素为**截断写**（与解释器一致） |
| 31 | `addressOfVar(name:type:)` | `&x` —— 变量**存储槽的地址**（**真指针**语义） | ✅ **A/D1 裁决：统一到本方（真引用）**。解释器现为快照，属**偏离**，须修 |

### 2.8 IO（G15/G17）

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 32 | `fileWrite(path:content:)` | 写文件；返回**写操作的整型结果码** | ✅ **A3 裁决：统一到本方**（返回整型码）。**已对齐**（2026-09-14，IO 语义格）：解释器返回值由 `null` 改为结果码（成功 `0`），单点登记表同步由 void 改整型。**HIR 侧已实现**（2026-09-14，G9）。⚠️ 裸整型码泄入语言层已立案（见注记末） |
| 33 | `fileRead(path:)` | 读取文件的**全部内容**并作为 `String` 返回 | ✅ **A2 裁决：统一到本方** —— **上限 65536 字节，超出静默截断**。**已对齐**（2026-09-14，IO 语义格）：解释器侧补上限，两处尺寸常量单源化。**HIR 侧已实现**（2026-09-14，G9）。⚠️ 该上限源于发射器缓冲尺寸，**已立案**：`docs/issue-io-limit-from-emitter-2026-09-12.md` |
| 34 | `readLine` | 从标准输入读**一行**，作为 `String` 返回；**输入耗尽返回空串** | ✅ **A1 裁决：统一到本方** —— **行终止符不剥离**；**上限 256 字节**（可观测值 = **255 字节**，即 `fgets` 的 `size - 1`）。**已对齐**（2026-09-14，IO 语义格）：解释器侧改为不剥 + 上限，**EOF 语义一并钉死**——LLVM 侧此前把 `fgets` 的 NULL 直接交给 `%s`（未定义行为，实测打印 `(null)`，7 字节，而解释器输出空串 1 字节），现两侧均为空串。**HIR 侧已实现**（2026-09-14，G9）。⚠️ 上限同上已立案；**超长行的流位置语义仍分歧**（同工单补记）。受害面已改：`Tests/PiniTests/IOTests/testReadLine.pini` 期望 |

> **A 组裁决的共同性质**（ADR-034 D3/D4）：三项均按判准**统一到 LLVM 侧**；上限本身
> 的合理性**不在本次裁量范围**，已另立工单。
> **落地状态**：三项**均已对齐**（2026-09-14，IO 语义格）；三项**在 HIR 引擎侧亦已实现**
> （2026-09-14，G9，打靶点清零）。本表数字均为**节点语义**，实现面的位置见
> `Sources/PiniCore/Common/IOLimits.swift`（两侧共用的上限）。

### 2.9 字符串与内建

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 35 | `isAsciiDigit(argument:)` | 首字符是否 ASCII `[0-9]`；空串 → 假 | ASCII 域内与解释器「首字素」规则重合；域外由 `ADR-019 D4` 管辖（显式 unsupported，fail-loud） |
| 36 | `stringCase(isUpper:receiver:)` | 大小写转换，**接收者不变**，返回新串 | ⚠️ **B 组缺陷**：契约 = **Unicode 感知**（`ADR-019 D1`）；LLVM 侧现为**逐字节 ASCII-only**，偏离（实测 `"café".upper()` → `CAFé`） |
| 37 | `stringContains(receiver:needle:)` | 子串包含判定 | ⚠️ **B 组缺陷**：契约 = **字素**语义；LLVM 侧现为**字节查找**，偏离（分解式 Unicode 下分歧） |
| 38 | `stringSubstring(receiver:start:length:)` | 取子串 | ⚠️ **B 组缺陷**：注册表与测试已裁 **`(start, end)`**；LLVM 侧现为 `(start, length)`，**偏离** |
| 39 | `stringSplit(receiver:delim:type:)` | 按分隔符切分为**真数组** | ✅ **A4 裁决：统一到本方** —— **跳过空 token**（`"a,,b"` → 2 段）。**已对齐（2026-09-15，`stringSplit` 格）**：偏离方是解释器，已由 `StdlibPini.split` 的两处 `len(cur) > 0` 守卫对齐；三通道在 `"a,,b"` / `",a"` / `"a,"` / `",,"` / `""` 上**逐字节一致**。⚠️ **本条只裁「空 token」**：**分隔符语义本身（子串 vs 字符集）与空分隔符语义均未裁**，LLVM 侧现按 `@strtok` 的**字符集**解释、且空分隔符无守卫 ⇒ **两处实测偏离不在本条裁决范围内，已另立工单**（`docs/issue-hir-stringsplit-delimiter-semantics-2026-09-15.md`，登记不修） |
| 40 | `arrayJoin(receiver:separator:)` | 字符串数组按分隔符连接 | ✅ **已核，移出 B 组（2026-09-15）**：`interp-ast` 与 `llvm-hir` 在**五类接收者形态**（普通 / 字面量 / 空分隔符 / 单元素 / **空数组**）上**逐字节一致**（P1-4，2026-09-12）⇒ **本节点测量不到字符语义偏离**；原「B 组」标注系**按邻近归类**（未经实测）给出，**测量未予支持**。⚠️ **订正一条此前不可核验的断言**：原文称「与**非 ASCII 分隔符 + 非 ASCII 元素**上亦逐字节一致」，而其指明的载体当时为 **752 字节纯 ASCII 文本（非 ASCII 字符数 = 0）** ⇒ 该断言**无落地载体**；**2026-09-15 已补测并同步补入夹具**（CJK / 韩文 / emoji ZWJ / 分解式重音等用例，三臂各 **49** 字节、`FLIP BLOCKERS 0`）⇒ 该断言现**可核验**。依 `ADR-034` 口径（B 组 = 规范已裁、实现偏离）与本次实测，**本节点不属 B 组** ⇒ **现行 B 组 5 项**（`§2.22` / `§2.23` / `§2.36` / `§2.37` / `§2.38`）。`interp-hir` 侧**已实现**（2026-09-14，G7 交付）——原文「未实现（`arrayLiteral` 更早拦截）⇒ P2 格」系 P1-4（2026-09-12）时点的**掩蔽**描述（本节点及其前的 `arrayLiteral` 当时均为打靶点），随该格落地失效；2026-09-14 复测本节点探针夹具三臂输出**逐字节一致**。⚠️ **本次补测的伴生发现**（同字形不同码点的字符串字面量碰撞，与 `join` 无关）已另立工单 `docs/issue-hir-string-literal-grapheme-collision-2026-09-15.md`（登记不修）。探针载体：`Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/testDiffArrayJoin.pini` |
| 41 | `stringConcat(lhs:rhs:)` | 字符串拼接（**字节语义**） | ✅ C 组：两侧结果一致，仅分配方式不同 |
| 42 | `interpString(parts:)` | 字符串插值：各部分转 C 串后拼接 | ✅ C 组：纯组装。F64 渲染走**最短往返**（`§2.8` / LR-8） |

### 2.10 LazyRef

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 43 | `lazyRefConstruct(closure:type:)` | 创建**一次求值**的惰性引用 | 求值时机是语义；wrapper 去重是发射实现 |
| 44 | `lazyRefValue(handle:type:)` | 读惰性引用的值（**触发首次求值**并缓存） | — |

### 2.11 并发与挂起

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 45 | `join(future:type:)` | `await f`（异步函数体内**挂起**等待）/ `wait f`（同步上下文**阻塞** join）：求值 `future`，待其决后**解构 `ok` / `err`**；`type` 为站点所得 `Result<T>` | ⚠️ **节点面已落地（2026-09-17，走 `§1.3` / `ADR-040`）**；**挂起语义的实现面尚未落地** —— `HIRLowerer` 无 `.join` 降载规则 ⇒ 本节点当前**不可达**。`interp-hir` 对该形态 **fail-loud**、不静默。挂起 / 恢复跨线程的上下文还原见 `pini-spec-v0.md` §3.1.3 |

> 注：§2.1–§2.11 的编号连续，共 **45 条**；**上表编号即契约条目号**，下游文档与工单以 `§2.N` 形式引用它。
> 语句位指针（`tryStmt` → §3.9、`matchStmt` → §3.14）**不占编号**，故编号与条目数严格相等。

## 3. 语句节点（17 条）

| # | 节点 | 语义 | 注记 |
|---|---|---|---|
| 1 | `allocVar(name:type:mutable:initializer:)` | 声明变量槽；有初值则在分配后立即存入 | 可变性 `mutable` 是语言约束，不靠后端 |
| 2 | `storeVar(name:type:value:)` | 向既有变量写值 | — |
| 3 | `ifStmt(label:condition:thenBody:elseBody:)` | 条件分支。`label` 非空时本节点是一个**可中断帧**：`break` 可定向到它（`ADR-039`） | 条件为布尔。`label` 本身运行时不读 —— 与循环同理，只有解析好的深度随信号走；`label != nil` 是后端「在此处捕获信号」的判据。`if` 帧**不是** `continue` 目标（`continue-stmt` 的「仅循环标签有效」） |
| 4 | `whileStmt(condition:body:step:)` | `while` 循环；**`step` 块每轮体后执行一次** —— 正常完成**与**无标签 `continue` 时均执行，`break` 跳过 | `step` 契约见 `ADR-014`；**这是常被误实现的点**。⚠️ 带标签 `continue` 且深度 > 1 时，`IREmitter` 跳 `header` 而非 `continueTarget` ⇒ **该臂不执行 `step`**（与两解释器臂相反，已单独立案） |
| 5 | `forInStmt(pattern:elementTypes:kind:iterable:body:step:)` | `for` 遍历；`kind` 决定元素读取方式；`"_"` 占位仍占槽位并带类型 | `break`/`continue` 的 `step` 契约同 `whileStmt`。⚠️ 同一缺陷在此更重：深度 > 1 的 `continue` 跳到边界检查、**跳过索引自增** |
| 6 | `returnStmt(value:)` | 返回值；`nil` 表示空返回 | — |
| 7 | `exprStmt(HIRExpr)` | 表达式求值并丢弃结果 | — |
| 8 | `deferStmt(body:)` | 语句块**离开作用域时按 LIFO 执行**（含每轮循环结束） | ⚠️ `break`/`return` 交互**未入语料 = 未门控面**（如实登记） |
| 9 | `tryStmt(operand:errorVar:handler:okTarget:type:)` | `try e else err: ...`（`ADR-032`）；操作数为 `result(ok:)`；错误路径绑定**类型擦除错误字**到 `errorVar` 并运行 handler；表达式位把 ok 载荷存入 `okTarget` | `nil` 的 `okTarget` = 语句位 |
| 10 | `subscriptStore(container:index:value:elementType:)` | 下标写 `c[i] = v`；可嵌套链；复合赋值降级为读改写 | 越界写报错（不得经赋值扩容） |
| 11 | `breakStmt(depth:)` | 跳出第 `depth` 个**可中断帧**（1 = 最内层，目标本身计入）；标签 break 已解析为深度。帧 = 循环 **＋ 带标签的 `if` 块**（`ADR-039`） | 不可解析目标（无同名标签 / 无任何循环帧）→ 降级为 `panicStmt`（fail-loud 对齐，非静默跳过）。⚠️ **本行的「对齐」在 `ADR-039` 之前是错的**：`break 指向 if 标签` 解释器解析它、降载层判它不可解析，两侧并不对齐；`ADR-039` 落地后才成立 |
| 12 | `continueStmt(depth:)` | 继续第 `depth` 个帧（1 = 重测最内层条件）。**目标只能是循环帧**（`continue-stmt` 的「仅循环标签有效」） | 同 `breakStmt` 的不可解析处置。⚠️ 一个带标签的 `if` 是 `break` 的合法目标、**不是** `continue` 的 —— 两者按同一深度计数，但可选项不同 |
| 13 | `panicStmt(message:)` | 无条件运行时陷阱，固定消息；块终止 | 用于解释器仅运行时才发现的逃逸 |
| 14 | `matchStmt(scrutinee:cases:scrutineeType:)` | `match` 分派；可分派于枚举、Optional 与**裸值字面量**（`HIRMatchLiteral`） | **未匹配 → 运行时 panic**（`matchNotExhaustive` 对齐） |
| 15 | `fieldStore(base:field:value:fieldType:)` | 具名字段写 | 对象需越过引用头（实现细节） |
| 16 | `captureMarker(name:)` | 闭包体内的 `capture` 标记语句；**捕获在闭包创建点解析**，本节点**降级为无操作** | 存在意义是让该语句种类在闭包体内被接受而非被门控 |
| 17 | `detachStmt(inner:)` | `detach <expr>`：求值操作数（须为 `Future` 值），把它从父任务**剪枝** —— 父返回时不再取消它（fire-and-forget 的**唯一**合法出口） | ⚠️ **节点面已落地（2026-09-17，走 `§1.3` / `ADR-042`）**；**降载规则与两台引擎的行为尚未落地** —— `HIRLowerer` 无 `detach` 降载 ⇒ 本节点当前**不可达**（与 §2.45 的 `join` 同一状态）。`interp-hir` **fail-loud**（`RuntimeError`）、`llvm` 侧 `fatalError`，**均不静默**。操作数非 `Future` 时按**运行时类型不符**报错（对齐解释器的 `typeMismatch(expected: "Future<T, Error>")`），**不是**降载期拒绝。**不带 `type`**：语句位不产出值，操作数类型在其自身节点内；且**没有任何 `HIRType` case 表示 future**（`Future` 是运行时值，同 `§2.45` 的立场）|

## 4. 预留位（**两条均已兑现**；本节只留可追性）

### 4.1 `char` 节点 —— **已于 2026-09-18 兑现为 §1 的 `char` 行**

原预留位（依据 / 契约预留 / 现状 / 命名注意 / 处置五条）随兑现**作废**，不再于此处复述。
**兑现动作**：`HIRType` 新增 `char` case（`Sources/PiniCore/HIR/HIRNode.swift`）+ 本节所属
契约 §1 新增 `char` 行；走 `§1.3`（等级 `G67`，`ADR-033`）。**前置已兑现**：FFI 单字节
`Char` 改名 `CChar`（2026-09-17，`ADR-033 D2` / `G65`）。

⚠️ **一处计数事实（留档）**：本契约 §1 标题原写「20 case」而实现实为 **19 case**（既存差异，
本次实测发现）；兑现后实现为 **20 case**，**标题与实现就此一致**。⇒ 原差异的合理解释是
标题写于 `ADR-033` 时期、**已把预留的 `char` 计入**（属推断，非实证）。

⚠️ **仍未实施的是 LLVM 端 grapheme 运行时符号**（2026-09-18 拆格、另立新格）—— 它**不在契约面**
（契约查**存在**不查**行为**，见 §0.3），故不构成本节遗留项。
⚠️ **保留此标题的作用是让旧引用可追**：原 §4.1 的「待 `P0d` 落地」与「**显式延后**」两条措辞
**不得**再据以写作；「处置登记」的规划载体 = `docs/issue-p0d-char-landing-plan-2026-09-18.md`。

### 4.2 `.join` 挂起语义 —— **已于 2026-09-17 兑现为 §2.45**

原预留位（依据 / 预留内容 / 现状三条）随兑现**作废**，不再于此处复述。**兑现动作**：新增
`HIRExpr.join` 节点 + 三锚点（`llvm` / `printer` / `interp-hir`）+ `§2.45` 语义条目，
走 `§1.3` 五步（`ADR-040`）。

⚠️ **仍未实施的是挂起语义本身**（CPS 求值器，格 `G3c`）—— 它不在契约面（契约查**存在**不查**行为**），
故不构成本节遗留项；该语义的进度见计划 §13 与 `docs/issue-hir-p4-gamma-g3-plan-2026-09-17.md`。

⚠️ **保留此标题的作用是让旧引用可追**：原 §4.2 的「`HIRLowerer` 须为 `.join` 增加节点面」与
`D-P4-26` 硬停条件**正面冲突**的记录（含 `R2` 记号在该处的义项），见上述规划件 —— **不得**再据旧措辞写作。

## 5. 冻结纪律与 `bk_*` 清单

### 5.1 冻结纪律（照搬 `bk_*` 范本，`ADR-034 D5`）

- 契约条目一经落地，**变更须走 §1.3**；不得为迁就某后端实现而漂移；
- `bk_*` 是 **LLVM 后端的实现面，不是语义定义处**；其 ABI 冻结（`ADR-031` 约束 4）继续有效；
- **每个后端须能自备 shim** —— 既有的「shim 边界必须是 C ABI」MUST 得到强化
  （`pini-spec-v0.md` §3.2），因为多后端下每个后端都需要自己的值层实现面。

### 5.2 `bk_*` 权威清单（37 个，2026-09-12 实测）

> **口径订正**：`ADR-031` 两处写「35 个」，`@_cdecl` 实测 **37 个**。本清单为该面的
> 单一权威来源，`ADR-031` 同步订正（`ADR-034 D6`）。

| 族 | 符号 | 数 |
|---|---|---|
| 数组 | `bk_array_create` `bk_array_destroy` `bk_array_ensure_unique_at` `bk_array_get` `bk_array_len` `bk_array_set` | 6 |
| 字典 | `bk_dict_contains` `bk_dict_create` `bk_dict_destroy` `bk_dict_ensure_unique_at` `bk_dict_get` `bk_dict_key_at` `bk_dict_len` `bk_dict_set` `bk_dict_val_at` | 9 |
| 集合 | `bk_set_add` `bk_set_at` `bk_set_create` `bk_set_destroy` `bk_set_len` | 5 |
| 句柄 / COW | `bk_handle_ensure_unique` `bk_handle_release` `bk_handle_retain` `bk_handle_shares` | 4 |
| LazyRef | `bk_lazyref_create` `bk_lazyref_destroy` `bk_lazyref_value` | 3 |
| 指针 | `bk_ptr_load_f32` `bk_ptr_load_f64` `bk_ptr_load_i32` `bk_ptr_load_i64` `bk_ptr_load_i8` `bk_ptr_store` | 6 |
| 展示 / 陷阱 | `bk_cstr` `bk_double_to_string` `bk_panic` | 3 |
| 运行时 | `bk_runtime_cleanup` | 1 |
| **合计** | | **37** |

## 6. 待办与已知偏离汇总

| 项 | 类别 | 载体 |
|---|---|---|
| A 组 4 项统一裁决（§2.32/33/34/39） | **已裁**；偏离方 = **解释器**。**§2.32/33/34 已对齐**（2026-09-14，IO 语义格）；**§2.39 已对齐**（2026-09-15，`stringSplit` 格）⇒ **A 组四项全部对齐** | §2.8 注记：IO 三项 = **IO 语义格**（已落地）；§2.39 的 `split` 空 token = **`stringSplit` 格**（**已落地**，窄读：只对齐空 token） |
| `stringSplit` 分隔符语义（§2.39 的**未裁部分**） | **缺口**：LLVM 侧 `@strtok` ⇒ 分隔符按**字符集**解释 + 空分隔符无守卫；契约**未裁**「子串 vs 字符集」 ⇒ 须走 spec §1.3 | `docs/issue-hir-stringsplit-delimiter-semantics-2026-09-15.md`（登记不修） |
| B 组 5 项字符语义偏离（§2.22/23/36/37/38） | **实现缺陷**，修实现对齐 `ADR-019 D1`。**`§2.40` 已于 2026-09-15 移出本组**（P1-4 实测未复现偏离 + 非 ASCII 面已补测，见 §2.40 行） | `docs/issue-hir-string-slice-byte-based-2026-09-11.md` |
| A1/A2 上限（§2.8 注记） | **有害默认**，须 §1.3 反向修订；**对齐已落地，但上限本身的合理性仍未裁** | `docs/issue-io-limit-from-emitter-2026-09-12.md`（含超长行流位置补记） |
| `addressOfVar` 解释器快照（§2.31） | **A/D1 裁决**：解释器须改为真引用 | 本契约 + 计划 IO/指针格 |
| `assoc` 等半语义两项（§2.17 / §2.29） | **规范表述**：须写成语义 | 本契约 |
| D2 路径基准 | **允许差异**（明文登记） | `ADR-034` D3；spec G58「v1 已知限制」 |
| D3 警告通道 | 缺口 | `docs/issue-diagnostic-channel-parity-2026-09-12.md` |
| `deferStmt` break/return 交互 | **未门控面** | 本契约（如实登记） |
| `HIRNode.swift` 头部「for the LLVM backend」 | ✅ **已订正**（2026-09-18 `P5` 收口批：实测 3 处改写、1 处判为叙述 `LR-4` 动机的历史句而不改）。⚠️ **本行系 `P0d` 批替 `P5` 补的账** —— 该批漏改本汇总行 | `docs/issue-lr4-p5-closeout-plan-2026-09-18.md` |
| `char` 节点 / `.join` 挂起语义 | **均已兑现，两条预留位清空**（`char` 于 2026-09-18 兑现为 §1 行，见 §4.1；`.join` 于 2026-09-17 兑现为 §2.45） | §4；`ADR-033` / `G67` · `ADR-040` |
| `detach` 的降载规则与两台引擎的行为 | **节点面已落、行为未落**（非预留位：条目是 2026-09-17 新裁的） | §3.17；`ADR-042` / 格 `G-3c-1` |

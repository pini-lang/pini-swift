# B 组字符语义专项（第一片：§2.22 / §2.23 / §2.36 / §2.37）交付报告

**日期**：2026-10-01
**授权**：`auth-74`（元仓 `authorizations.json`）
**前序**：`docs/spec/issue/selfhost-aot-gate-report-2026-10-01.md`（甲路线第一批：链路打通、语义未通）

---

## §1 一句话

**IR 契约 B 组四项字符语义偏离已在 LLVM 侧清零** —— 四条通道（`len` / 切片与下标 / 大小写 / `contains`）全部改经运行时段，语义逐条镜像解释器；判据夹具 **33 行两路逐字节相同**，配 **5 条只打自己的变异反证**。

⚠️ **但门禁仍未接原生臂**：自举各层跑不通的**下一个根因**已定位并做实证（§5），它**不在本专项范围内**。

---

## §2 修了什么

### 2.1 起点（开工前实测）

| 项 | 契约（= 解释器，权威） | LLVM 侧旧形状 |
|---|---|---|
| §2.22 `len(s)` | `text.count` = **字素簇** | 数「非续字节」= **Unicode 标量** |
| §2.23 `s[i]` | 字素簇 + 负值尾计数 + 越界 panic | **按字节**取一字节（非 ASCII 上还不是合法 UTF-8） |
| §2.23 `s.slice(lo,hi)` | 字素簇 + 尾计数 + 夹取 | **按字节**切 |
| §2.36 `upper/lower` | `String.uppercased()`（Unicode 感知） | 逐字节 `toupper`/`tolower`（ASCII-only） |
| §2.37 `contains` | 字素级扫描 | `strstr`（字节查找） |

⚠️ **机理**：`len` 与 `s[i]` 的「字符」定义**彼此不一致**（标量 vs 字节），在非 ASCII 文本上切点落进多字节序列内部 —— 这是自举 `splitLines` 切错行、`common` 层「取值全空」的直因。

### 2.2 落法：整族下沉到运行时段

新增 6 个运行时段（`Sources/PiniRuntime/PiniRuntime.swift`），与已交付的 `bk_substring` 同族相邻：

| 符号 | 权威出处（解释器那一路） |
|---|---|
| `bk_string_count` | `RuntimeOps.containerLength` 的 `.string` 分支（`text.count`） |
| `bk_string_char_at` | `SubscriptReadStrategy` 的 `.string` 策略 |
| `bk_string_slice` | `IRExecutor.sliceValue` 的 `.string` 分支 |
| `bk_string_upper` / `bk_string_lower` | `IRExecutor` 的 `.stringCase` 分支 |
| `bk_string_contains` | `IRExecutor` 的 `.stringContains` 分支 |

发射器（`Sources/PiniCore/CodeGen/IREmitter.swift`）改为接线，并**删掉**两个内联字节循环（`emitStringByteLength` / `emitStringCharCount`）—— 它们已无引用，留着就是会腐烂的死代码。`emit` 产物因此从 110848 行降到 **106510 行**。

⚠️ **两处设计取舍**（都写进了代码注释）：
- **开界传标志位，不传哨兵**：`bk_string_slice` 收 `hasStart` / `hasEnd` 两个标志。`s[-1...]` 是合法写法，拿 `-1` 当「开」会与真实下标撞车。
- **谓词一律回 `i32`**：C 的 `_Bool` 是零扩展 `i8`，与语言侧 `i1` 对不上；收敛到 `i1` 由调用点做（沿 `bk_is_letter` 一族的既有约定）。

---

## §3 判据与变异反证

### 3.1 判据夹具

`examples/selfhost/tools/.fixtures/bgroup-charmodel.pini` —— **33 行**，覆盖四条通道 ×（ASCII / CJK / 预组合 / 分解式组合序列 / ZWJ 序列 / 空串）。

⭐ **特殊字符一律用 `chr` 构造**（`chr(233,)` = U+00E9 预组合、`"e" + chr(769,)` = e + U+0301 分解式）：预组合与分解式在编辑器里**肉眼同形**，写成字面量就无法保证测的是哪一个。

**结果**：解释路径与原生路径 **33 行逐字节相同**。

⭐ 顺带的**正向对照**：`LEN-COMB 1`（字素簇）而不是 2（标量）或 3（字节）；`LEN-ZWJ 1` 而不是 3；`UP-ACC CAFÉ` + `UP-ACC-EQ true`（`É` = U+00C9）；`CONTAINS-NORM true`（`"café"` 分解式 `.contains("café"` 预组合`)`）—— 这一条**只有**字素模型能给真。

### 3.2 变异反证（每条只打自己）

⚠️ 夹具的 UP / LO 断言**刻意不经过下标** —— 早期版本用 `ord(upAcc[3])`，它同时依赖 §2.23，于是下标通道的变异会连带打红 UP 组（复合断言），反证就不「只打自己」了。改为字符串相等比较（`upAcc == wantUpper`，期望值同样用 `chr` 构造）后解耦。

| 变异 | 改什么 | 实际变红的行 | 判定 |
|---|---|---|---|
| **M1** | `bk_string_count` → `strlen`（字节） | `LEN-HAN/COMB/ZWJ/ACC`（4 行；`LEN-ASCII` / `LEN-EMPTY` 按预期**不动**） | ✅ 只打 §2.22 |
| **M2** | `bk_string_char_at` → 字节边界 + 取单字节 | `AT-*`（5 行）+ 其伴随断言 `ORD-*`（3 行） | ✅ 只打 §2.23 下标族 |
| **M3** | `bk_string_slice` → 按字节切 | `SLICE-0-2` / `SLICE-NEG` / `SLICE-COMB` / `SLICE-FULL`（`SLICE-CLAMP` / `SLICE-HI-LT-LO` 按预期不动 —— 夹到两端 / 空串时字节与字素同结果） | ✅ 只打 §2.23 切片族 |
| **M4** | `bk_string_upper` → ASCII-only | `UP-ACC` / `UP-ACC-EQ`（2 行）；读数正是契约登记的那个值 **`CAFé`** | ✅ 只打 §2.36 |
| **M5** | `bk_string_contains` → `strstr` | `CONTAINS-NORM` / `CONTAINS-NORM-REV`（2 行） | ✅ 只打 §2.37 |

变异全部撤回后复跑，输出与基准**逐字节相同**（`grep -c MUTATION-M` = 0）。

### 3.3 未覆盖面（如实登记）

**开界分支（`hasStart == 0` / `hasEnd == 0`）无夹具覆盖**。原因：`StdlibPini` 的 `slice|self(a: Any, b: Any,)` 收 `Any`，开界字面量（`none`）在那个参数位**写不出来**（实测 `E3-001 undefined variable 'none'`）；`null` 只有原生路径认（`StdlibPini` 段头明文）。⇒ 那两个标志位的**开界取值路径**本批只做了代码审查，没有运行期证据。

---

## §4 回归

| 臂 | 读数 | 与改动前 |
|---|---|---|
| `swift test` 全量 | **rc=0 · 167 测试 / 20 套件全过**（14 known issues） | 同值 |
| 仓内语料两路对照 | **44 / 51 逐字节相同** | 同值 ⇒ 无回归 |
| 自举整包 `emit` | rc=0 · 106510 行（旧 110848）· 新通道**接线正常** | IR 更短（内联循环被移除） |

⚠️ 语料 7 条差异**全是并发语料**（`rc 1/1`），改动前就在。

---

## §5 ⭐ 新发现：聚合返回值把栈地址交出去（**独立族，不在本专项内**）

### 5.1 是什么

自举各层仍不通（`lexer` / `parser` / `type-*` 等 `rc=139`；`common` 从崩溃变为跑出 30/36 行）。逐项追到**下一个根因**：

**函数返回结构体时，交出的是指向自己栈帧的指针。**

`makeLocation` 的生成 IR（`examples/selfhost/src/common/common.pini`）：

```llvm
define %struct.SourceLocation* @makeLocation(i32 %line, i32 %column, i8* %fileName) {
  ...
  %t1 = alloca %struct.SourceLocation          ; ← 本函数的栈
  ...
  %t23 = load %struct.SourceLocation*, ptr %loc_slot
  ret %struct.SourceLocation* %t23             ; ← 把栈地址交出去
}
```

调用方存储这个指针，函数返回后那块栈被复用 ⇒ **悬垂指针**。

### 5.2 最小复现（两路对照）

`examples/selfhost/tools/.fixtures/structret-escaping.pini`：

```pini
造|func() -> (点,):
    var p = 点()
    p.x = 7
    p.y = 9
    return p

main|func() -> ():
    let p = 造()
    print("BEFORE \(p.x,) \(p.y,)")     ; 解释 7 9 · 原生 1842884192 1
```

| 路径 | 读数 |
|---|---|
| 解释器（值语义） | `BEFORE 7 9` / `AFTER 7 9` |
| 原生 | `BEFORE 1842884192 1` / `AFTER 1842884192 1` |

⚠️ **这不是本批引入的**：它与字符串通道无关（结构体构造与返回的发射路径没被本批碰过）；本批之前它被**更早的崩溃**掩盖（上一批 `common` 是 `rc=139` 零输出，本轮把字符串语义修对后才跑到 `render` 并暴露它）。

### 5.3 影响面与为什么不在本批修

自举源码**重度使用结构体**（`SourceLocation` / `SourceSpan` / `Token` / 各 AST 节点…），所以它极可能是 `lexer` / `parser` / `type-*` 那些 `rc=139` 的**共同根因**。

> ⚠️ **2026-10-01 同日实测订正（影响到本条的口径，也影响到 §5.4 的三条修法）**：本句写时是**假设**，同日已**实测确证并加宽** ——
> 跨帧外逃在**四类名义值 + 闭包捕获**上全红（结构体 / 结构体套结构体 / **对象** / **带载荷枚举** / 闭包捕获），
> 而同帧对照**两路全一致** ⇒ 病根不是「结构体缺值语义拷贝」，是「**名义箱与捕获槽都分配在创建帧里**」。
> ⇒ §5.4 的三条修法（`sret` / `malloc` / 聚合值内联）**都只覆盖结构体**，对**对象与枚举**（它们在解释器里是**引用语义**、必须共享）**不成立**；
> 其中的「聚合值内联」另有一条硬障碍：自举 AST 是**互引图**，LLVM 类型须可定尺寸 ⇒ 递归类型**必须**用指针。
> ⇒ 订正后的路线 = **堆箱 + 引用计数**，见 `docs/spec/issue/survey-aggregate-return-2026-10-01.md` §9.3；
> 证据夹具见 `examples/selfhost/tools/.fixtures/aggregate-{escape,sameframe}-*.pini`。

**修法面**（三条，代价递减、风险递增）：

| 方案 | 做什么 | 代价 |
|---|---|---|
| **甲 · sret** | 聚合返回类型的函数改为「调用方分配 + 传 out 指针」，改签名 + 全部调用点（含函数值/闭包路径） | 中大规模，触及面广，但**正解** |
| **乙 · 返回时堆分配** | `return` 前 `malloc` + `memcpy` | 改动小，但自举跑百万级构造 ⇒ **内存爆炸**，不可行 |
| **丙 · 聚合值内联为 SSA** | 不用指针传聚合 | 等于重构表示层，最大 |

**本批不修的理由**：它**不属于** B 组字符语义（是独立的所有权/生命周期族），修复面涉及**全局返回值约定**，风险高于本专项。⇒ 按「一格一授权」的既有治理，**须另立条目**。

---

## §6 结论与下一步

**本专项（`auth-74`）交付完成**：

- ✅ B 组四项**清零**（契约 §2.21/22/23/36/37 五行已回填「已修」；§6 的 B 组清单标记销账）
- ✅ 判据夹具 + 5 条只打自己的变异反证
- ✅ 回归两条臂同值（无回归）
- ⛔ **门禁仍不接原生臂** —— 读数仍不一致时接上去就是拿错读数当门禁
- ⭐ 新登记一项独立族缺陷（§5），含最小复现与 IR 证据

**下一步（须裁）**：

1. **聚合返回值栈地址外逃**：立不立项？若立，建议走**甲（sret）** —— ⚠️ 它是甲路线跑通的**硬挡路石**，且自举越往后走（AST / 类型层）结构体用得越多。
2. **开界分支的夹具缺口**（§3.3）：要不要为它造一条能写出开界的输入路径？（**我的建议：暂不** —— 真实语料里全是整数界，投入产出比低；如实登记即可。）

# C 互操作第二版：字符串 · 回调 · 变参

- 状态：三点已定（2026-11-03）；「收口」已落地，其余五片待做。
- 基线：`150660d`；全量 437 条（文档读数，开工前重测）。
- 上承：`docs/spec/c-interop-design.md`。首版已落地的事实不重复，本文只定第二版。

## 结论

三个特性共用一处地基，通道面各不相同。

| 特性 | 语言面 | 两通道 | 主要代价 |
|---|---|---|---|
| 借出 | `String` 形参即 `const char*` | 一致 | 只在调用期有效，C 要保存得自己复制 |
| 取回 | 内建 `c字符串(*U8)` 返回 `String` | 一致 | 复制一次；`-> String` 在返回位被拒 |
| 句柄 | `StringHandle` 形参与返回 | 仅 LLVM | 运行时段符号不在 `pini` 进程里 |
| 回调 | 块内函数类型即 C 函数指针 | 一致（同线程） | 只收顶层自由函数，签名逐位相同 |
| 变参 | `\|varargs` 标志 | 仅 LLVM | 解释器做不出 C 变参 ABI（实测） |

顺序上先做「收口」，后四项都要改同一张类型表；「借出」与「取回」互不依赖可并行；「回调」最重；「变参」「句柄」各一片；文档最后一遍收。

三处待定已定：句柄只在 LLVM、变参只在 LLVM、回调用自由函数名直填。定案与代价见文末。

## 一、现状取证

八条探针都在 `pini` 上实测，分成两类：**首版留下的洞**是 `String` 形参、`String` 返回、对象形参、`U32` 宽度四条；**新特性的边界**是标志表、回调类型、变参 ABI、运行时段符号四条。

| 探针 | 读数 | 结论 |
|---|---|---|
| `atoi: (String,) -> (I32,)` | `run-llvm` 得 `123`；`run` 报 E5-006「not a C top-level type」 | 同一份源码换通道换行为 |
| `getenv: (*U8,) -> (String,)` | `run-llvm` 打印 `$HOME`；`run` 报 E5-006（返回位） | 返回方向同样分裂 |
| `puts: (人,) -> (I32,)`（对象形参） | `pini check` 通过 | ARC 对象进了 C 面却没人拦 |
| `atoi: (U32,)` | `check` 通过；`run` 与 `run-llvm` 都在 IRGen 报 E6-004 | 诊断落在错的阶段 |
| `printf\|varargs:` | E2-007「未知的外部符号标志」 | 标志表没有这一位 |
| `qsort` 带 `(*U8, *U8,) -> (I32,)` 形参 | 解析成功，语义层 E4-001「函数指针属 Phase 2b」 | 语法已在，只差语义放行 |
| 变参 ABI | 把 `int64_t sum3(int64_t, ...)` 用 8 个 GPR 位转调用，以 `sum3(1, 2, 3, 4)` 调用得 `22735859273`，正确值 `10` | 解释器那套固定 8 槽转发对变参不成立 |
| `Package.swift` | `PiniCLI` 只依赖 `PiniCore`，`PiniCore` 不含 `PiniRuntime` | `pini` 进程里没有 `bk_*` 符号 |

最后一条值得展开：`run-llvm` 走 `lli --dlopen`（`main.swift:2114`），`build --shared` 走 `-lPiniRuntime` 加 rpath（`main.swift:1551`），两条都在别的进程里加载运行时；`pini run` 自己不带。凡是要 C 侧按名字回调运行时段的东西（句柄的 `retain` / `release`），在解释器里都无处解析。

## 二、收口：一张闭合的类型表

### 2.1 表

| Pini 写法 | C 形态 | IR | 备注 |
|---|---|---|---|
| `I8` / `U8` | `int8_t` / `uint8_t` | `i8` | |
| `I32` | `int32_t` | `i32` | |
| `I64` / `U64` | `int64_t` / `uint64_t` | `i64` | |
| `F64` | `double` | `double` | |
| `Bool` | `bool` | `i1` | 见风险；回调签名不用 |
| `*T`（T 为标量或指针） | `T*` | `ptr` | 元素仍走既有 C 兼容校验 |
| `String`（仅形参） | `const char*` | `i8*` | 借出，见 3.2 |
| `StringHandle` | `bk_str_handle*` | `ptr` | 仅 LLVM，见 3.4 |
| `(A,) -> (B,)`（仅形参，块内） | `B (*)(A...)` | `ptr` | C 函数指针，见 4.1 |
| 其余 | — | — | 报错 |

「其余」是这张表的重点。今天 `checkFFITopLevelType`（`TypeChecker.swift:1804`）对未知简单名一律放行，注释写的理由是「shim 可能承载」；实际后果是对象、拼写错误、`Char`、`U32` 都能过闸（见上表）。第二版把它改成闭合表：**不在表内即报错**，没有一个「也许有 shim」的中间态。

### 2.2 一个判据，三处消费

同一张表今天被解释了三遍：

| 消费点 | 位置 | 现状 |
|---|---|---|
| 语义校验 | `TypeChecker.checkFFITopLevelType` | 白名单式放行 |
| 降载 | `IRLowerer.resolveForeignSignature` | 只看 IR 能不能表达 |
| 解释器 | `ForeignThunk.annotation(for:)` + `kind(of:)` | 从 IR 类型反推标注 |

三份必然漂：`String` 形参与 `U32` 宽度那两条就是漂出来的。第二版把「标注 → FFI 类型」的判定收到一处，IR 只搬运结果，解释器不再反推。

### 2.3 落点

| 文件 | 改什么 |
|---|---|
| `PiniSemantics/Common/FFIType.swift`（新） | 闭合枚举、归一函数、诊断；唯一定义处 |
| `IRModule.swift`（`IRForeignFunction:104`、`IRExportFunction:185`） | 形参与返回换成 FFI 类型；`isVariadic` 进来 |
| `IRLowerer.swift:1828` | `resolveForeignSignature` 改调归一函数，删本地判据 |
| `ForeignThunk.swift:122,141` | 删 `annotation(for:)` 与 `kind(of:)`，改吃 FFI 类型 |
| `IREmitter.swift:372` / `CHeaderBackend.swift:153` | 各自保留拼写表，键换成 FFI 类型 |

拼写留在后端，不放进语义层：`llvmSpelling` 属于发射层，`cSpelling` 属于头文件层，语义层只答「这是什么形状」。

### 2.4 诊断

| 情形 | 码 | 要点 |
|---|---|---|
| 类型不在闭合表内（含对象、`Char`、元组、结构体、集合、未知名） | E4-028 | 点名类型与所属条目，列出可用集合 |
| `I16` / `U16` / `U32` / `F32` | E4-029 | 说明三条通道要一致，IR 表达不了这四个宽度 |
| `String` 出现在返回位 | E4-030 | 指向 `c字符串` |
| 回调不是顶层自由函数 / 签名不逐位相同 / 含 `using` | E4-031 | 四种情形分句，点名是哪一条 |
| 回调签名含 `Bool` | E4-032 | 说明 `i1` 与 `_Bool` 的寄存器约定不同，给 `I32` 的替代写法 |
| `\|varargs` 写在数据条目上 | E4-033 | 这个标志只对函数条目成立 |
| 变参的额外实参不是 C 标量 | E4-034 | 点名第几个实参与它的类型，列出可用集合 |

码值以落地时 `Sources/PiniSemantics/Resources/Diagnostics.zh.toml` 的下一个空位为准（现表最大是 E4-027）。

## 三、字符串

### 3.1 三层与所有权

| 层 | Pini 写法 | C 形态 | 谁释放 | 通道 |
|---|---|---|---|---|
| 借出 | 形参 `String` | `const char*` | 调用方框架，调用返回即失效 | 一致 |
| 取回 | 返回值经 `c字符串(p)` | 入参 `const char*` | Pini 侧复制品，走既有串计数 | 一致 |
| 句柄 | 形参 / 返回 `StringHandle` | `bk_str_handle*` 不透明指针 | C 侧显式 `release` | 仅 LLVM |

判据一句话：**C 只读一次用借出；C 返回指针用取回；C 要存下来用句柄。**

### 3.2 借出

语义：`String` 形参在边界上就是 `const char*`，UTF-8、NUL 结尾，**只在本次调用期间有效**。C 侧要保存必须自己 `strdup`；语言不提供「借出后仍然有效」的中间态，那是句柄的活。

注意 —— 字面量与常量串落在只读段，C 侧往这个指针里写就是段错误。要可写缓冲，声明成 `*U8` 自己 `malloc`，别指望借出的串能改。

| 通道 | 做法 |
|---|---|
| 解释器 | thunk 把 Swift 串编码成临时 C 缓冲，调用结束释放 |
| LLVM | 直接传 `i8*`；拼接临时串在调用点之后释放（`releaseCallArguments` 既有行为），常量串是静态缓冲 |

注意 —— 解释器现在先按名字查 shim 表（`RuntimeOps.swift:411`），命中就用，不看声明。`strlen: (String,)` 因此撞上 shim 的 `*T` 断言，报「第 1 个参数须为 `*T` 指针」（实测）。规则改成：**shim 的形参形状与声明形状相容才生效，否则走通用 thunk**。`cstr` 自己的声明就是 `(String,) -> (*U8,)`，相容，行为不变。

### 3.3 取回

新增内建 `c字符串(p: *U8,) -> (String,)`：从指针读到 NUL，复制成 Pini 串。两通道同一语义——解释器 `String(cString:)`，LLVM 接运行时段新增的 `bk_str_from_cstr`。

`-> String` 在 FFI 返回位**拒绝**，理由不是保守：C 返回的指针可能是静态缓冲、可能是库内部缓冲、也可能是 malloc 的，Pini 侧无从判断。而 Pini 串的释放走登记表（`PiniRuntime.swift:928` 起），外来指针不在表里 ⇒ `release` 是无操作 ⇒ 泄漏；若猜成 malloc 去 `free`，则是把别人的静态内存放掉。复制是唯一不需要猜的形态。

名字：`cstr` 已经占了「出去」这一侧（`examples/ffi_module/cstring.pini:10`），反向再用同形英文读起来会混；取回叫 `c字符串`，方向在调用点一眼可辨。

### 3.4 句柄

C 面是一个不透明指针加四个入口。名字统一带 `handle`：`bk_str_retain` / `bk_str_release` 已经被计数串那一族占了（`PiniRuntime.swift:982`、`:998`），句柄再叫同名就是把两套账混成一个符号。

```c
typedef struct bk_str_handle bk_str_handle;
const uint8_t* bk_str_handle_bytes(const bk_str_handle*);   /* UTF-8 字节，不以 NUL 为界读 */
int64_t        bk_str_handle_len(const bk_str_handle*);     /* 字节数，不是字素数 */
bk_str_handle* bk_str_handle_retain(bk_str_handle*);
void           bk_str_handle_release(bk_str_handle*);
```

Pini 面：形参与返回都可以写 `StringHandle`。创建即复制——`bk_str_handle_new` 把传进来的 Pini 串拷一份，句柄自己持有，`release` 归零时释放 ⇒ 不引入别名规则，C 侧也不用关心原串的账。

通道：只有 LLVM 侧解析得到这些符号（见上表「运行时段符号」那条）。解释器在调用点拒绝，`check` 期给一条警告（见 7.1）。

### 3.5 与首版的关系

首版让 Pini 侧自己写 `*U8` 封装（`c-interop-design.md:389`）。三层落地后，`*U8` 仍留给真正的字节缓冲，字符串不再需要那一层包装；`examples/ffi_module/cstring.pini` 的 `cstr` 用法保留，它要的是「owned C 串给 free」，与借出不是一件事。

### 3.6 导出面

首版把 `String` 列在导出面的拒绝项里（`c-interop-design.md:318` 那张表）。第二版按同一个所有权思路开一半：

| 位置 | 允许 | C 形态 | 所有权 |
|---|---|---|---|
| 形参 | `String` | `const char*` | Pini 复制一份，C 保留原串 |
| 形参 | `StringHandle` | `bk_str_handle*` | 引用计数，C 自己 `release` |
| 返回 | `String` | — | 拒：返回的是 Pini 的临时串，C 拿不到释放权，也说不清有效到什么时候 |
| 返回 | `StringHandle` | `bk_str_handle*` | Pini 交出 +1，C 必须 `release` |

判据与导入面同一条：**能在边界上存活的只有句柄，能在边界上流传的只有借出**。导出函数返回 `String` 看起来最自然，实际是最容易悬垂的一种——函数返回后那次拼接的临时串已经记在账上，随时可能归零。

注意 —— 形参 `String` 的复制发生在转发层入口（`bk_str_from_cstr`），所以 C 侧传栈上的临时缓冲也安全；这条与导入面的「借出」正好对称。

## 四、回调

### 4.1 类型：C 函数指针

块内形参位上的函数类型就是 C 函数指针，语法不新增：

```
[libc|foreign]
qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()
```

这一行今天就能解析（见上表「qsort 形参」那条），只差语义放行。落地要动两处类型：

| 层 | 增什么 | 说明 |
|---|---|---|
| `TypeAnnotation` | `.cFunction(params:returns:)` | 只由 FFI 归一器产出，解析器不产；用户手写不到 |
| `IRType` | `.cFunction(params:returnType:)` | `llvmSpelling` 是 `ptr`，与 `.function` 的 `{ ptr, ptr }` 明确分开 |

分开是硬要求：`.function` 是 Pini 的胖指针 `{code, env}`，调用时第一个实参是 env；把 C 指针塞进那条路，等于把代码指针当环境指针用。

v2 **不让外部函数返回函数指针**。原因不是懒：返回值要先落进一个 Pini 变量，那就得给「C 函数指针」一个完整的一等类型（可存、可传、可比较、可空），而它的生命周期无从校验。要动态取符号仍旧走 `build --shared` 的静态导出。

### 4.2 谁能当回调

四条硬规则，全部在语义期判：

1. 实参位上写的是**一个标识符**，且它解析到顶层自由函数。方法、闭包字面量、变量、形参、`|test`、`main` 都不行——变量里装的可能是闭包，取址取到的是胖指针的一半。
2. 签名逐位相同：参数与返回都过 2.1 的表，无 `using`，返回至多一项。
3. 不含 `Bool`。Pini 的 `i1` 与 C 的 `_Bool`（零扩展的 `i8`）在寄存器层不是一个约定；回调方向没有转发层可以替它转。
4. 传出去的是 `@mangle(名)` 本身，不包一层。这与首版「名即符号」是同一条纪律：包一层就多了一个 C 侧看不见的名字。

规则 4 有一个直接后果：Pini 函数必须本身就是 C ABI。这一条今天已经成立——`IREmitter.swift:765` 发的是朴素函数，标量签名与 C 同形（实测 `加一` 发成 `define i32 @_u52A0_u4E00(i32 %n)`）。

### 4.3 导入侧：传出去

```
unsafe qsort(缓冲, 4, 1, 比较)
```

降载成新节点 `.cFunctionAddress(name)`，发射成 `ptr @_u6BD4_u8F83`。解释器侧见 4.6。

### 4.4 导入侧：调用收到的指针

形参进了函数体就是一个值，`fn(a, b)` 照常写。降载成新节点 `.cCall`，不复用 `.indirectCall`——后者取 `{code, env}` 再先传 env，对 C 指针是错的。

| 通道 | 发射 / 执行 |
|---|---|
| LLVM | `%p = load ptr, ...` 然后 `call i32 %p(i32 %a, i32 %b)` |
| 解释器 | 与 `ForeignThunk` 同一套位转调用，只是地址来自值而不是 `dlsym` |

### 4.5 导出侧：C 传进来

```
映射(f: (I32,) -> (I32,), x: I32,) -> (I32,):
    return f(x)

[calc|export]
calc_map|c = 映射
```

```c
int32_t calc_map(int32_t (*f)(int32_t), int32_t x);
```

头文件按 2.1 的表拼函数指针；导出转发只搬指针，不碰它的生命周期。C 侧传进来的指针在本次调用内有效，Pini 不清算它——这条要写进头文件注释。

### 4.6 解释器的桩

C 调用的是地址，地址必须真的能执行，所以解释器得备桩。

| 环节 | 做法 |
|---|---|
| 桩 | 按返回类分两组（整数/指针组、浮点组），每组四个槽位；签名用既有的 8 槽位转，与 `ForeignThunk` 同一套编解码 |
| 登记 | 线程局部的「槽位 → Pini 可调用体」表，调用前压入、`defer` 弹出；嵌套调用自然成栈 |
| 取体 | `.functionValue` 已经产出 `Value.function(FunctionValue)`（`IRExecutor.swift:855`），桩直接调 `callFunctionValue` |
| 上限 | 同一次调用里同类回调最多四路；超过在调用点报错（C 侧没有上下文可区分两个同类指针） |

桩要能回调进解释器，前提是引擎可重入：`invoke` 每次新建 `Environment`（`IRExecutor.swift:2135`），看起来成立，但这属于「必须先用探针证明」的那一类。**回调分片的第一件事**是写一个 C shim `ffi_apply(fn, a, b)`，手工装桩跑通一次；跑不通就退回「解释器拒绝回调」并在通道表里登记，别先写规则。

### 4.7 生命周期与线程

| 方向 | 谁发起 | 有效期 | 跨线程 |
|---|---|---|---|
| 传出去 | Pini 调 C | 本次调用内；地址本身进程期有效（代码段） | C 在别的线程调它，LLVM 侧可行，Pini 侧共享状态归调用方 |
| 传进来 | C 调 Pini | 本次调用内；Pini 不持有 | 同上，解释器会因线程局部登记表找不到而 panic |

注意 —— 「地址进程期有效」与「调用期有效」是两件事：函数指针不变，但它捕获不到任何东西（规则 1），所以跨调用重入同一函数是安全的；不安全的是 C 把指针存下来在**另一个线程**调，那时 Pini 侧若碰给定块，同步归调用方。

## 五、变参

### 5.1 语法

```
[libc|foreign]
printf|varargs: (*U8,) -> (I32,)
```

为什么用标志不用 `...`：

| 写法 | 改动面 | 读法 |
|---|---|---|
| `\|varargs` | `ForeignSymbol.knownFlags`（`ForeignDecl.swift:20`）加一项，闭表白名单路径已在 | 标志在名字旁，「这个符号是变参」 |
| `...` 进类型 | 词法加记号、函数类型文法加一支、`TypeAnnotation.function` 加字段，所有匹配点跟着改 | 标志在类型里，更贴 ABI 事实 |

选标志。代价写在明处：读者要记一条「这个标志只对函数条目成立」，所以 2.4 给它配了一条专门的诊断（E4-033）。`...` 留到哪天函数类型要带变参位时再谈——那时是语言级变更，不是互操作的一笔。

### 5.2 调用与提升

声明里的形参表是**固定前缀**，调用点可以多传。多传的实参只收 C 标量，且按 C 的默认实参提升传：

| Pini 实参 | 传法 | 备注 |
|---|---|---|
| `Bool` | `i32`（`zext`） | C 侧 `_Bool` 提升到 `int` |
| `I8` / `U8` | `i32`（`sext` / `zext`） | 按声明符号性 |
| `I32` | `i32` | 不动 |
| `I64` / `U64` | `i64` | 不动 |
| `F64` | `double` | 不动 |
| `*T` / `String` / 回调 | `ptr` | 借用规则同 3.2 |
| 其余 | — | 语义期拒（E4-034） |

LLVM 不做默认实参提升，这一层必须在发射点自己做；指望 `clang` 替我们补是错的——它看到的是 IR，不是源码。

### 5.3 通道

| 通道 | 行为 |
|---|---|
| LLVM | `declare i32 @printf(ptr, ...)`，调用点按 5.2 提升 |
| 解释器 | 调用点拒绝，文案给两条出路：换 `run-llvm`，或在 C 侧写固定参数的 shim |

拒绝而非降级，理由是上表「变参 ABI」那条实测：解释器转发靠「bitcast 成 8 个 GPR」，而 Apple arm64 把变参放在栈上，位转调用拿到的是垃圾。三条路都试过——引 libffi（第一个第三方依赖，分发形态要重谈）、编译期生成 C shim（每个调用点实参类型都不同，shim 无法预先固定签名）、白名单（只覆盖 printf 家族，且与「只声明」的边界纪律冲突）。三条都不如「明说这条只在 LLVM 上成立」。

## 六、实施分片

| 主题词 | 内容 | 验收 |
|---|---|---|
| 收口 | 闭合类型表、单一归一函数、IR 换形、三处消费点收敛 | 对象形参与 `U32` 两条转为 `check` 期报 E4-028 / E4-029；新增 8 条负例逐条对码；全量绿 |
| 借出 | `String` 形参走借出（导入与导出两侧）；shim 表按形状生效 | `atoi("123")` 在两通道都得 `123`；`strlen: (String,)` 不再撞 shim；导出的函数收 C 串时 Pini 拿到 `String`；`examples/ffi.pini` 的 golden 不变 |
| 取回 | `c字符串` 内建与 `bk_str_from_cstr` | `getenv` 取回两通道同值；`-> String` 在 `check` 期报 E4-030 |
| 回调 | `.cFunction` 两处类型、`.cFunctionAddress` / `.cCall` 两节点、导出头文件、解释器桩 | `qsort` 两通道同序；C shim 端到端；`calc_map` 的 C 调用方跑通；六条负例 |
| 变参 | 标志位、arity 放宽、提升、declare、解释器拒绝 | `run-llvm` 出 `declare i32 @printf(ptr, ...)`；`I8` / `Bool` 提升正确；`run` 报新码并给出两条出路 |
| 句柄 | 五个运行时段符号、`StringHandle` 形参/返回、头文件、解释器拒绝 | `build --shared` 的库由 C 侧 retain/release 与读字节；`run` 报新码 |
| 文档 | 四份规范、文法附录、示例与 golden | 文档链接门禁、注释门禁、契约计数全过 |

依赖关系：收口在最前；借出与取回互不依赖；回调只依赖收口；变参只依赖收口；句柄依赖取回（共用 `bk_str_*` 族）；文档跟在最后，但每片落地时同步改对应段落，不留到最后一次性补。

### 收口

- 新 `FFIType.swift`：枚举 + `FFIType(annotation:)` + 诊断；`pointer` 只允许标量或指针目标。
- `IRForeignFunction` 的 `paramTypes` 与 `returnType` 换成 FFI 类型；`IRForeignData.type` 保留 `IRType`（数据符号只有读/写，不需要回调与变参的记号）。
- `IRExportFunction.params` 与 `IRExportStorage.Field.type` 同步换形，头文件后端从 FFI 类型取拼写。
- `IRValidator` 里 foreign 段的类型检查跟着换；`IRPrinter` 的 `foreignDataAddress` 不变。
- 负例：对象、`Char`、元组、`[I32]`、`Result`、未知名、`U32`、`I16`、`F32` 各一条。

### 借出

- `ForeignThunk` 增 `.cString` 形状：分配、编码（UTF-8 + NUL）、调用、释放；失败路径也要释放。
- `RuntimeOps.libcShims` 的条目要带形参形状；命中判据从「名字在表里」改成「名字在表里且形状相容」。
- `checkFFITopLevelType` 的 `String` 分支从「引用类型放行」改成明确的一条。
- 导出面：形参 `String` 在转发层入口复制（`bk_str_from_cstr` 加一次 `bk_str_release` 能在返回前收干净）；返回位写 `String` 报 E4-030。
- 端到端：`atoi`、`strlen`、`puts` 各一条；再补一条「临时拼接串作实参」证明调用期有效；导出一侧补一条「C 传栈缓冲进 Pini」。

### 取回

- `BuiltinRegistry` 加条目。归组要新开一档：放 `char` 是把「字符串转换」当字符处理，放 `pointer` 是把它当内存原语，两处都会让人按错类别去找。
- 类型层签名 `(*U8,) -> (String,)`；调用点须在 `unsafe` 上下文（有指针实参，既有门禁已覆盖）。
- LLVM：`bk_str_from_cstr(ptr) -> i8*`，返回新分配的计数串，入账为「本层持有」。
- 解释器：`RuntimeOps` 里一条同名实现，两处同一语义。

### 回调

- `TypeAnnotation.cFunction`：`describe()` 写成 `(A,) -> (B,) [C]`，`isStructurallyEquivalent` 与 `.function` 互不相等；解析器不产，纯手写构造要报错。
- `IRType.cFunction`：`llvmSpelling` 为 `ptr`；`describe()` 同上；`IRType(from:)` 不接受。
- `.cFunctionAddress(name)` 与 `.cCall` 两个节点：`IRNode`、`IRPrinter`、`IRValidator`、三个后端的 anchor 全部补齐。契约表与三处 anchor 必须同一笔提交——`tools/ir-contract-check.py` 会逐项比「契约有条目 / 枚举有 case / 后端有分派」，缺一项即红。`IRType` 由 21 增到 22。
- 语义：`checkForeignDeclSignatures` 放行嵌套函数类型；调用点判「实参是不是顶层自由函数」；导出面判 FFI 类型表。
- 头文件：函数指针参数的拼写、注释「只在本次调用内有效」。
- 解释器：桩 + 登记表 + 拒绝跨线程 + 四路上限。

### 变参

- `ForeignSymbol.knownFlags` 加 `varargs`；`isFunction` 之外的条目带上它报 E4-033。
- `IRForeignFunction.isVariadic`；`IRLowererSignatureInfo` 加同名字段，arity 判据从「相等」改成「不少于」。
- 类型层调用检查同步放宽，多传的实参逐个过 5.2 的表。
- 发射：declare 带 `...`；调用点按提升改写 `argList`。
- 解释器：`IRExecutor` 在 foreign 调用分支先判 `isVariadic`，命中即抛带两条出路的运行时错误。

### 句柄

- 运行时段五个符号：3.4 那四个加 `bk_str_handle_new`；`docs/spec/runtime-abi.md` 由 97 改 103（取回 1 + 句柄 5）。
- `StringHandle` 作为内建简单名：只在 FFI 面合法，普通代码里出现即报错。
- LLVM：形参处 `bk_str_handle_new(ptr)` 包一层；返回位原样交出；`retain` / `release` 由 C 调。
- 解释器：调用点拒绝，文案指向 `run-llvm` 与 `build --shared`。

### 文档

| 文件 | 改哪几段 |
|---|---|
| `docs/spec/c-interop-design.md` | 类型映射表（318 行起）补四行；「首版不做」（481 行）改成第二版的三条边界；新增「第二版」四节与通道表；风险表补三条 |
| `docs/spec/pini-reference-v0.md` | 9.5 已知限制表删「变参 / 回调」两行；9.6 补三层字符串；9.7 的导出类型表补 `String` 形参与 `StringHandle`，回调参数另起一行；文法附录加 `\|varargs` |
| `docs/spec/ir-contract.md` | §1 类型层 21 → 22；§2 调用一节加两个节点；§5 后端义务加「C 函数指针对三个后端都是拒」 |
| `docs/spec/runtime-abi.md` | §2 表加两族；合计数与 §4 互补关系同批改 |
| `examples/` | `ffi.pini` 加一段 `qsort`（两通道都能跑）；`ffi_module/lib/ffilib.c` 加 `ffi_apply`；另加一例只讲借出与取回 |

注意 —— 变参与句柄各只有一个通道，示例门禁（`tools/examples-gate.py`）会同时跑 `run` 与 `run-llvm`，所以这两条不进 `examples/`，只进测试。要在示例里演，就等哪天真做成两通道一致。

## 七、诊断与警告

### 7.1 警告

| 码 | 触发 | 文案要点 |
|---|---|---|
| E7-006 | 声明了变参条目 | 只在 LLVM 通道可用；`run` 会在调用点拒绝 |
| E7-007 | 声明或使用了 `StringHandle` | 只在 LLVM 通道可用；解释器进程没有运行时段符号 |

警告放在声明处而不是调用处：作者写声明时就知道这条边界，别等到跑起来才发现。

### 7.2 运行时

| 码 | 触发 | 文案 |
|---|---|---|
| E5 段新码 | 解释器遇变参调用 | 「变参调用需要 C 变参 ABI，解释器只能按固定签名转发」+ `run-llvm` 与 shim 两条出路 |
| E5 段新码 | 解释器遇句柄形参 | 「字符串句柄由运行时持有，`pini` 进程里没有这些符号」+ `run-llvm` / `build --shared` |

## 八、风险

| 风险 | 说明 | 处置 |
|---|---|---|
| 解释器不可重入 | 桩回调进引擎时撞上共享状态 | 回调分片第一件事是 `ffi_apply` 探针；不通就退回通道表登记，别改语义 |
| `Bool` 的 ABI | `i1` 与 `_Bool` 的寄存器约定不同 | 回调签名直接拒（E4-032）；其余位置沿用首版结论（arm64 实测可用），换平台重验 |
| 句柄的通道缺口 | 解释器没有 `bk_*` 符号 | 声明期警告 + 调用点拒绝；真要求两通道一致，再谈把运行时链进 CLI |
| 变参的提升做漏 | `i8` 直接传，C 侧读到高位垃圾 | 提升表与诊断同批落地；用例覆盖 `I8` / `U8` / `Bool` |
| 回调数量上限 | 同类回调超过四路无法区分 | 调用点报错并说明原因，不留静默错配 |
| 契约计数 | 新节点未登记，`ir-contract-check` 变红 | 新增节点与三后端 anchor 同批提交 |
| 收口的返工面 | `IRForeignFunction` 换形会牵动校验、打印、两个后端 | 先只换 foreign 面，`IRExport*` 分第二笔；每笔都全量绿 |
| 名称撞车 | `StringHandle`、`c字符串` 与既有内建重名 | 开工前 `grep` 语料与内建表确认零占用 |

## 九、不做的事

- 不做 C++ / Rust 互操作，不做结构体按值，不做异步跨边界（沿用首版）。
- 不让外部函数返回函数指针，不做运行时动态取符号。
- 不做可空的函数指针，不做函数指针的比较与打印。
- 不做跨线程回调的保证；解释器遇到会 panic，LLVM 侧归调用方。
- 不做变参的导出（Pini 函数发布成 C 变参没有可读的语义）。
- 不为 `String` 做隐式拷贝语义的猜测：要么借出，要么显式取回，要么句柄。

## 已定的三点

三条都按推荐定案，2026-11-03。下面每条记「定案 / 代价 / 未取 / 落点」，未取的选项留着是为了将来改判时能看出当时否掉的是什么。

### 字符串句柄的可用面

- 定案：只在 LLVM。`StringHandle` 在 `pini run` 上不可用。
- 代价：声明期一条 E7-007 警告，解释器调用点一条 E5 错误，两条都指向 `run-llvm` 与 `build --shared`。开发循环里用到句柄的程序只能换通道跑。
- 未取：解释器按需 `dlopen` 运行时段——两通道一致，但 `pini run` 多一条运行期依赖、一次查找失败路径，且要以 `RTLD_GLOBAL` 载入，把 `bk_*` 名字塞进进程全局符号表。未取：不做可持有句柄——C 无法长期持有 Pini 字符串，文档得把这条再留给下一版。
- 落点：3.4 的 C 面、7.1 的警告、7.2 的运行时错误、分片表「句柄」那一行。

### 变参的通道

- 定案：只在 LLVM。`|varargs` 条目在解释器上调用即报错。
- 代价：一条能力只在一条通道上，文档要单列一行说明；`pini run` 跑不了声明了变参的模块（只要不调用就还能跑）。
- 未取：引 libffi——解释器也能调变参，代价是第一个第三方依赖，三平台分发与静态链接都要重谈。未取：解释器只认 printf 家族白名单——覆盖面窄，且与「只声明、不插桩」的边界纪律冲突。
- 落点：5.3 的通道表、7.1 的警告、分片表「变参」那一行。

### 回调的书写形式

- 定案：自由函数名直填实参位，形如 `unsafe qsort(缓冲, 4, 1, 比较)`。
- 代价：「取址」这件事不写在源码上，靠 4.2 的四条硬规则说清；实参位只收标识符，想把函数值先存进变量再传会被拒。
- 未取：显式内建 `c回调(比较)`——取址写在源码上，但要给「C 函数指针」一个可流转的一等类型（可存、可传、可比较），而它的生命周期无从校验。未取：只收 `|c` 已导出的名字——最保守，但要把内部函数先发布成 ABI 才能当回调。
- 落点：4.2 的四条规则、4.3 的降载节点、分片表「回调」那一行。

三点定案后实施顺序不变：收口 → 借出 / 取回 → 回调 → 变参 → 句柄 → 文档。

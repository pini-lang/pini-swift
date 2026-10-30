# C 后端计划

> 状态：第 ③ 阶段（模块实现）。已完成八刀，`examples` 51 个里 42 个编译成功且与解释器逐字节一致，
> 剩余 9 个未开（8 个并发 + 1 个前端拒绝）。
>
> 度量基线（本文件写就时）：examples 42/51 · `swift test --no-parallel` 288 个测试 / 47 套件 ·
> 注释门禁 306 个文件 · 产物零崩溃、零 `cc` 报错。

## 一、通道定位

C 后端是第四条执行通道：与 `IRExecutor`、`IREmitter` 平级，消费同一份 `IRModule`，
链接同一个 `libPiniRuntime`。

| 通道 | 输入 | 产物 / 执行 | 何时选它 |
|---|---|---|---|
| `IRExecutor` | IR | 进程内树遍历 | 开发、断点调试 |
| `IREmitter` | IR | `.ll` → `lli` / `clang` | 性能、发布 |
| `CEmitter` | IR | `.c` → 任意 `cc` | 无 LLVM 环境、人工审计、混入 C 工程 |

它不是新前端、不是新 IR、不是新运行时，也不是 LLVM 的替代品。它的立足点是「不依赖 LLVM」，
不是「更快」。

## 二、三条锁死契约

| 契约 | 内容 | 代价 |
|---|---|---|
| ABI 零改 | 链接现有 `libPiniRuntime`，`bk_*` 零新增、零改签名 | 能力上限 = 现有 ABI 的表达力；「纯 C 运行时子集」整条路线作废 |
| 所有权镜像 | 照抄 `IREmitter` 的插入点，不引入 RAII、作用域守卫 | 两处规则并存，靠差分门禁锁一致 |
| 产物切分 | `emit(module:) -> [CFile]`，每模块一 `.c` | 此处的「模块」指 `IRModule`，不是源文件 |

## 三、已定型决策

| 主题 | 决定 | 落点 |
|---|---|---|
| 对象头 | `{strong, weak, type_id, weak_table}`，64 位下 24 字节 | `headerSlotCount = 4`，字段 / 标签 / 载荷索引全由它派生 |
| C 基座 | C23；生成子集 = C89 语法 + `_Atomic` | 产物按 `-std=c23` 编译，不把编译器对 C23 的部分支持变成产物风险 |
| 陷阱口径 | 消息 + 换行进 stderr、退出码 1、stdout 不动 | `assert` 与 `panic` 同规；解释器的 E5 渲染归工具层，不进跨通道判据 |
| 产物目录 | `--out` > `PINI_BUILD_DIR` > `pini-build/` | 基名取输入路径；`pini_rt.h` 只放一份 |
| 类型标识 | 模块内声明序，0 留「未知」 | 跨模块链接前必须换成稳定 id |
| 函数值 | `{code, env}`，16 字节 | code 转函数指针调用：POSIX 保证、ISO C 不保证，产物自带这条边界声明 |
| Result | `{i64 tag, ok, i64 err}` 按值 | 与 LLVM 三元组同序，逐形状 `_Static_assert` |

注意 —— **生成子集**：这条不是风格偏好，它同时满足「以最新标准为准」与「任何 `cc` 都吃得下」。

## 四、已完成切片

每行的覆盖数是该刀落地后「编译成功且逐字节一致」的例子数，只增不减。

| 切片 | 范围 | 覆盖 |
|---|---|---|
| 骨架 | 标量、控制流、`print`、`panic`；`pini build --c-backend` 接线 | 8 |
| 名义类型 | 结构体、对象、枚举、`match`、字段读写、拷贝胶水、布局断言 | 19 |
| 所有权 | 别名点 retain、覆盖前 release、作用域退出释放；调用点临时值借用 | 19 |
| 容器 | 数组、字典、集合、`Optional`、`for-in` | 28 |
| 语句与字符串 | `defer`、带 step 的 `while`、拼接、插值、字符串内建、文件 IO | 33 |
| 闭包 | 闭包字面量、函数值、间接调用、env 结构 | 37 |
| 值族 | 元组、切片、`LazyRef` | 41 |
| 结果 | `Result` 构造、`try` 分支 | 42 |

## 五、剩余工作

### 并发第一刀：`Future` 与派发

- 入口：`CTypeMap` 的 `.future` 拼写；`CEmitter` 的 `.call` 分支（被调者 `isAsync` 即派发点）；
  `IRStmt.detachStmt`；`IRExpr.join(future:type:form:)`。
- 要做：句柄类型的拼写与零值；`bk_task_spawn` 的调用序列；`join` 的两种形态
  （`JoinForm.awaits` 可挂起、`.waits` 阻塞）。
- 验收：6 个卡在 `Future` 槽的例子逐字节一致。
- 风险：派发点的判据是「被调者 `isAsync`」而不是类型；漏判会退化成直接调用，
  语义从「异步」悄悄变成「同步」，而输出往往看不出差别。

### 并发第二刀：帧让出

- 入口：`IREmitter` 的 `frameMode = .resumable` 分支（判据 `isAsync` 且返回 `Result`）、
  `bk_task_frame` / `bk_task_slot` / `bk_task_await`。
- 要做：续跑点存帧首字、槽按固定顺序重放、让出时 `out` 一个字节都不写、`switch(resume)` 派发。
- 验收：`concurrency-async-contagion-end`、`concurrency-async-decl` 逐字节一致。
- 风险：局部变量必须全落帧槽；漏一个，让出恢复后读到的是垃圾，而崩溃点与根因相距很远。

### 并发第三刀：取消

- 入口：`bk_task_cancel` / `bk_task_is_cancelled`。
- 验收：`concurrency-cancel` 逐字节一致。

### `ffi`

前端 `E4-001` 就拒绝，`pini run` 同样失败，不属于后端工作面。要做先修类型检查器。

## 六、判据分层

四层各管一件事，互不替代。

| 层 | 手段 | 抓什么 |
|---|---|---|
| 对等 | `Tests/PiniTests/CBackendParityTests`：语料 + 手写期望 + 真实 `cc` + 逐字节比对 | 语义偏离 |
| 内存 | ASan 重编重跑 + 峰值 RSS 对照 | 泄漏、提前释放 —— 两者都不改输出字节 |
| 布局 | 产物里逐类型 `_Static_assert`（`sizeof` + 每个字段 `offsetof`） | 字段顺序或宽度漂移 |
| 诊断 | `tools/ir-parity-probe.py`（保持两通道） | 哪条通道坏了 |

注意 —— **参照物**：手写期望，不是另一条通道 —— 两条通道同时错会互相认证；探针只做诊断仪器，
不长判据链。

## 七、已知风险

| 风险 | 现状 | 处理 |
|---|---|---|
| 字段偏移漂移 | 已由逐类型断言挡住 | 新增聚合体必须同批加断言 |
| 所有权两处规则 | 靠差分门禁锁 | 出现第三次分叉时再抽共享层 |
| 标识符撞 C 关键字 | 已统一加 `pini_` 前缀，顺带躲开 C23 新关键字 | 新符号沿用前缀 |
| 函数指针转换 | POSIX 保证、ISO C 不保证 | 产物注释已声明，不宣称跨平台 |
| 临时值三处未覆盖 | `f(g())` 返回值、`match` 临时值、容器元素槽 | 与 LLVM 侧同缺口，两边一致；改动要同时做 |
| LLVM 侧并发发射崩溃 | `pini emit examples/concurrency.pini` 直接 fatal（rc=133） | 并发期验收前必须先修，否则「两通道对等」无从判定 |

## 八、工程约定

- **分支**：`agent/pini-dev/<slug>`；`--no-ff` 合并回默认分支，合并后显式切回工作分支。
- **提交前四件**：`swift build` clean、`swift test --no-parallel` 全绿、注释门禁通过、
  examples 全量对等（成功数不得回退）。
- **子代理读数复核**：先 `swift build`，再比 `.build/debug/pini` 与源码时间戳 ——
  已有两次「拿旧二进制收读数」的先例，结论全错。
- **注释**：每块 ≤3 行、每行 ≤120 字、中文；只写现状与不变量，不写改动史；不用 emoji，
  提示句写「注意 —— 」。
- **并行边界**：同一文件禁止并行编辑，多族工作必须串行。

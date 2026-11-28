# 运行时 ABI 契约

- 性质：**宿主级规范**。运行时段对外 C-ABI 的**唯一权威载体**。
- 适用面：一切由生成代码或解释器调用的运行时段入口。符号是 `pini_` 前缀的 C 导出，
  实现文件是 `Sources/PiniRuntime/PiniRuntime.swift`。
- 变更：删改符号先改本件，再改实现；新增符号同批登记。

## 0. 定位与判读规则

### 0.1 权威次序

1. **语言语义**以 `pini-reference.md` 为准；
2. **IR 节点语义**以 `ir-contract.md` 为准；
3. **符号名、族划分与计数**以**本件**为准 —— 其他文档只列族、不复制成员名。

### 0.2 边界纪律

- 本件只写**符号面**：名字、族、调用约定、份额归属与陷阱姿态。
- 不写语言语义（那在参考件），也不写 IR 节点语义（那在 IR 契约）。
- 同一份名单不写第二遍。参考件的运行时一节只承担「有哪些族、各干什么」。
- 前缀不是判据：解释器回调桩 `pini_cb_N` 与串常量全局 `pini_program_base` 也用 `pini_`，
  但都不在本清单内。清单只认 `@_cdecl` 导出。

### 0.3 量具口径

**134 = `@_cdecl("pini_…")` 的匹配数**，即导出符号数，不是 `@_cdecl` 的字样出现数。
两者相差 2：正文有两处注释提到 `@_cdecl` 却不导出符号。数出来差 1 或 2 时，先分清数的是哪一个。
器械是 `tools/runtime-abi-check.py`。

## 1. 冻结纪律

- 符号一经落地，改名或改签名须走语言级变更流程，不得为迁就某个后端而漂移。
- **shim 边界必须是 C ABI**，不是宿主语言的原生调用约定 —— 违反即把实现语言变成永久依赖。
- 集合、并发、LazyRef、FFI 共用同一个运行时段，不另设独立 shim。
- 新增符号同批登记本件，等式「清单数 = 导出数」是它唯一的自检方式。

## 2. 符号清单（135 个）

| 族 | 符号 | 数 |
|---|---|---|
| 数组 | `pini_array_append` `pini_array_create` `pini_array_destroy` `pini_array_ensure_unique_at` `pini_array_get` `pini_array_len` `pini_array_set` `pini_array_set_element_hooks` | 8 |
| 字典 | `pini_dict_contains` `pini_dict_create` `pini_dict_destroy` `pini_dict_ensure_unique_at` `pini_dict_get` `pini_dict_key_at` `pini_dict_len` `pini_dict_set` `pini_dict_val_at` | 9 |
| 集合 | `pini_set_add` `pini_set_at` `pini_set_create` `pini_set_destroy` `pini_set_len` | 5 |
| 句柄 / COW | `pini_handle_ensure_unique` `pini_handle_release` `pini_handle_retain` `pini_handle_shares` | 4 |
| LazyRef | `pini_lazyref_create` `pini_lazyref_destroy` `pini_lazyref_value` | 3 |
| 弱引用 | `pini_weak_create` `pini_weak_destroy` `pini_weak_value` | 3 |
| 默认实例 | `pini_given_get` | 1 |
| 指针 | `pini_ptr_load_f32` `pini_ptr_load_f64` `pini_ptr_load_i32` `pini_ptr_load_i64` `pini_ptr_load_i8` `pini_ptr_store` | 6 |
| 展示 / 陷阱 | `pini_cstr` `pini_double_bits` `pini_double_to_string` `pini_parse_double` `pini_panic` `pini_print_lock` `pini_print_unlock` | 7 |
| 运行时 | `pini_runtime_cleanup` | 1 |
| 字符 | `pini_char_equal` `pini_char_equal_string` `pini_char_release` `pini_char_retain` `pini_char_to_heap_string` `pini_chars` `pini_chr` `pini_is_letter` `pini_is_number` `pini_ord` `pini_temp_byte_to_int` `pini_temp_int_to_byte` `pini_temp_utf8_bytes` | 13 |
| 字符串面 | `pini_str_alloc` `pini_str_append_cstr` `pini_str_concat` `pini_str_dup` `pini_str_from_cstr` `pini_str_header_bytes` `pini_str_refcount` `pini_str_table_min_cap` `pini_str_release` `pini_str_retain` `pini_string_char_at` `pini_string_contains` `pini_string_count` `pini_string_index_of` `pini_string_lower` `pini_string_slice` `pini_string_split` `pini_string_trim_left` `pini_string_trim_right` `pini_string_upper` `pini_substring` | 21 |
| 字符串句柄 | `pini_str_handle_bytes` `pini_str_handle_len` `pini_str_handle_new` `pini_str_handle_release` `pini_str_handle_retain` | 5 |
| 闭包 / 结构体胶水 | `pini_nominal_alloc` `pini_nominal_release` `pini_nominal_retain` `pini_slot_alloc` | 4 |
| IO / 宿主查询 | `pini_append_file` `pini_argv` `pini_ensure_dir` `pini_exe_dir` `pini_exists` `pini_is_dir` `pini_list_dir` `pini_module_root` `pini_read_file` `pini_set_program_base` `pini_try_append_file` `pini_try_read_file` `pini_try_write_file` `pini_write_file` | 14 |
| 行输入 | `pini_stdin_read_line` | 1 |
| 进程 | `pini_process_release` `pini_process_spawn` `pini_process_stderr` `pini_process_stdout` `pini_process_wait` | 5 |
| 任务 / 并发 | `pini_capabilities` `pini_scope_close` `pini_task_cancel` `pini_task_detach` `pini_task_is_cancelled` `pini_task_join` `pini_task_join_all` `pini_task_join_all_box` `pini_task_join_within` `pini_task_spawn` `pini_task_yield` | 11 |
| 阻塞内建 | `pini_sleep` | 1 |
| 让出族 | `pini_task_await` `pini_task_frame` `pini_task_slot` | 3 |
| 调度驱动面 | `pini_task_bind_sched` `pini_task_state` | 2 |
| 错误载荷 | `pini_cancel_error_create` `pini_error_code` `pini_error_create` `pini_error_from_enum` `pini_error_is_cancel` `pini_error_lookup` `pini_error_message` `pini_error_with_code` | 8 |
| **合计** | | **135** |

## 3. 语义约束

### 3.1 句柄

- 容器、LazyRef、Future 一律不透明句柄，调用方只搬指针，不解读布局。
- 句柄的归还规则只有一条：**取用时谁分配谁交出，份额随句柄走**。写入口只搬字节、不 retain，故写入方
  须自带一份（别名点先 retain）；这一份由写入口消费 —— 落槽则转给容器，不落槽（重复元素、既有键）则当场归还。
  跨句柄的 retain / release 只经 `pini_handle_*` 与 `pini_nominal_*`，不直接改计数字段。

### 3.2 名义箱

- 头四格是强计数、弱计数、类型标识、弱引用旁表；字段与枚举载荷的索引全由它派生。
- 对象销毁时先标记旁表已死，再释放载荷；旁表由最后一个弱引用撤销时释放。

### 3.3 错误字

- `result` 的错误槽是**类型擦除的一个机器字**：`0` 表示无载荷，其余是错误对象的句柄位型。
- 读它只有 `pini_error_is_cancel` 与 `pini_error_message` 两个入口；它既不可解引用，也不参与计数。

### 3.4 陷阱

- `pini_panic` 以**退出码 1** 终止进程，消息进 stderr，stdout 不动。
- 该退出码与解释器通道对运行时错误的处理同码 ⇒「程序因运行时错误退出」可用单一条判据识别，
  与走哪条通道无关。

### 3.5 路径基准

- 接受路径的族按**程序基准**解析相对路径：以 `/`、`./`、`../` 开头者原样使用，其余拼在基准之后。
- 基准是**入口文件所在目录**的绝对路径，由入口注入一次（`pini_set_program_base`）；
  未注入时退化为进程当前目录。
- 不在编译期把字面量路径拼成绝对路径：那会让字面量与变量走两条路。

### 3.6 并发

- 任务族按能力位自述：不能真让出的宿主把 `pini_task_yield` 报为不可用，`await` 合规降级为占用，
  不报错。
- 取消是协作式的，在让出 / 恢复边界生效。
- 一次 `print` 的输出是**一段不可分割的字节**：发射层用 `pini_print_lock` / `pini_print_unlock` 包住整行拼装，
  并发程序的两行不会互相插入。这个是进程内的锁，跨进程输出不在此保证内。

### 3.7 字符串句柄

- 句柄 = 一份自有拷贝加一个计数。`new` 起始为 1，`retain` / `release` 成对加减，归零时释放拷贝。
- `bytes` 与 `len` 只在句柄存活期内有效；字节视图不以 NUL 为界读，字节数以 `len` 为准。
- Pini 侧不参与这套计数：句柄在 IR 里是 `stringHandle`（份额归 inert），创建点交出那一份，
  C 拿到后自己收账。

### 3.8 建目录

- `pini_ensure_dir` 幂等：目录已存在即成功，不报错也不清空。
- 中间层一并创建；建不出来（权限不足、某个路径分量已是文件）时 `pini_panic`，不返回布尔 ——
  调用方没有「可以继续」的分支可走。
- 路径按 3.5 的基准解析，与 IO 族其余成员同规。

### 3.9 进程

- `spawn` 的入参是**每行一个参数的文本**，首行为可执行。含 `/` 按路径直起；否则经
  `/usr/bin/env` 走 PATH —— 裸名与 shell 同口径，故 POSIX 前提写在此处，不留给调用方猜。
- 文本承载串表是权宜：语言面还没有「集合过外部 ABI」的写法（`Array<T>` 过外部块报 E4-028）。
  补上串表句柄后换签名，本条随之删除。
- `capture` 非零时两路输出落到临时文件、退出时读回；零则子进程继承调用方的 stdout / stderr。
- `wait` 结算一次并缓存：重复问答同一次结果。退出码按 shell 惯例归一，被信号杀死答 `128 + 信号`。
- 两路输出是**句柄内视图**，NUL 结尾、不以长度定界；句柄释放后失效。调用方要留住须自己复制。
- 起不来（可执行不存在、权限不足）即 `pini_panic`，不返错误码：调用方没有「进程没起来但继续」的分支。

### 3.10 行输入

- 一次调用读一行，**行终止符保留**：空行答 `"\n"`、EOF 答 `""`，两者因此可区分。
- `limit` 是字节上限，由编译器传 `IOLimits.maxLineBytes`；切点落在多字节字符中间时按宽容解码
  表示（替换字符），与解释器同一口径。
- 返回计数串（+1），调用方按 `pini_str_release` 归还；不预读、不改标准流状态。
- 拼写只有这一条：发射器不引 `stdin` 与 `__stdinp`，平台差异由 Swift 的 `readLine` 承担。

### 3.11 工具链位置

- `pini_exe_dir` 返回可执行文件所在目录，供工具链定位随行的标准库与运行时库；与程序基准无关。
- 返回值是**借用**指针、活到进程结束，调用方不释放；取不到答空串。

## 4. 零调用点登记

以下符号当前没有发射器调用点。**零调用点不等于该删** —— 每个都是某条路线的锚点。

| 符号 | 数量 | 处置 |
|---|---|---|
| `pini_process_*` | 5 | 待接编译命令：`compile` / `run-llvm` / `test-llvm` 的进程入口，发射器不产出 |
| `pini_ptr_*` | 6 | 保留。LLVM FFI 的预留面，删掉后接 FFI 时无处接线 |
| `pini_task_is_cancelled` `pini_capabilities` `pini_task_yield` `pini_task_state` | 4 | 解释器与宿主观测面，发射器不产出 |
| `pini_str_alloc` `pini_str_header_bytes` `pini_str_refcount` `pini_str_table_min_cap` `pini_handle_shares` `pini_scope_close` | 6 | 只被 ABI 测试或宿主直接调用；`pini_str_alloc` 的拼接调用点已并入 `pini_str_concat` |
| `pini_str_handle_bytes` `pini_str_handle_len` `pini_str_handle_retain` `pini_str_handle_release` | 4 | C 侧读字节与收账的入口；发射器只发 `pini_str_handle_new` |
| `pini_double_bits` `pini_parse_double` | 2 | 只由自举编译器在编译期调用，发射器不产出 |
| `pini_exe_dir` | 1 | 自举工具链经外部块调用：hostproc 按它定位随行标准库与运行时库，发射器不产出 |

本表与编译器侧清单互补：`BuiltinInventory.swift` 列出已接线的 107 条，本表列出其余 28 条，
两者合计即第 2 节的 135。互补关系由 `tools/builtin-inventory-check.py` 校验。

## 5. 维护条款

- 口径是**导出符号数**，故新增或删除 `@_cdecl` 入口时须同批改本表。
- 不为「已定案但尚未落源码」的符号留行 —— 那种行会让等式失真，落地时再加。
- `tools/runtime-abi-check.py` 比对三样：本表的符号集、`PiniRuntime.swift` 的导出集、
  本表声明的合计数。任一处不等即失败。
- `tools/builtin-inventory-check.py` 加第三方：编译器清单 `BuiltinInventory.swift` 与 `CodeGen`
  里的符号引用；同时校验第 4 节与本表互补。

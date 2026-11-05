# 运行时 ABI 契约

- 性质：**宿主级规范**。运行时段对外 C-ABI 的**唯一权威载体**。
- 适用面：一切由生成代码或解释器调用的运行时段入口。符号是 `bk_` 前缀的 C 导出，
  实现文件是 `Sources/PiniRuntime/PiniRuntime.swift`。
- 变更：删改符号先改本件，再改实现；新增符号同批登记。

## 0. 定位与判读规则

### 0.1 权威次序

1. **语言语义**以 `pini-reference-v0.md` 为准；
2. **IR 节点语义**以 `ir-contract.md` 为准；
3. **符号名、族划分与计数**以**本件**为准 —— 其他文档只列族、不复制成员名。

### 0.2 边界纪律

- 本件只写**符号面**：名字、族、调用约定、份额归属与陷阱姿态。
- 不写语言语义（那在参考件），也不写 IR 节点语义（那在 IR 契约）。
- 同一份名单不写第二遍。参考件的运行时一节只承担「有哪些族、各干什么」。

### 0.3 量具口径

**109 = `@_cdecl("bk_…")` 的匹配数**，即导出符号数，不是 `@_cdecl` 的字样出现数。
两者相差 2：正文有两处注释提到 `@_cdecl` 却不导出符号。数出来差 1 或 2 时，先分清数的是哪一个。
器械是 `tools/runtime-abi-check.py`。

## 1. 冻结纪律

- 符号一经落地，改名或改签名须走语言级变更流程，不得为迁就某个后端而漂移。
- **shim 边界必须是 C ABI**，不是宿主语言的原生调用约定 —— 违反即把实现语言变成永久依赖。
- 集合、并发、LazyRef、FFI 共用同一个运行时段，不另设独立 shim。
- 新增符号同批登记本件，等式「清单数 = 导出数」是它唯一的自检方式。

## 2. 符号清单（109 个）

| 族 | 符号 | 数 |
|---|---|---|
| 数组 | `bk_array_append` `bk_array_create` `bk_array_destroy` `bk_array_ensure_unique_at` `bk_array_get` `bk_array_len` `bk_array_set` | 7 |
| 字典 | `bk_dict_contains` `bk_dict_create` `bk_dict_destroy` `bk_dict_ensure_unique_at` `bk_dict_get` `bk_dict_key_at` `bk_dict_len` `bk_dict_set` `bk_dict_val_at` | 9 |
| 集合 | `bk_set_add` `bk_set_at` `bk_set_create` `bk_set_destroy` `bk_set_len` | 5 |
| 句柄 / COW | `bk_handle_ensure_unique` `bk_handle_release` `bk_handle_retain` `bk_handle_shares` | 4 |
| LazyRef | `bk_lazyref_create` `bk_lazyref_destroy` `bk_lazyref_value` | 3 |
| 默认实例 | `bk_given_get` | 1 |
| 指针 | `bk_ptr_load_f32` `bk_ptr_load_f64` `bk_ptr_load_i32` `bk_ptr_load_i64` `bk_ptr_load_i8` `bk_ptr_store` | 6 |
| 展示 / 陷阱 | `bk_cstr` `bk_double_to_string` `bk_panic` `bk_print_lock` `bk_print_unlock` | 5 |
| 运行时 | `bk_runtime_cleanup` | 1 |
| 字符 | `bk_chars` `bk_chr` `bk_is_letter` `bk_is_number` `bk_ord` | 5 |
| 字符串面 | `bk_str_alloc` `bk_str_append_cstr` `bk_str_concat` `bk_str_dup` `bk_str_from_cstr` `bk_str_header_bytes` `bk_str_refcount` `bk_str_release` `bk_str_retain` `bk_string_char_at` `bk_string_contains` `bk_string_count` `bk_string_index_of` `bk_string_lower` `bk_string_slice` `bk_string_split` `bk_string_trim_left` `bk_string_trim_right` `bk_string_upper` `bk_substring` | 20 |
| 字符串句柄 | `bk_str_handle_bytes` `bk_str_handle_len` `bk_str_handle_new` `bk_str_handle_release` `bk_str_handle_retain` | 5 |
| 闭包 / 结构体胶水 | `bk_nominal_alloc` `bk_nominal_release` `bk_nominal_retain` `bk_slot_alloc` | 4 |
| IO / 宿主查询 | `bk_append_file` `bk_argv` `bk_exists` `bk_is_dir` `bk_list_dir` `bk_module_root` `bk_read_file` `bk_set_program_base` `bk_try_append_file` `bk_try_read_file` `bk_try_write_file` `bk_write_file` | 12 |
| 任务 / 并发 | `bk_capabilities` `bk_scope_close` `bk_task_cancel` `bk_task_detach` `bk_task_is_cancelled` `bk_task_join` `bk_task_join_all` `bk_task_join_all_box` `bk_task_join_within` `bk_task_spawn` `bk_task_yield` | 11 |
| 阻塞内建 | `bk_sleep` | 1 |
| 让出族 | `bk_task_await` `bk_task_frame` `bk_task_slot` | 3 |
| 调度驱动面 | `bk_task_bind_sched` `bk_task_state` | 2 |
| 错误载荷 | `bk_cancel_error_create` `bk_error_code` `bk_error_create` `bk_error_from_enum` `bk_error_is_cancel` `bk_error_lookup` `bk_error_message` `bk_error_with_code` | 8 |
| **合计** | | **112** |

## 3. 语义约束

### 3.1 句柄

- 容器、LazyRef、Future 一律不透明句柄，调用方只搬指针，不解读布局。
- 句柄的归还规则只有一条：**取用时谁分配谁交出，份额随句柄走**。写入口只搬字节、不 retain，故写入方
  须自带一份（别名点先 retain）；这一份由写入口消费 —— 落槽则转给容器，不落槽（重复元素、既有键）则当场归还。
  跨句柄的 retain / release 只经 `bk_handle_*` 与 `bk_nominal_*`，不直接改计数字段。

### 3.2 名义箱

- 头四格是强计数、弱计数、类型标识、弱引用旁表；字段与枚举载荷的索引全由它派生。
- 对象销毁时先标记旁表已死，再释放载荷；旁表由最后一个弱引用撤销时释放。

### 3.3 错误字

- `result` 的错误槽是**类型擦除的一个机器字**：`0` 表示无载荷，其余是错误对象的句柄位型。
- 读它只有 `bk_error_is_cancel` 与 `bk_error_message` 两个入口；它既不可解引用，也不参与计数。

### 3.4 陷阱

- `bk_panic` 以**退出码 1** 终止进程，消息进 stderr，stdout 不动。
- 该退出码与解释器通道对运行时错误的处理同码 ⇒「程序因运行时错误退出」可用单一条判据识别，
  与走哪条通道无关。

### 3.5 路径基准

- 接受路径的族按**程序基准**解析相对路径：以 `/`、`./`、`../` 开头者原样使用，其余拼在基准之后。
- 基准是**入口文件所在目录**的绝对路径，由入口注入一次（`bk_set_program_base`）；
  未注入时退化为进程当前目录。
- 不在编译期把字面量路径拼成绝对路径：那会让字面量与变量走两条路。

### 3.6 并发

- 任务族按能力位自述：不能真让出的宿主把 `bk_task_yield` 报为不可用，`await` 合规降级为占用，
  不报错。
- 取消是协作式的，在让出 / 恢复边界生效。
- 一次 `print` 的输出是**一段不可分割的字节**：发射层用 `bk_print_lock` / `bk_print_unlock` 包住整行拼装，
  并发程序的两行不会互相插入。这个是进程内的锁，跨进程输出不在此保证内。

### 3.7 字符串句柄

- 句柄 = 一份自有拷贝加一个计数。`new` 起始为 1，`retain` / `release` 成对加减，归零时释放拷贝。
- `bytes` 与 `len` 只在句柄存活期内有效；字节视图不以 NUL 为界读，字节数以 `len` 为准。
- Pini 侧不参与这套计数：句柄在 IR 里是 `stringHandle`（份额归 inert），创建点交出那一份，
  C 拿到后自己收账。

## 4. 零调用点登记

以下符号当前没有发射器调用点。**零调用点不等于该删** —— 每个都是某条路线的锚点。

| 符号 | 数量 | 处置 |
|---|---|---|
| `bk_ptr_*` | 6 | 保留。LLVM FFI 的预留面，删掉后接 FFI 时无处接线 |
| `bk_dict_contains` | 1 | 保留。`collection.contains` 已在类型层声明为 trait 方法，降载未实现，本符号是接线点 |
| `bk_task_is_cancelled` `bk_capabilities` `bk_task_yield` `bk_task_state` | 4 | 解释器与宿主观测面，发射器不产出 |
| `bk_str_refcount` `bk_handle_shares` `bk_scope_close` `bk_runtime_cleanup` | 4 | 只被 ABI 测试或宿主直接调用 |
| `bk_str_handle_bytes` `bk_str_handle_len` `bk_str_handle_retain` `bk_str_handle_release` | 4 | C 侧读字节与收账的入口；发射器只发 `bk_str_handle_new` |

本表与编译器侧清单互补：`BuiltinInventory.swift` 列出已接线的 90 条，本表列出其余 19 条，
两者合计即第 2 节的 109。互补关系由 `tools/builtin-inventory-check.py` 校验。

## 5. 维护条款

- 口径是**导出符号数**，故新增或删除 `@_cdecl` 入口时须同批改本表。
- 不为「已定案但尚未落源码」的符号留行 —— 那种行会让等式失真，落地时再加。
- `tools/runtime-abi-check.py` 比对三样：本表的符号集、`PiniRuntime.swift` 的导出集、
  本表声明的合计数。任一处不等即失败。
- `tools/builtin-inventory-check.py` 加第三方：编译器清单 `BuiltinInventory.swift` 与 `CodeGen`
  里的符号引用；同时校验第 4 节与本表互补。

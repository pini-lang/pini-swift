# Pini 下一轮演进路线图（Next-Round Roadmap）

> 状态：P0–P7 已全交付（v0.25.0+，623 XCTest + 38 swift-testing / 0 失败）。本文是 P0–P7 之后的**新一轮**规划，承接 P0–P7 交付收口。
>
> 战略定位（已在上一轮对齐、写进 `MEMORY.md`）：**COW 优先、MOVE 暂不做**。Pini 是中文友好的「应用 / 脚本 / 领域建模」静态类型语言，站位为 **Swift 系（值 struct + ARC 对象 + 扁平可读）**，非 Rust 系。
>
> 变更治理：本路线图落地的任何语法 / 语义变更，必须经 spec v0 的 RFC/ADR 轻量流程，并 bump 版本。规范单一事实源地位不变。

---

## 0. 两个必须先纠偏的前提（避免方案建在错误假设上）

| # | 用户原表述 | 事实核查 | 结论 |
|---|-----------|---------|------|
| P-A | "为 TOML 支持 `#` 注释" | `pini.toml` 解析器 `FileLoader.parseManifest`（`FileLoader.swift:122`）已 `line.hasPrefix("#")` 跳过注释；TOML 原生即支持 `#` | **伪需求，无需做**。真缺口是跨模块依赖只记录不解析 + 清单格式选型（见 T2）。 |
| P-B | "管道风格的可用性" | spec/草稿**无** `|>` 前向管道运算符。现存 `|` 仅用于：① 方法 self 修饰 `方法名\|self()`；② 草稿已废弃的 `[名称\|import]`/`[类型名称\|export]`；③ 逻辑或 `\|\|` | 需先对齐意图：是想要**新的 pipe-forward 运算符**，还是排查**现有 `\|` 语法 / 多行续行的可用性**（见 T3）。 |

---

## 1. 候选主题清单（含 RICE 评估）

评分量纲：Reach(R,1–5) × Impact(I,0.5/1/2/3) × Confidence(C,0.5/0.8/1) ÷ Effort(E,人周约数 1–8)。RICE 越高越优先。

| ID | 主题 | 对应来源 | R | I | C | E | RICE | 一句话价值 |
|----|------|---------|---|---|---|---|------|-----------|
| **T1** | 诊断体系现代化（错误+警告） | 用户① | 5 | 2 | 1.0 | 3 | **3.3** | 引入 warning 层级 + 稳定错误码(E0xxx) + 跨度下划线 + 修复建议；当前 `PiniError` 只有 error、无 warning、消息裸字符串 |
| **T5** | 形式文法 + 运算符优先级 | gap 1.1/1.2/1.3 | 4 | 3 | 1.0 | 3 | **4.0** | ✅ 已并入 spec 附录（形式文法 EBNF + 优先级表，v0.43.0）；形式文法唯一载体为 spec 附录（原草案与事实基线文档已删除） |
| **T9a** | 代码格式化器 `pini fmt` | 工具链 | 5 | 2 | 1.0 | 3 | **3.3** | 依赖 T5；统一代码风格、可被编辑器/LSP 复用 |
| **T6** | 标准库扩充 | 实践缺口 | 5 | 2 | 0.9 | 4 | **2.25** | `map/filter/reduce/forEach`、JSON 序列化、日期时间、正则、更多字符串/数学方法 |
| **T2** | 模块化深化（依赖解析 + 清单格式） | 用户② | 3 | 3 | 0.7 | 6 | **1.05** | **部分交付（G52，2026-08-28）**：模块边界 / 无环依赖图 / `import` 语义 / 清单**双通道**（`require` 模块 / `resources` 资源）+ `tap` + `replace` 已决议落档；清单格式已定（沿用 TOML，不立 `.pnmod`），`[dependencies]` 移除。**剩余**：宿主实现、MVS 与 `pini-summary.toml` 生成、`pini mod` 命令集、远程抓取 |
| **T4** | COW 写时复制 | 锁定方向 | 3 | 3 | 0.9 | 6 | **1.35** | 大集合/大 struct 赋值共享 buffer、首写分裂；服务现有用户、契合 Swift 站位（下一轮头条） |
| **T7** | 异步语义正式化（G12→Stable） | 稳定性 | 2 | 2 | 1.0 | 2 | **2.0** | 异步语义已落入 `Pini草稿.md`（异步函数块），spec v0 G12 升级 Stable 时直接吸收草稿；executor/结构化并发/取消语义定稿 |
| **T8** | 性能与后端成熟 | P7-5 续 | 3 | 2 | 0.7 | 6 | **0.7** | SSA / 内联 / 死代码消除（P7-5 仅常量折叠）；解释器热点优化；LLVM vs 解释器取舍 |
| **T10** | 自带测试框架 `pini test` | 工具链 | 3 | 2 | 0.9 | 4 | **1.35** | ✅ **已实现（G41，v0.42.0）**：`\|test` 函数块 + `assert` 内建 + `pini test` 子命令 + SwiftTesting 宿主 |
| **T3** | 多行 / 管道语法可用性 | 用户③ | 3 | 1.5 | 0.5 | 2 | **1.13** | 先排查：显式续行符、长表达式跨行、`\|` 语法易用性；再决定是否引入 pipe 运算符（需先定 P-B 意图） |
| **T11** | 诊断本地化（中文一致） | 体验 | 3 | 1 | 1.0 | 1 | **3.0** | 错误消息中英混杂；对"中文友好"定位，统一中文（或双语 `-–lang`） |
| **T12** | REPL 成熟 | P7-1 续 | 2 | 1.5 | 0.9 | 2 | **1.35** | 多行编辑、历史、Tab 补全；当前 REPL 基础 |
| **T13** | 小 ergonomics 收口 | gap 2.5 | 2 | 1 | 1.0 | 2 | **1.0** | 元组解构/元素访问已实现（批次 1）；剩余：类型推断范围文档化（`iota()` 已于 v0.29.0 移除） |
| **T14** | FFI / 互操作 | 生态 | 2 | 3 | 0.4 | 10 | **0.24** | ✅ **解释器优先已落地（ADR-015，Phase 2a，v0.48.2）**：`[名称\|foreign]` 块 + 预注册原生函数表（malloc/free/memcpy/memset/strlen/puts/strcmp/cstr）+ `*T`/`&`/`unsafe`/`\|unsafe` + `load`/`store`/`addressof`。剩余：dlsym 动态符号解析、LLVM 端 FFI、`&` 真引用语义、被嵌入场景 |

> 注：候选主题 T1–T14 为已对齐的演进方向（RICE 评估见上）。`Pini草稿.md` 表达的**意图候选项**（块标签 redesign / for-in / 扩展块 / 路径枚举 / defer 定义 / step 同步）是另一类——属自由意图通道、尚未采纳、不构成排期承诺，统一在 §6 轻量跟踪，对应 spec 已知缺口登记与意图候选项。

---

## 2. 建议的 Now / Next / Later 分组

### Now（下一迭代，低风险高价值，可立即启动）
- **T1 诊断体系现代化**：用户①，RICE 最高且为纯增量（不破坏现有语义）。含 warning 层级 + 错误码 + 跨度高亮 + "did you mean"。
- **T5 形式文法 + 优先级**：一次性补齐规范根基，解锁 T9a/formatter 与未来 fuzzer。
- **T11 诊断本地化**：极低成本，与 T1 同源推进最划算。
- **T7 异步语义正式化**：把待清理文档回写为权威附录，消一个"待清理"项。

> Now 目标：**把"能跑"升级为"可信 + 好读"**。这些项都不引入破坏性语法变更。

### Next（中期，需设计决策）
- **T6 标准库扩充**：`map/filter/reduce` + JSON 是高频刚需，独立可验证。
- **T9a 格式化器**：依赖 T5 落地后做，复用文法。
- **T4 COW 写时复制**：按锁定方向起草 RFC/ADR（G 新编号），先集合后大 struct。
- **T3 多行/管道**：先完成排查 + 定 P-B 意图，再实现（可能是"加续行符"而非"加 pipe 运算符"）。
- **T2 模块化**：清单格式与四条规则已由 **G52** 定稿（不另立 ADR，随 G52 走；决议见 `issue-module-system-rules-2026-08-28`，D1–D18）。下一步 = **宿主实现**（依赖图构建 + 环检测 + MVS + 校验和），清单格式选型争议已终结。

### Later（远期 / 独立立项）
- **T8 性能与后端成熟**：SSA/内联需审慎，避免与 COW 收益重叠。
- ~~**T10 自带测试框架**~~：✅ **已实现（G41，v0.42.0）**——`pini test` + `|test` + `assert` + SwiftTesting 宿主。
- **T12 REPL 成熟**、**T13 小 ergonomics**：穿插在 Next 中按需消化。
- **T14 FFI**：✅ 解释器优先已落地（ADR-015，Phase 2a）——`foreign` 块 + 原生函数表 + `*T`/`unsafe`；LLVM 端 FFI 与 dlsym 动态解析为后续。

---

## 2.5 长期愿景：自举纯 libc（北极星指引）

> 权威锚点：`pini-spec-v0.md`（阶段 2 C-ABI 版本化 / 阶段 3 自举纯 libc + 自举前置检查清单）。本节为执行指引：自举不是 RICE 候选排期项，而是长期北极星——以 Pini 自身重写 `libPiniRuntime` 的 `@bk_*` C ABI 面，最终用户程序只依赖 libPiniRuntime（乃至纯 libc）。

**已实现愿景支撑（2026-08-24 检查）**：
- **C ABI shim 边界已守住**：`@bk_*` 仅接受/返回 C 兼容类型，`RuntimeBackendTests` 三执行路径锁步（解释器 / `lli`-JIT / `clang`-AOT）防 Swift 类型泄漏；
- **语言侧核心构件已就位**：`ok`/`err` + `match`、泛型单态化、`LazyRef<T>`（引用语义，统一 ptr ABI wrapper）、`|test` + `assert` + `pini test`（自举后用自身写宿主测试）；
- **`@bk_*` 目标清单已固化**：`bk_handle_*` + `bk_array_*` + `bk_dict_*` + `bk_set_*` + `bk_lazyref_*`（对应 `PiniRuntime.swift` 的 `@_cdecl` 面）。

**自举前置依赖**：
- **T14 FFI / 内存管理（已部分满足）**：自举需调用 libc（`malloc`/`free`/`memcpy`）并操作不透明指针——**解释器优先已落地（ADR-015，Phase 2a）**：`[名称\|foreign]` 块 + 预注册原生函数表 + `*T`/`&`/`unsafe`/`\|unsafe`。剩余前置：LLVM 端 FFI、dlsym 动态符号解析（当前 shim 保持 Swift 实现）。
- C-ABI 版本化（阶段 2）在有真实第二后端需求前不提前固化（spec：C-ABI 阶段 2 规则）。

**对日常决策的指导**：
1. 任何新增运行时能力（集合/并发/LazyRef/工具内建）都应走 `@bk_*` C ABI 面——不改签、不引入 Swift 专有类型，保持自举终态可达；
2. 语言新特性评估「自举可用性」：自举编译器（用 Pini 写的 Pini 编译器）是否能用它表达宿主实现需求；
3. 治理上：向自举收敛的决策记入 spec，避免在多处分散表述。

---

## 3. 需拍板的开放决策

1. **P-B 管道意图**：是想要全新的 `|>` pipe-forward 运算符，还是只排查现有 `|` 语法/多行续行可用性？（决定 T3 是"加特性"还是"做可用性排查"）
2. **T2 清单格式**：维持 TOML 并扩充自研解析器（支持数组/版本约束），还是迁移到自建 `.pnmod` 格式（用 `;` 注释与语言一致）？建议走 **ADR** 定夺。
3. **T4 COW 范围**：~~本轮先做到"集合 COW"还是一并覆盖"大 struct COW"？~~ **已落地（v0.38.0，G34）**：集合 COW 值语义完成（`cow.pini`）；大 struct COW 未排期。
4. **Now 边界确认**：T1/T5/T11/T7 是否作为下一迭代的 Now 承诺？（T5 草案已交付，见 §1）

---

## 4. 建议先启动的轻量交付物

- T2 manifest 格式决策（TOML 扩 vs .pnmod）——决策直接钉入 spec，不另立 ADR 文档
- T4 COW 范围与语义（已落地 v0.38.0，G34）——决策直接钉入 spec，不另立 ADR 文档
- spec v0 附录：形式文法 EBNF + 运算符优先级表（T5，EBNF 草案已交付，已于 v0.43.0 并入 spec 附录）
- spec v0 附录：异步语义契约（T7，吸收 `Pini草稿.md` 异步函数块细则）
- 诊断错误码登记表 `diagnostic-codes.md`（T1）——**已落地**（v0.44.0 批次 A：`DiagnosticProviding` + TOML 语言资源；权威映射规则见 spec，本 md 为派生的迟维护视图）

---

## 5. 与"待清理"文档的关系

上一轮已标记 17 个 P0–P7 遗留文档为「待清理」，已于 2026-08-12 随 `Pini草稿.md` 意图澄清一并删除（异步语义契约现落于草稿，spec v0 G12 升级 Stable 时直接吸收）；本文件与之不再有依赖。

> 验收门槛沿用 P2 起的惯例：`examples/*.pini` 经 `ExamplesConformanceTests` 全绿，任何破坏示例 `check` 的改动视为未通过。

---

## 6. 草稿意图候选项（未采纳，轻量跟踪；G35/G36/G40/G41 已采纳移出）

> 本节将 `Pini草稿.md` 意图通道表达的意图候选项接入演进进程做**轻量跟踪**（对应 spec 已知缺口登记与意图候选项；G35/G36 已于 v0.39.0 采纳转正，见 §6.2 历史注记）。
> 这些**尚未采纳**，不构成排期承诺；草稿是自由意图通道，未来可能继续演化（含破坏性改动）。
> 若未来某候选要立项，须走 spec 变更治理并 bump 版本，以届时评审与草稿最新状态为准。

### 6.1 候选项 ↔ 缺口 ↔ 路线图 映射

| 意图候选项 | 缺口（spec） | 路线图候选 | 来源草稿章节 | 与现况关系 |
|-----------|----------------|-----------|-------------|-----------|
| ~~块标签 `#label`→`@label` + `#` 文档注释~~ | G35（**已采纳 v0.39.0**） | v0.39.0（已实施） | 「#文档注释符」「块内语法·@标识符」 | 破坏性迁移 `while#`→`while@`（codemod 9 处） |
| ~~`for-in` 迭代~~ | G36（**已采纳 v0.39.0**） | v0.39.0（已实施） | 「块内语法·for ... in」 | 逆转 G17/README:242 非目标 |
| 扩展块语法 | G37 | （候选，未排期） | 「[[扩展枚举块]]」等 | 新增，依赖 G8 |
| 路径枚举 | G38 | （候选，未排期） | 「[路径枚举|关键字]」 | 新增 |
| `defer` 正式定义 | G39 | （候选，未排期） | 「defer 块退出前清理:」 | 定义既有实现 |
| `step:` 规范同步（已落地更正） | G32（已更新） | — | 「step:」 | 事实更正 |
| **元组解构** `var (t, e) = rhs` | （spec 已登记，v0.42.0 批次 1 落地） | ✅ **批次 1（已实现）** | 「(元组,)」 | 纯新增；`TupleDestructureTests`；复用 for-in 模式元组产生式（parseFor） |
| **元组元素访问** `.0` / `.名称` | （spec 已登记，v0.42.0 批次 1 落地；含命名元组标签） | ✅ **批次 1（已实现）** | 「(元组,)」 | 纯新增；`.0` 经 Lexer/Parser 允许 `.` 后整数；命名标签经类型层 tuple labels |
| **`^` 右值糖**（解包/err 控制返回） | （spec 已登记，v0.42.0 批次 1 落地；类型糖 `^T` 已实现 spec D3） | ✅ **批次 1（已实现）** | 「Result<结果类型>」 | 纯新增；`^` 三重身份（中缀位异或/类型糖/右值糖）登记消歧规则；`ResultUnwrapTests` |
| **if/elif/else 同级块匹配** | （spec 已登记，v0.42.0 批次 2 落地） | ✅ **批次 2（已实现）** | 「if 单行单表达式:」等 | 澄清；parseIf 同级缩进校验加固 |
| **match 子块缩进 + `case _:` 通配 + 可达性检查** | **G28（已更新，v0.42.0 批次 3 落地）** | ✅ **批次 3（已实现）** | 「match 模式单行单表达式:」「case 值:」 | **结构性破坏**：case 缩进进 match 子块、通配改 `case _:`、default 随 G28 更新废弃；14 示例 + 20 测试迁移（§6.3） |
| ~~`Lazy<懒加载类型>`（懒加载值）~~ | G40（**已采纳 v0.42.0**，转正为 `LazyRef<T>`：`.value` once / 引用语义 / 双后端；`.valueFuture` 已抛弃） | v0.42.0（已实施） | 「Lazy<懒加载类型>」 | 纯新增；`LazyRef<T>(闭包)` / 推断糖；`examples/lazyref.pini` |
| ~~`测试函数块 |test`~~（测试函数块必须显式声明 `|test` 标记） | G41（**已采纳 v0.42.0**：`pini test` 子命令 / `assert` 内建 / 通用访问控制 / 参数注入零值 / SwiftTesting 宿主） | v0.42.0（已实施） | 「测试函数块必须显示声明|test」 | 纯新增；`examples/test.pini` |

### 6.2 若未来采纳，可能的次序（非承诺）

1. ~~**批次 1：元组一揽子 + `^` 右值糖**~~（元组解构 / 元素访问 `.0`+`.名称` / `^` 解包）——✅ **已实现**（v0.42.0 落地）。
2. ~~**批次 2：if/elif/else 同级块**~~——✅ **已实现**（v0.42.0 落地）。
3. ~~**批次 3：match 子块结构（G28 更新）**~~——✅ **已实现**（v0.42.0 落地，结构迁移见 §6.3）。
4. G39 `defer` 定义：低风险治理清理，把既有实现钉为权威语义。
5. G37/G38 扩展块/路径枚举：纯新增，依赖 G8 trait 约束求解先落定。
6. ~~**批次 4：Lazy + test 块（G40/G41）**~~——✅ **已实现并转正**（v0.42.0：`LazyRef<T>` + `\|test`/`assert`/`pini test`；另有 G42 Ref 系引用语义修复，见 §6.6）。

> **历史注记（批次进度）**：批次 1-4 已全部落地并转正——G35/G36（v0.39.0）、批次 1/2/3（元组/`^`、if-elif 同级块、match 子块结构）、G40/G41/G42（v0.42.0）均已采纳并移出本节（见 §6.1 删除线；细节归档 `CHANGELOG.md`）。本节剩余候选：G37/G38/G39（见 §6.2 第 4-5 条）。

### 6.3 治理清理 backlog（非新意图，须跟进）

- **match 示例迁移**（批次 3 结构性破坏）：✅ **已完成（2026-08-23，commit 9fdc20b）**——14 示例 + 20 测试文件全量迁移（`case _:` 通配、穷尽性内建 R1），闭合张力 T6。
- **`step` 规范滞后**：✅ 已同步为已落地（2026-08-18）。
- **`iota` 表述**：✅ 已确认属错误并删除（G10 已于 v0.29.0 移除）；草稿可自由表达意图，进入 spec 时须评审。

### 6.4 批次 3 实施记录（match 子块结构，G28——✅ 已实现 v0.42.0）

**现况**：`case` 缩进进 match 子块；通配兜底=`case _:`；`default:`/pass 通配子块已移除；穷尽性检查**总是开启**（R1，枚举缺变体且无 `case _:` → `nonExhaustiveMatch`）；字面量 match 未命中且无 `case _:` 时静默（R3）。14 示例 + 20 测试文件已迁移（commit `9fdc20b`）。权威语义见 spec；迁移细节归档 `CHANGELOG.md`。

### 6.5 批次 4 决策记录（Lazy / test 块，2026-08-24 全部拍板并落地，见 §6.6）

> 批次 4 决策已全部拍板（2026-08-24）并随 spec 变更治理（§1.3）落地（v0.42.0，G40/G41 转正）。

**G40 `Lazy<懒加载类型>` → `LazyRef<T>`（✅ 已转正 v0.42.0，2026-08-24；`.valueFuture` 已按用户决策抛弃）**：

> **方向（2026-08-24 用户表态并落地）**：标准库通用延迟类型 `LazyRef<T>` 对象——`.value` 同步阻塞获取（内部锁保证 once）。`.valueFuture`（返回 Future）**已于 2026-08-24 抛弃**，LazyRef 仅保留同步 `.value`。

| # | 决策点 | 落定（2026-08-24） |
|---|--------|----------|
| D1 | 构造语法 | `LazyRef<T>(初始化闭包)` 显式优先 + `LazyRef(闭包)` 推断糖（双形态，解释器 + LLVM） |
| D2 | `.value` 触发点 | 成员访问即触发（once 锁求值缓存）；引用语义优先（struct 字段复制共享引用） |
| D3 | ~~`.valueFuture`~~ | **已抛弃（2026-08-24 用户决策）**——LazyRef 仅保留同步 `.value` |
| D4 | 线程安全 | 解释器 NSLock + 标志；LLVM `libPiniRuntime` `bk_lazyref_*`（once 锁） |
| D5 | 实施范围 | 先解释器后 LLVM 两批（S0-S2 解释器含 WeakRef 修复，S3 LLVM） |
| D6 | 转正 | v0.42.0 转正（spec 已定义 Provisional） |

**G41 测试函数块 `|test`**（✅ 已转正 v0.42.0，2026-08-24；R1-R5 全拍板落地）：

| # | 决策点 | 候选方案 |
|---|--------|----------|
| R1 | 测试发现与执行 | **已拍板（2026-08-24）**：新增 `pini test` 子命令——收集顶级 `|test` 函数块逐一执行，汇总通过/失败报告（退出码 0/1/2）；`Interpreter.runTests` 为运行时入口 |
| R2 | 判定机制 | **已拍板（2026-08-24）**：新增 `assert` 内建，参数由实现设计：`assert(条件: Bool,)` / `assert(条件: Bool, 消息: String,)`——条件 false 抛 `RuntimeError.assertionFailed`（缺省消息 "assert failed"），测试运行器捕获为失败；LLVM 端经 `@bk_panic` 终止（双后端「以错误终止」语义对齐） |
| R3 | 私有符号访问 | **已拍板（2026-08-24）**：暂使用通用访问控制机制（测试函数可访问同级可见性符号） |
| R4 | 函数形态 | **已拍板（2026-08-24）**：允许参数注入——`pini test` 按参数声明顺序注入**类型零值**（I32→0 / F64→0.0 / Bool→false / String→"" / 无标注→null）；注入协议后续可按名/按上下文扩展 |
| R5 | 与宿主测试关系 | **已拍板（2026-08-24）**：宿主测试使用 SwiftTesting（swift-testing）驱动 `.pini` `|test` 函数块（Package.swift tools-version 5.9→6.2 升级，新增 `PiniSwiftTests` target） |

> **✅ 已实现（2026-08-24）**：S0 tools-version 升级 → S1 语法/语义基底（`|test` 两形式解析 + 语义接受 + 参数允许）→ S2 assert 内建（解释器 + LLVM 双端）→ S3 `pini test` 子命令（含参数注入）→ S4 SwiftTesting 宿主端到端 → S5 示例/文档/全量验证。见 §6.6 批次 4 实施记录。
> **✅ 已转正（v0.42.0）**：spec 登记 `|test` 函数块 + `assert` 内建（Provisional）；spec G41 缺口行已采纳；roadmap §6.1 移出。

**G42 `Ref 系类型引用语义`（WeakRef 语义缺陷治理 + LazyRef 架构约束，2026-08-24 用户提出）**：

**缺陷证据（WeakRef 现状，已核实代码）**：
1. **值拷贝分裂**：`copyIfStruct`（Interpreter.swift:875）深拷贝 `.structInstance` → `var b = a` 复制出**新 WeakRef 包装实例**，但 `_target` 是 `.objectReference(obj)`（非 struct 原样返回）→ 包装值拷贝、内部引用共享，语义分裂；
2. **弱引用计数不对称**：构造 `arcManager.weakRetain(obj)` 恰 1 次（Interpreter.swift:1171），复制 N 份不 retain；
3. **无释放路径**：`weakRelease` 全库无调用点，StructInstance 无 deinit → 弱引用表条目永不清理（泄漏）；将来补释放后 N 份各 release 与单次 retain 不对称（虽有 `max(0,-1)` 兜底）。

**决策（2026-08-24 已拍板）**：
- **Ref 系类型（WeakRef / LazyRef）为引用语义**：独立 `Value` case + class 承载（**不用 `.structInstance`**，避开 `copyIfStruct` 深拷贝），复制即共享同一状态；
- **LazyRef**：共享「锁 + once 标志 + 缓存」，满足「object 缓存共享 + 多线程仅一次初始化 + 循环引用可解」；
- **WeakRef 修复**：改为引用语义承载 + 对称弱引用计数（retain/release 配对）+ 释放路径（引用计数归零时 weakRelease）。
- 修复与 LazyRef 实现同批次（G40 批次 4 前置/并行），见 §6.6。

### 6.6 批次 4 实施计划（LazyRef G40 + WeakRef 修复 G42，2026-08-24 细化）

**目标语义**：
- `LazyRef<T>`（标准库通用延迟类型，**引用语义**）：`.value` 同步阻塞获取（内部锁保证 once，首访执行初始化闭包并缓存、后续返回缓存）；多线程首访仅一个线程执行初始化；复制共享同一 box（引用语义承载，草稿「struct 复制强制求值」不适用于引用语义，见 D2）。
- `WeakRef` 修复（G42）：引用语义承载 + 对称弱引用计数 + 释放路径，消除值拷贝分裂 / 计数不对称 / 表泄漏。

**架构决策（2026-08-24 已拍板）**：
- Ref 系（WeakRef/LazyRef）**引用语义**：独立 `Value` case + class 承载（非 `.structInstance`，避开 `copyIfStruct` 深拷贝），复制即共享同一状态；
- LazyRef 共享「锁 + once 标志 + 缓存」；WeakRef 补齐 retain/release 配对与释放路径（引用计数归零触发 weakRelease）。

**决策（2026-08-24 已全部拍板；`.valueFuture` 已按用户决策抛弃）**：

| # | 决策点 | 拍板 |
|---|--------|------|
| D1 | LazyRef 构造语法 | **两者兼有，显式优先**：`LazyRef<T>(初始化闭包)` 显式泛型构造为主，`LazyRef(闭包)` 类型推断为语法糖 |
| D2 | `.value` 触发点 | 成员访问即触发（once 求值缓存）；**引用语义优先**——LazyRef 作 struct 字段时复制共享同一引用（草稿「结构块复制时强制求值」不适用于引用语义承载） |
| D3 | ~~`.valueFuture`~~ | **已抛弃（2026-08-24 用户决策）**：LazyRef 仅保留同步 `.value`（曾设计「共享缓存 Future」，已撤销） |
| D4 | 线程安全实现 | 解释器：`NSLock` + 初始化标志（once）；LLVM：`libPiniRuntime` 加 `bk_lazyref_*`（once 锁） |
| D5 | 实施范围 | **先解释器后 LLVM（两批）**：S0-S2 解释器（含 WeakRef 修复 S0），S3 LLVM 端 |
| D6 | WeakRef 修复范围 | **已定**：承载改造（.structInstance→独立 case）+ 对称计数 + 释放路径，全部纳入（S0 前置） |

**影响面**：
- `Value.swift`：新增 `.lazyRef` / `.weakRef` case（class 承载）→ 波及所有 `switch value` 的代码（Interpreter / SuspendEvaluator / Stringify / TypeChecker / CodeGen 等，逐一补 case）
- `ARCManager`：弱引用计数对称 + 释放入口
- 成员访问：`.value` / `.valueFuture`（LazyRef）、`.target` / `.isAlive`（WeakRef 迁移）
- LLVM 端：`libPiniRuntime` 新增 `bk_lazyref_*` C ABI（含 once 互斥）；WeakRef 如无 LLVM 支持则先仅解释器

**分阶段步骤（文件级）**：
1. **S0 WeakRef 修复**（G42）：Value 新增 `.weakRef(WeakRefBox)` case 承载 → 构造/成员访问迁移 → 对称 weakRetain/weakRelease（Box 引用计数归零释放）→ 现有 WeakRefTests 迁移 + 新增「复制共享」「计数对称」「释放不泄漏」测试。
2. **S1 LazyRef 构造 + `.value`**：`.lazyRef(LazyRefBox)` case（锁 + once 标志 + 缓存 + 闭包）→ 构造特判 → `.value` 成员访问（once 求值缓存）→ 单测（首访一次 / 二次缓存 / 并发仅一次）。
3. **S2 `.valueFuture`**：D3 拍板后实现，复用 `FutureValue`。
4. **S3 LLVM 端**：`bk_lazyref_create/value/value_future` + codegen 成员访问发射 → 双后端锁步测试。
5. **S4 示例 + 文档 + 全量**：`examples/lazyref.pini`、roadmap/spec G40/G42 落板、全套件验证。

**验收标准**：双后端锁步一致；LazyRef 并发单测（多线程仅一次初始化）；WeakRef 复制共享 + 计数对称 + 释放不泄漏（ARCManager 表无残留）；全套件（931 + 新增）全绿。

> **✅ 已实现（2026-08-24，941 XCTest + SwiftTesting 41 全绿；G40 已转正 v0.42.0）**：
> - **S0** WeakRef 修复（G42）：`.weakRef(WeakRefBox)` 引用语义承载 + init weakRetain/deinit weakRelease 对称配对 + 释放路径；WeakRefTests 9/9。
> - **S1** LazyRef 构造 + `.value`（解释器）：`.lazyRef(LazyRefBox)`（NSLock + once + 缓存）；D1 双形态（显式 `LazyRef<T>(闭包)` + 推断糖）；`.value` once 求值；LazyRefTests 6/6。
> - **S2** ~~`.valueFuture`~~（共享缓存 Future）——**已抛弃（2026-08-24 用户决策）**，相关代码/测试/文档全部撤销（commit b339d56）。
> - **S3** LLVM 端：libPiniRuntime `bk_lazyref_create(5参)/value/destroy` + codegen 类型特化 wrapper（`@__lazyref_wrapper_<T>(ptr code, ptr env, ptr out)` 统一 ptr ABI）；`.value` 三执行路径锁步；RuntimeBackendTests 51/51。
> - **S4** examples/lazyref.pini（run + run-llvm 双入口）+ ExamplesRunTests 黄金登记。
> - **转正**（v0.42.0）：spec 登记 LazyRef（Provisional）；spec G40 缺口行已采纳；roadmap §6.1 移出；printVersion → 0.42.0。
> - 提交：1bb6189（docs）→ 8713d42（S0+S1）→ 631f42f（S2 已撤销）→ 352299e（S3）→ c1daa24（S4）→ b339d56（抛弃 .valueFuture）→ 转正。

### 7 结构化并发契约（G12 实施细则）

异步执行模型（G12，ADR-012）的结构化并发由以下**不变契约**保证，具规范事实源地位；完整理由与过渡见既有并发设计记录。

**`await` / `wait` 挂起 await 语义（已落地）**：`await expr`（异步体内）/ `wait expr`（同步上下文）求值 `expr` 得 `Future`，返回 `Result<T, Error>`（错误即数据，不抛出）。
- **挂起模式**（suspend 后端，`SuspendScheduler`）：Future 未决时当前任务**挂起**——保存续体、释放当前 OS 线程（非阻塞），Future 决后经 executor 从**精确恢复点**续跑；CPS 求值器支持任意表达式深度挂起、已执行副作用**不重跑**（`print(await f())` 恰打印一次）。Future 已决则直接取 `ok/err` 值，不挂起。
- **同步/阻塞路径**（默认后端，`GCDScheduler`）：`wait` 为阻塞 join（占 worker 线程），语义与挂起等价——均经 `await`/`wait` 站点解构 `ok/err`。挂起模式是**新增能力**，默认行为不变。
- `joinWithin(t, ms)` 为带超时**阻塞** join，超时归约为 `err(CancelError)`，不受挂起模式影响（探针边界，见下）。

- **B2-1 取消树（父子结构）**：每个 `Future` 是取消树节点；spawn 时父强持有子、子弱引用父（无保留环）。父被取消时递归取消全部子；父已取消后新登记的子立即取消（不漏网）。取消树即派发树，与调用方是否保留子句柄无关。
- **B2-2 父返回自动取消**：任务体结束（正常返回 / 抛错 / 被取消）时，取消所有**未 join 且未完成**的子任务，保证子生命周期不超出父、零泄漏；已 join 的子经 `detachFromParent()` 脱离父约束（兼剪枝，避免 `children` 无界增长）。
- **joinAll 聚合（fail-fast）**：多 `Future` 聚合为单个 `Future`；任一成员 `err` 立即以该 `err` 返回并取消其余未完成任务；成员 `cancel` 经 `onCancel` 联动取消（父子链不被篡改）。
- **失败传播（甲，严格结构化）+ `detach` 出口**：函数体 `return` 即 scope 的**显式 join 边界**——一个从未被 `await`/`wait` join、也未被 `detach`、却 resolve 为 `err` 的子任务，其失败在该边界上浮：scope 收口例程（`closeScope`）收集 leaked 失败，若局部结果本为 `ok(v)` 则翻为 `err(aggregate)`（**唯一有界 override**，正当性来自「失败不得泄漏」；错误始终是值、可被 `match` 解构，非异常注入）。已 `await`/`wait` join 的错误在 join 站点已被 `ok/err` 解构，不再计入父失败。「未 join 被取消」属预期（不记失败），「未 join 失败」才须上浮，二者不可混淆。**`detach(future)`** 为 Spine 级内建（非 Layer-2 库类型）：将子任务从父 scope 剪枝、**主动退出所有权**（结局不再归父所有，既不触发上浮、也不被 B2-2 取消）——fire-and-forget 的唯一合法出口，使（甲）可逆。
- **协作式取消**：取消不强杀线程，于下一个挂起 / resume 边界生效——挂起模式在 **resume 边界统一检查点**（任务被取消经 `onCancel` 即时唤醒、resume 入口 `checkCancellation` 见 cancelled 即抛 `CancelError` 终结；即使挂起等待的 Future 永不 resolve / 已 `detach`，取消也即时生效）；同步/阻塞路径检查点位于循环头 / 函数入口 / 睡眠分片。**非挂起即不可中断**（同 Swift）：紧循环不挂起则循环中不可被打断，循环头/回边检查仍保留。`CancelError` 经 `Result` 显式传播，不穿透 `try/except`。
- **挂起模式上下文还原（MUST）**：挂起/恢复跨线程（work-stealing 复用 OS 线程）时，continuation 必须捕获并还原解释器线程上下文 `{currentEnv, currentFuture, deferStack, debugDepth, callStackNames}`，否则上下文串台（类比 Swift `Executor` 上下文 / Kotlin `CoroutineContext`）。已落地（`SuspendTaskCPS`，`SuspendEvaluator.swift`）。
- **探针边界（显式报错，不静默错）**：挂起模式暂不支持泛型构造实参内的 `await` 及 `callFunctionValue` 特殊形态（枚举构造 / Optional / WeakRef）在含 `await` 实参下的逐形复制；此类路径报「挂起模式暂不支持」。`joinWithin` 保持阻塞语义（上）。完整 CPS 化覆盖 match / try / for / labeled 实参 / break / continue 内挂起（已支持并经同步/CPS 差分测试逐字节对齐）。

---

## 8 本轮批次登记（2026-09 轮次）

> 登记缘由：本轮（批 1 / 1.5 / 2 / 3）此前**只存在于会话上下文**，未落档，导致范围与变更不可审计。本节按 §6.4–6.6 既有「批次实施记录」体例补登记，并设变更规则（见 §8.4）。

### 8.1 批次登记表

| 批次 | 范围（IN） | 明确排除（OUT） | 前置 | 出口条件 | 状态 / 实测 |
|------|-----------|----------------|------|---------|------------|
| **批 1**（G52 模块系统语义层） | 块形式 import/export 为唯一顶级形态（裸语句移除）、R2 依赖环检测、R4 限定 `alias.symbol` 跨模块访问（仅 public）、R1 物理边界（`pini.toml`） | MVS、`pini mod` 命令集、远程抓取（属 T2 剩余） | — | gate 五关 + 全量测试 | ✅ 已落地：`0f10319` / `5e8acfa`（宿主）、`2eefa3c`（自举同步） |
| **批 1.5**（跨行字面量，A12 方案 B） | 普通括号内 NEWLINE 等同空白、缩进不参与；块携带括号（开括号同行紧跟 `func`）布局照常 | `< >` 深度跟踪；IIFE/实参位块体的任何语义变更 | 批 1 | L0/parse 差分门禁 + 全量测试 | ✅ 已落地：`03ce2df` / `8bc2560`（宿主）、`a35a037`（自举）。宿主 1103/0；L0 MATCH 508、parse 222+94、自举 70/0 |
| **批 2**（G48 下标三通道） | `a[i]` 安全断言（panic E5-005）/ `.get(i)` 安全可选（`.none`）/ `unsafe .getUnchecked(i)` 不安全（UB）；三类型一致；**解释器端** | LLVM 端通道 2/3 实现；字典类型名规范 | 批 1.5 | 同上 + 迁移后门禁 | ✅ 已落地：`cbdd479` / `64c2531` / `031adca` / `8ed57c3`（宿主）、`8a1ae62`（自举）。宿主 1105/0 |
| **批 3**（括号内记法收口） | 实参标签 / 字典条目 / 元组标签 / 枚举具名构造改用 `=`；旧 `:` 记法报错并给迁移提示；match 具名绑定保留 `:` | 形参声明与类型标注；空字典字面量（走类型构造） | 批 2 | 同上 + 迁移后门禁 | ✅ 已落地：`ad10773` / `cbeec25` / `831b3db`（宿主）、`d96c996`（自举）。宿主 1116/0 |

**出口条件（每批固定，不逐批另设）**：①宿主全量 `swift test` 0 失败；②`gate.sh` 五关 GREEN（L0 diff_tokens / parse ×2 / `pini check` / `pini test` / host-gap 台账）；③基线重标定后**重跑门禁自校验**；④两仓提交分离（宿主 / 自举）。

### 8.2 变更记录（计划修正案）

> 规则见 §8.4。两次修正案均已获用户批准，此处补登记以恢复可审计性。

| # | 修正案 | 触发证据 | 性质 | 批准 |
|---|--------|---------|------|------|
| **AM-1** | 批 1.5 实现判据由「深度>0 即抑制」改为**路 C（块携带括号标记制）** | 语料普查：`LazyRef<I32>(func …:` 括号内块体（3 处合法在用）+ 畸形夹具（`[Bad1\|notakw`）8 行 | **改变已批准方案的判据**（原方案会杀死合法代码） | 2026-09-01（用户裁决路 C，依据草稿 IIFE 语法） |
| **AM-2** | 批 3 D-3：枚举具名构造同步 `=` | 与 `f(a = 1)` 同属实参绑定；不同步则同括号两种记号 | **触及已钉定规范面**（G54，2026-08-29 钉定且已实现） | 2026-09-02（用户「按你的建议来」） |

### 8.3 §1.3 治理债清偿清单（本轮三批均未走完五步）

对照 spec §1.3「提议 → 影响评估 → 登记 → 落地 → 证据登记」：

| 步骤 | 批 1.5 | 批 2 | 批 3 | 清偿动作 |
|------|--------|------|------|---------|
| ①提议（动机/影响面/破坏性） | ✅ 工单 | ✅ 工单 | ✅ 工单 | — |
| ②影响评估 / 破坏性升级评审 | ✅ 非破坏性 | ✅ ADR-028 影响评估表 | ✅ ADR-029 影响评估表（含 G54 触及说明） | 已清偿（2026-09-02） |
| ③§3 缺口登记 | ✅ G55 | ✅ G56（G48 行另已修订） | ✅ G57（规则 3.15 另已修订） | 已清偿（2026-09-02） |
| ③ADR（决策理由） | 不需要（非破坏性） | ✅ ADR-028 | ✅ ADR-029 | 已清偿（2026-09-02） |
| ④spec 章节 | ✅ | ✅ | ✅ | — |
| ④`Pini草稿.md` rationale 同步 | ❌ | ❌ | ❌ | 补同步 |
| ④README / 示例 | ❌ 示例未加跨行用法 | ✅ | ✅ | 批 1.5 补示例 |
| ④迁移说明 | 不需要（新增能力） | ✅ `migration-2026-09.md` §A | ✅ `migration-2026-09.md` §B | 已清偿（2026-09-02） |
| ⑤证据登记（`evidence-table.toml`） | ❌ | ❌ | ❌ | 补登记（符号定位 + `validated_at`） |
| 版本 bump（路线图条款：语义变更须 bump） | ❌ | ❌ | ❌ | 仍 `0.50.0`，待清偿后统一 bump |

### 8.4 变更规则（本轮起生效）

1. 凡**改变已批准方案的判据**，或**触及已钉定（Pinned）规范面**的发现 → 必须先登记为**计划修正案**（含证据出处 + 批准时点），**批准后方可继续**，不得边做边改。
2. 每批开工前须在本表登记：范围 IN / OUT、前置、出口条件；出口条件沿用 §8.1 固定四项，不逐批另设。
3. 每批完工须走完 §1.3 五步后再标记 ✅；未完成项记入 §8.3 治理债，**不得隐性挂账**。
4. 单批内的阶段推进（spec → 实现 → 迁移 → 门禁）**逐阶段向用户报告并等待确认**，不连续执行。

### 8.5 待开工（均须先走 §1.3 ①②）

| 项 | 提议载体 | 状态 | 备注 |
|---|---------|------|------|
| **F5 块文法钉定**（缩进块 + 顶格块 + 括号内记号流三维度） | `docs/spec/issue/issue-de-facto-grammar-pinning-2026-08-30.md` §F5（Proposed, 2026-08-30） | 待排期 | 提议已存在，缺影响评估与排期 |
| **IO 相对路径基准**（`readFile`/`writeFile` 现按进程 CWD；`import` 按模块根，双基准并存） | **缺**（待新建 §1.3 提议） | 待提议 | 候选方案：A 按模块根（破坏性）/ B 仅暴露 `moduleRoot()` / C 运行时切 CWD / D 仅文档约束 |

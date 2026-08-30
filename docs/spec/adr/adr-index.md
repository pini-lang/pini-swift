# ADR 索引（ADR Index）

> **性质**：受 `pini-spec-v0.md` §7 治理的配套登记表。代码注释中引用的 `ADR-NNN` 必须在此可兑付（redeemable）；缺失或悬空的 ID 视为注释违规（spec §7.4）。
>
> **ADR-024 后本表为「登记表」而非「目录」**：语言级 ADR 落 `docs/spec/adr/`，宿主级落 `docs/adr/`，自举实施细则落 `examples/selfhost/docs/`。**编号全局共享**——代码注释引用裸 `ADR-NNN`，ID 空间不分层，否则 L6 兑付崩溃。
>
> **层级图例**：
> - `语言级` — 改变语言契约（语法 / 语义 / 诊断码语义 / 标准库契约 / 项目布局）。完成标志：spec v0 相应章节已修订 + 证据登记。
> - `宿主级` — 改变 pini-swift 的实现方式（架构 / 后端 / 性能 / 工具 / 分发 / 测试基建）。完成标志：代码落地 + 测试通过。
> - `自举级` — 仅对 `examples/selfhost` 生效的项目约定与实施细则。
> - `治理级` — 元治理决策（规范与仓库的组织方式本身）。
>
> **状态图例**：`active` = 当前生效；`reversed` = 已被后续 ADR 撤销/改写（注释中若仍出现，须理解为历史语境，不得作为当前行为依据）。

| ADR | 层级 | 标题 | 状态 | 定义位置 |
|---|---|---|---|---|
| ADR-001 | 语言级 | 运行时值分裂与 COW 判定（`shares` / 集合原生 COW） | active | 注释语境推导（§2） |
| ADR-008 | 语言级 | 并发后端抽象（GCD 无关、集合后端、`Scheduler` 协议边界） | active | 注释语境推导（§4.3） |
| ADR-009 | 语言级 | 并发调度脊柱（`Scheduler` 协议抽象 + CPS 化可恢复求值器） | active | 注释语境推导（阶段 A / §8 / §8.2） |
| ADR-012 | 语言级 | 异步 join 表层（`await`/`wait` 前缀取代 `<=` 前缀，v0.41.0） | active（曾逆转立场 B） | `../CHANGELOG.md` v0.45.0；spec 状态表 |
| ADR-013 | 语言级 | 块标签语法（`scope 块标签:`，v0.41.0） | reversed（被 ADR-014 逆转） | spec / 注释语境推导（v0.41.0） |
| ADR-014 | 语言级 | 控制流标签语法反转（`scope label:` → `标签\|关键字`） | active | `../pini-landing-plan-v048.md` §ADR-014；spec G44 |
| ADR-015 | 语言级 | 采纳 FFI & unsafe 子系统 | active | `../pini-landing-plan-v048.md` §ADR-015；spec §2.7 |
| ADR-016 | 语言级 | 解析器声明上下文收紧（规则 3.2 / 3.14 / 3.15） | active | `../pini-landing-plan-v048.md` §ADR-016 |
| ADR-017 | 宿主级 | Phase 2b 解释器 dlsym 动态加载 | active | `../pini-landing-plan-v048.md` §ADR-017；`docs/CHANGELOG.md` v0.48.3 |
| ADR-018 | 自举级 | 自举验证契约与项目风格（Bootstrap Validation Contract & Project Style） | **部分被 ADR-024 取代** | `adr-018-bootstrap-style.md`（M1/M2/D1 及自举成功定义已撤销，ID 保留可兑付） |
| ADR-019 | 语言级 | Unicode 字符模型与字符谓词集（grapheme 钉住 / Char 两阶段 / IDENT 续字符放宽 / 三谓词三层对齐） | active | `adr-019-unicode-char-model.md` |
| ADR-020 | 语言级 | 内建特征化（`collection` 最小面 / 内建双层 / 单点登记 / 归组表 / 缓冲惯用法 / 特征内 unsafe 消耗点；COW 机制推迟） | active | `adr-020-builtin-traits.md` |
| ADR-021 | 语言级 | 宽松词法（未知字符兜底单字符 IDENT / 字符串三边界宽松 / 畸形数字回退 / 标识符规则一致性；错误报告后移解析语义；词法段 E1-001/E1-002 移除） | active | `adr-021-bootstrap-lex-diagnostics.md` |
| ADR-022 | 宿主级 | 分发策略（源码分发用户自建 / 仅 macOS / 零签名 / LLVM 后端随宿主 / 自举跟随宿主可移植性） | active | `../../adr/adr-022-distribution-strategy.md` |
| ADR-023 | 语言级 | 具名枚举关联值与 match 解构（具名声明/标签构造/位置·具名·`_` 解构；单绑定=第 1 位（破坏性）；arity → E4；含「实现先于 spec」的流程越界记录与事后追认） | active | `adr-023-named-associated-values.md` |
| ADR-024 | 治理级 | 规范治理归位——撤销元仓、三层规范模型与自举探针定位 | active | `adr-024-spec-governance-relocation.md` |

## 备注

- 本表为**最小登记表**：ID → 层级 → 标题 → 状态 → 定义位置，使代码注释里的 `ADR-NNN` 可追。**第一列必须是 `ADR-NNN`**——`hooks/comment-lint.sh` L6 依赖首列做兑付匹配。
- **层级与定义位置可以不同**：ADR-018 标记为自举级（其内容规范自举项目），但文件落在 `docs/spec/adr/`，以保证既有注释中的 ID 兑付不中断（ADR-024 挂账 7）。
- `reversed` 类（ADR-013）在旧注释中仍大量出现，属历史语境；注释清理时保留 ID 但删除其附带的版本号叙事（见 `pini-comment-style-guide.md` §9 P3）。
- 2026-08-27 治理收口：全仓 180 处 `ADR-NNN` 引用（集中在 `PiniCore` 并发 / FFI / 解析器）**全部可兑付**，`comment-lint.sh` L6 已作为门禁挂 pre-commit 与 CI（大小写不敏感，堵 `adr-` 小写盲区）。
- **2026-08-30（ADR-024）**：登记表自 `pini-meta` 迁至本目录；`comment-lint.sh` 中的登记表路径同步改为 `docs/spec/adr/adr-index.md`，L6 门禁恢复。

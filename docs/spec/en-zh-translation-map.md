# zh↔en Translation Map（中英翻译对照表）

> **定位**：Pini 项目文档英文化（zh→en）的翻译对照表，沉淀自 pini/ 脚手架英文化作业（ADR-018 D3：pini/ 为英文项目）。
> **用途**：后续任何 zh→en 文档翻译作业先查本表，保证译法一致、避免一词多译。
> **与 glossary 分工**：`pini-glossary.toml` 管**术语规范引用**（`{term:key}`，供诊断消息 / 文档引用、机器可追溯）；本表管**翻译对照**（zh→en 词对 + 上下文备注），不承担引用契约。
> **新增词对**：翻译作业遇到本表未收录的对应，补入对应分类并提交（走 pini-meta 变更治理）。

## 1. Git 协作

| 中文 | English | 上下文 / 备注 |
|---|---|---|
| 单一事实源 | Single Source of Truth | 约定文档定位语 |
| 仓库级协作约定 | project-level collaboration convention | — |
| 贡献者注册表 | Contributor Registry | §2 专名 |
| 唯一标识 | unique ID | 命名规则：human:\<handle\> / agent:\<handle\> |
| 规范身份 | canonical identity | 固定 user.name / user.email |
| 提交者名称弹跳 | committer-name bouncing | 防弹跳动机 |
| 防弹跳 | anti-bouncing | 纪律名 |
| 主干保护 | trunk protection | 受保护分支 |
| 特性分支 / 修复分支 | feature branch / fix branch | 分支前缀 |
| 引用名（ref） | ref name | git 禁用 `:` 于分支名 |
| 短横线小写描述 | hyphen-lowercase description | slug 规则 |
| 基线 | baseline | 从最新 main 切出 |
| 集成回 | integration back | 合回主干 |
| 保留分支拓扑 | keep branch topology | --no-ff 理由 |
| 历史改写 | rewrite history | 共享分支禁止 |
| 冲突解决 | conflict resolution | 本地解决 |
| 提交信息约定 | commit message convention | Conventional Commits |
| 现在时、祈使 | present tense, imperative | commit 语气 |
| 多行正文 | multi-line body | 空行分隔 |
| 草稿提交 | draft commit | 用 chore: 兜底 |
| 钩子 | hook | pre-commit / comment-lint |
| 一次性，仅本地 | one-time, local only | hooksPath 启用 |
| 绝对路径 / 相对路径 | absolute path / relative path | hooksPath 必须绝对 |
| 工作树 | worktree | — |
| 主工作树 / 次要工作树 | primary worktree / secondary worktree | — |
| 链接工作树 | linked worktree | .git 为链接文件 |
| 对象库 | object store | 共享 .git |
| 单工作树 / 多工作树 | single worktree / multi-worktree | 拓扑形态 |
| 独立仓库 | standalone repo | 单 .git 无挂接 |
| 摘除工作树 | remove worktree | 勿直接 rm |
| 排障 | troubleshooting | — |
| 目录分叉 | directory fork | 排障场景 |
| 子模块 | submodule | 宿主拉取方式（ADR-018 D1） |
| 版本锚点 | version anchor | .pini/version / pini.toml spec 字段 |
| 逻辑引用 | logical reference | 跨仓库引用，不写物理路径（M1） |
| 远程 | remote | push / fetch 目标 |

## 2. 项目与语言工程

| 中文 | English | 上下文 / 备注 |
|---|---|---|
| 项目清单 | project manifest | pini.toml |
| 钉住的规范版本 | pinned spec version | pini.toml spec 字段 |
| 兼容性承诺锚点 | compatibility commitment anchor | spec 字段语义 |
| 可执行入口 | executable entry | [[bin]].entry |
| 顶级交替（根） | top-level alternation (root) | Pini 语言结构 |
| 阶段占位 | stage placeholder | src/main.pini 占位 |
| 依赖拓扑序 | dependency-topological order | ADR-018 G1 重述顺序 |
| 临时约定 | provisional convention | T9a 落地前 |
| 续行 / 行宽 | line continuation / line width | 格式约定 |
| 括号内换行 | parenthesized wrapping | 续行策略 |
| 声明头文档注释 | declaration-head doc comment | `#` 分级 |
| 行尾注释 | line-tail comment | `;` 分级 |
| 公开契约面 | public contract surface | `#` 用途 |
| 符号型稳定 ID | stable symbolic ID | ADR-NNN / G## / E5-xxx |
| 版本号叙事 | version narrative | 注释禁止（L4） |
| 动词短语 | verb phrase | 方法命名 `动词\|func` |
| 类型体 | type body | struct/object/enum 字段区 |
| 扩展块 | extension block | ((T)) 等，同文件约束 |
| 结构块 / 对象块 / 枚举块 | struct block / object block / enum block | 类型形态 |

## 3. 治理与验证

| 中文 | English | 上下文 / 备注 |
|---|---|---|
| 决策记录 | decision record | ADR |
| 现状 / 决策 / 后果 | Context / Decision / Consequences | ADR 模板 |
| 状态 / 相关 | Status / Related | ADR 模板 |
| 已接受 / 已废弃 / 被取代 | Accepted / Deprecated / Superseded | ADR status |
| 变更治理 | change governance | spec §1.3 |
| 轻量流程 | lightweight process | RFC/ADR |
| 破坏性变更 | breaking change | spec 治理 |
| 演进路线图 | evolution roadmap | roadmap 文档 |
| 已知缺口 | known gaps | spec §3 登记 |
| 权威锚点 | authoritative anchor | 文档层级 |
| 北极星（愿景） | North Star | 长期指引 |
| 终态 / 过渡期 | end state / transition period | 拓扑演进 |
| 回退 | rollback | 自举链回退 |
| 派生视图 | derived view | 派生文档（diagnostic-codes） |
| 权威映射 | authoritative mapping | 权威 TOML |
| 治理 / 登记表 | governance / registry | — |
| 门禁 | gate | CI / lint 门禁 |
| 可兑付 | redeemable | ADR 引用兑付（L6） |
| 承重墙 | load-bearing wall | 差分测试定位（G1） |
| 基线先行 | baseline-first | G1 纪律 |
| 参考语义 | reference semantics | 宿主=参考语义非结构 |
| 黄金文件 | golden file | 字节级对比 |
| 消歧 / 副语言 | disambiguation / secondary language | 术语表 / i18n |
| 单一事实源 | source of truth | 与 §1 同词，此处属治理语义 |
| 已知副作用 | known side effects | ADR-018 Consequences |

## 4. 通用写作（本次作业常见）

| 中文 | English | 上下文 / 备注 |
|---|---|---|
| 对齐 | aligned with | 与宿主惯例对齐 |
| 占位 | placeholder | — |
| 待办 | backlog / pending | 待办登记 |
| 默认 | default | — |
| 显式 / 隐式 | explicit / implicit | — |
| 命名 | naming | — |
| 语法 | grammar | — |
| 制表符 | tab | 禁用 Tab |
| 换行 / 拆分 | wrap / split | 行拆分策略 |
| 契约 | contract | 契约面 |
| 纪律 | discipline | 身份纪律等 |
| 上下文 / 备注 | context / note | 表头 |

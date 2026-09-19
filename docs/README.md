# docs/ — 本仓库文档

**语言级文档**在 **`docs/spec/`**（语言级治理事实源，2026-08-30 自 pini-meta 迁回，见 规范治理归位）。语言面描述由 `spec/pini-reference-v0.md` 承担——两者的权威次序与挂钩点见 `spec/pini-spec-v0.md` 的事实源层级一节与语言细则索引。

| 类别 | 位置 |
|---|---|
| 语言级（SSOT） | `spec/`：pini-spec-v0.md（**工程与治理面**权威 / 首要入口；含项目布局与清单 schema） / pini-reference-v0.md（**语言面**权威 / 成熟成果沉积处） / pini-comment-style-guide.md / pini-glossary.toml / pini-landing-plan-v048.md / diagnostic-codes.md / test-refactoring-principles.md / en-zh-translation-map.md / evidence-table.toml / CHANGELOG.md（语言版本里程碑） |
| 决策记录（ADR） | `spec/adr/`：`adr-<三位编号>-<slug>.md`（编号**自 001 起**，**只增不改**、不复用）。⚠️ 2026-09-19 编号重置：旧一批（018–043）连同索引表**已整体退役**，见该目录 `README.md` |
| 语言级 issue | `spec/issue/`：`issue-*.md`（活跃工单）、`proposal-*.md`（待裁决提案）、`archive/`（已 Closed / LANDED，仅留档不维护） |
| 宿主级 issue | `docs/issue-*.md`（平铺，无归档机制） |
| 宿主级其他 | BUILDING.md / CHANGELOG.md（实现版本演进） |

> 原 `spec/issue/archive/pini-project-spec.md`（项目目录结构）与 `spec/issue/archive/pini-roadmap-next.md`（演进路线图）已于 2026-09-16 归档（文档面收口）：前者的责任移交规范第 8 节（项目布局与清单 schema），后者整体退役。

> `Pini草稿.md`（设计意图与理由稿）位于 `docs/` 根、被 `.gitignore` 排除、**不随本仓分发**，故不列入上表。

> **本表不枚举具体文件名。** 手工枚举必然随新增/归档而漂移（2026-09-02 实测：ADR 表停在某编号而实际已推进数条；宿主级 issue 枚举漏 2 个）。完整清单以目录内容为准。
> ADR 的兑付判据**就是文件本身**（同编号文件存在与否），不再另设索引表——索引与文件是同一事实的两份副本，副本必然漂移。目录约定见 `spec/adr/README.md`。

> 归档约定：语言级 issue 完结（Closed / LANDED）后移入 `spec/issue/archive/` 并加
> `> **ARCHIVED（日期）**` 标记——保留历史、清理台面。宿主级 issue 暂无对应归档目录。

> 层级判据见 决策记录的分层与归属：改变语言契约 = 语言级；改变 pini-swift 实现方式 = 宿主级。

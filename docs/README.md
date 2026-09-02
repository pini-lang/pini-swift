# docs/ — 本仓库文档

**语言级文档**在 **`docs/spec/`**（语言级治理单一事实源，2026-08-30 自 pini-meta 迁回，见 ADR-024）。

| 类别 | 位置 |
|---|---|
| 语言级（SSOT） | `spec/`：pini-spec-v0.md / pini-project-spec.md / pini-comment-style-guide.md / pini-glossary.toml / pini-roadmap-next.md / pini-landing-plan-v048.md / Pini草稿.md / diagnostic-codes.md / test-refactoring-principles.md / en-zh-translation-map.md / evidence-table.toml / CHANGELOG.md（语言版本里程碑） |
| 语言级 ADR | `spec/adr/`：`docs/spec/adr/adr-index.md`（登记表）+ `adr-NNN-<slug>.md`（018 起递增，**只增不改**） |
| 语言级 issue | `spec/issue/`：`issue-*.md`（活跃工单）、`proposal-*.md`（待裁决提案）、`archive/`（已 Closed / LANDED，仅留档不维护） |
| 宿主级 ADR | `adr/`：adr-022（分发策略） |
| 宿主级 issue | `docs/issue-*.md`（平铺，无归档机制） |
| 宿主级其他 | BUILDING.md / CHANGELOG.md（实现版本演进） |

> **本表不枚举具体文件名。** 手工枚举必然随新增/归档而漂移（2026-09-02 实测：ADR 表停在
> `adr-024` 而实际已到 `adr-030`；宿主级 issue 枚举漏 2 个）。完整清单以目录内容为准，
> ADR 的语义登记表见 `docs/spec/adr/adr-index.md`。

> 归档约定：语言级 issue 完结（Closed / LANDED）后移入 `spec/issue/archive/` 并加
> `> **ARCHIVED（日期）**` 标记——保留历史、清理台面。宿主级 issue 暂无对应归档目录。

> 层级判据见 ADR-024 D6：改变语言契约 = 语言级；改变 pini-swift 实现方式 = 宿主级。

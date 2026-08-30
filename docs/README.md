# docs/ — 本仓库文档

**语言级文档**在 **`docs/spec/`**（语言级治理单一事实源，2026-08-30 自 pini-meta 迁回，见 ADR-024）。

| 类别 | 位置 |
|---|---|
| 语言级（SSOT） | `spec/`：pini-spec-v0.md / pini-project-spec.md / pini-comment-style-guide.md / pini-glossary.toml / pini-roadmap-next.md / pini-landing-plan-v048.md / Pini草稿.md / diagnostic-codes.md / test-refactoring-principles.md / en-zh-translation-map.md / evidence-table.toml / CHANGELOG.md（语言版本里程碑） |
| 语言级 ADR | `spec/adr/`：adr-index.md（登记表）+ adr-018/019/020/021/023/024 |
| 语言级 issue | `spec/issue/`：模块系统规则、语法审计等语言级决议 |
| 宿主级 ADR | `adr/`：adr-022（分发策略） |
| 宿主级 issue | `issue-*.md`（平铺）：ffi-module / host-optional-slice / lexer-gaps / lexer-gap-closure / unicode-char-predicates |
| 宿主级其他 | BUILDING.md / CHANGELOG.md（实现版本演进） |

> 层级判据见 ADR-024 D6：改变语言契约 = 语言级；改变 pini-swift 实现方式 = 宿主级。

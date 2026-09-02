# Issue: 测试与示例的命名/结构卫生（2026-09-02 收口批次）

- 状态：**本批已落地 2/4；其余留作独立批次**（2026-09-02）
- 层级：宿主级（pini-swift 仓库内约定，不改语言契约；判据 ADR-024 D6）

---

## 诊断：不是随机劣化，是「在途迁移停在混合态」

`Tests/PiniTests/` 昨日呈现「少数测试文件已文件化、其余仍内联 Pini 源码」的混合态。
根因不是没规范，而是**迁移停在半路**：`docs/issue-inline-pini-extraction-2026-08-31.md`
已拍板方案并跑通试点。看起来像劣化，实际是半拉子工程。

> **2026-09-03 更正**：该工单原记「819 块」经实测证伪——真 Pini 源码仅 **15 块**
> （另有 TOML 配置块 8 个非源码、单行串 290 个抽离无收益）。**本批已完成全部 15 块抽离**，
> 全量 1144 tests / 0 failures，见 `docs/issue-inline-pini-extraction-2026-08-31.md`。
> 教训：据以排期的量化现状，开工前须实测复核。

结论：**不要另起炉灶发明新规范，续推既有工单即可。**

---

## 本批已落地（2026-09-02）

### ① examples 文件命名收口

- 5 个下划线文件 → kebab-case：`array_basic` / `compound_assign` / `control_if` /
  `control_while` / `dict_set_d2`。
- 5 个 `syntax-*` → 归入 `concurrency-*` 族。**判据**：这 5 个文件内容全是并发语义
  （`=>` 声明异步、`wait` 值级等待、Future 句柄、异步传染性终点），头部注释自称「语法点 ①–④」。
  `syntax-` 是按「抽象层级」归类，与按「演示对象」归类的 `concurrency-*` 平行共存，构成伪分类。
- `examples/README.md` 补「文件名：kebab-case + 按特性族加前缀 + 禁横切前缀」规则
  ——**此前该文件只有类型/变量命名约定，无文件命名规则，这是规范空白而非违规**。
- 映射表补登 6 个漏登文件：`enum-named` / `ffi` / `lazyref` / `multidim` / `slice` / `test`。
  校验：磁盘 50 个 `.pini` ↔ README 登记 50 个，双向零差异。
- 同步引用点：`ExamplesRunTests.swift`（黄金表硬编码 5 个）、`docs/BUILDING.md`、
  `docs/spec/pini-spec-v0.md`、`docs/spec/pini-landing-plan-v048.md`、`docs/spec/evidence-table.toml`。

### ② 工单台账维护

- `spec/issue/archive/` 新建，2 个已完结工单移入并加 `ARCHIVED` 标记：
  `issue-d4-deferred-defects`（Closed）、`issue-crossline-literals`（LANDED）。
- `docs/README.md` 文档表**停止枚举具体文件名**：实测 ADR 表停在 `adr-024`（实际已到 `adr-030`）、
  宿主级 issue 枚举漏 2 个。手工枚举必然漂移，改为按目录描述。

门禁验证：`swift test --filter Examples` 4/4 通过。

---

## 遗留：独立批次，不混进本批

### ③ A 域 · 内联 Pini 源码抽离 —— ✅ 已收口（2026-09-03）

- 15 块真 Pini 源码全部抽离为 `.pini` 夹具（ParenEqualsTests 11 + IOTests 4），
  全量 **1144 tests / 0 failures / 20 skipped**。细节见
  `docs/issue-inline-pini-extraction-2026-08-31.md`。
- **原「顺序约束」作废**：此前以「819 块 / 102 文件」为前提论证「抽离必须先于 ④」，
  前提证伪后论证不成立。**④ 不再受 ③ 阻塞**，可按自身节奏立项。

### ④ C 域 · 总结「测试目录单元」规范（待立）

`Tests/PiniTests/` 下 108 个目录**已自发形成一个稳定单元结构**，但从未写成规范：

```
<TestClassName>Tests/
    <TestClassName>Tests.swift   ← 同名测试类
    testXxxBehavior.pini         ← 供其读取的 fixture，与测试函数同名
    testYyyBehavior.pini
```

待办：把这一**已被实践验证**的模式提炼成规范，写进 `docs/spec/test-refactoring-principles.md`
（该文件目前只覆盖测试三要素与注释风格，无目录/fixture 布局约定）。
规模：一次文档增补，排在 ③ 完成之后。

---

## 待核实：10 个无状态字段的存量工单

以下工单**没有状态字段**，无法判断是否完结。本批不逐个读内容核实（成本过高），登记待办：

| 工单 | 行数 |
|---|---|
| `spec/issue/issue-draft-impl-syntax-audit-2026-08-28.md` | 95 |
| `spec/issue/issue-module-system-rules-2026-08-28.md` | 508 |
| `spec/issue/issue-spec-impl-syntax-audit-2026-08-28.md` | 94 |
| `spec/issue/issue-tdd-module-blockers-2026-08-28.md` | 110 |
| `spec/issue/issue-pini-dir-namespace-2026-08-29.md` | （有状态：已批准，落档进行中） |
| `issue-bootstrap-gap-remediation-2026-08-30.md` | 104 |
| `issue-ffi-module-2026-08-27.md` | 78（有状态：Open） |
| `issue-host-optional-slice-2026-08-28.md` | 136 |
| `issue-lexer-gap-closure-2026-08-29.md` | 54 |
| `issue-lexer-gaps-2026-08-28.md` | 99（有状态：Open） |
| `issue-unicode-char-predicates-2026-08-29.md` | 50 |

核实方式：逐个读结论段 → 判 Closed / 仍活跃 → 前者移 `archive/`，后者补状态字段。

---

## 纪律

- **不为便利新增禁令**：本批只收口已被实践验证的模式，不预判式约束未来。
- **同一件事只写一处**：③ 的细节全在抽离工单，本工单仅引用。
- 完结判据：④ 落文档 + 存量工单核实完毕 → 本工单移 `docs/spec/issue/archive/`（宿主级归档目录待立）。

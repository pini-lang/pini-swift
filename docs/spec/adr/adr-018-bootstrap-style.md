# ADR-018: 自举验证契约与项目风格（Bootstrap Validation Contract & Project Style）

## Status

Accepted（2026-08-28）

## Context

Pini 语言启动**编译器自举**：以宿主 `pini-swift`（Swift 实现，充当参考实现与引导编译器）为基座，用 Pini 自身重写编译器（实现仓库 `pini/`），并将语言级治理资产独立为 `pini-meta` 文档治理仓。

**动机**：① 语言成熟度的终极证明——Pini 若能写出自己的编译器，则"中文友好、扁平可读、errors-as-data"等设计主张经受了真实复杂系统的检验；② 自举链的可验证性——Pini 实现的编译器必须与宿主行为等价，否则错误一旦固化进自举链极难排查。

**前置已就绪（2026-08-28 核实）**：宿主工具链可构建可运行（v0.48.4，远程 tag 确认）；FFI/unsafe 解释器端已落地（ADR-015 / ADR-017）；语言侧自宿主构件齐备（`ok`/`err` + `match`、泛型、`LazyRef`、`\|test`）；C ABI shim 边界不泄漏 Swift 类型（spec §3.2 硬约束）。

**需要治理的问题**：两个实现共享同一套语言级资产（spec/诊断码/术语/ADR），但分属独立仓库；纯重述驱动下行为保真不再由结构保真保证；决策若不落档将在多会话间漂移。

## Decision

以下 19 项决策按三层组织，构成自举项目的验证契约与项目风格。决策 ID 供注释/文档稳定引用。

### 表层（仓库 / 工程 / 契约）

| ID | 决策 |
|---|---|
| **D1** | `pini/` 为独立 git 仓库，与宿主无物理耦合；经 git 依赖（submodule `deps/pini-swift`，钉 commit/tag）拉取宿主工具链 |
| **D2** | `pini/` 目录布局遵循语言项目规范（`pini.toml` + `src/` + 入口 + `.pini/version` + `docs/`）；`src/` 内按编译器阶段分子目录：**common**（跨阶段共享基础设施：SourceLocation/Diagnostic/Token）、**ast**（AST 数据模型，多阶段共享的核心领域模型）、**lexer / parser / semantic / type / interpreter**（五阶段管线）、**codegen**（LLVM 后端，分期 M2 占位，含 `[RuntimeCall]` 契约表）——自举项目是规范第一个真实消费者；架构落地见 `pini-bootstrap-architecture.md`（pini-meta） |
| **D3** | **`pini/` 为英文项目**：实现代码、项目文档与代码注释均用英文；用户可见输出（错误消息/诊断）走 **i18n**，中文为第一副语言（仅出现在 i18n 资源与可选的对中文用户发布说明）。五层符号空间：L1 公共 API / L2 内部实现 / L4 文档与注释 英文；L3 用户可见输出 i18n；L5 测试 |
| **D2-注释** | 注释位置约定：`#` = 声明头文档注释（文档契约面）；`;` = 行尾注释（行细节末尾）；lint（L1–L6）复制进各实现仓库 |
| **P1** | 诊断资源机制**过渡式**：短期宿主工具链（Swift）从 `Diagnostics.{en,zh}.toml` 生成 Pini 资源代码，长期迁到语言内 TOML 解析；**诊断码从第一天对齐宿主** |
| **P2** | 差分测试契约粒度：**码 + 位置 + 形状**（诊断码 E5-xxx + 源码位置 + 错误形状），消息文本单独快照；黄金文件（`parse`/`tokens` 输出）始终字节级 |
| **P3** | **全英文零中文标识符**（编译器代码；文档与注释同英文，见 D3）——中文友好的实证点落在 i18n 产品面 |
| **差分骨架** | harness 放宿主 `pini-swift/Tests`（Swift 侧唯一能同时驱动两路径的中立位置：宿主直接执行 corpus vs 宿主加载 `pini/` 编译器再执行 corpus）；corpus = `examples/`，单一事实源在宿主 |
| **工程纪律** | 继承 GIT_WORKFLOW（贡献者注册表 `agent:pini-dev`、分支命名、Conventional Commits、comment-lint pre-commit），各仓库复制 |
| **术语词典** | `../pini-glossary.toml`（TOML 载体）；术语条目挂稳定 ID，诊断消息/文档引用用 `{term:key}` 机器可追溯；条目 `en`/`zh`/`status`/`since` 必填，`alt_zh`/`pos`/`contexts` 可选（消歧） |

### 基因层（代码组织 / 错误建模 / 格式）

| ID | 决策 |
|---|---|
| **G1** | 移植路径**纯重述驱动**：以 spec 为语义契约，用 Pini 惯用法重新组织，不机械翻译 Swift 代码。推论：行为等价性唯一证据 = 差分测试（承重墙）；**行为基线先行**（重述任何阶段前先用宿主产出 corpus 基线快照）；**重述按依赖拓扑序**（Common → AST → Lexer → Parser → Semantic → Type → Interpreter），每层锁步差分；宿主代码 = 参考语义，非参考结构 |
| **G2** | AST 与阶段 pass 组织：**搁置**（独立架构议题，待专门设计）；登记偏好 = 独立 pass 模块 + `match` 模式分发（受"同文件扩展块"语言约束——不能跨文件给类型加方法，P4 模块系统落地前） |
| **G3** | 编译器内部错误建模：**统一诊断枚举**（一个 `Diagnostic` 枚举：码 + 位置 + 参数，全阶段共用）；消息文本在 TOML 资源，代码只写码 + 参数（零裸消息字符串） |
| **G4** | 临时格式约定（T9a 格式化器落地前，记 `docs/code-style.md`）：4 空格缩进、行宽 100、续行保守（T3 未定）。**命名体系（五档，全小写基调）**：① 单词类型全词（`token`/`keyword`）；② 复合类型缩写头 + 下划线（`src_loc`/`str_seg`）；③ 枚举 case / 字段同复合类型（`int_lit`/`l_paren`）；④ 变量 / 参数简短无分隔（`tok`/`loc`）；⑤ 方法完整词 + 下划线（`tokenize_func`）；关键字转义 `kw_` 前缀（`kw_var`）。**理论依据：snake_case 全小写对中英混排标识符唯一自洽**——camelCase/PascalCase 依赖大小写转折作词界，中文无大小写（词界无信号）；下划线显式分隔中英词界。标准缩写表见 `docs/abbreviations.md`（项目级治理） |

### 元项目层（治理 / 托管 / 记忆）

| ID | 决策 |
|---|---|
| **M1** | 单一事实源纪律跨仓库延伸：实现仓库**不复制**语言级资产正文，只持版本锚点（`.pini/version` + `pini.toml` 的 `spec` 字段）+ 逻辑引用（不写跨仓库物理路径，延续注释风格 L3） |
| **M2** | 语言级**文档类**资产独立成仓 `pini-meta/`（可推远程），从宿主"从零开始"迁移（不导入 git 演进史；内容史由 ADR/CHANGELOG 语义化承载）；**数据类**资产（权威 `Diagnostics.{en,zh}.toml` + `examples/` corpus）留宿主实现——元仓库是文档治理仓，非完整语言资产仓；两实现是对称消费者 |
| **M3** | Memory 分层：workspace 根 `.workbuddy/memory/`（跨仓库、不进 git）；决策的持久归宿 = ADR/文档，memory 是易失便签；可复用约定进 `MEMORY.md`、一次性过程进当日便签 |
| **自举成功定义** | **差分全绿 + 能编译自身**（经典自举定义）；"成为默认实现（`pini run` 默认加载 `pini/` 编译器）"为**实现替换触发点**（不再是资产迁移触发点——资产归 pini-meta，与实现解耦） |

### 三仓库引用拓扑

```
pini-meta/（文档治理仓，可推远程）      pini-swift/（实现 A：Swift 宿主）
  docs/ 语言级资产 11 项                 代码 + Diagnostics TOML（权威）
  README / GIT_WORKFLOW / hooks          examples/（= 差分 corpus）
        ▲                                   ▲
        │ git 依赖（spec/术语锚点）           │ git 依赖（工具链 + corpus）
        │                                   │
        └───────────  pini/（实现 B：Pini 自举编译器）  ───────────┘
```

## Consequences

**变容易（增益）**：
- 治理与实现彻底解耦——自举成败不影响语言级资产归属（pini-meta 即终态），"终态迁移"概念消失；
- 差分测试成为行为等价性的唯一证据链（承重墙），配合基线先行 + 拓扑序重述，错误可定位；
- `pini/` 作为语言规范第一个真实消费者，暴露工具链缺口（`pini.toml` 解析、T2 模块化、诊断码跨仓库对齐），"吃自己的狗粮"在语言与元项目两个层面同时生效；
- 术语 ID 机器追溯 + 稳定诊断码，为 T11（诊断本地化）铺平地基。

**变困难（代价）**：
- 纯重述风险高于翻译驱动——行为保真无结构兜底，差分测试是唯一安全网，须严格按拓扑序 + 基线快照推进；
- `pini/` 零中文标识符使 CJK 工具链（LSP/格式化/REPL 输入）支持降为宿主 examples 级验证；
- 已知副作用（待治理）：① pini-swift 的 comment-lint L6（ADR 兑付）因登记表迁至 pini-meta 而跳过，需适配（豁免或跨仓库读表）；② `comment-lint.sh` 各仓库一份副本，防漂移（规则事实源在 pini-meta）；③ `Diagnostics.{en,zh}.toml` 注释中 `../diagnostic-codes.md` 文档名快照为既有内容，未动。

## 相关

- 前置：ADR-015 / ADR-017（FFI 与 unsafe 解释器端）；spec §3.2（C ABI shim 硬约束、阶段 3 自举北极星）
- 产物：`../pini-glossary.toml`（术语表）；`pini/` 脚手架（D2 布局）；差分 harness（宿主 Tests）
- 后续：G2 专门设计（AST 形态 + pass 组织，独立架构议题）

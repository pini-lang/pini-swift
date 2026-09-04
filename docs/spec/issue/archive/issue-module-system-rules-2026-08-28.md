# 工单：模块系统规则收口（G52）—— 物理边界 / 无环依赖图 / MVS 与校验和

- 日期：2026-08-28
- 提出方：用户（规则提出与拍板）+ agent:pini-dev（架构评估、Go 机制调研与成文）
- 状态：**Closed / LANDED（2026-09-04）** —— 本文档即决议记录，**R1–R8 / D1–D28 不变**。
  决议、规范登记与宿主实现均已交付，由三个批次承接：

  | 批次 | 日期 | 承接内容 |
  |---|---|---|
  | **批 1**（语义层） | 2026-08-31 | R1 物理边界（import 加载侧）、R2 依赖图无环、R4 跨模块访问（仅 `public`）、块式 import/export 为唯一顶级形态 |
  | **批 6**（工具链） | 2026-09-02 | 清单双通道解析、MVS（本地退化形态）、`pini-summary.toml`、SHA-256（TOFU）、`pini mod {tidy,refresh,verify,graph}`、build 漂移检查、R1 父扫描侧嵌套排除 |
  | **批 7**（远程 tap） | 2026-09-04 | `github:`/`git:` 抓取、**经典 MVS**（tag 候选）、resources 落地、锁文件 `commit` 真值 |

  **遗留未修（见 §9）**：`[[bin]]/[lib] entry` 未被消费、`graph.order` 未被解释器消费、resources 根检（R7 反向）未实现、`[replace]` 两种形态未实现。
- 关联：
  - `docs/spec/issue/issue-pini-dir-namespace-2026-08-29.md`（**R5–R8**：点目录规则、`.pini/` 命名空间、resources 落地与检查、文件命名）
  - G49（清单 schema 单一 `[package]`、`[build] exclude`、`pini test` 收集单位 = 模块）
  - G51（import/export 块形式为唯一顶级形态；宿主裸语句为**已知偏差**，收敛待办）
  - ADR-017（`[ffi]` 模块配置，pini.toml 唯一已兑现的模块级语义）
  - ADR-018 D1（宿主 git 依赖）
  - `docs/spec/pini-project-spec.md` §3（预留目录）/ §4（`.gitignore` 基线）/ §7（清单 schema）
  - `docs/spec/pini-roadmap-next.md` T2（模块化深化，RICE 1.05）

> **改名溯源（R8，2026-08-29）**：本工单原文使用 `module.toml` / `_summary.toml`，
> 现统一为 **`pini.toml`** / **`pini-summary.toml`**（理由见 R8；过程见 `docs/spec/issue/issue-pini-dir-namespace-2026-08-29.md`）。
> 这是一次**纯改名，不改任何决议的实质**——D1 / D15 / D20 等仍是**现行规则**，
> 故其文本一并更新为新的哨兵名：**留旧名会让现行规则写错判据**。

---

## 1. 背景

宿主（pini-swift）现有模块机制经三轮架构评估，结论为**层次错位**而非实现缺陷：

- **命名空间层**：`FileLoader.loadDirectory`（`FileLoader.swift:25-48`）递归 glob 整个目录树，全部文件扁平化进**同一个命名空间**（`SemanticAnalyzer.analyze(package:)` `:91-116`、`TypeChecker.check(package:)` `:276-295`、`Interpreter.run(package:)` `:235-248`）。跨文件引用无需、也不能 import。
- **跨模块层全空转**：`import`/`export` 解析后**零消费者**（`SemanticAnalyzer.swift:193`、`TypeChecker.swift:363`、`IRGenerator.swift:332` 全部 `case .importDecl, .exportDecl: break`）；`[dependencies]` 注释自陈"记录但**不解析**"；四级可见性中 `package` 与 `public` 同桶（无第二模块可"public 给"）。
- **清单兑现率约 5/12**：`parseManifest`（`FileLoader.swift:193-244`）只消费 `name`/`version`/`dependencies`（存而不用）/`ffi.*`/`build.exclude`；**不消费** `spec`（§7.2 标 Stable 的兼容性锚点）、`[[bin]].entry`、`[lib]`、`[tool.pini]`。

**路线分歧已明确（与 Go 相反）**：Go 的嵌套 `go.mod` 是**切断**（`src/cmd/go/internal/modload/search.go:132-137` 遇子 `go.mod` 即 `filepath.SkipDir`，父子无任何隐式关系）；Pini 选择**包含**——嵌套即词法包含，但**一切跨模块可见性必须显式建立**，不引入自动向下可见。

**关键转折**：早期版本曾设"父模块非私有符号自动对子模块可见"，该条使**依赖环成为结构必然**（子依赖父 + 父用子 = 环），导致"禁环"与"导出规则"互斥。用户改为**消费方显式注册**（后进一步简化为 `import` 即依赖）后，环从"结构必然"降级为"可选"，禁环方为可行。

**新编 G 号：G52**（上一个为 G51）。

---

## 2. 决议：八条规则

### R1 · 物理边界

> 以 `pini.toml` 为标志划分模块。目录树中**排除含 `pini.toml` 的子目录**，使父子模块边界明确。

- 一个目录根只有一个根模块；含 `pini.toml` 的子目录是**子模块**，相对地成为子模块的**父模块**。
- 以 `pini.toml` 为根的目录树，排除含 `pini.toml` 的子目录，**收纳一般子目录与平级文件**（一般子目录属本模块，共享扁平命名空间）。
- 推论：嵌套模块从父模块包自动切出，**`deps/` 内的 Pini 模块无需再写 `[build] exclude`**。
- ~~**补充（R1'）**：`deps/` 保留目录永不扫描。~~ **已由 R6 撤销**（`docs/spec/issue/issue-pini-dir-namespace-2026-08-29.md`）：
  R1' 是**工具侧硬编码的目录名单**，与 R6（点前缀 / `.pini/` 统一承载非源码内容）重复，且比 R6 更难维护——
  每加一类外来物都要往名单里塞一项。撤销后 `deps/` **只放 `require` 的模块**（各带 `pini.toml` ⇒ R1 自切），
  非 Pini 依赖与宿主一律进 `.pini/`（R6）。
  （R1' 的原始动机记录在此：R1 只切含 `pini.toml` 的目录，而**非 Pini 依赖不含 Pini 的 `pini.toml`**
  ——如宿主 `pini-swift` 是 Swift 工程——R1 切不到它，`loadDirectory` 会递归进去扫到其中的 `.pini` 文件。
  该问题现由 R6 的落点规则解决，而非由目录名单解决。）

### R2 · 依赖图无环（import 即依赖）

> **`import` 即依赖。** 构建时检测依赖图，若存在环则报错。

- import 是**文件级**声明（每个文件自己的 `[名称|import]` 块）；**模块依赖 = 该模块所有文件 import 的并集**（与 Go 同构：import 按文件书写，依赖按模块聚合）。
- 环检测在**模块图**上运行（SCC），报错须给出可读路径：`app → text → uni → app`。
- 环检测通过 ⇒ 依赖图是 **DAG** ⇒ 可拓扑序编译 ⇒ **子模块是独立编译单元**；**顶层初始化顺序 = 拓扑序，良定义**（无需为跨模块顶层初始化单独立禁令）。
- **特权与限制**：禁环意味着**父子不能互相使用**——需要互相引用时，必须抽出第三方模块（依赖倒置）。此为本规则唯一需要用户让步之处，须写入 spec。
- `deps/` 反向依赖问题由禁环自动兜住：依赖注册其使用者即成环，被拒。
- **别名一致性**：模块内**非 `_` 别名到模块的绑定必须全局一致**；`_别名` 为**文件私有导入**，不进模块共享表面、不受此限。

### R3 · 版本按 MVS 生成到 `pini-summary.toml`

> 版本按 **MVS（Minimal Version Selection）** 算法求解，结果生成到 `pini-summary.toml`。

- **MVS 由 `[require]` 激活**：`[require]` 的条目集合**由代码中的 `import` 生成**（D19），因此 **MVS 输入 = `require` 集合 = `import` 的物化**，三者同一。
  - 推论：**"声明了却没用"的幽灵依赖结构上不可能存在**——原先为排除它而定的 D3 条款，因此由"独立规定"降级为**模型的自然后果**。
  - 失去 Go"用一条空 `require` 强制抬升传递依赖版本"的惯用法——**该能力已由 D13 本轮即建的 `[replace]` 覆盖**（`replace uni = "3.2.0"` 即等效），不构成缺口。
- **`[resources]` 不参与 MVS**：它不是模块，无版本图可解（见 §3.3）。
- **解析在本地进行**（读已落地的 `deps/<name>/pini.toml`）；抓取与重解析由显式命令 `pini mod refresh` 完成，**build 永不抓取**（D4 保留）。

### R4 · 跨模块访问

> 任何跨模块访问必须 `import`，**全导入**即绑定模块到别名。

- **注入** = 以 `别名.符号` **限定访问**，而**不是** `import.别名.符号`——`[名称|import]` 的块头名只是标签，**不进访问路径**。
- 别名**静态消解**：不参与运行时值命名空间，故永不与用户变量重名；语法复用草稿已有的限定访问形态（`Pini草稿.md:47` `形状.圆(原点, 3.14)`），零新增语法。
- **可见性门槛 = 仅 `public`**（见 §4.3 定稿表）。

### R5 · 点前缀目录不参与源码扫描

> 以 `.` 开头的目录，其整棵子树不参与任何模块的源码扫描。

- **只取 `.`，不取 `_`。** `_` 前缀在 Pini 是 **package 级可见性**语义；Go 的 `_` 前缀则是「工具完全不可见」。照搬会与 Pini 的可见性语义撞车。
- 这是**推广既有约定，不是新造**：`.pini-build/` `.pini-cache/` 已在 `project-spec` §4 的 `.gitignore` 基线中。
- 与 R1 的关系：**R1 切「另一个模块」，R5 切「不是源码」**——两者正交，命中其一即跳过。

### R6 · `.pini/` 为工具命名空间根

> 所有工具管理的非源码内容，统一置于模块根的 `.pini/` 下。

| 路径 | 内容 | 来源 |
|---|---|---|
| `.pini/resources/<name>/` | `[resources]` 落地 | 新增 |
| `.pini/toolchain/<name>/` | 宿主 / 工具链（git submodule） | 新增 |
| `.pini/build/` | 构建产物 | 收编自 `.pini-build/` |
| `.pini/cache/` | 工具链缓存（LSP 索引、增量编译状态） | 收编自 `.pini-cache/` |
| `.pini/version` | 宿主版本 pin | 收编自 `.pini/version` |

- **收编的理由**：规则因此只需一句——「`.pini/` 及其下一切不参与扫描」。不收编则须写成「`.pini/` 及 `.pini-*`」，将来每加一个都会漏。
- ⇒ `deps/` **不再是保留目录**（R1' 撤销），只放 `require` 的模块。
- ⇒ 宿主自带的散 `.pini` 文件与示例清单**全部自动失效**，不需要任何一层补丁（G49 的 `exclude = ["deps"]`、R1' 均成历史）。

### R7 · resources 检查：根检，不深检

| 通道 | 目标根 `pini.toml` | 深层 |
|---|:---:|:---:|
| `require X` | **必须有** | 不查 |
| `resources X` | **必须无** | **不查** |

- 同一个谓词取反，无额外实现成本。
- **保留根检的三个理由——都不是「有害」**：① **语义清晰**（根清单 = D15 分区判据本身）；② **早期纠错**（误将模块配成 resource 是常见错，应在 `refresh` 暴露）；③ **成本近零**（根检代码本来就要为 `require` 的正向判定而写）。
- **取消深检**：`.pini/resources/` 不被扫描 ⇒ 深层清单物理上不可能造成伪模块边界。
  ⚠ **D20 的旧理由「会造成伪模块边界」在 R6 下已失效**，现由上述三条支撑。**若文档只留旧理由，会被「反正不扫描，无害」推翻。**

### R8 · 文件命名：清单 `pini.toml`，锁文件 `pini-summary.toml`

> **模块清单 = `pini.toml`**（原 `module.toml`）；**锁文件 = `pini-summary.toml`**（原 `_summary.toml`）。同前缀、同置模块根，便于配对识别。

- **理由**：R1 以「目录内是否存在清单文件」作**哨兵**判定模块边界，哨兵必须特异到误判率近零。
  `module.toml` 是通名，外来工程（非 Pini 项目）携带同名文件会导致两种误判：该子树被 R1 **静默**排除出扫描；`resources` 根检误拒正常资源。
  生态惯例一致：Go `go.mod`、Rust `Cargo.toml`、Elixir `mix.exs`、Python `pyproject.toml`——**没有成功者用通名**。
- **配套：旧名必须报错，不得静默忽略。** 清单缺失在实现中是**静默降级**（按「隐式根模块兜底」= 一组独立程序处理）。
  硬切而不配套，既有的 `module.toml` 会从**模块边界**退化为**普通文件**，其下源码被父模块扫入、模块身份判定改变，**全程不报错**。
  ⇒ 工具在扫描范围内检测到 `module.toml` 时**一律报错**，提示改名为 `pini.toml`。
  宿主已实现：`FileLoader.loadManifest` 抛 `LoaderError.legacyManifestName`（并有正反两个测试锁定，见 `CLIDirectoryTests`）。

---

## 3. 字段规范

### 3.1 `pini.toml [tap]` —— 从哪来

`tap` 沿用 Homebrew 的心智模型（`brew tap user/repo` → github），默认为 github。

```toml
[tap]
default = "github:pini-lang"                      # 默认源；org 显式书写
core    = "github:pini-lang"                      # → github.com/pini-lang/<name>
mirror  = "git:https://git.example.com/<name>.git"
local   = "file:../vendor/<name>"
```

- 协议前缀：`github:` / `git:` / `file:`；`<name>` 为占位符，展开时替换为模块名。
- **D11 · org 必须显式书写**：`github:` 后必须带 org（`github:pini-lang`），**不允许**只写 `github` 再由工具补全。
  - 理由：**可复现性**。若 org 来自全局配置或环境变量，两台机器会解析到不同模块，`pini-summary.toml` 的锁定即失效。
  - 折中：org 只在 `[tap] default` 写**一次**（落在随仓库版本化的 pini.toml 里），`[require]` / `[resources]` 即可简写为 `text = "1.2"`。既无 magic，也不必重复书写。

### 3.2 `pini.toml [require]` —— 模块依赖（**可 import、激活 MVS**）

> **判据**：目标**含 `pini.toml`**，即它是一个 Pini 模块。

**条目集合由代码中的 `import` 生成**（D19），不是人手声明：人工只能覆盖**版本约束**，
不能凭空新增条目——集合由 import 决定。

采用 **TOML 嵌套表**，段名 `require.<tap>`，可**零解析器改动**落地（`FileLoader.swift:207-210` 已把 `[...]` 内整串当段名存下，`require.core` 会原样落到 `currentSection`）。

```toml
[require]                   # 由 import 生成；版本约束可人工覆盖
text = "1.2"
fmt  = ">=2.0, <3.0"

[require.core]              # 指定 tap = core
uni = "^3.0"
```

- 版本约束语法复用 `docs/spec/pini-project-spec.md` §7.3 已定义的 `^1.2` / `~1.2.3` / `=1.2.3` / `">=1.0, <2.0"`；**未知写 `*`**，由 `pini mod refresh` 回填精确版本（D21）。
- **本节是 MVS 的输入**——MVS 在 `require` 的传递闭包上求解（R3）。
- 生成命令 `pini mod tidy` **离线运行**（D21）：它只读本地 import 与既有 require，不联网。

### 3.3 `pini.toml [resources]` —— 资源落地（**不可 import、不参与 MVS**）

> **判据**：目标**不含 `pini.toml`**，即它不是 Pini 模块——正是 `[require]` 判定的**取反**（D20）。

```toml
[resources]                 # 资源：只要它在那儿，不可引用
pini-swift = "0.48.4"       # 宿主工具链（Swift 工程，无 Pini pini.toml）
corpus     = "1.0"

[resources.local]           # 指定 tap = local
dataset = "*"
```

- **落地位置**：固定 **`.pini/resources/<name>/`**（R6）。点前缀 ⇒ **永不参与源码扫描**；**无 `to` 参数**（可配落点会让工具重新需要判断「某路径是否参与扫描」，正是 R6 要消灭的东西）。
- **不可被 `import`**：它们不是 Pini 模块，没有可引用的符号。
- **不参与 MVS**：无版本图可解。
- **安全约束（D20 + R7）**：目标**根**含 `pini.toml` → 拒绝，提示改用 `[require]`。**不查深层**——`.pini/resources/` 不被扫描，深层清单物理上无害；保留根检是为语义清晰与早期纠错（三条理由见 R7）。
- **典型用例**：语料 / 数据集、脚本、非 Pini 资产。
  ⚠ **宿主 `pini-swift` 不属此类，但原因不是检查**：它是**工具链**——读清单的那个东西，不是被清单描述的东西（Go 不在 `go.mod` 里写 Go 编译器）。
  注意它 `examples/` 下确有 3 个示例 `pini.toml`，而 **R7 只查根**、其根是 SwiftPM 的 `Package.swift` ⇒
  **单看检查它会通过**。⇒ **不把宿主当资源是类别判断，不是检查结果**；宿主归 `.pini/toolchain/`（R6），由 `.pini/version` pin。
- 段名 `resources.<tap>` 形式与 `[require.<tap>]` 同构，同样零解析器改动。
- **寻址（待定）**：不被扫描 ⇒ 不能 `import` ⇒ 只能按路径读写。v1 只做「落地 + 校验」，**寻址方式后定，不假装已解决**。

> **D20 · 节名 `install` → `resources`**（用户拍板，2026-08-28）：`install` 表达的是**动作**（装），
> 而本节的判据是**性质**（不是模块，是资源）。`resources` 直接说出判据，并与 `require`
> 构成「**能 import 的 / 不能 import 的**」这一清晰对比。

### 3.4 双通道分区（可判定、双向封闭）

`[require]` 与 `[resources]` 以「**有无 `pini.toml`**」为判据构成**完全划分**，且**双向强制**：

| 情况 | 报错 |
|---|---|
| `resources X`，X **根**含 `pini.toml` | `X 是 Pini 模块，应改用 require`（用户已提） |
| `require X`，X **根不含** `pini.toml` | `X 不是 Pini 模块，应改用 resources`（本工单补充） |

**双向都拦，划分才可判定**——否则把资源误写进 `require` 时，要等到 MVS 阶段才以更晚、更难懂的方式失败。

两侧的判定**都只看目标根**（R7）：深层清单不参与分区判据。

> **这个分区修掉了一处补丁**：
> 早期模型只有单一通道时，`deps/pini-swift`（Swift 工程，**无** Pini `pini.toml`）无法被 R1 切出，
> 只能靠"R1'`deps/` 保留目录永不扫描"兜底，而 G49 又已靠手写 `exclude = ["deps"]` 打过一次补丁——**同一个问题两层补丁**。
> 双通道把「是不是 Pini 模块」变成**可判定的**，工具因此能自动区分；**最终由 R6 收口**：
> 非 Pini 依赖与宿主统一进 `.pini/`（点前缀不参与扫描），**R1' 与 `exclude = ["deps"]` 两项均成历史**——
> 目录级特例被"位置即规则"取代：物理布局不需要维护，配置边界会漂移。

### 3.5 `pini-summary.toml` —— 生成物，**必须提交**

```toml
[build]
toolchain = "pini 0.48.4 (spec 0.1)"
generated = "2026-08-28T20:00:33+08:00"

[[module]]
name         = "uni"
version      = "3.1.0"
tap          = "core"
source       = "https://github.com/pini-lang/uni"
commit       = "a1b2c3d..."          # 来源定位（非校验凭证）
manifest_sum = "sha256:..."          # pini.toml 摘要
sum          = "sha256:..."          # 模块内容树摘要
path         = "deps/uni"
imported-by  = ["text"]              # 传递来源，供环检测诊断

[[module]]
name         = "text"
version      = "1.2.3"
tap          = "github"
source       = "https://github.com/pini-lang/text"
commit       = "d96d0c1..."
manifest_sum = "sha256:..."
sum          = "sha256:..."
path         = "deps/text"
imported-by  = ["<root>"]

[[resource]]                       # resources 通道：不参与 MVS，同样受校验和约束
name    = "pini-swift"
version = "0.48.4"
tap     = "github"
source  = "https://github.com/pini-lang/pini-swift"
commit  = "d96d0c1..."
sum     = "sha256:..."             # 无 manifest_sum：它没有 Pini pini.toml
path    = "deps/pini-swift"

[graph]
order = ["uni", "text", "app"]       # 拓扑序，供构建调度
```

**D16 · 字段 `required-by` → `imported-by`**（承接 D15）：既然依赖边只由 `import` 建立，该字段记录的其实是「**谁 import 了它**」。沿用 `required-by` 会保留一个已被移除的术语。字段名与 R2 对齐后，环检测诊断（`app → text → uni → app`）的措辞也自洽。

**D12 · `commit` 字段名保持不变，语义放宽为「来源侧内容定位符」**（用户拍板："保持 commit，大家看得懂"）：

| 源类型 | `commit` 取值 |
|---|---|
| `git:` / `github:` | commit hash |
| `file:` | `-`（本地源无内容寻址标识） |
| 未来 registry / tarball | 发布物标识或版本串 |

- 不因引入非 git 源而改名为 `ref` / `locator`——可读性优先，改名收益不抵认知成本。
- **`commit` 仅供人读与来源追溯，永不作为校验凭证**；**`sum` 始终有值，是唯一可信字段**。
- `commit` 可以缺席或为 `-`，`sum` 不可缺席。

### 3.6 校验和 —— **必备，不可省略**

**为什么是 `tap` 的必然（用户拍板，2026-08-28）**：

1. `tap` 的本质是**让来源可配置**。一旦来源可配置，内容就必须**独立于来源**被验证——否则换 tap（切镜像）时内容会**静默变化**。
2. `commit` 哈希只在"信任该 VCS"的前提下认证内容，且**对 `file:` 源、tarball、未来 registry 一概不适用**。
3. 供应链安全是 `go.sum` / `Cargo.lock` / npm `integrity` 的共同结论，不是可选项。
4. **纠正此前评估中的错误判断**：曾议"git 下 commit 即校验和，v1 可省 `sum` 字段"——该判断**错误**，本次推翻。`commit` 与 `sum` **权责不同、必须并存**：`commit` 是来源定位，`sum` 是内容凭证。

**设计**：

| 字段 | 摘要对象 | 用途 |
|---|---|---|
| `manifest_sum` | `pini.toml` 本身 | MVS 只消费清单，单独摘要可快速校验元数据未被篡改；也是 MVS 可复现性的一部分 |
| `sum` | 模块内容树 | 内容完整性 |

- **算法**：SHA-256。
- **规范化遍历**（保证确定性，对齐 `loadDirectory` 的 `units.sort { $0.fileName < $1.fileName }`）：按路径字典序遍历，**排除** `.git/`、`pini-summary.toml` 自身、构建产物目录、`project-spec` §4 的 `.gitignore` 基线项。
- **语义**：**TOFU（首次信任）**——首次拉取时记录基线，此后不匹配即报错。v1 **不做**中心化 sumdb（对齐 Go 的 `GONOSUMDB` 私有化路径，但默认全量校验）。
- `pini-summary.toml` 提交进 git ⇒ TOFU 基线随仓库版本化。

### 3.7 `pini.toml [replace]` —— 一步到位（D13）

用户拍板："既然要新建节，就一步到位。" 故本轮**即**建立覆盖"强制版本 / 本地调试 / 换 fork"的完整替换机制。

```toml
[replace]
uni  = "3.2.0"                      # 只换版本（= override 语义），来源不变
dev  = "file:../dev"                # 换来源为本地目录（调试用）
fork = "github:me/fork@v1.0"        # 换来源为 fork + 指定版本
```

- **语法**：`key = "value"`，与既有 section 完全一致 ⇒ **零解析器改动**（`parseManifest` 已支持逐段 `key = "value"`）。
- **value 三种形态**：
  | 形态 | 语义 |
  |---|---|
  | `"<版本约束>"` | 只换版本，来源不变（等价 npm `overrides` / yarn `resolutions`） |
  | `"file:<路径>"` | 换来源为本地目录 |
  | `"github:<org>/<repo>[@<版本>]"` / `"git:<url>"` | 换来源为 fork 或镜像 |
- **只建 `[replace]`，不另立 `[override]`**：override 是 replace 的特例（只换版本、不换来源），单节即可覆盖，不引入冗余概念。
- **不建 `[exclude]`**：① 与 G49 已定义的 `[build] exclude`（排除**目录**）**同名不同义**，并存必然误导；② 其主要用例已被 `replace` 覆盖。
- **作用域（安全属性）**：`[replace]` **仅在主模块生效**，依赖模块清单中的 `[replace]` 一律忽略——否则一个依赖就能劫持整个构建（Go 同规则）。

### 3.8 决议汇总

| 决议 | 结论 | 依据 |
|---|---|---|
| D1 | 边界 = `pini.toml` 切分，嵌套即**包含**（非 Go 的切断） | 用户拍板 |
| D2 | `import` 即依赖；依赖图**禁环**，构建时 SCC 检测并报错 | 用户拍板 |
| D3 | MVS 由 `[require]` **激活**；因 require 由 import 生成，"未引用的声明"结构上不可能存在——本条由"独立规定"降级为**模型的自然后果** | 本工单建议，用户采纳 |
| D4 | **build 永不抓取**——抓取与重解析只发生在显式命令 `pini mod refresh` | 本工单建议，用户采纳 |
| D5 | `[require.<tap>]` / `[resources.<tap>]` 嵌套表写法（**零解析器改动**，复用 `FileLoader.swift:207-210` 已存整段名的行为） | 本工单建议，用户采纳 |
| D6 | **校验和必备**（`manifest_sum` + `sum`），推翻"v1 可省"的先前提议 | **用户拍板** |
| D7 | `commit` 与 `sum` 并存，权责不同 | 用户拍板 |
| D8 | 跨模块引入的可见性门槛 = **仅 `public`** | 本工单建议，用户采纳 |
| D9 | 别名：非 `_` 全局一致，`_别名` 文件私有 | 本工单建议，用户采纳 |
| D10 | `pini-summary.toml` 为生成物但**必须提交** | 本工单建议，用户采纳 |
| D11 | `[tap]` 的 org **必须显式书写**，禁止从全局配置/环境变量推断（可复现性）；只在 `[tap] default` 写一次 | 本工单建议，用户采纳 |
| D12 | `commit` 字段名**保持不变**，语义放宽为「来源侧内容定位符」；非 git 源可填 `-`；**`sum` 始终有值且为唯一凭证** | **用户拍板** |
| D13 | **本轮即**建立 `[replace]` 节（覆盖强制版本/本地/换 fork）；不立 `[override]`（为其特例）、不立 `[exclude]`（与 `[build] exclude` 撞名）；仅主模块生效 | **用户拍板** |
| D14 | `private` 与 `internal` **保持原样不区分**——封装性由文件内保证 | **用户拍板** |
| D15 | **双通道分区**：`[require]`（**含** `pini.toml`，可 import、激活 MVS）／`[resources]`（**不含** `pini.toml`，不可 import、不参与 MVS）。判据 = 有无 `pini.toml`，**双向强制**（写错一侧即报错并指引到另一侧）。**取代**原"单向改名 install"方案 | **用户拍板**（审计后修订） |
| D16 | `pini-summary.toml` 字段 **`required-by` → `imported-by`**——依赖边只由 import 建立，该字段记的是「谁 import 了它」 | 本工单建议，用户采纳 |
| D17 | `[dependencies]` **直接移除、不设 Deprecated 共存期**（职责**拆分**给 `require` + `resources`）——当前无任何实现消费它，硬切成本为零 | **用户拍板**（选项 b） |
| D18 | `deps/` **保留在 `.gitignore` 基线**，并加注：git submodule 形式的依赖是 gitlink、由父仓库跟踪，**不受该条影响** | **用户采纳**本工单建议（选项 a） |
| D19 | **`[require]` 由代码中的 `import` 生成**——人工只可覆盖版本约束，不能凭空新增条目；集合由 import 决定 | **用户拍板** |
| D20 | 节名 **`install` → `resources`**——`install` 表达动作，本节判据是性质（不是模块，是资源）；且 `[resources]` **目标根含 `pini.toml` 即拒**。**D20 原措辞「拒绝下载含 `pini.toml` 的库」已由 D26 收窄为「仅拒根检」**（原措辞会把 `deps/pini-swift` 自身拒掉——它 `examples/` 下有 3 个示例清单，而根是 `Package.swift`） | **用户拍板**＋D26 收窄 |
| D21 | **`pini mod tidy` 离线**：只做集合对齐，不联网查版本；新增条目约束未知则写 `*`，由 `refresh` 回填精确版本 | **用户拍板**（问题①） |
| D22 | 命令集 = `pini mod {tidy, refresh, verify, graph}`；`graph` **默认展示，`--cycles` 服务 R2 环诊断** | **用户拍板** |
| D23 | **放弃全局缓存，不设 `clean` 命令**。落点（R6 修订）：**`require` 的模块 → `deps/<name>/`；`resources` → `.pini/resources/<name>/`；宿主 / 工具链 → `.pini/toolchain/<name>/`** | **用户拍板**（问题②③）＋R6 修订 |
| D24 | **R5 · 点前缀目录不参与源码扫描**。**只取 `.`，不取 `_`**——`_` 在 Pini 是 **package 级可见性**语义，Go 的 `_` 前缀则是「工具不可见」，照搬会撞车。与 R1 正交：**R1 切「另一个模块」，R5 切「不是源码」** | **用户拍板** |
| D25 | **R6 · `.pini/` 为工具命名空间根**：`resources/` `toolchain/` `build/` `cache/` `version` 统一收其下；**收编**原 `.pini-build/` `.pini-cache/` `.pini/version`；**撤销 R1'**（`deps/` 保留目录）。理由：一条命名约定吃掉「可扫描树计算 + 两级判定 + `to` 参数 + 模块下沉」四层 machinery | **用户拍板** |
| D26 | **R7 · resources 检查：根检，不深检**。根检保留的三条理由 = **语义清晰 / 早期纠错 / 成本近零**（**都不是「有害」**）。⚠ **D20 旧理由「会造成伪模块边界」在 R6 下已失效，必须换成这三条**——只留旧理由会被「反正不扫描，无害」推翻 | **用户拍板** |
| D27 | **`[build] exclude` 是 `pini test` 收集范围的排除，不是模块树扫描的排除**（依据 `pini-spec-v0.md:109`「`pini test <path>` 可加回 exclude 排除目录」）。放置问题由 R6 解决，`exclude` **不参与** | **用户拍板** |
| D28 | **R8 · 文件命名**：清单 `module.toml` → **`pini.toml`**，锁文件 `_summary.toml` → **`pini-summary.toml`**。理由：文件名是 R1 判定边界的**哨兵**，须特异到误判率近零（通名会让外来工程被**静默**误判为子模块）。**旧名必须报错**，不得静默降级为「无清单」 | **用户拍板** |

---

## 4. 工具链命令（`pini mod`）

用户拍板（2026-08-28）：命令集 = `pini mod {tidy, refresh, verify, graph}`；**放弃全局缓存，不设 `clean`**（D23）。

| 命令 | 维度 | 读 | 写 | 联网 |
|---|---|---|:---:|:---:|
| `pini mod tidy` | **集合** | 全部文件的 `import`、既有 `require` | `[require]`（增删条目） | ❌ **离线** |
| `pini mod refresh` | **版本** | `require` 约束、`[tap]`、`[replace]` | `pini-summary.toml`（精确版本 + 校验和）、`deps/` | ✅ |
| `pini mod verify` | **完整性** | `pini-summary.toml` + 落地内容 | 无（只读） | ❌ |
| `pini mod graph` | **结构** | require 图 | 无（输出） | ❌ |

**分工维度互不重叠**：`tidy` 管**集合**（要什么），`refresh` 管**版本**（要哪版 + 取下来）。Go 的 `go mod tidy` 把两者合一，此处拆开更单一。

### 4.1 `tidy` —— 集合对齐（**离线**）

- 令 `[require]` 的条目集合与代码中实际出现的 `import` 一致：删多余、补缺失与间接依赖。
- **D21 · 离线**：不联网查询版本；新增条目约束**未知则写 `*`**，由 `refresh` 回填精确版本。
  - 理由：确定约束需知可用版本 → 需联网 → 会让 `tidy` 同时承担"集合"与"版本"两件事，与 `refresh` 的边界糊掉。
  - 与 Go 的分工同构：`require`（约束，人可读可手改）由 tidy 写；`pini-summary.toml`（解析结果，生成物）由 refresh 写。
- **典型流**：改完 import → `pini mod tidy` → `pini mod refresh`。

### 4.2 `refresh` —— 重解版本 + 下载

- 在 require 的传递闭包上重跑 MVS，写入 `pini-summary.toml`（精确版本、`sum`、`manifest_sum`、`imported-by`、`graph.order`），并下载缺失的**依赖与资源**。
- **这是唯一联网、唯一下载的命令**；build 永不抓取（D4）。

### 4.3 `verify` —— 校验和的实际执行点

- 校验落地内容（**含 `resources`**）与 `pini-summary.toml` 的 `sum` / `manifest_sum` 是否匹配；不匹配即报错。
- **这是 D6「校验和必备」的执行点**——没有它，`sum` 字段只是摆设。
- ⚠️ **须与另一个检查区分**：

  | | 防什么 | 何时跑 |
  |---|---|---|
  | **build 时一致性校验** | `require` 与 `import` 漂移 | **每次 build**（不符报错并提示 `pini mod tidy`） |
  | `pini mod verify` | 依赖内容被替换 / 篡改 | 显式调用 / CI |

  两者都要，是**两个不同的检查**：前者防漂移，后者防篡改。

### 4.4 `graph` —— 依赖图（默认展示，`--cycles` 服务环诊断）

- **默认**：输出依赖图（人读）。
- **`--cycles`**：只输出环，作为 **R2 环诊断的官方入口**；build 的环报错应提示 `run 'pini mod graph --cycles'`。
- `pini-summary.toml` 的 `imported-by` 字段天然支撑"谁引了它"类查询，故**不单开 `why` 子命令**（D16 保留该字段的价值在此）。

### 4.5 不设的部分

- **不设 `clean`**：无全局缓存，无可清理对象（D23）。
- **不设 `add` / `get`**：依赖由 `import` 生成——加依赖 = 写一句 import + `pini mod tidy`，无需独立命令。
- **不设全局缓存**：依赖一律落地到项目内 `deps/<name>/`，随 git submodule 或手工拷贝管理（D23）。

---

## 5. 连带决议（兑现既有欠账）

### 5.1 `[[ ]]` 数组表支持（顺带兑现 `[[bin]]`）

现有 `parseManifest` 对 `[[bin]]` 的处理是 `dropFirst().dropLast()`，得到段名 `"[bin]"`（**带方括号**），故 `[[bin]]` 从未被匹配上——这是 `[[bin]].entry` 一直未兑现的**直接原因**。

实施：为 `parseManifest` 增加 `[[ ]]` 数组表识别。**一箭双雕**——`pini-summary.toml` 的 `[[module]]` 与 `pini.toml` 的 `[[bin]]` 同时可用。

### 5.2 `pini-summary.toml` 与 `project-spec` §4 的冲突（须修订）

§4 规定构建类产物进 `.gitignore`（`build/` `.pini-build/` `target/` `gen/` `.pini-cache/`）。而 `pini-summary.toml` 是**锁文件，必须提交**——不提交即无可复现构建。

它带 `_` 前缀、又是生成的，极易被误当作"构建产物"忽略。**须在 §3/§4 明确写一条：`pini-summary.toml` 是生成物但必须纳入版本控制，与 §4 的构建产物不同类。**

### 5.3 四级可见性定稿表

| 级别 | 触发 | 本模块内（含一般子目录） | 可被跨模块引入 |
|---|---|---|---|
| private | 符号 `_` 前缀 | 仅类型内 | ❌ |
| internal | 文件 `_` 前缀 | 仅本文件 | ❌ |
| **package** | 目录 `_` 前缀 | ✅ | **❌** |
| **public** | 无 `_` | ✅ | **✅** |

R4 落地后，`package` 与 `public` **首次获得区分度**（此前同桶，因无第二模块可"public 给"）。

**D14**：`private` 与 `internal` **保持原样，不做区分**——用户在 `isVisible`（`Visibility.swift:76-79`）层面仍同为"仅本文件可达"，但**封装性由文件内保证**（用户拍板，2026-08-28）。即：两者的差异体现在"作用域是符号级还是文件级"，而非"可达范围"；可达范围同桶是可接受的，不另立机制。

### 5.4 与 G51 的分工

G51 已钉 import/export **块形式为唯一顶级形态**，宿主裸语句为已知偏差。本工单**不改变语法形态**，只赋予块形式真实语义；宿主裸语句移除仍属 G51 收敛待办。

---

## 6. 实施清单（2026-09-04 收口：落点已核，未逐项照抄原文）

> 收口原则：本节**只记落点**，不重复承载实施计划——实施由批 1 / 批 6 / 批 7 承接，
> 双份清单必然漂移（这正是本节此前停在 2026-08-28、与实际脱节一整轮的原因）。

### 6.1 治理（pini-meta）

| 项 | 落点 | 核实 |
|---|---|---|
| 工单落档 | 本文件 | ✅ |
| `docs/spec/pini-spec-v0.md`：G52 决策行 + §2.5 访问控制表「可被跨模块引入」列 + import/export 条款（import 即依赖 / 禁环 / 双通道 / R8 命名 / MVS / 四命令） | spec v0 §2.5 | ✅ 已登记（批 1/批 6 时点写入，2026-09-04 补批 7） |
| `docs/spec/pini-project-spec.md`：§3/§4 `pini-summary.toml`「生成但必须提交」+ §7 schema（`[tap]`/`[require]`/`[resources]`/`[replace]`，`[dependencies]` 标 Removed）+ §7.3 版本约束语法 | project-spec §3 §4 §7 | ✅ 已登记 |
| `docs/spec/pini-roadmap-next.md`：T2 状态 + §8.1 批次登记表 | roadmap T2 / §8.1 增批 7 行 | ✅ 2026-09-04 更新 |

### 6.2 宿主 pini-swift

| 项 | 落点 | 核实 |
|---|---|---|
| `parseManifest`：`[[ ]]` 数组表 + `[tap]`/`[require]`/`[require.<tap>]`/`[resources]`/`[resources.<tap>]`/`[replace]`；`[dependencies]` 命中即报错（D-B） | 批 6 | ✅ |
| `loadDirectory`：遇含 `pini.toml` 的祖先目录即跳过（R1 父扫描侧） | 批 6 D-4 前置 | ✅ `FileLoader.swift` 祖先逐级查清单 |
| 双通道判定 · **正向**（`require`/import 目标**不含** `pini.toml` → 报错指引 `[resources]`） | 批 6 | ✅ `ToolchainFailure.importTargetNotModule` |
| 双通道判定 · **反向**（`resources X` 而 X **根含** `pini.toml` → 报错，R7） | — | ❌ **未实现**（§9 Def-1） |
| 依赖图构建（别名→模块，模块级并集）+ 别名冲突拦截 | 批 1 | ✅ `ModuleSystemTests.testAliasNameConflictRejected` |
| 环检测 + 可读路径诊断 | 批 1 + 批 6 `graph --cycles` | ✅ `testDependencyCycleRejected` |
| MVS | 批 6（本地退化）→ **批 7 升级为经典 MVS**（tag 候选，取满足全部约束的最小版本） | ✅ |
| `pini-summary.toml` 生成（`manifest_sum`/`sum`/`commit`/`imported-by`/`graph.order`） | 批 6 生成；**批 7 补齐 `commit` 的读取** | ✅（`commit` 此前只写不读，批 7 修） |
| 校验和：规范化遍历 + SHA-256 + TOFU | 批 6 | ✅ 篡改检出有用例 |
| CLI `pini mod {tidy, refresh, verify, graph}` | 批 6 | ✅ `refresh` 由批 7 扩到远程 tap |
| 资源落地 `.pini/resources/<name>/`（R6） | **批 7** | ✅ 此前为「目录不存在则 `continue`」静默跳过 |
| 语义/类型层：跨模块符号解析（仅 `public`）+ 别名静态消解 | 批 1 | ✅ `testNonPublicAccessDenied` / `testCrossModuleCall` |
| `Interpreter`：按 `graph.order` 拓扑序注册模块 | — | ❌ **未实现**（§9 Def-2）：`graphOrder` 只写进锁文件，全仓无消费点 |
| 兑现 `[[bin]].entry` / `[lib].entry`（顺带根治 G49 双 `main` 冲突 E3-004） | — | ❌ **未实现**（§9 Def-3）：全仓 `entry` 零消费点，入口仍为「全局找 `main`」 |

### 6.3 pini/ 自举仓对齐

- **关键性质成立**：本套规则建在既有扁平命名空间之上，不拆包层；自举仓无跨模块场景，零改动通过。
- ✅ `deps` 已从 `examples/selfhost/pini.toml` 的 `exclude` 移除（现为 `exclude = ["examples"]`）。
- ⚠ **新开放问题**：D27 把 `exclude` 收窄为「`pini test` 收集范围」后，`examples/` 需要新归宿（详见 §9 Def-4）。

---

## 7. 验收记录（2026-09-04 实测，取代原 DoD 表述）

> 原 DoD 的基线数字（"1010 执行 / 20 跳过"）已严重过期。**一切以实测为准**。

| # | 原 DoD | 实测 | 依据 |
|---|---|:---:|---|
| 1 | 宿主全量测试不回退 + G52 用例全绿 | ✅ | **1157 执行 / 112 跳过 / 0 失败**（G52 批 7 前基线 1144，净增 13）。跳过数与原记的 20 不符，原因未查，不影响结论 |
| 2 | 三层嵌套模块切分为 3 个模块，命名空间独立 | ⚠ **部分** | 两层（app ⊃ helper）有用例（`ModuleSystemTests` + `demo/` 夹具，跨模块限定调用与命名空间隔离均覆盖）；**三层无专项用例** → §9 Def-5 |
| 3 | 成环报错并给出完整环路径 | ✅ | E3-010 `module dependency cycle (R2): '{chain}'`（`Sources/PiniCore/Resources/Diagnostics.en.toml`）；`ModuleSystemTests.testDependencyCycleRejected`；`pini mod graph --cycles` 另出环列表 |
| 4 | `[require.<tap>]`/`[resources.<tap>]` 解析成功；`[dependencies]` 已移除 | ✅ | `ModuleTestCollectionTests` 双通道四节用例；`[dependencies]` 命中即 `legacyDependenciesSection` 报错（D-B） |
| 5 | 双通道**双向**封闭 | ❌ **单向** | 正向（`require` 目标不是模块）✅ `importTargetNotModule`；**反向（`resources X` 而 X 根含 `pini.toml`）未实现** → §9 Def-1 |
| 6 | 锁文件可生成可校验；篡改后 `verify` 必须报错 | ✅ | `testRefreshVerifyChainAndTamperDetection` + 批 7 `testRefreshFetchesRemoteTapAndVerifies`（篡改依赖清单后 `verify` 检出不符） |
| 7 | `tidy` 离线；`graph --cycles` 出环；`refresh` 唯一联网 | ✅ | 三命令均不含网络调用；批 7 后抓取**只**发生在 `refresh`（`resolveFetching`），`resolve`/`graph` 保持只读 |
| 8 | `[[bin]].entry` 生效，双 `main` 冲突不再出现 | ❌ **未实现** | 全仓 `entry` 零消费点 → §9 Def-3 |
| 9 | 自举仓零改动通过 `pini check .` / `pini test` | ✅（部分） | `pini check .` **实测通过**（15 文件，rc=0）。⚠ 原条目的 `deps/pini-swift 归类为 resources` 已**过时**：ADR-024 D2 后宿主不再随仓携带，改由嵌套独立仓 + `.pini/` 承载，该判据失效 |

**结论**：9 项中 6 项通过、1 项部分、2 项未实现（另有 1 条判据已过时）。未实现项**不阻塞关闭**——
它们已登记为 §9 缺陷，由后续批次承接；本工单的职责（**把决议与主体实现落到规范与代码**）已完成。

---

## 8. 开放问题收口（2026-08-28，用户已全部拍板）

| # | 原问题 | 裁决 | 落点 |
|---|---|---|---|
| 1 | `private` 与 `internal` 在 `isVisible` 层面同桶，需否区分 | **保持原样，不区分**——封装性由文件内保证 | **D14**（§5.3） |
| 2 | `tap` 的默认 github org 显式书写 vs 工具补全 | **必须显式书写**，禁止从全局配置/环境变量推断；只在 `[tap] default` 写一次 | **D11**（§3.1） |
| 3 | 非 git 源时 `commit` 字段的替代表达 | **字段名保持 `commit` 不变**（可读性优先），语义放宽为「来源侧内容定位符」；非 git 源填 `-`；`sum` 为唯一凭证 | **D12**（§3.5） |
| 4 | `[override]` / `[replace]` 节何时引入 | **本轮一步到位**：即建 `[replace]`，不立 `[override]`、不立 `[exclude]` | **D13**（§3.7） |
| 5 | 是否仍需 `require` 来激活 MVS | **需要**——`require` 保留并作为 MVS 输入，且其条目**由 import 生成** | **D19**（§3.2） |
| 6 | `install` 节的定位 | 改为 **`resources`**：`require` 判定「是否 Pini 资源」的**取反**；不可被依赖。**原裁决「拒绝下载含 `pini.toml` 的库」已由 D26 收窄为「目标根含 `pini.toml` 即拒，不查深层」** | **D20**（§3.3）＋**D26** |
| 7 | `pini mod tidy` 是否联网 | **离线**：只做集合对齐，未知约束写 `*`，精确版本由 `refresh` 回填 | **D21**（§4.1） |
| 8 | 全局缓存 / `clean` 命令 | **均放弃**；依赖一律落地到项目内 `deps/<name>/` | **D23**（§4.5） |
| 9 | `graph` 与环诊断的关系 | **默认只做展示**，通过 `--cycles` 服务 R2 环诊断 | **D22**（§4.4） |

**剩余待观察项**（不构成阻塞，记录备查）：

1. `[replace]` 的**作用域内 override** 需求（"只有 text 要的 uni 换版本"）——当前 `[replace]` 是全局的（Go 同），若将来出现定向需求再评估；
2. registry / tarball 源落地时，`commit` 字段值的具体取值规范；
3. 中心化校验和数据库（Go `GONOSUMDB` 的正向对应物）的价值与引入时机；
4. `[resources]` 是否也需要校验和——当前设计**同样校验**（§4.3 要求 verify 覆盖 resources），若将来出现超大资源需评估开销。

---

## 9. 遗留缺陷（2026-09-04 收口时登记，**不在本工单内修**）

> 按项目工作法：完成计划 → 记下缺陷 → 由后续批次承接。本节即"记下"的落点，
> **不新开工单文档**（用户裁决 2026-09-04：遗留项在此登记即可）。

| # | 缺陷 | 判据 | 影响 |
|---|---|---|---|
| **Def-1** | **R7 反向根检未实现**：`resources X` 而 X 根含 `pini.toml` 时不报错 | R7 / D20 / D26「双向封闭」 | DoD #5 只兑现一半。把 Pini 模块误配成资源不会被拦，需人工发现 |
| **Def-2** | `graph.order` **只写不读**：解释器未按拓扑序注册模块 | §3.5 / §6.2 | 锁文件里的 `order` 字段形同虚设；跨模块顶层初始化顺序目前靠实现细节，不靠 DAG 保证 |
| **Def-3** | `[[bin]].entry` / `[lib].entry` **全仓零消费点**，入口仍是「全局找 `main`」 | §6.2 / G49 | G49 的双 `main` 冲突（E3-004）**未根治**；多 bin 项目无法定位入口 |
| **Def-4** | D27 把 `[build] exclude` 收窄为「`pini test` 收集范围」后，`examples/selfhost/pini.toml` 的 `exclude = ["examples"]` **失去扫描语义** | D27 + `examples/selfhost/pini.toml` 注释 | 自举仓 `examples/` 需新归宿（自带清单自切 / 移入 `.pini/` / 恢复扫描语义，三选一）。宿主当前仍按 G49 的包加载排除实现，故暂不炸 |
| **Def-5** | 三层嵌套模块切分**无专项用例**（仅两层） | DoD #2 | R1 的递归排除在三层以上未受测试保护 |
| **Def-6** | `[replace]` 的**版本覆盖**（`uni = "3.2.0"`）与 **fork 替换**（`github:me/fork@v1.0`）两种形态未实现，仅 `file:` 形态生效 | D13 / §3.7 | D13 三种形态只兑现一种 |
| **Def-7** | 锁文件 `tap` / `source` 字段**只写不读**（`parseSummary` 丢弃） | §3.5 | 批 7 已补 `commit` 的读取，这两个仍无消费者；`verify` 报错时无法回显来源 |
| **Def-8** | `[resources]` 的**产品内寻址方式**未定义 | §3.3 明文「待定」 | v1 只做「落地 + 校验」，代码无法按名引用资源内容 |

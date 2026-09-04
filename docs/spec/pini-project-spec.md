# Pini 项目规范 · 项目目录结构（Project Layout）

> **定位**：本文是 Pini 语言的**项目级目录结构规范**（Project Layout），规定一个「Pini 语言项目」在磁盘上**应当如何组织**。它与 `pini-spec-v0.md`（语言语义事实源）是互补关系：spec v0 管「语言长什么样」，本文管「用这门语言写的项目长什么样」。
>
> **事实源层级**：`pini-spec-v0.md` ＞ 本文（项目布局规范）＞ `Pini草稿.md`（设计意图）＞ README ＞ `examples/`。任何冲突以更高层级为准。形式文法 EBNF 的**唯一载体**为 `pini-spec-v0.md` §A 附录（原独立草案与事实基线文档已并入并删除）。
>
> **分类意图**：目录按稳定性意图分三类——
> - **① 必需目录**（Mandatory）：构建/运行/可复现所必须，缺失即不构成合法项目。
> - **② 可扩展目录**（Extensible）：非必须，但有约定俗成的标准位置，工具链与社区会默认查找。
> - **③ 预留目录**（Reserved）：为尚未实现的能力（模块系统、包管理、工具链缓存等）预留的路径，提前占坑以避免未来破坏性改名。

---

## 0. 设计原则（语言项目布局最佳实践）

本规范借鉴成熟语言的项目布局约定，取其三要素：

1. **单一清单（Manifest）**：每个项目有且仅有一个声明文件（名称/版本/依赖/入口/钉住的规范版本）。对应 Cargo 的 `Cargo.toml`、Go 的 `go.mod`、SwiftPM 的 `Package.swift`。
2. **约定优于配置（Convention over Configuration）**：源码、测试、示例、基准各归其位，工具链无需额外配置即可发现。对应 Cargo 的 `src/` `tests/` `examples/` `benches/`。
3. **构建产物与源码隔离**：所有生成物进独立目录，且不纳入版本控制。对应 SwiftPM 的 `.build/`、Cargo 的 `target/`。

**关键区分——宿主布局 vs 语言布局**：
当前 `Pini/` 仓库本身是一个 **SwiftPM 宿主工程**（`Package.swift` + `Sources/` + `Tests/` + `examples/` + `docs/`），它承载的是「Pini 解释器/编译器实现」。本文定义的「项目目录结构」是 **Pini 语言使用者的项目**应当遵循的布局；宿主工程通过在其 `Package.swift` 中声明 Pini 工具链依赖来复用本规范，二者层级不同、可共存。

---

## 1. ① 必需目录（Mandatory）

任何合法的 Pini 项目**必须**包含以下路径。缺失任一项，工具链应拒绝构建并报「项目结构不合法」。

| 路径 | 类型 | 用途 | 备注 |
|---|---|---|---|
| `pini.toml` | 文件 | **项目清单（Manifest）**：项目名、版本、`spec` 钉住的规范版本（如 `spec = "0.1"`）、入口声明、依赖列表 | 等价 SwiftPM 的 `Package.swift` 在语言层的存在；若项目以 SwiftPM 宿主方式组织，则可用 `Package.swift` 代替并内嵌等效字段 |
| `src/` | 目录 | **源码根**：所有 `.pini` 源文件默认所在目录 | 必需；不可改名（约定优于配置） |
| `src/main.pini` | 文件 | **可执行项目入口**：顶级交替起点 | 库项目可用 `src/lib.pini` 代替；二选一必需 |
| `.pini/baseline` | 文件 | **标定记录**：上次构建/差分验证通过时的宿主状态（ADR-024 D8） | 内容如 `host=<sha> version=0.50.0 spec=0.1 verified=<date>`；宿主与规范同仓时，单 `sha` 同时钉住二者，差分失败时据此判定哪侧变动。~~原 `.pini/version`（「拉取指令」语义）~~ 由 ADR-024 D8 改写 |
| `docs/` | 目录 | 项目自身文档（含对 spec v0 的引用摘录） | 库项目必需；可执行小工具可豁免 |

**必需项的设计约束**
- Manifest 必须声明 `spec` 版本，使「破坏性变更治理」（`pini-spec-v0.md`）可被机器校验：工具链读到 `spec = "0.1"` 即知仅承诺 v0.1 稳定性。
- `src/` 名称不可配置，避免工具链做路径推断；子目录允许自由嵌套（见 §2 扩展项）。

---

## 2. ② 可扩展目录（Extensible）

以下目录**非必须**，但一旦存在，工具链与社区约定其语义；新增工具应优先在此落位，而非发明新路径。

| 路径 | 类型 | 用途 | 与最佳实践映射 |
|---|---|---|---|
| `tests/` | 目录 | 单元/集成测试（`.pini` 测试文件，或 `tests/` 下子项目） | Cargo `tests/`、SwiftPM `Tests/` |
| `examples/` | 目录 | 可独立运行的示例程序 | Cargo `examples/`；当前 `Pini/examples/` 已采用 |
| `benches/` | 目录 | 性能基准 | Cargo `benches/` |
| `docs/` 子结构 | 目录 | 教程、`api.md`、规范摘录、ADR 记录 | — |
| `tools/` 或 `scripts/` | 目录 | 项目级脚本、代码生成入口、构建辅助 | 通用约定 |
| `std/` | 目录 | 随项目分发/可被覆盖的**标准库源码** | 允许项目本地覆盖 stdlib（实验性） |
| `src/**`（子包目录） | 目录 | 按主题拆分的源码子目录 | 模块系统落地前，用目录近似「内部分包」 |
| **`deps/`** | 目录 | **外部依赖源码落地**（G52 激活，从 §3 迁入） | `vendor` 概念；当前经 git submodule 落地，物理形态为 `deps/<name>/`，每个含自己的 `pini.toml` |
| **`.pini/toolchain/`** | 目录 | vendored 宿主工具链（历史上经 git submodule 落地，G52 R6 确立） | **ADR-024 后自举项目不再使用**——宿主以嵌套独立仓 `examples/selfhost/` 入树（物理在内、git 归属在外）；保留为一般性机制，§7.1/§7.2 的「宿主不属 require/resources」注记指向此处 |

**扩展项的演进钩子**
- `src/**` 子目录在 **P4 模块系统**落地后，应平滑升级为显式 `module` 声明，无需改动物理路径（路径即模块名，零破坏）。
- `std/` 与 spec v0 标准库最小契约联动：本地 `std/` 只能**扩充**契约，不能削弱保证 API。
- `deps/` 的**边界性质（G52 R6 修订）**：它**只放 `require` 的 Pini 模块**——其下每个模块自带 `pini.toml`，由 **R1 自动切出**父模块的扫描，**无需任何排除配置**。
  ~~原 R1'「`deps/` 是保留目录，工具链永不扫描」**已撤销**~~：非 Pini 依赖与宿主一律落 `.pini/`（R6，点前缀目录不参与扫描），
  目录级特例因此不再需要（撤销理由见 `docs/spec/issue/archive/issue-module-system-rules-2026-08-28.md` R1 条）。
  **宿主判定补注（ADR-024）**：判据按**清单类型**判定——宿主 pini-swift 根含 `Package.swift`（SwiftPM 清单）而非 `pini.toml`，不满足「Pini 模块」判据，故从不属 `deps/`。其承载方式：submodule 时代落 `.pini/toolchain/`；ADR-024 起为嵌套独立仓（见 §5）。

---

## 3. ③ 预留目录（Reserved）

为**尚未实现**的能力提前占坑。当前工具链**不要求也不使用**这些路径；但若未来启用，必须使用下表既定名称，禁止另起名字，以保前向兼容。

| 路径 | 类型 | 预留给 | 关联路线图 |
|---|---|---|---|
| `modules/` 或 `pkg/` | 目录 | 多模块 / 本地包根 | P4 模块系统 |
| `vendor/` | 目录 | 备用依赖落地名（当前采用 `deps/`，见 §2） | P4 包管理 |
| `build/` 或 `.pini/build/` | 目录 | 构建产物 / 中间表示（IR）/ 字节码（原 `.pini-build/`，G52 R6 收编） | P6 LLVM 后端补全 |
| `gen/` | 目录 | 代码生成输出（trait 派生、FFI 桩、宏展开） | P3 trait / 未来阶段：FFI |
| `.pini/cache/` | 目录 | 工具链缓存（LSP 索引、类型推断缓存、增量编译状态）（原 `.pini-cache/`，G52 R6 收编） | 未来阶段：工具链 |
| `proto/` 或 `idl/` | 目录 | 接口/ABI 描述文件（FFI 契约、调试协议描述） | 未来阶段：FFI / 调试协议 |
| `target/` | 目录 | 跨平台产物根（多 target 输出隔离） | 未来阶段：平台 ABI |

**预留治理规则**
- 所有预留目录**默认加入 `.gitignore` 模板**（构建类）或**禁止手写内容**（语义类如 `proto/` 在未定义格式前）。
- 注意：roadmap（`pini-roadmap-next.md`）当前仅定义 **P0–P7**。上表「关联路线图」中的「未来阶段：…」为**预留主题占位**（FFI / 调试协议 / 平台 ABI / 工具链），待 roadmap 扩编后再赋予正式 P 编号——本文不臆造阶段编号。
- 任一预留项被 roadmap 激活时，本文将其从「③ 预留」迁移至「① 必需」或「② 可扩展」，并 bump 规范次版本。

---

## 4. 推荐 `.gitignore` 基线

基于上述分类，Pini 项目默认忽略构建与缓存类目录：

```gitignore
# 构建产物（§3 预留）
build/
.pini/build/
target/
gen/

# 工具链缓存（§3 预留）
.pini/cache/
# ↑ 收编自 .pini-build/ 与 .pini-cache/（G52 R6）：统一置于 .pini/ 命名空间根，
#   使「不参与扫描」只需一条规则（.pini/ 及其下一切），而非「.pini/ 及 .pini-*」。

# 依赖落地（§2 扩展项，G52 激活）
deps/
vendor/
# 注：以上两条**不影响**以 git submodule 形式加入的依赖——
# submodule 是父仓库索引中的 gitlink，本身即被跟踪（G52 D18）。
# 这两条只针对手工拷贝进来的依赖源码。

# ⚠ 陷阱：本项目既有的点目录**全部**在此忽略列表里，「点前缀 = 不进版本控制」已成直觉。
# 但 .pini/ 下还有**必须提交**的内容，须显式豁免：
!.pini/resources/
!.pini/toolchain/
!.pini/baseline
# 不豁免的后果：换机器后 verify 报「内容缺失」，症状离原因很远。
# （原 !.pini/version → !.pini/baseline，ADR-024 D8：标定记录取代拉取指令）

# 例外：pini-summary.toml 虽由 MVS 生成，但它是**锁文件**而非构建产物，
# 必须纳入版本控制，否则无可复现构建（G52 R3 / D10）
!pini-summary.toml
```

> ⚠️ **易错点**：`pini-summary.toml` 带 `_` 前缀（生成物命名惯例）且由工具产出，极易被误当作构建产物顺手忽略。
> 它与 §3 的构建产物**不同类**——前者是**可复现性凭据**，后者是**可再生的中间物**。

---

## 5. 与既有资产的映射

| 本文条目 | 关联文档/资产 | 关系 |
|---|---|---|
| Manifest `spec` 字段 | `pini-spec-v0.md` 版本策略、破坏性变更 | 机器可读的兼容性承诺锚点 |
| `src/` 入口 `main.pini` | `pini-spec-v0.md` 顶级交替、运行时 | 入口即语言「顶级交替」的物理落点 |
| `std/` 扩充约束 | `pini-spec-v0.md` 标准库最小契约 | 本地覆盖不得削弱契约 |
| `modules/` `deps/` 预留 | `pini-roadmap-next.md` P4 | 模块系统/包管理的物理落位 |
| `build/` `gen/` 预留 | `pini-roadmap-next.md` P6/P3 | 后端与代码生成的产出目录 |
| `examples/` 已采用 | 当前 `Pini/examples/*.pini` | 规范追认现有实践，零破坏 |
| 宿主布局并存 | 当前 `Package.swift` + `Sources/` + `Tests/` | 实现宿主 vs 语言布局的层级区分（§0） |
| 嵌套独立仓 | `examples/selfhost/`（自举项目，ADR-024 D2） | 宿主自带的语言项目示例：**物理在内、git 归属在外**——宿主 `.gitignore` 忽略 `/examples/selfhost`，不进宿主历史与归档；自举项目仍完整遵循本规范 |

---

## 6. 验收标志（Definition of Done）

- [ ] 一份合法 Pini 项目的最小磁盘结构 = `pini.toml` + `src/` + 入口 + `.pini/baseline` + `docs/`（库）/ 入口（可执行）。
- [ ] 工具链能据 Manifest 的 `spec` 字段校验破坏性变更兼容性。
- [ ] `tests/` `examples/` `benches/` 被默认发现，无需额外配置（`[build] exclude` 显式排除的路径除外，G49）。
- [ ] 所有 §3 预留目录在包管理器/模块系统启用前保持「占坑不用」，且进入 `.gitignore` 基线。
- [ ] 本文与 spec v0、roadmap 的交叉引用一致，无矛盾。

---

## 7. 清单 schema：`pini.toml`（Manifest 字段规范）

> Manifest 是「必需目录」的核心。下列 schema 为 **v0.1 基线（Provisional）**：字段可能随 P4 包管理器落地细化，但 `spec` / `name` / `version` / `entry` 为 Stable，不破坏。

### 7.1 顶层字段

```toml
# pini.toml —— Pini 项目清单（v0.1）

[package]
name        = "hello"        # (Stable) 模块标识，本地唯一；建议反向域名风格
version     = "0.1.0"        # (Stable) 语义化版本 SemVer 2.0
spec        = "0.1"          # (Stable) 钉住的规范版本——兼容性承诺锚点（见 7.4）
edition     = "2026"         # (Provisional) 语法纪元，未来破坏性语法切换时递增
description = "A demo project"
license     = "MIT"
authors     = ["wen <wen@example.com>"]

# 入口二选一：库用 [lib]，可执行用 [[bin]]
[lib]
path = "src"                 # 库根目录；默认入口文件为 src/lib.pini
entry = "src/lib.pini"         # 可选覆盖

[[bin]]
name  = "hello"
entry = "src/main.pini"        # 可执行入口（顶级交替起点）

# (Provisional) 模块包文件集（G49）；值不支持行内注释
[build]
exclude = ["examples"]

# ── 依赖（G52）─────────────────────────────────────────────
# [tap]    从哪来。org 必须显式书写，禁止从全局配置/环境变量推断（可复现性，D11）
[tap]
default = "github:pini-lang"        # → github.com/pini-lang/<name>
core    = "github:pini-lang"
local   = "file:../vendor/<name>"

# [require] 模块依赖：目标**含 pini.toml**。**可 import、激活 MVS**。
#            条目集合**由代码中的 import 生成**，人工只可覆盖版本约束（D19）。
#            段名 [require.<tap>] 指定源；版本约束语法见 §7.3。
[require]
text = "1.2"
fmt  = ">=2.0, <3.0"
[require.core]
uni = "^3.0"

# [resources] 资源落地：目标**根不含 pini.toml**（语料、数据集、脚本、非 Pini 资产）。
#              **不可 import、不参与 MVS**；固定落地 .pini/resources/<name>/（R6，点前缀不扫描）。
#              检查**只看目标根**（R7）：根含 pini.toml 即拒，提示改用 [require]；不查深层。
#              ⚠ 宿主 pini-swift **不属本节**——它是工具链，归 .pini/toolchain/（见 §2；
#              ADR-024 后自举项目经嵌套独立仓 examples/selfhost/ 入树，亦不属本节）。
[resources]
corpus     = "1.0"
dataset    = "2.3"
[resources.local]
dataset = "*"

# [replace] 替换（一步到位：强制版本 / 本地调试 / 换 fork）。**仅主模块生效**（D13）。
[replace]
uni  = "3.2.0"                      # 只换版本（等价 npm overrides）
dev  = "file:../dev"                # 换来源为本地目录
fork = "github:me/fork@v1.0"        # 换来源为 fork

[tool.pini]               # (Provisional) 工具链配置
target   = "native"          # 目标后端；未来阶段（平台 ABI）后接受三元组
opt-level = 2
```

> **`[dependencies]` 已移除**（G52 D17）：职责**拆分**给 `[require]` + `[resources]`，且**不设 Deprecated 共存期**——当前无任何实现消费它，硬切成本为零。
>
> **依赖相关节的分工**（G52）：
>
> | 节 | 回答 | 判据 | 建立依赖边？ | 参与 MVS？ |
> |---|---|---|:---:|:---:|
> | `[tap]` | 从哪来 | — | 否 | 否 |
> | `[require]` | 要哪些**模块** | 目标**含** `pini.toml` | 间接（由 import 生成） | **是** |
> | `[resources]` | 要哪些**资源** | 目标**不含** `pini.toml` | **否** | 否 |
> | `[replace]` | 如何替换 | — | 否 | 影响解析 |
> | `import`（代码内 `[名称\|import]` 块） | 用什么 | — | **是** | 是 |
>
> **分区双向封闭**：`resources X` 而 X 含 `pini.toml` → 报错"应改用 `require`"；
> `require X` 而 X 不含 → 报错"应改用 `resources`"。判据可判定，错误在写入时即暴露，不会拖到 MVS 阶段。
>
> **工具链命令**：`pini mod {tidy, refresh, verify, graph}`——`tidy` 离线对齐集合（未知约束写 `*`）、
> `refresh` 重解 MVS 并下载（**唯一联网**，build 永不抓取）、`verify` 执行校验和、`graph --cycles` 输出环。
> **无全局缓存、无 `clean`**；依赖一律落地到项目内 `deps/<name>/`。

### 7.2 字段稳定性分级（呼应 spec v0）

| 字段 | 级别 | 说明 |
|---|---|---|
| `package.name` / `version` / `spec` / `entry` | **Stable** | v0.x 内不破坏 |
| `package.edition` | Provisional | 仅在切换语法纪元时使用 |
| `build.exclude` | Provisional | **`pini test` 收集范围**的排除（G49 + **G52 D27 收窄**）——**不是**模块树扫描的排除；模块树扫描边界由 R1（清单）与 R5/R6（点前缀 / `.pini/`）决定 |
| `tap.*` | Provisional | 依赖源声明；**org 必须显式书写**（G52 D11） |
| `require.*` | Provisional | 模块依赖（目标**根含** `pini.toml`）；**可 import、激活 MVS**；条目由 import 生成（G52 D19）；落地 `deps/<name>/`，R1 自切 |
| `resources.*` | Provisional | 资源落地（目标**根不含** `pini.toml`）；**不可 import、不参与 MVS**；固定落 **`.pini/resources/<name>/`**（G52 D20 + R6）；检查**只查根、不查深层**（R7）。⚠ **宿主不属此节**——归 `.pini/toolchain/` |
| `replace.*` | Provisional | 强制版本 / 本地 / 换 fork；**仅主模块生效**（G52 D13） |
| `tool.pini.*` | Provisional | 工具链参数可能增删 |
| ~~`dependencies.*`~~ | **Removed** | 职责拆分给 `require.*` + `resources.*`，无共存期（G52 D17） |

### 7.3 版本约束语法（`require` / `resources`）

| 写法 | 展开为 | 含义 |
|---|---|---|
| `^1.2` | `>=1.2.0, <2.0.0` | caret：允许兼容的 minor/patch 更新 |
| `~1.2.3` | `>=1.2.3, <1.3.0` | tilde：仅允许 patch 更新 |
| `=1.2.3` | `=1.2.3` | 精确锁定 |
| `">=1.0, <2.0"` | 范围 | 显式区间 |

### 7.4 `spec` 字段语义（破坏性变更治理的机器可读锚点）

- `spec = "0.1"` 表示：本项目按 **spec v0.1** 编写，工具链承诺仅接受 v0.1.x 内的兼容变更；遇到 v0.2+ 的破坏性语法时**报错并提示迁移**，而非静默误编译。
- 工具链读取 `spec` 后锁定对应稳定性分级表（spec v0），据此决定哪些语言特性可用、哪些标记为 Deprecated。
- 与 `.pini/baseline`（标定记录）分工（ADR-024 D8）：`spec` 是**意图声明**（本项目承诺兼容的规范版本），`baseline` 是**实测观察**（上次验证通过时的宿主状态）。二者必须一致，由门禁校验——否则等于重新引入一对会漂移的双钉。宿主与规范同仓时（ADR-024），`baseline` 的单 `host=<sha>` 即同时钉住工具链与规范。

---

## 8. 最小合法项目脚手架（Scaffold）

> 一套可被 `pini run` 直接识别的最小结构。工程师复制即用。

**磁盘结构**

```
hello/
├── pini.toml
├── .pini/baseline
├── src/
│   └── main.pini
└── docs/
    └── README.md
```

**`pini.toml`**

```toml
[package]
name = "hello"
version = "0.1.0"
spec = "0.1"

[[bin]]
name = "hello"
entry = "src/main.pini"
```

**`.pini/baseline`**（ADR-024 D8：标定记录，非拉取指令）

```
host=<sha> version=0.42.0 spec=0.1 verified=2026-08-30
```

**`src/main.pini`**（顶级交替入口；`;` 为行注释）

```pini
; 入口示例：main 函数块为可执行入口
main|func() -> ()
    print("Hello, Pini!")
    return
```

**`docs/README.md`**

```markdown
# hello

最小 Pini 可执行项目。运行：`pini run`。
```

### 脚手架校验规则

- 工具链从 `pini.toml` 读 `[[bin]].entry` → 定位 `src/main.pini` → 作为顶级交替根。
- 若缺 `pini.toml` 或 `spec` 字段 → 报「项目结构不合法」（§1 必需项）。
- 若 `src/` 下无任何入口声明文件 → 报「缺少入口」。
- 库项目将 `[[bin]]` 换为 `[lib]`，入口改 `src/lib.pini` 即可，物理结构不变。

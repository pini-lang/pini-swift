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
| `module.toml` | 文件 | **项目清单（Manifest）**：项目名、版本、`spec` 钉住的规范版本（如 `spec = "0.1"`）、入口声明、依赖列表 | 等价 SwiftPM 的 `Package.swift` 在语言层的存在；若项目以 SwiftPM 宿主方式组织，则可用 `Package.swift` 代替并内嵌等效字段 |
| `src/` | 目录 | **源码根**：所有 `.pini` 源文件默认所在目录 | 必需；不可改名（约定优于配置） |
| `src/main.pini` | 文件 | **可执行项目入口**：顶级交替起点 | 库项目可用 `src/lib.pini` 代替；二选一必需 |
| `.pini-version` | 文件 | 钉住的**工具链/规范版本**，保证可复现构建 | 内容如 `pini 0.4.0 (spec 0.1)`；CI 与 `pini run` 据此选择工具链 |
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

**扩展项的演进钩子**
- `src/**` 子目录在 **P4 模块系统**落地后，应平滑升级为显式 `module` 声明，无需改动物理路径（路径即模块名，零破坏）。
- `std/` 与 spec v0 标准库最小契约联动：本地 `std/` 只能**扩充**契约，不能削弱保证 API。

---

## 3. ③ 预留目录（Reserved）

为**尚未实现**的能力提前占坑。当前工具链**不要求也不使用**这些路径；但若未来启用，必须使用下表既定名称，禁止另起名字，以保前向兼容。

| 路径 | 类型 | 预留给 | 关联路线图 |
|---|---|---|---|
| `modules/` 或 `pkg/` | 目录 | 多模块 / 本地包根 | P4 模块系统 |
| `deps/` 或 `vendor/` | 目录 | 依赖源码落地（包管理器拉取的第三方代码） | P4 包管理 |
| `build/` 或 `.pini-build/` | 目录 | 构建产物 / 中间表示（IR）/ 字节码 | P6 LLVM 后端补全 |
| `gen/` | 目录 | 代码生成输出（trait 派生、FFI 桩、宏展开） | P3 trait / 未来阶段：FFI |
| `.pini-cache/` | 目录 | 工具链缓存（LSP 索引、类型推断缓存、增量编译状态） | 未来阶段：工具链 |
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
.pini-build/
target/
gen/

# 工具链缓存（§3 预留）
.pini-cache/

# 依赖落地（包管理器启用后）
deps/
vendor/
```

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

---

## 6. 验收标志（Definition of Done）

- [ ] 一份合法 Pini 项目的最小磁盘结构 = `module.toml` + `src/` + 入口 + `.pini-version` + `docs/`（库）/ 入口（可执行）。
- [ ] 工具链能据 Manifest 的 `spec` 字段校验破坏性变更兼容性。
- [ ] `tests/` `examples/` `benches/` 被默认发现，无需额外配置。
- [ ] 所有 §3 预留目录在包管理器/模块系统启用前保持「占坑不用」，且进入 `.gitignore` 基线。
- [ ] 本文与 spec v0、roadmap 的交叉引用一致，无矛盾。

---

## 7. 清单 schema：`module.toml`（Manifest 字段规范）

> Manifest 是「必需目录」的核心。下列 schema 为 **v0.1 基线（Provisional）**：字段可能随 P4 包管理器落地细化，但 `spec` / `name` / `version` / `entry` 为 Stable，不破坏。

### 7.1 顶层字段

```toml
# module.toml —— Pini 项目清单（v0.1）

[project]
name        = "hello"        # (Stable) 项目标识，本地唯一；建议反向域名风格
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

[dependencies]               # (Provisional) P4 包管理器启用后生效；当前忽略
pini-std-extra = "^1.2"                 # caret：>=1.2.0, <2.0.0
"some-pkg"         = ">=2.0, <3.0"         # 显式范围

[tool.pini]               # (Provisional) 工具链配置
target   = "native"          # 目标后端；未来阶段（平台 ABI）后接受三元组
opt-level = 2
```

### 7.2 字段稳定性分级（呼应 spec v0）

| 字段 | 级别 | 说明 |
|---|---|---|
| `project.name` / `version` / `spec` / `entry` | **Stable** | v0.x 内不破坏 |
| `project.edition` | Provisional | 仅在切换语法纪元时使用 |
| `dependencies.*` | Provisional | 依赖解析语义随 P4 包管理器收敛 |
| `tool.pini.*` | Provisional | 工具链参数可能增删 |

### 7.3 版本约束语法（`dependencies`）

| 写法 | 展开为 | 含义 |
|---|---|---|
| `^1.2` | `>=1.2.0, <2.0.0` | caret：允许兼容的 minor/patch 更新 |
| `~1.2.3` | `>=1.2.3, <1.3.0` | tilde：仅允许 patch 更新 |
| `=1.2.3` | `=1.2.3` | 精确锁定 |
| `">=1.0, <2.0"` | 范围 | 显式区间 |

### 7.4 `spec` 字段语义（破坏性变更治理的机器可读锚点）

- `spec = "0.1"` 表示：本项目按 **spec v0.1** 编写，工具链承诺仅接受 v0.1.x 内的兼容变更；遇到 v0.2+ 的破坏性语法时**报错并提示迁移**，而非静默误编译。
- 工具链读取 `spec` 后锁定对应稳定性分级表（spec v0），据此决定哪些语言特性可用、哪些标记为 Deprecated。
- 与 `.pini-version`（工具链版本）解耦：`spec` 管「语言契约」，`.pini-version` 管「用哪版工具链构建」。

---

## 8. 最小合法项目脚手架（Scaffold）

> 一套可被 `pini run` 直接识别的最小结构。工程师复制即用。

**磁盘结构**

```
hello/
├── module.toml
├── .pini-version
├── src/
│   └── main.pini
└── docs/
    └── README.md
```

**`module.toml`**

```toml
[project]
name = "hello"
version = "0.1.0"
spec = "0.1"

[[bin]]
name = "hello"
entry = "src/main.pini"
```

**`.pini-version`**

```
pini 0.42.0 (spec 0.1)
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

- 工具链从 `module.toml` 读 `[[bin]].entry` → 定位 `src/main.pini` → 作为顶级交替根。
- 若缺 `module.toml` 或 `spec` 字段 → 报「项目结构不合法」（§1 必需项）。
- 若 `src/` 下无任何入口声明文件 → 报「缺少入口」。
- 库项目将 `[[bin]]` 换为 `[lib]`，入口改 `src/lib.pini` 即可，物理结构不变。

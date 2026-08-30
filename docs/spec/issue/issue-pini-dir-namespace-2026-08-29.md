# `.pini/` 命名空间、点目录规则与文件命名（G52 续）

> **状态：已批准，落档进行中（2026-08-29）。**
>
> 本文件保留为**设计理由记录**——G52 工单只存规则正文与决议，本稿存「为什么」。
> 承接 `issue-module-system-rules-2026-08-28.md`（G52，D1–D23）；
> 本稿的 **R5–R8 已入工单 §2**，对应决议 **D24–D28 已入工单 §3.8**。
> 落档进度见 §7（已勾选项即已完成）。
>
> 本文档**有意保留** `module.toml` / `_summary.toml` 旧名——R8 的改名说明需要它们。

---

## 1. 问题：三层补丁，同一个错误

G52 定了 `require` / `resources` 双通道，但没解决「resources 落在哪、会不会被扫描」。
围绕 `deps/pini-swift`（项目唯一真实案例）先后加了三层补丁：

| 层 | 做法 | 状态 |
|---|---|---|
| G49 | 手写 `exclude = ["examples", "deps"]` | 现存 |
| R1' | `deps/` 作保留目录，永不扫描 | 现存 |
| D24 | 固定落点 `deps/<name>/` + 不查深层 | **已撤销** |

**三层的共同错误**：试图用**配置**（exclude / 保留目录 / 落点规则）解决一个本该由**物理布局**解决的问题。
配置会漂移、需要每个模块重复书写；位置错了则立刻可见。

### 实证（`pini-swift`，2026-08-28 测得）

> 以下为**改名前的现状测量**；清单文件名按 R8 改为 `pini.toml` 后，结论不变。

- `.pini` 文件 **60 个**，其中 **52 个不在任何清单管辖下**
- 清单 **3 个**，位于 `examples/{ffi_module, multifile, package-demo}/module.toml`
- **根部无**清单（根部是 SwiftPM 的 `Package.swift`）
- `pini/.gitmodules` → `deps/pini-swift`，而 `pini/module.toml` 在 repo 根
  ⇒ **repo root == module root**，而 git submodule 的 path 不可能在 repo 之外

---

## 2. 核心拆解：扫描 ≠ 依赖图

两个关注点此前被混为一谈，这是三层补丁的根源。

| 关注点 | 由什么决定 |
|---|---|
| **扫描**（哪些文件被加载为本模块源码） | 目录规则：R1 + 点前缀 |
| **依赖图**（谁是依赖） | **只由 `import` + `[require]` 决定** |

**物理位置对依赖图零影响。** 物理上的子模块不会自动成为依赖——只有被显式 `import`
并在 `[require]` 中声明，才进入依赖图。

⇒ 「不扫描会不会破坏模块边界纯粹性」是伪问题：**模块边界纯粹性不由扫描管，由依赖图管。**

---

## 3. 规则

### R5 · 点前缀目录不参与源码扫描

以 `.` 开头的目录，其整棵子树不参与任何模块的源码扫描。

- **只取 `.`，不取 `_`。** `_` 前缀在 Pini 是 **package 级可见性**语义；Go 的 `_` 前缀则是
  「工具完全不可见」。照搬会与 Pini 的可见性语义撞车。
- 这是**推广既有约定，不是新造**：`.pini-build/` `.pini-cache/` 已在 `project-spec` §4 的
  `.gitignore` 基线中。

### R6 · `.pini/` 为工具命名空间根

所有工具管理的非源码内容，统一置于模块根的 `.pini/` 下：

| 路径 | 内容 | 来源 |
|---|---|---|
| `.pini/resources/<name>/` | `[resources]` 落地 | 新增 |
| `.pini/toolchain/<name>/` | 宿主 / 工具链（git submodule） | 新增 |
| `.pini/build/` | 构建产物 | 收编自 `.pini-build/` |
| `.pini/cache/` | 工具链缓存（LSP 索引、增量编译状态） | 收编自 `.pini-cache/` |
| `.pini/version` | 宿主版本 pin | 收编自 `.pini-version` |

**收编的理由**：规则因此只需一句——「`.pini/` 及其下一切不参与扫描」。
不收编则须写成「`.pini/` 及 `.pini-*`」，将来每加一个都会漏。

### R7 · resources 检查：根检，不深检

| 通道 | 目标根 `pini.toml` | 深层 |
|---|:---:|:---:|
| `require X` | **必须有** | 不查 |
| `resources X` | **必须无** | **不查** |

同一个谓词取反，无额外实现成本。

**保留根检的三个理由——都不是「有害」：**

1. **语义清晰**：根清单 = 目标自我声明为 Pini 模块，这正是 D15 分区判据本身。
2. **早期纠错**：误将模块配成 resource 是常见错误，应在 `refresh` 时暴露，
   而不是等到有人想 `import` 它时才发现。
3. **成本近零**：根检代码本来就要为 `require` 的正向判定而写，取反即可。

**取消深检的理由**：`.pini/resources/` 不被扫描 ⇒ 深层清单 **物理上不可能**
造成伪模块边界。为一个结构上无害的情况付一次全树遍历，不值得。

> **注意（防止将来被误推翻）**：D20 原措辞「拒绝下载含 `module.toml` 的库」的理由是
> 「会造成伪模块边界」——该理由在 R6 下**已失效**。R7 的新理由是上述三条。
> 若文档只留旧理由，将来会有人用「反正不扫描，无害」把它推翻。

### R8 · 文件命名：清单 `pini.toml`，锁文件 `pini-summary.toml`

**模块清单 = `pini.toml`**（原 `module.toml`）；**锁文件 = `pini-summary.toml`**（原 `_summary.toml`）。
两者同前缀、同置于模块根，便于配对识别。

**为什么清单必须改名**：R1 以「目录内是否存在清单文件」作**哨兵**判定模块边界。
哨兵必须特异到误判率近零。`module.toml` 是通名，外来工程（非 Pini 项目）携带同名文件
并不罕见，会导致两种误判：

- 该子树被 R1 **静默**排除出扫描——外来工程的目录被当成 Pini 子模块
- `resources` 根检误判 ⇒ 正常资源被拒（R7）

**生态惯例一致**：Go `go.mod`、Rust `Cargo.toml`、Elixir `mix.exs`、Python `pyproject.toml`
——**没有成功者用通名**。`module.toml` 是异类。

> **配套：旧名必须报错，不得静默忽略。** ⚠
>
> 当前实现中「清单缺失」是**静默降级**（`FileLoader.swift:53`：
> `guard FileManager.default.fileExists(atPath: tomlPath) else { return nil }`），
> 目录随即按「隐式根模块兜底」处理（一组独立程序，而非模块）。
>
> **硬切而不配套 ⇒ 既有的 `module.toml` 从「模块边界」退化为「普通文件」：**
> 其下源码被父模块扫入、`findModuleRoot` 的模块身份判定改变，
> **全程不报错**。症状（"这目录的文件怎么被扫进去了"）离原因很远。
>
> ⇒ 工具在模块扫描范围内检测到 `module.toml` 时**一律报错**，提示改名为 `pini.toml`。
>
> 这不是为假想场景造机制：现存量 **4 个**——`pini/module.toml`
> 与 `pini-swift/examples/{ffi_module, multifile, package-demo}/module.toml`。

---

## 4. 落点总表

| 东西 | 位置 | 声明在 | 为何不被扫描 |
|---|---|---|:---:|
| 模块源码 | 模块树 | — | —（要扫） |
| 子模块 | `deps/<name>/` | `[require]` + `import` | **R1**：自带 `pini.toml` |
| resources | **`.pini/resources/<name>/`** | `[resources]` | **R6** |
| 宿主 / 工具链 | **`.pini/toolchain/pini-swift`** | 见 §6-①（搁置） | **R6** |
| 构建产物 / 缓存 | `.pini/build/` `.pini/cache/` | — | **R6** |
| 锁文件 | `pini-summary.toml`（模块根） | 生成，**必须提交** | — |

- `deps/` **只放 `require` 的模块**（各自带 `pini.toml` ⇒ R1 自切），
  **不再是保留目录** ⇒ **R1' 撤销**。
- 资源与宿主落在 `.pini/` 下 ⇒ 宿主自带的 52 个散 `.pini` 与 3 个示例清单
  全部自动失效，**不需要任何一层补丁**。
- 清单改名后，外来工程的 `module.toml` 不再被误认 ⇒ **R1 的误判面归零**（R8）。

---

## 5. `[build] exclude` 的定位（用户裁决）

> **`exclude` 是 `pini test` 收集范围的排除，不是模块树扫描的排除。**

- 依据：`pini-spec-v0.md:109` —— `pini test <path>` 可「加回 `[build] exclude` 排除目录」。
- ⇒ 它属于**测试收集**语义，不属于模块包加载。
- ⇒ 放置问题由 R6 解决，`exclude` 不参与其中。

---

## 6. 待定（本轮搁置）

### ① 宿主版本 / spec pin 的归属 —— **用户裁决：搁置**

已发现的重复事实（恢复讨论时的起点；路径按 R6/R8 已改名）：

```
pini/.pini/version   →  pini 0.48.4 (spec 0.1)
pini/pini.toml       →  spec        = "0.1"
```

**同一个事实（`spec 0.1`）在两处声明。**

恢复时的要点：**读清单需要宿主** ⇒ 写在 manifest 里的宿主版本只能是
**约束**（MSRV 式，不满足即报错），不能是 **pin**（据此切换需要宿主自己，或需要
一个能读纯文本的 bootstrapper）。对照 Cargo：`Cargo.toml` 的 `rust-version`（约束）
与 `rust-toolchain.toml`（实际 pin）是分开的。

### ② `examples/` `bench/` 的归属

`exclude` 不再管扫描后，模块**自己的**非源码目录没有机制。候选：

| 候选 | 做法 | 评价 |
|---|---|---|
| a | 给 `examples/` 一个 `pini.toml` ⇒ R1 自切 | 与 §2 一致（不是依赖，除非被 import）；但引入「幽灵模块」观感 |
| b | 移入 `.pini/` 下 | 与 R6 统一；但示例通常希望可见 |
| c | 保持现状，待观察 | 需先明确「不被扫描」的机制是什么 |

### ③ resources 的寻址方式

不被扫描 ⇒ 不能 `import` ⇒ 只能按路径读写。
**v1 只做「落地 + 校验」，寻址方式后定——但不在文档中假装已解决。**

---

## 7. 落档清单（批准后执行）

### A. `issue-module-system-rules-2026-08-28.md`（pini-meta）

- [x] §2 增 **R5 / R6 / R7 / R8**
- [x] §3.3 `resources`：落点改 `.pini/resources/<name>/`；检查改「仅根检」，并按 R7 改写理由
- [x] §3.5 锁文件名 `_summary.toml` → **`pini-summary.toml`**
- [x] **删 R1'**（改为划删 + 保留撤销理由与其原始动机）
- [x] **D20** 措辞：由「拒绝下载含 `module.toml` 的库」改为「目标根含 `pini.toml` 即拒」，并标注由 D26 收窄
- [x] 新增 **D24（R5）/ D25（R6）/ D26（R7）/ D27（`exclude` 定位）/ D28（R8 改名）**
- [x] §8 第 6 行：旧措辞同步为「根检」，并标注 D26 收窄
- [x] 全文改名：清单 `module.toml` → `pini.toml`；`_summary.toml` → `pini-summary.toml`
- [x] 加「改名溯源」注：说明本工单原文用旧名，**纯改名不改决议实质**，故 D1/D15/D20 等**现行规则**的文本一并更新
- [x] §5 连带决议：无需改动——工单 §5 未提及 `.pini-build/` / `.pini-cache/`，收编只落在 `project-spec`

> **原清单中有两条经核查不成立，已删**：
> ① 「删 D24」——D24 **只存在于被回滚的分支**，主干从未有过；
> ② 「§8 待观察删两条」——那两条待观察项**主干上也不存在**（只写在本稿里）。
> 教训：**清单条目要对着目标文件的实际内容核，不能对着记忆写。**

### B. `pini-project-spec.md`（pini-meta）

- [x] §4 `.gitignore` 基线：`.pini-build/` → `.pini/build/`，`.pini-cache/` → `.pini/cache/`
- [x] **`.pini/resources/` 与 `.pini/toolchain/` 必须显式不进 `.gitignore`**
      ⚠ **陷阱**：本项目既有的点目录**全部**在 `.gitignore` 里，「点前缀 = 不进版本控制」
      已成直觉。不显式豁免，`verify` 会在换机器后才报内容缺失。
      （与 `pini-summary.toml` 同类：生成物 / 外来物，但必须提交。）
- [x] §2 `deps/` 边界性质：由「R1' 保留目录永不扫描」改为「只放 `require` 的模块，R1 自切」
- [ ] §7 清单 schema：`resources.*` 增落点说明；`build.exclude` 标注为**测试收集**语义

### C. `pini-spec-v0.md`（pini-meta）

- [x] §2.5 依赖图与跨模块访问：双通道判据改「目标**根**有无 `pini.toml`」；
      新增 resources 落点 `.pini/resources/<name>/`、R5–R6 落点与扫描、**R8 文件命名**三段
- [x] G49 行：`[build] exclude` 定位收窄为测试收集（标注 D27 收窄）

### D. 改名专项 `module.toml` → `pini.toml`（**三仓同步**，约 144 处 / 28 文件）

| 仓 | 处 | 主要落点 |
|---|---|---|
| `pini-meta` | ~94 | 工单 G52 **31**、project-spec **18**、本稿、spec-v0 **11**、adr-018 3、`Pini草稿` 3、其余文档 |
| `pini-swift` | ~48 | `FileLoader.swift` **10**、`main.swift` **11**、`CLIDirectoryTests` **10**、`ModuleTestCollectionTests` 2、`FFIModuleTests` 2、示例 `.pini` 注释 |
| `pini` | 2 | `module.toml` 自身、`GIT_WORKFLOW.md` |

**改动点：**

- [x] **`pini-swift` / `FileLoader.swift`**：新增 `manifestFileName = "pini.toml"` /
      `legacyManifestFileName = "module.toml"` 两个常量（commit `080023e`）
- [x] **`pini-swift` / `FileLoader.loadManifest`**：**新增旧名探测**——无新名且存在 `module.toml`
      即抛 `LoaderError.legacyManifestName`（R8 配套，**缺此项硬切会静默降级**）
- [x] `pini-swift`：`Sources/PiniCLI/main.swift`、`Tests/**`、示例 `.pini`/`.c` 注释同步改名
- [x] `pini-swift/examples/{ffi_module, multifile, package-demo}/module.toml` → `pini.toml`
- [x] **`pini-swift` 新增 2 测试**：旧名必抛错 + 新名正常加载（后者防前者写成恒真）
- [x] `pini/module.toml` → `pini.toml`（commit `b4f8405`）
- [x] `pini-meta`：**实测 119 处 / 10 文件**（`module.toml` 91 + `_summary.toml` 28）

**同步顺序（避免断链）：**

1. ~~`pini-swift` 改名 + `swift test` 全绿 + **推送**~~ ✅ 改名与测试已完成（`080023e`），**推送待做**
2. ~~`pini/` 改名~~ ✅ 已完成（`b4f8405`）；~~更新 submodule 指针~~ ⏸ **暂缓**（见 E）
3. ~~`pini-meta` 文档收尾~~ ✅ 进行中（本分支）

⚠ `pini-swift` 当前 **ahead 未推**。若跳过第 1 步的推送，`pini/` 会指向本地不存在的 commit。

**验收：✅ 已通过** —— `swift test --disable-sandbox` →
**1012 tests / 0 failures / 20 skipped / All tests passed**（36.5s）。
两个新测试确认在套件中实际执行并通过。
（原计划靠「先红后绿」验收；实际因改名与测试同批完成，直接以全绿验收。）

> **环境教训**：`dangerouslyDisableSandbox: true` 对本仓库**无效**（前台后台均 1 秒失败）。
> 正解是命令自带 **`swift test --disable-sandbox`**——症状 `sandbox-exec: sandbox_apply: Operation not permitted`
> 发生在 **Package.swift manifest 编译阶段**，与 XCTest 无关。

### E. `pini/` 仓（其余）

- [x] `.pini-version` → `.pini/version`（commit `227d269`）
- [ ] `pini.toml`：**清 `[dependencies]`**（D17 已移除，此仓仍在用）
- [ ] `.gitmodules`：`deps/pini-swift` → `.pini/toolchain/pini-swift`
- [ ] `pini.toml`：`exclude = ["examples", "deps"]` → `["examples"]`

⚠ **后三项必须按序执行，顺序错了会出事**：
**先移宿主 → 再删 `exclude`**。反过来的话，宿主仍在 `deps/pini-swift` 而 `exclude` 已删
⇒ 其 **52 个散 `.pini`** 会被根模块扫入。
而改 submodule path **需要 submodule 已检出**才能验证——本工作区未检出（`pini/deps` 为空，
`git status` 显示 ` D deps/pini-swift`）。⇒ 需先 `git submodule update --init`。

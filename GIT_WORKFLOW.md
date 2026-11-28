# Pini Git 工作流元信息

> **单一事实源（Single Source of Truth）。** 本文件是项目级 Git 协作约定。任何会话——无论是人还是 AI 助手——在修改本仓库前都应先读取本文件，并遵守其中的**分支策略**与**身份注册规则**。

---

## 1. 目的

1. 多会话 / 多人**并发修改**时和谐协作（多分支、互不踩踏）。
2. 通过「**人类可读唯一标识注册**」防止**提交者名称弹跳（committer-name bouncing）**——即同一贡献者在跨会话时 `user.name` / `user.email` 频繁变化，导致 `git blame` / `git log` 难以追溯。

---

## 2. 贡献者注册表（唯一标识 → 规范身份）

每个贡献者必须在此注册一个**稳定且人类可读的唯一 ID**，并固定其规范 `user.name` / `user.email`。
**提交前必须把本地 git 身份设为该 ID 对应的规范值。** 不在下表中的身份会被 pre-commit 钩子拒绝（见 §5）。

| 唯一 ID | 类型 | 规范 `user.name` | 规范 `user.email` | 说明 |
|---|---|---|---|---|
| `human:winterarch` | 人 | WinterArch | winterarch@foxmail.com | 项目所有者 / 主力开发者（可选采用，便于区分归属） |
| `agent:pini` | 自动化代理 | Pini Dev | dev@pini.local | 通用 AI 助手会话（默认）；与历史提交保持一致，避免弹跳 |
| `agent:<session-id>` | 自动化代理 | Pini Dev | dev@pini.local | 其他 AI 会话：在 `agent:` 后追加唯一片段以区分 |

**注册新贡献者：** 复制上表任意一行，填入唯一 ID、类型与规范身份，然后提交本文件。
ID 命名规则：`human:<handle>` 或 `agent:<handle>`，需**全局唯一**且**人类可读**（禁止临时捏造的名字）。

### 身份纪律（防弹跳核心）

- 提交前务必执行（以默认 AI 会话为例）：
  ```bash
  git config user.name  "Pini Dev"
  git config user.email "dev@pini.local"
  ```
- 不得直接使用全局身份（如 `WinterArch`）或临时名字提交，**除非该名字已作为你的 ID 登记在上表中**。
- 若当前 `user.name` / `user.email` 不在注册表，pre-commit 钩子会**拒绝提交**，并列出已登记身份。

---

## 3. 并发多分支策略

- **主干保护：** `main` 为受保护分支，**任何会话都不得直接提交到 `main`**。所有改动走特性分支。
- **分支命名：**
  - 特性：`feature-<id>-<slug>`
  - 修复：`fix-<id>-<slug>`
  - AI 会话临时工作：`dev-agent-<id>-<slug>`
  - 其中 `<id>` 取 §2 注册的唯一 ID，`<slug>` 为短横线小写描述。
  - 注意 **引用名禁用字符：** git 不允许 `:` 出现在分支名中。因此在分支名里把注册 ID 的 `:` 替换为 `-`。例如注册 ID `human:winterarch` 对应分支前缀 `human/winterarch`；AI 默认会话 `agent:pini` 对应 `dev-agent-pini`。
- **基线：** 从最新的 `main` 切出；开工前先 `git fetch`（若存在远程）确认基线最新。
- **集成回 `main`：**
  - 推荐 `git merge --no-ff <branch>`（保留分支拓扑，便于回溯）。
  - 或个人分支上 `git rebase main` 保持线性；
  - **禁止对已经推送 / 被他人依赖的共享分支做 rebase 或任何历史改写。**
- **冲突解决：** 本地解决。用 `git status` 与 `git diff --name-only --diff-filter=U` 定位冲突文件；解决后 `git add` 再继续。

---

## 4. 提交信息约定（延续历史风格）

沿用本仓库既有的 **Conventional Commits** 风格（英文、现在时、祈使）：

- 类型：`feat` / `fix` / `test` / `refactor` / `chore` / `docs` / `style` / `perf`
- 格式：`<type>(<scope>): <subject>`，`scope` 可选；多行正文用空行分隔。
- 示例：
  - `feat(stdlib): add string member methods and math free functions`
  - `test(parser): cover generic construct with args and multiple type params`
  - `chore(git): add workflow meta-info and contributor registry`
- 不要用无意义的消息（如 `workbuddy`、`wip`）——若确需草稿提交，用 `chore: ...` 并随后改写。

### 4.1 提交时机与跨仓配对

- **完成即提交**：一个可验收的改动（门禁跑完、读数在手）完成即提交，不攒批、不等提醒。
  未提交的改动不算交付——换分支或切工作树都会把它带走。
- **跨仓配对**：判据（本仓的规范与计划）与实现（`pini-bootstrap`）同轮提交，两笔各自引用
  对方仓名与主题；不让规范单独挂着等实现，也不让实现先于判据进主干。
- **按改动面选门禁**：

| 改动面 | 至少跑 |
|---|---|
| 规范 / 计划 | `tools/check-doc-links.sh` |
| Swift 源码 | `swift test` |

注意 规范改动先在本仓定判据，再由 `pini-bootstrap` 的实现在同一轮追平；两笔提交的主题
各写清判据侧与实现侧，便于 `git log` 对上。

### 4.2 提交之后：合并、验证与升种子

- **合并前**：分支上跑完 §4.1 的门禁，`git fetch` 确认 `main` 最新。
- **合并**：`git merge --no-ff <branch>`。合并提交由 `pre-merge-commit` 在容器里跑
  `ci/run.sh`；Docker 不在就拒绝，不降级放行。
- **推送**：合并通过后推 `origin main`。
- **回退**：合并在钩子上失败就回分支修；已推送的 `main` 出错用新提交前滚，不在 `main` 上
  rebase 或 force push。
- **供种子钉住**：合并后的 `main` 哈希即 `pini-bootstrap` 的 `seed/pin.toml` 要钉的值。
  只改规范与文档不升种子，改 `Sources/` 或 `Package.swift` 才升；`seed/bin.toml` 重登、
  生成器与全量门禁的步骤见对方仓 §4.2。

---

## 5. 防弹跳强制（可选启用，推荐）

仓库提供两个钩子：

- `hooks/pre-merge-commit`：`git merge` 不跑 `pre-commit`，合并提交由它置 `PINI_MERGE_GATE` 后转交，判据只有一份。
- `hooks/pre-commit`：① 校验 author / committer 身份是否已在 §2 注册；② 注释门禁；③ 格式门禁（含「产物不旧于源码」；落后时本地删产物重链，CI 里仍只读拒绝）；④ 合并提交经 `ci/run.sh` 起容器跑整条 `ci/entrypoint.sh`（构建、全部门禁、带 `PINI_CLI_BIN` 的测试）。

第 ④ 项必须走容器，不在宿主上直接跑 `ci/entrypoint.sh`：两者系统、LLVM 版本与编译器分支都不同，
`#if canImport(Darwin)` 覆盖的 Linux 代码在宿主上根本不参与编译。合并提交是交给远程前的最后一道本地判据，
宿主读数替代不了容器读数。Docker daemon 未运行时钩子**拒绝提交**并给出启动命令，不降级放行。

判据看 `MERGE_HEAD` 而不是分支名——并回主干就是待推送状态，等推送再验已经晚了；合并被拦下后补 `git commit` 时它仍在，CI 会再跑一遍。

启用（一次性，仅本地）：

```bash
git config core.hooksPath "$(git rev-parse --show-toplevel)/hooks"
```

钩子逻辑：若 `user.name` 或 `user.email` 不在注册表，打印已登记列表并**拒绝提交**。
> 说明：必须用**绝对路径**（上例用 `git rev-parse --show-toplevel` 自动解析，兼容任一工作树），不要用相对路径 `hooks`——相对路径在链接工作树下会按当前工作树解析，易出错。设置后该目录取代默认 `.git/hooks`；若还需其他钩子，请一并放入 `hooks/` 目录。

### 5.1 注释门禁的后端选择（`PINI_RG`）

`hooks/comment-lint.sh` 优先用 ripgrep，缺失时回退 `grep -E`。**两个后端的判据等价**
（已在真仓与变异树上比对为逐行一致），差异只在速度，以及「哪一端实际跑了哪条路径」：

| 端 | 实际后端 | 说明 |
|---|---|---|
| GitHub Actions（Ubuntu 容器） | `grep` | 容器不装 ripgrep；GNU grep 快，无感知 |
| macOS + Homebrew | `ripgrep` | 经绝对路径候选命中（brew bin 可能不在 `PATH`） |
| 其他环境 | 视 `PATH` | 探测顺序见下 |

探测顺序：`PINI_RG` → `PATH` 中的 `rg` → 绝对路径候选
（`/opt/homebrew/bin/rg`、`/usr/local/bin/rg`、`/usr/bin/rg`）。
候选的**作用域只有一种情形**：macOS 装了 ripgrep 但 brew bin 未进 `PATH`。
Linux 上经 apt/snap 安装的 rg 必在 `PATH`（`command -v` 先命中），候选不会生效 ——
它是 macOS 例外通道，不是跨平台兜底。

> 注意 **为什么不能只查 `PATH`**：本仓对「工具装着但 `PATH` 里看不见」有明确规定 ——
> 判某个外部命令是否可用，不得只看自动化 / 代理环境的默认 `PATH`，须在完整登录 shell 里实测；
> `command -v lli` 曾两次造出假「门关」结论。可执行的部分落在 `LLVMToolchain` 的四级回退与
> `LLVMToolchainTests` 上（装着就得找到，没装才算没有），人工复核仍在完整登录 shell 里做。
> 只在 `PATH` 里找 rg，会让脚本**静默回退**到最慢后端；若该后端的 `grep` 又被代理存根接管，
> 7 趟全树扫描会从 1 秒膨胀到约 9 分钟。未找到 ripgrep 时脚本会打印一行 `[后端]` 提示，
> 便于从 CI 日志判断实际走了哪条。

指定后端（CI 或非常规安装位置）：

```bash
PINI_RG=/path/to/rg git commit -m "..."
```

---

## 6. 新会话快速上手

1. 读取本文件。
2. 在 §2 确认或登记你的唯一 ID。
3. 执行 `git config user.name / user.email` 设为规范值。
4. 从 `main` 切出特性分支，按 §3 / §4 工作。
5. 完成后合回 `main` 并（若有远程）推送。
6. 宿主只构建 release：`swift build -c release --disable-sandbox`。门禁、钩子与 CI 只认
   `.build/release/pini`；`tools/host-profile-check.py` 会拦下脚本与命令里写回的 debug 二进制。
7. 自举实现在 `pini-bootstrap` 仓：本仓不再包含自举树，也不再跑它的门禁。两边的对照
   （差异普查、命令行对照、语料）归那个仓；本仓只守宿主实现与语言规范，不再有第二份源码。

> 注意 缺 release 产物时门禁直接拒绝并打印构建命令，不静默回退 debug：两份产物的读数不可比，
> 且 debug 下整套门禁慢数倍。

> 注意 **开工前先 `git status -sb` 确认所在分支**：本仓库主干为 `main`，改动一律走特性分支（§3）。

---

## 7. 仓库拓扑：单工作树 + 嵌套独立仓

### 本仓

单一 `.git`、单一工作树（`Projects/Pini语言语法与Swift-Package实现_20260827/pini-swift`），分支 `main`，远程 `origin = github.com/pini-lang/pini-swift`。如需并行工作，按 §3 用 `worktree/<purpose>` 前缀新增工作树：

```bash
git worktree add <path> -b worktree/<purpose> main
git worktree remove <path>    # 摘除务必用命令，勿直接 rm
```

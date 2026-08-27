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
| `agent:pini-dev` | 自动化代理 | Pini Dev | dev@pini.local | 通用 AI 助手会话（默认）；与历史提交保持一致，避免弹跳 |
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

- **主干保护：** `master` 为受保护分支，**任何会话都不得直接提交到 `master`**。所有改动走特性分支。
- **分支命名：**
  - 特性：`feature/<id>/<slug>`（例：`feature/human/winterarch/stdlib-io`）
  - 修复：`fix/<id>/<slug>`
  - AI 会话临时工作：`agent/<id>/<slug>`
  - 其中 `<id>` 取 §2 注册的唯一 ID，`<slug>` 为短横线小写描述。
  - ⚠️ **引用名禁用字符：** git 不允许 `:` 出现在分支名中。因此在分支名里把注册 ID 的 `:` 替换为 `/`。例如注册 ID `human:winterarch` 对应分支前缀 `human/winterarch`；AI 默认会话 `agent:pini-dev` 对应 `agent/pini-dev`。
- **基线：** 从最新的 `master` 切出；开工前先 `git fetch`（若存在远程）确认基线最新。
- **集成回 `master`：**
  - 推荐 `git merge --no-ff <branch>`（保留分支拓扑，便于回溯）。
  - 或个人分支上 `git rebase master` 保持线性；
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

---

## 5. 防弹跳强制（可选启用，推荐）

仓库提供 `hooks/pre-commit` 钩子，在每次提交时校验 author / committer 身份是否已在 §2 注册。
启用（一次性，仅本地）：

```bash
git config core.hooksPath "$(git rev-parse --show-toplevel)/hooks"
```

钩子逻辑：若 `user.name` 或 `user.email` 不在注册表，打印已登记列表并**拒绝提交**。
> 说明：必须用**绝对路径**（上例用 `git rev-parse --show-toplevel` 自动解析，兼容任一工作树），不要用相对路径 `hooks`——相对路径在链接工作树下会按当前工作树解析，易出错。设置后该目录取代默认 `.git/hooks`；若还需其他钩子，请一并放入 `hooks/` 目录。

---

## 6. 新会话快速上手

1. 读取本文件。
2. 在 §2 确认或登记你的唯一 ID。
3. 执行 `git config user.name / user.email` 设为规范值。
4. 从 `master` 切出特性分支，按 §3 / §4 工作。
5. 完成后合回 `master` 并（若有远程）推送。

> ⚠️ **开工前先 `git worktree list` 确认自己位于哪一棵树**（见 §7）：本仓库挂接了多个物理工作树，不同目录共享同一 `.git` 对象库。务必先定位当前工作树与所在分支，再动手，避免跨树混淆。

---

## 7. 仓库拓扑：多工作树（worktree）

本仓库在**单一 `.git` 对象库**下挂接多个物理工作树（不同目录共享同一份历史，互不漂移）。任何会话都可能身处其中任一目录——开工前先 `git worktree list` 确认自己位于哪一棵树。

### 当前已登记的工作树

| 物理目录 | 角色 | 分支 | 说明 |
|---|---|---|---|
| `Projects/Pini语言语法与Swift-Package实现_20260808/Pini` | 主工作树 | `master` | 常规开发主入口 |
| `Downloads/Pini语言语法与Swift-Package实现_20260808/Pini` | 次要工作树 | `worktree/secondary` | 与主树内容一致，可作另一会话 / 人并行或暂存之用 |

> 两树的 `.git` 指向同一对象库（次要树的 `.git` 是**链接文件**而非目录）。它们**不是**两个独立仓库，不存在“落错仓库”风险。

### 操作纪律（worktree 专属）

- **提交安全：** 在任一工作树提交都写入同一仓库；主操作仍建议放在主工作树（`master`）。
- **分支互斥：** 同一分支不能同时在两个工作树 checkout。主树已占 `master`，故次要树用专用分支 `worktree/<purpose>`（当前 `worktree/secondary`）。新增工作树沿用此前缀，避免与 `feature/*` / `fix/*` / `agent/*` 冲突。
- **新增工作树：**
  ```bash
  git worktree add <path> -b worktree/<purpose> master
  ```
- **摘除工作树（务必用命令，勿直接 `rm`）：**
  ```bash
  git worktree remove <path>      # 有未提交改动会拒绝；确认干净或用 --force（慎用）
  ```
- **钩子跨树生效：** `core.hooksPath` 已设为绝对路径，保证从任一工作树提交都触发 §2 身份校验。
- **记忆目录 `.workbuddy/` 位于仓库父级**（不在 `Pini/` 内），未被 git 跟踪，不属任何工作树。

### 排障

- 若某工作树变成“独立仓库”（两侧 `git worktree list` 各只显示自己），即发生目录分叉。恢复：移除分叉目录的 `.git`，再 `git worktree add` 挂回主仓库。
- 切换工作树前先 `git status` 确认无未提交改动，避免跨树混淆。

---

*本文件由 `agent:pini-dev` 于仓库初始化协作约定时建立，随仓库提交，所有会话默认读取。§3 分支命名修正（去除 git 禁用的 `:`）、§5 改为绝对 `hooksPath`、§7 多工作树布局于 2026-08-09 增补，反映 worktree 统一后的实际拓扑。*

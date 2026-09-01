# ADR-024: 规范治理归位——撤销元仓、三层规范模型与自举探针定位

## Status

Accepted（2026-08-30，用户批准）

**Supersedes（部分撤销）**：ADR-018 的 **M1 / M2 / D1**，及其「自举成功定义」

---

## Context

**元仓 `pini-meta` 设计失效**（ADR-018 M1 / M2 所立）。根因是**切分轴选错**：按「资产类型」（文档 vs 数据）切分，而真实内聚轴是「语言 vs 实现」——欲解耦「规范 vs 实现代码」，却把「规范 vs 承载规范的仓库」一并解耦。失效表征：元仓无 remote，锚点机制从未存在；跨仓引用腐烂且**不可检测**；comment-lint L6 因登记表迁走而关闭；lint 副本反由一份增至三份；钉版与工具链版本分处两仓必然漂移；ADR-023 记录了「实现先于 spec」的越界。

**submodule 无消费者**：pini 的差分脚本直读旁挂克隆的构建产物；`.pini/toolchain/pini-swift` 从未被构建、零处代码引用。

**自举定位重定**（用户裁决 2026-08-30）：自举是**探针**而非目标——其价值在于暴露宿主缺陷并提案修改。实证：近期 5/6 项 ADR 由自举触发；因探针仅覆盖到 lexer，其发现亦集中于 lexer / 字符类。

---

## Decision

### D1 撤销 ADR-018 M2：元仓解散，内容三向切分

`pini-meta` **归档保留**（README 顶部标注、停止写入，不删除——可逆性优先）。内容按「**谁必须对它采取行动**」切分：

| 目的地 | 内容 | 判据 |
|---|---|---|
| `pini-swift/docs/spec/` | `../pini-spec-v0.md`、`../pini-project-spec.md`、`../pini-comment-style-guide.md`、`../pini-glossary.toml`、`../en-zh-translation-map.md`、`../diagnostic-codes.md`、`../test-refactoring-principles.md`、`../pini-roadmap-next.md`、`../pini-landing-plan-v048.md`、`../evidence-table.toml`、语言 CHANGELOG、**语言级 ADR** | 对所有实现成立 |
| `pini-swift/docs/` | ADR-022（宿主级）、宿主侧 `issue-*.md`、BUILDING、实现级 CHANGELOG | 仅对 pini-swift 成立 |
| `examples/selfhost/docs/` | `pini-bootstrap-architecture.md`、`code-style.md`、`abbreviations.md`、自举侧 `issue-*.md` | 仅对自举成立 |

### D2 撤销 ADR-018 M1 / D1：自举入树为嵌套独立仓

- 自举项目置于 **`pini-swift/examples/selfhost/`**，为**独立 git 仓**（自有 `.git`）
- 目录名取 `selfhost`，以避开与宿主可执行文件 `pini`（`.build/debug/pini`）撞名
- `pini-swift/.gitignore` 增列 **`/examples/selfhost`**（锚定仓库根，须带前导斜杠）
- 自举侧移除 submodule `.pini/toolchain/pini-swift`
- 自举仓**接受本地唯一副本，不设 remote**（定位为探针，非交付物）

**隔离效果**（git 结构保证，/tmp 实测）：

| 维度 | 结果 | 依据 |
|---|---|---|
| 不进 pini-swift 历史 | ✅ | git 结构性地不跟踪嵌套仓内容 |
| 不进 release 归档 | ✅ | 被忽略者不入 `git archive`（**无需再配 `export-ignore`**） |
| 不被 clone 获取 | ✅ | 新克隆者完全看不到 |
| 无 submodule / 无 pin / 无漂移 | ✅ | 钉版漂移这一类失效被根除 |
| `git clean -fdx`（单 f）误删 | ✅ 安全 | git 保护含 `.git` 的目录；仅 `-ffdx` 才会删 |

> **命名说明**：目录名取 `selfhost`，以避开与宿主可执行文件 `pini`（`.build/debug/pini`）撞名。其愿景含义见 `../pini-roadmap-next.md` §2.5，本 ADR 不重述。

### D3 三层规范模型

| 层 | 名称 | 归属 | 消费者 |
|---|---|---|---|
| **L1** | 语言规范 | `pini-swift/docs/spec/`（**SSOT**） | pini-swift + 自举 |
| **L2** | 宿主项目规范 | `pini-swift/docs/` + `GIT_WORKFLOW.md` | 仅 pini-swift |
| **L3** | 自举项目规范 | `examples/selfhost/docs/` | 仅自举 |

**selfhost 拥有自己的项目规范**（L3，落 `examples/selfhost/docs/project-spec.md`）：明确声明遵循 L1 的哪些条款，并列出自举专属增量（英文纪律 D3、五档命名 G4、阶段目录、差分门禁、`.pini/baseline` 纪律）。

L3 **不复制 L1 正文**，只持路径引用（`../../docs/spec/`）——**指针而非副本**，避免重蹈元仓「副本漂移不可检测」的覆辙。因二者现处同一文件树，链接有效性**可被脚本校验**（见「挂账」第 8 项）。

### D4 自举验收判据换挡

ADR-018 的验收定义「差分全绿 + **能编译自身**」→ **当前阶段改为「差分全绿 + 覆盖面持续推进」**。

**长期愿景不在本 ADR 定义**，见 `docs/spec/pini-roadmap-next.md` §2.5（自举北极星）。本 ADR 不重述愿景。

> 推论：**推进自举阶段覆盖 = 最高杠杆投资**。每推进一步，打开一整类从未被检验的宿主行为。

### D5 双段落地律（Two-Stage Landing）

语言级变更 = **规范段**（L1 治理，走 spec §1.3 流程）+ **实现段**（L2 治理，走 GIT_WORKFLOW），由**同一 ADR ID 串联**；规范段先于或同期于实现段合并。

> **ADR-023** Status 自记的「实现先于 spec」越界，即本律记录在案的反例。

### D6 ADR 分层：编号共享、归属分流

| | 语言级 ADR | 宿主级 ADR |
|---|---|---|
| **判据** | 改变**语言契约**（语法 / 语义 / 诊断码语义 / 标准库契约 / 项目布局） | 改变**实现方式**（架构 / 后端 / 性能 / 工具 / 分发 / 测试基建） |
| **落位** | `docs/spec/adr/` | `docs/adr/` |
| **完成标志** | spec v0 相应章节已修订 + 证据登记 | 代码落地 + 测试通过 |
| **治理流程** | spec §1.3（提议→ADR→spec→实现→证据） | GIT_WORKFLOW（分支→PR→lint→tag） |

**编号继续共享**——全仓 180 处注释引用裸 `ADR-NNN`，ID 空间须全局唯一，否则 comment-lint L6 的兑付直接崩溃。`adr-index.md` 因此由「目录」变为**登记表**，指向两处。

**既有 ADR 重分类**：ADR-019 / 020 / 021 / 023 → 语言级；**ADR-022（分发）→ 宿主级**（spec v0 中零引用）；ADR-018 → 拆分（D/G 系列随自举走，M 系列由本 ADR 撤销）。

### D7 自举提案必须落在宿主侧

自举产生的发现与提案写入 `pini-swift/docs/issue/`（语言级则升格为 ADR），**不留在自举仓内**。

**理由**：selfhost 是**宿主的示例**——它因宿主而存在、为宿主服务；提案留在自举仓，等于放在宿主团队不会去看的地方。

### D8 标定记录取代版本钉

`.pini/version` → **`.pini/baseline`**，语义由「拉取指令」改为「标定记录」：

```
host=<sha> version=<version> spec=0.1 verified=<date>
```

因宿主与语言规范同在 pini-swift 一仓，**单个 sha 同时钉住工具链与规范**，结构上**不可能不一致**（优于旧的双钉方案：submodule sha + version 字符串）。差分失败时可据此判定是宿主移动还是自举移动。

### D9 探针信度约束

自举作为**交付物**无关紧要，但作为**测量仪器**其信度是承重的：

- 差分门禁须保持可运行（P2 粒度：**码 + 位置 + 形状**；黄金文件字节级）
- 每次标定后更新 `.pini/baseline`
- **不得伪造 baseline**：差分若红，如实记红并挂账——伪造的 baseline 会直接摧毁探针信度

> 一个腐烂的探针比没有探针更糟——它消耗注意力却不产出可信信息。**信度 > 寿命**。

**内建新增不设禁令**：为自身便利新增宿主内建是合法的快速解——**`BuiltinRegistry`（ADR-020 D3/D4）本身即此路径的先例**：逐个便利新增 → 三处手工同步之痛积累 → 统一路径浮现 → ADR 追认。收敛时机交由工程实践判断，不在本 ADR 预判。

**配套（唯一要求）**：新增内建时在 `BuiltinRegistry` 声明处**以注释标注动因**，使积累**可见、可 grep**。以可观测性替代无法强制的禁令。

### D10 保留的纪律

ADR-018 中继续有效：D2（目录布局）、D3（英文项目）、D2-注释（`#` 声明头 / `;` 行尾）、G1（纯重述驱动 + 拓扑序 + 基线先行）、G3（统一诊断枚举）、G4（五档命名）、P2（差分粒度）、P3（零中文标识符）。

---

## Consequences

**变容易（增益）**

- 规范与实现同仓 → 引用腐烂**可被 CI/grep 检出**（此前结构上不可检测）
- 无 submodule、无 pin → **钉版漂移这一类失效被根除**
- comment-lint **L6（ADR 兑付）可恢复**（adr-index 回到本仓）
- 自举提案直达能行动的一方（D7）
- 规范版本与工具链版本由单个 sha 统一（D8）
- 元仓「每拖一天多一天内容落错地方」的压力解除

**变困难（代价）**

- **CI 无法运行自举差分门禁**——CI 拿不到被 gitignore 的 `examples/selfhost`。差分维持手动门禁，**与今日状态持平，未变差但也未变好**
- 自举仓为本地唯一副本，**存在单点丢失风险**（已接受：探针定位）
- 新开发者 clone 后无 `examples/selfhost`，需文档 / setup 说明
- 自举入宿主树后，「顺手给宿主加内建」的摩擦下降——**不视为风险**（D9：便利新增是合法快速解，收敛交由实践），但要求动因可 grep

**挂账（后续必办）**

1. **元仓三向切分**（D1）
2. **8 处引用腐烂待改**（原列 7 处，补 1）：
   - pini-swift 侧：`README.md`×3（312/314/331 行）、`docs/README.md`、`docs/CHANGELOG.md` 首行、**`GIT_WORKFLOW.md` §7（`master`→`main`、worktree 路径过期、需增列 `examples/selfhost` 为嵌套独立仓）**
   - selfhost 侧：`GIT_WORKFLOW.md` §7（拓扑与路径全改）、`docs/code-style.md` 头部、`pini.toml` 注释
3. **`../pini-project-spec.md` 4 处过时点待修订**：
   - §7.1 注称「宿主归 `.pini/toolchain`（见 §2）」但 **§2 表中无该条目**，交叉引用指向不存在的小节
   - §2 `deps/` 判据「根含 `pini.toml`」**对宿主失效**（宿主含 `Package.swift`）
   - §4 `.gitignore` 同时 ignore `deps/` 又说 submodule 被跟踪（注释已自认矛盾）
   - §1 未表达 `.pini/version` 的「工具链 + 规范双钉」语义（将由 D8 改写）
4. **自举入树 + submodule 移除**（D2）。**顺序：先移动、再改路径**——否则 `diff_tokens.sh` 的 `HOST` 路径会被改两遍
5. **`.pini/baseline` 初始值必须实测确立**：迁移后**立即跑一次差分门禁**。**若红，如实记录红状态并挂账，不得伪造绿**——伪造的 baseline 会毁掉探针信度（D9）
6. **`spec` 双重声明需校验**：`pini.toml` 的 `spec = "0.1"` 是「**意图声明**」，`.pini/baseline` 的 `spec=` 是「**实测观察**」。二者须一致并由门禁校验——否则等于又造了一对会漂移的双钉，重蹈 D8 所要根除的覆辙
7. **ADR-018 的归属**：留在 `docs/spec/adr/`，标注「**部分被 ADR-024 取代**」；其 D/G 系列的实施细则进 `selfhost/docs/`。**ADR ID 兑付不得中断**（全仓 180 处注释引用裸 ID）
8. **链接校验**：L3 对 L1 的路径引用须可校验。新增 `tools/check-doc-links.sh`（或并入 comment-lint）并纳入 CI——这是 ADR-018 M1 当年**结构性缺失**的能力
9. **实测清单**：① `examples/selfhost/` 带 `pini.toml` 后是否影响 G49 `pini test` 收集 ② 差分门禁在新路径下能否跑通 ③ `linux-test.yml` 是否受 `examples/selfhost` 存在影响 ④ comment-lint 在 `.pini` 文件上是否工作
10. **comment-lint 副本收敛**：元仓归档后规则事实源在 `docs/spec/pini-comment-style-guide.md`，脚本保留**两份**（宿主扫 Swift / 自举扫 Pini），各自头部注明事实源位置
11. **`examples/` 语义分裂**：立约定——顶层 `.pini` = 差分 corpus；带 `pini.toml` 的子目录 = 独立项目，由 R1 哨兵自动切出扫描
12. **`adr-index.md` 转型为登记表**：迁至 `docs/spec/adr/`，增「层级」列（语言级 / 宿主级），指向两处落点

---

## 相关

- **前置**：ADR-018（部分被取代，ID 保留可兑付）、ADR-022（重分类为宿主级）、ADR-023（D5 的反例）
- **产物**：`docs/spec/` 目录结构、`.pini/baseline`、本 ADR
- **后续**：见「挂账」12 项。建议执行顺序——① 本 ADR 批准 ② 元仓三向切分 ③ 8 处引用修正 + 链接校验脚本 ④ `../pini-project-spec.md` 修订 ⑤ 自举入树（先移动后改路径）+ submodule 移除 ⑥ 跑差分门禁确立 baseline ⑦ 四项实测 ⑧ `adr-index.md` 转登记表 ⑨ pini-meta 归档（最后）

---

## 后记（2026-08-30）：pini-meta 删除

内容全部迁出并通过验收（③ 引用校验 / ⑥ 差分 MATCH / ⑦ 四项实测）后，`pini-meta`
于同日**直接删除**——修订 D1 的「归档保留」：持有成本虽近零，但工作区留有一个
名字带 meta 的只读目录，会持续诱发「去元仓看看」的错觉，与「同一件事只写一处」
冲突。56 个（实为 60 个）文档提交的演进史随之丢弃，按 M2 原则由 ADR/CHANGELOG
语义化承载；**未做 bundle 存档**（用户裁决，接受不可逆）。

归档 README 的「内容去向映射表」抢救如下，作为本仓之外的唯一存续记录：

| 原资产（pini-meta） | 新家 |
|---|---|
| 语言级文档：spec v0 / project-spec / comment-style-guide / glossary / roadmap / landing-plan-v048 / diagnostic-codes / test-refactoring-principles / evidence-table / CHANGELOG(语言) / Pini草稿 | `docs/spec/` |
| 语言级 ADR：018 / 019 / 020 / 021 / 023 + adr-index（已转登记表） | `docs/spec/adr/` |
| 宿主级 ADR：022（分发策略） | `docs/adr/` |
| 语言级 issue：draft-impl-syntax-audit / spec-impl-syntax-audit / module-system-rules / pini-dir-namespace / tdd-module-blockers | `docs/spec/issue/` |
| 宿主级 issue：lexer-gap-closure / unicode-char-predicates | `docs/`（平铺） |
| 自举级文档：pini-bootstrap-architecture / issue-bootstrap-token-stream（均已英文化） | `examples/selfhost/docs/` |
| hooks/comment-lint.sh、根 GIT_WORKFLOW、归档 README | 不迁移（副本在宿主与 selfhost 各存；治理随仓归档） |

文中其余「归档保留」表述以本后记为准。

# 工单：TDD 模块阻塞三项（`pini test` 单文件局限 / 清单 schema 分歧 / 模块包无排除机制）

- 日期：2026-08-28
- 提出方：agent:pini-dev
- 状态：已决议（本文档即决议记录），宿主实现待做
- 关联：G41（`|test` 测试函数块）、G49（本次决议登记）、ADR-018 D1（宿主 git 依赖）、pini-project-spec §7（清单 schema）

## 1. 背景

pini/（自举仓）在 `tests/` 落地了 G41 风格测试（`名称|test()` + `assert`），随后发现 TDD 流程被宿主模块机制阻塞。调查（2026-08-28，宿主 v0.48.4 二进制实测）确认测试设施本身完好（`|test` 修饰符解析、`assert` 内建、`Interpreter.runTests` 逐测试执行与汇总均正常），阻塞点集中在**模块加载层**，共三项。

## 2. 缺陷实证

### 2.1 `pini test` 仅单文件（核心阻塞）

CLI `runTestPath` 直接 `readFile(path)` 构造单文件 module，不走 `FileLoader.loadDirectory`，同模块其他文件的符号不可见。语义/类型门禁在执行前即失败：

```
$ pini test tests/token_tests.pini
Error: Semantic Error [E3-002]  at tests/token_tests.pini:2:12
  assert(opType("+") == "plus", ...)
         ~
undefined function 'opType'
```

spec v0 G41 行写明「收集顶级 `|test` 逐一执行」，未限定单文件；现实现退化为 `<file>` 单文件收集，**偏离原意**。衍生 workaround（手工拷贝 `tests/lexer_src.pini` 源码副本、cat 拼接临时文件）均已实证脆弱（副本漂移）。

### 2.2 清单 schema 分歧：spec `[project]` vs 宿主 `[package]`

宿主 manifest 解析器只认 `[package]` 区段（`FileLoader.parseManifest`），pini-project-spec §7.1/§8 规定为 `[project]`，pini/ 脚手架按 spec 写 `[project]` → 目录模块模式整体不可用：

```
$ pini check .
Error: 非法的 pini.toml：./pini.toml
```

### 2.3 模块包加载无排除机制

修复合法清单后（临时副本实验），`loadDirectory` 递归加载一切 `.pini`：

- `examples/lex_corpus.pini`（刻意不可解析的词法差分**语料**，数据非代码）炸掉解析（十余个 parse error）；
- 剔除 examples 后，`tests/lexer_tests.pini` 的 `main` 与 `src/main.pini` 冲突：`E3-004 redeclared symbol 'main'`。

无任何「程序目标 vs 测试/数据文件」的分离语义。

## 3. 决议（用户拍板，2026-08-28）

### D1 — 清单 schema 单一 `[package]`，spec 向宿主靠拢

- pini.toml = **模块身份文件**；模块系统的设计目标是子模块无痛组合，所有 pini.toml 必须同一 schema。
- **`project` 概念不入 pini.toml**（层次混淆：project ≠ module）。未来若需多模块工作区概念，另立工作区级文件（如 `project.toml`），届时再议。
- 落点：pini-project-spec §7.1/§7.2/§8 修订 `[project]` → `[package]`；pini/ 脚手架随动。宿主零改动。

### D2 — `pini test` 回归 G41 原意：收集单位 = 模块

- `Interpreter.runTests` 本就遍历整个 module 的 declarations（原意完好）；偏离只在 CLI 单文件喂入。修复 = 削掉 CLI 单文件退化。
- 语义：`pini test [path]`
  - 无参 → 自 cwd 向上定位 pini.toml 取模块根，加载模块包后收集全部顶级 `|test`；
  - 显式 `<path>`（文件或目录）→ 收集范围限定为该路径下文件；模块包仍完整加载（跨文件符号可见）；显式路径可**加回**被 `[build] exclude` 排除的目录（测试目标可检视排除区）；
  - 单文件位于模块外 → 保持现有单文件行为（向后兼容）。
- 衍生：tests/ 内手动 `main` 串联（单文件时代的 workaround）退场；tests/ 文件只含 `|test` 函数与辅助函数。

### D3 — 模块包排除走显式清单 `[build] exclude`（Provisional）

- 不引入隐式目录约定（如 tests/ 特殊地位）；排除关系**显式写在清单里**。
- schema：`[build]` 区段 + `exclude = ["examples", ...]`（内联字符串数组，相对模块根的路径，P4 可扩展 glob）。
- 语义：被排除路径从**模块包加载**中剔除，run/check/build/test 全目标统一生效（单一机制，无逐目标例外）；`pini test` 的显式 `<path>` 例外加回（见 D2）。
- 语料类数据文件（lex_corpus 等）经 exclude 排除出加载——数据文件混用源码后缀进入模块包本就是误用；是否另立数据文件后缀规范留 P4，不在本工单展开。
- 注意：pini/ 的 tests/ **不**进 exclude——D2 落地后测试文件无 `main`，留在包内无冲突，`pini test` 无参即可全量收集。

## 4. 实施清单

### 4.1 治理（本文档随附，已做）

- [x] pini-project-spec §7.1/§7.2/§8：`[project]` → `[package]`（含 §6 检查项 exclude 注记）
- [x] pini-spec-v0 G41 行收集语义更正 + G49 决策登记
- [x] pini/ pini.toml `[project]` → `[package]`

### 4.2 宿主 pini-swift（待做，分支实现）

- [ ] `parseManifest`：新增 `[build]` 区段解析（复用 `parseTOMLArray`）；`ModuleManifest` 增加 `buildExclude: [String]`
- [ ] `loadDirectory`：跳过落在 exclude 条目下的相对路径文件
- [ ] CLI `runTestPath` 模块化：向上定位清单；文件在模块内 → 模块模式（目录加载 + 显式路径收集范围 + exclude 加回）；模块外单文件 → 现行为
- [ ] check/run 目录模式自然受益于 exclude（无需单独改）
- [ ] XCTest：exclude 语义、模块模式 test 收集、模块外单文件回退、D2 无参行为
- [ ] `pini help` 文案更新（`test <file.pini>` → `test [path]`）

### 4.3 pini/ 脚手架对齐（已做，2026-08-28）

- [x] 删除手工副本 `tests/lexer_src.pini`（已与 src 漂移）
- [x] `tests/lexer_tests.pini` 删手动 `main` 串联
- [x] pini.toml 增加 `[build] exclude = ["examples", "deps"]`（`deps` 为实施中补充：宿主工具链子模块源码不属本模块包，同时防子模块 init 后递归加载）
- [x] **驱动 main 归位**：`src/lexer/lexer.pini` 尾部的临时驱动 `main` 剥离（纯库 pass），读 `/tmp/lex_in.pini` 的驱动逻辑并入 `src/main.pini`（包模式下双 `main` 会 E3-004；`tools/diff_tokens.sh` 改为 `pini run <module root>`）
- [x] tests/ 首次入库（`has_substr` 助手见 §6 重名劫持）
- 验收结果：`pini check .` 全绿（模块 pini，5 文件）；`pini test` 无参 → **8 通过 / 2 失败**——失败为 `lex_indent_dedent` / `lex_nested_indent`，即 **L1（indent/dedent）的 TDD 先行红**（lexer.pini 零 indent 实现，预期红）；`tools/diff_tokens.sh` MATCH（225 行）

## 6. 实施中新发现的宿主缺陷（登记待办，不阻塞 G49）

**用户自由函数与成员方法内建重名 → 调用被劫持**。`contains` 是宿主注册的 `String` 成员方法（`TypeChecker.defineMethod`；`upper`/`lower`/`substring`/`split`/`slice` 同批）；用户定义同名自由函数后，自由形式的调用 `contains(hay, needle)` 在 `Interpreter` 调用分派处按名字命中成员内建分支（`if fv.name == "contains"`），按成员语义去找接收者 → 运行期报 `未定义变量: self`（location 合成，排障困难）。

- 最小复现：模块内 `contains|unsafe(hay, needle,) -> (Bool,)` + `|test` 调用即触发；同名函数体改名 `c4_full` 后逐字不变则通过（实证为名字分派问题，非函数体问题）。
- pini/ 侧 workaround：测试助手改名 `has_substr`。
- 待决议（host-fix 候选，走独立工单/G 号）：自由函数与成员内建的**名字分派优先级**——用户显式定义的自由函数应优先于按名劫持的成员分支；或至少给出可定位的诊断。

## 5. 验收口径（DoD）

1. 宿主全量测试绿（现基线 1004 执行 / 20 跳过 / 0 失败不回退）——**已达成：1010 执行 / 20 跳过 / 0 失败（+6 G49 用例）**；
2. pini/ 根目录 `pini test` 无参 → 收集全部 `|test`——**已达成（8 通过；2 红为 L1 TDD 先行，见 4.3）**；
3. pini/ 根目录 `pini check .` → 绿——**已达成**；
4. 手工副本与 cat 拼接 workaround 移除后无回归——**已达成（`tools/diff_tokens.sh` MATCH 225 行）**。

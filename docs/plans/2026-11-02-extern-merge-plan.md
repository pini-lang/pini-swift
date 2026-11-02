# extern 并入 export：决定与落地计划

- 分支：`dev-agent-pini-c-interop`（未推送）
- 起手 HEAD：`85da45f`
- 回滚点：`c41715c`
- 状态：已执行（2026-11-02）
- 日期：2026-11-02

## 结论

取消 `[名|extern]` 块。对外发布只写在 `[文件名|export]` 里，目标写在条目上：

```pini
; calc.pini
[calc|export]
calc_add|c = 加法
calc_state|c = 计数器状态

公开名 = 原符号          ; 省略目标 = |pini
_私有名 = 原符号         ; 仍是抑制
```

- 块声明「这个文件发布什么」，条目声明「发布给谁」。
- `|c` 是 C 面，沿用现有导出面的全部判据；`|pini` 是模块面，沿用 export 块的重命名语义（仍是暂存，不 enforce）。
- 一个块可以混写两种目标；有没有 `|c` 条目决定它算不算库。
- 块头仍是文件名（D-1：块头名须为当前文件名，不变），所以产物、生命周期符号、头文件保护名都取文件名。
- `--extern` 撤掉；`--backend c` 保留，它选的是发射器，不是语言。

## 四个面

### 目标标签

状态：已定，按你的原话落地。

是什么：条目从一种形状 `A = B` 变成带可选目标的 `A|目标 = B`，目标只有 `pini` 与 `c`，省略即 `pini`。

为何现在定：extern 块与 export 块各有一套条目语法，同一件事要学两遍；语言又放在命令行上，源文件读不出产物形态。

选项与代价：

- 目标写在条目上（采用）：语法多一个可选段，解析与 AST 要改；换来一个块管两种发布面，语言与符号写在一起。
- 保留 extern 块：不动语法；但两块并存，产物名、块名、文件名三者继续不一致。
- 目标写在块头（`[calc|c|export]`）：块级一刀切，同一文件不能同时发布 pini 与 C 面；不采用。

### 产物命名

状态：待确认，拟采用「取文件名」。

一句话：`calc.pini` 的 C 产物是 `libcalc.{dylib,so}`，生命周期是 `calc_init` / `calc_shutdown`；块头仍等于文件名，不给「块头 = 文件名」开例外。选项与代价见文末「需要你确认的两点」。

### 单库约束

状态：待确认，拟采用「一个模块一个库」。

一句话：一个模块最多一个文件带 `|c` 条目，`build --shared` 只出一个库，名字取那个文件；第二个文件报错并点名。选项与代价见文末「需要你确认的两点」。

### 命令行收口

状态：已定，随合并直接收掉。

是什么：不再有 `--extern` 与 `ExternLanguage`；语言只写在条目上，`build --shared <路径> [-o 产物]` 不再收语言参数。

为何现在定：语言已在条目上，命令行再收一个语言只会与条目打架；目前只有 C 一条落地路径，这个开关本来就是空转。

代价：旧写法 `--extern c` 变成定向报错（提示语言写在条目上）；回滚已丢弃 `85da45f` 的 `--extern` 用例与文档段落，本次只需补一条旧参数提示。

## 回滚

回滚点选 `c41715c`，不是 `57ed47f`：

```
git reset --hard c41715c
```

- 丢弃 `85da45f`（`|c` → `|extern` 的改名、`--extern` 开关、转义穷举判据）。这正是要撤的那一步。
- 保留 `2a1fed0`（`build --shared`）与 `c41715c`（`emit` 对库模块放行）。两者与块语法正交，代码已测过，重做没有收益。
- `85da45f` 仍可通过 reflog 取回；其中「转义单射穷举」判据要在「测试」里重新加回，不能随提交一起丢。
- 不选「向前再改一版」：分支未推送，历史里留「引入 extern 又取消」的两笔只会让后来者多读一段废案。
- 不选「退到 `57ed47f`」：那会连 `build --shared` 与 `emit` 放行一起丢掉，重做面更大。

回滚后的基线读数：397 条测试 / 64 套件全绿，工作树干净。注意 回滚是破坏性操作，执行前确认 `git status` 为空；若有未提交改动先停下。

## 语法与语义细则

### 块与条目

```
export-decl ::= '[' IDENT '|' 'export' ']' NEWLINE { export-item };
export-item ::= IDENT [ '|' ('c' | 'pini') ] '=' IDENT;
```

| 写法 | 目标 | 含义 |
|---|---|---|
| `公开名 = 原符号` | pini | 提升私有符号为公开（`_` 前缀仍是抑制） |
| `公开名\|pini = 原符号` | pini | 同上，显式写法 |
| `对外名\|c = 原符号` | c | 发布成 C 符号；右端须是自由函数或给定块 |

- 块头必须是当前文件名（去 `.pini`）；否则报错，消息补一句「文件名即 C 产物名」。
- 每个文件最多一个 export 块；同文件第二个块报错，消息提示把条目并进同一块。
- 块内可以混写两种目标；`|pini` 条目不影响 C 面，`|c` 条目不影响 Pini 可见性。
- 只有 `|c` 条目的左名过 `CName.escape`；`|pini` 的别名是 Pini 名，不转写。`|c` 条目的左名是字面 C 名，`_` 不表示抑制，C 保留区检查照旧。
- 目标只认 `pini` / `c`；`|rust` 报错并列出可用目标。
- 旧的 `[名|extern]` 与 `[名|c]` 各给一条定向迁移消息，不静默当成别的东西。
- 条目写冒号（`calc_state: 计数器状态`）报错：冒号在导入块与字段里表示类型，export 条目一律用等号。

### C 面判据

沿用现有导出面的类型与 ABI 判据，不新增 ABI 语义：

- 右端必须是本模块的自由函数或给定块；方法、泛型、异步、`|test`、`main` 不进 C 面；泛型给定块拒。
- 形参与返回走现有 C 标量白名单；`^T` 降成「状态码 + 出参」；`using` 不进 C 原型。
- 对外名过 `CName.escape`：ASCII 原样，其余 `_u` 加 6 位大写十六进制。
- 对外名不得与生命周期符号同名、不得撞转义形状、不得落 C 保留区；重复的 C 名报错。
- 给定块字段全部可写成 C 类型，否则整块拒。
- 文件名转写后必须是合法 C 标识符（不能以数字开头）；不合法就报错，不改名。

### 产物

```
pini build --shared calc.pini            → libcalc.dylib（-o 改落点）
pini emit calc.pini calc.h --backend c   → calc.h
```

- 产物名 `lib<文件名>.{dylib,so}`；生命周期 `<文件名>_init` / `<文件名>_shutdown`。
- 头文件保护名取文件名大写；结构体与 `_Static_assert` 不变。
- 无 `|c` 条目的模块：`build --shared` 报错且不留产物；`emit` 仍要求 `main`（E6-004）。
- `compile` / `run-llvm` 一律要求 `main`，与现在一致。

## 落地步骤

| 主题词 | 改什么 | 完成判据 |
|---|---|---|
| 语法 | AST、解析器、所有 switch 消费点 | `swift build` 通过；新语法可检查，旧语法定向报错 |
| 语义 | 类型检查、降载、头文件错误文案 | 聚焦测试通过；无 `ExportCDecl` 残留 |
| 命令行收口 | `EntryPolicy`、旧参数提示、产物名 | CLI 测试通过；三条入口判据正确 |
| 测试 | 三套测试改写、新增负例、转义穷举 | 全量绿；负例逐条有消息断言 |
| 文档 | 参考手册、设计文档、文法附录 | 文档链接门禁与注释门禁通过 |
| 验收 | 端到端、门禁、提交 | 读数与提交记录 |

### 语法

- 删 `Sources/PiniSyntax/AST/Declarations/ExportCDecl.swift`；把条目并进 `ImportExportDecl.swift`：`ExportEntry { name, target, symbol, location }`，`ExportTarget { pini, c }`；`ExportDecl` 增 `name`（块头，即文件名）。
- `TopLevelDecl` 去掉 `exportCDecl`；`ConstantFolder` / `Desugar` 去掉对应直通分支。
- `Parser.parseExportBlock` 改条目解析：`IDENT` 后看 `.pipe` 还是 `.assign`；`|` 后读目标标识符；未知目标报错。
- 删 `parseExportCBlock`（独立 C 导出块）；`|c` 分支改成迁移提示，`|extern` 也加一条迁移提示。
- `Parser.parseModuleImpl` 记录 export 块数量，第二个块报错。
- CLI 的 AST dump：`export A|c = B`；pini 目标省略标签，保持与源码默认一致。

### 语义

- `TypeChecker.check(module:)` 在声明遍历之后加 `for block in module.exports`；`check(package:)` 在多文件循环里逐 unit 检查，`packageContext` 已就位。
- `checkExportCBlock` 改名为 `checkExportSurface`，只遍历 `target == .c` 的条目；pini 条目直接跳过。
- `exportCBlockCount` 改名为 `cSurfaceCount`，按模块累计；第二个带 `|c` 条目的文件报错并点名两个文件。
- 块名校验：`CName.escape(block.name)` 须以字母或下划线开头，且不落保留区；消息指向文件名。
- `enforceDeclTypeVisibility` 的 `.exportCDecl` 分支移成 `enforceExportBlockVisibility(_:)`，只查 `|c` 条目的给定块类型；函数目标的可见性维持现状（既有缺口，本次不扩）。
- `IRLowerer.lower(module:)` 从 `module.exports` 里找唯一带 `|c` 条目的块；`lowerExportBlock` 的块名取 `decl.name`，条目只收 `.c`。多于一个块带 `|c` 条目时降载层抛错兜底。
- `SemanticAnalyzer` / `Visibility` / `PredefinedDecls` 去掉 `.exportCDecl` 分支；`ErrorFormatter` 与 `CHeaderBackend` 的「C 导出面 / `[库|c]`」文案改成「export 块的 `|c` 条目」。

### 命令行收口

- `EntryPolicy` 的判据从「有 C 导出块」改成「有 `|c` 条目」：单文件看 `module.exports`，包看 `fileUnits.flatMap(\.module.exports)`。
- `lowerSingleFile` / `lowerPackage` 传同一个判据函数，避免两条路漂移。
- 回滚后 `--extern` / `ExternLanguage` 已随 `85da45f` 消失，不要加回来；`runBuildShared` 保持无语言参数。
- 若用户按旧写法传 `--extern`，给定向报错：「语言写在条目上，如 `calc_add|c = 加法`」。
- `runBuildShared` 的拒绝消息改成「模块没有带 `|c` 条目的 export 块」；产物名继续取 `irModule.export.name`（现在就是文件名）。
- 帮助文本：`build --shared <path> [-o out]`，说明产物名取文件名。

### 测试

- `CInteropExportTests`：所有 `typeChecked` / `lowered` 传 `fileName: "calc.pini"`；块改 `[calc|export]`；条目加 `|c`；新增：
  - 省略目标与 `|pini` 等价；
  - `|rust` 报错并列出 `pini` / `c`；
  - `[calc|extern]`、`[calc|c]`、冒号条目各给迁移消息；
  - 同文件两个 export 块被拒；
  - 块头与文件名不符被拒，消息含「文件名即产物名」。
- 把 `85da45f` 里的转义单射穷举判据加回（允许域 1–3 字符全组合，样本超过 500）。
- `CSharedLibraryTests`：`librarySource` 改新语法；模块夹具 `surface.pini` → `calcmod.pini`、块改 `[calcmod|export]`；保留无 export 块的拒绝用例，另加「只有 pini 条目的模块被 `build --shared` 拒」；再加一个模块目录用例，两个文件各带 `|c` 条目时 `build --shared` 报错、点名两个文件、不留产物；其余 dlopen 断言不变。
- `BackendSeamTests`：`[seam|export]` 加 `seam_get|c = seam_value`，`lowered` 传 `fileName: "seam.pini"`。
- 新增负例：无 `main` 无 `|c` 的模块在 `emit` 仍报 E6-004；`compile` 对库模块仍拒。

### 文档

- `docs/spec/pini-reference-v0.md`：
  - §4.1 块类型表保留 `[名称|export]`，释义改成「发布块：`|c` 条目落地为 C，缺省 `|pini`」；回滚后本来就没有 extern 行，不用删。
  - §4.2 导出块改成新语法，补目标表与「块头 = 文件名」；
  - §9.7 改名「export 块的 `|c` 条目」，示例与命令改成新语法，产物名按文件名；
  - 文法附录删 `export-c-decl`，`export-item` 加可选目标。
- `docs/spec/c-interop-design.md`：
  - 「可导出的东西」表加 `|c`；
  - 「语法」节重写，删「两块并存，不合并」，把「块名命名产物」改成「文件名命名产物」，补合并理由；
  - 「标识符转 ASCII」例子改 `calc_add|c = 加法`；
  - 「发射物」表命令改成 `build --shared <路径> [-o 产物]`，说明产物名取文件名；
  - 入口口径段落改成「带 `|c` 条目的 export 块」；
  - 实施分片表把导出面那一行改成合并后的形态，验收读数改成本次。
- 注意：文档不写 emoji，提示句用「注意 」；改完跑文档链接门禁。

### 验收

1. 构建：`swift build --scratch-path /tmp/pini-scratch --disable-sandbox`。
2. 全量：`PINI_CLI_BIN=/tmp/pini-scratch/debug/pini swift test --scratch-path /tmp/pini-scratch --disable-sandbox`，预计 400 条上下，以实际读数为准；不允许 known issue 顶替。
3. 门禁：`python3 tools/check-comment-lint.py`、`bash tools/check-doc-links.sh`。
4. 端到端（临时目录）：
   - `calc.pini` 写混合块；
   - `pini build --shared calc.pini` 出 `libcalc.dylib`；
   - `pini emit calc.pini calc.h --backend c` 出头文件；
   - C 调用方链接后打印 `add=12`、`state.n=0`、写后 `11`。
5. 负例：旧块标记、冒号条目、未知目标、两个 C 面文件、只有 pini 条目的库、无 `main` 无 `|c` 的 emit、只有 pini 条目时 `--backend c` 报无 C 面，逐条看消息。
6. 提交：一笔 `refactor(ffi): fold the extern block into export`；提交前 `git status` 确认只含预期文件，提交后确认 HEAD 变化。

## 风险与对策

| 风险 | 后果 | 对策 |
|---|---|---|
| 回滚丢掉 `85da45f` 的穷举判据 | 转义单射失去判据 | 在「测试」里重加；提交前确认测试数不比基线少 |
| 测试夹具仍用默认 `inline.pini` | 块头与文件名不符，用例假红 | 三个套件统一传 `fileName`；用 grep 反查 export 块头 |
| `EntryPolicy` 只看 declarations | 库模块仍被要求 `main` | 单文件与包共用 `hasCSurface`；加端到端负例 |
| 文件名当 ABI 名 | 文件改名即库改名 | 错误消息写明；文档单列一条 |
| 同文件多块 / 多文件 C 面 | 产物名撞车或静默取其一 | 解析期拒多块；语义期拒多文件；降载层兜底抛错 |

## 不做的事

- 不实现 `|pini` 的可见性 enforce：export 块目前仍是「暂存，不解析 / 不 enforce」，本次只借它的位置，不扩语义。
- 不加第二种外部语言；目标表只列 `pini` / `c`。
- 不改 C 类型映射、Result 状态码、给定块布局、`CName.escape`。
- 不生成 C 实现，只出头文件与动态库。
- 不支持一个模块多个 C 面 / 多个库。

## 需要你确认的两点

### 产物命名

- 是什么：C 产物与生命周期符号取文件名，`calc.pini` → `libcalc` / `calc_init`。
- 为何现在定：合并后块头必须等于文件名；这是唯一不需要给「块头 = 文件名」开例外的方案。
- 选项与代价：
  - 取文件名（推荐）：无语法例外；代价是文件改名即库改名，测试夹具要改名。
  - 允许块头自由（仅带 `|c` 条目时）：产物名可任意；代价是「块头 = 文件名」变成条件规则，解析器要多一条例外，文档要解释两套块头规则。
- 建议：取文件名。名字只有一个来源，读者不用猜「块名还是文件名」。

### 单库约束

- 是什么：一个模块最多一个文件带 `|c` 条目，只出一个库。
- 为何现在定：`IRModule.export` 是单值，`-o` 也只收一个产物；多库要同时改 IR、命令行与加载约定。
- 选项与代价：
  - 单库（推荐）：两个文件带 `|c` 条目直接报错；代价是要多库就拆模块。
  - 多库：每个文件出一个库，`-o` 改成目录语义，生命周期与头文件按文件各一份；代价是本次改动面翻倍，且与「模块 = 一个产物」的现有叙事冲突。
- 建议：单库。先把合并做稳，多库另开一题。

两点均按推荐落地；回滚、语法、语义、命令行收口、测试、文档、验收按序完成。

# 工单：G52 批 1「边界与语义」预先立项（2026-08-31）

- 状态：**Pre-approved 立项**（用户拍板合并规划：批 1 与块形式批次合并推进；本文为开工前置产出）
- 上游：`issue-module-system-rules-2026-08-28.md`（G52 八规则，R1/R2/R4 为本批范围）
- 范围声明：本批 = **块式 import/export 解析 + 顶级裸语句移除（破坏性）+ R2 依赖图无环 + R4 跨模块访问**。
  MVS / `pini-summary.toml` / 校验和 / `pini mod` 工具链属批 3，远程抓取属批 4——**不在本批**。

---

## 1. 裸 import/export 语料盘点（实测 2026-08-31）

| 位置 | 形态 | 迁移动作 |
|---|---|---|
| `Tests/PiniTests/GrammarConsistencyTests/testProductionsImportExport.pini` | `import foo` / `export bar` | 改块形式（该文件为产生式对拍语料，宿主与自举双改） |
| `Tests/PiniTests/ImportExportTests/testParseImportAndExportWithProgram.pini` | `import math` / `export helper` | 改块形式 + 断言更新 |
| `Tests/PiniTests/ParseProjectionTests/testASTHoldsStepFieldInitAndImports.pini` | `import std` | 改块形式 + 投影断言更新 |
| `examples/selfhost/examples/lex_corpus.pini`（L24-25） | `import m` / `export s` | 改块形式（L0 词法门禁语料，记号不变则无影响，仅源形态变） |
| `examples/selfhost/examples/parse_slice_corpus.pini`（L8-9） | `import std` / `export pts` | 改块形式 + **自举 parser 同步**（host-gaps 台账返工点） |

- 宿主 examples/（非测试）**零使用**；`examples/package-demo` 用的是 `_` 前缀约定制，与裸语句无关。
- 迁移面：**5 个文件**。破坏性移除的语料成本极低，窗口期内一次改完。

## 2. `别名.符号` 限定访问设计草案（批 1 唯一有设计不确定性的点）

### 2.1 语义（R4 已裁决，本节为**实现落点**设计）

- `[别名|import]` 块把包路径绑定到别名；**全导入**——别名即模块命名空间的静态句柄。
- 访问一律 `别名.符号`；别名是**静态限定符**，不进运行时值命名空间（永不与用户变量重名）。
- 跨模块引入门槛 = 仅 `public`（G52 D8/定稿表）：被引入模块中 `_` 前缀（private/internal/package）符号经 `别名.` 前缀访问 → 拒。

### 2.2 实现落点（三层各一处）

| 层 | 落点 | 动作 |
|---|---|---|
| 解析 | `Parser.parseImportDecl`（现为裸语句） | 改块形式解析：块头 + `IDENT '=' STRING` 项集，产出 `ImportDecl(别名, 包路径)`（**ImportDecl 需加别名字段**——现只有 moduleName） |
| 语义 | `SemanticAnalyzer`（`requireDefined` / `PackageSymbolIndex`） | ①登记「别名 → 模块根」映射（模块级，非作用域级）；②`别名.符号` 的 member 表达式在 base 为 import 别名时改走跨模块符号解析，而非普通成员调用；③可见性判定 `isVisible(from:)` 增加「跨模块 → 仅 public」通道 |
| 运行 | `Interpreter`（globalEnv / 符号解析） | 模块加载期将被引入模块的 public 顶级符号以 `别名.符号` 复合键预注入（或经限定查表），用户变量命名空间不受污染 |
| 类型 | `TypeChecker` | `别名.类型名` 的类型标注解析（typeEnv 跨模块查表，同门槛） |

### 2.3 设计疑点（开工前须用户裁决）

| # | 疑点 | 选项 |
|---|---|---|
| D-1 | 块头形态：spec 现行产生式写 `[import \| import]`，草稿为 `[名称 \| import]`（任意标签名）。R4 说「块头名只是标签，不进访问路径」——倾向草稿形态 | A：`[名称\|import]`（推荐，与草稿/export 对称） B：固定 `[import\|import]` |
| D-2 | 别名与用户顶级符号重名：别名是静态限定符不进值命名空间（R4），理论上无冲突；但**类型层** `别名.类型名` 与本地类型名的解析优先级须明确 | 建议：限定形式只走跨模块通道，永不解析本地符号——`别名.` 前缀即明示跨模块 |
| D-3 | 错误码：环检测（R2）、非 public 跨模块引入（R4）各立新码（E3-0xx 语义域或新域） | 批 1 实施时定 |
| D-4 | `_B = path`（隐式别名注入，草稿 L68）是否批 1 落地 | 建议：批 1 只做显式别名，隐式注入随批 3 清单规范（其语义与 `[tap]`/包路径解析耦合） |

## 3. 批 1 步骤表（预排）

| # | 步骤 | 验证 |
|---|---|---|
| 1 | spec：import-decl/export-decl 产生式修订（含 D-1 裁决）+ R2/R4 语义章 | L1-L6 |
| 2 | Parser：块式解析 + 裸语句移除（报错附迁移提示） | 编译 + 单元 |
| 3 | ImportDecl/ExportDecl 加别名字段；全语料迁移（§1 五文件） | 全量 |
| 4 | SemanticAnalyzer：别名登记 + `别名.符号` 跨模块解析 + public 门槛 + 环检测（R2） | 专用测试 |
| 5 | Interpreter/TypeChecker：跨模块符号/类型注入 | 运行级测试 |
| 6 | 自举 parser 同步（语料 + 投影镜像） | gate.sh |
| 7 | 双模块演示（examples/ 新增两模块互相 import 的最小样例） | 全量 + gate |
| 8 | 基线重标定 + 登记册（G52 批 1 出账） | hook |

## 4. 风险

- **破坏性**：裸语句移除走 Provisional 窗口（语料成本已盘点，§1）。
- **双仓同步**：自举 parser 的 import/export 解析为已知返工点，批 1 内必须同批（gate 是硬门禁）。
- **作用域耦合**：`requireDefined` 增加跨模块通道不得扰动既有 `_` 前缀可见性语义——用 `CrossFileVisibilityTests` 全量锁。

# 工单：G52 批 1「边界与语义」预先立项（2026-08-31）

- 状态：**Pre-approved 立项**（用户拍板合并规划：批 1 与块形式批次合并推进；本文为开工前置产出）
- 上游：`archive/issue-module-system-rules-2026-08-28.md`（G52 八规则，R1/R2/R4 为本批范围）
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

| # | 疑点 | 裁决（2026-08-31，用户） |
|---|---|---|
| D-1 | 块头形态 | **块头名 = 当前文件名**（去 `.pini` 后缀，解析器校验一致）。理由：原 `[import\|import]` 把保留关键字 `import` 放进标签位——照原样实现必然与关键字保留冲突（纸面自洽、落地即炸），且「两个 import」令人困惑。spec 产生式已同步修订；export 对称适用 |
| D-2 | 别名与本地符号重名的解析优先级 | **策略二（静态互斥）**：禁止声明与 import 别名同名的本地顶级符号与局部变量（E3 重声明域报错）——静态可判定，无静默遮蔽（H-3 反面教材）。`别名.符号` 限定形式只走跨模块通道，永不解析本地成员。详见附录 A 详析 |
| D-3 | 错误码 | 实施时定 |
| D-4 | 隐式别名注入 `_B = path` | **推迟到批 3**（与 `[tap]`/包路径解析耦合） |

### 附录 A · D-2 详析（应用户要求展开）

**问题本质**：`别名.符号` 在语法上与「本地结构体/对象值的成员访问」完全同形。若别名进入
与用户符号同一命名空间，两类歧义无法静态消解：

```pini
[app|import]
demo = "./vendor/demo"

(盒<T>)
值: T = 0

main|func() -> ():
    var demo = 盒()      ; 本地变量名恰为别名
    demo.值               ; ← 本地变量的字段？还是跨模块 demo 的符号？
```

**三个候选策略**：

| 策略 | 规则 | 判定 |
|---|---|---|
| 一（遮蔽式） | 有同名本地变量时本地优先，否则走跨模块 | **否决**——歧义随作用域动态变化，不可静态判定 |
| 二（静态互斥） | 禁止声明与别名同名的本地符号（重声明域报错） | **采纳**——静态可判定；别名是「稀缺名」，让渡成本极低 |
| 三（顺序式） | `X.Y` 先试本地成员、失败再试别名模块 | **否决**——静默遮蔽正是 H-3 明确反对的行为模式 |

**策略二的完整规则**：
1. `别名.符号`（base 为已登记 import 别名）→ 只走跨模块通道，永不解析本地成员——
   别名前缀即明示跨模块意图；
2. 本地顶级符号、局部变量、参数声明与 import 别名同名 → E3 重声明域报错（提示「与
   import 别名冲突」）；
3. 别名不占运行时值命名空间（R4 不变）——冲突检查发生在**静态声明登记期**；
4. 类型位置 `别名.类型名` 同规则（typeEnv 跨模块查表，public 门槛一致）。

## 3. 批 1 步骤表（2026-08-31 执行完毕：步骤 1-7 全部落地）

| # | 步骤 | 状态 |
|---|---|---|
| 1 | spec 产生式修订（D-1） | ✅ |
| 2 | Parser 块式解析 + 裸语句移除 | ✅ |
| 3 | AST 重塑（ImportDecl(alias,path)/ExportDecl(renames)）+ 语料迁移（5 文件） | ✅ |
| 4 | SemanticAnalyzer：别名登记 + 限定校验 + D-2 静态互斥 + R2 禁环（E3-010/011/012 新码） | ✅ |
| 5 | Interpreter：prepare/loadImports 递归 + `别名.符号` 限定派发（子解释器隔离命名空间） | ✅ |
| 6 | 自举 parser 同步（ast/parser/format + 语料 + 测试） | ✅（自举 2eefa3c） |
| 7 | 双模块演示（Tests/PiniTests/ModuleSystemTests/demo：app→helper）+ ModuleSystemTests 7 用例 | ✅ |
| 8 | 基线重标定 + 登记册 | ✅ |

实现备注：①加载器 `loadGraph` 递归预载全图，环检测先于缓存（缓存不得豁免环路径）；②canonical 必须**绝对化**（相对路径下 standardizingPath 不解析 `..`，链比较失明——实测教训）；③parseModule 将 importDecl 路由进 `module.imports` 侧表，加载器须单独收集（初版仅收 declarations 导致子模块依赖静默丢失）；④跨模块签名类型校验批 1b 为不透明处理，深化随批 3。

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

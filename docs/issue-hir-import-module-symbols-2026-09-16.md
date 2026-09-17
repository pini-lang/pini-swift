# HIR 降载层看不到依赖模块的符号（`import` 目标）

> 状态：**Open**（2026-09-16 立案；**只登记不修**）
> 发现于：P4-1a（包运行入口）首次实测。它**不是**该批的对象，而是在该批接通 CLI 之后**露出的下一道缺口**。
> 上游：`docs/issue-hir-p4-plan-2026-09-16.md` 的 `P4-1c` 行。

## 1. 现象（实测，2026-09-16，`d0d258b` + P4-1a 装配层改动）

夹具：含 `import` 的多文件包（`[main|import]` + `deps/<name>/` 下有独立清单的依赖模块）。

**形态一 · 裸调用注入符号**（`_text = "./deps/text"` 后调用 `hello()`）：

| 命令 | 结果 |
|---|---|
| `pini run <pkg>`（默认 `ast`） | rc=0，stdout `hi\nhi\n` |
| `PINI_INTERP_ENGINE=hir pini run <pkg>` | **rc=1**，`E6-004` — `unsupported feature 'call to unknown function 'hello' (intrinsics beyond print are later grids)'` |

**形态二 · 限定名**（`uni = "./deps/uni"` 后调用 `uni.hello()`）：

| 命令 | 结果 |
|---|---|
| `pini run <pkg>`（默认 `ast`） | rc=0，stdout `来自注入` |
| `PINI_INTERP_ENGINE=hir pini run <pkg>` | **rc=1**，`E6-004` — `unsupported feature 'reference to undeclared variable 'uni''` |

**对照：不含 `import` 的包**在两条通道上 **rc / stdout / stderr 逐项相同**（rc=0，输出 `plain`）
⇒ 问题只在「依赖模块的符号」，不在包运行本身。

**受影响的 XCTest 断言**（`ImportInjectionTests`，HIR 引擎下）：
L152 / L153（`testInjectionEndToEndViaCLI`）· L223（`testCrossModuleInjectionPropagation`）·
L195（`testArgvPassthroughViaCLI` 的模块分支 —— 与 `argv` 缺口**叠加**）。

## 2. 符号级根因（实测，非推断）

1. **`Package` 不携带依赖**：`Sources/PiniCore/AST/Package.swift` 的 `Package` 只有
   `name` 与 `fileUnits` 两个字段，**没有任何依赖模块/被引入包的位置**。
2. **依赖模块的源文件不进 `fileUnits`**：`FileLoader.loadDirectory` 在扫描时显式跳过嵌套模块
   —— 「相对路径上任一祖先目录含 `pini.toml` 即 `continue`」。故 `deps/text/lib.pini` 虽在包目录下，
   **不属于**该包的 `fileUnits`。
3. 于是 `HIRLowerer.lower(package:)`（把各 `fileUnit` 的 `declarations` 合并成一个虚拟模块再降载）
   **拿不到依赖模块的声明** ⇒ 裸调用解析不到具名函数、限定名的别名解析不到变量。
4. **AST 侧无此问题，因为它走的是运行时机制，不是静态合并**：`Interpreter.loadImports` 为每个
   `import` 项创建一个**子解释器**（`importEnvs[alias]` 保存其全局环境），`_` 前缀别名另有
   **文件级注入表**（`fileInjections`，供被引入文件内部的裸名解析）。HIR 是静态降载，**没有对应物**。

## 3. 影响面

- **用户可见**：任何**带 `import` 的包**在 HIR 引擎下不可运行（只有无 `import` 的包能跑）。
- **判据面**：上述 4 条 XCTest 断言（其中 1 条与 `argv` 缺口叠加）⇒ 这是 `PINI_INTERP_ENGINE=hir`
  全套回归里剩余失败的主要成分。
- **翻转前置**：`P4` 本体要切换默认引擎，届时带 `import` 的包是**绝大多数实际程序** ⇒ 本单是硬前置。

## 4. 实现路径（**未裁**；未决策前不动源码）

- **路径 A（倾向）· 静态合并依赖声明**：在 `lower(package:)` 里用**同一个**
  `ModuleDependencyLoader`（其 `LoadedModule` 已携带 `declarations: [TopLevelDecl]` 与
  `publicSymbols`，且自带 R2 环检测）递归加载依赖模块，把声明并入虚拟模块。
  与现有的「合并本包各文件」同构，**不动契约**。
  需处理三件事：① **限定名解析**（要认出 `alias.symbol` 里的 `alias` 是模块别名，而不是成员访问）；
  ② **同名冲突**的命名空间（AST 侧用 `@序号` 后缀）；③ 只并入 `public` 符号（跨模块门槛）。
- **路径 B · 引入跨模块专门形式**：若合并方案在符号面上产生歧义（例如别名与方法名不可区分），
  则为跨模块访问引入专门的 HIR 形式。代价：**契约计数变更**（走 `spec §1.3`，先登记后实现）。

**规模**：中等。改动落在 `HIRLowerer`（降载层），不属装配层。

## 5. 与在册条目的关系（避免重复登记）

| 在册项 | 与本单的关系 |
|---|---|
| `docs/issue-hir-package-run-unsupported-2026-09-16.md` | **不同对象**：那份讲**判据同时失明**（探针只扫单文件 / 回归跑默认引擎），是**测量**问题；本单是**能力**缺口 |
| `docs/spec/issue/archive/issue-hir-builtin-callee-unowned-2026-09-14.md` | **不同对象**：那份是内建 callee 无主（已关闭归档） |
| `argv` / `moduleRoot` 缺口（已改挂 `P4-1b`） | **同层不同因**：三项都在降载层，但那两项是**节点缺失**，本单是**包级符号表缺失** |

## 6. 不做范围

- **未裁前不动源码**（本单只登记）。
- 不改 `Package` 的字段（若路径 A 需要，另立决策）。
- 不并入 `P4-1a`（该批已按「装配层」如实收口，见 `docs/spec/issue/archive/issue-hir-p4-1-plan-2026-09-16.md` 的交付记录）。

## 7. 追加证据：形态三（2026-09-17，`A1` 批实测）

`A1`（包通道补全）把**模块成员**纳入判定之后，本单多了一条与前两形态**不同因**的实测。
夹具不是为本单写的，是既有的一组宿主模块（`Tests/PiniTests/ModuleSystemTests/demo3/app`，
其 `frontend/` 下还有一层 `syntax/`）。

| 命令 | 结果 |
|---|---|
| `pini run Tests/PiniTests/ModuleSystemTests/demo3/app`（默认 `ast`） | rc=0，stdout `110` |
| `PINI_INTERP_ENGINE=hir pini run <同一个目录>` | **rc=1**，`E6-004` — `unsupported feature 'imported modules '<…>/frontend' and '<…>/frontend/syntax' both export the top-level name '取值': this channel merges import targets into one module, so it cannot keep their namespaces apart'` |

**为什么它是新形态**：形态一 / 二都是「依赖模块的声明**根本没进**虚拟模块」；形态三是
「**进了**，但两个依赖模块导出**同名顶级符号**，而合并式降载**没有命名空间可放**」。
⇒ 这正是本单 §4 路径 A 需处理的第 ② 项（「同名冲突的命名空间（AST 侧用 `@序号` 后缀）」）
**已经作为一条实测出现**，而不是一个假想的边界情况。

**顺带的口径事实**：这条分歧在 `A1` 之前**没有任何器械能看见** —— 该模块的成员文件在探针里是
`PACKAGE_MEMBER`（无 `main`，单文件通道拒收），而 `run-llvm` 没有包通道。
⇒ 「本单的实测形态是**两**条」这个旧表述应读作「**至少三**条」（详见 `docs/hir-criteria-gap-ledger.md` §10）。

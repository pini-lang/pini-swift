# CHANGELOG

> 宿主实现（pini-swift）**实现版本演进记录**。语言版本里程碑见 `spec/CHANGELOG.md`（语言级）；治理变更见 `spec/adr/`（ADR）与 `spec/issue/`。
> 版本号与 `pini version` 输出同源：`PiniCore/Common/Version.swift`。

## Unreleased

> 批 7（远程 tap）当时未登记，此处一并补上；批 8 为 G52 工单的收尾补修。

### Added
- **远程 tap 抓取**（G52 批 7）：`TapFetcher` 支持 `github:<org>` / `git:<url>` / `file:<path>`（`git:` 接受本地路径 ⇒ 整条链路可离线端到端测试）；`git clone`/`fetch`+`checkout` + `rev-parse` 取 `commit`
- **经典 MVS**：候选来自远端 tag，取满足全部约束的**最小**版本（`^1.0` → `1.0.0`，不是 `1.2.3`）；全约束为 `*` 时按 D21 回填取最新
- **有界不动点迭代**：依赖的版本决定其自身的 `[require]`，故约束集随选择而变；上限 8 轮，不收敛即报错而非静默取某一轮
- resources 由 `refresh` 落地到 `.pini/resources/<name>/`（此前目录不存在则静默跳过，资源永远不进锁文件）
- **`[replace]` 三种形态**（G52 批 8 / D13）：版本覆盖（只换版本）、`file:`（换本地目录）、`github:`/`git:` fork（可带 `@版本`）；版本类替换并入 MVS 约束当下界；fork 与本地形态锁文件 `tap` 记 `replace`

### Fixed
- 锁文件 `commit` 此前恒为 `-`（只写不读），现为真实的来源定位符；`tap` / `source` 同样补上读取，`verify` 报错回显来源
- **R7 双向封闭**：`resources X` 而 X 的根含 `pini.toml` → 报错指引改用 `[require]`（此前只兑现正向）
- **`file:` 替换不再往用户本地目录抓取**（批 7 引入的回归）：落地目录被换成本地目录后，抓取仍按 tap 的 spec 执行，会在用户的开发工作区里 `fetch`+`checkout`

### Internal
- 三层嵌套模块夹具 `Tests/PiniTests/ModuleSystemTests/demo3/`（R1 递归排除此前只有两层覆盖）

## v0.52.0 (2026-09-02)

### Added
- **模块工具链 `pini mod`**（G52 批 3）：`tidy`（离线对齐 require↔import）/ `refresh`（本地 tap 重解版本 + 写 `pini-summary.toml`）/ `verify`（SHA-256 校验和执行点）/ `graph [--cycles]`
- **清单双通道**：`[tap]`/`[require]`/`[resources]`/`[replace]` 及点分子表、`[[ ]]` 数组表（MiniTOML）；MVS v1（本地 `file:` tap）
- **隐式别名注入**（D-4，ADR-029 后续裁决）：`_别名 = path` = 注入全导入（文件级裸调用或 `_别名.符号` 限定）；冲突 E3-013；名字不一致 E7-002 弱警告（E7 段首个发出的警告）
- **argv 透传**（F6）：`argv()` 内建返回脚本路径之后的裸参数（LLVM 端暂 unsupported）
- 多项 import 块；R1 嵌套清单父扫描排除补全

### Changed
- **破坏性**：旧 `[dependencies]` 清单节命中即报错（指引 `[require]`/`[resources]`）；单文件 `pini run` 现过语义门禁（E3 拒绝后才执行）

### Fixed
- `run(package:)` 补加载 import 块（跨模块限定调用运行时 E5-001，语义/类型检查不受影响）

### Internal
- MiniTOML 共享解析器、纯 Swift SHA-256（NIST 向量验证）、语义警告通道（E7 段）上 stderr、子进程 CLI 测试基建

## v0.51.0 (2026-09-02)

### Added
- **下标三通道**（G48 破坏性修订，ADR-028）：`a[i]` 安全断言（越界 panic E5-005）；`.get(i)` 安全可选（越界 `.none`，Array/Dictionary/String 一致，字典键按任意值匹配）；`unsafe .getUnchecked(i)` 不安全（解释器以「UB 陷阱」E5-006 近似，LLVM 端未实现报 unsupported）
- **跨行字面量**（G55，A12 方案 B / 路 C）：普通括号内 NEWLINE 等同空白、缩进不参与；块携带括号（开括号同行紧跟 `func`）布局照常——草稿「原地调用 IIFE」形态由此可用；自举 lexer 同步（差分 L0 MATCH 508）
- **括号内 `=` 记法**（G57，ADR-029）：实参标签 / 字典条目 / 元组标签 / 枚举具名构造统一 `=`（注入方向）；自举 parser 同步

### Changed
- **破坏性**：下标读返回元素类型 `T`（原 `Optional<T>`），越界由「得 nil」改「panic」；`unsafe a[i]!` 类剥壳写法失效（迁移见 `docs/spec/migration-2026-09.md` §A）
- **破坏性**：注入位旧 `:` 记法（`f(a: 1)`、`[k: v]`、`(a: 1,)`、`E(x: 1)`）废弃并报错（带迁移提示）；match 具名绑定 `case A(x: v):` 保留 `:`（§B）
- 解释器下标语义向 LLVM 既有 panic 行为**收敛**（`@bk_array_get` 一直 `bk_panic`），闭合双后端不一致（`issue-host-optional-slice`）

### Fixed
- Dictionary `.get(key)` 误要求整数索引——键现按任意值匹配（批 2 缺陷，批 3 取证发现）

## v0.49.0 (2026-08-29)

### Added
- **内建单点登记表**（ADR-020 D3/D4）：`BuiltinRegistry` 承载 28 个内建声明（名字/归组/签名/三层开关），解释器、类型检查、语义分析三处表驱动派生；成员方法表驱动派发（String/Array 11 方法）
- **collection 内建特征声明面**（ADR-020 步骤 A）：抽象签名 + String/Array 标记式 conformance；用户类型严格校验可用
- **标准库语言内下沉试点**（ADR-020 D2）：`StdlibPini.swift` 内嵌 Pini 源，`String.contains` 为首个 Pini 实现的成员方法（body-first 派发通道）
- **码点原语**（词法门禁 H1）：`ord`/`chr`（grapheme 首 Unicode scalar；空串/越界/代理区哨兵）
- **字符谓词扩容**（G45/ADR-019 D4）：`is_ascii_digit` / `is_number` / `chars`（grapheme 预切）；`is_letter` 三层登记
- **宽松词法**（ADR-021）：未知字符 → 单字符标识符 token（`unknown` 类型移除）；非法转义原样保留；字符串行尾/EOF 隐式终止；畸形进制/指数回退 `int` + 标识符（`0xg` → `int 0` + `identifier xg`）
- **G49**：模块级 `pini test` 收集 + `[build] exclude`

### Changed
- **G50（破坏性）**：`Self` 关键字更名 `own`，`Self` 降级普通标识符（对齐自举 lexer 与 spec EBNF）
- **module.toml → pini.toml**；R5：点前缀路径构件扫描跳过
- 语言级文档迁移至 pini-meta 仓库（ADR-018）——2026-08-30 由 ADR-024 迁回本仓 `docs/spec/`

### Fixed
- G48 下标安全模型：负索引尾部计数、越界 nil、切片语法、substring 尾部计数；下标读严格 Optional some/none（P2-E）
- String `notEqual` 分派缺失（语言内 contains 试点发现）
- 后缀 `!` 强制解包 + 回退透明解包（嵌套下标）

## v0.50.0 (2026-08-29)

### Breaking
- **match 单绑定语义**（ADR-023 D2）：`case X(b):` 的 `b` 现在绑定**第 1 个关联值**（原为整个关联值元组）。
  迁移：`case 圆(r):` 对 2 关联值声明 → 改写 `case 圆(r, _):`。
  实测影响面：examples/tests 中 26 处单绑定均为单值关联值（等价、零迁移）；
  `examples/enum-namespacing.pini` 已迁移（2 关联值 + 单绑定）。
- **绑定数与关联值数不匹配 → E4-005**（原静默绑 `.null`）。

### Added
- 具名枚举关联值全链路（ADR-023）：声明 `case E(x: T, y: U,)`、标签实参构造（具名声明）、
  match 具名解构 `case E(x: v):`、`_` 占位。

## v0.48.4 (2026-08-24)

- Initial public release of Pini (Swift implementation)

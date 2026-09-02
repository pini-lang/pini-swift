# ADR-030 · IO 相对路径解析基准——三段式方案 A（程序基准 / 运行时 CWD / 绝对）

- 状态：active（2026-09-02 采纳并实现，批 5；**追溯补写**——裁决与实现同日完成，影响评估先于实现落档于提议文档 §5）
- 关联：`docs/spec/issue/proposal-io-path-base-2026-09-02.md`（①提议 + ②影响评估，D-1~D-6 裁决记录）、§3 G58、G14（文件 IO 行已钉入基准语义）、`docs/spec/issue/issue-conflict-register-2026-08-31.md` A13/P-path（由本 ADR 出账）、F6（argv 透传，本批仅铺路）、`docs/spec/migration-2026-09.md` §E

## 背景（Context）

**双基准不对称**：`import` 的包路径解析以模块根为基准（`ModuleDependencyLoader.LoadedModule.rootPath`），而 `readFile`/`writeFile` 直接把路径传给 Foundation——相对路径按**进程 CWD** 解析。同一程序内两套路径语义并存。

**可复现性缺失**：相对路径随调用目录变化。实证：自举探针的 5 个测试用 `readFile("examples/parse_slice_corpus.pini")` 相对模块根书写，只能从模块根目录运行（gate 恰好从模块根跑而掩盖隐患）；批 6 清单工具、批 7 远程抓取均会踩。

**F6 耦合**：argv 透传落地后，用户 shell 传入的路径与程序资源路径将共用 `readFile`——基准规则不定，F6 无法立项。

**取证修正**（2026-09-02 01:43，现于 18:30 重验符号 FRESH）：LLVM 端 IO **已实现**（`BuiltinsEmitter.generateBuiltinReadFile/WriteFile` 直接 `fopen`），IO 非解释器专属——方案必须含双后端对齐。迁移面 ≈ 0：现存 IO 用法全为绝对路径（`io.pini` 用 `/tmp`）或测试绝对注入（IOTests），破坏面为零；G14 尚为 Provisional，窗口期合适。

## 决策（Decision）

D-1~D-6 全按提议推荐（2026-09-02 用户批准）：

| # | 裁决 | 理由 |
|---|---|---|
| **D-1** | 采**方案 A：按路径形态三段式**——绝对路径原样；`./` `../` 开头相对**运行时 CWD**（用户/shell 视角）；其余相对路径相对**程序基准**（模块运行=模块根、单文件=入口文件所在目录） | 程序资源可复现（自举 5 假失败零改动修复）；用户路径天然正确（F6 铺路）；与 import 基准对齐消除双基准。B（全 CWD + 查询）把可复现性推给每个程序；C（chdir）吞掉用户 CWD；D（仅文档）隐患保留 |
| **D-2** | 新增 `moduleRoot() -> String`（.io 组）返回程序基准 | 程序可显式感知基准；未注入基准时**如实返回 CWD**（不伪造模块根）；LLVM 端 unsupported（ADR-028 惯例） |
| **D-3** | 单文件模式基准 = 入口文件所在目录 | 脚本在哪儿，资源就在哪儿；比 CWD 可预测 |
| **D-4** | LLVM 端：无前缀相对路径**字面量**编译期烘焙 `基准 + "/" + 路径`（`generateIOPathArgument`）；`./` `../` 原样嵌入（运行时 CWD） | 双后端语义一致（批 2 建立的原则）；跨机运行路径不可移植、非字面量路径按 CWD——**v1 已知限制，如实记录** |
| **D-5** | argv 透传不入本批 | 本批只定 `./` 语义铺路 |
| **D-6** | 本项 = 批 5；清单工具顺延批 6、远程抓取批 7 | — |

**实现形态**：解释器 `programBase`（子解释器继承——import 模块内 IO 相对主程序基准）；CLI 六执行入口注入（run 单文件/模块、两调试器路径、模块/单文件测试、模块外目录聚合）；`absoluteProgramBase` 辅助（相对输入先按 CWD 绝对化再标准化）。

## 后果（Consequences）

**正面**：程序资源路径可复现可测；自举测试从仓根直跑 70/0（原 5 个 CWD 依赖假失败**零测试改动**修复，终验通过）；`./` 语义为 F6 铺路；双后端一致。

**负面 / 限制（如实记录）**：
- **破坏性**：无前缀相对路径 CWD → 程序基准；现存用例受害数 0（全部绝对路径或绝对注入）。
- LLVM 非字面量路径（变量/插值）无法烘焙，运行时按 CWD——与解释器在「路径来自运行时计算」时不一致；v1 限制。
- LLVM 烘焙使 IR 携带编译机绝对路径——跨机分发不可移植；v1 限制。
- REPL / 直建 `Interpreter()` 未注入基准 → 退回 CWD（兼容既有 IOTests）。

**迁移**：`docs/spec/migration-2026-09.md` §E——相对路径需 CWD 语义的加 `./` 前缀；需程序资源的保持无前缀（模块模式自动正确）。

## 实测证据

| 断言 | 证据 |
|---|---|
| 模块运行无前缀路径解析到模块根（CWD≠模块根） | 2026-09-02 18:30 探针：从 `/tmp` 跑 `/tmp/base_mod`，`readFile("res.txt")` 成功读取模块根下文件；`./res.txt` 按运行时 CWD 找不到 → panic |
| LLVM 烘焙生效 | IR 常量解码 = `/tmp/base_mod/res.txt\00`（22 字节含 NUL），fopen 实参经 `@.str0` GEP 引用 |
| 自举假失败修复 | `pini test examples/selfhost` 从仓根直跑 70/0（测试文件零改动）；IOTests 6/0（兼容面） |

代码定位（2026-09-02 18:30 符号重验）：`Sources/PiniCore/Interpreter/Interpreter.swift:147` programBase、`:160` resolveIOPath；`Sources/PiniCLI/main.swift:679` absoluteProgramBase；`Sources/PiniCore/CodeGen/IRGenerator.swift:107` programBase；`Sources/PiniCore/CodeGen/Emitters/BuiltinsEmitter.swift:173` generateIOPathArgument；`Sources/PiniCore/CodeGen/Emitters/ExprEmitter.swift:663` moduleRoot unsupported；`Sources/PiniCore/Common/BuiltinRegistry.swift:111` moduleRoot 登记。

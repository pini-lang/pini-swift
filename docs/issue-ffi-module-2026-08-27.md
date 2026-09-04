# Issue: FFI 模块示例专项 — 缺陷与待办收录

- **状态**：Open（部分已修复，部分待立项）
- **提出视角**：测试工程师（examples/ffi_module 示例与 FFIModuleTests 门禁交付过程中发现）
- **关联交付**：`examples/ffi_module/`、`Tests/PiniTests/FFIModuleTests/FFIModuleTests.swift`
- **范围**：本 issue 不拆分子工单，统一收录 FFI 示例独立性改造中遇到的全部缺陷、坑与建议。

---

## 一、已修复的真缺陷（代码级，已合入）

| # | 缺陷 | 组件 | 修复位置 | 验证 |
|---|---|---|---|---|
| B1 | dlsym 返回的 `*T` 指针 `elemType:nil`，导致 `store`/`load` 报「指针元素类型未知」(E5-006) | 解释器后端 | `Sources/PiniCore/Interpreter/ForeignThunk.swift`：从签名 `*T` 提取元素类型回填 `RawPointerValue` | 原 libc 版靠 native shim 白名单绕过，改 `ffi_*` 名字暴露；修复后 vendored lib 上 store/load 正常 |
| B2 | `[ffi].search_paths` 按进程 cwd 解析，配置不随模块目录移动 | 加载器 | `Sources/PiniCore/Common/FileLoader.swift`：`loadManifest` 将非绝对项规一为相对模块目录的绝对路径 | 从 `/tmp` 等不同 cwd 运行 `pini run/test` 均定位到 vendored lib |
| B3 | `pini test <单文件>` 不读所在目录 `pini.toml` 的 ffi 配置，找不到 vendored lib | CLI | `Sources/PiniCLI/main.swift`：`runTestPath` 改为从单文件目录 `loadManifest` 并 `Interpreter(ffiConfig:)` | 单文件 `pini test examples/ffi_module/cstring.pini` 2 用例通过 |

> 以上三项已随示例独立性改造在本会话内修复，`swift test` 全绿（FFIModuleTests 7 用例通过）。

---

## 二、语言既定行为（非 bug，已文档化，未改解释器）

以下在 FFI 示例中实测确认，当前作为行为约束写进 `cstring.pini` 注释与项目记忆；**未改动解释器**，是否升级为设计提案见第三节。

| # | 行为 | 影响 | 当前规避方式 |
|---|---|---|---|
| G1 | foreign 符号为**文件级作用域**，跨文件不可见（报错 E5-017 undefined function） | 多文件模块里 raw 调用必须与 `[X\|foreign]` 声明同文件 | **已钉定（2026-09-04 批 D）**：文件级作用域入 spec §2.7（最小暴露原则），残余清零 |
| G2 | `load` 返回动态 `Any`；仅在**非 unsafe 上下文**（main / `\|test` 块）用 `unsafe load(p)` 才能显式标注收回具体标量；`\|unsafe` 函数体内 `load` 恒为 `Any`，无法转具体类型 **〔时间线注记 2026-09-04〕本行为描述写于 ADR-015 Phase 2a 落地之前，已过时：现 load 按指针元素类型编解码返回类型化值（spec §2.7），实测 main 内裸 `load(p)` 不报 E4-001、正常解码（E-111）；§2.7 与本表 G2 语义以 spec 为准** | 「读回指针值」的演示只能放在 main / `\|test`，unsafe 封装函数只能返回 `*U8`（由调用方读取） | 值读取移出 unsafe 函数体 |
| G3 | `==` 仅对 **I32** 可靠；U64/U8/指针比较在 `assert` 参数内报类型错，仅在 `if` 条件内对 foreign 直接返回值可用 | `\|test` 断言只能对 I32 返回（atoi/strcmp）用干净 `assert`，U64/U8 结果改用 `main` 经 golden 输出验证 | `if/else + assert(Bool)` 或 golden 比对 |
| G4 | foreign C 调用（如 `puts`）直写真实 stdout，绕过解释器 `outputSink` | 进程内测试捕获不到该输出行，`pini run` 终端可见 | golden 测试排除 puts 行并在注释说明 |

---

## 三、待立项建议（本 issue 收录，不单独开工单）

> 用户决定：不拆分子工单，以下统一在本 issue 跟踪。优先级供排期参考。

### P1 — FFI 输出可观测性（真缺陷，建议后端修复）
- **问题**：foreign C 调用绕过 `outputSink`，测试无法断言 FFI 的 stdout 副作用（G4）。
- **建议**：要么把 foreign 输出统一接回解释器 `outputSink`，要么在 spec §2.7 明确「FFI 外部副作用不受解释器捕获」并给出测试替代方案（如用返回值代替打印）。
- **归属**：后端 / 可观测性。

### P2 — 比较运算符类型宽度（已转正式提案）
- **〔2026-09-04 批 D〕**已登记为正式提案 `docs/spec/issue/proposal-comparison-width-2026-09-04.md`
  （§1.3 ①，含 P-α/P-β/P-γ 三候选路径），本工单不再承载设计内容。

### P3 — FFI 规范文档补全（spec §2.7）

- **内容**：foreign 文件级作用域（G1）、`load→Any` 语义（G2）、libc 保留名跳过 `[ffi]` 配置、`search_paths` 相对模块目录解析（B2）等，目前散落示例注释，应进入规范正文，避免后人重复踩坑。
- **归属**：文档 / spec。
- **〔时间线注记 2026-09-04〕**大部分已被 spec §2.7 覆盖出账：`search_paths` 相对模块目录解析（B2）、解析顺序（shim 白名单 → 裸 C 绑定，即 libc 保留名语义）、`[ffi]` 配置语义均已入正文；G2 的 load 语义描述本身已过时（见上表注记）。**残余唯 G1（foreign 文件级作用域）未入 spec**，P3 收窄为「G1 钉定」。**〔2026-09-04 批 D〕G1 已钉定入 spec §2.7——P3 全部出账，本节收口。**

### P4 — vendored 库跨平台工程化
- **内容**：`examples/ffi_module/lib/libffilib.dylib` 为 macOS 专属二进制；CI 需在 Linux 用 `cc -shared -fPIC -o libffilib.so ffilib.c` 重建。建议加构建脚本或纳入 `.gitattributes` 标记二进制，避免 diff 膨胀。
- **归属**：工具链 / 跨平台。

---

## 四、验收口径（Definition of Done）

- [x] B1/B2/B3 已修复并验证
- [ ] P1 决定修复方案（接回 outputSink 或 spec 明确）并落代码/文档
- [ ] P2 形成类型系统设计提案（ADR 或 spec 修订）
- [ ] P3 规范 §2.7 补全上述 G1/G2/libc 保留名/search_paths 语义
- [ ] P4 提供跨平台构建脚本或 `.gitattributes` 标记

---

## 附录：复现命令

```bash
cd Pini
swift build
pini run  examples/ffi_module/              # 预期 6 行输出
pini check examples/ffi_module/             # 通过
pini test examples/ffi_module/cstring.pini    # 2 通过
swift test --filter FFIModuleTests             # 7 通过
```

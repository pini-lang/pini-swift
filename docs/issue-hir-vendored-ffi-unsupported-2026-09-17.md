# HIR 引擎解析不了 vendored FFI 符号（`[ffi] libs`，即 dlsym 那一段）

> 状态：**Open**（2026-09-17 立案；**只登记不修**）
> 发现于：`A1`（包通道补全，队列甲组）。它**不是**该批的对象，而是在包通道首次把模块成员纳入判定之后
> **露出的下一道缺口** —— 在此之前这个模块**不被任何探针看过**（探针 6 根里它是 `PACKAGE_MEMBER`）。
> 上游：`docs/issue-hir-blocker-queue-2026-09-17.md` §1 的 `A1` 行 · `docs/hir-criteria-gap-ledger.md` §9。

## 1. 现象（实测，2026-09-17，`e3dd5c8`，`A1` 批）

夹具：`examples/ffi_module`（含 `pini.toml` 的模块；`[ffi] libs = ["ffilib"]`、
`search_paths = ["lib"]`，符号来自同目录 vendored 的 `lib/libffilib.dylib`）。

| 命令 | 结果 |
|---|---|
| `pini run examples/ffi_module`（默认 `ast`） | rc=0，stdout 6 行（`长度 = 8` / `atoi = 4096` / `填充字节 = 7` / `堆字节 = 100` / `拷贝字节 = 7` / `hello, FFI`） |
| `PINI_INTERP_ENGINE=hir pini run examples/ffi_module` | **rc=1**，`E5-006` — `invalid operation: HIR executor: foreign callee ffi_strlen is declared by the module but has no shim; raw C bindings need the interpreter's dlsym loader, which this engine does not carry` |

**对照（关键）**：`examples/ffi.pini`（**单文件**，只用 libc 侧预注册符号）

| 命令 | 结果 |
|---|---|
| `pini run examples/ffi.pini`（`ast`） | rc=0，stdout `buf =  42 / buf =  100 / x =  7 / len =  5 / hello, FFI` |
| `PINI_INTERP_ENGINE=hir pini run examples/ffi.pini` | rc=0，**stdout 逐字节相同** |

⇒ 问题**不在 FFI 本身**，而在**符号解析的第二段**（vendored 库 / 裸 C 绑定）。

## 2. 符号级根因（读码，非推断）

1. **解释器侧的解析顺序是两段**，`Sources/PiniCore/Interpreter/Interpreter.swift` 的注释原文写明：
   「解析顺序固定：① 预注册 shim 白名单（`nativeFunctions`）→ ② 裸 C 绑定（dlsym，Phase 2b）」。
   第 ① 段的表在 `Interpreter.registerNativeFunctions()`（同文件）用 `Interpreter.libcShims` 填充。
2. **HIR 执行器只带第 ① 段**：`Sources/PiniCore/Interpreter/HIRExecutor.swift` 的 foreign 分派处
   在表里查不到 callee 即拒（上面那句错误文本就在该处）。
3. `cstring.pini` 声明的 `ffi_strlen` / `ffi_atoi` / `ffi_strcmp` **不在 `libcShims` 内**
   —— 它们来自 `[ffi] libs` 指向的 vendored 动态库，**必须走第 ② 段的 dlsym**（载体在
   `Sources/PiniCore/Interpreter/ForeignThunk.swift` + `SystemDL.swift`）⇒ HIR 侧**没有路径**。

## 3. 影响面

- **用户可见**：翻转（`P4`）后默认引擎是 HIR ⇒ **凡依赖 vendored FFI 库的程序不再可运行**。
  这是能力回退形态，与 `R1/R2` 那次「保能力」的账同族。
- **规范口径**：`docs/spec/pini-spec-v0.md` §2.4.1 的 `[名称|foreign]` 块一行现记
  「已实现（ADR-015，Phase 2a 解释器优先；LLVM 端显式 unsupported）· ✅（解释器）」——
  **HIR 这一条通道的缺口未登记**。
- **判据面**：该模块整个不被探针覆盖（`PACKAGE_MEMBER`）；`A1` 之前**没有任何器械**能看见这条分歧。

## 4. 实现路径（**未裁**；未决策前不动源码）

- **路径 A（倾向）· 把「foreign callee 解析」做成单源表，两引擎读同一张**：
  照 `G-3a` 的「表即白名单」定式，让 HIR 侧与解释器侧共用同一条解析链（先查 shim 表，
  未命中再走 dlsym）。收益 = 能力不回退、且两引擎不会各持一份规则。
  代价 = HIR 执行器要能触达 `SystemDL` 的**已加载库句柄**（该句柄现在活在解释器实例上），
  需先定清它的归属（模块级资源 vs 引擎级资源）。
- **路径 B · 显式退役**：`[ffi] libs` 在 HIR 侧不支持，随翻转明示（release note + 规范口径），
  `examples/ffi_module` 随之改指 AST 通道或降为「解释器专属示例」。
  代价 = 用户可见能力回退（与 `R1` 裁决的方向相反），收益 = 不动第二个大件。

## 5. 与在册条目的关系（避免重复登记）

| 在册项 | 与本单的关系 |
|---|---|
| `docs/issue-ffi-module-2026-08-27.md` | **不同对象**：那是示例专项（其 B1 修的是 dlsym 返回值 `*T` 的 `elemType`，**解释器后端**已修）；本单是 **HIR 引擎缺这一段** |
| `docs/issue-hir-import-module-symbols-2026-09-16.md` | **不同对象**：那是 `import` 目标的**符号表**缺失（包级合并）；本单是 **foreign 符号的解析链**缺失 |
| `docs/issue-llvm-concurrency-runtime-2026-09-08.md` | **不同对象**：并发面；本单与它共享一句「翻转后某能力面无跨实现证据」，但语料与机制不相交 |

## 6. 不做范围

- **未裁前不动源码**（本单只登记）。
- 不改 `docs/spec/pini-spec-v0.md` §2.4.1 那一行的状态（若裁 A/B，随裁决另立文档动作）。
- 不并进 `A1`（该批按「判据器械」如实收口：包通道补全 + 分歧归主，**不修分歧**）。

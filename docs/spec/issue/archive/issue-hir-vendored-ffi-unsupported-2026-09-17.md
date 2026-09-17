# HIR 引擎解析不了 vendored FFI 符号（`[ffi] libs`，即 dlsym 那一段）

> 状态：**已交付并收口（2026-09-18）** —— 走 §4 **路径 A**（两引擎共用一条解析链）；处置见 §7。
> 原状态：Open（2026-09-17 立案；只登记不修）
> 🏁 **归档（2026-09-18，工单巡查批）**：判据 = §7 处置记录（目标达成 · 缺口消失 ·
> 残留「LLVM 端 FFI 仍 unsupported」已标注**不属本单**）。本件由宿主级 `docs/` 移入
> `docs/spec/issue/archive/`；全部入向引用已同批改指。
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

## 7. 处置记录（2026-09-18，`G-4` 批）

**结论**：目标达成，**走 §4 路径 A**。缺口消失，工单闭环。

**裁决与范围**：`G-4` 的裁决（`D-P4-31` 取 ①）本只覆盖「HIR 侧实现测试块驱动」；
用户 2026-09-18 **当场追加**「本批一并实现 HIR 侧 `dlsym` 加载器」（本项目原建议挂账，
用户改取并入），故本单目标随 `G-4` 同批达成。

**落地**（`Sources/PiniCore/`，与 §2 的符号级根因逐条对应）：
| §2 指出的缺环 | 本批补法 |
|---|---|
| ① 解析顺序是两段，HIR 只带第 ① 段 | 两段都在：`RuntimeOps.libcShims`（与解释器**同一张表**）→ `FFILoader.resolve` |
| ② foreign 分派处查不到 shim 即拒 | 改为「shim 未命中 → `dlsym` 裸 C 绑定 → `ForeignThunk`」 |
| ③ 库句柄活在解释器实例上（§4 路径 A 的代价） | **定为引擎级资源**：`HIRExecutor` 各持一份 `FFILoader`，与解释器同形；不引入跨引擎共享句柄表 |
| shim 名与裸绑定名不分 | `foreignNames: Set<String>` → `foreignDecls`（名 → 块名 + 签名），块名即库绑定键 |

**判据（现测）**：`pini run examples/ffi_module/`（默认引擎）**rc=0**，stdout 与 AST
**逐字节相同**（md5 `cbb80b5d…`）——即 §1 表里那两行的分歧**已消**。
`pini test examples/ffi_module/cstring.pini` 与包模式各 2 通过 0 失败。
全量回归逐条「新增红 0」；探针 320 夹具零位移。

**§3 的两条影响面处置**：
- **用户可见**：不再是回退 —— 默认引擎上可运行（即本单的验收）。
- **规范口径**：已订正 `docs/spec/pini-spec-v0.md` 两处 —— §3 台账 `[名称|foreign]` 行
  的状态由「✅（解释器）」改为「✅（解释器 + HIR）」、实现栏补 Phase 2b 与共用解析链；
  长期愿景 T14 行删去已落地的「`dlsym` 动态符号解析」项。

**残留（不属本单）**：LLVM 端的 FFI 仍显式 unsupported（`D1` 暂缓，见 §3 那一栏），
本批未动；`ForeignThunk` 的「GPR + 浮点混合签名不支持」为既存限制，仍在册。

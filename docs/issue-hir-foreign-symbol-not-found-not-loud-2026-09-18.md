# Issue：**未找到的 `foreign` 符号在 HIR 侧不 fail-fast**（AST 急切解析 · HIR 惰性解析）

> **日期**：2026-09-18｜**状态**：**已交付**（`G-6a`，2026-09-18）—— 判据 1/2/3 实测达；
> **判据 4 该批未记录复核**，列入 `G-6b` 开工前的复核清单（见 §8）
> **发现于**：格 `G-5`（D 类参照臂改造）—— `FFIModuleTests` 的驳回性用例换腿后**不再抛错**
> **性质**：**既有语义差异**（两引擎对同一份源码的**失败行为**不同）
> **归属**：**`G-6` 前置**（该用例无法换腿）—— ✅ 前置已解除

## 1. 现象（实测）

夹具 `Tests/PiniTests/FFIModuleTests/testUndefinedForeignSymbolRejected.pini`：

```
[libc|foreign]
不存在的符号(x: I32,) -> (I32,)

main|func() -> ():
    print("x")
    return
```

`符号`**声明了但从未被调用**。两个引擎的实测对比：

| 引擎 | 实测读数 |
|---|---|
| AST 走查 | **抛错**，报错含 `未找到符号` / `symbol` / `E5-017` ⇒ 用例通过 |
| HIR 树走查 | **不抛错**（`XCTAssertThrowsError failed: did not throw an error`），且 `print("x")` 正常输出 ⇒ 用例红 |

## 2. 根因（符号级：**解析时机不同**）

| 侧 | 位置 | 形态 |
|---|---|---|
| AST | `Sources/PiniCore/Interpreter/Interpreter.swift:721`–`:724` | 声明登记时**逐个急切解析**：`if case .foreignDecl(let fd)` → `try resolveForeignImpl(f, library: fd.name, …)` ⇒ **未调用也解析** |
| AST | 同件 `:742` | `resolveForeignImpl` → `FFILoader.resolve(…)` |
| 公共 | `Sources/PiniCore/Interpreter/FFILoader.swift:20` | `throw RuntimeError.symbolNotFound(library:symbol:location:)`（即 `E5-017`）|
| **HIR** | `Sources/PiniCore/Interpreter/HIRExecutor.swift:448`–`:451` | 只**记名**：`foreignDecls[function.name] = (library: block.name, function: function)` |
| **HIR** | 同件 `:604`–`:607` | **调用点才解析**（`if let foreign = foreignDecls[name]` → `ffiLoader.resolve(…)`）|

⇒ **HIR 侧没有「注册期解析」这一步**，于是「找不到的符号」在**没人调用它**时**永远不被发现**。

## 3. 影响面

| 面 | 说明 |
|---|---|
| **`G-4` 刚交付的 dlsym 加载器** | 本缺口**不是它引入的**（`G-4` 让 HIR 能解析**存在**的符号）—— 它是**同一条链的另一半**：解析失败时报不报 |
| 用户可见性 | 一条拼错的 `foreign` 声明在 HIR 引擎上**静默通过**，直到第一次调用才炸；AST 侧当场炸 |
| 判据面 | `FFIModuleTests` 的这条**驳回性**用例是唯一定位它的器械 ⇒ 无法换腿 |

⚠️ **与 `G-4` 的闭环工单不是同题**：那份（`…vendored-ffi-unsupported…`）记的是「HIR 侧**没有** dlsym 链」，
已随 `G-4` 交付闭环；本条记的是「有链之后，**解析失败不报**」。⇒ **新立，不并件**。

## 4. 处置候选（**不预设**）

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** | HIR 侧加**注册期急切解析**（`prepare(module:)` 里对 `module.foreigns` 逐个 `ffiLoader.resolve`）⇒ 与 AST 同相 | 小（约 10 行，`HIRExecutor.prepare` 一处）；须核「解析即加载」是否会拖慢或不必要地 `dlopen` 未用到的库 |
| **B** | 保持惰性，但**语言面**改口径为「声明即契约，调用才校验」 | 中：须走 `spec §1.3`，且**两引擎口径要一起改**（否则差异更隐蔽） |
| **C** | 显式退役该用例，把差异登记为已知 | 小；但**丢掉唯一的器械** |

**建议**：**A** —— AST 侧的语义是既成事实（`E5-017` 是**注册期**错误码），
HIR 追上它属「实现对齐既有约定」；且代价是全条里最小的。

## 5. 判据（怎么算完成）

| # | 判据 | 测法 |
|:--:|---|---|
| 1 | 两引擎对同一夹具**同相** | HIR 与 AST 都抛 `E5-017`（或都按新口径不抛，取决于裁决） |
| 2 | 该用例在**默认引擎**上绿 | `swift test --filter FFIModuleTests` 7/7 |
| 3 | 无新增红 | 全量回归逐条集合：新增 0 |
| 4 | 正常的 vendored FFI 不受影响 | `examples/ffi_module` 仍 `rc=0` 且与 AST 逐字节相同 |

## 6. 不做范围

只登记。**不改 `Sources/`、不改测试、不改规范**；开工须单独点名。
本批（`G-5`）已把该用例**回退到 AST 臂**并在注释里写明理由 —— **回退不是修复**。

## 7. 复现方式

```bash
cd <repo>
swift test --disable-sandbox --scratch-path /tmp/pini-build --filter FFIModuleTests
# 换腿形态：Executed 7 tests, with 1 failure（testUndefinedForeignSymbolRejected）
# 回退形态：Executed 7 tests, with 0 failures
# ✅ `G-6a` 之后：Executed 7 tests, with 0 failures
```

---

## 8. 交付记录（`G-6a`，2026-09-18）与一项**未记录的判据**

### 8.1 处置与证据

| 项 | 值 |
|---|---|
| 裁决 | 用户 2026-09-18：**全补实现** ⇒ 取 §4 的选项 **A**（HIR 侧加注册期急切解析） |
| 实现 | `HIRExecutor.prepare(module:)` 改 `throws` + 声明后**逐个急切解析** |
| ⚠️ 一处必须记住的**链序** | 解析顺序照解释器：**先 `RuntimeLibcShims` 白名单、再 `dlsym`** —— **顺序反了**会把 `cstr`/`puts`（shim 提供的名字）**误报为找不到** |
| 判据 1 | ✅ 两引擎对同一夹具**同相**（HIR 侧 `did not throw` → 现在抛 `E5-017`，与工单预测**逐字吻合**） |
| 判据 2 | ✅ `FFIModuleTests` **1 红 → 0** |
| 判据 3 | ✅ 全量回归逐条集合：**新增红 0** |
| 判据 4 | ⚠️ **该批未记录复核** —— 见 §8.2 |
| 实录 | `docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-6a` §三项处置（处置 A） |

### 8.2 ⚠️ 判据 4 是**本单唯一未记录复核**的一项（如实登记，不在单内写成已验）

判据 4 原文：「正常的 vendored FFI 不受影响 —— `examples/ffi_module` 仍 `rc=0` 且与 AST 逐字节相同」。

**为什么这一条不是可跳过的**：本单的实现把「解析失败报不报」从**调用期**挪到了**`prepare` 期**——
即**每一次准备模块时，所有声明的 foreign 符号都必须解析成功**（不只是被调用的那个）。
⇒ 它**扩大了**解析的触发面，而 vendored 库（`examples/ffi_module` 的 `[ffi] libs`）正是最可能被这一变化
影响的对象。G-4 曾实测该夹具 `rc=0` 且与 AST 逐字节相同，但那是**改动之前**的读数。

| 项 | 值 |
|---|---|
| 状态 | ⏳ **未复核**（`G-6a` 的收口判据里没有这一项） |
| 归谁 | **`G-6b` 开工前的复核清单**（一次 `pini run examples/ffi_module/` 与 AST 逐字节比对 ⇒ 约 2 条命令） |
| ⚠️ 纪律 | **不得**在复核前把本单写成「全部判据已达」；也不得据此判为「有缺陷」—— 它是**未测**，不是**测出问题** |

## 9. 不做范围（本单交付后）

- 判据 4 的复核须**单独点名**（归 `G-6b` 的前置复核，不属本单的处置动作）。
- **不**把本单与 `docs/spec/issue/archive/issue-hir-vendored-ffi-unsupported-2026-09-17.md` 合并 ——
  §3 已说明二者不同题（「有链之后解析失败不报」vs「没有链」），后者已随 `G-4` 闭环。

# P4-0 判据面清零 · 工作件 / 交付记录

> 状态：**已交付并收口（2026-09-16）** —— `FLIP BLOCKERS 11 → 0`，三条收口判据全过。
> 分支：`agent/pini-dev/p4-0-criteria-clear`（基于 `main` @ `104a1b0`；收口时 `--no-ff` 合回、分支已删）
> 上游规划：`docs/issue-hir-p4-plan-2026-09-16.md` §3 行「P4-0」
> ⚠️ **§0–§4 是 WIP 时点**的记录，保留作历史对照；**交付读数见 §8**。

## 0. 本件目标（验收判据）

把全量探针的 **FLIP BLOCKERS 由 11 → 0**，且 7 个真阻塞各带「变异反证两级」。

**达成（2026-09-16）**：`11 → 0` ✅；变异反证两级 ✅（见 §8.3）。两条都在本件 §8 有实测证据。

- 11 = **7 真 + 4 假阳性**。
- 7 真阻塞构成（实测）：
  - `builtin-callee-unowned` × 4：`sqrt` × 3 + `malloc` × 1 → 报 `no module-level function named '…'`。
  - `struct-copy-missing` × 3：`abs` × 3 → 报 `unary operator 'abs' has no interpreter counterpart`。
- 4 假阳性：成因 = `run-llvm` 忽略 `lli` 退出码；用户在 **P3-G1 已明示接受**，本批只把该接受落到判据上（**不修 `run-llvm`**），并为「忽略退出码」**立案（只登记不修）**。详见父计划 §7 D-P4-7。

⚠️ 三条收口判据（父计划 §4）缺一不可：① AST 全量回归 0 退；② `PINI_INTERP_ENGINE=hir` 全量回归；③ 全量探针 + 逐夹具对账（FLIP BLOCKERS 11→0）。

## 1. 已批准的方案（用户 2026-09-16「这次按你的倾向来」）

**单源内建（singleton reimplementation + 分层）**：

- `abs` / `min` / `max` / `sqrt` 在解释器通道原为内联实现，HIR 通道因 lowering 形态不同（abs→一元算子、min/max→二元算子、sqrt→调用）**没有对应实现**，于是两通道各有一份定义 → 要抽成**单一源**。
- 落地位置：`Interpreter` 新增 4 个 `static` 单源方法（`builtinAbs` / `builtinMin` / `builtinMax` / `builtinSqrt`），原内联处改为调用它们；`HIRExecutor` 在对应 lowering 落点调用同一批静态方法。
- 边界保护随单源一起抽走（不能丢）：`abs` 的 `Int.min` 整数溢出拦截（`abs(Int.min)` 会触发整数溢出 trap，必须显式抛错）。
- **`malloc` 与 `sin`/`cos`/`tan` 属不同分层，不在此次「纯数学内建」的同一判断里**（见 §3 / §4）。

## 2. 当前进度（**WIP 时点**，`git diff` 实测，非记忆）

> ⚠️ 本节记的是 **WIP 落盘时**的账；其中 `malloc`「未接」与「4 假阳性未落判据」两行
> **已被 §8 取代**（两者均已交付）。保留本节是为了让「当时以为还剩什么」可复核。

### 2.1 已完成（已写入工作树，未提交）

**`Sources/PiniCore/Interpreter/HIRExecutor.swift`（+31 行）**：
- `.binary` 落点：`.minOf` → `Interpreter.builtinMin`、`.maxOf` → `Interpreter.builtinMax`（在 `operatorFor` 返回 nil 之前拦截）。
- `.unary` 落点：`case .abs` → `Interpreter.builtinAbs`（在 `operatorFor` 返回 nil 之前拦截）。
- `.call` 落点（按名分发）：`name == "sqrt"` → 校验参数个数后调 `Interpreter.builtinSqrt`；其余仍走原有 `no module-level function named` 报错。

**`Sources/PiniCore/Interpreter/Interpreter.swift`（+108 / -39）**：
- 原 `abs`/`min`/`max`/`sqrt` 内联实现**删除**，改为调用 `Interpreter.builtinAbs/Min/Max/Sqrt`。
- 文件末尾新增 4 个 `static` 单源方法（含 `abs` 的 `Int.min` 拦截、`sqrt` 的 int/float 分支）。
- **`sin`/`cos`/`tan` 内联实现未动**（仍是 `if ["sin","cos","tan"].contains(fv.name)`），确认此前误删已修复、调用链完好。

### 2.2 进度账

| 真阻塞项 | 状态 | 处理 |
|---|---|---|
| `abs` × 3（struct-copy-missing） | ✅ 已接 | HIRExecutor `.unary .abs` → `builtinAbs` |
| `sqrt` × 3（builtin-callee-unowned） | ✅ 已接 | HIRExecutor `.call "sqrt"` → `builtinSqrt` |
| `min`/`max`（防御性，不在 7 内） | ✅ 已接 | HIRExecutor `.binary .minOf/.maxOf` → `builtinMin/Max` |
| `malloc` × 1（builtin-callee-unowned） | ❌ **未接** | 见 §4.1（FFI 分层，需单独判定） |
| 4 假阳性 | ❌ **未落判据** | 见 §4.2（改判据 + 立案，不修 run-llvm） |

## 3. 已知但**不在 11 阻塞内**的 HIR 侧缺口（须实测确认）

`sin` / `cos` / `tan` 在 lowerer 侧被 lowering 成 `llvm.sin.f64` 等 **intrinsic 调用**，HIR 通道不识别（会走 `no module-level function named`）。它们**不在上述 11 个 FLIP BLOCKERS 里**（11 = sqrt/malloc/abs + 4 假阳性），但若某夹具用到它们并落入阻塞桶，则会成为新增阻塞。

⇒ 续作第一步必须先跑探针实测：若它们以新阻塞形态出现，则同 §1 抽单源（`builtinSin/Cos/Tan`）；若只落在 `CHANGE_*` / `EXEC_GAP` 等非阻塞桶，则**不计入 11→0 验收**，另立工单（只登记不修）。**不要凭记忆假设**，以探针实测为准。

## 4. 续作清单（严格按序）

> ⚠️ **本节是 WIP 时的待办清单，现已全部执行完毕**；逐项结果见 §8。第 5 步（合 main）在收口时完成。

1. **`malloc` × 1 接单源**（§2.2 唯一未接的真阻塞）
   - 先确认 AST 解释器如何应答 `malloc`（应是 `BuiltinRegistry` 里的 foreign/FFI 条目，不是纯 Swift 内建）。
   - 在 `HIRExecutor` 的 `.call` 落点加 `name == "malloc"` 分支，调用同一份单源（抽成 `Interpreter.builtinMalloc` 或复用既有 foreign 派发）。**不要猜映射**，先读 `BuiltinRegistry` / `Interpreter.builtinDispatch` 里 `malloc` 的现状。
   - 这是「分层」判断点：malloc 是 FFI callee，与纯数学内建不同层，处理方式可能不同（也许 HIR 侧应直接转发 foreign，而非抽 Swift 单源）。**此处须先读代码、再定，不在本存档里预下结论。**

2. **4 假阳性落判据**（不修 `run-llvm`）
   - 改 `tools/hir-parity-probe.py` 的判据，使这 4 个（成因 = `run-llvm` 忽略 `lli` 退出码）**不再计入 FLIP BLOCKERS**，并在判据注释里写明该已知盲区。
   - 为「`run-llvm` 忽略 `lli` 退出码」**立案**（新建 `docs/issue-*.md`，**只登记不修**）。注意：这与 `docs/issue-diagnostic-channel-parity-2026-09-12.md`（不转发语义警告）**不是同一缺陷**，后者保持 Open，不在本批。

3. **跑全量探针**（用加速姿势，见 §5.3）；预期 FLIP BLOCKERS 11 → 0（含 §3 实测后决定的 sin/cos/tan 处理）。

4. **三条收口判据**（父计划 §4）：① AST 回归 0 退；② `PINI_INTERP_ENGINE=hir` 回归（预期 7 ImportInjectionTests failures 仍在、但 builtin 相关应消解——若 sin/cos/tan 在 HIR 侧仍有 swift-test 失败，单独立案）；③ 探针逐夹具对账 Δ 全 0。

5. **提交 + 合 main**：本分支 `git add` 相关文件 → commit → `--no-ff` 合回 `main`（**不 push**）。提交信息写清「WIP 收口至 malloc 接单源 + 假阳性落判据」。

## 5. 命令速查

```bash
# 5.1 构建（沙箱关、独立 scratch，避免污染）
swift build --disable-sandbox --scratch-path /tmp/pini-build

# 5.2 两条回归（必跑，且要分层报告，不可合并成一个数）
swift test --disable-sandbox --scratch-path /tmp/pini-build            # AST（基线）
PINI_INTERP_ENGINE=hir swift test --disable-sandbox --scratch-path /tmp/pini-build   # HIR

# 5.3 全量探针（加速姿势：env -u PYTHONPATH 把 6min 降到 ~34s；-u 行缓冲实时看进度）
env -u PYTHONPATH python3 -u tools/hir-parity-probe.py

# 5.4 本回合未跑：务必在续作第 3 步前先确认当前工作树仍可编译
git diff --stat   # 预期仅 HIRExecutor.swift + Interpreter.swift 两文件改动
```

## 6. 文件地图

| 文件 | 角色 |
|---|---|
| `Sources/PiniCore/Interpreter/HIRExecutor.swift` | HIR 执行通道；本批加 4 个内建落点（~365-428 区段） |
| `Sources/PiniCore/Interpreter/Interpreter.swift` | AST 解释器；本批抽 4 个 `static` 单源（~3619-3685）+ 调用改写（~3358-3386） |
| `Sources/PiniCore/HIR/HIRLowerer.swift` | lowering：`abs`→`.unary(.abs)`、`min/max`→`.binary(.minOf/.maxOf)`、`sqrt`→调用（~2394-2421，未改） |
| `Sources/PiniCLI/main.swift` | HIR 拒绝目录/模块运行（~885）—— **这是 P4-1 的活，不在 P4-0** |
| `tools/hir-parity-probe.py` | 差分探针；第 2 步改其判据 |
| `docs/issue-hir-p4-plan-2026-09-16.md` | 父计划（分批 + 裁决） |
| `/tmp/p4_0_singleton.py` · `/tmp/p4_0_singleton_v2.py` | 本批抽取脚本（brace-pair 计数法，已用 v2 正确套用；可留作复算） |

## 7. 风险与未决

- **本回合未做全量验证**：仅 `git diff` 确认代码形态；`swift build` / 探针 / HIR 回归均**未跑**。续作第 3、4 步前必须先过 5.1/5.3。
- **`malloc` 映射未定**（§4.1）：属 FFI 分层，须先读 `BuiltinRegistry` 再定，不在本存档预下结论。
- **sin/cos/tan 是否进阻塞集未定**（§3）：以探针实测为准，不凭记忆。
- **git 纪律**：当前改动在功能分支、未提交；本批收口（第 5 步）才提交并 `--no-ff` 合 main，**绝不在 main 直落**，绝不 push。


## 8. 交付记录（2026-09-16 收口）

> 本节是**交付读数**。§0–§4 是 **WIP 时点**的记录，保留作历史对照。

### 8.1 验收（父计划 §0 的两条 + 父计划 §4 的三条，全部现跑）

| 判据 | 读数 | 判定 |
|---|---|---|
| `FLIP BLOCKERS` | **11 → 0** | ✅ |
| 7 个真阻塞各带「变异反证两级」 | 见 §8.3（两级成立、零外溢） | ✅ |
| ① AST 全量回归 | `1269 / 3 skipped / 0 failures`（EXIT=0）+ swift-testing **45 / 14 suites**；与基线**逐项相同** | ✅ 零位移 |
| ② `PINI_INTERP_ENGINE=hir` 全量回归 | `1269 / 3 skipped / **7 failures**` —— **恰是那 7 个**，全在 `Tests/PiniTests/ImportInjectionTests/ImportInjectionTests.swift` | ✅ 未新增（⇒ P4-1 的活） |
| ③ 全量探针 + 逐夹具对账 | 319 → 319、键集相同、判定变化**恰 4 处**（全 `GAP_EXEC → OK`）、其余 315 个 Δ 0、`process leaks 0` | ✅ |

**7 个真阻塞的去向**（闭合账目）：**3 个由 WIP 提交 `b04eb09` 清掉**
（`testDiffStructValue` / `examples/struct` / `testBuiltinMathIntegersViaLLI`）+
**4 个由本会话清掉**（`testBuiltinMathFloatsViaLLI` / `testDiffStdlib` / `examples/stdlib` / `examples/ffi`）
= 7，**无余项**。

### 8.2 实现面（两处，各是「一处机制一道门」）

- `Sources/PiniCore/Interpreter/Interpreter.swift`：
  libc 预注册表由实例方法内联**提为 `static let libcShims`**（单源，8 个 shim）；
  `sin` / `cos` / `tan` 由内联**提为 `builtinSin` / `builtinCos` / `builtinTan`**，
  强制转换收进共用的 `trigArgument`（诊断文案逐字不变）。
- `Sources/PiniCore/Interpreter/HIRExecutor.swift`：`.call` 落点新增**两道门** ——
  ① **declared-foreign 门**：名字落在 `module.foreigns` 里才查 `Interpreter.libcShims`；
  **未声明仍报错**，故两通道对「没声明就调用」的判断一致（不无条件认领 shim 名）；
  ② **intrinsic 门**：`llvm.` 前缀的名字按表回答（`llvm.sin.f64` / `llvm.cos.f64`），表外 fail-loud。

**为何 `tan` 不在实现面**：lowering 把它拆成 `llvm.sin.f64` 与 `llvm.cos.f64` 的**除法**
（LLVM 无 `tan` intrinsic）⇒ 引擎永远看不到 `tan`。`builtinTan` 仍留在 AST 侧作**唯一一份** `tan` 定义。

### 8.3 变异反证两级（本批 7 个真阻塞的判据）

四夹具 × 五态。**M1** = 两道门全禁（= 本批实现面整体撤销）；
**M2** = 只禁 foreign 门；**M3** = 只禁 intrinsic 门。

| 夹具 | 基线 | M1 | M2 | M3 | 还原后 |
|---|---|---|---|---|---|
| `Tests/PiniTests/CodeGen/IRExecutionTests/testBuiltinMathFloatsViaLLI.pini` | OK | **GAP_EXEC** | OK | **GAP_EXEC** | OK |
| `Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/testDiffStdlib.pini` | OK | **GAP_EXEC** | OK | **GAP_EXEC** | OK |
| `examples/stdlib.pini` | OK | **GAP_EXEC** | OK | **GAP_EXEC** | OK |
| `examples/ffi.pini` | OK | **GAP_EXEC** | **GAP_EXEC** | OK | OK |

⇒ **两级都成立**：M1 全红 = **精确回退到本批前的状态**；M2 与 M3 **各自只红自己的路径、零外溢**
⇒ 两条路径**可分别归因**。源码 md5 还原后逐字节相同，`git diff --numstat -- Sources` 与变异前一致。

⚠️ **器械自身的一条假绿（已挡下，留档）**：首跑四夹具**全判 `FRONTEND_FAIL`** ——
根因是**器械没带 LLVM 的 PATH**（`run-llvm` 起不来 `lli`），**不是代码**。
⇒ 器械已加**基线自守**（四夹具基线须为 `OK`，否则中止）：否则会得到一张
「每个变异轮都无变化」的空表，读起来像**代码无罪**。

### 8.4 判据面：4 个假阳性的「接受」**已落地**

- `tools/hir-parity-probe.py` 新增**非阻塞槽位 `WARN_LLVM_RC_UNPROPAGATED`**，
  门 = **参照臂非零 ∧ LLVM 臂 stderr 非空**（缺一即仍落 `GAP_EXEC`）。
- **区分力是实测的**：判据真值表自检 **6/6** —— 其中三例专测**「只在 HIR 臂失败」仍落回阻塞集**，
  即这次改动**没有**顺手放行真缺口。
- `run-llvm` 依裁决**未改**；其「丢弃 `lli` 退出码」已立案：
  `docs/issue-run-llvm-discards-lli-exit-status-2026-09-16.md`（登记不修）。
- 分母守恒：254 + 27 + 12 + 2 + 20 + 4 = **319**。

### 8.5 本批未做（写成范围）

- **未做 P4-1 ~ P4-4** —— HIR 回归那 7 个失败**原样在册**，指向 P4-1（包运行入口）。
- **未修 `run-llvm`**（依裁决）；**未处置** `CG-03/09/10/11/12`（挂「P4 前置 · 独立批次」，本批不并）。
- **未动 spec / ADR / 契约**（本批不触语言面）。
- ⚠️ **未测 `sin` / `cos` 的 f32 变体**：`Sources/PiniCore/CodeGen/IREmitter.swift` 只声明
  `llvm.sin.f64` 与 `llvm.cos.f64` 两条 intrinsic，**`.f32` 不存在** ⇒ 本批按 f64 实现，
  且对表外 `llvm.*` 名 fail-loud（将来若出现 `.f32`，会**大声失败**而不是静默错算）。
- 未 push（宿主仓从未 push）。

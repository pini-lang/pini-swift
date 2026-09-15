# P4-0 判据面清零 · 工作件 / 续作存档

> 状态：**WIP（已开工，2026-09-16 落盘）**
> 分支：`agent/pini-dev/p4-0-criteria-clear`（基于 `main` @ `104a1b0`）
> 上游规划：`docs/issue-hir-p4-plan-2026-09-16.md` §3 行「P4-0」
> 本件是 P4-0 的**工作件 + 续作存档**；本回合因会话截断风险，先落盘进度，未做全量验证。

## 0. 本件目标（验收判据）

把全量探针的 **FLIP BLOCKERS 由 11 → 0**，且 7 个真阻塞各带「变异反证两级」。

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

## 2. 当前进度（本回合 `git diff` 实测，非记忆）

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

# Issue：`run-llvm` 丢弃 `lli` 的退出码 —— LLVM 臂的返回码不反映程序的成败

- 状态：**Open（2026-09-16 立案；登记不修）** —— **未决策前不动源码**。
  本单是**判据类**缺陷（器械读到的是假的成功），不是语言语义缺口。
- 发现来源：**P4-0（判据面清零）批**。该批按既有裁决（P3-G1 用户明示接受的
  「4 个负向测试被计为阻塞」）把 4 个夹具移出阻塞集，并**同时为它们读到假状态的那个机制立案** ——
  接受代价**不等于**让机制继续无户口。
- 关联（**不是同一件事，勿合并**）：
  - `docs/issue-diagnostic-channel-parity-2026-09-12.md`：对象是**不转发语义警告**
    （`WARN_CHANNEL_ASYMMETRY` 那 20 例的根源）。本单对象是**退出码不转发**，两者**根因、载体、
    影响面均不同**。该单保持 Open，A/B/C 未裁，**不在本单范围**。
  - `docs/spec/hir-contract.md` §5.1：`bk_*` 是 LLVM 后端的实现面，本单不改变该口径。
  - `docs/hir-criteria-gap-ledger.md`：本单**不是** `CG-` 族条目（那族是「判据看不见 / 判据说了
    不算」），本单是**被判据读到的那个信号本身是错的**；两者相邻但登记处不同。

## 性质

- **不是翻转阻塞**：这 4 个夹具的程序在**两个引擎下都失败**，翻转前后**行为不变**
  （见下表：`a_rc=1` 且 `h_rc=1` 且 LLVM 臂 stderr 有真报错）⇒ 它不进 `FLIP BLOCKERS`。
- **是判据缺陷**：`pini run-llvm` 的**退出码恒为 0**（只要 JIT 起得来），于是任何以该 rc 为
  证据的判据都会把「程序崩了」读成「程序成功」。这是一种**假绿**：
  它让「LLVM 臂没意见」与「LLVM 臂其实也失败了」在判据层**同形**。
- **是用户可见缺陷**：脚本里 `pini run-llvm x.pini` 无法据返回码判断失败；
  `&&` 链、CI 步骤、以及任何自动化都会静默继续。

## 现象（实测，2026-09-16，本机）

三通道逐夹具实测（`pini run` × 2 与 `pini run-llvm`，见「复现」）：

| 夹具 | `interp-ast` rc | `interp-hir` rc | `llvm-hir` rc | LLVM 臂 stderr 首行 |
|---|:---:|:---:|:---:|---|
| `Tests/PiniTests/RuntimeBackendTests/testArrayOutOfBoundsBothBackendsError.pini` | 1 | 1 | **0** | `Pini runtime error: array index 99 out of bounds (size 3)` |
| `Tests/PiniTests/RuntimeBackendTests/testArrayWriteOutOfBoundsBothBackendsError.pini` | 1 | 1 | **0** | `Pini runtime error: array index 5 out of bounds (size 3)` |
| `Tests/PiniTests/RuntimeBackendTests/testDictMissingKeyBothBackends.pini` | 1 | 1 | **0** | `Pini runtime error: dict key not found …` |
| `Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/testDiffIoProgramBase.pini` | 1 | 1 | **0** | `Pini runtime error: readFile could not open the file` |

⚠️ **关键读数**：LLVM 臂的 stderr **非空**（真报错，且带 `Stack dump:` 段），
而它的 **rc 是 0**。⇒ 判据若只读 rc，得到的是与事实相反的信号；
正因为 stderr 非空，本单的机制**可测**、且探针的新槽位能给出可核验的门。

## 根因（符号级）

`Sources/PiniCLI/main.swift` 的 `run-llvm` 分支：

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: lli)
process.arguments = lliArgs
try process.run()
process.waitUntilExit()          // ← terminationStatus 被丢弃，函数无返回值表达它
```

- 该分支 `waitUntilExit()` 之后**不读 `process.terminationStatus`**，也不据此影响自身退出码
  ⇒ 只要 `process.run()` 成功，命令即返回 0。
- 这与**测试 Harness 侧**形成对照：`Tests/` 内的 lli 调用点收口在单一 helper，且
  **读 stderr 并检查 `terminationStatus`**（该纪律是 M6b 缺 `--dlopen` 那类「空 stdout 假象」
  的处置产物）⇒ **同一个 lli，两个消费者，只有 CLI 这一侧把状态扔了**。

## 为什么不在 P4-0 顺手修（三条拒绝理由）

1. **用户已明示接受该代价，且明示「不修 `run-llvm`」**（P3-G1 裁决；本批父计划据此复述）。
   接受一条代价 ≠ 授权改实现，两件事。
2. **修它不是机械改动**：把 `terminationStatus` 透出后，探针的既有规则 3
   （`l_rc != 0` ⇒ `FRONTEND_FAIL`）会**抢先命中**这 4 个夹具 —— 而它们是**运行时**失败，
   不是前端拒绝 ⇒ 修完会把它们从「假阻塞」换成**错标签**。正解需要同时给判据加
   **运行时失败槽位**，属判据族的改动，不属清阻塞。
3. **影响面未清点完毕**：以 `run-llvm` 的 rc 为证据的消费者至少 4 个
   （`tools/hir-parity-probe.py` · `tools/hir-spec-assert.py` · `tools/three-channel.py` ·
   `bench/run_benchmarks.py`），其中第三层器械**把 rc 与 `.expected` 比对** ⇒
   翻转该 rc 的语义前须逐消费者核，否则会把一个判据面的改动扩散成三个器械同时改口。

## 建议处置（A / B，待裁）

- **A（推荐）：透出 `terminationStatus`，并同步改判据族**
  1. `pini run-llvm` 在 lli 非零退出时以**非零**退出（并保留 lli 的原始码或映射为统一码 —— 取哪种须一并裁）；
  2. 探针加**运行时失败槽位**（三臂皆失败且 LLVM 臂 stderr 非空），使「程序失败」在三臂上
     都是非阻塞且**标签正确**，不再借 `FRONTEND_FAIL` 或 `GAP_EXEC` 表达；
  3. 逐消费者核 `hir-spec-assert.py` / `three-channel.py` / `bench/run_benchmarks.py`。
  - 代价：三处联改；须跑全量探针 + 双回归复核零位移之外的**预期位移**。
  - 收益：LLVM 臂的退出码成为**真信号**；本单所述的假绿消失；
    探针的「LLVM 臂没意见」这句话第一次有证据支撑。
- **B：维持现状，把该盲区**继续**写在判据里**（即 P4-0 已落地的形态：新槽位
  `WARN_LLVM_RC_UNPROPAGATED` + 门 + 本单）。
  - 代价：`pini run-llvm` 对用户仍不可依赖；每个新器械都要**重新知道**这条盲区。
  - 判定：可接受为**临时态**，但不足以作为长期口径 —— 盲区写在工具注释里，
    对工具之外的用户不成立。

⇒ **倾向 A**，排期不并入 P4 前置（它不影响翻转的正确性），**建议随 P5 收口批或单列一批**。

## 复现

```
pini run-llvm <夹具路径>        # 例：退出码 0，但 stderr 有 `Pini runtime error: …`
```

逐通道对照（含 `PINI_INTERP_ENGINE=ast` / `=hir` 两条解释器臂）见 P4-0 的探针产物与当日日志；
本表读数取自 `tools/hir-parity-probe.py` 的全量扫（`--out` 指定的 TSV）与一次独立的三臂直跑。

## 未做（本单）

- 不改 `Sources/PiniCLI/main.swift`（`terminationStatus` 原样被丢弃）；
- 不改任何判据的现有槽位（新槽位 `WARN_LLVM_RC_UNPROPAGATED` 由 P4-0 落，**本单只登记本缺陷**）；
- 未测 `compile`（AOT）与 `debug` / `dap` 路径是否同病（它们各自 spawn 别的进程）——
  **未实测不作断言**，实施处置 A 时须一并核；
- 未清点 XCTest 侧是否有以 CLI rc 为证据的用例（测试 Harness 自有 lli helper，预计不受影响，
  但**未实测**）；
- 不 push（宿主仓从未 push）。

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


---

## 补记（2026-09-17，CG 批盘点时第三次实测到，形态相同）

同一形态在本日盘点中**又出现了两次**，且都在探针之外、值得单列：

| 输入 | `pini run-llvm` 打印 | `rc` |
|---|---|---|
| 一个只用字典 `.get` 的程序 | `lli: error: '%t14' defined with type 'ptr' but expected 'i32'` | **0** |
| 一个**模块目录**（`examples/package-demo`） | `Error: The file "package-demo" couldn't be opened.` | ~~**0**~~ **1** ⚠️ **本行原记有误**（`A2` 批订正；原值保留以留痕，理由见本文 §`A2` 批现测复核） |

⇒ ① 前者使探针把一条**真缺陷**判成非阻塞槽 `HARNESS_DEPENDENT`（详见
`docs/issue-hir-dict-get-emitter-invalid-ir-2026-09-17.md`）；
② 后者说明 **`run-llvm` 没有包通道** —— 这直接决定了探针那 27 条 `PACKAGE_MEMBER`
在 `hir⇄llvm` 这条边上**不可能**被覆盖（见 `docs/issue-hir-blocker-queue-2026-09-17.md` §1-A1）。

本单**仍未修**（登记不修），上述两条只是补证。


---

## `A2` 批现测复核（2026-09-17）：复现命令、成立域、以及一处**订正**

> 队列甲组 `A2` 要求「把 `A1` 的成因补进在册工单（`run-llvm` 不接受目录 + `rc=0` 掩盖），
> **只登记不修**」，判据 = 「在册工单多一条实测证据（**含复现命令**）」。
> 本节的实测把上面那句里的**两件事分开了** —— 它们**不是同一个缺陷**，而且**只有一件属于本单**。

### 复现命令（可直接复制）

```sh
export PINI_LLVM_BIN=/opt/homebrew/opt/llvm/bin     # ADR-031 约束 6；否则 lli 找不到

# ① 目录输入：**显式失败**，rc=1
pini run-llvm examples/package-demo ; echo "rc=$?"
#   stderr: Error: The file “package-demo” couldn’t be opened.
#   rc=1

# ② 对照：lli 真跑起来、程序运行时崩 —— **这里才是 rc=0 的假绿**
pini run-llvm Tests/PiniTests/RuntimeBackendTests/testArrayOutOfBoundsBothBackendsError.pini ; echo "rc=$?"
#   stderr: Pini runtime error: array index 99 out of bounds (size 3)
#   rc=0

# 两臂对照（同一夹具，解释器两引擎都如实报 1）
PINI_INTERP_ENGINE=ast pini run Tests/PiniTests/RuntimeBackendTests/testArrayOutOfBoundsBothBackendsError.pini ; echo "rc=$?"   # 1
PINI_INTERP_ENGINE=hir pini run Tests/PiniTests/RuntimeBackendTests/testArrayOutOfBoundsBothBackendsError.pini ; echo "rc=$?"   # 1
```

### 现测读数（2026-09-17，`291a4b3`，两个二进制各三次连跑）

| 输入 | `pini run-llvm` stderr | rc（三次） |
|---|---|:---:|
| `examples/package-demo`（目录） | `Error: The file “package-demo” couldn’t be opened.` | **1 / 1 / 1** |
| `examples/multifile`（目录） | `Error: The file “multifile” couldn’t be opened.` | **1 / 1 / 1** |
| `…/RuntimeBackendTests/testArrayOutOfBoundsBothBackendsError.pini` | `Pini runtime error: array index 99 out of bounds (size 3)` | **0 / 0 / 0** |

两处细节：① 用 **`.build/debug/pini` 与 `/tmp/pini-build/…/pini` 两个二进制**分别跑，
读数逐项相同（⇒ 不是构建差异）；② 每条**连跑三次**，读数稳定（⇒ 不是闪断）。

### ⚠️ 订正：本单「上文」的那条读数，**成立域比它写的窄**

本单前两节（§补记的表格第二行）与台账 §9、阻塞队列 §1.1 都记着
「`pini run-llvm <目录>` → `couldn't be opened.`，**`rc=0`**」。
**现测为 `rc=1`**，且**符号级可达性**也支持现测（见下）⇒ **那三处的 `rc=0` 是错的**，
本批一并订正（见文末「订正清单」）。

**为什么会错**：`rc=0` 这条读数**本身是真的**，但它属于**另一条路径** —— 前两节把它与
「目录被拒」并排写进同一张表，读者会顺理成章地读成「目录输入也静默 rc=0」。
**本批不替那次读错编解释**（是按错读、是抄串行、还是当时确有第三种形态，无从复原）；
本批只做两件事：**给出可复现的现测**，并**把两条路径在代码上分开**。

### 符号级根因：两条路径在**不同位置**

```swift
// Sources/PiniCLI/main.swift:1729 —— 本单认领的这一半
case "run-llvm":
    guard args.count >= 3 else { … exit(1) }
    do {
        let source = try readFile(args[2])          // ← 直接把参数当**文件**读，没有目录分支
        try runLLICommand(source: source, fileName: args[2])   // ← rc=0 的假绿发生在这句**内部**
    } catch {
        printError(formatCLIError(error: error, source: nil))
        exit(1)                                     // ← 读不到 ⇒ 显式失败
    }
```

对照 `case "run"` → `runRunPath`（`main.swift:869` 起）：它有完整的目录分支
（`P4-1a` 交付：`loadManifest` → `loadDirectory` → 按引擎分派），所以
**`pini run <目录>` rc=0 正常出结果，而 `pini run-llvm <目录>` 连解析都没进去**。

⇒ **两条路径的性质相反**：

| 路径 | 触发条件 | 表现 | 性质 | 属本单？ |
|---|---|---|---|:---:|
| `readFile` 失败 | 参数不是可读文件（目录 / 打不开） | 显式报错 + **rc=1** | **显式失败** —— 脚本能看见 | ✗ |
| `runLLICommand` 内部 | 文件读到了、lli 跑起来了、**程序自己崩了** | lli 的 stderr 有真报错，命令却 **rc=0** | **假绿** —— 脚本看不见 | ✓ |

**只有下面那一行是本单的对象**：`rc=0` 假绿的成立域 = **lli 真的执行过之后**
（`waitUntilExit()` 丢弃 `terminationStatus`，见上文「根因（符号级）」）。

### 全量复测：27 条 `PACKAGE_MEMBER` 的 `rc` 真实分布（本单核心证据）

`A1` 说「那 27 条在 `hir⇄llvm` 边上不可能被覆盖」。本节把这句的**实际机制**测出来 ——
对探针排除的 **27 条逐条**跑 `pini run-llvm <成员文件>`（27/27；超时 25s）：

| rc | 条数 | 报文 | 失败发生在哪一层 |
|---|---:|:---:|---|
| **1** | **26** | `E6-004` × 12 · `E4-001` × 12 · `E2-001` × 1 · `E4-010` × 1 | **前端 / 降载层**拒绝 ⇒ Swift 侧 `exit(1)` |
| **0** | **1** | `examples/ffi_module/cstring.pini` → `JIT session error: Symbols not found: [ _ffi_memset, … ]` | **lli 真跑起来了**，符号缺失而失败 ⇒ `terminationStatus` 被丢弃 ⇒ **`rc=0`** |

⇒ 那**一条**（`cstring.pini`）是本单「假绿」在探针排除面上的实例：探针只能把它记成
`PACKAGE_MEMBER`（未测），而它的真实形态是「**独立臂跑起来了**，却静默失败」。

⚠️ **同时订正一处形态**：既有记载写「`pini run-llvm <成员>` 打印**同一错误**，但 `rc=0`」——
**实测不成立**：27 条里 **26 条 `rc=1`**（且报文**并不统一**，共四种错误码），只有 **1 条 `rc=0`**。
⇒ 那条记载把**一条**的读数写成了**通例**，并把两类失败（前端拒绝 vs 运行时失败）混成了一句。
这与上一节的订正是**同一类错误**：**把不同层的现象并排写进一行**。

### 归属：另一半（`run-llvm` 无目录分支）不在本单

「`run-llvm` 不接受目录」是一条**能力缺口**，不是判据缺陷：它以**显式 `rc=1`** 失败，
脚本与 CI 都看得见，**不会造成假绿**。它的真实危害只有一条 ——
探针那 **27 条 `PACKAGE_MEMBER`** 在 `hir⇄llvm` 这条边上**不可能**被覆盖
（`hir⇄llvm` 边喂不进目录）。

⇒ 归 **`docs/issue-hir-package-run-unsupported-2026-09-16.md`**（该单主题正是「包运行入口」，
且它的 §状态更新 已把本项列为三类子缺口之外的相邻项）。**本单不认领、本批不修、不新建单** ——
两条缺陷的载体是**同一个文件、同一个 `case`**，拆成两张单会让「一处代码的两个不足」分家；
本批改为**两边各写清归属**（该单也补了指针，见其 §`A2` 批补记）。

## 订正清单（`A2` 批，`rc=0` → `rc=1`）

| 载体 | 位置 | 改成 |
|---|---|---|
| 本单 | §补记 表格第二行 | 已在本节订正（历史行保留） |
| `docs/hir-criteria-gap-ledger.md` | §9 `PACKAGE_MEMBER` 行的成因 | `rc=1`（显式失败）+ 归属补实 |
| `docs/issue-hir-blocker-queue-2026-09-17.md` | §1.1 第 4 行表格 | `rc=1` |
| `docs/issue-hir-package-run-unsupported-2026-09-16.md` | §`A2` 批补记 | 新增（含复现命令） |

**未做（本批）**：不改 `Sources/PiniCLI/main.swift`（`terminationStatus` 原样丢弃、
`run-llvm` 原样无目录分支）· 不动任何判据槽位 · 不 push。

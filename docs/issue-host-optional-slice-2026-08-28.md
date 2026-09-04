# Issue: Host Optional/Subscript runtime incoherence (P2-E incomplete)

- Date: 2026-08-28
- Status: INTERPRETER-FIXED / LLVM-M2-CLEARED（2026-09-04 批 C2，见文末 M2 出清记录）
- Related: P2-E (spec G48); issue-lexer-gaps-2026-08-28 (P2-E item); self-hosted lexer plan SHELVED pending this fix.

## Context

While prototyping a self-hosted lexer in Pini (`pini/src/lexer/lexer.pini`, differential against
`pini tokens`), we discovered the host's Optional handling for collection subscript is incoherent.
This blocks any Pini code that needs to destructure an Optional subscript result via `match` /
`if let` / `??` as the language design (P2-E, G48) intends.

## Root cause

P2-E typed subscript *reads* as `Optional<T>` in `TypeInference.swift`
(`SubscriptReadStrategy` returns bare values), but `SubscriptStrategies.swift`
`SubscriptReadStrategy` returns:

- in-bounds string subscript → bare `.string(ch)`
- in-bounds array subscript  → bare `.arrayElement(...)`
- out-of-bounds              → `.null`

There is **no `some(...)` / `none()` `Optional` enum wrapper** at runtime. The static type
(`Optional<T>`) and the runtime representation disagree.

## Reproduction (verified by probe)

Given `var s = "abc123"`:

- `s[i]!` / `s[i] ?? x` / `if let ch = s[i]:` → parse or semantic failure (syntax unsupported).
- `match s[i]: case some(ch): ... case none: ...` → neither case matches (no wrapper exists);
  `match s[i]: case _:` matches but cannot extract the value.
- Only `s[i:i+1]` (slice, non-optional) or a bounds-guarded access works.

This is the "slice behavior inference is illogical" symptom: the language declares `Optional<T>`
for subscript but provides no usable way to consume it.

## Expected (fix direction)

1. Subscript read strategies return real `Optional` enum values:
   - in-bounds  → `.enumValue("some", payload: value)`
   - out-of-bounds → `.enumValue("none")`
2. Verify `match s[i]: case some(ch): ... case none: ...` extracts correctly (in-bounds hits
   `some`, OOB hits `none`).
3. Verify unwrap forms `??` / `!` / `if let` — if the parser does not support them yet, that is a
   separate gap; either implement or explicitly document as not-yet-supported.
4. Slice `a[i:j]` return type must be coherent and non-optional (String / Array). Confirm the
   desugar-to-`.slice(...)` path types and runs consistently.

## Acceptance

- `match s[i]: case some(ch): ... case none: ...` works end-to-end. ✅ (verified by `array_basic.pini` / `slice.pini`)
- Self-hosted Pini code can iterate a string by index using `match` (no slice hack required). ✅
- Interpreter-side suite (`ExamplesRunTests` / `CollectionsTests` / `RuntimeBackendTests` 解释器专属用例) stays green. ✅
- Full suite (`swift test --disable-sandbox`) stays green **modulo the M2 LLVM gap below** — the LLVM/IR
  双后端用例已显式 `XCTSkip` 并指向本工单，不计入红。

## 修复范围（本分支已完成）

`Sources/PiniCore/Interpreter/SubscriptStrategies.swift`：三处读策略（array / string / dictionary）越界返回
`Optional.none`、界内返回 `Optional.some(value)`。**严格枚举语义：下标读/写入口一律不做 `some(x)` → `x`
透明解包**——此前的"透明解包后门"已回退（当初为支持 `a[i][j]` 隐式剥壳而加，属权宜且引入读/写二义，
按设计讨论"涟漪1"推翻）。嵌套下标必须显式剥壳 `a[i]![j]!`（后缀 `!` 见下）或经 `match` 取内层后写回：
`var row = unsafe a[i]!; row[j] = v; a[i] = row`。

### 后缀 `!` 强制解包运算符（本分支新增）

多维下标访问对强制解包提出了硬需求。设计要点（设计讨论"涟漪2/3"修正后落地）：

- **两种 `!` 身份消歧**：前缀 `!` = 逻辑取反 `logicalNot`；后缀 `!` = 强制解包 `forceUnwrap`。因 `!=` 已被词法
  归并为 `.notEqual`，故后缀位遇到的 `.logicalNot` token 必为强制解包，无歧义。
- **实现最小侵入**：复用 `.unary(op: .forceUnwrap)` 而非新增 AST 节点，仅触及 5 处编译器逻辑
  （`UnaryExpr` 枚举项 + `Parser.parsePrimarySuffix` 后缀解析 + `TypeInference` 去 Optional 壳 +
  `TypeChecker` 门控/校验 + `Interpreter` 求值）+ LLVM `ExprEmitter` 兜底 no-op（M2 见下）。
- **`unsafe` 上下文门控（与 `&` 对称）**：后缀 `!` 须处于 `unsafe` 上下文
  （`|unsafe` 函数体，或 `unsafe (...)` 零散消耗点，`unsafeContextDepth > 0`）。非 `unsafe` 上下文出现 `!`
  由 `TypeChecker` 拦截并报告"强制解包 `!` 出现在非 unsafe 上下文"。`!` **不强制**整函数 `|unsafe`，可由零散
  `unsafe (...)` 前缀逐点消费。
- **`!` 是只读右值**：不能作 lvalue，`a[i]![j] = v` / `a[i]! += 5` 不成立；嵌套写范式见上 `var row = ...`。
- **求值语义**：操作数须为 `Optional` 枚举值（`some(x)`/`none`）；命中 `some` 取内层、命中 `none` 抛
  "强制解包 `!` 命中 Optional.none（元素不存在）"。
- **示例载体**：`examples/multidim.pini`（新建）演示安全 `match` 路径 + 强制解包路径 + 嵌套写，函数本身为
  安全 `|func`，仅那一处 `!` 由零散 `unsafe` 前缀消费；`examples/array_basic.pini`、`examples/collections.pini`、
  `examples/cow.pini` 的嵌套读/写均已改写为显式 `!` 剥壳。

## M2 gap：LLVM / IR 双后端未对齐（已知、已登记、显式跳过）

**根因**：本分支把解释器下标读改为严格 `some/none`，但 LLVM 后端（`generateSubscriptRead`）与运行时 shim
（`@bk_array_get` / `@bk_dict_get` / 字符串取下标）仍返回裸值 / `.null`，且 LLVM 越界仍走 `bk_panic`（见
P2-C 既有 backlog）。两侧现存在系统性分歧：

1. 下标读：解释器 `some(x)` / `none` ↔ LLVM 裸值 `x` / `null`（打印为 `none` vs `null`）。
2. 复合赋值：解释器 `a[i] += k` 因读到 `some` 而类型错；LLVM 侧语义未定义。
3. 字典缺失键打印：`none`（解释器）vs `null`（LLVM 经补零值）。

**处理（按决策「显式跳过 + 登记」）**：以下双/三后端与 IR 执行用例已加 `XCTSkip`，消息统一指向本工单，
不计入红。M2 阶段完成 LLVM 下标读 `some/none` 包装 + 越界安全通道后，移除对应 skip 即可恢复对齐。

- `RuntimeBackendTests.testArrayViaRuntimeLLI`
- `RuntimeBackendTests.testArrayViaRuntimeClang`
- `RuntimeBackendTests.testStringArrayViaRuntimeLLI`
- `RuntimeBackendTests.testNestedStringArrayViaRuntimeLLI`
- `RuntimeBackendTests.testF64ArrayViaRuntimeLLI`
- `RuntimeBackendTests.testBoolArrayViaRuntimeLLI`
- `RuntimeBackendTests.testArraySubscriptWriteBothBackends`
- `RuntimeBackendTests.testNestedSubscriptWriteBothBackends`（新增：严格枚举下嵌套写须 `!`+`unsafe`，而 LLVM 后端暂不支持 FFI/unsafe 子系统）
- `RuntimeBackendTests.testNestedAliasCOWBothBackends`（新增：同上，双后端嵌套别名 COW 锁步待 M2）
- `RuntimeBackendTests.testDictViaRuntimeLLI`
- `RuntimeBackendTests.testDictSubscriptWriteBothBackends`
- `RuntimeBackendTests.testCompoundAssignAliasCOWBothBackends`
- `RuntimeBackendTests.testBreakCollectionAllThreeBackends`
- `RuntimeBackendTests.testContinueCollectionAllThreeBackends`
- `RuntimeBackendTests.testForInBodyCollectionAllThreeBackends`
- `RuntimeBackendTests.testForInNestedArrayAllThreeBackends`
- `RuntimeBackendTests.testNestedMixedContainerCOWBothBackends`
- `RuntimeBackendTests.testLoopBodyCollectionAllThreeBackends`
- `IRExecutionTests.testD3ContainerPrintBothBackendsMatch`
- `IRPrintGoldenTests.testAggregatePrintMatchesInterpreter`

解释器专属用例（无 LLVM 依赖）已就地改写为严格枚举 + 显式 `!` 剥壳：
- `RuntimeBackendTests.testArraySubscriptWriteInterpreter`：`a[1] += 5` 改 `match a[1]: case some(v): a[1] = v + 5`；
  嵌套读 `m[0][1]` 改 `print(unsafe m[0]![1]!)`（取裸值 `99`），预期输出同步为
  `some(10)/some(25)/some(3)/99/some(z)/some(false)`。
- 前述 `testNestedSubscriptWriteBothBackends` / `testNestedAliasCOWBothBackends` 因含 `!`+`unsafe` 嵌套写且 LLVM
  端不支持 FFI/unsafe 子系统，按决策标 M2 跳过（见上方清单），不计入红。

## M2 出清记录（2026-09-04 批 C2，实测核验）

**本节所记分歧已被语义演进消解，20 个 M2 XCTSkip 全部移除**：

1. 本仓下标语义后演进为**双通道**：`xs[i]` 下标语法 = 裸值 + 越界抛错（解释器 E5-005 / shim
   `bk_panic`，**双后端天然对齐**）；`some/none` 严格枚举语义实挂于 `get(i)` 方法通道。
   本节原拟的「下标读 some/none 分歧」前提不再成立。
2. 实证：移除 skip 后 clang 通道（同 IR + 同 shim，本机唯一可执行通道）`testArrayViaRuntimeClang`
   **真绿**；其余测试落到环境门（lli/clang 可用性，与 E-076 同惯例——本机与 CI 均无 lli）。
3. **勘测副产品（新立案）**：LLVM 端 `get`/`unchecked` 内建方法零实现——
   见 `docs/issue-llvm-get-unchecked-2026-09-04.md`（含 `Optional` IR ABI 已在位的有利条件与验收口径）。
4. 嵌套容器 + `!` 剥壳 + `unsafe` 子系统相关测试（`testNestedSubscriptWriteBothBackends` /
   `testNestedAliasCOWBothBackends` 等）依赖 LLVM 端 FFI/unsafe 能力，属后续独立能力项，不再挂本工单。

## Secondary item (lower priority)

- `and` / `or` / `not` appear in `token.pini` `[keyword]` (`kw_and` / `kw_or` / `kw_not`) but the
  host lexer emits them as `identifier`. Confirm whether they should be `keyword` per spec; if so,
  register them. (Note: word-form operators like `neq` / `band` are NOT Pini syntax — earlier
  "identifier" observation for those was a synthetic-corpus artifact and is retracted.)

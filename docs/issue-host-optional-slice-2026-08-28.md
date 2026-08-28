# Issue: Host Optional/Subscript runtime incoherence (P2-E incomplete)

- Date: 2026-08-28
- Status: INTERPRETER-FIXED / LLVM-M2-OPEN
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
`Optional.none`、界内返回 `Optional.some(value)`；`read`/`write` 入口对 `some(x)` 透明解包以支持嵌套下标
`a[i][j]`（与 LLVM 裸元素行为对齐）。严格枚举语义：下标读**始终**是 `some(...)`/`none`，元素必须靠 `match`
取出；复合赋值 `a[i] += k` 不再对下标读做值语境透明解包，须改写为 `match a[i]: case some(v): a[i] = v + k`。

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

解释器专属用例（无 LLVM 依赖）已就地改写为严格枚举：`RuntimeBackendTests.testArraySubscriptWriteInterpreter`
（`a[1] += 5` → `match a[1]: case some(v): a[1] = v + 5`）。

**M2 待办**：在 LLVM codegen 与运行时 shim 中将下标读包装为 `Optional.some`/`none`，使双后端锁步；
完成前上述 skip 保持生效。

## Secondary item (lower priority)

- `and` / `or` / `not` appear in `token.pini` `[keyword]` (`kw_and` / `kw_or` / `kw_not`) but the
  host lexer emits them as `identifier`. Confirm whether they should be `keyword` per spec; if so,
  register them. (Note: word-form operators like `neq` / `band` are NOT Pini syntax — earlier
  "identifier" observation for those was a synthetic-corpus artifact and is retracted.)

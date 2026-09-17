# `argv` / `moduleRoot` 在 LLVM 通道无运行时段（且 `emit` 静默产出不可用 IR）

> 状态：**Open**（2026-09-16 立案；**只登记不修**）
> 发现于：P4-1b（`argv` / `moduleRoot` 降载层）实现之后 —— 该批只落了 **HIR 执行器侧**。
> 关联：`docs/issue-hir-p4-plan-2026-09-16.md` 的 `P4-1b` 行；交付记录见 `docs/spec/issue/archive/issue-hir-p4-1-plan-2026-09-16.md`。

## 1. 现象（实测，2026-09-16，`P4-1b` 交付后）

夹具：单文件 `main|func() -> (): print(argv()) return`。

| 命令 | 结果 |
|---|---|
| `pini run <file> <args>`（默认 `ast`） | rc=0，正常输出参数 |
| `PINI_INTERP_ENGINE=hir pini run <file> <args>` | rc=0，**与上一行逐项相同**（本批交付） |
| `pini emit <file>` | **rc=0**（看起来成功），但产出的 IR 里有 `%t1 = call %bk_array* @argv()` —— **引用一个从未定义/声明的符号** |
| `pini run-llvm <file>` | 失败：`lli: error: use of undefined value '@argv'` |

⇒ **两条独立缺陷**：

1. **能力缺口**：LLVM 侧没有 `argv` / `moduleRoot` 的运行时段（HIR 执行器侧已实现）。
2. ⚠️ **静默错误**：`emit` **返回成功**却产出**通不过 IR 验证**的输出 —— 错误被推迟到 `run-llvm`
   才以 lli 的措辞暴露。`moduleRoot` 同型。

## 2. 根因（符号级）

- `HIRLowerer` 把两项零参内建降成**既有的 `call` 形状**（`call(function: "argv", arguments: [])`）。
  这是**有意的**：与 `print` 同法，不为内建新增契约节点。
- **HIR 执行器**（`Sources/PiniCore/Interpreter/HIRExecutor.swift`）在 `.call` 分支里按名回答，
  两行与解释器同名内建**逐字同义**；参数来自执行器持有的 `processArguments`。
- **`IREmitter` 侧没有对应实现**：它按 `@<mangled function>` 直接发调用 ⇒ 得到一个未定义的符号。
  本批**刻意未改 `IREmitter`** —— 该文件用 `fatalError` 表达「lowerer 保证不会发生」，
  而这里是**合法输入 + 未实现**，加 `fatalError` 会让 CLI 崩溃、比现状更糟。

## 3. 影响面

- 任何使用 `argv()` / `moduleRoot()` 的程序在 **LLVM 通道**（`emit` / `compile` / `run-llvm`）不可用。
- **探针无判据覆盖**：319 个夹具里没有用 `argv` 的 ⇒ 该缺口在等价探针上**结构性不可见**
  （与「包运行路径无探针覆盖」同族）。
- 对 LR-4 的位置：**不是 P4 翻转的前置**（翻转切的是默认解释器引擎，LLVM 通道不在翻转对象内），
  但翻转后 `argv` 在**解释器侧**已可用，故用户可见能力无回退。

## 4. 实现路径（**未裁**；未决策前不动源码）

- **路径 A（倾向）· 运行时段原生取参**：在 LLVM 侧新增取值面（例如把 `argc`/`argv` 从
  `main` 的入口参数传进来，或新增 `bk_argc` / `bk_argv_at` 两个 `@_cdecl` 符号），
  `IREmitter` 对两个内建发对应调用。代价：触及 `bk_*` 权威清单与契约的运行时段登记。
- **路径 B · 只为 `emit` 加门**：让 `IREmitter` 在遇到两项时**明确报错**（需要非致命错误通道 ——
  该文件当前没有），把「静默产出坏 IR」先堵掉，能力仍缺。代价：需先给发射器引入错误通道。

**建议顺序**：先做 B 的**最小形态**（把静默变显式）或直接做 A；两者都属独立批。

## 5. 不做范围

- 本单**只登记**；未决策前不改 `Sources/`。
- 不改契约计数（两项内建复用既有 `call` 形状，不新增节点）。
- 不背进 `P4-1` 的收口（该批的验收判据 = HIR 执行器侧，已达成）。

---

## 8. 同类现象：`G-2a` 补齐的五个字符内建（2026-09-16）

**同一形态在另一批上重现**，因此并入本单而不是另立（对象相同：**降载层已接受、LLVM 侧无运行时段**）。

夹具：`Tests/PiniTests/CodeGen/IRExecutionTests/testIsLetterUnsupportedViaIRGen.pini`

| 命令 | 结果 |
|---|---|
| `pini emit <file>` | **rc=0**（看起来成功），IR 里出现对 `is_letter` 的调用 —— **未定义符号** |
| 探针 | 该夹具由 `FRONTEND_FAIL` 变为 **`HARNESS_DEPENDENT`**（1 个）；`FLIP BLOCKERS` 仍 **0** |

⭐ **这不是 `G-2a` 的疏漏，而是 `G-2` 的固有代价，必须记账**：
`G-2` 的每一个子批都在做「让降载层接受某个特性」，而那些特性**在 LLVM 侧大多没有运行时段**。
⇒ 每补齐一个子批，就会多出一批「`emit` 静默产出不可用 IR」的符号。
⇒ **待裁**：LLVM 侧的运行时段是**并入 `G-2` 逐子批同步**，还是**单立一批**在 `G-2` 之后统一补。
（本单**只登记不修**，这个裁量留给 `G-2` 的执行计划。）

**本单的对象因此扩为**：`argv` · `moduleRoot` · `chars` · `chr` · `ord` · `is_letter` · `is_number`
（后续 `G-2` 子批补齐的每个内建，按同一口径追加到本列表，不新开单）。

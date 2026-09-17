# Issue：`G-6` 删 `Interpreter` 前必须先处置的**残余引用面**（含规划件过期读数的实测订正）

> **日期**：2026-09-18｜**状态**：**Open**（只登记不修）
> **发现于**：格 `G-5`（D 类参照臂改造）的开工前引用面普查
> **性质**：**三种形态并存** —— ① 规划件的一处读数**已过期**（抽取其实已完成）；
> ② 一条**从未登记**的用户可见能力断点（`pini dbg` 无 HIR 分支）；③ 一处测试侧**无主**静态入口。
> **归属**：**`G-6` 前置**（用户 2026-09-18 裁决：立工单并并入前置）。

## 0. 一句话

`G-6` 是不可逆的「删 4143 行」批。本篇给出**删之前必须先处置的最小引用面**，
并且**订正**规划件里一个会误导后续批次的读数：规划记「静态成员被保留面使用 ~30 处」，
**去注释实测为 0 处代码引用** —— 摘要抽取（`P4-0` / `P4-1b`）**已经完成**。

## 1. 实测：真引用面（去注释扫描，2026-09-18）

判据装置：把 `.swift` 逐字符剥掉 `//` · `/* */` · 字符串字面量，再检索 `\bInterpreter\b`。
**必须去注释** —— 本仓大量 docstring 在**叙述** `Interpreter.matchArmMatches` 这类语义出处，
按原文 grep 会把这些叙述算成引用（本单的两个错误结论都出在这个坑上，见 §3）。

| 面 | 规划件（`4b154fa` 时点） | **本次实测** | Δ |
|---|---|---|---|
| `Sources` 侧 `Interpreter.<静态成员>` **代码**引用 | 39 处 | **0 处** | ⚠️ **表格已过期** |
| `Sources` 侧 `Interpreter(...)` **构造点** | 4 处 | **6 处** | ⚠️ 漏记 2 处（见 §2.1） |
| `Tests` 侧 `Interpreter(...)` 构造点 | 16 文件，未细分 | 见 `G-5` 载体 | —— |
| `Tests` 侧 `Interpreter.<静态成员>` 代码引用 | 未登记 | **5 处 / 2 文件**（其中 2 处随退役文件消亡） | ⚠️ **无主** |

## 2. 必须处置的三组

### 2.1 `Sources` 侧 6 处构造点（**规划只记了 2 处**）

| 位置 | 所在函数 | 形态 | `G-6` 后的处置 |
|---|---|---|---|
| `Sources/PiniCLI/main.swift:906` | `runRunPath` | 单文件 run 的 **AST 回落**（`if engine == .hir { … return }` 之后） | 收开关时一并删 |
| `Sources/PiniCLI/main.swift:965` | `runRunPath` | 包 run 的 **AST 回落** | 同上 |
| `Sources/PiniCLI/main.swift:1047` | **`runDebugFile`** | **无回落分支，恒 AST** | ⛔ **见 §2.2** |
| `Sources/PiniCLI/main.swift:1066` | **`runDebugDirectory`** | **无回落分支，恒 AST** | ⛔ **见 §2.2** |
| `Sources/PiniCore/REPL/ReplEvaluator.swift:104` | REPL `.ast` 分支 | 收开关时删 | 已登记（`P4-β` 迁移件的「三份同构」项） |
| `Sources/PiniCore/Debugger/DAPServer.swift:191` | `makeRun` 未注入时的默认路径 | `let ast = Interpreter()` | 已登记（`G-6` 行「`DAPServer` 默认路径改指」） |

### 2.2 ⛔ 新增且无主：`pini dbg` 的 CLI 入口**恒走 AST**（用户可见能力断点）

```swift
// Sources/PiniCLI/main.swift:1040
private func runDebugFile(_ path: String) {
    …
    let engine = Interpreter(programBase: absoluteProgramBase(path))   // ← 无 HIR 分支
    startDebugger(run: DebugRun(host: engine) { try engine.run(module: module) }, …)
}
// :1055 同理 —— runDebugDirectory 也是裸 Interpreter
```

**性质**：这不是「参照臂」也不是「回落」，而是**唯一实现**。
`DAPServer.swift:191` 的默认路径与它是同一件事的两面 —— DAP 侧**可以**由调用方注入 `makeRun`
（`DebuggerTests` 正是注入 `dbgMakeRunHIR`），而 **CLI 侧从不注入**。

⇒ **`G-6` 直接删除 `Interpreter` 会让 `pini dbg <file>` 与 `pini dbg <dir>` 整体消失**，
而 `G-6` 的判据 3 只写了「第四项（调试/DAP/REPL）**须先完成参照臂改造**才可读」——
**参照臂改造（`G-5`）不包含这两处**：它们没有第二臂可换，只有一条臂要**新建**。

**处置候选**（不预设）：

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** | 把两条入口改指 `HIRExecutor`（照 `DebuggerTests.dbgMakeRunHIR` 的形状：`check → lower → execute`） | 中：须实测 `pini dbg` 的暂停点/断点行为在 HIR 侧等价（`DebuggerTests` 已有 12 条参数化用例覆盖同一面，可复用为判据） |
| **B** | 先在 `G-6` 前的某个批里补 HIR 分支并**保留** AST 分支（双引擎并存，随 `G-6` 收成一臂） | 中：多一个中间态 |
| **C** | 显式退役 CLI 调试能力，`pini dbg` 报「暂不可用」 | 小，但**用户可见能力净减** ⇒ 须走 `spec §1.3` 登记 |

### 2.3 `Tests` 侧静态入口（**无主**）

| 位置 | 引用 | 处置 |
|---|---|---|
| `Tests/PiniTests/StructuredConcurrencyTests/StructuredConcurrencyTests.swift:199-200` | `Interpreter.makeResult` ×2 · `Interpreter.makeError` ×1 | 改指 `RuntimeOps.*`（**行为中性**：两侧都已是 `RuntimeOps` 的薄转调） |
| `Tests/PiniTests/SuspendRuntimeTests/SuspendRuntimeTests.swift:192,227` | `Interpreter.isCancelErrorValue` ×2 | **条件项**：`G-3e` 退役单的 `SuspendRuntimeTests` 节记该类 11 条**全部**退役 ⇒ 取处置 A（移入退役登记处）则随文件消亡；取处置 B（原地保留只读规格）则须一并改名 |

## 3. 本单的两个错误结论（如实登记，因为它们是同一坑的两次）

普查过程中我先得到两个**后来被推翻**的结论，都是「把注释当引用」：

1. 首扫（按原文 grep）得「`Sources` 侧静态成员引用 40+ 处」，与规划件的 39 处吻合
   ⇒ 一度以为**规划件是对的**。去注释后为 **0**。
2. 中间结论「`FFIModuleTests.runProgram` 是死代码」（`G-5` 复核轮记入的）
   ⇒ 实测它在 `:181` 被 `testUndefinedForeignSymbolRejected` 调用，**不是**死代码。
   （该订正已进 `G-5` 载体，此处只作交叉引用。）

⇒ **纪律**：凡「某标识符被引用 N 处」类读数，**必须去注释**；本仓的 docstring 会大段复述
其他文件的语义出处，按原文 grep 的读数**系统性偏高**。

## 4. 判据（怎么算完成）

| # | 判据 | 测法 |
|:--:|---|---|
| 1 | 三组引用面**逐处**有主 | §2.1/§2.2/§2.3 每一行都有「谁在哪一步做掉」 |
| 2 | `pini dbg` 能力**不净减** | 两条入口在 `G-6` 后仍可用（取 §2.2 的 A/B），或按 C 走完 `spec §1.3` 登记 |
| 3 | 规划件读数**已订正** | `issue-hir-p4-gamma-plan-2026-09-16.md` 的「事实基础」与「复现方式」两处的「39 处」旁有订正标注与指针 |
| 4 | 编译面**零残留** | `G-6` 删除后 `swift build` 无 `cannot find 'Interpreter' in scope` |

## 5. 不做范围

- **只登记不修**：本单不改任何源码、不改测试、不改规范。开工须单独点名。
- **不顺手做 §2.3 的改名** —— 它属 `G-6` 前置，与 `G-5` 的换腿不是同一件事
  （换腿改的是**测试怎么驱动引擎**，改名改的是**静态工具函数的挂载点**）。
- **不把 §2.2 直接按 A 做掉** —— 它需要在 HIR 侧验证 `pini dbg` 的暂停面，属独立一格。

## 6. 复现方式

```bash
# 去注释后的真引用面（本单的核心读数）
python3 - <<'PY'
import re, pathlib
def strip(text):
    out=[];i=0;n=len(text)
    while i<n:
        if text.startswith("//",i):
            j=text.find("\n",i); i=n if j<0 else j; continue
        if text.startswith("/*",i):
            j=text.find("*/",i+2); i=n if j<0 else j+2; continue
        if text[i]=='"':
            j=i+1
            while j<n:
                if text[j]=='\\': j+=2; continue
                if text[j]=='"': break
                j+=1
            i=j+1; out.append('""'); continue
        out.append(text[i]); i+=1
    return "".join(out)
for p in sorted(pathlib.Path("Sources").rglob("*.swift")):
    if p.name in ("Interpreter.swift","SuspendEvaluator.swift"): continue
    for i,l in enumerate(strip(p.read_text(errors="replace")).splitlines(),1):
        if re.search(r'\bInterpreter\b', l): print(f"{p}:{i}: {l.strip()}")
PY

# `pini dbg` 无 HIR 分支（§2.2）
grep -n 'if engine == .hir' Sources/PiniCLI/main.swift     # 只在 runRunPath 里，debug 两入口没有
```

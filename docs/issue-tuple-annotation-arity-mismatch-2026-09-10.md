# Issue：元组类型注解的标签数与分量数不一致（推断静默跳过 + 三处空标签生产点）

- 状态：**Open（2026-09-10 立案；非 M6a 阻塞项。**2026-09-13 工单整理批订正**：原写「源码未改」已失真 —— P2a 第 2 格 G2 已改 `Sources/PiniCore/Type/TypeInference.swift` 两处（调用推断分支 `:180` 与方法返回推断分支 `:334`，`.tuple(labels: [], elements: sig.returns, ...)` → `.tuple(labels: sig.returnLabels, elements: sig.returns, ...)`），本单「不变量与实测差异」表中**仍有三处空标签生产点**：高阶被调者分支 `:191`、元组字面量分支的静默跳过、以及 `Sources/PiniCore/Type/TypeChecker.swift` payload 形状处）**
- 发现来源：LLVM 重写 M6a G16 格勘测（`.0` / 解构 / 多槽返回语料差分 fixture
  编写时踩中；先表现为 HIR 降载的 `requireAssignable` 类型不匹配）
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（M6a 准备批 D7）；
  同族工单 `docs/spec/issue/archive/issue-hir-cli-diagnostic-loss-2026-09-08.md`
  （HIR 侧诊断面，已关闭归档）

## 不变量与实测差异

`Sources/PiniCore/AST/Types/Type.swift` 对 `.tuple(labels:elements:location:)`
写明：**`labels[i]` 对应 `elements[i]` 的可选标签**（nil = 位置元素）。

实测：三个生产点写出的注解**违反该配对关系**。

| 生产点 | 产出 | labels 数 vs 分量数 |
|---|---|---|
| `Sources/PiniCore/Type/TypeInference.swift` 调用推断分支（多返回值调用） | `tuple(labels: [], elements: sig.returns)` | 0 vs N |
| 同上（高阶函数被调者分支） | `tuple(labels: [], elements: returns)` | 0 vs N |
| 同上（方法返回推断分支） | `tuple(labels: [], elements: sig.returns)` | 0 vs N |
| `Sources/PiniCore/Type/TypeChecker.swift`（payload 形状） | `tuple(labels: [], elements: f.returnTypes)` | 0 vs N |
| `Sources/PiniCore/Type/TypeInference.swift` 元组字面量分支 | `tuple(labels: <AST 标签>, elements: elemTypes)` | 可能不等（见下） |

## 复现（实测，2026-09-10）

### 1. 元组字面量分支静默跳过推断失败的分量

该分支逐个推断元素，**仅当推断成功时才 append**：

```
case .tuple(let labels, let elements, let loc):
    var elemTypes: [TypeAnnotation] = []
    for elem in elements {
        if let t = infer(expression: elem) { elemTypes.append(t) }
    }
    return .tuple(labels: labels, elements: elemTypes, location: loc)
```

推断失败的元素被丢弃，`elemTypes` 变短而 `labels` 保持原长（不匹配），
且返回**非 nil**——调用方无法区分「完整推断」与「部分推断」。

实测（`var a = 10` / `var b = 20` / `var p = (a, b)` 语料）：

| 通道 | 结果 |
|---|---|
| 差分 Harness（checker 先行 + 作用域表持久） | ✅ 通过 |
| CLI `emit` 单文件（checker 先行，但 HIR 分支此前未开持久表） | ❌ `type mismatch: tuple(labels: [nil,nil], fieldTypes: [i32,i32]) is not tuple(labels: [nil,nil], fieldTypes: [])` |
| **HIR 执行器一致性 Harness（`HIRExecutorTests.runBothChannels`，2026-09-13 补测）** | ❌ **同一条错误**——本条即本表第二列的最后一处漏网点 |

第二列的根因是该分支丢弃了分量类型，下游得到 `fieldTypes: []`。
（CLI 通道自身的作用域表缺行已在 M6a a2 单独修正，与本工单的两件事独立。）

**2026-09-13 补记（LR-4 P2a G2）**：`persistAcrossScopesForCodegen` 的漏网范围比本单原记更宽——
会 `HIRLowerer.lower` 的器械共 5 处（`HIRDifferentialTests.runNewPipeline` ×2 调用点、
`IRExecutionTests`、`IRPrintGoldenTests`、`RuntimeBackendTests`）与生产路径 3 处
（CLI 的 `run`（HIR 引擎）/ `emit` / `compile` / `run-llvm`）**都已设置**，唯独
`HIRExecutorTests.runBothChannels` 未设；该器械的 ast↔hir 白名单因此在扩充到 17 项元组夹具时
暴露本单第 1 条（`testDiffTupleConstruct` / `...Clang` 无法降载）。已就地补上该 flag
（补后 13 用例全绿、白名单 18 项全跑通）。⇒ 本单第 1 条的**触发面**修正为「任何未设该 flag
的降载入口」，而非仅 CLI 早年那处；该 flag 是事实上的降载前置约定，新增降载入口必须带上。

### 2. 空标签列表的消费歧义

HIR 侧 `HIRType` 的元组分支要求 `labels` 与 `fieldTypes` **按下标配对**，
消费上述注解时会拿到 0 个标签对 N 个分量。当前规避方式是在 HIR 边界
把空标签列表展开为全 nil（`HIRLowerer` 的 `HIRType.init?(from:)` 元组分支，
已随 M6a a2 落地并就地注明）。

即：**实现层已归一化，但注解层仍产出违反自身不变量的值**——任何新增的
按对索引 labels 的消费者都会重新踩中。

## 影响

- 静默跳过使「部分推断成功」伪装成「推断完成」，错误面被推到下游
  （表现为看似无关的类型不匹配），诊断指向偏离根因。
- 空标签与「全部位置元素」在实现层被当作同义，但该等价关系**未在
  `Type.swift` 写明**；`labels: []` 现为事实上的重载记号（空元组 / 未命名元素表）。
- 当前无已知错误编译产物：两处后果都是 fail-loud（降载期报错），非静默错码。

## 建议处置（未决，待排期）

1. 元组字面量分支：任一元素推断失败即返回 nil（fail-loud），或补齐
   `labels`/`elements` 长度后再返回。
2. `labels: []` 的语义二选一并在 `Type.swift` 写明：(a) 明确定义为
   「全部位置元素」的简写（则消费点统一归一化）；(b) 禁止非空分量配空标签，
   三个生产点改写真标签。
3. 归属需先判定：语言级（注解语义 → spec §1.3 治理）还是宿主级
   （仅实现收敛 → 本仓修复）。**未判定前不动源码。**

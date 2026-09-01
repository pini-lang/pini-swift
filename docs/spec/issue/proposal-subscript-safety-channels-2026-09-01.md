# 提案：集合下标三通道安全模型（2026-09-01，用户新需求）

- 状态：**已记录，待裁决**（用户 2026-09-01 提出；「先记下」——本文为登记产出，不含实现承诺）
- 提出方：用户
- 优先级占位：**批 2 候选**（与既有的「批 2 = F5 块文法钉定」**批号冲突**，须用户裁定，见 §4 D-1）
- 关联：spec §2.4.1 **G48**（现行下标安全模型）、`issue-lexer-gaps-2026-08-28` **P2-E / P2-F**、`docs/issue-host-optional-slice-2026-08-28`（Optional/下标运行时不一致修复）、ADR-020 D6（`unsafe <expr>` 消耗点）、ADR-015（`|unsafe` 仅限自由函数）

---

## 1. 需求原文（用户 2026-09-01）

```pini
let 元素 = 数组[5]                     ; 安全，越界 panic
let 元素 = 数组.get(5)                 ; 安全，越界返回 .none
let 元素 = unsafe 数组.getUnchecked(5) ; 不安全，越界 UB
```

三通道分工：

| 通道 | 形态 | 越界行为 | 返回值类型 |
|---|---|---|---|
| 下标（安全） | `数组[i]` | **panic**（运行时错误终止） | `T`（不必解包） |
| 显式取（安全） | `数组.get(i)` | 返回 `.none` | `Optional<T>`（调用者解包） |
| 显式取（不安全） | `unsafe 数组.getUnchecked(i)` | **UB**（调用者承担前置条件证明义务） | `T` |

设计取向：下标是「我断言界内」的常用写法 → 直接给 `T`，断言失败即 panic；需要容错时显式 `.get`；性能敏感且已证明界内时走 `unsafe .getUnchecked`。与 Rust（`[]` panic / `get` Option / `get_unchecked` unsafe）同构。

## 2. 现状取证（2026-09-01 实测）

| 项 | 现状 | 证据 |
|---|---|---|
| 下标读越界 | **返回 `Optional.none`（nil）**，不是 panic | `Interpreter/SubscriptStrategies.swift:36,51,124`：「安全通道越界返回 Optional.none」「读通道越界返回 nil（P2-C），读写不对称是有意设计」 |
| 下标读类型 | 类型层推断为 `Optional<T>`（P2-E） | `TypeInference`；`docs/issue-host-optional-slice-2026-08-28.md:16` |
| `.get(i)` 成员方法 | **不存在** | `grep '"get"' Sources/PiniCore/` 零命中 |
| `.getUnchecked(i)` | **不存在** | 全仓零命中 |
| `unsafe <expr>` 消耗点 | **已存在且在用**（无需新增语法面） | ADR-020 D6 / ADR-015；`examples/array_basic.pini:23` `print(unsafe m[0]![1]!)`、`examples/collections.pini:18` |
| P2-F（unsafe 单元素直接访问） | **搁置至 roadmap backlog**，原设想为「底层内建特征默认为集合派发不安全访问」 | `issue-lexer-gaps-2026-08-28.md:43,70` |
| 规范现行表述 | G48 越界（读）返回可空 `nil`，「与字典缺失键一致」，调用者显式解包 | spec §2.4.1 行 346 |
| 语料规模（粗估，待精测） | 26 个文件命中下标形态（含 examples 与测试夹具；grep 为宽松模式，迁移面须逐条实测） | 实测命令见 §5 |

## 3. 冲突与影响面（本需求是**破坏性变更**）

1. **G48 读通道语义翻转（破坏性）**：`a[i]` 由「越界 → `.none`」改为「越界 → panic」，返回类型由 `Optional<T>` 变为 `T`。这是 v0.49.0 落地并转正的语义（CHANGELOG v0.49.0「下标读严格 Optional some/none（P2-E）」），**须走 spec §1.3 变更治理**。
2. **解包语法连带**：现行语料大量 `unsafe m[0]![1]!` 依赖「下标返回 Optional + `!` 强制解包」。下标改返回 `T` 后，这批写法**同时失去 `!` 与 `unsafe` 的必要性**，且 `unsafe` 消耗点会变成「消耗了不存在的 unsafe 操作」——须一并裁量（是报警、降级为无害、还是报错）。
3. **读写不对称原则被改写**：现行「读返回 nil、写越界报错」的不对称设计（issue-lexer-gaps P2-C 论证）被本需求改成「读 panic、写报错」的对称形态——P2-C 的论证文本须同步修订，不能只改实现。
4. **P2-F 从 backlog 复活**：本需求的第三通道正是 P2-F 的目标（unsafe 单元素直接访问），且形态由「特征默认派发」改为「显式成员方法 + `unsafe` 消耗点」——ADR-020 D6 的「`|unsafe` 不扩展到特征方法派发」约束因此**未被触碰**（新方法不是 `|unsafe` 方法，而是调用点 `unsafe <expr>`）。
5. **双后端**：解释器与 LLVM 两条路径都要实现 panic 与 UB 通道（`SubscriptStrategies` + IR 生成）；LLVM 侧 UB 语义须明确落点（无边界检查的 IR，还是带 `assume`）。
6. **Optional 耦合**：`.get` 返回 `Optional<T>` 依赖 P2-E 的可空类型支持（已部分支持）；`.some/.none` 枚举形态与严格解包语义（`!`）须与 `docs/issue-host-optional-slice-2026-08-28` 的既有修复保持一致。
7. **自举探针**：自举 lexer 用字符串当数组（O(n²) 累积），若引入 `.get` 需确认自举侧不需要同步（lexer 阶段无下标需求 → 预期零同步，实施时实测确认）。

## 4. 待裁决点

| # | 问题 | 备注 |
|---|---|---|
| **D-1** | **批号归属**：本需求是「批 2」并取代 F5 的位置，还是排在 F5 之后成「批 3」？ | 既有排期：批 1.5（已 LANDED）→ **批 2 = F5 块文法钉定**（spec §2.2 已留指针）→ 批 3（清单与工具）→ 批 4（远程）。用户原文「做批 2」与既有 F5 批 2 冲突 |
| **D-2** | 下标 panic 的**错误载体**：RuntimeError（解释器）/ trap（LLVM）还是语言级 `panic` 构造？ | 决定是否需要新增语言级 panic 语义与错误码 |
| **D-3** | `.get` / `.getUnchecked` 的**归属**：成员方法（内建特征，ADR-020 登记）还是语法糖（脱糖为既有内建）？ | 影响 BuiltinRegistry 登记与两处同步成本 |
| **D-4** | `unsafe` 消耗点在**无 unsafe 操作**时（如 `unsafe 数组[5]`）的行为：报错 / 报警 / 无害？ | 现行语料 `unsafe m[0]![1]!` 迁移面依赖此裁决 |
| **D-5** | 字典/字符串是否同步三通道？ | 现行「字典缺失键返回 nil」与下标 OOB 一致；本需求若只改集合，`a[i]` 与 `d[k]` 语义将分叉 |
| **D-6** | LLVM 端第三通道怎么办？（取证后新增） | LLVM 对 `unsafe`/`&` 已显式 unsupported（ADR-015 FFI Phase 2a D1，解释器优先）。沿用 unsupported 错误 = 最小改动；另行实现 = 违背既有 D1 决策 |
| **D-7** | 迁移策略：一次性全改（窗口期内）还是分两批（先翻转下标 panic、后补 `.get`/`getUnchecked`）？ | 批 1 先例是一次性；本批 218 处高密度改写，一次性风险更高但避免中间态 |

## 5. 前置取证实测结果（2026-09-01 22:57-23:05）

### 5.1 语料迁移面（精测）

| 类别 | 计数 | 说明 |
|---|---|---|
| 下标用法总量 | **395 处 / 75 文件** | examples + Tests + 自举语料（宽松匹配，含写通道与字面量容器内误命中） |
| **精确 `]!` 解包** | **218 处 / 13 文件** | **强制迁移面**：下标返回 `T` 后 `!` 失去对象（D-4 判为报错） |
| 切片 `a[i:j]` 等 | 17 处 | 不受影响（切片语义不变） |
| 直接编码 nil 语义的测试夹具 | **5 个** | `testArraySubscriptOutOfRangeReturnsNull`、`testDictionarySubscriptMissingKeyReturnsNull`、`testNegativeIndexBeyondBoundsReturnsNull`、`testStringSubscriptOutOfRangeReturnsNull`、`testArrayLastPopOnEmptyReturnsNull`（后两者语义另有出处，须逐个判定） |

`]!` 高度集中（13 文件承载 218 处），迁移是「少量文件高密度改写」，与批 1「5 文件低密度」不同，须工具化 sed + 逐文件人工复核。

### 5.2 类型层落点

`Sources/PiniCore/Type/TypeInference.swift:230-245`：下标读按容器类型返回 `Optional<元素>`（Array/Dictionary/String 三种），P2-E 注释明确「安全通道下标返回可空 T?（越界/缺键 → nil，与运行时 .null 对齐）」。**本需求要把它改为返回元素类型 `T`**；同时 `TypeInference.swift:56-57`（后缀 `!` 的类型 = Optional 内部类型）成为 D-4 报错的判定点。

### 5.3 后端现状：**两后端当下就不一致（关键发现）**

| 后端 | 越界读行为 | 证据 |
|---|---|---|
| 解释器 | 返回 **`Optional.none`**（实测输出 `none`） | `SubscriptStrategies.swift:36,51,124`；实测 `pini run` 输出 `none` |
| LLVM | **`bk_panic` 终止**（"array index N out of bounds"） | `Sources/PiniRuntime/PiniRuntime.swift:240,244`；下标读经 `@bk_array_get`（`ExprEmitter.swift:161`） |

即：**本需求的第一通道（下标 panic）正是 LLVM 后端早已实现的行为**，解释器向它收敛 —— 本批在运行时层面是「消除既有的双后端不一致」，其登记出处即 `docs/issue-host-optional-slice-2026-08-28`（「Optional/下标运行时 incoherence，P2-E incomplete」）。破坏性集中在**类型层（Optional<T> → T）与语料层（218 处 `]!`）**，而非运行时行为凭空转向。

（本环境未安装 `lli`/clang，LLVM 端行为以源码为准，未经实跑；Phase E 须在有 LLVM 工具链的环境复核。）

### 5.4 LLVM 侧 `unsafe` 约束（新增决策 D-6）

`ExprEmitter.swift:123-127`：**LLVM 后端对 `unsafe` / `&` 表达式显式 unsupported**（ADR-015 FFI Phase 2a，用户决策 D1：解释器优先）。故第三通道 `unsafe .getUnchecked(i)` 在 LLVM 端无法落地，只能沿用「unsupported」错误或另行实现。

---

## 记录说明

本文档**只做登记**（用户「先记下」指令），不含实现承诺。开工前须：①D-1 批号裁定；②D-2~D-5 裁决；③§5 前置取证完成。

# ADR-020: 内建特征化（`collection` 特征与内建归组）

## Status

Accepted（2026-08-29，用户批准；含 D6 特征内不安全行为条款）

## Context

自举 lexer 实现过程暴露标准库不足导致的绕弯（实证）：

1. **无可变缓冲原语**：`append` 为 `arr + [x]`（O(k) 拷贝返回新数组），导致 lexer 用字符串当缩进栈、字符串累积输出，实测 O(n²)（n 翻倍耗时 ×3.3，见 ADR-019 性能项 bench）。
2. **内建三处手工同步**：每个内建函数须在 `Interpreter.registerBuiltins`（运行时）、`TypeChecker`（静态签名）、`SemanticAnalyzer`（符号表）三处各写一遍，本周 `is_number`/`chars` 落地时各重复三次，漂移风险持续存在。
3. **内建平铺蔓延**：27 个自由函数 + String/Array 成员方法硬编码分发于 `evaluateMember`，无组织主轴。

**约束（本轮讨论裁决）**：自举前每个语言特性都是自举债（自举端须复刻）；COW 机制（唯一性判定 + `|unsafe` 原地写）**显式推迟**到自举后性能期（无 bench 证据，独立 ADR）；特征机制本身已存在（trait + conformance + 默认实现），本 ADR 只做**组织方式收敛**，零语言表面增量。

## Decision

### D1: `collection` 特征最小面（行为零变更）

String / Array（Dictionary/Set 随后跟进）声明遵循 `collection`，方法集 = **现存方法原样挂入**：

`len`、下标读、`append`、`pop`、`slice`、`join`、`contains`

不新增方法、不改任何签名与语义；Swift 层级（Sequence/Collection 细分、Index）不引入，v1 后按需生长。

### D2: 内建双层结构（目标态）

- **内建层（intrinsic）**：宿主原生实现，长期保持最小面（无法用 Pini 高效表达的底层操作）。
- **语言层**：特征的默认实现尽量以 Pini 书写（如 `contains` 可由下标遍历实现），自举后逐步从内建层下沉——**标准库自举即编译器自举的一部分**。
- v0.x 现阶段：全部维持宿主实现，仅完成 D3/D4 的组织收敛；下沉动作逐个独立评估（正确性对拍 + bench 双门槛）。

### D3: 单点登记机制

新增**按特征声明一处、三层自动生效**的注册路径（`BuiltinRegistry` 或等价机制）：每个内建声明一次（签名 + 运行时实现 + 归属特征），解释器 / 类型检查 / 语义分析从同一注册表取用。现有三处手工列表改为从注册表派生。

### D4: 内建归组表（旧调用名全部保留，零破坏）

| 组 | 内建 |
|----|------|
| collection | `len`、`append`、`pop`、`slice`、`join`、`contains`（+ String/Array 成员方法挂特征） |
| char | `is_letter`、`is_ascii_digit`、`is_number`、`chars` |
| pointer（unsafe） | `load`、`store`、`addressof` |
| io | `readFile`、`writeFile`、`readLine` |
| math | `abs`、`min`、`max`、`sqrt`、`sin`、`cos`、`tan` |
| concurrency | `sleep`、`joinAll`、`joinWithin`、`isCancel` |
| value（暂不归组） | `print`、`assert`、`ok`、`err`、`Error`、`CancelError` |

### D5: 缓冲惯用法（替代 unsafe 写，本轮裁决）

自举期推荐模式：**数组逐元素 append + 末尾一次 `join`**（O(k) 指针拷贝，memcpy 常数，自举规模实测足够）。登记为官方推荐惯用法；`|unsafe` 数组原地写 / COW 唯一性判定推迟至 post-bootstrap，须 bench 证据立项（登记 §3 缺口）。

### D6: 特征内不安全行为的表达（用户裁决，2026-08-29）

特征的默认实现**允许包含不安全行为**，但表达方式不是 `|unsafe` 方法修饰符——`|unsafe` 维持 ADR-015 的仅限自由函数约束，**不扩展到特征方法派发**。特征方法（`|self`）体内需要不安全操作时，在**方法体内部用 `unsafe <expr>` 消耗点逐个消耗**（ADR-015 既有机制）。

理由：① 方法派发机制（解析/类型检查/运行时分派）完全不感知 unsafe，特征子系统零增量；② 不安全范围收敛到单个表达式而非整个方法体，与「`unsafe` 标记单次不安全操作」的既有语义一致；③ 避免 `|self` 与 `|unsafe` 两个修饰符在方法头上组合出新语法面。

### D7: 集合特征链形态——参考 Swift，在哈希与序列上分叉（用户裁决，2026-08-29）

`collection` 之下的特征链对齐 Swift 的组织方式：集合能力沿**序列（sequence）**与**哈希（hashable）**两条分支展开。**优先完成 sequence 分支**（迭代/下标/缓冲惯用法是 lexer/parser 等编译器 pass 的当务之急）；hashable 分支（字典键、集合去重依赖）随后跟进。D1 的 `collection` 最小面即为 sequence 分支的首期内容，命名与层级待 sequence 落地后随 spec 修订定稿。

## Consequences

**变容易**：内建新增从「三处同步」降为「一处声明」；lexer/parser 等 pass 获得官方缓冲写法，绕弯（字符串当栈/累积）有据可依；内建面有了组织主轴，自举端可按特征逐组对拍。

**变难 / 挂账**：注册机制改造触碰三个手工列表的初始化时序（登记点必须先于任何 use）；默认实现下沉（D2 语言层）每项都需独立对拍；`collection` 特征面在 Dictionary/Set 跟进时可能暴露方法面不足（届时小步扩面）。

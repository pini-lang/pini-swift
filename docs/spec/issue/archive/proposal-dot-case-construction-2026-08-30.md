# 提案：`.caseName(...)` 点号用例构造语法

- 状态：**LANDED（2026-09-04 批 E）**（原 2026-08-30 自举探针批次 1 设计讨论裁决「立项挂账、择破坏窗口裁决」；2026-09-04 提案检查时用户裁决采纳；2026-09-04 批 E 实施落地）
- 关联：ADR-026 D1（裸名用例构造的三档静态解析规则）；ADR-023（具名关联值决议）；E-120；issue-llvm-dotcase-expected-type-2026-09-04（LLVM 端余量）

## 动机

Pini 的用例构造 `caseName(args)` 在语法上与函数调用**完全同形**——成员身份不可见。
ADR-026 D1 静态收敛后，裸名构造按「期望类型 → 模块唯一 → 报错要求限定」解析，
规则正确，但有两个残留代价：

1. **可读性**：读者看到 `int_lit(...)` 无法即判「这是一个枚举用例构造」，
   需要类型信息才能定位成员归属；
2. **期望类型缺位的强制限定**：歧义名在无期望类型位置（如 `Any` 参数、无标注
   let）必须写完整限定形式 `枚举名.caseName(...)`——Swift 用前导点
   `.caseName(...)` 把这个「成员意图」压缩到一个字符。

## 提案语义

新增产生式：`case-construction ::= '.' IDENT ['(' args ')']`——
**前导点 = 成员意图标记**，语义与限定形式完全等价（去糖为
`expectedEnum.caseName(...)`；期望类型不可知时报错同 D1 第 3 档）。

- `let x: Expr = .int_lit(value: 1, loc: l)` —— 等价 `Expr.int_lit(...)`
- `match v { case .int_lit(p, l): }` —— 可选配套（模式位点号），二期再议
- 完全去糖、零运行时语义变化；纯语法糖

## 参照

- Swift：前导点 + 上下文消歧是唯一形态；成员意图语法化使上下文解析安全且无歧义
- Rust：`Enum::Variant` 完全限定 + `use` 导入（更重的限定形式）
- Haskell：平面命名空间禁止同名（自举实测证明不适合 AST 类代码）

## 落地前置

- 破坏窗口：Provisional 期内（G50 先例——趁自举早期执行破坏性更名/语法变更）
- 迁移面：examples 全量 + selfhost src/tests + spec 产生式（case-construction
  进入 primary 表达式）
- 不阻塞任何在途里程碑（S5–S11 以现有裸名规则运行）

## 落地记录（2026-09-04 批 E）

- **D-1 AST 形态**（用户裁决，经 Swift 实证调研）：专用未解析节点
  `Expression.dotCaseRef`，与 Swift `UnresolvedMemberExpr` 同构——解析期仅携带
  名字、实参挂外层 `.call`；决议在类型检查阶段完成（期望类型优先）。否决
  「解析期哨兵去糖」（与 G30 `nil` 去糖不同，dot-case 基座解析期未知）。
- **决议规则**：期望类型命中 > 唯一父枚举回退 > 歧义拒绝（D1 第 3 档同轨，
  报错文案区分点号形态）。语义差异点：**成员意图不受本地位遮蔽影响**
  （裸名构造会被局部变量劫持，点号不会——testDotCaseIgnoresLocalShadowing 钉定）。
- **内建 Optional**：`.some` / `.none` 直达（用户枚举候选为空时；用户枚举
  候选优先）。
- **D-2 迁移面收窄**（用户裁决）：提案「迁移面 examples 全量 + selfhost」为
  破坏性假设残留——本语法纯增量（旧写法继续合法），**不做全量迁移**，仅新增
  `examples/enum-dot-case.pini` 演示 + 7 个测试 fixture。
- **D-3 LLVM 范围**（用户裁决）：唯一名 + 内建 some/none 可用；歧义名显式
  E6-004（期望类型线程缺位，报错 + 立案 issue-llvm-dotcase-expected-type-2026-09-04，
  不硬塞）。`pini compile` 唯一名端到端实测通过。
- **单文件 `pini run` 行为注记**：单文件通道类型层宽松（既有行为，与裸名构造
  对称），歧义点号构造在运行期报错——package / `pini check` 通道静态决议完整。
- spec：primary-atom 新增 `'.' IDENT` 产生式 + 点号构造注；enum-case D1 注补
  点号指针。全量测试 1192 / 112 跳过 / 0 失败。

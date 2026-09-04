# Issue：LLVM 端点号构造的期望类型线程缺位

- 状态：**Open**（2026-09-04 批 E dot-case 落地时立案，D-3 裁决：报错 + 立案，不硬塞）
- 关联：proposal-dot-case-construction-2026-08-30（已 LANDED 归档）；E-120

## 现状

解释器通道对「歧义 case + 期望类型」的点号构造完整可用（checker 在期望类型命中位记录
`BareCaseResolutionRegistry`，运行期查表构造——varDecl 标注位 / 实参位 / 无实参形态均覆盖）。

LLVM 端无期望类型线程：`ExprEmitter.generateCall` 对 `.dotCaseRef` 只能经
`enumCaseQualifiedKey(forUnqualified:)` 按未限定名解析——唯一名成功，歧义名抛
E6-004「ambiguous unqualified enum construction」（提示改用限定形式）。

## 缺口

LLVM 端若要支持「歧义 case + 期望类型」的点号构造，需给 `generateExpression` /
`generateCall` 补期望类型参数线程（generateExpression 加 `expected:` 参数，涟漪面大），
或复用 checker 的静态决议表（BareCaseResolutionRegistry 按位置查表——需确认 IRGen
运行时点 checker 已跑完、registry 未被 reset，且 SourceLocation 键可对齐）。

## 验收判据

- `let s: 形状 = .圆(3.0)`（跨枚举同名）在 `pini compile` 通道正确构造 形状.圆；
- golden IR 不受唯一名路径影响（字节级不变）。

## 优先级

低——限定形式 `形状.圆(3.0)` 在 LLVM 端已完整可用，点号歧义场景可迁移绕行；
排期与 LLVM FFI / get·unchecked（issue-llvm-get-unchecked-2026-09-04）一并考虑。

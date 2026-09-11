# Issue：LLVM 端点号构造的期望类型线程缺位

- 状态：**Closed**（2026-09-07 落地：复用 checker 静态决议表，单点修改覆盖全部构造形态）
- 关联：proposal-dot-case-construction-2026-08-30（已 LANDED 归档）；E-120、E-131

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

## 落地记录（2026-09-07，Closed）

**裁决**：两条候选路径中采纳「复用 checker 静态决议表」（路径 B）——`generateExpression`
期望类型线程化（路径 A）涟漪面大，与工单低优先级定位不匹配。

**实现**：

- `AggregateEmitter.enumCaseQualifiedKey(forUnqualified:at:)` 加 `at loc:` 参数；
  歧义分支（`keys.count > 1`）先查 `BareCaseResolutionRegistry.parent(at: loc)`，
  命中即返回该父枚举限定键（`mangle` 对齐非 ASCII 名），未命中维持既有报错（fail-open）。
  单点修改自动覆盖全部 4 个构造位（裸名无实参 / 点号无实参 / 点号 callee / 裸名带关联值）。
- **位置键对齐（实现关键）**：checker 两条 record 路径（`noteBareCaseOutcome` /
  `refineEnumCaseConstruction`）对 call 形态记录的均为**外层 call 的 loc**——而
  `generateCall(callee:arguments:)` 原签名恰好丢弃外层 loc。签名改为
  `generateCall(callee:arguments:at:)` 线程外层位置；无实参形态传表达式自身 loc。
  全 CodeGen 唯一的 `sl()` 是恒零 stub，不可用于查表（初稿踩坑，已改为显式 loc 线程）。
- **生命周期前提（勘测补证）**：LLVM 管线先 check 后 IRGen（CLI 主流程既有顺序），
  `BareCaseResolutionRegistry.reset()` 仅在 `check()` 开头——IRGen 查表时数据完好。
- 唯一名路径不进歧义分支，golden IR 字节级不变。

**验证**（E-131）：

- CLI 冒烟三态：点号歧义 + 期望类型 = 42（Shape.Circle 正确构造）；裸名歧义 + 期望类型 = 42；
  无期望类型 checker 层 E4-001 拒绝（fail-open 守卫）。
- 新测试 3 个：`testDotCaseAmbiguousExpectedTypeViaLLI`、`testBareCaseAmbiguousExpectedTypeViaLLI`
  （checker 先行 harness 变体）、`testAmbiguousCaseWithoutResolutionRejected`（无 checker 时
  IRGen 层维持拒绝，无门控恒执行）。
- 门开全量 1214 / 0 失败；真门关 1214 / 0 / 114 skipped（+2 门控 skip）。
- **勘误**：E-130 所记「门关 112 skipped」实为门开假象——`which lli` 命中
  `/opt/homebrew/opt/llvm/bin`（llvm keg 路径在默认 PATH 可见），门判据 PATH 漂移再现；
  运行期统一判据仍未落地（遗留，见活跃账本）。

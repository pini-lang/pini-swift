# Issue：旧后端 F64 值处理对超大浮点触发 Int64 溢出陷阱

- 状态：**Closed（2026-09-11 立案；2026-09-12 M6b 翻转完成，旧 CodeGen 已整体删除，
  本缺陷随之消亡。冻结先例见 ADR-031 约束 1）**
- 发现来源：M6c 横切项 X2（`CHANGE_F64` 预期重基线核验）抽查 `testDiffFloatPrint` 时
  观察到旧通道非零退出
- 关联：`docs/issue-print-f64-format-parity-2026-09-07.md`（同一夹具的来源）、
  `docs/issue-legacy-i64-print-sext-2026-09-07.md`（同类「旧后端 print 面缺陷、冻结待删」先例）、
  `docs/issue-llvm-rewrite-plan-2026-09-07.md`

## 现象

旧通道跑差分套件的浮点边界值夹具时**崩溃退出**（rc = -5，非 lli 报错、非 Pini 诊断）：

```
pini run-llvm Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests/testDiffFloatPrint.pini
→ rc=-5
→ Swift/arm64e-apple-macos.swiftinterface: Fatal error: Double value cannot be converted
  to Int64 because the result would be greater than Int64.max
```

同一夹具的解释器与 HIR 通道均正常，输出一致（最短往返格式）：

```
2.5 / 0.30000000000000004 / 0.5 / 1000000.0 / 1000000000000000.0 / 1e+16 / 1e+21 / 0.0001 / 1e-05 / 123456789.123456
```

## 根因

`Sources/PiniCore/CodeGen/IRGenerator.swift` 的 F64 值处理分支：

```swift
if value == Double(Int64(value)) && abs(value) < 1e15 {
```

两个条件之间是**短路与**，而 `Int64(value)` 排在范围守卫**之前**，因此先求值。
Swift 的 `Int64(Double)` 对超出表示范围的值是 **trap**（不是返回 nil、也不是饱和），
守卫来不及拦。

- 触发阈值：`|value| > Int64.max ≈ 9.22e18`；
- 夹具里的 `1e21` 落在其中，于是整条旧管线在这里终止进程；
- `1e16` 仍在 Int64 范围内，不触发——所以该分支平时看不出问题。

## 影响与边界

- 仅旧后端（`IRGenerator`）受影响；新发射层 `IREmitter` 的 F64 打印经运行时
  helper（`bk_double_to_string`）走宿主标准库，不经过该分支。
- 触发条件是「程序里存在超大 F64 值参与这条处理路径」，属输入相关崩溃，
  不是编译期可预知的拒绝。
- 该 fixture 是 M4 批②为 F64 展示语义新增的边界值用例，覆盖 `1e16` / `1e21`
  等阈值——正是它能暴露此缺陷的原因。

## 建议处置（未决）

1. **交换求值顺序**：`abs(value) < 1e15 && value == Double(Int64(value))`。
   一行改动即可消除陷阱，且语义不变（守卫本就是为这个范围检查而写）。
2. 或**按冻结约束不动**：ADR-031 已冻结旧后端功能新增，旧 CodeGen 在 M6 翻转批
   整体删除，缺陷随载体消亡。参照 `issue-legacy-i64-print-sext` 的 wontfix 先例。

推荐 2（与既有先例一致，避免为待删代码增加改动面）；若 M5/M6 期间旧通道仍需
维持该夹具可跑，则按 1 处理并补旧管线单测。

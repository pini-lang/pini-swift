# Issue：解释器 evaluateBinaryOp 缺失 float 比较分支

- 状态：**Closed（2026-09-08 收口）**
- 收口记录：LR-7 裁决补齐六分支。`evaluateBinaryOp` 新增
  `(.float, .float, op)` 六个比较分支（== != < <= > >=，照 int 分派形态，
  返回 `.bool`）；混合 int/float 比较维持 TypeChecker 拒绝（E4-001 实测，
  非解释器层缺口）。TDD：`testFloatCompare` 红（E5-003 复现）→ 绿；
  差分套件补 `testDiffFloatCompare`（18→19 fixture 中的第一个）。
  证据 E-140（源已删除）。
- 发现渠道：HIR 差分测试批②——fixture `print(sum == 3.0)`（两个 F64 相等比较）
  在解释器通道直接抛 RuntimeError，LLVM 通道 fcmp 正常。

## 缺陷描述

`Sources/PiniCore/Interpreter/Interpreter.swift` 的 `evaluateBinaryOp` 对
`.float` 只有四个算术分支（plus/minus/multiply/divide），**没有任何比较分支**：
`.float` 与 `.float` 的 `==`、`!=`、`<`、`<=`、`>`、`>=` 全部落入
`default`，抛 `typeMismatch(expected: "compatible", got: "float(a), float(b)")`
——即使两侧都是 float 也报「类型不匹配」。

复现（解释器通道，`pini run`）：

```
main|func() -> ():
    let a: F64 = 2.5
    let b: F64 = 0.5
    print(a + b == 3.0)
    return
```

期望 `true`，实际抛 `类型不匹配: 期望 compatible, 得到 float(3.0), float(3.0)`。

## 影响

- 语言层 F64 只能算不能比，`if x > 1.5` 这类守卫在解释器通道不可用；
- HIR 差分测试（Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests.swift）
  因解释器侧无法运行 F64 比较，float fixture 整体缺席，f64 发射路径暂无
  差分覆盖（注释中已标注本工单号）。

## 修复方向

- 按既有 int 分派形态补六个 float 比较分支（返回 `.bool`）；
- 补解释器单测（六个比较算符 × 相等/不等两侧）；
- 修复后为差分套件补 `testDiffFloatCompare` fixture。

## 关联

- `docs/issue-llvm-rewrite-plan-2026-09-07.md`（M4 批②；LR-3 类型化树已携带
  F64 比较节点，发射侧就绪、解释器侧缺口）
- `docs/spec/issue/archive/issue-print-f64-format-parity-2026-09-07.md`（F64 print 格式分歧，
  float fixture 补齐的另一半前置）

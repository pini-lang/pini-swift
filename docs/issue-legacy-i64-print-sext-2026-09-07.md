# Issue：旧后端 print(I64) 发射非法 IR（sext i64 -> i32）

- 状态：**Closed（2026-09-08 关单，LR-10 裁决 = wontfix）**
- 关单记录：旧后端已冻结功能新增（ADR-031 约束 1），M6 翻转批将整体删除旧
  CodeGen（本缺陷随之自然消亡）；新管线 `IREmitter` 已用 `trunc` 修正
  （M4 批②，差分绿）。不做修复，本单按 wontfix 关闭；若 M5 期间出现
  「旧管线必须维持 i64 print 可用」的需求再翻案重开。
- 发现渠道：HIR 差分测试先以旧后端同款 `sext` 发射 i64 print，lli 报
  `invalid cast opcode for cast from 'i64' to 'i32'`；回查旧发射器确认同病。

## 缺陷描述

`Sources/PiniCore/CodeGen/Emitters/StringifyEmitter.swift` 单参 print 的
类型分派中：

```
case "i8", "i16", "i64":
    // sext <ty> ... to i32
```

把 `i64` 与 `i8`/`i16` 混在同一**加宽**分支。`sext i64 -> i32` 是收缩转换，
LLVM 拒绝（正确指令为 `trunc`）。凡 `print(I64 值)` 的程序，旧管线
（IRGenerator）产出的 IR 无法通过 lli/clang。

- 现状：无既有测试覆盖 i64 print（能力清单 M2 的 59 语料中无此形态），
  缺陷静默存活至今。
- 新管线 `IREmitter` 已改用 `trunc i64 -> i32`（M4 批②落地，差分绿）。

复现（旧管线，`pini emit` 或 run-llvm 通道）：

```
main|func() -> ():
    let a: I64 = 1000000
    let b: I64 = 2000000
    let c: I64 = a + b
    print(c - b)
    return
```

## 修复方向

- StringifyEmitter 该分支按宽度分派：i8/i16 → sext；i64 → trunc；
- 补旧管线单测（run-llvm 或 emit + llvm-as 校验）；
- 顺带核对多参 print 与插值路径是否存在同款混用。

## 关联

- `docs/issue-llvm-rewrite-plan-2026-09-07.md`（M4 批②；LR-6 重写路线下
  本缺陷随旧 CodeGen 在 M6 翻转批删除，若迁移期内不修则登记后按工单维护）

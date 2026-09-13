# Issue: LLVM 端 `get` / `unchecked` 内建方法零实现

- **状态**：Open（2026-09-04 批 C2 勘测新立案，自 M2 账面拆出；**2026-09-13 工单整理批勘误并刷新** —— 见下「勘误与刷新」节，开放面收窄为 `Dictionary.get`；证据 E-161）
- **归属**：LLVM 后端 / 内建方法
- **关联**：`docs/spec/issue/archive/issue-host-optional-slice-2026-08-28.md`（M2 账面已出清；本缺陷为其勘测副产品）/ ADR-008（C-ABI 运行时）/ `Optional` 枚举 IR ABI（`%enum.Optional`，AggregateEmitter 已具备）

## 勘误与刷新（2026-09-13 工单整理批）

- **命名**：正文写的 `unchecked(i)` 是旧名。`ADR-028` D-1 表定名为 **`getUnchecked`**
  （`Sources/PiniCore/Common/BuiltinRegistry.swift` 的注册名同此）。
- **越界语义**：正文写「越界保持 panic」不再成立 —— `ADR-028` D-1 表把 `getUnchecked`
  的越界定为 **UB**。
- **验收面收窄**：`ADR-028` D-6 明示第三通道（`getUnchecked`）为**解释器专用**，
  LLVM 端沿用 unsupported ⇒ 本单验收口径第 2 条**不再适用**，
  「有利条件」段与「备注」段所据的旧前提随之作废。
- **所指文件已删**：正文引用的 `Sources/PiniCore/CodeGen/Emitters/`
  （含 `AggregateEmitter` / `StmtEmitter`）已随 M6b 翻转批整体删除；
  现唯一发射路径为 `Sources/PiniCore/HIR/` 加 `Sources/PiniCore/CodeGen/IREmitter.swift`。
- **已出账部分**：`xs.get(i)` / `s.get(i)`（Array / String 通道）在 HIR 侧已落地
  （`HIRLowerer` 的成员分派 + `IREmitter.emitOptionalGet`）。
- **剩余开放项**：`d.get(k)`（Dictionary 通道）在 HIR 侧仍抛 unsupported；
  而契约条目 `optionalGet` 未限定类型 ⇒ 二选一：补实现，或明文缩小契约的类型范围。

## 缺陷描述

解释器端容器访问为**双通道**语义（`Interpreter.swift` 内建分派）：

| 通道 | 界内 | 越界/缺失 |
|---|---|---|
| `xs[i]`（下标语法） | 裸值 | 抛错（E5-005 / shim `bk_panic`）——**双后端已对齐** |
| `xs.get(i)` | `Optional.some(v)` | `Optional.none` |
| `xs.unchecked(i)` | 裸值 | 抛错 |

**LLVM 后端对 `get` / `unchecked` 方法零实现**（`Sources/PiniCore/CodeGen/Emitters/` 内无任何 `"get"` 分派；`get` 走通用成员方法调用路径报 unsupported）。含 `get(i)` / `match xs.get(i): case some(v): ...` 惯用法的程序在 LLVM 端无法编译。

## 有利条件

`Optional` 的 IR ABI 已完整在位（`AggregateEmitter.generateEnumCaseConstruction`：none tag=0 / some tag=1 装箱构造；`StmtEmitter` match some 装箱解构）——本缺陷实现面 = 在内建方法分派处为 `get` 接 `some/none` 构造（越界/缺失 → none：数组 shim 越界现走 `bk_panic`，需与 M2 工单同类的外科处理：`get` 语义先行界检查 `bk_array_len` 或 shim 增设安全读入口）、`unchecked` 接裸值路径（越界保持 panic）。

## 验收口径

- [x] Array / String 通道（`xs.get(i)` / `s.get(i)`）已出账。
- [ ] **Dictionary 通道（`d.get(k)`）仍开放** —— HIR 侧抛 unsupported。
- [x] `getUnchecked` 条目不适用（`ADR-028` D-6：第三通道为解释器专用，LLVM 端沿用 unsupported）；本条原写的「越界保持 panic」语义亦被 `ADR-028` D-1 表改为 **UB**。
- [ ] 双后端对比测试（clang 通道本机可验证；LLI 通道随环境）。

## 备注

`get` 的越界→none 需 shim 层非 panic 读取通道（`bk_array_get` 现越界即 panic）——与 M2 工单原拟的「越界安全通道」同题；实现时二选一：codegen 先 `bk_array_len` 界检查，或 shim 增设 `bk_array_get_opt` 返回 NULL。设计取舍在实施批次定。

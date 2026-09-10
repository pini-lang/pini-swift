# 工单：HIR 管线 CLI 诊断丢失（HIRLoweringError 未接 DiagnosticProviding）

- 状态：**Closed（2026-09-11 a8 收口归档；M6a a6 已落地，a8 复验达成）**
- 提出：2026-09-08（M5 规划补全批勘测发现）
- 严重度：低（诊断质量；不影响能力与正确性）
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（M6a 横切②，裁决点 D5=A）

## 现象

`pini emit` / `pini run-llvm`（含 `PINI_HIR_PIPELINE=1`）在 HIR 门控报错时只输出：

```
Error: The operation couldn’t be completed. (PiniCore.HIRLowerer.HIRLoweringError error 1.)
```

`HIRLoweringError` 携带 `message` + `location`（`CustomStringConvertible` 已实现），
但 `formatCLIError`（main.swift:1476）只对 `DiagnosticProviding` 走诊断渲染，
其余错误落入 `localizedDescription` 兜底 —— Swift 枚举 Error 的默认描述即
"error N"，行号与门控消息全部丢失。

## 影响

- 能力 sweep 的 hir-emit 通道 note 列拿不到逐文件 gate 明细（本次规划批
  被迫用一次性探针测试绕行取证）。
- 用户侧所有 HIR 门控错误不可读。

## 建议修法

`HIRLoweringError` 实现 `DiagnosticProviding`（对齐其它诊断类型的元数据
形态：错误码 + 消息 + 跨度），或最低成本：`formatCLIError` 对
`CustomStringConvertible` 错误输出其 `description`。二选一，裁决后落地。

## 验收

`PINI_HIR_PIPELINE=1 pini emit examples/collections.pini` 输出包含
"dictionary literal" 与行号，而非 "error 1"。

## 落地记录（2026-09-11，a8 收口）

**实现（a6）**：`HIRLoweringError` 实现 `DiagnosticProviding`，复用既有 E6 错误码面——
HIR 门控统一落 E6-004（unsupported feature），并接入 `ErrorFormatter` 的
「错误码 + 位置 + 消息」渲染；同批顺带修 `readFile` / `writeFile` 的 `fopen` 判空
（HIR 侧对 NULL 落 `bk_panic`，缺文件不再段错误）。

**验收复验（a8 实跑，当前 HEAD）**：

```
$ PINI_HIR_PIPELINE=1 pini emit examples/concurrency.pini
Error: IRGen Error [E6-004]
  at examples/concurrency.pini:15:14

unsupported feature 'call to unknown function 'sleep' (intrinsics beyond print are later grids)'
```

修复前该路径输出 `(PiniCore.HIRLowerer.HIRLoweringError error 1.)`——无错误码、无位置、
无门控消息。现为**错误码 + 相对路径行号 + 具名门控文本**，验收达成。
（验收原写语料 `examples/collections.pini` 在 G5 字典族完成后已能通过，
故复验改用仍在门控态、且同时驱动双通道的并发语料。）

**连带消解**：能力 sweep 的 hir-emit 通道 note 列现已给出「码 + 位置 + 门控明细」
（`Error: IRGen Error [E6-004]   at <语料>:行:列   unsupported …`），
即本工单「影响」节第一条所述的一次性探针绕行取证不再必要。

**遗留（另案，不在本单范围）**：`emit` 系命令的诊断仍以 `source: nil` 调格式化器，
**源码行与下划线标记缺失**，而同命令的类型错误路径是带的。已立
`docs/issue-emit-diagnostic-source-snippet-2026-09-10.md` 交治理流程裁决。

# 工单：HIR 管线 CLI 诊断丢失（HIRLoweringError 未接 DiagnosticProviding）

- 状态：Open
- 提出：2026-09-08（M5 规划补全批勘测发现）
- 严重度：低（诊断质量；不影响能力与正确性）

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

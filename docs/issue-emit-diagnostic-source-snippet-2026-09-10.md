# 工单：emit 系命令的诊断拿不到源码片段（附默认语言注释失真）

- 状态：Open
- 提出：2026-09-10（M6a a6 诊断面落地，验证输出时发现）
- 严重度：低（诊断质量；不影响能力与正确性）

## 现象

HIR 门控错误接上诊断面之后，`pini emit` 的输出有错误码、有位置，但**没有源码行与跨度下划线**：

```
Error: IRGen Error [E6-004]
  at examples/concurrency.pini:15:14


unsupported feature '...'
```

原因是 `emit` / `compile` / `run-llvm` 三条命令的 catch 一律以 `source: nil` 调
`formatCLIError`，诊断渲染因此拿不到源码。而源码在**调用点手边就有**——同一个 do 块内
刚 `readFile` 出来的结果，只是没有往下传。

## 影响

- 诊断少了指认现场的那一半：用户只能自己数第 15 行。
- 同一批命令的**类型错误路径带源码行**（`typeCheckThenGenerate` 内部直接渲染），
  两条路径的诊断质量不一致，读者会以为门控错误天生低一档。

## 建议修法

把三条命令的 `readFile` 结果提到 do 块外（或改用「先读源码，再调用」的两段式），
将 `source` 传进 `formatCLIError`。只需逐处判定该调用点是否已持有源码，渲染逻辑不动。

## 附带观察（同批勘测）

`DiagnosticResources` 的初始语言是 `en`（`Sources/PiniCore/Common/DiagnosticResources.swift`），
而 CLI 解析 `--lang` 处的注释写「默认 zh」，诊断测试也按「产品默认 en」写
setUp / tearDown。即：不显式传 `--lang zh` 时全部诊断按英文模板渲染，注释与实现不一致。

需一次裁决：注释订正为 en（改注释），还是默认值改为 zh（改行为，会影响既有英文输出
的调用方与测试）。二选一，不在此工单内动手。

## 验收

`pini emit <被门控的文件>` 的输出在 `at …:行:列` 之后给出该行源码
与 `~` 标记，与同命令的类型错误输出形态一致。

# 结果匹配

## 目标与边界

让宿主的 `check` 对 `Result<T>` 主体的 match 判臂名、绑定数与穷尽，与自举侧对齐；三条语料在宿主侧
分别发出 `E3-007`、`E4-005`、`E3-006`。

边界：只补宿主语义层的类型名推导与随之生效的既有检查，不新写一套 match 规则——自举侧已实现，
本件是把同一判据搬到宿主。不动 `Result` 的语言面语义。

## 缺口与读数

| 项 | 现状 | 取数入口 |
|---|---|---|
| 宿主诊断 | 三条语料零诊断（`工作区检查通过`） | `pini check tests/conformance/cases/diag-result-match-*` |
| 自举诊断 | 已补齐：三条各报期望码 | `pini-bootstrap/.build/release/bin/pini check` 同路径 |
| 根因 | `typeNameOfAnnotation` 只认 `.simple`，泛型注解返空 | `Sources/PiniSemantics/Semantic/SemanticAnalyzer.swift` |
| 差异基线 | 三条登记为宿主缺口 | `pini-bootstrap/tests/conformance/divergence-baseline.tsv` |
| 期望码 | `E3-007` 未穷尽、`E4-005` 绑定数不符、`E3-006` 未知用例 | 各 `case.toml` 的 `code` 字段 |

## 批次

### 一、泛型注解取名字

`typeNameOfAnnotation` 对 `.generic(name, _)` 返回 `name`，与 `.simple` 同口径。`Result<T>` 因此
得到一个类型名，后续判定按名字查表，`<T>` 的具体实参不参与。

判据：`Result<I32>` 注解能读出 `Result`（取数：一条最小夹具 + `dump`）；副作用面全量回归无新增诊断。

### 二、三条语料转绿

改完推导后，`checkMatchExhaustive` 与臂绑定数校验会自动生效。逐条核对码与位置：码取 `case.toml`
的 `code`，位置取 `line` / `col`。

判据：三条语料在宿主侧分别发出 `E3-007`、`E4-005`、`E3-006`，位置与 `case.toml` 一致；
自举侧读数不变（两跑相同）。

### 三、删基线与台账行

`divergence-baseline.tsv` 三条按门禁规则删掉（只许缩小，转绿即红提示删）；自举计划件台账的
**结果匹配** 行收口删行。

判据：`tools/conformance.py` 通过；`parity.py --check` 表与盘上一致；台账无该行。

## 风险与裁定

| 风险 | 处置 |
|---|---|
| 认出 `Result` 后连带放开了本不该判的东西 | 只改注解取名字这一处；全量回归里任何新增诊断都算回归，逐条查清再放行 |
| `Result` 之外的泛型注解（如 `Box<I32>`）也被认出 | 同一条路径，改动同样受回归约束；不在本件扩大判据 |
| 宿主与自举的位置口径不同 | 位置以 `case.toml` 为准；两侧位置不同即判红，不做偏移换算 |
| 与 **泛型类型面** 交叉 | 本件只认注解文本，不依赖泛型类型实例；两件互不为前置 |

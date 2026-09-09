# Issue: multidim 语料宣称的「下标读返回 Optional」语义解释器未实现

- **日期**：2026-09-09
- **状态**：Open
- **发现批次**：M5 G11 struct 深化族（分支 `agent/pini-dev/llvm-m5-g11-struct-deepening`）
- **登记证据**：E-151

## 现象

`multidim.pini` 语料头部宣称「下标读返回 Optional」（match some / none
分支即为此设计），但探针实测：

1. 解释器裸下标读返回**裸值**：`print(m[1])` 直接打印 `[4, 5, 6]`，
   非 Optional 包装。
2. match some / none 分支**静默不命中**：scrutinee 类型
   `array(element: i32)` 不属于 Optional/enum，两分支均跳过——
   只有补 `case _` 才有输出。

## 根因

解释器未实现「数组下标读返回 Optional」语义：裸读返回裸值，
Optional 包装缺失，导致依赖该语义的 match some / none 静默失配。

## 实证链

- G11 红灯期勘测：`match scrutinee type 'array(element: i32)' outside
  this grid` → 实测 some/none 静默不命中（非报错）。
- HIR 通道按实测定为死臂降载（发射不派发、绑定类型 = scrutinee
  本身），与解释器现行为 parity，差分绿。

## 影响面

- `multidim.pini` 语料自述文档与解释器实际行为不一致（文档超售）。
- legacy 通道 multidim 维持 FAIL（E6-002，既有独立缺陷，本工单不覆盖）。

## 处置原则

按「记缺陷 → 工单 → 治理流程」推进，不在 G11 格内连续修复。可选方向
（待裁决）：① 实现下标读 Optional 包装（语言级变更，走 spec §1.3）；
② 修订语料自述，删除 Optional 宣称（文档级对齐）。

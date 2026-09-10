# Issue：HIR 侧聚合值（struct / object）打印缺失（迁移期已裁决豁免）

- 状态：**Open（2026-09-10 立案；M6a 裁决为除名豁免，不阻塞 M6a / M6b；源码未改）**
- 发现来源：LLVM 重写 M6a 门槛口径订正（a3 收口把分母从两套修正为四套后，
  这批夹具首次进入门槛视野；a4 追查其性质）
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（M6a 准备批 a4 与裁决点 D8）；
  `docs/llvm-capability-matrix.md`（迁移期已知限制节）

## 现象与实测

HIR 通道**拒绝**把 struct / object 值交给 `print`：

| 夹具 | 黄金输出（解释器与旧后端一致） | HIR 报错 |
|---|---|---|
| `Tests/PiniTests/CodeGen/IRPrintGoldenTests/_c_3.pini` | `点{label: hi, ok: true, x: 1}` | `printing a struct/object value is a later grid (value formatting)` @ 10:10 |
| `Tests/PiniTests/CodeGen/IRPrintGoldenTests/_c_4.pini` | `计数{名字: n, 数值: 42}` | 同上 @ 8:10 |
| `Tests/PiniTests/CodeGen/IRPrintGoldenTests/_c_5.pini` | `盒{内色: 蓝}` | 同上 @ 11:10 |

三者均为 `LEGACY_PASS_HIR_FAIL`（旧后端通过、HIR 拒绝），是 M6a 收尾时
门槛内**仅存**的阻塞项。a4 之前 `_c_5` 另有一层原因：其字段声明类型是用户枚举，
字段解析一度返回 nil，报错误称「字段不存在」（no field …）。该层已随 a4 修掉，
`_c_5` 现与其余两例报同一门控、且定位到 `print` 行——**诊断面已诚实**。

## 解释器侧契约（需逐字节对齐的对象）

`Sources/PiniCore/Interpreter/Interpreter.swift` 的 `stringify`：

- struct：`类型名{` + **按字段名升序**（Swift `String` 比较序）的 `字段: 值` 逗号分隔 + `}`；
- object：同形（字段同样按名升序）；
- 值递归：枚举 / 容器 / 字符串 / 标量各自沿用既有展示语义
  （容器与枚举打印 HIR 侧**已实现**，`_c_6` – `_c_9` 等用例在门槛内为 PASS）；
- 另有一处特例：struct 含 `message` 字段时走单独分支。

即：缺口只在「名义类型的字段枚举 + 排序 + 包裹」这三步，值本身的递归
格式化在 HIR 侧已具备可复用实现。

## 为什么它不在已完成的格内

- `docs/llvm-capability-matrix.md` 与 M6 计划均把它写作**后续格**
  （「值格式化」），HIR 门控文案也自述 later grid——能力声明与实现**一致**，
  不属 G15 / G16 那类「PASS 高估能力」的假绿。
- M6a 的格划分（G16 / G17 / G18）来自「14 夹具聚类」，而本工单的 3 个夹具
  **从未进入那 14 个**：a3 收口把门槛分母由两套（`IRExecutionTests` /
  `RuntimeBackendTests`）修正为四套后，它们才第一次出现在阻塞表里。
  即：这是**口径修正新暴露的范围**，不是原计划欠账。

## 影响

- **翻转后 `print(structValue)` 由可用变为带位置信息的 fail-loud**。
  不产生静默错码（a4 后报错行号与门控文案均准确），但对使用者是能力下降。
- 旧后端删除后，该能力的唯一实现载体消失；`IRPrintGoldenTests` 亦属
  待删 / 待重定基线的 A 类套件，其回归信号随之一并消失。
- M6a 的 a7 验收口径为「阻塞数 = 0 **或全部转已裁决豁免**」，本项按后者处理；
  豁免需在 `docs/llvm-capability-matrix.md` 有对应记载，避免成为「未声明的限制」。

## 建议处置（未决，待排期）

1. **作为独立格实现**（推荐路径，需先估工）：新增名义值打印的 HIR 节点 + 发射路径，
   复用既有容器 / 枚举打印递归；字段顺序可在编译期定序（结构体在 IR 里是定型聚合、
   字段位置静态已知），因此**不一定需要运行时排序**——这是估工的关键未知项，需实测确认。
2. 若评估为需触 >3 个发射路径，按 ADR-031 §4 的 S-4 止损直接转为永久豁免并写明理由。
3. 无论实现或豁免，都需与解释器 `stringify` 做**逐字节**对齐验证（嵌套枚举字段、
   容器字段、字符串字段、`message` 字段特例），并补差分夹具；
   风险集中在「格式对齐」而非「能否发射」。

**本轮不实现**的理由：该能力面在计划中已被显式划到后续格，且属口径修正新暴露的
范围；把它拉进 M6a 会让准备批失去「零删除、可停」的形状，而翻转的验收口径本身
允许已裁决豁免。若后续估工显示成本很低，可在 M6a 的 a7 复扫点重新纳入。

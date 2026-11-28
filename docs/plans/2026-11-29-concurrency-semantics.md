# 并发语义检查

## 目标与边界

把并发面的两条判据补齐：语义层拒绝跨任务共享可变引用（`E4-013`），解释通道能跑并发示例
（执行表九例由「保留差异」转「通过」）。

边界：不改发射层的任务模型。`packages/backend-llvm/src/_internal/task.pini` 已承载结构化并发的发射，
本件只补检查与解释执行两侧。`asyncDeinit` 与作用域退出归 **引用计数进解释器**，不在此件。

## 缺口与读数

| 项 | 现状 | 取数入口 |
|---|---|---|
| 执行表九例 | 全部「保留差异」：并发语义面未落地，执行线只跑单线程 | `pini-bootstrap/tests/parity/execution-disposition.tsv` |
| `E4-013` | 未发出：并发任务拒收引用形参的检查没做 | `tests/parity/diagnostics.tsv` |
| 语义层 | 无并发检查：`packages/semantics/src/api/` 下无并发相关文件 | 目录列表 |
| 发射层 | 已有：`task.pini` 出任务树与汇合 | 同上 |
| 解释器 | 单线程；`sleep` 等并发内建不提供 | `packages/evaluator/src/api/native.pini` |

九例分别是：`concurrency`、`concurrency-arrow-dual`、`concurrency-async-contagion-end`、
`concurrency-async-decl`、`concurrency-await`、`concurrency-cancel`、`concurrency-future-handle`、
`concurrency-joinall`、`concurrency-joinall-var`。

## 批次

### 一、`E4-013` 检查

在语义层采集「并发入口」的函数集，对每个任务形参判类型类别：引用类型（object）直接拒，值类型放行。
判据由参考件的并发章给出，不按实现反推。

判据：`E4-013` 发出；正例（struct 形参）不报；两侧差异表删该行。

### 二、解释通道的并发内建

补 `sleep`、`joinAll`、Future 句柄四类内建。解释器单线程，`await` 与 `wait` 的语义差别只在
「能否让出」——单线程下两者都按占用的合规降级处理，但**类型与位置检查仍要照做**，不能因为不真让出就跳过。

判据：异步函数类别（`=>`）可声明并调用；`await` 在同步体里报错；九例中不依赖真并行的先转绿。

### 三、九例逐个转绿

按 `execution-disposition.tsv` 逐条改处置并删行。取消与 Future 句柄两例依赖运行时段，排在本批末尾。

判据：执行表九例转「通过」；`pini tools/examples-gate.py --legs run` 零差异；
`parity.py --check` 通过（处置表与盘上一致）。

## 风险与裁定

| 风险 | 处置 |
|---|---|
| 单线程下把「跑得过」当成「语义对」 | 类型与位置检查单独立判据，不因降级执行而放宽 |
| 九例里有依赖真并行的（`concurrency` 行序由调度决定） | 该例按行多重集比，不逐字节比；已在 golden 豁免表登记 |
| 解释通道的并发内建与运行时段符号面重复 | 内建只落到解释器，不进 ABI；要用运行时段时按 **运行时 C 化** 的符号表取 |
| 检查过严拒掉合法写法 | 判据只认参考件写明的条款；参考件没写的从严会让实现变成规范，须先补条款再补检查 |

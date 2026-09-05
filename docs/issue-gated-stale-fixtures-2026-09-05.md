# 门控测试夹具过时（跳过门后潜伏缺陷）：批③ 全量回归暴露

- 状态：**Open（2026-09-05 批③ 全量回归时暴露；按「立案不修」方法论单列，批③ 未触碰）**
- 性质：**既有潜伏缺陷，非批③ 回归**——main 工作树对照实测：同批 4 个测试在 main 上全部 skip 或同因失败（对照命令与 scratch 见下），排除批③ 引入。

## 现象（批③ 全量回归实测 1198 执行 / 5 失败，其中 4 失败属本工单）

| 测试 | 我的分支表现 | main 对照 | 失败原因 |
|---|---|---|---|
| `IRExecutionTests.testD3ContainerPrintBothBackendsMatch` | FAIL | **skip** | 夹具第 4 行仍用字典旧记法 `[键: 值]`——G57（批 3，2026-09-02）改 `=` 后夹具未随改；因门控常 skip 从未暴露（Parser.swift 字典记法报错） |
| `IRExecutionTests.testIsAsciiDigitViaLLI` | FAIL（19 ≠ 1） | **FAIL（同因）** | lli 门开时实际运行失败；lli 可用性与门控行为本机不稳定（批 C1 时记录本机无 lli） |
| `IRPrintGoldenTests.testAggregatePrintMatchesInterpreter` | FAIL（索引越界） | **FAIL（同因，9 断言失败）** | 门开时实际运行失败（SubscriptStrategies 索引越界），夹具与门控通道不匹配 |
| `RuntimeBackendTests.testArraySubscriptWriteBothBackends` | FAIL（LLVM 未记录数组元素类型） | **skip** | LLVM 端能力门：门开时暴露 D1 范围限制（LLVM 后端未记录变量 `mrow` 的数组元素类型） |

## 根因候选

1. **门控判据跨 scratch 不稳定**：主仓 scratch（/tmp/pini-build，跨会话复用）与新建 scratch（/tmp/pini-main-scratch）的门开合不同——疑似门判据在编译期捕获环境（lli/clang 探测），随构建产物固化；同机不同 scratch 结论可相反。
2. **门后夹具失修**：长期 skip 的测试在依赖语法/能力演进（G57 字典记法、LLVM D1 范围）后夹具/断言未随改，门一开即炸。

## 建议（待裁决，本工单不执行）

- 门判据统一为**运行期**探测并在 skip 消息里带上原因与判据值；
- 对门控测试的夹具做一次「门开演练」（强制开启跑一遍），修夹具至真绿，再恢复门；
- 或按 ADR-020 D1 范围给 `testArraySubscriptWriteBothBackends` 换 LLVM 不可用时的负向断言。

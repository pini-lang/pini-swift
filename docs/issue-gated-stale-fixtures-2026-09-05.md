# 门控测试夹具过时（跳过门后潜伏缺陷）：批③ 全量回归暴露

- 状态：**Open（2026-09-05 批③ 全量回归时暴露；按「立案不修」方法论单列，批③ 未触碰）**
- 状态：**Closed（2026-09-07 落地收口，见文末落地记录；门判据运行期统一留待后续批）**
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

## 落地记录（2026-09-07，用户裁决：#2 修后端对齐 / #3 对齐三通道 panic）

门开演练（`PINI_LLVM_BIN=/opt/homebrew/opt/llvm/bin` 强制开启）实测四个失败，性质分层后全部修复至真绿：

| 测试 | 性质 | 处置 |
|---|---|---|
| testD3ContainerPrintBothBackendsMatch | 纯夹具腐烂 ×2 | ① 行内字典 `["Alice": 30]` 迁 G57 `=` 记法（语料迁移漏掉行内源码串）；② 夹具内 `print(d["Zoe"])` 行为三通道前「打 null」残留 → 移除（panic 场景由 testDictMissingKeyBothBackends 覆盖），黄金串去 null 尾巴 |
| testIsAsciiDigitViaLLI | 后端不一致缺陷 | 单参 print 不发换行（`@fmt_int = "%d"` 无 `\n`），而多参 print 已带——补 `@fmt_newline` 常量 + 单参/插值/空参路径统一补发换行（对齐解释器；多数测试的空白归一化此前掩盖了该分歧） |
| testAggregatePrintMatchesInterpreter | 陈旧语义残留 | `_c_10` 黄金样例编码 P2-E 前的「缺键打 null」→ 移除样例与夹具；panic 场景由补齐的 testDictMissingKeyBothBackends 锁步覆盖 |
| testArraySubscriptWriteBothBackends | D1 能力边界 | 按本工单建议转负向断言：IR 生成期 unsupportedFeature（含「数组元素类型」），无门控恒可执行；能力扩展时翻转 |

**后端语义修复（随 #3 裁决一并落地）**：`bk_dict_get` 缺失键由「返回 NULL → IR 补零值」改为直接 `bk_panic`（G48 三通道：缺键 = 越界同义，与解释器 panic 对齐，同 `bk_array_get` 越界机制）；IR 侧字典读取的「NULL → 补零值」死分支随之删除；`print(d[k])` 缺失键 null 特例（`generatePrintDictSubscriptWithNull` + `@bk_dict_contains` declare）移除。验证：命中键读、len、COW 直调（RuntimeCOWTests 走命中路径）不受影响。

**门判据漂移根因确认**：`PINI_LLVM_BIN` → `llvm-config` → `which` 三级探测随调用环境 PATH 漂移；本机 lli 存在于 `/opt/homebrew/opt/llvm/bin` 但不在默认 PATH——跨 scratch 门开合相反即源于此。运行期统一判据（工单建议①）留待后续批，不在本次范围。

- 证据：E-130。

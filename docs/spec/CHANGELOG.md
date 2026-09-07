# Pini 变更日志（CHANGELOG）

> 版本里程碑归档：只记录**公开版本**的变更摘要。规范正文描述现况（`pini-spec-v0.md`）；历次公开版本的变更事实集中归档于此。

## v0.53.0（2026-09-07）

- **try-else 错误传播**（G3 迁移落地，ADR-032 / spec §2.4.4）：`try <expr> else <e> <handler>` 为错误传播唯一原语，语句位与表达式位双形态（表达式位挂 primary 位）；操作数静态要求 `Result<T, E>`，handler 限控制流（return/break/continue/pass，pass 仅语句位吞错；块形式须控制流终止）。
- **`^` 右值糖重定义**：`^e` ≡ `try e else err: return err`（Parser 层定义性脱糖），不再注入返回元组末槽；`^T` 类型糖（≡ `Result<T>`）不变。
- **破坏性（D2 一步删，无迁移提示）**：`try`/`except` 块语法移除（`except` 退出关键字表）；`(值, 错误)` 元组错误位约定退役（错误传播只经 `Result`；`err("")` 亦为错误，无空串特判）；LLVM 后端 try-else 表达式暂 fail-loud（提示改用解释器）。
- 语料迁移：`examples/try.pini`、TryExceptTests/CPS 夹具改写；`testTryStatement_LLI` 删除（LLVM 发射待后端批）。

## v0.52.0（2026-09-02）

- **模块工具链**（G52 批 3 落地，ADR-024 治理面）：`pini mod {tidy, refresh, verify, graph}`；清单双通道（require/resources/tap/replace）；MVS + `pini-summary.toml` + SHA-256 校验和（TOFU）；build 漂移检查（采用门控）。v1 边界：仅本地 `file:` tap。
- **隐式别名注入**（D-4 钉定，spec §2.5）：`_别名 = path` = 注入全导入（文件级）；非 `_` 别名必须限定调用；冲突 E3-013；别名不一致 E7-002 弱警告。`_` 记法四义位置表入 spec。
- **argv 透传**（F6）：`argv()` 内建。
- **多项 import 块**；R1 嵌套清单排除补全（父扫描侧）。
- **破坏性**：`[dependencies]` 节移除（命中报错）；单文件 run 过语义门禁。

## v0.51.0（2026-09-02）

- **集合下标三通道**（G48 破坏性修订，ADR-028）：`a[i]` 安全断言（返回元素类型 `T`，越界 **panic**）；`a.get(i)` 安全可选（`Optional<T>`，越界 `.none`）；`unsafe a.getUnchecked(i)` 不安全（越界 UB）。三类型一致，字典缺失键与越界同义。解释器向 LLVM 既有行为收敛。
- **括号内记法收口**（G57 破坏性修订，ADR-029）：**`=` = 值的注入方向**（实参标签 / 字典条目 / 元组标签 / 默认参数），**`:` = 标注与取出方向**（类型标注 / 块开启 / match 具名绑定）；注入位旧 `:` 记法废弃。空字典无字面量，走类型构造 `字典<键, 值>()`。
- **跨行集合 / 元组字面量**（G55，A12 方案 B / 路 C）：普通括号内 NEWLINE 等同空白、缩进不参与；块携带括号（开括号同行紧跟 `func`）内部布局照常（草稿 IIFE 形态正名）。
- 破坏性迁移指南：`docs/spec/migration-2026-09.md`。

## v0.48.4（2026-08-28，初始公开发布）

- **初始公开发布**：Pini 语言（Swift 实现）首个公开版本。静态类型、声明/块交替顶级结构、函数体强制缩进、数据与逻辑分离、显式错误传播（errors-as-data）、异步与并发（`=>`/`await`/`wait`/`joinAll`）、FFI 与 unsafe（ADR-015）、语言级 `|test` 测试块、解释器 + LLVM 双后端。

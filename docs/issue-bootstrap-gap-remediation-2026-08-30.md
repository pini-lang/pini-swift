# Issue: 自举探针缺口修复方案——八项宿主缺口的规模评估与落地批次（2026-08-30）

> **来源**：`examples/selfhost`（自举探针）parser 阶段 S0–S4 落地过程中发现，全部证据为可执行探针实测（`examples/selfhost/docs/host-gaps.md` 为权威台账，本 issue 为宿主侧落点，ADR-024 D7）。
> **背景**：S5–S11 已搁置，待本方案的类型系统簇落地后折返（`examples/selfhost/docs/issue-bootstrap-parser-2026-08-30.md`）。
> **治理**：批次 0 为宿主级 bug fix（D6，无需 ADR）；批次 1 需语言级 ADR + spec §1.3 流程（D5 双段落地）；批次 2–4 为 spec 修订 + 实现配套。

## 一、缺口总览（严重度 × 规模）

| 缺口 | 现象 | 严重度 | 宿主改动面 |
|---|---|---|---|
| **G-P9①** | 探针阶段解释器 **SIGSEGV**（exit 139、零输出）；macOS 崩溃报告诊断：无界 Pini 级调用递归打穿线程栈，**无任何深度护栏与诊断** | 🔴 内存安全/可诊断性 | Interpreter 单点 |
| **G-P6** ⭐ | match 模式与构造调用均**按名字全模块解析**，无视被匹配类型/期望类型（E4-005 错误参量数、E4-001 expected-expr-got-int_lit） | 🔴 语义正确性 | 类型检查器核心 |
| **G-P8** | `let x = self.f()` 结果被推成 Any，后续与字面量比较即 E4-001；外部接收者保持类型（探针实证） | 🟡 | 类型传播管线单点 |
| **G-P2** | `Array<T>.append` 类型擦除（H2/H3 修复曾落地后被 9e54e27 回退，需复盘根因） | 🟡 | 类型传播 |
| **G-P3** | 枚举 case 值无类型身份：不能作关联值（"expected keyword, got kw_var"）、return 位置拒收 | 🟡 | 类型层 case 装箱 |
| **G-P1** | 无 F64 值构造；混合算术 E5-003 | 🟢 有绕行 | BuiltinRegistry + spec 数值小节 |
| **G-P7** | `pini parse` 投影**有损且文法未钉**：while `step:` 块、struct 字段初始化器、import/export 不渲染、无位置 | 🟢 有绕行 | CLI 打印 + 文档 |
| **G-P5** | 关键字不能作构造标签（`object`/`step` 实测解析错误）；**自举侧提议：反引号转义允许关键字作标识符/标签**（Swift 语义） | 🟢 有绕行 | 词法 + spec 标识符小节 |
| **G-P9②③** | String/I32 字面量被 `Any` 参数拒绝（装箱不一致）；`|self|unsafe` 组合修饰符解析失败，对象方法无法进入 unsafe 上下文 | 🟡 | 运行时装箱 + 解析器 |

## 二、落地批次（依赖序）

### 批次 0（立即，宿主级 bug fix）
**解释器调用深度护栏**：`callFunctionValue` 增加深度计数，超过上限抛 `RuntimeError.invalidOperation`（复用既有错误码，零 spec 变更）。理由：自举是常驻探针（D9——会崩的探针比没有更糟），无限递归/深层嵌套都应得到可诊断错误而非进程死亡。

### 批次 1（语言级，ADR-026 候选「case 值类型身份与类型传播」）
依赖序：G-P6①（构造调用按期望类型解析）→ G-P8（self 调用类型传播）→ G-P2（复盘 revert 根因后重做类型传播）→ G-P6②（match 按 scrutinee 类型解析）→ G-P3（case 值完整身份收尾）。spec §A.4 / match / 数值关联小节随行修订。
**自举侧收益**：拆除全部绕行（case 改名还原、内联比较还原、`[Any]` 流还原）。

### 批次 2（词法/语法）
G-P9③（放行组合修饰符，`modifiers` 列表已存在）+ G-P5（反引号转义，三选项中推荐反引号；备选：标签命名空间解耦 / 维持现状+spec 写明）。

### 批次 3（投影规范）
G-P7 推荐路线：投影文法钉为规范并**补齐有损项**（step 块/字段初始化器/import-export 各补打印）——差分 oracle 升级为无损；备选：声明现投影非规范、另立稳定规范形输出。

### 批次 4（数值）
G-P1：`BuiltinRegistry` 新增 F64 转换（按 ADR-020 D3/D4 快速路径，声明处注释动因）+ spec 数值小节。自举侧 float 从持文本升级持值，差分达值等价。

## 三、验收与闭环

每批落地：宿主测试绿 → 自举重标 `.pini/baseline` → 台账翻 `HOST-FIXED-AWAITING` → 删除偏离与标记 → 复绿（G-P4 已示范全流程）。类型系统簇全部闭环后，自举折返 S5–S11。

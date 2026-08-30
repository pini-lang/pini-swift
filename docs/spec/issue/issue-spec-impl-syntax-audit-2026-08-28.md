# 工单：spec EBNF ↔ 实现语法审计（G50 治理复核 + 特征块 `|own` 设计落点）

- 日期：2026-08-28
- 提出方：agent:pini-dev（用户委托："own 治理复核 + 特征块 |own 内指代 + 找出元仓库草稿与实现不吻合的语法"）
- 方法：以宿主 v0.48.4+（main 0d5bf64 / G50 分支）`pini check` / `pini tokens` 为事实基线，对 spec §A.1–A.2 全部产生式逐构造最小样本探针（三轮，约 60 样本）；错误按 E2（解析拒）/E3+（语义收，语法通）分类。
- 状态：已拍板（G51，2026-08-28）；spec 修订完成；宿主收敛项登记待实施

## 0. 用户拍板记录（2026-08-28，G51）

依据：`../Pini草稿.md`（设计原意的事实源）。四条裁决：
1. **spec 是权威事实源**——不再"以实现现行、延迟更新事实源"；偏离一律登记宿主收敛项；
2. **顶级裸 import/export 语句不应存在**——Pini草稿 §[名称|import]（包路径绑定 + `_` 隐式别名）/ §[类型名称|export]（可见性别名导出表，与 `_` 访问控制联动）是唯一设计形态；宿主裸语句实现为已知偏差，收敛待办；
3. **花括号函数声明是过时语法，应当清除**——Pini草稿函数块仅裸名形式（§函数块），花括号专属对象块；spec 产生式已删除（宿主本就拒绝，`func-rest` 悬空引用一并消除）；
4. **`@` 保留**——未来可能用上；DELIMITER 收编（宿主 lexer 已产出 at token）。

## 0.5 G51 处置落点（已执行，spec 修订）

| 审计项 | 处置 |
|---|---|
| A1/A2 import/export | **spec 保留**（草稿形态）+ 钉"块形式是唯一顶级形态"注；宿主收敛项：移除裸语句、实现块形式 |
| A3 花括号 func-decl | **spec 删除**产生式；top-level-decl 改引 bare-func-decl；object 花括号糖拆为 object-decl-sugar（仅裸名，A4） |
| A4 `\|object` 可选项 | spec 改为 object-decl-sugar 仅裸名（糖语义，Pini草稿 §{对象块}） |
| A5 defer | spec 改双形态：相邻单行语句（宿主现行）+ `:` 块形式（草稿意图，宿主待实现） |
| B1/B2 match 守卫/绑定 | **spec 挪入 §A.5 未采纳草案**（草稿 match-case 无此设计） |
| B3 KEYWORD | spec 补 `pass`（34 个，消除 C1 自相矛盾）；`test` 保留（草稿有测试函数块，宿主对齐登记待办）；`scope` 保留不再使用 |
| C2 trait-body | **spec 落地产生式**：`trait-body ::= { trait-method }`，`trait-method ::= IDENT ['\|' ('self'\|'own')] func-signature [func-body]`——无修饰符 = 抽象方法、`\|self` = 本身方法（可捕获 self）、`\|own` = 本型方法（own 指代实现特征的被扩展类型，禁止捕获外部对象）、有体 = 默认实现（特征扩展） |
| C3 `@` | DELIMITER 收编，"保留待用（G51）" |
| B4 try 限定 | 保留（草稿 try/except 通用设计；宿主 async 限定为覆盖缺口） |
| D 级 A.6.5 快照 | 随下版 bump 顺手更新 |

**宿主收敛待办清单（G51 遗留，按优先级）**：
1. 移除顶级裸 `import`/`export` 语句解析路径，实现 `[名称|import]` / `[名称|export]` 块形式（含 `_` 别名语义——与 `_` 访问控制系统联动，涉及可见性层）；**2026-08-31 已裁决执行**（用户拍板）：理由是本语言顶层未为裸语句留空间（连全局变量都没有），不可能仅为 import/export 破例。排期在「块形式批次」，依赖 G52 的 import-即-依赖 与跨模块访问语义先行；为破坏性变更，走 Provisional 破坏窗口。返工点：自举 parser / 语料 / 投影镜像了宿主的裸语句实现，须随宿主同步（记于自举 issue §7.1 L1b 入口清单）；
2. `defer` 块形式（`defer:` + 缩进块）；
3. `test` 关键字词法对齐（现以标识符修饰符路径实现 `|test`）；
4. （既有）成员内建名劫持、`ImportExportTests` 裸语句用例改写为块形式。

## 0. G50 治理复核（用户关注点 ①）

**已走完 spec 治理**，无缺口：
- G50 决策行已登记（§G 表，Provisional v0.49.0，含更名理由与破坏性标注）；
- EBNF 已更名 5 处：KEYWORD 表（§547）、method-decl（§668）、modifier（§684）、type-annotation `'self'|'own'`（§783/§817）、规则 3.13（§861）；
- §A.2.6 注（§340）与特性表行（§139）已带溯源；
- 宿主（分支 a86d4e7）与自举（4c79577）已随动，测试全绿。

## 1. 偏离清单（用户关注点 ③）

### A 级：EBNF 记载与实现直接冲突（产生式需重写/作废）

| # | spec 条款 | spec 说 | 实现实证 | 备注 |
|---|---|---|---|---|
| A1 | import-decl（§616-617） | 块形式 `['import'\|'import']` + `IDENT '=' STRING` item | 裸语句 `import math` ✓、`import math as m` ✓（as 重命名实现已收） | 块形式 E2-002 拒；两套语义完全不同 |
| A2 | export-decl（§619-620） | 块形式 + `IDENT '=' IDENT` 重命名 | 裸语句 `export add` ✓；`export myAdd = add` **E2-006 拒** | 重命名 export 未实现 |
| A3 | func-decl 花括号形式（§634） | `'{' IDENT ['\|' 'func'] ... '}' func-rest` | `{f}` / `{f\|func}` 顶级均 **E2-001 拒** | 花括号函数声明不存在；`func-rest` 产生式亦未定义（spec 内部悬空引用） |
| A4 | object-decl 花括号 `['\|' 'object']` 可选项（§635） | `{cfg\|object}` 合法 | `{cfg\|object}` **E2-002 拒**；裸 `{计数对象}` ✓、`{{计数对象}}` 扩展 ✓（object.pini 在用） | 可选修饰符实际被拒 |
| A5 | defer-stmt（§729） | `'defer' control-block`（块形式） | `defer print("bye")` ✓、`defer x = 5` ✓；`defer:` 块 **E2-006 拒** | 实现是 `defer + 语句`（Parser.swift:2266 起），非块 |

### B 级：EBNF 超前于实现（主文法收录了未采纳构造）

| # | spec 条款 | spec 说 | 实现实证 |
|---|---|---|---|
| B1 | match-case 守卫（§724） | `['if' expression]` 守卫 | `case n if n > 0:` **E2-001 拒** |
| B2 | match-binding（§726） | `case 2 (n):` 位置绑定 | **E2-001 拒**（枚举 case 的整体绑定 `case 圆(r):` 已实现；标量/通配绑定未实现） |
| B3 | KEYWORD 表（§543-548） | 含 `'test'`、`'scope'` | 宿主无 `test` 关键字；`scope` 为 reserved-error（G44）——与既有 P4-A backlog 同源 |
| B4 | try-stmt 通用性（§725） | `'try' expression control-block` 通用语句 | 仅异步 CPS 语境有测试覆盖（`try (await child()):`）；同步 `try boom():` 报 E3-001（语法收、语义仅 async 路径）——建议 spec 标注 async 限定 |

### C 级：spec 内部自相矛盾

| # | 条款 | 矛盾 |
|---|---|---|
| C1 | KEYWORD 表 vs pass-stmt | KEYWORD 列表**缺 `'pass'`**（却含未实现的 `'test'`），而 §727 有 `pass-stmt ::= 'pass'` 产生式；宿主 pass 关键字 + 语句均可用（探针 OK） |
| C2 | trait-body 悬空引用 | §638/§644 两处引用 `trait-body`，**全文无产生式定义**（特征块内方法文法缺失——正是特征块 `\|own` 设计无落点的原因，见 §2） |
| C3 | DELIMITER 注（§590-591） | "'@' 历史残留不列入"——但宿主 lexer 产出 `at @` token、自举 [token] 模型含 at；要么实现移除、要么 spec 收编 |

### D 级：记录类（非冲突）

- A.6.5 验证记录快照陈旧（941 tests → 现 1010）：建议改为"以最近一次全量回归为准"的动态表述或随版本 bump 更新。
- 一致项抽查全过：进制 0x/0b/0o、科学计数、插值 `\(...)`、control-block 同行 `if true: print(1)` 与缩进块两形态、`&x`（unsafe 门控）、`unsafe` 消耗点、`*T`/`^T`/`[K:V]`/`{T}` 类型注解、字典/集合字面量、复合赋值全集（含 `<<=`/`>>=`）、前缀 `++`/`--`/`^`、泛型 `identity\|func<T>(x: T)` + 调用点 `identity<I32>(5)` + 约束 `T \| 形状`、匿名函数 `func (n,) -> (I32,):`（含无类型参数）、标签 `lp\|while` + `break lp`、`step` 块、foreign 块（签名无 `\|func`，与 EBNF foreign-signature 一致）、结构体组合行。

## 2. 特征块 `|own` 内指代（用户关注点 ②）

**实现已就绪，spec 缺正式化**：
- 探针：`<可克隆>` 内 `克隆|own() -> (own,)` + `((点))` 内 `克隆|own() -> (点,)` **check 通过**（`|own` 修饰符在特征块被接受，`own` 返回类型的 conformance 替换已有 TraitConstraintTests 覆盖）；
- 反例印证：扩展块实现方法**无修饰符**时被规则 3.14 拒（`克隆(self) -> (点,)` E2-006）——即 `|own` 正是特征块实现侧的合法内指代通道；
- 缺口 = C2：trait-body 无产生式，特征块方法文法（无修饰符抽象签名 / `\|own` 类型级方法 / 参数 `self` 实例方法）未成文。
- 建议：补 `trait-body` 产生式（吸收现状 + `\|own` 语义条款），登记新 G 号；与 G50 呼应（`own` 关键字在特征块的自指语义闭环）。

## 3. 处置选项（待拍板）

1. **A 级**：按实现事实重写 EBNF（import/export 裸语句 + as、defer 语句形式、删除花括号 func-decl、object 花括号去 `|object` 可选项）——机械修正，低风险；
2. **B1/B2**：二选一——(a) 实现 match 守卫与标量绑定（parser/语义层新增）；(b) EBNF 挪入 §A.5 草案（未采纳区）；
3. **B3**：KEYWORD 名单对齐宿主（去 `test`/`scope` 加 `pass`），连带关闭 P4-A backlog；
4. **C2 + §2**：trait-body 产生式 + `\|own` 特征块语义条款（新 G 号）；
5. **C3**：`@` 收编或实现移除；
6. **D 级**：随下版 bump 顺手更新。

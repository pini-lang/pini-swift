# 移除花括号函数声明 `{名}(...)`（批③ 治理落地）

- 状态：**LANDED（2026-09-05 批③）**
- 裁决链：G51②（2026-08-31，用户拍板「spec 是权威事实源」时已裁决「花括号函数声明产生式作废移除（过时语法）」——spec 侧当时已移除产生式，但误记「宿主已拒」）；2026-09-05 用户再次确认移除并指出其历史定位：**object 语法糖引入之前的古早函数声明办法**，此后花括号专用于对象声明、函数改裸声明。
- 治理路径：spec §1.3 提议（G51②）→ 影响评估（本工单）→ 落地（批③：宿主移除 + spec 注记 + 迁移说明）。

## 影响评估（移除前实测）

- **实现面**：`Parser.parseTopLevelDecl` 行首 `{` 位经 `isBraceFuncDecl()` 前瞻（`{名}` 后首个非换行 token 为 `(`）分派到 `parseFuncDecl(isTopLevel: true)`——该函数为花括号形态专用（全仓唯一调用点），随移除一并删除（死面）。
- **语料面**：`examples/`、`examples/selfhost/`、自举测试零使用（grep `^\{[^}]*\}\s*\(` 仅命中测试夹具与 selfhost `.git` 对象噪声）。零迁移成本。
- **测试面**：两处夹具钉定旧形态，随裁决改造为拒绝断言（见下）。
- **保留面**：`{名}` / `{名|object}` 裸名对象糖不变（G51③）；类型体内旧 `{名|self}(...)` 方法形态此前已废止（ADR-016 规则 3.2，报错指向扩展块），不受本次影响。

## 落地记录（批③，全量测试基准见 evidence E-124）

0. **豁免项（实施中修正）**：`{名|test}(签名)` 测试块花括号形态**不在移除范围**——它是 spec 测试函数块条目文档化的现行形式（`TestBlockTests.testParseTestBlockBraceForm` 钉定），不是古早通用函数声明。首次实施时误伤该形态（全量回归暴露），随即修正：前瞻检测器升级为返回修饰符，`|test` 豁免（`parseTestBraceDecl` 专用路径），其余修饰符/无修饰符照移。**遗留候选**：花括号测试形态与「花括号 = 对象、函数 = 裸声明」的语体一致性是否收敛，留待独立裁决（不默认跟进）。
1. **Parser**：顶层 `{` 分派改为——`braceFuncDeclModifier()` 命中且非 `|test` 即报 E2-005 迁移提示（「已移除…请改用裸声明 `名|func(...)`；类型方法移至扩展块并显式 `|self`」），否则恒走 `parseObjectDecl`；`parseFuncDecl(isTopLevel:)` 删除（花括号通用形态死面），`|test` 豁免走新增 `parseTestBraceDecl`。
2. **测试改造**（断言均能区分移除前后两态）：
   - `GrammarConsistencyTests.testDisambigBraceFuncVsObject` → `testBraceFuncDeclRejectedWithHint`（断言拒绝 + 报错含「已移除」「裸声明」；对象糖分支保留，夹具改名 `testBraceObjectSugar.pini`）。
   - `MethodSelfModifierTests.testTopLevelBraceFuncDoesNotNeedSelf` → `testTopLevelBraceFuncRejected`（同上；夹具改名 `testTopLevelBraceFuncRejected.pini`）。
3. **spec**：§A.4 规则 3.4 重写（前瞻分派作废 → 移除 tombstone + 迁移指引）。
4. **CHANGELOG**：Unreleased 新增 Removed 节（含迁移说明）。

## 移除前的假象记录（诚实归档）

- G51② 行文「宿主已拒」在移除前与事实不符（宿主实际接受，实测 `{加}(a: I32, b: I32,)` 解析为 funcDecl）——spec 走在了实现前面，实现为滞后方。本批落地后该表述成为事实。教训归档：裁决「产生式作废移除」后应同步立案宿主移除工单，而不是让 spec 单方面先行。

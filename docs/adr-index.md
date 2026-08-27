# ADR 索引（ADR Index）

> **性质**：受 `pini-spec-v0.md` §7 治理的配套登记表。代码注释中引用的 `ADR-NNN` 必须在此可兑付（redeemable）；缺失或悬空的 ID 视为注释违规（spec §7.4）。
>
> **状态图例**：`active` = 当前生效；`reversed` = 已被后续 ADR 撤销/改写（注释中若仍出现，须理解为历史语境，不得作为当前行为依据）。

| ADR | 标题 | 状态 | 定义位置 |
|---|---|---|---|
| ADR-001 | 运行时值分裂与 COW 判定（`shares` / 集合原生 COW） | active | 注释语境推导（§2） |
| ADR-008 | 并发后端抽象（GCD 无关、集合后端、`Scheduler` 协议边界） | active | 注释语境推导（§4.3） |
| ADR-009 | 并发调度脊柱（`Scheduler` 协议抽象 + CPS 化可恢复求值器） | active | 注释语境推导（阶段 A / §8 / §8.2） |
| ADR-012 | 异步 join 表层（`await`/`wait` 前缀取代 `<=` 前缀，v0.41.0） | active（曾逆转立场 B） | `CHANGELOG.md` v0.45.0；spec 状态表 |
| ADR-013 | 块标签语法（`scope 块标签:`，v0.41.0） | reversed（被 ADR-014 逆转） | spec / 注释语境推导（v0.41.0） |
| ADR-014 | 控制流标签语法反转（`scope label:` → `标签|关键字`） | active | `pini-landing-plan-v048.md` §ADR-014；spec G44 |
| ADR-015 | 采纳 FFI & unsafe 子系统 | active | `pini-landing-plan-v048.md` §ADR-015；spec §2.7 |
| ADR-016 | 解析器声明上下文收紧（规则 3.2 / 3.14 / 3.15） | active | `pini-landing-plan-v048.md` §ADR-016 |
| ADR-017 | Phase 2b 解释器 dlsym 动态加载 | active | `pini-landing-plan-v048.md` §ADR-017；`CHANGELOG.md` v0.48.3 |

## 备注

- 本表为**最小登记表**：仅记录 ID → 标题 → 状态 → 定义位置，使代码注释里的 `ADR-NNN` 可追。完整决策理由应逐步补入各 ADR 专节（建议 `docs/adr/ADR-NNN.md`），届时更新本表「定义位置」。
- `reversed` 类（ADR-013）在旧注释中仍大量出现，属历史语境；注释清理时保留 ID 但删除其附带的版本号叙事（见 `pini-comment-style-guide.md` §9 P3）。
- 2026-08-27 治理收口：全仓 180 处 `ADR-NNN` 引用（集中在 `PiniCore` 并发 / FFI / 解析器）**全部可兑付**，`comment-lint.sh` L6 已作为门禁挂 pre-commit 与 CI（大小写不敏感，堵 `adr-` 小写盲区）。

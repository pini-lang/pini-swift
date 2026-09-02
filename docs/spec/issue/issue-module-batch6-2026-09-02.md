# 批 6 · 模块工具链落地（G52 批 3：`pini mod` + MVS + `pini-summary.toml` + 校验和）

- 状态：**In progress**（2026-09-02 开工；语义面已由 G52 D1–D23 钉定，本批为宿主实现，无新语义裁决）
- 依据：`docs/spec/issue/issue-module-system-rules-2026-08-28.md`（字段规范 §3 + 命令规范 §4）、spec §2.5（G52）、`issue-module-batch1-2026-08-31.md`（批 3 推迟项：D-4 隐式别名等）
- 前置：批 5（IO 路径基准）——`deps/` 落地与工具路径解析依赖程序基准语义

## 1. 范围（IN / OUT）

**IN**：
- 清单解析升级：`[tap]` / `[require]` / `[require.<tap>]` / `[resources]` / `[resources.<tap>]` / `[replace]`；TOML `[[ ]]` 数组表（G52 §5.1 连带决议，供锁文件复用）
- MVS：`[require]` 传递闭包上的最小版本选择 → `pini-summary.toml`（含 `imported-by`、`graph.order`，D16）
- SHA-256 校验和（`manifest_sum` + `sum`；规范化遍历；TOFU；D6）
- `pini mod {tidy, refresh, verify, graph}`（D23：无全局缓存、无 clean/add/get）
- build 时 require↔import 漂移检查（每次 build，不符提示 `pini mod tidy`）
- D-4 隐式别名注入（G52 批 1 推迟项）——**已于 2026-09-02 裁决并落地**（用户逐条裁决 #1~#6）：`_别名 = path` = 注入全导入（文件级裸名空间，裸调用或 `_别名.符号` 限定）；非 `_` 别名必须限定；三类冲突 → E3-013；别名≠目标名仅 E7-002 弱警告；前置缺口一并补齐（多项 import 块、R1 父扫描嵌套排除）。遗留 Def-1/2/3 见 `docs/spec/issue/issue-d4-deferred-defects-2026-09-02.md`
- 旧 `[dependencies]` 节：命中即报错并指引迁移到 `[require]`（本批 D-B）

**OUT（明确排除）**：
- **远程 tap 下载**（`github:`/`git:` 协议解析、下载、解包）→ 批 7；批 6 的 `refresh` 只服务本地 `file:` tap，遇远程 tap **报错退出**（本批 D-A）
- 资源寻址 API（G52 §3.3 明文「待定」——v1 只做落地 + 校验）
- 中心化 sumdb（v1 不做，TOFU 即可）

## 2. 实施决策（2026-09-02 用户批准，全按推荐）

| # | 决策 | 理由 |
|---|---|---|
| **D-A** | `refresh` 遇远程 tap（`github:`/`git:`）：**报错退出**，不跳过 | 半成品依赖比报错更危险；批 7 落地后自然解除 |
| **D-B** | 旧 `[dependencies]` 节：**报错指引**迁移到 `[require]`，不静默忽略 | spec 已移除该节；静默 = 复活已死语义（与旧 `module.toml` 命中即报错同风格） |
| **D-C** | `graph` 默认输出缩进树文本（`app └─ text 1.2.3`）；`--cycles` 输出环路径列表 | 与 R2 环报错措辞（`app → text → uni → app`）复用，服务环诊断 |

## 3. 阶段与出口

| 阶段 | 内容 | 出口 |
|---|---|---|
| 1 | 范围登记（本文 + 路线图 §8.1） | 落档 |
| 2 | 清单解析升级（§1 前两项 + D-B） | 构建 + 既有测试 0 失败 |
| 3 | MVS + 锁文件生成 + 校验和 | 本地 tap 夹具上 summary 生成且字段齐全 |
| 4 | 四命令 `pini mod {tidy, refresh, verify, graph}` | 全链路 tidy→refresh→verify 在夹具走通 |
| 5 | build 漂移检查 + D-4 隐式别名 | 漂移报错提示 tidy；D-4 用例过 |
| 6 | 测试补齐（MVS 用例 / 篡改检出 / 环诊断）+ 证据登记 + gate + 基线 | 四项标准出口 + **篡改 `deps/` 后 `verify` 必须报错** |

## 4. 现状取证（2026-09-02 19:05，开工前）

- `FileLoader.parseManifest`（`Sources/PiniCore/Common/FileLoader.swift:232`）：仅 `[package]`/`[dependencies]`（占位）/`[ffi]`/`[build]`；值仅字符串与内联数组；未知节容错忽略。
- `pini mod` 子命令不存在；`pini-summary.toml` / 校验和 / MVS 全仓 grep 零命中。
- `ModuleManifest.dependencies` 消费点仅 2 处（`FileLoader.swift:101` 透传、`:190` init）——可安全移除。
- 语料中 `[dependencies]` 仅 `examples/multifile/pini.toml` 一处且无实际条目（仅注释）——迁移零风险。

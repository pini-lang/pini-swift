# Issue：MiniTOML 不剥离值行行内注释，G52 Def-3 入口校验据此误报 E5-018

- 状态：**Closed（2026-09-07 收口——引号感知行内注释剥离落地，六门回归证明通过，见文末收口记录）**
- 来源：`examples/selfhost`（嵌套独立仓）第 20 次重校准跑 `tools/gate.sh`，`pini run` 对 selfhost 清单报 E5-018
- 关联：G52 §9 Def-3 入口一致性校验（`Sources/PiniCore/Interpreter/Interpreter.swift` `checkEntryConsistency`，2026-09-04 落地）；`Sources/PiniCore/Common/MiniTOML.swift`

## 缺陷描述

宿主自带解析器 `Sources/PiniCore/Common/MiniTOML.swift` 提取键值时**不剥离行内注释**：
`entry = "src/main.pini"      # Executable entry (...)` 整行（含引号与注释）被当作值，
`stripQuotes()` 因值不以引号结尾而不生效。

G52 Def-3（`9e52cf9`，2026-09-04）新增的入口一致性校验拿这个污染值与 `main` 声明文件
比对，任何清单里值行带行内注释的项目都会得到 **E5-018 入口配置不一致** 的误报：

```
入口配置与代码不一致：清单声明入口为 ./"src/main.pini"      # Executable entry (...)，
但 main 定义在 ./src/main.pini
```

实测复现：selfhost 清单 `examples/selfhost/pini.toml` 的 `entry` 行自始带行内注释；
Def-3 落地（09-04）晚于第 19 次重校准（09-02），故该误报在 main 上潜伏三天未被门禁暴露。

TOML 规范允许值后行内注释；`doc.plain("lib")` / `[[bin]]` 各键同样受影响（当前仅
`entry` 被强校验故只在此暴露）。

## 请求

1. `MiniTOML` 按引号感知方式剥离值内行内注释（引号串内部的 `#` 不算注释）；
2. 补充解析级断言：值含行内注释的清单行不再透传引号/注释残片（对照样例：
   `entry = "src/main.pini"  # 注释` → 值恰为 `src/main.pini`）。

## 已做的临时规避（selfhost 侧，非修复）

selfhost 清单的值行行内注释已改为独立行注释（语义惰性）；`tools/audit_host_gaps.sh`
S1 与 `tools/diff_parse.sh` 各自的 spec 双声明检查对 baseline 键值行同样不剥行内注释，
本次一并规避。**宿主侧根因未修**。

## DoD

- 引号感知的行内注释剥离落地，全量测试 GREEN；
- selfhost 第 20 次重校准（`.pini/baseline`，host=6485609）在清单恢复行内注释写法后
  仍六门 GREEN（回归证明）；
- spec 双声明检查对含注释 baseline 行为稳健（或注明不支持并写死约定）。

## 收口记录（2026-09-07）

裁决（用户同日拍板）：①只修 MiniTOML 剥离——两个 shell 脚本的 spec 双声明 sed 检查
不稳健化，「baseline 键值行禁尾注」保持文字约定；②selfhost 清单恢复行内注释写法做
回归证明；③增量发现一并修：表头行内注释（`[tool.pini]  # Provisional` 因尾部非
`]` 匹配失败 → 键落进上一表）随同一修复点消除。

落点：

- 宿主修复（分支 agent/pini-dev/minitoml-inline-comment-fix，commit 321b2c2）：
  `MiniTOML.strippingInlineComment`——首个未处于引号串内的 `#` 起截断（`"` 翻转
  引号态；MiniTOML 无转义序列故简单翻转即可），应用点在 trim 后、表头/kv 分派前
  （一处剥，全下游干净）；整行注释剥空后按既有空行路径跳过。
- 测试（同批）：新建 `MiniTOMLTests` 6 用例——值行注释剥离（E5-018 复现）、裸值、
  引号内 `#` 保留、整行注释、表头注释（键落位断言）、数组表头注释。
  Red→Green 实证：修复前 5/6 失败，修复后全绿。
- selfhost 回归（分支 agent/pini-dev/minitoml-inline-comment-regression，
  selfhost commit 902be69 → merge 9719532）：entry 行内注释恢复原形（自 M3 规避
  提交取回原文）；manifest NOTE 更新为「值行行内注释已支持」；`[tool.pini]` 表头
  行内注释保持现状——修复后首次正确解析为独立表。六门 GREEN（L0 / parse /
  check 15 文件 / test 70-0 / audit_host_gaps GREEN），baseline 未动（无重校准）。
- 宿主全量：1226 tests / 0 failures（1220 存量 + 6 新增）。

DoD 核验：

- 剥离落地 + 全量 GREEN ✅；
- 六门回归证明 ✅（行内注释恢复后 GREEN，baseline 未动）；
- shell 脚本稳健化：按裁决①不做，「baseline 键值行禁尾注」约定维持文字记载 ✅。

证据登记：E-136（FRESH，`docs/spec/evidence-table.toml`）。

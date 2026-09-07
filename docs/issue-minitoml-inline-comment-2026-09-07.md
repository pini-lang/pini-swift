# Issue：MiniTOML 不剥离值行行内注释，G52 Def-3 入口校验据此误报 E5-018

- 状态：**Open（2026-09-07 selfhost 门禁重开批 M3 发现立案）**
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

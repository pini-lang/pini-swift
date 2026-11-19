# 验收语料

每例一个目录，自带工作区清单与成员包，能被两条通道独立装配。期望写在 `case.toml` 里，
来源是语言参考与诊断表，不拿任何一侧的输出回填。

## 目录

```text
cases/<slug>/
  case.toml        用例元数据与期望
  pini.toml        工作区清单（成员即本例的包）
  pkg/             成员包：pini.toml、src/、tests/
```

`slug` 是目录名，只作稳定标识与基线键；`name` 是中文显示名。

## case.toml 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | 是 | 中文显示名，全语料唯一 |
| `category` | 是 | `legal`、`illegal`、`unicode`、`path`、`diagnostics`、`package`、`cinterop`、`determinism` |
| `kind` | 是 | `pass`（两侧测试全过）、`error`（两侧报同一码与位置）、`reject`（两侧都必须非零）、`stable`（同一通道两次输出相同） |
| `spec` | 是 | 规范位置：哪一条语言参考或诊断表条目支撑这个期望 |
| `code` `line` `col` | `error` 必填 | 期望的诊断码与主标签起点 |
| `host` | 否 | 宿主通道入口：`check`（缺省，指向成员包）或 `build`（指向工作区，多包时用） |
| `probe` | 否 | `stable` 的探针：`check`（缺省）或 `test` |

## 判据

`error` 只比首条诊断的码与起点。渲染措辞不进判据，位置约定是「主标签落在最小可指结构」；
规范没写死位置时，按这条约定裁定，裁定不了的进基线而不是放宽判据。

`pass` 只比退出码：两侧各跑一遍同一组测试，全过才算通过。测试体是手写判据，不从宿主抄输出。

## 基线

`divergence-baseline.tsv` 记「某一侧当前还不同意规范」的现状，三列：用例、通道、实测值。
规则只有一条：只许缩小。某条实测值与期望一致了、或用例改名了，门禁会红，提示删掉那一行；
新差异必须先写进计划件的已知缺口，再用 `--update-baseline` 登记。

## 跑法

```bash
python3 bootstrap/tools/conformance.py                # 全量
python3 bootstrap/tools/conformance.py --list         # 只列用例
python3 bootstrap/tools/conformance.py --filter 名字   # 单例
python3 bootstrap/tools/conformance.py --update-baseline
```

两侧产物都要先备好：宿主 `swift build --disable-sandbox`，自举 `bash bootstrap/tools/build.sh`。
两代对照与不动点归 `bootstrap/tools/selfhost.sh`，不进合并流水线。

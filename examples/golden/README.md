# 黄金输出

每个 `<示例名>.out` 是对应示例 `pini run` 的 **stdout 逐字节期望**，由 `tools/examples-gate.py`
的 `golden` 腿比对。文件名去掉 `.out` 就是示例名（`hello.pini.out` ↔ `hello.pini`）。

- 新增示例必须同时写 `.out`；写不出逐字节期望时，在 `EXEMPT.tsv` 登记原因。
- 两者都没有 ⇒ 门禁红；`EXEMPT.tsv` 条目补上 `.out` ⇒ 门禁报 `STALE`，提示删掉豁免。
- 期望值由人审核，不要拿一次实际输出直接当期望 —— 那会把当前缺陷固化成判据。
- 比对只看 stdout；stderr 与退出码由 `run` 腿负责。

# Issue：对等探针的**默认二进制路径**写死历史布局 ⇒ 不设 `PINI_SWEEP_BIN` 时探针恒不可用

> **日期**：2026-09-18｜**状态**：**已修复**（`G-6b-2`，2026-09-18）—— 四判据全部实测达成，见 §9
> **发现于**：`G-6a` 收口批（两次误读，见 §4）· 本单的读数在 `G-6b` 规划期现测复核
> **性质**：**器械缺陷**（不是产品缺陷）—— 测量装置指向一个不再存在的产物布局
> **归属**：待裁（并入 `G-6b` / 单列一小批 / 继续只登记，三选项与代价见 `docs/issue-hir-p4-gamma-g6b-plan-2026-09-18.md` §5.3）

## 0. 一句话

`tools/hir-parity-probe.py` 的 `BIN` 默认值是 **`/tmp/pini-build/arm64-apple-macosx/debug/pini`**，
那是 **SwiftPM 旧布局**的绝对路径；今天的布局是 **`<scratch>/out/Products/Debug/pini`**。
⇒ 不显式设 `PINI_SWEEP_BIN` 就跑探针，**量到的不是「旧二进制」而是「找不到」**。

## 1. 符号级（两行）

| 位置 | 内容 |
|---|---|
| `tools/hir-parity-probe.py:250–252` | `BIN = os.environ.get("PINI_SWEEP_BIN", "/tmp/pini-build/arm64-apple-macosx/debug/pini")` |
| `tools/hir-parity-probe.py:647–650` | 不可执行时的提示语：`swift build --disable-sandbox --scratch-path /tmp/pini-build --product pini` |

⚠️ **提示语与默认值互不相容**：按提示建完，产物落在 `/tmp/pini-build/out/Products/Debug/pini`，
**仍然不等于**默认值指向的那条 ⇒ 照提示走完一遍，默认值**照样找不到**，
用户必须**另加一步** `export PINI_SWEEP_BIN=...`。这是「提示把人引向一个半成品动作」。

## 2. 实测（2026-09-18）

```sh
$ python3 tools/hir-parity-probe.py --timeout 10 --out /tmp/x.tsv     # 不设 env
pini binary missing at /tmp/pini-build/arm64-apple-macosx/debug/pini
  swift build --disable-sandbox --scratch-path /tmp/pini-build --product pini
# rc=1

$ ls -la /tmp/pini-build/arm64-apple-macosx/debug/pini
ls: No such file or directory

$ swift build --show-bin-path
/Volumes/.../pini-swift/.build/out/Products/Debug
```

| 项 | 读数 |
|---|---|
| 默认值指向的文件 | **不存在** ⇒ 走 `os.access(BIN, os.X_OK)` 失败分支 ⇒ **明确报错、`rc=1`**（**不是**静默） |
| 现行布局 | `<scratch>/out/Products/Debug/pini`（`--scratch-path X` ⇒ `X/out/Products/Debug`） |
| 无 env 时探针可用性 | **恒不可用** |

## 3. ⚠️ 两种形态必须分辨：现行态是「不可用」，历史态才是「静默量旧件」

`docs/issue-hir-p4-gamma-batches-2026-09-16.md` 的 `G-6a` 记录把现象写成
「不显式设 `PINI_SWEEP_BIN` 就会**量到陈旧二进制**」。**该表述只对历史态成立**：

| 态 | 条件 | 表现 | 危害 |
|---|---|---|---|
| **历史态** | 旧布局文件**还在** `/tmp` 里（同一台机器早先构建过） | `os.access` **通过** ⇒ 探针**静默量旧件**、rc=0、读数字面正常 | ⭐ **高**：读数是假的，且**看起来像真的** |
| **现行态**（本单现测） | 旧布局文件已被系统清理 | `os.access` 失败 ⇒ **明确报错** | 低：可见的失败 |

⇒ **根因同一个**（默认值写死历史布局的绝对路径），但**危害随环境漂移** ⇒ 单内的写法必须两态并列，
不得只写历史态那一句（否则下一位读者会以为「只要没报错就没事」）。

## 4. 已造成的两次误读（`G-6a` 批，如实登记）

| # | 误读 | 纠正 |
|:--:|---|---|
| 1 | 「同一夹具在测试路径绿、在 CLI 路径红 ⇒ 架构矛盾」（`E6-004`） | 实测是**测了另一条路径上的旧文件**；换当前构建后三个夹具全部通过 |
| 2 | 由此得出的两条排除性结论「不是旧二进制」「不是路径不同」 | **两条都错**（当时测的是旧件，故"强制重建后仍报错"不成立） |

⚠️ 这两次误读**不是**「读数不小心」，而是**器械指错对象**：它的"通过"与"失败"都不指向当前源码。

## 5. 处置候选（**不预设**）

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** | 默认值改为**运行时解析**：`subprocess.check_output(["swift","build","--show-bin-path"])` 拼 `/pini`（解析失败再回退到 `PINI_SWEEP_BIN` 与报错） | 小（约 6 行）；须核「探针启动多一次 `swift build --show-bin-path` 调用」的耗时 |
| **B** | 保留写死，但**把布局改对**（`/tmp/pini-build/out/Products/Debug/pini`）并同步提示语 | 最小（1–2 行）；⚠️ 仍会在下一次 SwiftPM 布局变更时复发 —— **同一个坑的第二轮** |
| **C** | 不改默认值，改为**无 `PINI_SWEEP_BIN` 时立即硬失败并给出完整指令**（含 `export`） | 小；把「默认值」变成「必填参数」，语义变诚实，但仍要每次手填 |

**建议**：**A**，且**保留 `PINI_SWEEP_BIN` 覆盖**（CI / 冻结件流程要靠它固定被测件）。
理由：B 是「把字面量改对」——`charter.md` E2 明写「**判据绑机制，不绑字面量**：仓名 / 分支名 / 路径 /
版本号一律运行时取值」。本缺陷正是**该条被违反的实例**：一个**产物路径**被写死进了器械。
⚠️ **本单只登记不修**；是否并入 `G-6b` 见 `G-6b` 规划 §5.3（该处给了「构成阻塞 + 工作量小」两条 D2 判据的核对）。

## 6. 判据（怎么算完成）

| # | 判据 | 测法 |
|:--:|---|---|
| 1 | **无 env 可用** | `env -u PINI_SWEEP_BIN python3 tools/hir-parity-probe.py …` 能跑出读数，rc=0 |
| 2 | **覆盖仍生效** | 显式设 `PINI_SWEEP_BIN=<另一枚>` 时，实测**读的是它**（用两枚 md5 不同的二进制对照） |
| 3 | **不再绑字面量** | 工具内**零**硬编码的产物布局路径（`grep` 只剩提示语里的 `swift build` 命令） |
| 4 | **提示语自洽** | 失败分支给出的指令，照做一遍之后**默认值即可用**（无第二步骤） |

## 7. 不做范围

只登记。**不改 `tools/`、不改任何源码**；开工须单独点名。
⚠️ 本单**不主张**它是 `G-6` 的前置 —— 它不阻塞删除；它阻塞的是**每一批的探针护栏读数可信**。

## 8. 复现方式

```sh
cd <repo>
grep -n 'PINI_SWEEP_BIN' tools/hir-parity-probe.py           # :250 默认值
swift build --show-bin-path                                   # 现行布局
ls -la /tmp/pini-build/arm64-apple-macosx/debug/pini          # 现测：不存在
env -u PINI_SWEEP_BIN python3 tools/hir-parity-probe.py --timeout 10 --out /tmp/x.tsv
```

---

## 9. 交付记录（`G-6b-2`，2026-09-18）

| 项 | 值 |
|---|---|
| 裁决 | 用户 2026-09-18「按你的建议来」⇒ 取 §5 的**选项 A**（并入 `G-6b-2` 同批修复） |
| 实现 | `BIN` 改为 `main` 内由 `resolve_bin()` 填充；新增 `_show_bin_path()` / `resolve_bin()` / `build_hint()`；新增 `--scratch-path` 参数；失败分支重写；每次运行打印 `binary under test: <路径>` |
| 文件 | `tools/hir-parity-probe.py`（**唯一改动文件**） |

### 9.1 四判据（逐条实测）

| # | 判据 | 实测 |
|:--:|---|---|
| 1 | **无 env 可用** | `env -u PINI_SWEEP_BIN … --scratch-path /tmp/pini-build` ⇒ **`rc=0`**；首行 `binary under test: /tmp/pini-build/out/Products/Debug/pini`；78 夹具，`FLIP BLOCKERS 0` |
| 2 | **覆盖仍生效** | 设 `PINI_SWEEP_BIN=<repo>/.build/out/Products/Debug/pini` ⇒ 工具**读的是它**（两枚二进制 **md5 不同**：`73e012579e3c076be5e323728d6e8d91` vs `ac1c1b297d6ac2f6c341816ef5fa1a54`） |
| 3 | **不再绑字面量** | 工具内**零**硬编码产物布局：`arm64-apple-macosx` / `out/Products` / `/tmp/pini-build` 三个模式**全仓 0 命中** |
| 4 | **提示语自洽** | 解析失败时打印 `build it with:  swift build --disable-sandbox --product pini --scratch-path <同一个>` ⇒ **照做一遍即落在解析处**，无第二步骤 |

### 9.2 ⚠️ 一处**行为变化**（必须随修复一起登记，否则下一位读者会踩）

探针**新增 `--scratch-path`**。不带它时解析的是 **SwiftPM 默认布局**（仓内 `.build/out/Products/Debug`）；
而本仓各批一贯用 `--scratch-path /tmp/pini-build` 构建 ⇒ **规范调用式随之下调为带该旗标**
（已同步进 `pini-repo-handbook` 的探针命令）。

这不是缺陷，是「默认值从前说死、现在必须说清」的必然结果：**一个解析出来的默认值只能有一个**，
而本仓有两个常用 scratch ⇒ 让**调用方**说明用哪个，比让工具猜更诚实。

### 9.3 ⭐ 附带修掉的一个隐患（顺手，因为修法在同一处）

原来那个**写死的路径**有个更坏的形态：**旧布局文件还在时**，`os.access` 通过 ⇒ 探针**静默量旧件**、
`rc=0`、读数字面正常。**`md5` 相同也不报警**。本次修法把它一并关掉 —— 现在「读的是哪个产物」
**每次都打印在首行**，且路径来自工具链 ⇒ 「量错对象」从**不可见**变成**首行可读**。

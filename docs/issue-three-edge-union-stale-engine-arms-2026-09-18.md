# Issue：`three-edge-union.py` 的包通道仍按**两个引擎**跑并对比 ⇒ 两臂同源，`agreed` 不构成等价证据

> **日期**：2026-09-18｜**状态**：**Open（登记不修）** —— 器械缺陷，**不阻塞 `LR-4` 收口**
> **发现于**：`LR-4` 收口（`P5`）批的过期表述全扫（判据 4）—— 本单是那次扫描的**遗留产物**
> **性质**：**器械缺陷**（不是产品缺陷）—— 一件测量装置**声称测两条臂，实际只有一条**
> **归属**：**未被任何在册工单覆盖**（该器械的立项条目是 `docs/hir-criteria-gap-ledger.md` 的 `CG-03`，
> 但那是**判据缺口**、不是器械缺陷 ⇒ 本单不与之合并）

## 0. 一句话

`tools/three-edge-union.py` 的包通道（`read_package_channel`）把同一个模块**跑两遍**
——一遍 `PINI_INTERP_ENGINE=ast`、一遍 `=hir` —— 再比较两次输出。
而该环境变量**已在 `G-6c` 退役**（`pini run` 不再读它）⇒ **两遍跑的是同一个引擎**
⇒ 输出恒相同 ⇒ **`agreed` 分支必然命中，`diverged` 分支今日不可达**。

⚠️ **危险的不是「它报错」，而是「它报绿」**：一张写着 `3 agreed` 的读数会被读成
「包通道的两引擎等价已被验证」，而实际上它是**自己跟自己比**。

## 1. 符号级（三处，同行）

| 位置 | 内容 |
|---|---|
| `read_package_channel` | `ast = run_package_module(root, "ast")` · `hir = run_package_module(root, "hir")` —— 两臂 |
| `run_package_module` | `env.pop("PINI_INTERP_ENGINE", None)` 后 `env["PINI_INTERP_ENGINE"] = engine` —— 设一个**没人读**的变量 |
| `main`（包通道分支） | `where = "pini run <module> (both engines, host modules only)"` —— ⚠️ **`(both engines)` 是过期表述** |

⚠️ **同族一处未修**：该件的 `BIN` 默认值写死 `/tmp/pini-build/arm64-apple-macosx/debug/pini`
——**与已修的探针缺陷（`docs/issue-hir-parity-probe-default-bin-path-2026-09-18.md`）同族**
（写死历史布局的绝对路径，今天布局已变）。探针已改为运行时解析，**本件未改**。

## 2. 实测（2026-09-18，本单独有判据）

**判据设计（有区分力）**：`P1-3` 为引擎开关定下的契约是「**非法值一律报错、不静默回落**」
（静默回落＝假绿）。⇒ 传一个**非法值**：开关若仍被读，必报错；若不读，则无影响。

```sh
$ PINI_INTERP_ENGINE=ast ./pini run examples/package-demo                      # rc=0，输出 6 行
$ PINI_INTERP_ENGINE=hir ./pini run examples/package-demo                      # rc=0，同上
$ PINI_INTERP_ENGINE=definitely-not-an-engine ./pini run examples/package-demo # rc=0，同上 ← 关键
```

| 臂 | 退出码 | 结论 |
|---|:---:|---|
| `ast` | 0 | —— |
| `hir` | 0 | —— |
| **非法值** | **0** | ⭐ **开关确实已不被读取** ⇒ 上两臂同源 |

⚠️ **为何前两行不构成判据**：两引擎在该模块上**本就可能输出相同**（HIR 是唯一执行路径）
⇒ 只有**第三行**才有区分力。**不得**只看前两行「输出一致」就下结论。

## 3. 为什么它会产假绿（机制）

| 分支 | 今日可达？ | 是否构成判据 |
|---|:---:|---|
| `agreed`（两臂 rc 相同 ∧ stdout 相同） | ✅ 可达（**恒命中**） | ❌ **不构成** —— 自己跟自己比 |
| `diverged`（一臂跑通、另一臂被拒，或输出不同） | ❌ **不可达** | —— |
| `refused`（两臂都被拒） | ✅ 可达 | ❌ **不构成** —— 其设计用途是「两拒绝文案**并排对比**」，而两臂相同 ⇒ 也恒同 |

⇒ 该函数的**分辨力整体归零**：它的三个输出里，没有一个还能区分两个引擎。

## 4. 为什么不修（规模守护，`charter.md` `D2`）

`D2`：**当场修**仅在 ①构成阻塞 ②工作量小 **两条同时**满足时允许。
本项 **①不满足**（器械、非产品，不阻塞 `LR-4` 收口）⇒ **登记不修**。

⚠️ 另一条理由：**在收口批里改器械行为，等于给一次文书批新增一个未验收的行为面** ——
这与 `docs/issue-cli-package-entry-check-2026-09-18.md` 的处置同理（该处在删除批里
「只立案、不顺手修」，理由正是「修它等于给一次删除批新增一个拒绝行为」）。

✅ **风险已被部分声明**：该文件的 docstring（`LOST MOST OF ITS OBJECT IN G-6c`）已写明
「Running it today measures nothing meaningful: the remaining edge duplicates the probe」。
⚠️ **但声明位置与产出位置分离** —— 读输出的人看不到它，且**没有任何门禁或护栏**
阻止 `agreed` 被当作证据引用。这正是本单成立的理由。

## 5. 复现命令（三条，全部只读）

```sh
# ① 两臂同源的判据（有区分力的那条）
PINI_INTERP_ENGINE=definitely-not-an-engine .build/debug/pini run examples/package-demo; echo "rc=$?"

# ② 过期表述的位置
rg -n "both engines" tools/three-edge-union.py

# ③ 同族未修：写死的默认二进制路径
rg -n "pini-build/arm64-apple-macosx" tools/three-edge-union.py
```

⚠️ **本机必须用 `rg`**：`grep` 被 PATH 存根接管、**静默返回空**（本批实测两例假阴性）。

## 6. 关联

- `docs/hir-criteria-gap-ledger.md` —— 该器械的**立项条目** `CG-03`（口径为「判据看不见」；
  ⚠️ **本单对象不同**：这里是「器械产出无内容的读数」，故不合并）
- **⚠️ 与 `G-6c-2` 已记内容的区分**（本单**不是**重复件）：`G-6c-2` 登记的是
  「该器械**已失去对象 ⇒ 不重构**」—— 那是一条**决策**；本单登记的是
  「**该决策未附带护栏**：产出口仍会报 `agreed`，而它不构成等价证据」—— 那是**决策的漏洞**。
  两者可并存：前者说「不去修它」，后者说「至少别让它报绿」。
  ✅ 已如实承认：该器械的 **docstring 已声明**「Running it today measures nothing meaningful」
  —— 本单不声称「无人知晓」，只声称「**声明在文件头，读数在输出里，两者之间没有护栏**」。
- `docs/issue-hir-parity-probe-default-bin-path-2026-09-18.md` —— **同族已修**件（默认二进制路径）
- `docs/spec/issue/archive/issue-interpreter-hir-unification-2026-09-07.md` —— `LR-4` 定义出处
- `docs/issue-lr4-p5-closeout-plan-2026-09-18.md` —— 本单是 `P5` 判据 4 全扫的遗留产物

## 7. 处置选项（留待点名，本单不代裁）

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** | **删该器械**（其对象已大部分消失，剩余边与探针重复） | ⚠️ 会让台账 `CG-03` 的条目**指向不存在的东西** —— 正是该台账被建立起来要避免的失败（docstring 自陈） |
| **B** | **保留 + 把包通道降级为 `UNMEASURED`**（它今天确实量不到东西） | 改动最小、最诚实；代价 = 该入口的「总判定」永久不再是绿（但它**今天也不该是绿**） |
| **C** | 给包通道换一个**还有第二条臂的**判据（例如与 `pini check` 的诊断对照） | 最大；须重新设计判据，且 `pini check` **不执行**（见主计划 §8.1）⇒ 不能作执行等价的第二臂 |

**登记者的倾向（非裁决）**：**B**。理由是它与 `P5` 收口要建立的**读法纪律**同向 ——
「量不到就报量不到」，而不是报一个内容为空的绿。

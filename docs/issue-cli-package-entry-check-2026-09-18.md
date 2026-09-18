# Issue：`pini run <目录>` 不做入口一致性校验（**默认引擎路径上，自 P4 翻转起就是死的**）

> **日期**：2026-09-18｜**状态**：**Open**（只登记不修）
> **发现于**：`G-6c`（删 AST 走查本体）的开工前勘测 —— 核查「删除会不会顺手带走一项用户可见能力」
> **性质**：**用户可见校验在默认路径上缺席**；删除 AST 走查**不造成**它，但让「另一条路径还查」也不再成立
> **归属**：**独立小批**（不属 `G-6c`）—— 见 §5 的裁决依据

## 0. 一句话

清单声明了入口（`[[bin]].entry` / `[lib].entry`）时，`pini run <目录>` **应当**校验「`main` 是否定义在声明入口里」。
该校验有两份实现（一份在 AST 解释器、一份在 `ProgramRunner`），而 CLI 只把 `entryFiles` 注入了**前者**。
默认引擎自 P4 翻转（2026-09-16）起是 HIR ⇒ **这条校验在默认路径上已经不执行了**，
而 `G-6c` 删掉解释器那条路径后，「至少显式回落时还查」也不复存在。

## 1. 实测（2026-09-18，`G-6c` 勘测，起点 `31f6889`）

夹具：一个入口声明与代码不一致的包 —— `pini.toml` 声明 `[[bin]].entry = "other.pini"`，
而 `main` 定义在 `main.pini`、`other.pini` 只有一个未被调用的 `helper`。

```bash
# 1) 默认引擎（hir）
$ pini run <该目录>
42
$ echo $?
0                       # ⛔ 不一致被静默放过

# 2) 显式 ast 回落（该路径已在 G-6c 删除）
$ PINI_INTERP_ENGINE=ast pini run <该目录>
Error: Runtime Error [E5-018]
  at <该目录>/main.pini:1:1
入口配置与代码不一致：清单声明入口为 <该目录>/other.pini，但 main 定义在 <该目录>/main.pini
                        # ✅ 校验如设计生效
```

⇒ **同一份输入、同一条命令，两个引擎给出不同结论**；默认的那个放过。

## 2. 根因（符号级）

| 环节 | 事实 |
|---|---|
| CLI 目录分支 | 构造 `Interpreter` 并设 `interpreter.entryFiles = Set(manifest.entryPoints.map { … })` —— **只注入 AST 臂** |
| HIR 包入口 | `runHIRPackageEngine(package:moduleRoot:typeInference:ffiConfig:argv:)` **没有 `entryFiles` 参数**，也不做该校验 |
| 执行器 | `HIRExecutor` 无入口一致性检查（它只执行一棵已降载的树） |
| 校验本体 | `Interpreter.checkEntryConsistency()` 与 `ProgramRunner.checkEntryConsistency(_:)` / `(in:)` —— **两份实现**；后者是 `private` |
| 谁能作证 | `CLIDirectoryTests` 的 4 条 entry 用例驱动的是 **`ProgramRunner`**（不是 CLI），所以「校验本身可用」有测试，而「CLI 走哪条路」没有 |

⚠️ 该检查的**不存在**与「测试全绿」长期并存，因为**没有任何一条测试断言 CLI 的包路径会拒绝它**。

## 3. 与 `G-6c` 的因果关系（**订正一处容易写错的归因**）

- ❌ **不是**「删除 AST 走查导致校验消失」——默认路径上它**早已不执行**（默认即 HIR）。
- ✅ 删除的真实影响是：**「显式回落时还查」这条退路也没了**，于是这个洞从「默认漏、回落补」变成「全漏」。
- ⇒ 因此**不在 `G-6c` 顺手修**：修它会在删除批里引入一次**新的拒绝行为**（现有包/夹具里若有 entry 声明与 main 不符，会当场变红），
  那是**行为变更**而非删除的收尾，须单独成批并单独给判据。

## 4. 处置候选（不预设）

| 选项 | 动作 | 代价 |
|---|---|---|
| **A** | 把校验**单源化**到 `ProgramRunner`（它是唯一还活着的实现），CLI 的包路径改为经它执行 —— 顺带恢复入口校验 | 中：CLI 包路径换执行入口，需实测 `argv` / `ffiConfig` / `programBase` 三项语义不变；且会**新增拒绝面**（须先扫 `examples/` 与 `Tests/` 的带 entry 声明的包） |
| **B** | 只把校验**上提**为可复用入口（如 `RuntimeOps` 或 `FileLoader` 侧），CLI 在 `runHIRPackageEngine` 前显式调用一次 | 小：约 15 行；不换执行入口，风险面最小 |
| **C** | 显式**退役**该能力：删除 `entryPoints` 的校验语义，只保留清单解析 | 小，但**用户可见能力净减** ⇒ 须走 `spec §1.3` 登记 |

**建议 B**（先恢复行为、不动执行路径），并在该批里补一条**CLI 面**的验收用例
（现有的 4 条都在 `ProgramRunner` 上，正是本洞长期不被发现的原因）。

## 5. 不做范围

- **只登记不修**：本单不改任何源码。开工须单独点名。
- **不在 `G-6c` 内处置**：理由见 §3 —— 它会引入新拒绝行为，属独立的行为变更批。
- **不删 `manifest.entryPoints`**：清单解析本身没问题，问题只在「谁校验」。

## 6. 判据（怎么算完成）

| # | 判据 | 测法 |
|:--:|---|---|
| 1 | CLI 包路径**会拒绝**入口不一致 | §1 的夹具 + 默认命令 ⇒ 非零退出且消息含声明入口与 `main` 实际所在文件 |
| 2 | CLI 包路径**不误拒**合法声明 | §1 夹具改为 `entry = "main.pini"` ⇒ 照常输出 |
| 3 | 该行为**有 CLI 面见证** | `CLIDirectoryTests` 或同级新增至少一条**经 CLI**（非经 `ProgramRunner`）的用例 |
| 4 | 单源化后**零新增红** | 全量回归**逐条集合相等** |

## 7. 复现方式

```bash
cd <repo>
d=$(mktemp -d)
printf '[package]\nname = "demo"\n\n[[bin]]\nname = "app"\nentry = "other.pini"\n' > "$d/pini.toml"
printf 'main() -> ():\n    print(42)\n    return\n' > "$d/main.pini"
printf 'helper() -> ():\n    return\n' > "$d/other.pini"
pini run "$d"            # 默认：打印 42、rc=0（应为拒绝）
```

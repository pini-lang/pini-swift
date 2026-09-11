# Issue：三通道执行等价探针的自围堵缺陷（sweep 死锁 + 挂死被记为前端拒绝）

- 状态：**Closed（2026-09-11 立案并同批修复；修复与验证见下）**
- 发现来源：M6c 判据升级后的实测复核（用户提示「lli 进程没有正常结束」后追查）
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md`（M6c 判据批）、
  `tools/hir-parity-probe.py`（修复落点）、`tools/compare-sweeps.py`（同批补判据）

## 现象

一次针对 `Tests/PiniTests/CodeGen/IRGeneratorTests` + `HIRTests` 的定向 sweep
**永不返回**：探针进程存活数十分钟、零输出推进；同时一个 `lli` 进程持续空转，
`/tmp` 里留下孤儿 IR 文件。

三件事同源，且都不产生任何错误信息：

1. **死锁**：探针卡在超时后的排空调用上，不返回、不报错、不落任何 verdict。
2. **进程泄漏**：`lli` 不被杀掉。`pini run-llvm` 以 `Process.waitUntilExit()` 等待
   `lli`，而 `pini` 被 SIGKILL 后 **`defer` 不执行**，临时 IR 文件留在磁盘上。
3. **判定丢失**：挂死通道的退出码是 124，被分类规则里的「旧后端也拒绝 → 前端拒绝」
   一条先行吞掉，于是**挂死看起来像前端问题**，完全不出现在阻塞计数里。

指纹取证（修复前 `/tmp` 残留 15 个孤儿 IR，两组同源 md5 交替出现、间隔精确 30s）
反推出更早的 sweep 早已发生同类挂死：**那些运行的结果里 `l_rc = 124` 的行全部落在
`FRONTEND_FAIL` 桶内**，从未被人看见。

## 根因（三层，逐层都产生过一个假信号）

### 第 1 层：超时后的排空调用无界

`proc.communicate(timeout=...)` 之后的**第二次** `communicate()` 未设超时。而组杀
并不保证能杀掉 `lli`——实测 `pini` 已死（进程表无 `pini run-llvm`）而 `lli` 存活，
说明 `lli` 不在探针创建的进程组里（Foundation 的 `Process` 给子进程另建了组）。
存活的 `lli` 继承着 stdout/stderr 管道，于是排空**永久阻塞**。这是最严重的一层：
工具在此状态下完全沉默，使用者只能看到「没有进展」。

### 第 2 层：超时被当成前端拒绝

分类规则先判「旧后端非零退出 → `FRONTEND_FAIL`」，再判其它。而挂死正是非零退出
（124），于是这条规则先命中，挂死被记为「前端问题、非后端缺口」。判据对挂死
**结构性失明**——与旧 emit-only 判据对执行差异失明是同一类错误，只是藏在别的规则里。

### 第 3 层：收割器若按 `/bin/ps` 写会静默失效

修复过程中实测：本会话沙箱**拒绝执行 `/bin/ps`**（bash 与 python 均报
`Operation not permitted`）。若收割器以 `ps` 读进程表，它会静默返回空集、
「成功收割 0 个」——修复看起来生效、实际什么都没杀。这正是本工具立项要消灭的假绿，
故收敛到 `pgrep -fl`（可用），并在不可用时**明说 containment UNAVAILABLE**。

## 修复

`tools/hir-parity-probe.py`：

1. **有界排空**：超时后先组杀，再以 `DRAIN_TIMEOUT`（5s）为限排空；仍超时则关管道、
   `kill()`、限时 `wait()`。永不无界阻塞。
2. **按 argv 收割孤儿**：`pgrep -fl lli` → 解析出 argv 携带 `/tmp/pini_*.ll` 的
   进程（先判程序名，避免误伤只是在命令行里提到 `lli` 的 shell）→ SIGKILL
   （被拒则退化为 `pkill -9 -f <该 IR 路径>`）→ 删除对应 IR 文件。每次超时当场收割
   一次，收尾再收割一次。
3. **超时判定前移**：新增 `TIMEOUT_ALL`（三通道皆挂 = 程序自身设计内死循环）、
   `TIMEOUT_INTERP`、`TIMEOUT_LEGACY`、`GAP_HANG`（旧后端正常终止、HIR 挂死，
   **计入翻转阻塞**）。墙体时间判定先于前端拒绝判定。
4. **自证不撒谎**：收尾复查存活 `lli`，有则打印 `STILL ALIVE` 并**以退出码 1 结束**
   ——存活进程是工具失败，不是夹具结论；另报告累计收割数（只报收尾那一次会印出
   「0 killed」而 `/tmp` 同时是干净的，自相矛盾）。
5. **自清理**：删除本轮新建、且无存活 `lli` 持有的杂散 IR 文件。
6. 订正 `run()` 内一句**已被实测证伪**的旧注释（原称「组杀能同时带走两者」）。

`tools/compare-sweeps.py`：`BLOCKERS` 元组补入 `GAP_HANG`，否则翻转批的隔离证明
会漏算新引入的挂死。

## 验证（A/B 同夹具，`--filter ContinueInWhile`）

复现夹具：`Tests/PiniTests/CodeGen/IRGeneratorTests/testContinueInWhile.pini`

```
var i = 0
while i < 5:
    continue
    i = i + 1
```

`continue` 在递增之前，**按程序自身语义就是死循环**，故三通道皆挂属预期。

| | 修复前 | 修复后 |
|---|---|---|
| 耗时 | **永不返回** | **41s** |
| 判定 | `FRONTEND_FAIL`（假） | `TIMEOUT_ALL`（真） |
| 存活 `lli` | 1 个持续空转 | **0** |
| 孤儿 IR | +1 | **0** |
| 退出码 | —（被人工中断） | 0 |

全量重测（7 根 / 389 夹具）：**763s，退出码 0，收尾复查 0 存活 `lli` / 0 孤儿**；
摘要记 `2 lli killed in total, 0 of them at exit`（两次超时当场收割）。

## 影响（含对已发布数的订正）

1. **M6c 报告的「真阻塞 13 → 7」订正为 13 → 8。** 多出的 1 例是
   `Tests/PiniTests/RuntimeBackendTests/testNestedCOWIRContract_2.pini`：它**从未计入
   13 的基线**，是判据补入 stderr 形状后才从 `OK_HARNESS` 暴露的。C4 的提交说明明写
   「4 change, all intended」并列出该例，即**实现按 4 例改动、计数仍写 3 例**。
2. **`FRONTEND_FAIL` 43 → 42**：全量重测显示恰好 1 例从该桶移出（即上面的复现夹具）
   ——这正是「隐藏挂死」在旧桶里的直接证据。
3. **旧分母不完整**：`IRGeneratorTests` / `HIRTests` 两根此前从未被探针跑通（死锁所致），
   本批首次纳入。新覆盖 155 例（OK 126 / FRONTEND_FAIL 19 / CHANGE_F64 5 /
   OK_HARNESS 2 / HARNESS_DEPENDENT 1 / CHANGE_OTHER 1 / TIMEOUT_ALL 1）。
4. **隔离证明**：在 234 个新旧两把尺都量过的夹具上，**verdict 变动 0 例**——围堵改动
   除打开此前不可达的根之外，未扰动任何既有结论。

## 遗留（不在本项范围）

1. **探针无自动化自测**：本项的回归靠 `testContinueInWhile` 作复现夹具 + 收尾自证
   （存活即退出码 1）。按纪律未为工具另建测试基建。
2. **宿主侧形态不改**：`pini run-llvm` 以 `waitUntilExit` 等待子进程，父进程被杀即留孤儿，
   这是父子进程设计的固有属性，非宿主缺陷。
3. **`pgrep` 依赖**：若无 `pgrep`，围堵降级为「只清杂散 IR + 明说不可用」，
   不假装成功。

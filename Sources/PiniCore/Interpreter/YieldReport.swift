import Foundation

// MARK: - 让出的可观测通道（解释器后端）

/// 闸门：**仅在环境变量置位时**输出，未置位 ⇒ **零输出**。
///
/// ⛔ 性质与对侧逐字相同：它是**测试器械专用**的观测面 —— **不是** ABI、**不是**诊断通道、
/// **不是**给用户的功能。本仓另有一笔**已登记的**「诊断通道」缺口，**二者不是一件事**；
/// 这条声明的作用同样是防止有人把它当成那个缺口的补丁。
///
/// ⚠️ **与对侧的一处刻意差异在挂点，不在形态**：对侧的读数属于发射腿，挂在**进程退出钩子**上；
/// 这一处挂在**运行入口返回**时。理由不是偏好 —— 那个钩子在发射腿那边**曾长期不生效**
/// （全局 `let` 惰性初始化且无读者），故其形态**不得照抄**（`ADR-002` §3.3 代价表的明文约束）。
/// 闸门、环境变量、输出行**逐字节对齐** ⇒ 两份读数是**同一个量**。
private let interpreterYieldReportEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["PINI_YIELD_REPORT"] else { return false }
    return !(raw.isEmpty || raw == "0")
}()

/// 打**一行**汇总到 stderr —— 形态与发射腿那行逐字节一致。
///
/// ⚠️ **计数由让出动作本身驱动**：`GCDScheduler.noteYield()` 不看闸门
/// （闸门只决定**打不打印**，不影响运行时行为）⇒ 未置位时程序照常让出，只是没有读数。
/// ⛔ 这也意味着「未置位 ⇒ 让出次数 = 0」**不成立**，读不到不等于没发生。
///
/// ⚠️ 计数住在**进程级单例**上 ⇒ 本读数的口径是「**本进程累计**」，
/// 与对侧（进程退出时打一行）同口径：一次 `run` 一个进程时，两者都是「本程序让出过几次」。
func reportInterpreterYieldsIfGated() {
    guard interpreterYieldReportEnabled else { return }
    let count = GCDScheduler.shared.yieldedTaskCount
    FileHandle.standardError.write(
        Data("pini-yield-report: bodies-suspended=\(count)\n".utf8))
}

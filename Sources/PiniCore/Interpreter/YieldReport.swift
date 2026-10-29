import Foundation

// MARK: - 让出的可观测通道（解释器后端）

/// 让出读数的闸门：仅环境变量置位时输出，未置位即零输出。属测试器械专用观测面，不是 ABI、也不是诊断通道。
/// 与发射腿同一环境变量、同一输出行，故两份读数是同一个量。
/// 差异只在挂点：发射腿挂在进程退出钩子，这里挂在运行入口返回。
private let interpreterYieldReportEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["PINI_YIELD_REPORT"] else { return false }
    return !(raw.isEmpty || raw == "0")
}()

/// 打一行汇总到 stderr，形态与发射腿那行逐字节一致。
/// 计数由让出动作本身驱动：`noteYield()` 不看闸门，闸门只决定打不打印，故未置位时程序照常让出，只是没有读数。
/// 计数住在进程级单例上，口径是「本进程累计」——读不到不等于没发生。
func reportInterpreterYieldsIfGated() {
    guard interpreterYieldReportEnabled else { return }
    let count = GCDScheduler.shared.yieldedTaskCount
    FileHandle.standardError.write(
        Data("pini-yield-report: bodies-suspended=\(count)\n".utf8))
}

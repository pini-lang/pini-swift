import Foundation

/// 并发能力的分层（`DE-1` §6.1 形态）。
///
/// ⛔ **一层套一层，不是矩阵** —— 嵌套关系**有方向**，这正是「矩阵」不成立的理由：
/// 有让出 ⇒ 必有调度；**反过来不成立**（无线程 ⇒ 无让出，**但调度仍在**）。
///
/// ## ⚠️ 位值：**本批定案**（`DE-1` 只定了形态、没定位值）
///
/// `DE-1` §3.4 定下 `bk_capabilities() -> u32` 的**形态**是位图，而**位值本身是 ABI 的一部分**
/// —— `DE-3` 建 C ABI 运行时时必须照它发。各后端各定一套的话，`DE-4` 的契约参照就没有共同基准，
/// 所以在此定案并登记（见提案件 `DE-2b-3` 执行记录）。
public enum ConcurrencyTier: UInt32, Sendable, CaseIterable {
    /// **L0 调度** —— 派发任务与阻塞 join。**不依赖线程**，因而是唯一无条件可用的层。
    case dispatch = 1
    /// **L1 让出** —— 让出当前任务时**真的释放**当前 OS 线程，并从精确恢复点续跑。
    /// 依赖 L0 **且有线程**。
    case yield = 2
    /// **L2 抢占** —— 时间片 / 分层抢占。依赖 L1 **且多线程**。
    /// ⛔ **一律不授予**（裁定 29：登记不实现 —— 语言远未成熟时任何等级都承诺不出来）。
    case preemption = 4
}

/// 后端能力的**自述**（`DE-1` §3.4 与 §6 在解释器后端的对应物）。
///
/// ## 为什么它是一个**值**而不是一句注释
///
/// 「本后端能不能让出」如果不是可读的，那么「后端兑现不了让出时 `await` 该怎么办」
/// 就只存在于实现者的记忆里。而它有一条**规范级的 MUST 纪律**要守（`DE-1` §6.2 纪律 3：
/// **无合格版本则降级，不失败**）⇒ 纪律要能被执行路径读到，否则它只是纸上的。
/// 本类型就是那条纪律的读数面。
public struct ConcurrencyCapabilities: Sendable, Equatable {
    /// 位图。与 `bk_capabilities()` 的返回值**同形**（`DE-1` §3.4）。
    public let bitmap: UInt32

    public init(bitmap: UInt32) { self.bitmap = bitmap }

    /// 本后端是否支持某一层。
    public func supports(_ tier: ConcurrencyTier) -> Bool {
        bitmap & tier.rawValue != 0
    }

    /// 本批次位对应的层名（诊断 / 参照输出用，顺序照分层从低到高）。
    public var tierNames: [String] {
        ConcurrencyTier.allCases.filter { supports($0) }.map { "\($0)" }
    }

    /// 解析一次 —— ⛔ **不 throw**，这是纪律 3 的落点（**降级，不失败**）。
    ///
    /// 为什么参数是「有没有线程」而不是别的：L1 的**唯一**前提就是「能不能释放当前 OS 线程」。
    /// 无线程的宿主（单线程执行器 / 某些 WASM 目标）不是错误配置，是一种**合规的**后端 ⇒
    /// 它自述为「只有 L0」，于是 L1 自动不可用、`await` 降级为占用，而**任何东西都不报错**。
    ///
    /// ⚠️ **L2 不参与解析**：裁定 29 说登记不实现 ⇒ **任何后端都不许宣称它**。
    /// 这里刻意没有对应分支 —— 免得将来有人以为「多给一个参数就能开抢占」。
    public static func resolve(threadsAvailable: Bool) -> ConcurrencyCapabilities {
        var bits = ConcurrencyTier.dispatch.rawValue
        if threadsAvailable { bits |= ConcurrencyTier.yield.rawValue }
        return ConcurrencyCapabilities(bitmap: bits)
    }
}

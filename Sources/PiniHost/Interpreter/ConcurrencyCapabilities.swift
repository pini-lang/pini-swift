import Foundation

/// 并发能力的分层：一层套一层而非矩阵——有让出必有调度，反过来不成立（无线程则无让出，但调度仍在）。
/// `bk_capabilities() -> u32` 的形态是位图，而位值本身是 ABI 的一部分，各后端须照此发，否则契约参照就没有共同基准；
/// 故位值在此定案登记，后端不得自行另定一套。
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

/// 后端能力的自述，也是「无合格版本则降级，不失败」这条纪律的读数面。
/// 能力若不是可读的值，「兑现不了让出时 `await` 该怎么办」就只存在于实现者的记忆里；
/// 纪律要被执行路径读到才算数，故本类型是它的载体而非一句注释。
public struct ConcurrencyCapabilities: Sendable, Equatable {
    /// 位图。与 `bk_capabilities()` 的返回值**同形**。
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

    /// 解析一次，不 throw：这是「降级而不失败」的落点。参数只问有没有线程，因为 L1 的唯一前提是能释放当前 OS 线程。
    /// 无线程宿主（单线程执行器 / 某些 WASM 目标）是合规后端，自述为只有 L0：L1 自动不可用、`await` 降级为占用而不报错。
    /// L2 不参与解析——登记不实现，任何后端都不许宣称它；这里刻意没有对应分支，免得以为多给一个参数就能开抢占。
    public static func resolve(threadsAvailable: Bool) -> ConcurrencyCapabilities {
        var bits = ConcurrencyTier.dispatch.rawValue
        if threadsAvailable { bits |= ConcurrencyTier.yield.rawValue }
        return ConcurrencyCapabilities(bitmap: bits)
    }
}

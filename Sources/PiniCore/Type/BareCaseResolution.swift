import Foundation

/// 裸名 case 消歧的静态决议交接：checker 在期望类型命中候选的构造位记录「调用点位置 → 父枚举」，
/// 解释器对歧义名的裸名构造查此表——查到按静态决议构造，查不到报「需限定形式」。
/// 运行期不做任何动态猜测（类型确定成员原则）。
public enum BareCaseResolutionRegistry {
    private static let lock = NSLock()
    /// 可变表：三个入口都在 `lock` 内读写；免隔离是交权给锁，不是声称它不可变。
    nonisolated(unsafe) private static var sites: [String: String] = [:]

    private static func key(_ loc: SourceLocation) -> String {
        return "\(loc.fileName):\(loc.line):\(loc.column):\(loc.endLine):\(loc.endColumn)"
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        sites = [:]
    }

    public static func record(_ loc: SourceLocation, parent: String) {
        lock.lock()
        defer { lock.unlock() }
        sites[key(loc)] = parent
    }

    public static func parent(at loc: SourceLocation) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sites[key(loc)]
    }
}

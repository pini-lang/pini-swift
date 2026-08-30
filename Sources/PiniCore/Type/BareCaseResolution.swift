import Foundation

/// ADR-026 D1（静态收敛版）：歧义 case 裸名构造的静态决议交接。
/// checker 在期望类型命中候选的构造位记录「调用点位置 → 父枚举」；
/// 解释器对歧义名的裸名构造查此表——查到即按静态决议构造，查不到即报
/// 「需限定形式」。运行期不做任何动态猜测（类型确定成员原则）。
public enum BareCaseResolutionRegistry {
    private static var sites: [String: String] = [:]

    private static func key(_ loc: SourceLocation) -> String {
        return "\(loc.fileName):\(loc.line):\(loc.column):\(loc.endLine):\(loc.endColumn)"
    }

    public static func reset() {
        sites = [:]
    }

    public static func record(_ loc: SourceLocation, parent: String) {
        sites[key(loc)] = parent
    }

    public static func parent(at loc: SourceLocation) -> String? {
        return sites[key(loc)]
    }
}

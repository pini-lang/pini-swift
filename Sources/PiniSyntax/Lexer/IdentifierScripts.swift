import Foundation

/// 标识符的脚本归属：只区分拉丁、西里尔与希腊三个高风险脚本，其余一律按其它。
/// 数据取自随包提交的 UCD 脚本文件，运行期不查宿主系统的 Unicode 版本。
enum IdentifierScripts {

    static let latin = 1
    static let cyrillic = 2
    static let greek = 3

    /// 区间按起点升序；空表说明资源没加载上，判定据此退化为「一律不混写」。
    private static let ranges: [(lo: UInt32, hi: UInt32, script: Int)] = loadRanges()

    /// 已加载的区间数，供测试确认表不是空的。
    static var rangeCount: Int { ranges.count }

    /// 码点的脚本号：命中区间答 1 至 3，其余答 0。
    static func script(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            if value < range.lo {
                high = mid - 1
            } else if value > range.hi {
                low = mid + 1
            } else {
                return range.script
            }
        }
        return 0
    }

    /// 标识符里出现过的高风险脚本集合；同一脚本重复出现只算一次。
    static func highRiskScripts(in name: String) -> Set<Int> {
        var found: Set<Int> = []
        for scalar in name.unicodeScalars {
            let value = script(of: scalar)
            if value != 0 { found.insert(value) }
        }
        return found
    }

    /// 混写判定：两个及以上不同的高风险脚本同时出现。
    static func isMixed(_ name: String) -> Bool {
        return highRiskScripts(in: name).count >= 2
    }

    /// 只读脚本资源。文件缺失或读不懂时返回空表，不抛错：编译器不该因数据缺失而崩溃。
    private static func loadRanges() -> [(lo: UInt32, hi: UInt32, script: Int)] {
        guard
            let url = Bundle.module.url(forResource: "scripts-15.1.0", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        var loaded: [(lo: UInt32, hi: UInt32, script: Int)] = []
        for raw in text.split(separator: "\n") {
            let content =
                raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let line = content.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let fields = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }
            let script: Int
            switch fields[1] {
            case "Latin": script = latin
            case "Cyrillic": script = cyrillic
            case "Greek": script = greek
            default: continue
            }
            let bounds = fields[0].components(separatedBy: "..")
            guard let lo = UInt32(bounds[0], radix: 16) else { continue }
            let hi = bounds.count > 1 ? (UInt32(bounds[1], radix: 16) ?? lo) : lo
            loaded.append((lo, hi, script))
        }
        loaded.sort { $0.lo < $1.lo }
        return loaded
    }
}

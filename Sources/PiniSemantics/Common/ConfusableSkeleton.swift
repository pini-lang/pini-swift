import Foundation

/// 形近字符骨架（UTS 39）：NFD、逐标量折到形近代表、再 NFD。只用于诊断，不参与符号查找。
/// 数据与自举侧同一份文件，查表口径同为「单码点源行」。
enum ConfusableSkeleton {

    /// 单码点映射；空表说明资源没加载上，骨架退化为规范分解。
    private static let table: [UInt32: [UInt32]] = loadTable()

    /// 已加载的映射条数，供测试确认表不是空的。
    static var entryCount: Int { table.count }

    /// 名字的骨架。ASCII 名字不参与折叠，直接原样返回，省掉一次分解与查表。
    static func skeleton(of name: String) -> String {
        if name.unicodeScalars.allSatisfy({ $0.value < 128 }) { return name }
        var mapped: [Unicode.Scalar] = []
        for scalar in name.decomposedStringWithCanonicalMapping.unicodeScalars {
            if let target = table[scalar.value] {
                for code in target {
                    if let converted = Unicode.Scalar(code) { mapped.append(converted) }
                }
            } else {
                mapped.append(scalar)
            }
        }
        let joined = String(String.UnicodeScalarView(mapped))
        return joined.decomposedStringWithCanonicalMapping
    }

    /// 只读混淆资源；缺失时返回空表，不抛错。
    private static func loadTable() -> [UInt32: [UInt32]] {
        guard
            let url = Bundle.module.url(forResource: "confusables-15.1.0", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var loaded: [UInt32: [UInt32]] = [:]
        for raw in text.split(separator: "\n") {
            let content =
                raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let line = content.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let fields = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }
            let source = fields[0].split(separator: " ").compactMap { UInt32($0, radix: 16) }
            let target = fields[1].split(separator: " ").compactMap { UInt32($0, radix: 16) }
            guard source.count == 1, !target.isEmpty else { continue }
            loaded[source[0]] = target
        }
        return loaded
    }
}

/// 组合附加符号的四个区块：只允许作标识符续字符，不得作首字符。
/// 区块与语言参考的后续字符条款一致，也与 Swift 词法规则的组合标记条目同源。
enum CombiningMarks {

    /// 该标量是否属于组合附加符号。
    static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F:
            return true
        default:
            return false
        }
    }

    /// 字素簇的首个标量；空簇返回 nil。
    static func leading(_ character: Character) -> Unicode.Scalar? {
        return character.unicodeScalars.first
    }
}

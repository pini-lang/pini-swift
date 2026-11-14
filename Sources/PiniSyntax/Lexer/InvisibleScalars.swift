/// 源码里不该出现的不可见标量：零宽字符、双向控制、变体选择符与格式字符。
/// 按区段列举而不查宿主类别表，区段外新增的格式字符保守放行；命中即由词法层拒绝。
enum InvisibleScalars {

    /// 该标量是否属于禁止出现在源码中的不可见字符。
    static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0x180E, 0xFEFF, 0x110BD, 0x110CD:
            return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F:
            return true
        case 0xFE00...0xFE0F, 0xFFF9...0xFFFB, 0x1D173...0x1D17A:
            return true
        case 0xE0000...0xE007F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    /// 双向控制字符：Unicode `Bidi_Control` 属性的全部成员。
    /// 标识符里由 `isForbidden` 直接拒绝；注释与字符串里只给警告——那两处是文字，不是程序结构。
    static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    /// 字素簇里第一个被禁止的标量；整簇干净时返回 nil。
    /// 组合附加符号不在禁止之列：NFD 拼写的重音字母正是基字加附加符号。
    static func firstForbidden(in character: Character) -> Unicode.Scalar? {
        for scalar in character.unicodeScalars where isForbidden(scalar) {
            return scalar
        }
        return nil
    }

    /// 码点的展示形式，供诊断消息使用：至少四位、大写十六进制。
    static func label(_ scalar: Unicode.Scalar) -> String {
        return label(scalar.value)
    }

    /// 与标量版同规，供只知道码点数值的调用点使用。
    static func label(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

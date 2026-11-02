import Foundation

/// C 边界上的标识符转写：Pini 名字可以是 UTF-8，C 标识符只收 ASCII。
/// ASCII 字母数字与下划线原样保留，其余码位写成 `_u` 加 6 位大写十六进制。
/// 6 位定宽保证可解码；与字面 `_uXXXXXX` 的撞名由导出期拒绝，不靠转义消歧。
public enum CName {
    public static func escape(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if isASCIIAlnum(scalar) || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else {
                result += "_u" + String(format: "%06X", scalar.value)
            }
        }
        return result
    }

    /// 名字里有一段字面 `_u` 加 6 位十六进制 —— 与转义输出同形，解码时分不清，导出期须拒。
    public static func collidesWithEscape(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 8 else { return false }
        for start in 0...(scalars.count - 8) {
            guard scalars[start] == "_", scalars[start + 1] == "u" else { continue }
            let digits = scalars[(start + 2)...(start + 7)]
            if digits.allSatisfy({ isHexDigit($0) }) { return true }
        }
        return false
    }

    /// C 保留给实现的标识符：`__` 开头，或 `_` 加一个大写字母开头。
    /// 这些名字 C 编译器不会报错，但属于未定义行为，导出面不往外发。
    public static func isReserved(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.first == "_", scalars.count >= 2 else { return false }
        let second = scalars[1]
        return second == "_" || ("A"..."Z").contains(second)
    }

    private static func isASCIIAlnum(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9": return true
        default: return false
        }
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "A"..."F", "a"..."f": return true
        default: return false
        }
    }
}

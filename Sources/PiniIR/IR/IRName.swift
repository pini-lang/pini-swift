import Foundation

/// IR 标识符 mangle（IR 管线与遗留管线共享）：非 ASCII 标量 hex 编码为下划线前缀形式
/// （`点` → `_u70B9`）；不用 `String(format:)`，它 Linux 上并发降载时崩在 CVarArg 里。
/// 名字属于 IR：解释器按同一规则拼调度器方法名，两个通道由此得到同一个符号。
public enum IRName {
    public static func mangle(_ name: String) -> String {
        var needs = false
        for byte in name.utf8 where byte > 127 {
            needs = true
            break
        }
        if !needs { return name }
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar.value < 128 {
                result.append(Character(scalar))
            } else {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "_u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            }
        }
        return result
    }

    /// 本型方法的 IR 名。与实例方法 `方法__类型` 分道，顶层函数表里一名一义。
    public static func ownMethod(_ method: String, on type: String) -> String {
        "own__\(mangle(method))__\(mangle(type))"
    }
}

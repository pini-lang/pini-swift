import Foundation

/// IR 标识符 mangle（IR 管线与遗留管线共享的唯一实现源）：
/// 非 ASCII 标量 hex 编码为下划线前缀形式（`点` → `_u70B9`）。
/// 名字属于 IR 而非发射层：解释器按同一规则拼调度器方法名，两个通道由此得到同一个符号。
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
                result += "_u" + String(format: "%04X", scalar.value)
            }
        }
        return result
    }
}

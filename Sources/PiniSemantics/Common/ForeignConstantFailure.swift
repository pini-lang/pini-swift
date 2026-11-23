import Foundation

/// 宏常量求值的失败理由。未求值不是错误本身：它随声明记下，只在被读到时才转成诊断。
/// 六种理由各有出处：缺配置、头里没有、函数式、展不开、越界、缺计划。
public enum ForeignConstantFailure: Equatable, Sendable {
    case noHeaders
    case notDefined
    case functionLike
    case unparsable(text: String, detail: String)
    case outOfRange(value: String, type: String)
    case missingPlan

    /// 诊断里的理由句：读者据此决定补配置、写 shim 还是删声明。
    public var reasonText: String {
        switch self {
        case .noHeaders:
            return "没有可用的头文件：包里 `[ffi].headers` 为空，单文件模式没有 `pini.toml`"
        case .notDefined:
            return "头文件里没有这个宏"
        case .functionLike:
            return "它是函数式宏，Pini 不展开宏；要调用请写 C shim"
        case .unparsable(let text, let detail):
            return "展开后是 `\(text)`，不是常量表达式：\(detail)"
        case .outOfRange(let value, let type):
            return "值 \(value) 超出声明类型 \(type) 的范围"
        case .missingPlan:
            return "本机构建计划里没有它的求值结果；跑 `pini build` 生成计划"
        }
    }

    /// 计划里的理由码：只写枚举拼写，不写自然语言，换文案不改计划字节。
    public var planReason: String {
        switch self {
        case .noHeaders: return "noHeaders"
        case .notDefined: return "notDefined"
        case .functionLike: return "functionLike"
        case .unparsable: return "unparsable"
        case .outOfRange: return "outOfRange"
        case .missingPlan: return "missingPlan"
        }
    }

    /// 计划里的细节：只补各类理由特有的信息，缺省为空。
    /// 引号与换行会破坏计划的行结构，统一替换成空格；长度按诊断同一口径截断。
    public var planDetail: String {
        switch self {
        case .noHeaders, .notDefined, .functionLike, .missingPlan:
            return ""
        case .unparsable(let text, let detail):
            return Self.planSafe("展开后是 `\(text)`：\(detail)")
        case .outOfRange(let value, let type):
            return Self.planSafe("值 \(value) 超出声明类型 \(type) 的范围")
        }
    }

    /// 计划只存单行字符串：双引号换行制表符都替换，超出 160 字素截断并以省略号收尾。
    static func planSafe(_ text: String) -> String {
        let single =
            text
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard single.count > 160 else { return single }
        return String(single.prefix(160)) + "…"
    }
}

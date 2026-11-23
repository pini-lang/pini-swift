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
}

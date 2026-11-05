import Foundation

/// match 语句
/// matchStatement(value: Expression, cases: [MatchCase], defaultCase: Block?, location: SourceLocation)

/// match 模式（P5-4 HIGH-2）：枚举 case 名 / 整数字面量 / 浮点字面量 / 字符串字面量 / 布尔字面量 / 通配 `_`
/// 字面量带位置：AST 只存值，打印器要保住 `0xFF` 这类写法只能回词法旁路按位置取原文。
public enum MatchPattern: Equatable, CustomStringConvertible, Sendable {
    case enumCase(String)
    case intLiteral(Int, SourceLocation)
    case floatLiteral(Double, SourceLocation)
    case stringLiteral(String)
    case boolLiteral(Bool)
    case wildcard

    public var description: String {
        switch self {
        case .enumCase(let name): return name
        case .intLiteral(let n, _): return "\(n)"
        case .floatLiteral(let f, _): return "\(f)"
        case .stringLiteral(let s): return "\"\(s)\""
        case .boolLiteral(let b): return "\(b)"
        case .wildcard: return "_"
        }
    }
}

/// match case
public struct MatchCase: Equatable, ASTNode, Sendable {
    public let pattern: MatchPattern
    public let bindings: [MatchBinding]
    public let block: Block
    public let location: SourceLocation

    public init(pattern: MatchPattern, bindings: [MatchBinding], block: Block, location: SourceLocation) {
        self.pattern = pattern
        self.bindings = bindings
        self.block = block
        self.location = location
    }
}

/// match 绑定（命名或位置）
public struct MatchBinding: Equatable, Sendable {
    public let paramName: String?
    public let varName: String

    public init(paramName: String?, varName: String) {
        self.paramName = paramName
        self.varName = varName
    }
}

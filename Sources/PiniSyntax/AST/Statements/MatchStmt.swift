import Foundation


/// match 模式：枚举 case 名 / 整数字面量 / 浮点字面量 / 字符串字面量 / 布尔字面量 / 通配 `_`。
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

/// 枚举措辞：拼写形态决定打印器原样还原，语义层只认叶名，形态只用于校验与输出。
/// 裸名是过渡形态，解析器收窄后仅剩 `nil`、点号推断与限定名三种。
public enum EnumCaseSpelling: Equatable, Sendable {
    /// `case nil:`：关键字形态，语义等同 `Optional.none`。
    case nilKeyword
    /// `case 圆(...)`：裸名，父枚举由被匹配值类型决定。
    case bare
    /// `case .圆(...)`：点号推断，父枚举由被匹配值类型决定。
    case inferred
    /// `case 形状.圆(...)`：限定名，父枚举写明，须与被匹配值类型一致。
    case qualified(owner: String)

    /// 拼写前缀：`nil` 由模式名单独处理，这里只补点与父枚举。
    public var namePrefix: String {
        switch self {
        case .nilKeyword, .bare: return ""
        case .inferred: return "."
        case .qualified(let owner): return owner + "."
        }
    }
}

/// match 的单个分支：模式 + 绑定 + 子块。
public struct MatchCase: Equatable, ASTNode, Sendable {
    public let pattern: MatchPattern
    public let bindings: [MatchBinding]
    public let block: Block
    public let location: SourceLocation
    public let spelling: EnumCaseSpelling

    public init(
        pattern: MatchPattern,
        bindings: [MatchBinding],
        block: Block,
        location: SourceLocation,
        spelling: EnumCaseSpelling = .bare
    ) {
        self.pattern = pattern
        self.bindings = bindings
        self.block = block
        self.location = location
        self.spelling = spelling
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

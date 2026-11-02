import Foundation

/// 枚举块声明
public struct EnumDecl: Equatable, ASTNode, Sendable {
    public let name: String
    public let genericParams: [GenericParam]
    public let cases: [EnumCase]
    public let methods: [FuncDecl]
    /// `实现:` 声明的特征名。枚举体只收用例，故这一项由解析器在体内单独摘出。
    public let traits: [String]
    public let location: SourceLocation

    public init(
        name: String, genericParams: [GenericParam], cases: [EnumCase], methods: [FuncDecl],
        traits: [String] = [], location: SourceLocation
    ) {
        self.name = name
        self.genericParams = genericParams
        self.cases = cases
        self.methods = methods
        self.traits = traits
        self.location = location
    }
}

/// 枚举用例
public struct EnumCase: Equatable, ASTNode, Sendable {
    public let name: String
    public let associatedParams: [AssociatedParam]
    public let location: SourceLocation

    public init(name: String, associatedParams: [AssociatedParam], location: SourceLocation) {
        self.name = name
        self.associatedParams = associatedParams
        self.location = location
    }
}

/// 枚举关联参数（可选命名 + 类型 + 可选默认表达式）
public struct AssociatedParam: Equatable, Sendable {
    public let name: String?
    public let type: TypeAnnotation
    /// 可选默认表达式（如字面量 `0`）。仅在枚举 case 关联值位置求值，供构造期按默认补位。
    public let defaultValue: Expression?

    public init(name: String?, type: TypeAnnotation, defaultValue: Expression? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }
}

import Foundation

/// 给定块声明 `[名称|given]`：带字段初值的具名复合类型，其默认实例可被 `using` 参数隐式取用。
/// 与对象声明同形（字段 + 特征），但字段必须带初值——默认实例正由这些初值构造，缺初值则 `using` 无处取用。
/// `given` 不入关键字表：它只在 `|` 右侧的修饰符位，与 `|foreign`/`|import`/`|export` 同走标识符白名单。
public struct GivenDecl: Equatable, ASTNode {
    public let name: String
    public let genericParams: [GenericParam]
    public let fields: [FieldDecl]
    public let methods: [FuncDecl]
    /// `实现: T` 在解析期即被摘出字段表（与 `ObjectDecl` 同路径）。
    public let traits: [String]
    public let location: SourceLocation

    public init(
        name: String,
        genericParams: [GenericParam] = [],
        fields: [FieldDecl],
        methods: [FuncDecl] = [],
        traits: [String] = [],
        location: SourceLocation
    ) {
        self.name = name
        self.genericParams = genericParams
        self.fields = fields
        self.methods = methods
        self.traits = traits
        self.location = location
    }
}

import Foundation

/// 给定块声明（ADR-001 · `[名称|given]`）
///
/// 给定块 = 带字段初值的具名复合类型，其**默认实例**可被 `using` 参数隐式取用。
/// 与对象声明同形（字段 + 特征），但字段**必须带初值**——「默认实例」正是由这些
/// 初值构造出来的，缺初值的字段会让 `using` 无处取用（该约束的落地检查属后续批次）。
///
/// 文法（与 `object-decl` 同形，仅块头修饰符不同）：
/// ```
/// given-decl ::= '[' IDENT '|given' ']' given-body;
/// given-body ::= (field-decl | '实现' ':' IDENT)*;   (* 方法与类型体同规：移至扩展块 *)
/// ```
///
/// `given` **不入关键字表**：它只出现在 `|` 右侧的修饰符位，与 `|foreign` /
/// `|import` / `|export` 同走标识符白名单路径（先例见 `Parser.parseBracketDecl`）。
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

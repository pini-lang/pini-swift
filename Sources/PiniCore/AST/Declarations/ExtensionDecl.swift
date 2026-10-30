import Foundation

/// 扩展块声明：类型体只含字段/用例，方法必须写在同一文件的扩展块里并显式使用 `|self` 或 `|Self`，
/// 扩展块内禁止自由函数。四种形 `((` / `{{` / `[[` / `<<` 分别对应结构 / 对象 / 通用 / 特征。
/// `targetTypeAnnotation` 是 `((名称: 类型注解))` 形式的限定，当前只解析存储，合并按 `targetType` 名称匹配。
public struct ExtensionDecl: Equatable, ASTNode, Sendable {
    /// 扩展种类。`bracketExt`（方括号）是通用形：不预设目标类别，归并时按目标的实际注册类别决定落哪张表，
    /// 故 `((` 与 `{{` 在归并层互通——条件只看「目标是否注册为名义类型」，不看 kind 本身。
    /// 其余三形是按类别专门化的糖（`((` 结构 · `{{` 对象 · `<<` 特征）。
    public enum Kind: Equatable, Sendable {
        case structExt
        case objectExt
        /// 方括号 `[[X]]` —— 通用扩展（方括号本身是通用形，见 `给定块`）。
        case bracketExt
        case traitExt
    }

    public let kind: Kind
    public let targetType: String
    public let targetTypeAnnotation: TypeAnnotation?
    public let methods: [FuncDecl]
    public let location: SourceLocation

    public init(
        kind: Kind,
        targetType: String,
        targetTypeAnnotation: TypeAnnotation? = nil,
        methods: [FuncDecl],
        location: SourceLocation
    ) {
        self.kind = kind
        self.targetType = targetType
        self.targetTypeAnnotation = targetTypeAnnotation
        self.methods = methods
        self.location = location
    }
}

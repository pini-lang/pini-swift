import Foundation

/// 扩展块声明（声明上下文收紧·规则 3.2/3.14， extension-decl）
///
/// 数据与逻辑分离：类型体（struct/object/enum）只含字段/用例；方法必须写在
/// 同文件扩展块中，并显式使用 `|self` 或 `|Self`。扩展块内禁止自由函数。
///
/// 文法：
/// ```
/// extension-decl ::= '((' IDENT [':' type-annotation] '))' method-body (* 结构扩展 *)
/// | '{{' IDENT [':' type-annotation] '}}' method-body (* 对象扩展 *)
/// | '[[' IDENT [':' type-annotation] ']]' method-body (* 通用扩展 *)
/// | '<<' IDENT '>>' trait-body; (* 特征扩展 *)
/// ```
/// `targetTypeAnnotation` 为 `((名称: 类型注解))` 形式的限定（泛型特化扩展场景，
/// 暂只解析存储；当前合并按 `targetType` 名称匹配）。
public struct ExtensionDecl: Equatable, ASTNode {
    /// 扩展种类。
    ///
    /// ⚠️ `bracketExt`（方括号）是**通用形**：它不预设目标类别，归并时按**目标的实际
    /// 注册类别**决定落到哪张表（名义类型 ⇒ 归并其方法；枚举 ⇒ 不归并，与今日行为一致）。
    /// 其余三形是**按类别专门化的糖**（`((` 结构 · `{{` 对象 · `<<` 特征）。
    /// 实测（2026-09-19）：`((` 与 `{{` 在归并层**互通**（对结构 / 对象目标皆生效）——
    /// 归并条件从来只看「目标是否注册为名义类型」，不看 kind 本身。
    public enum Kind: Equatable {
        case structExt
        case objectExt
        /// 方括号 `[[X]]` —— 通用扩展（方括号本身是通用形，见 `给定块` AD-001）。
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

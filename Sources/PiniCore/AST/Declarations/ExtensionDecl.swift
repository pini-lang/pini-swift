import Foundation

/// 扩展块声明（ADR-016 规则 3.2/3.14， extension-decl）
///
/// 数据与逻辑分离：类型体（struct/object/enum）只含字段/用例；方法必须写在
/// 同文件扩展块中，并显式使用 `|self` 或 `|Self`。扩展块内禁止自由函数。
///
/// 文法：
/// ```
/// extension-decl ::= '((' IDENT [':' type-annotation] '))' method-body (* 结构扩展 *)
/// | '{{' IDENT [':' type-annotation] '}}' method-body (* 对象扩展 *)
/// | '[[' IDENT [':' type-annotation] ']]' method-body (* 枚举扩展 *)
/// | '<<' IDENT '>>' trait-body; (* 特征扩展 *)
/// ```
/// `targetTypeAnnotation` 为 `((名称: 类型注解))` 形式的限定（泛型特化扩展场景，
/// 暂只解析存储；当前合并按 `targetType` 名称匹配）。
public struct ExtensionDecl: Equatable, ASTNode {
 /// 扩展种类（决定消费端合并到哪类类型/特征）。
 public enum Kind: Equatable {
 case structExt
 case objectExt
 case enumExt
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

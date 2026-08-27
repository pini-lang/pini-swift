import Foundation

/// 结构块声明（值类型）
public struct StructDecl: Equatable, ASTNode {
 public let name: String
 public let genericParams: [GenericParam]
 public let fields: [FieldDecl]
 public let methods: [FuncDecl]
 public let composedType: String?
 public let traits: [String]
 public let location: SourceLocation

 public init(name: String, genericParams: [GenericParam], fields: [FieldDecl], methods: [FuncDecl], composedType: String? = nil, traits: [String] = [], location: SourceLocation) {
 self.name = name
 self.genericParams = genericParams
 self.fields = fields
 self.methods = methods
 self.composedType = composedType
 self.traits = traits
 self.location = location
 }
}

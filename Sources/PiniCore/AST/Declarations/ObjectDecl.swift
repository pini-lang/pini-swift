import Foundation

/// 对象块声明（引用类型）
public struct ObjectDecl: Equatable, ASTNode {
 public let name: String
 public let genericParams: [GenericParam]
 public let fields: [FieldDecl]
 public let methods: [FuncDecl]
 public let traits: [String]
 public let location: SourceLocation

 public init(name: String, genericParams: [GenericParam], fields: [FieldDecl], methods: [FuncDecl], traits: [String] = [], location: SourceLocation) {
 self.name = name
 self.genericParams = genericParams
 self.fields = fields
 self.methods = methods
 self.traits = traits
 self.location = location
 }
}

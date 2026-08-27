import Foundation

/// 特征体声明
public struct TraitDecl: Equatable, ASTNode {
 public let name: String
 public let genericParams: [GenericParam]
 public let signatures: [FuncDecl]
 public let location: SourceLocation

 public init(name: String, genericParams: [GenericParam], signatures: [FuncDecl], location: SourceLocation) {
 self.name = name
 self.genericParams = genericParams
 self.signatures = signatures
 self.location = location
 }
}

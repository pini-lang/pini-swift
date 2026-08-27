import Foundation

/// 函数声明
public struct FuncDecl: Equatable, ASTNode {
 public let name: String
 public let modifiers: [String]
 public let genericParams: [GenericParam]
 public let params: [Parameter]
 public let returnTypes: [TypeAnnotation]
 /// 草稿 A2（批次 1.3，D1）：命名返回元组的分量标签，与 returnTypes 一一对应（nil = 无标签）。
 /// 运行时给多返回值补写标签，`.名称` 标签访问才可命中。
 public let returnLabels: [String?]
 public let isAsync: Bool
 public let body: Block?
 public let location: SourceLocation
 public let captured: [String]

 public init(name: String, modifiers: [String], genericParams: [GenericParam], params: [Parameter], returnTypes: [TypeAnnotation], returnLabels: [String?] = [], isAsync: Bool = false, body: Block?, location: SourceLocation, captured: [String] = []) {
 self.name = name
 self.modifiers = modifiers
 self.genericParams = genericParams
 self.params = params
 self.returnTypes = returnTypes
 self.returnLabels = returnLabels
 self.isAsync = isAsync
 self.body = body
 self.location = location
 self.captured = captured
 }
}

/// 字段声明
public struct FieldDecl: Equatable, ASTNode {
 public let name: String
 public let typeAnnotation: TypeAnnotation
 public let initializer: Expression?
 public let location: SourceLocation

 public init(name: String, typeAnnotation: TypeAnnotation, initializer: Expression?, location: SourceLocation) {
 self.name = name
 self.typeAnnotation = typeAnnotation
 self.initializer = initializer
 self.location = location
 }
}

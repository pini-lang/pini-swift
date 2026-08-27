import Foundation

/// AST 节点基础协议
/// 所有 AST 节点类型应遵循此协议，提供位置信息和节点描述能力
public protocol ASTNode {
 var location: SourceLocation { get }
}

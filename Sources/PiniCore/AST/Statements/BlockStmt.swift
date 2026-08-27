import Foundation

/// 块语句和辅助类型
public struct Block: Equatable, ASTNode {
 public let statements: [Statement]
 public let location: SourceLocation

 public init(statements: [Statement], location: SourceLocation) {
 self.statements = statements
 self.location = location
 }
}

/// 赋值目标
public enum AssignTarget: Equatable {
 case identifier(name: String)
 case member(object: Expression, name: String)
 /// 下标写目标 `a[i] = v`（#46-D D1.5：数组下标写）。
 /// - `expr`：容器表达式（任意表达式，非 identifier-only）
 /// - `index`：索引表达式
 case `subscript`(expr: Expression, index: Expression)
}

/// elif 分支
public struct ElifBranch: Equatable, ASTNode {
 public let condition: Expression
 public let block: Block
 public let location: SourceLocation

 public init(condition: Expression, block: Block, location: SourceLocation) {
 self.condition = condition
 self.block = block
 self.location = location
 }
}

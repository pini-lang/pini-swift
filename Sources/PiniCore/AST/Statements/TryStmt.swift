import Foundation

/// try 语句
/// tryStatement(expression: Expression, tryBlock: Block, exceptClauses: [ExceptClause], location: SourceLocation)

/// except 子句
public struct ExceptClause: Equatable {
 public let errorVar: String
 public let body: Block
 public let location: SourceLocation

 public init(errorVar: String, body: Block, location: SourceLocation) {
 self.errorVar = errorVar
 self.body = body
 self.location = location
 }
}

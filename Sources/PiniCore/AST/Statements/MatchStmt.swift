import Foundation

/// match 语句
/// matchStatement(value: Expression, cases: [MatchCase], defaultCase: Block?, location: SourceLocation)

/// match 模式（P5-4 HIGH-2）：枚举 case 名 / 整数字面量 / 浮点字面量 / 字符串字面量 / 布尔字面量 / 通配 `_`
public enum MatchPattern: Equatable, CustomStringConvertible {
 case enumCase(String)
 case intLiteral(Int)
 case floatLiteral(Double)
 case stringLiteral(String)
 case boolLiteral(Bool)
 case wildcard

 public var description: String {
 switch self {
 case .enumCase(let name): return name
 case .intLiteral(let n): return "\(n)"
 case .floatLiteral(let f): return "\(f)"
 case .stringLiteral(let s): return "\"\(s)\""
 case .boolLiteral(let b): return "\(b)"
 case .wildcard: return "_"
 }
 }
}

/// match case
public struct MatchCase: Equatable, ASTNode {
 public let pattern: MatchPattern
 public let bindings: [MatchBinding]
 public let block: Block
 public let location: SourceLocation

 public init(pattern: MatchPattern, bindings: [MatchBinding], block: Block, location: SourceLocation) {
 self.pattern = pattern
 self.bindings = bindings
 self.block = block
 self.location = location
 }
}

/// match 绑定（命名或位置）
public struct MatchBinding: Equatable {
 public let paramName: String?
 public let varName: String

 public init(paramName: String?, varName: String) {
 self.paramName = paramName
 self.varName = varName
 }
}

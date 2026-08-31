import Foundation

public enum IRGenError: Error, LocalizedError {
 case unsupportedType(name: String, SourceLocation)
 case unsupportedExpression(kind: String, SourceLocation)
 case unsupportedStatement(kind: String, SourceLocation)
 case unsupportedFeature(feature: String, SourceLocation)
 case typeMismatch(expected: String, got: String, SourceLocation)

 public var errorDescription: String {
 switch self {
 case .unsupportedType(let name, let loc):
 return "IRGenError: 不支持的类型 '\(name)' at \(loc.fileName):\(loc.line):\(loc.column)"
 case .unsupportedExpression(let kind, let loc):
 return "IRGenError: 不支持的表达式 '\(kind)' at \(loc.fileName):\(loc.line):\(loc.column)"
 case .unsupportedStatement(let kind, let loc):
 return "IRGenError: 不支持的语句 '\(kind)' at \(loc.fileName):\(loc.line):\(loc.column)"
 case .unsupportedFeature(let feature, let loc):
 return "IRGenError: 不支持的特性 '\(feature)' at \(loc.fileName):\(loc.line):\(loc.column)"
 case .typeMismatch(let expected, let got, let loc):
 return "IRGenError: 类型不匹配, 期望 '\(expected)' 实际 '\(got)' at \(loc.fileName):\(loc.line):\(loc.column)"
 }
 }
}

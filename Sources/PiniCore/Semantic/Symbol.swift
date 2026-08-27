import Foundation

/// 符号
/// 用于语义分析阶段的符号表条目
public struct Symbol {
 public let name: String
 public let kind: SymbolKind
 public let location: SourceLocation

 public init(name: String, kind: SymbolKind, location: SourceLocation) {
 self.name = name
 self.kind = kind
 self.location = location
 }
}

/// 符号种类
public enum SymbolKind: Equatable {
 case variable(isMutable: Bool)
 case function
 case `struct`
 case `object`
 case `enum`
 case `enumCase`
 case trait
 case parameter
}

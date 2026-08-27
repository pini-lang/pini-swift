import Foundation

/// 作用域
/// 用于语义分析阶段的作用域管理
public final class Scope {
 public let name: String
 public let parent: Scope?
 public private(set) var symbols: [String: Symbol] = [:]

 public init(name: String, parent: Scope? = nil) {
 self.name = name
 self.parent = parent
 }

 public func define(_ symbol: Symbol) {
 symbols[symbol.name] = symbol
 }

 public func resolve(_ name: String) -> Symbol? {
 if let symbol = symbols[name] {
 return symbol
 }
 return parent?.resolve(name)
 }
}

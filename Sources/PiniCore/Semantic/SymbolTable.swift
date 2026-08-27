import Foundation

/// 符号表
/// 管理全局和局部作用域中的符号
public final class SymbolTable {
 public private(set) var current: Scope

 public init(globalScope: Scope = Scope(name: "global")) {
 self.current = globalScope
 }

 public func enterScope(name: String) {
 current = Scope(name: name, parent: current)
 }

 public func exitScope() {
 if let parent = current.parent {
 current = parent
 }
 }

 public func define(_ symbol: Symbol) {
 current.define(symbol)
 }

 public func resolve(_ name: String) -> Symbol? {
 current.resolve(name)
 }

 /// 当前（最内层）作用域内是否已定义该名字。
 /// 用于「同作用域重声明」检测：跨作用域的遮蔽（shadowing）不在此列。
 public func isDefinedInCurrentScope(_ name: String) -> Bool {
 current.symbols[name] != nil
 }
}

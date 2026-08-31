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

 /// 自当前作用域向上解析，同时返回命中作用域。供 H-1 capture 语义判定：
 /// 命中作用域在匿名函数体作用域边界之外（外层局部）还是之内（体内局部/参数）。
 public func resolveWithScope(_ name: String) -> (symbol: Symbol, scope: Scope)? {
 var scope: Scope? = current
 while let s = scope {
 if let sym = s.symbols[name] { return (sym, s) }
 scope = s.parent
 }
 return nil
 }
}

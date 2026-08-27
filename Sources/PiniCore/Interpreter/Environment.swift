import Foundation

public class Environment {
 private struct Binding {
 var value: Value
 var isMutable: Bool
 }

 private var scopes: [[String: Binding]]
 public let enclosing: Environment?

 public init(enclosing: Environment? = nil) {
 self.scopes = [[:]]
 self.enclosing = enclosing
 }

 @discardableResult
 public func pushScope() -> Environment {
 let child = Environment(enclosing: self)
 child.scopes = [[:]]
 return child
 }

 public func popScope() {
 }

 public func define(name: String, value: Value, isMutable: Bool) {
 scopes[scopes.count - 1][name] = Binding(value: value, isMutable: isMutable)
 }

 public func get(name: String) throws -> Value {
 for scope in scopes.reversed() {
 if let binding = scope[name] {
 return binding.value
 }
 }
 if let enclosing = enclosing {
 return try enclosing.get(name: name)
 }
 throw RuntimeError.undefinedVariable(name: name, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }

 public func assign(name: String, value: Value) throws {
 for i in (0..<scopes.count).reversed() {
 if let binding = scopes[i][name] {
 if !binding.isMutable {
 throw RuntimeError.immutableVariable(name: name, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 scopes[i][name] = Binding(value: value, isMutable: true)
 return
 }
 }
 if let enclosing = enclosing {
 try enclosing.assign(name: name, value: value)
 return
 }
 throw RuntimeError.undefinedVariable(name: name, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }

 /// 查询变量是否可变（P3-3 加固：供 `let` 聚合成员赋值的运行时拦截使用）。
 /// 沿作用域链与 enclosing 向上查找；未找到返回 nil。
 public func isMutable(name: String) -> Bool? {
 for scope in scopes.reversed() {
 if let binding = scope[name] { return binding.isMutable }
 }
 if let enclosing = enclosing {
 return enclosing.isMutable(name: name)
 }
 return nil
 }

 /// 快照当前作用域内所有绑定（名称 + 值），供调试器在停止点展示局部变量。
 /// 外层作用域在前，内层覆盖在后。
 public func listBindings() -> [(name: String, value: Value)] {
 var result: [(String, Value)] = []
 for scope in scopes {
 for (name, binding) in scope {
 result.append((name, binding.value))
 }
 }
 return result
 }
}

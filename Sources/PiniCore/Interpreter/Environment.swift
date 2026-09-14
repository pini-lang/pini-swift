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

 /// 就地初始化一个**已声明**的绑定，保留其可变性。
 ///
 /// 与 `assign` 的区别只在一点：这里不做可变性检查。它不是「更宽松的 assign」，
 /// 而是语言里客观存在的第三种写：**声明处的一次初始化**（`let x = ...`）。`assign`
 /// 在这里会误判——把「初始化一个 `let`」当成「给 `let` 赋值」而拒绝。
 ///
 /// 存在的理由是降载形状：`let x = try ... else e:` 被拆成
 /// `allocVar(x, initializer: nil)` + `tryStmt(okTarget: x)` 两条语句，ok 臂必须写进
 /// 前一条已经声明的槽。查找顺序与 `assign` 一致（内层优先，未找到抛 undefinedVariable）。
 public func initialize(name: String, value: Value) throws {
  for i in (0..<scopes.count).reversed() {
   if let binding = scopes[i][name] {
    scopes[i][name] = Binding(value: value, isMutable: binding.isMutable)
    return
   }
  }
  if let enclosing = enclosing {
   try enclosing.initialize(name: name, value: value)
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

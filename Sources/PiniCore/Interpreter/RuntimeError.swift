import Foundation

public enum ControlSignal: Error {
 case returnSignal(Value?)
 case breakSignal(label: String?)
 case continueSignal(label: String?)
}

public struct ErrorSignal {
 public let value: Value
 public init(value: Value) {
 self.value = value
 }
}

/// 草稿 A2（批次 1.4，D2）：`^` 右值糖解包 `err(e)` 时的控制返回信号。
/// 由最近函数边界（executeFunctionBody）捕获，错误 e 注入返回元组末槽
/// （errors-as-data，错误即数据、可被 `await`/`wait` 取 `Result` 后 `match` 解构，不穿透异常路径）。
public final class UnwrapErrSignal: Error {
 public let error: Value
 public init(error: Value) {
 self.error = error
 }
}

public enum RuntimeError: Error, CustomStringConvertible {
 case undefinedVariable(name: String, location: SourceLocation)
 case immutableVariable(name: String, location: SourceLocation)
 case typeMismatch(expected: String, got: String, location: SourceLocation)
 case divisionByZero(location: SourceLocation)
 case indexOutOfRange(location: SourceLocation)
 case invalidOperation(reason: String, location: SourceLocation)
 case mainNotFound(location: SourceLocation)
 case notCallable(location: SourceLocation)
 case arityMismatch(expected: Int, got: Int, location: SourceLocation)
 /// 字段级 type-private 违规（P4.5）：访问了以 `_` 前缀声明的字段，
 /// 但访问点不在该字段**声明类型自身的方法**内（同文件普通函数 / 跨类型方法 / 跨文件均不可访问）。
 case inaccessibleField(typeName: String, fieldName: String, location: SourceLocation)
 /// 并发任务被取消（B2-1，立场 B ）：手动 `t.cancel()` / 父任务返回自动取消 /
 /// 超时归约取消。join 时被 `Interpreter.joinFuture` 归约为 `err(CancelError)` 数据值，
 /// 不会作为异常冒泡到用户代码——错误即数据。
 case taskCancelled(reason: String, location: SourceLocation)
 /// match 未穷尽（MED-1，P5）：枚举值主体无 case 命中且无可兜底（default/通配子块）时抛错，替代原静默 no-op。
 case matchNotExhaustive(value: String, location: SourceLocation)
 /// G41（test 块，R2）：assert 内建断言失败——条件为 false 时抛出，测试运行器捕获为测试失败。
 case assertionFailed(message: String, location: SourceLocation)
 /// Phase 2a（ADR-015 FFI）：原生函数实参个数不符（load/store/malloc 等）。
 case argumentCountMismatch(name: String, expected: Int, got: Int, location: SourceLocation)
 /// Phase 2a（ADR-015 FFI）：`[名称|foreign]` 声明的 C 函数不在原生函数表（未预注册）。
 case undefinedNativeFunction(name: String, available: [String], location: SourceLocation)
 /// Phase 2b（ADR-017 FFI dlsym）：`[名称|foreign]` 块名对应的库在搜索路径中未找到。
 case libraryNotFound(library: String, searched: [String], location: SourceLocation)
 /// Phase 2b（ADR-017 FFI dlsym）：库已加载但其中未找到 foreign 声明的符号。
 case symbolNotFound(library: String, symbol: String, location: SourceLocation)

 public var description: String {
 switch self {
 case .undefinedVariable(let name, let loc):
 return "未定义变量: \(name) at \(loc)"
 case .immutableVariable(let name, let loc):
 return "不可修改的变量: \(name) at \(loc)"
 case .typeMismatch(let expected, let got, let loc):
 return "类型不匹配: 期望 \(expected), 得到 \(got) at \(loc)"
 case .divisionByZero(let loc):
 return "除以零 at \(loc)"
 case .indexOutOfRange(let loc):
 return "索引越界 at \(loc)"
 case .invalidOperation(let reason, let loc):
 return "无效操作: \(reason) at \(loc)"
 case .mainNotFound(let loc):
 return "未找到 main 函数 at \(loc)"
 case .notCallable(let loc):
 return "不可调用 at \(loc)"
 case .arityMismatch(let expected, let got, let loc):
 return "参数数量不匹配: 期望 \(expected), 得到 \(got) at \(loc)"
 case .inaccessibleField(let typeName, let fieldName, let loc):
 return "无法访问私有字段 '\(typeName).\(fieldName)': 该字段为 type-private，仅 \(typeName) 类型自身的方法可访问 at \(loc)"
 case .taskCancelled(let reason, let loc):
 return "\(reason) at \(loc)"
 case .matchNotExhaustive(let value, let loc):
 return "match 未穷尽: 值 '\(value)' 未匹配任何 case 且无 default/通配子块兜底 at \(loc)"
 case .assertionFailed(let message, let loc):
 return "断言失败: \(message) at \(loc)"
 case .argumentCountMismatch(let name, let expected, let got, let loc):
 return "原生函数 \(name) 参数数量不匹配: 期望 \(expected), 得到 \(got) at \(loc)"
 case .undefinedNativeFunction(let name, let available, let loc):
 return "未注册的原生函数 '\(name)'（`[名称|foreign]` 声明的 C 函数须在原生函数表内）；可用: \(available.isEmpty ? "（无）" : available.joined(separator: ", ")) at \(loc)"
 case .libraryNotFound(let library, let searched, let loc):
 return "FFI 库 '\(library)' 未找到（已搜索：\(searched.isEmpty ? "（无搜索路径）" : searched.joined(separator: ", "))）at \(loc)"
 case .symbolNotFound(let library, let symbol, let loc):
 return "FFI 库 '\(library)' 中未找到符号 '\(symbol)' at \(loc)"
 }
 }
}

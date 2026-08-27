import Foundation

/// 类型错误
public enum TypeError: Error, Equatable {
 case mismatch(expected: String, got: String, location: SourceLocation)
 case undefined(name: String, location: SourceLocation)
 case cannotInfer(location: SourceLocation)
 case invalidOperation(op: String, type: String, location: SourceLocation)
 case argumentCountMismatch(expected: Int, got: Int, location: SourceLocation)
 case genericArgumentCountMismatch(typeName: String, expected: Int, got: Int, location: SourceLocation)
 /// 类型声明实现某 trait 但未提供其抽象方法（body 为空的方法签名）。
 case traitRequirementNotSatisfied(typeName: String, traitName: String, methodName: String, location: SourceLocation)
 /// 类型提供的方法签名与 trait 抽象方法要求不匹配（参数个数/类型或返回类型不符）。
 case traitMethodSignatureMismatch(typeName: String, traitName: String, methodName: String, detail: String, location: SourceLocation)
 /// 已知内建类型（String/Array）上调用未注册成员方法（P3-2 ③：内建成员方法静态校验）。
 /// 运行时本就会对未知成员抛 undefinedVariable，此处提前到静态检查捕获（如拼写错误 `s.uppr()`）。
 case unknownMember(typeName: String, memberName: String, location: SourceLocation)
 /// 对 `let` 声明的不可变变量重新赋值（P3-3：值/引用语义收口之 `let` 不可变边界）。
 /// 运行时 `Environment.assign` 本就会抛 `immutableVariable`，此处提前到静态检查捕获。
 case reassignmentToImmutable(variableName: String, location: SourceLocation)
 /// 跨文件可见性违规：引用了定义在其他文件中、按 4 级可见性不可见的符号。
 /// `definedIn` 为定义所在源文件，`level` 为该符号的可见性级别。
 case inaccessibleSymbol(name: String, definedIn: String, level: VisibilityLevel, location: SourceLocation)
 /// 字段级 type-private 违规（P4.5）：访问了以 `_` 前缀声明的字段，
 /// 但访问点不在该字段**声明类型自身的方法**内（同文件普通函数 / 跨类型方法 / 跨文件均不可访问）。
 /// `typeName` 为字段声明所在类型，`fieldName` 为被访问的 `_` 字段。
 case inaccessibleField(typeName: String, fieldName: String, location: SourceLocation)
 /// 任务隔离违规（B3-1，消解 R6）：把引用类型（object）作为实参传过 `=>` 并发进程的
 /// 调用边界，会让两个线程持有同一 `ObjectReference` 并发改写其字段——那是内存不安全（实测 SIGABRT），
 /// 而非仅仅"计数不准"。`typeName` 为触发隔离的引用类型（可能藏在 struct 字段或容器实参里，
 /// 此时它是递归找到的那个引用类型），`paramName` 为并发函数的形参名，`functionName` 为被调并发进程。
 case sharedReferenceAcrossTasks(typeName: String, paramName: String, functionName: String, location: SourceLocation)
 /// 3.15：枚举用例构造为位置式，不允许具名实参（如 `圆(半径: 5.0)`）。
 case enumCaseArgumentLabel(label: String, caseName: String, location: SourceLocation)
}

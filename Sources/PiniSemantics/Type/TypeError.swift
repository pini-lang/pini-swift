import Foundation
import PiniSyntax

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
    /// 任务隔离违规：引用类型（object）作为实参越过 `=>` 并发进程边界，两线程会共持同一
    /// `ObjectReference` 并发改写字段，属内存不安全（实测 SIGABRT），非仅计数不准。
    /// `typeName` 为递归找到的引用类型，`paramName` 为并发函数形参名，`functionName` 为被调并发进程。
    case sharedReferenceAcrossTasks(typeName: String, paramName: String, functionName: String, location: SourceLocation)
    /// 3.15：枚举用例构造为位置式，不允许具名实参（如 `圆(半径: 5.0)`）。
    case enumCaseArgumentLabel(label: String, caseName: String, location: SourceLocation)
    /// 给定块的类型名出现在值位（`取(配置)` / `配置.方法()`）：类型名不是值，默认实例只能经
    /// `using` 形参取得；此诊断在静态层拒绝，避免落到 IRGen 报出误导性的「未声明变量 '配置'」。
    /// 同一通路本就不可行，故这不是新增约束，只是把报错提前并把做法写进文案。
    case givenBlockTypeInValuePosition(typeName: String, location: SourceLocation)
    /// export 块 `|c` 条目：引用的声明不合格，或两个条目转写后撞成同一个 C 名。
    /// `reason` 是一句自成句子的说明，诊断头由格式化层加。
    case exportCInvalid(reason: String, location: SourceLocation)
    /// 错误码申报不合格：`码()` 的载体、函数体或码值越界。不合格的申报一旦被忽略，
    /// 作者会以为码已固定，实际发出去的是自动码 —— 那正是这一层要拦的沉默。
    case errorCodeInvalid(reason: String, location: SourceLocation)
    /// C 边界类型不在闭合表里：未知名、对象、元组、集合，或指针目标不合格。
    /// 放行会产生「能过 check、换个通道就换行为」的声明，故一律在语义期挡住。
    case foreignTypeNotRepresentable(type: String, reason: String, location: SourceLocation)
    /// 语言层有这个宽度，IR 没有对应类型（I16 / U16 / U32 / F32）。
    case foreignTypeWidthNotInIR(type: String, location: SourceLocation)
    /// `String` 出现在外部函数的返回位：C 返回的指针归属不明，取回必须显式复制。
    case foreignStringInReturnPosition(location: SourceLocation)
    /// 回调实参不合格：不是裸标识符、解析不到顶层自由函数，或签名与形参声明不是逐位相同。
    /// 三种情况都指向同一件事——传出去的地址必须真的能被 C 按那个签名调用。
    case foreignCallbackNotFreeFunction(reason: String, location: SourceLocation)
    /// 回调签名里的 `Bool`：`i1` 与 C `_Bool` 的寄存器约定不同，回调方向没有转发层可替它转。
    case foreignCallbackBoolean(location: SourceLocation)
}

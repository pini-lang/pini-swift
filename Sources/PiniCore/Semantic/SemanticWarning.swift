import Foundation

/// T1/B2（2026-08-24）：语义警告（非致命诊断，`severity: .warning`，不阻断 run/check，exit 0）。
/// 首版仅检测函数/块作用域内的局部 `var`/`let` 未使用（见 `SemanticAnalyzer.emitUnusedWarnings`）——
/// 不检测：函数参数、顶层声明、对象/结构体字段、枚举关联值、for 模式绑定变量、`_`/`_xxx` 前缀。
public enum SemanticWarning: Error, Equatable {
 case unusedVariable(name: String, location: SourceLocation)
 /// 批 6 D-4：隐式别名与目标模块名不一致（弱警告——检查不强制，D-4 #1 用户裁决）。
 case implicitAliasNameMismatch(alias: String, targetName: String, location: SourceLocation)
}

extension SemanticWarning: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .unusedVariable: return "\(DiagnosticDomain.warning.rawValue)-001"
 case .implicitAliasNameMismatch: return "\(DiagnosticDomain.warning.rawValue)-002"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .warning }
 public var suggestion: String? { nil }
 public var diagnosticLocation: SourceLocation {
 switch self {
 case .unusedVariable(_, let loc): return loc
 case .implicitAliasNameMismatch(_, _, let loc): return loc
 }
 }
}

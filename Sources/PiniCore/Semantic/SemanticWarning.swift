import Foundation

/// 语义警告（非致命诊断，`severity: .warning`，不阻断 run/check，exit 0）。
/// 目前只检测 `emitUnusedWarnings` 里函数/块作用域内的局部 `var`/`let` 未使用——
/// 参数、顶层声明、字段、枚举关联值、for 模式绑定与 `_`/`_xxx` 前缀都不检测。
public enum SemanticWarning: Error, Equatable {
    case unusedVariable(name: String, location: SourceLocation)
    /// 隐式别名与目标模块名不一致（弱警告——检查不强制，由用户裁决取舍）。
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

import Foundation
import PiniSyntax

/// 语义警告（非致命诊断，`severity: .warning`，不阻断 run/check，exit 0）。
/// 未使用变量只检测 `emitUnusedWarnings` 里函数/块作用域的局部 `var`/`let`：参数、顶层声明、字段、
/// 枚举关联值、for 模式绑定与 `_`/`_xxx` 前缀都不检测。物化环由 `IRModule.givenReferences` 检出。
public enum SemanticWarning: Error, Equatable {
    case unusedVariable(name: String, location: SourceLocation)
    /// 隐式别名与目标模块名不一致（弱警告——检查不强制，由用户裁决取舍）。
    case implicitAliasNameMismatch(alias: String, targetName: String, location: SourceLocation)
    /// 给定块物化环：路径首尾同名（`甲块 → 乙块 → 甲块`）。环在物化时必然无限递归，警告只负责指出来。
    case givenCycle(path: [String], location: SourceLocation)
    /// 非 enum 错误类型没有写 `码()`：编译器兜底分配了一个码。该码不承诺跨版本稳定，
    /// 警告写明档位与固定办法——不静默是这条规则的全部意义。
    case automaticErrorCode(typeName: String, code: Int32, location: SourceLocation)
}

extension SemanticWarning {
    /// 环路径的展示形。三处拼装文案共用这一份：箭头变了不会只改到其中一处。
    public var cyclePathText: String? {
        guard case .givenCycle(let path, _) = self else { return nil }
        return path.joined(separator: " → ")
    }
}

extension SemanticWarning: DiagnosticProviding {
    public var diagnosticCode: String {
        switch self {
        case .unusedVariable: return "\(DiagnosticDomain.warning.rawValue)-001"
        case .implicitAliasNameMismatch: return "\(DiagnosticDomain.warning.rawValue)-002"
        case .givenCycle: return "\(DiagnosticDomain.warning.rawValue)-003"
        case .automaticErrorCode: return "\(DiagnosticDomain.warning.rawValue)-004"
        }
    }
    public var diagnosticSeverity: DiagnosticSeverity { .warning }
    public var suggestion: String? { nil }
    public var diagnosticLocation: SourceLocation {
        switch self {
        case .unusedVariable(_, let loc): return loc
        case .implicitAliasNameMismatch(_, _, let loc): return loc
        case .givenCycle(_, let loc): return loc
        case .automaticErrorCode(_, _, let loc): return loc
        }
    }
}

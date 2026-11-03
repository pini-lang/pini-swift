import PiniSyntax
import PiniSemantics

/// 运行时错误的诊断元数据。放在错误类型自己这一层：诊断核心只提供协议与渲染，
/// 具体错误码由拥有该错误的层声明，核心因此不必认识执行层。
extension RuntimeError: DiagnosticProviding {
    public var diagnosticCode: String {
        switch self {
        case .undefinedVariable: return "\(DiagnosticDomain.runtime.rawValue)-001"
        case .immutableVariable: return "\(DiagnosticDomain.runtime.rawValue)-002"
        case .typeMismatch: return "\(DiagnosticDomain.runtime.rawValue)-003"
        case .divisionByZero: return "\(DiagnosticDomain.runtime.rawValue)-004"
        case .indexOutOfRange: return "\(DiagnosticDomain.runtime.rawValue)-005"
        case .invalidOperation: return "\(DiagnosticDomain.runtime.rawValue)-006"
        case .mainNotFound: return "\(DiagnosticDomain.runtime.rawValue)-007"
        case .notCallable: return "\(DiagnosticDomain.runtime.rawValue)-008"
        case .arityMismatch: return "\(DiagnosticDomain.runtime.rawValue)-009"
        case .inaccessibleField: return "\(DiagnosticDomain.runtime.rawValue)-010"
        case .taskCancelled: return "\(DiagnosticDomain.runtime.rawValue)-011"
        case .matchNotExhaustive: return "\(DiagnosticDomain.runtime.rawValue)-012"
        case .assertionFailed: return "\(DiagnosticDomain.runtime.rawValue)-013"
        case .argumentCountMismatch: return "\(DiagnosticDomain.runtime.rawValue)-014"
        case .undefinedNativeFunction: return "\(DiagnosticDomain.runtime.rawValue)-015"
        case .libraryNotFound: return "\(DiagnosticDomain.runtime.rawValue)-016"
        case .symbolNotFound: return "\(DiagnosticDomain.runtime.rawValue)-017"
        case .entryMainMismatch: return "\(DiagnosticDomain.runtime.rawValue)-018"
        case .variadicCallUnsupported: return "\(DiagnosticDomain.runtime.rawValue)-019"
        }
    }
    public var diagnosticSeverity: DiagnosticSeverity { .error }
    public var suggestion: String? { nil }
    public var diagnosticLocation: SourceLocation {
        self.location
    }
    private var location: SourceLocation {
        switch self {
        case .undefinedVariable(_, let loc), .immutableVariable(_, let loc),
            .typeMismatch(_, _, let loc), .divisionByZero(let loc),
            .indexOutOfRange(let loc), .invalidOperation(_, let loc),
            .mainNotFound(let loc), .notCallable(let loc),
            .arityMismatch(_, _, let loc), .inaccessibleField(_, _, let loc),
            .taskCancelled(_, let loc), .matchNotExhaustive(_, let loc),
            .assertionFailed(_, let loc),
            .argumentCountMismatch(_, _, _, let loc),
            .undefinedNativeFunction(_, _, let loc),
            .libraryNotFound(_, _, let loc),
            .symbolNotFound(_, _, let loc),
            .entryMainMismatch(_, _, let loc),
            .variadicCallUnsupported(_, let loc):
            return loc
        }
    }
}

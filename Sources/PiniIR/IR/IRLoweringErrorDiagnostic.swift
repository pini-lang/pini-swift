import PiniSyntax
import PiniSemantics

/// 能力门禁用 irgen 诊断域装「不支持的特性」。那些码登记在诊断目录里，
/// 沿用同一域意味着换了产出方它们仍在，不会被顺手退役。
extension IRLowerer.IRLoweringError: DiagnosticProviding {
    public var diagnosticCode: String { code }
    public var diagnosticSeverity: DiagnosticSeverity { .error }
    public var suggestion: String? { nil }
    public var diagnosticLocation: SourceLocation { location }
}

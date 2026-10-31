import PiniSyntax
import PiniSemantics

/// The capability gate uses the irgen code domain for its "unsupported feature" bucket. Those
/// codes are registered in the diagnostic catalogue, and keeping the domain means they survive
/// the change of producer instead of being retired by accident.
extension IRLowerer.IRLoweringError: DiagnosticProviding {
    public var diagnosticCode: String { code }
    public var diagnosticSeverity: DiagnosticSeverity { .error }
    public var suggestion: String? { nil }
    public var diagnosticLocation: SourceLocation { location }
}

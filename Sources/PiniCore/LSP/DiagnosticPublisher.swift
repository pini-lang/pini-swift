import Foundation

/// 诊断发布器：将 Pini 三类错误映射为 LSP Diagnostic 数组。
public struct DiagnosticPublisher {

 /// 将 Pini 错误统一转为 LSP Diagnostic
 /// - Parameters:
 /// - source: 完整源码文本，用于生成带出错行/波浪线的诊断消息；留空则不含源码片段
 /// - language: 诊断语言（LSP 由 initialize 的 locale 决定；缺省用全局当前语言，与 CLI 解耦）
 public func publish(
 parserErrors: [ParserError],
 semanticErrors: [SemanticError],
 typeErrors: [TypeError],
 semanticWarnings: [SemanticWarning] = [],
 uri: String,
 source: String = "",
 language: DiagnosticLanguage? = nil
 ) -> PublishDiagnosticsParams {
 var diagnostics: [Diagnostic] = []
 
 for err in parserErrors {
 diagnostics.append(mapParserError(err, source: source, language: language))
 }
 for err in semanticErrors {
 diagnostics.append(mapSemanticError(err, source: source, language: language))
 }
 for err in typeErrors {
 diagnostics.append(mapTypeError(err, source: source, language: language))
 }
 for warning in semanticWarnings {
 diagnostics.append(mapSemanticWarning(warning, source: source, language: language))
 }
 
 return PublishDiagnosticsParams(uri: uri, version: nil, diagnostics: diagnostics)
 }

 // MARK: - Mapping

 private func mapSemanticWarning(_ warning: SemanticWarning, source: String, language: DiagnosticLanguage?) -> Diagnostic {
 Diagnostic(
 range: toLSPRange(warning.diagnosticLocation),
 severity: .warning,
 source: "pini-semantic",
 message: ErrorFormatter.formatDiagnostic(warning, source: source, language: language)
 )
 }

 private func mapParserError(_ err: ParserError, source: String, language: DiagnosticLanguage?) -> Diagnostic {
 let loc = location(of: err)
 let msg = ErrorFormatter.formatParserError(err, source: source, language: language)
 return Diagnostic(
 range: toLSPRange(loc),
 severity: .error,
 source: "pini-parser",
 message: msg
 )
 }

 private func mapSemanticError(_ err: SemanticError, source: String, language: DiagnosticLanguage?) -> Diagnostic {
 let loc = location(of: err)
 let msg = ErrorFormatter.formatSemanticError(err, source: source, language: language)
 return Diagnostic(
 range: toLSPRange(loc),
 severity: .error,
 source: "pini-semantic",
 message: msg
 )
 }

 private func mapTypeError(_ err: TypeError, source: String, language: DiagnosticLanguage?) -> Diagnostic {
 let loc = location(of: err)
 let msg = ErrorFormatter.formatTypeError(err, source: source, language: language)
 return Diagnostic(
 range: toLSPRange(loc),
 severity: .error,
 source: "pini-type",
 message: msg
 )
 }

 // MARK: - Location → LSP Range (single-char span)

 private func toLSPRange(_ loc: SourceLocation) -> LSPRange {
 // Pini 行列均为 1-based，LSP 为 0-based
 let line = max(0, loc.line - 1)
 let col = max(0, loc.column - 1)
 let pos = Position(line: line, character: col)
 // 单字符跨度：end = col+1
 return LSPRange(start: pos, end: Position(line: line, character: col + 1))
 }

 // MARK: - Error location extraction

 private func location(of err: ParserError) -> SourceLocation {
 switch err {
 case .unexpectedToken(_, _, let loc): return loc
 case .expectedToken(_, let loc): return loc
 case .missingIndent(let loc): return loc
 case .missingDedent(let loc): return loc
 case .invalidDeclaration(_, let loc): return loc
 case .invalidExpression(_, let loc): return loc
 case .invalidStatement(_, let loc): return loc
 case .invalidType(_, let loc): return loc
 case .missingBlockBody(let loc): return loc
 case .missingBlockEnd(let loc): return loc
 case .invalidModifier(_, let loc): return loc
 case .missingParameterName(let loc): return loc
 case .missingReturnType(let loc): return loc
 case .missingFieldName(let loc): return loc
 case .missingCaseName(let loc): return loc
 case .missingMethodName(let loc): return loc
 case .missingTraitName(let loc): return loc
 case .missingStructName(let loc): return loc
 case .missingObjectName(let loc): return loc
 case .missingEnumName(let loc): return loc
 case .missingGenericParam(let loc): return loc
 case .missingLabel(let loc): return loc
 case .unexpectedEOF(let loc): return loc
 case .methodDefaultAssumptionTerminated(let loc): return loc
 }
 }

 private func location(of err: SemanticError) -> SourceLocation {
 switch err {
 case .undefinedVariable(_, let loc): return loc
 case .undefinedFunction(_, let loc): return loc
 case .undefinedType(_, let loc): return loc
 case .redeclaredSymbol(_, let loc): return loc
 case .inaccessibleSymbol(_, _, _, let loc): return loc
 case .unknownMatchCase(_, let loc): return loc
 case .nonExhaustiveMatch(_, let loc): return loc
 case .captureWithoutDeclaration(_, let loc): return loc
 case .invalidCaptureTarget(_, _, let loc): return loc
 }
 }

 private func location(of err: TypeError) -> SourceLocation {
 switch err {
 case .mismatch(_, _, let loc): return loc
 case .undefined(_, let loc): return loc
 case .cannotInfer(let loc): return loc
 case .invalidOperation(_, _, let loc): return loc
 case .argumentCountMismatch(_, _, let loc): return loc
 case .genericArgumentCountMismatch(_, _, _, let loc): return loc
 case .traitRequirementNotSatisfied(_, _, _, let loc): return loc
 case .traitMethodSignatureMismatch(_, _, _, _, let loc): return loc
 case .unknownMember(_, _, let loc): return loc
 case .reassignmentToImmutable(_, let loc): return loc
 case .inaccessibleSymbol(_, _, _, let loc): return loc
 case .inaccessibleField(_, _, let loc): return loc
 case .sharedReferenceAcrossTasks(_, _, _, let loc): return loc
 case .enumCaseArgumentLabel(_, _, let loc): return loc
 }
 }
}

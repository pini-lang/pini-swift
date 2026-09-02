import Foundation

/// T1 诊断体系（2026-08-24 批次 A）：为全部错误类型附加 code / severity / span / suggestion。
///
/// 设计：最小侵入——错误枚举自身结构不变（payload + location），经 `DiagnosticProviding`
/// 协议扩展附加诊断元数据；`ErrorFormatter` 消费协议渲染（错误码 + 跨度 + 建议）。
/// 错误码域：E0 通用 / E1 词法 / E2 语法 / E3 语义 / E4 类型 / E5 运行时 / E6 IR 生成。

/// 诊断码域前缀（枚举级段号）。
public enum DiagnosticDomain: String {
 case general = "E0"
 case lexer = "E1"
 case parser = "E2"
 case semantic = "E3"
 case type = "E4"
 case runtime = "E5"
 case irgen = "E6"
 case warning = "E7"
}

/// 源码跨度（T1：跨度下划线渲染的最小信息；由 `SourceLocation` 可推导）。
public struct SourceSpan: Equatable {
 public let startLine: Int
 public let startColumn: Int
 public let endLine: Int
 public let endColumn: Int

 public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
 self.startLine = startLine
 self.startColumn = startColumn
 self.endLine = endLine
 self.endColumn = endColumn
 }

 /// 由单点位置构造单字符跨度。
 public init(location: SourceLocation) {
 self.startLine = location.line
 self.startColumn = location.column
 self.endLine = location.endLine
 self.endColumn = location.endColumn
 }
}

/// 诊断提供协议：错误/警告类型附加诊断元数据（错误码、严重级别、可选修复建议）。
/// 不要求错误类型携带字段——经协议扩展按 case 映射（错误枚举自身零改动）。
public protocol DiagnosticProviding {
 var diagnosticCode: String { get }
 var diagnosticSeverity: DiagnosticSeverity { get }
 var suggestion: String? { get }
 /// 错误位置（含文件名；渲染 header「at file:line:col」用）。
 var diagnosticLocation: SourceLocation { get }
 /// 渲染跨度（默认 = 单点位置；多字符跨度由诊断源提供 end）。
 var span: SourceSpan { get }
}

extension DiagnosticProviding {
 public var span: SourceSpan {
 SourceSpan(location: diagnosticLocation)
 }
}

// MARK: - 8 类错误枚举的 DiagnosticProviding 扩展（A1）

extension PiniError: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .lexer: return "\(DiagnosticDomain.general.rawValue)-101"
 case .parser: return "\(DiagnosticDomain.general.rawValue)-102"
 case .typeCheck: return "\(DiagnosticDomain.general.rawValue)-103"
 case .semantic: return "\(DiagnosticDomain.general.rawValue)-104"
 case .runtime: return "\(DiagnosticDomain.general.rawValue)-105"
 case .io: return "\(DiagnosticDomain.general.rawValue)-106"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .error }
 public var suggestion: String? { nil }
 public var diagnosticLocation: SourceLocation {
 switch self {
 case .lexer(_, let loc), .parser(_, let loc), .typeCheck(_, let loc),
 .semantic(_, let loc), .runtime(_, let loc):
 return loc
 case .io:
 return SourceLocation(line: 0, column: 0, fileName: "")
 }
 }
}

extension LexerError: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .invalidCharacter: return "\(DiagnosticDomain.lexer.rawValue)-001"
 case .unterminatedString: return "\(DiagnosticDomain.lexer.rawValue)-002"
 case .indentationError: return "\(DiagnosticDomain.lexer.rawValue)-003"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .error }
 public var suggestion: String? { nil }
 public var diagnosticLocation: SourceLocation {
 switch self {
 case .invalidCharacter(_, let loc), .unterminatedString(let loc), .indentationError(let loc):
 return loc
 }
 }
}

extension ParserError: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .unexpectedToken: return "\(DiagnosticDomain.parser.rawValue)-001"
 case .expectedToken: return "\(DiagnosticDomain.parser.rawValue)-002"
 case .missingIndent: return "\(DiagnosticDomain.parser.rawValue)-003"
 case .missingDedent: return "\(DiagnosticDomain.parser.rawValue)-004"
 case .invalidDeclaration: return "\(DiagnosticDomain.parser.rawValue)-005"
 case .invalidExpression: return "\(DiagnosticDomain.parser.rawValue)-006"
 case .invalidStatement: return "\(DiagnosticDomain.parser.rawValue)-007"
 case .invalidType: return "\(DiagnosticDomain.parser.rawValue)-008"
 case .missingBlockBody: return "\(DiagnosticDomain.parser.rawValue)-009"
 case .missingBlockEnd: return "\(DiagnosticDomain.parser.rawValue)-010"
 case .invalidModifier: return "\(DiagnosticDomain.parser.rawValue)-011"
 case .missingParameterName: return "\(DiagnosticDomain.parser.rawValue)-012"
 case .missingReturnType: return "\(DiagnosticDomain.parser.rawValue)-013"
 case .missingFieldName: return "\(DiagnosticDomain.parser.rawValue)-014"
 case .missingCaseName: return "\(DiagnosticDomain.parser.rawValue)-015"
 case .missingMethodName: return "\(DiagnosticDomain.parser.rawValue)-016"
 case .missingTraitName: return "\(DiagnosticDomain.parser.rawValue)-017"
 case .missingStructName: return "\(DiagnosticDomain.parser.rawValue)-018"
 case .missingObjectName: return "\(DiagnosticDomain.parser.rawValue)-019"
 case .missingEnumName: return "\(DiagnosticDomain.parser.rawValue)-020"
 case .missingGenericParam: return "\(DiagnosticDomain.parser.rawValue)-021"
 case .missingLabel: return "\(DiagnosticDomain.parser.rawValue)-022"
 case .unexpectedEOF: return "\(DiagnosticDomain.parser.rawValue)-023"
 case .methodDefaultAssumptionTerminated: return "\(DiagnosticDomain.parser.rawValue)-024"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .error }
 public var suggestion: String? { nil }
 public var diagnosticLocation: SourceLocation {
 self.location
 }
 private var location: SourceLocation {
 switch self {
 case .unexpectedToken(_, _, let loc), .expectedToken(_, let loc),
 .missingIndent(let loc), .missingDedent(let loc),
 .invalidDeclaration(_, let loc), .invalidExpression(_, let loc),
 .invalidStatement(_, let loc), .invalidType(_, let loc),
 .missingBlockBody(let loc), .missingBlockEnd(let loc),
 .invalidModifier(_, let loc), .missingParameterName(let loc),
 .missingReturnType(let loc), .missingFieldName(let loc),
 .missingCaseName(let loc), .missingMethodName(let loc),
 .missingTraitName(let loc), .missingStructName(let loc),
 .missingObjectName(let loc), .missingEnumName(let loc),
 .missingGenericParam(let loc), .missingLabel(let loc),
 .unexpectedEOF(let loc), .methodDefaultAssumptionTerminated(let loc):
 return loc
 }
 }
}

extension SemanticError: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .undefinedVariable: return "\(DiagnosticDomain.semantic.rawValue)-001"
 case .undefinedFunction: return "\(DiagnosticDomain.semantic.rawValue)-002"
 case .undefinedType: return "\(DiagnosticDomain.semantic.rawValue)-003"
 case .redeclaredSymbol: return "\(DiagnosticDomain.semantic.rawValue)-004"
 case .inaccessibleSymbol: return "\(DiagnosticDomain.semantic.rawValue)-005"
 case .unknownMatchCase: return "\(DiagnosticDomain.semantic.rawValue)-006"
 case .nonExhaustiveMatch: return "\(DiagnosticDomain.semantic.rawValue)-007"
 case .captureWithoutDeclaration: return "\(DiagnosticDomain.semantic.rawValue)-008"
 case .invalidCaptureTarget: return "\(DiagnosticDomain.semantic.rawValue)-009"
 case .moduleDependencyCycle: return "\(DiagnosticDomain.semantic.rawValue)-010"
 case .moduleRootMissing: return "\(DiagnosticDomain.semantic.rawValue)-011"
 case .crossModuleAccessDenied: return "\(DiagnosticDomain.semantic.rawValue)-012"
 case .injectedSymbolConflict: return "\(DiagnosticDomain.semantic.rawValue)-013"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .error }
 public var suggestion: String? {
 switch self {
 // B1（did-you-mean）接入点：suggestion 由建议引擎动态填充，静态占位 nil。
 case .undefinedVariable, .undefinedFunction, .undefinedType:
 return nil
 default:
 return nil
 }
 }
 public var diagnosticLocation: SourceLocation {
 switch self {
 case .undefinedVariable(_, let loc), .undefinedFunction(_, let loc),
 .undefinedType(_, let loc), .redeclaredSymbol(_, let loc),
 .inaccessibleSymbol(_, _, _, let loc), .unknownMatchCase(_, let loc),
 .nonExhaustiveMatch(_, let loc), .captureWithoutDeclaration(_, let loc),
 .invalidCaptureTarget(_, _, let loc), .captureWithoutDeclaration(_, let loc),
 .crossModuleAccessDenied(_, let loc),
 .injectedSymbolConflict(_, _, let loc):
 return loc
 case .moduleDependencyCycle, .moduleRootMissing:
 return SourceLocation(line: 0, column: 0, endLine: 0, endColumn: 0, fileName: "未知文件")
 }
 }
}

extension TypeError: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .mismatch: return "\(DiagnosticDomain.type.rawValue)-001"
 case .undefined: return "\(DiagnosticDomain.type.rawValue)-002"
 case .cannotInfer: return "\(DiagnosticDomain.type.rawValue)-003"
 case .invalidOperation: return "\(DiagnosticDomain.type.rawValue)-004"
 case .argumentCountMismatch: return "\(DiagnosticDomain.type.rawValue)-005"
 case .genericArgumentCountMismatch: return "\(DiagnosticDomain.type.rawValue)-006"
 case .traitRequirementNotSatisfied: return "\(DiagnosticDomain.type.rawValue)-007"
 case .traitMethodSignatureMismatch: return "\(DiagnosticDomain.type.rawValue)-008"
 case .unknownMember: return "\(DiagnosticDomain.type.rawValue)-009"
 case .reassignmentToImmutable: return "\(DiagnosticDomain.type.rawValue)-010"
 case .inaccessibleSymbol: return "\(DiagnosticDomain.type.rawValue)-011"
 case .inaccessibleField: return "\(DiagnosticDomain.type.rawValue)-012"
 case .sharedReferenceAcrossTasks: return "\(DiagnosticDomain.type.rawValue)-013"
 case .enumCaseArgumentLabel: return "\(DiagnosticDomain.type.rawValue)-014"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .error }
 public var suggestion: String? { nil }
 public var diagnosticLocation: SourceLocation {
 self.location
 }
 private var location: SourceLocation {
 switch self {
 case .mismatch(_, _, let loc), .undefined(_, let loc), .cannotInfer(let loc),
 .invalidOperation(_, _, let loc), .argumentCountMismatch(_, _, let loc),
 .genericArgumentCountMismatch(_, _, _, let loc),
 .traitRequirementNotSatisfied(_, _, _, let loc),
 .traitMethodSignatureMismatch(_, _, _, _, let loc),
 .unknownMember(_, _, let loc), .reassignmentToImmutable(_, let loc),
 .inaccessibleSymbol(_, _, _, let loc), .inaccessibleField(_, _, let loc),
 .sharedReferenceAcrossTasks(_, _, _, let loc),
 .enumCaseArgumentLabel(_, _, let loc):
 return loc
 }
 }
}

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
 .symbolNotFound(_, _, let loc):
 return loc
 }
 }
}

extension IRGenError: DiagnosticProviding {
 public var diagnosticCode: String {
 switch self {
 case .unsupportedType: return "\(DiagnosticDomain.irgen.rawValue)-001"
 case .unsupportedExpression: return "\(DiagnosticDomain.irgen.rawValue)-002"
 case .unsupportedStatement: return "\(DiagnosticDomain.irgen.rawValue)-003"
 case .unsupportedFeature: return "\(DiagnosticDomain.irgen.rawValue)-004"
 case .typeMismatch: return "\(DiagnosticDomain.irgen.rawValue)-005"
 }
 }
 public var diagnosticSeverity: DiagnosticSeverity { .error }
 public var suggestion: String? { nil }
 public var diagnosticLocation: SourceLocation {
 switch self {
 case .unsupportedType(_, let loc), .unsupportedExpression(_, let loc),
 .unsupportedStatement(_, let loc), .unsupportedFeature(_, let loc),
 .typeMismatch(_, _, let loc):
 return loc
 }
 }
}

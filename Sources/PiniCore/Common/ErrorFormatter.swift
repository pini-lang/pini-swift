import Foundation

/// 错误格式化器（T1/T11，2026-08-24 批次 A 重写）
/// 诊断驱动渲染：错误码 + 严重级别 + 源码行 + 跨度下划线（多字符 `~~~`）+ 修复建议 + 可选 ANSI 颜色。
/// 语言策略：消息统一中文（T11；此前 ErrorFormatter 英文 vs RuntimeError.description 中文的双轨已收敛）。
public enum ErrorFormatter {

 // MARK: - 核心渲染

 /// 渲染一段诊断（含错误码 / 严重级别 / 源码行 / 跨度下划线 / 建议 / 可选颜色）。
 public static func format(
 errorType: String,
 message: String,
 location: SourceLocation,
 source: String,
 code: String? = nil,
 severity: DiagnosticSeverity = .error,
 suggestion: String? = nil,
 span: SourceSpan? = nil,
 colorize: Bool = false
 ) -> String {
 let s = span ?? SourceSpan(location: location)
 let severityLabel = severity == .warning ? "Warning" : "Error"
 let codeSuffix = code.map { " [\($0)]" } ?? ""
 let sevColor = severity == .warning ? "\u{1B}[33m" : "\u{1B}[31m"
 let reset = "\u{1B}[0m"
 var result: String
 if colorize {
 result = "\(sevColor)\(severityLabel)\(reset): \(errorType)\(codeSuffix)\n"
 } else {
 result = "\(severityLabel): \(errorType)\(codeSuffix)\n"
 }
  if location.line > 0 {
   result += "  at \(location.fileName):\(location.line):\(location.column)\n"
  }
 result += "\n"

 let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
 let lineIndex = s.startLine - 1
 if lineIndex >= 0 && lineIndex < lines.count {
  let sourceLine = String(lines[lineIndex])
  result += "  \(sourceLine)\n"

 let caretColumn = max(0, s.startColumn - 1)
 let padding = String(repeating: " ", count: caretColumn)
 let underlineLen: Int
 if s.endLine == s.startLine && s.endColumn > s.startColumn {
 underlineLen = max(1, s.endColumn - s.startColumn)
 } else {
 underlineLen = 1
 }
 let underline = String(repeating: "~", count: underlineLen)
  if colorize {
   result += "  \(padding)\(sevColor)\(underline)\(reset)\n"
  } else {
   result += "  \(padding)\(underline)\n"
  }
 }

 if let sug = suggestion, !sug.isEmpty {
 result += " help: \(sug)\n"
 }
 result += "\n"
 result += message
 return result
 }

 // MARK: - 诊断驱动入口（协议元数据 + 中文消息）

 /// 任意符合 `DiagnosticProviding` 的错误 → 完整诊断渲染（CLI 主入口）。
 /// `language` 缺省用全局当前语言（CLI --lang）；LSP 等按自身上下文显式传入（与全局解耦）。
 public static func formatDiagnostic(_ error: Error, source: String, colorize: Bool = false, language: DiagnosticLanguage? = nil) -> String {
 if let d = error as? any DiagnosticProviding {
 var args = diagnosticArgs(of: error)
 var suggestion = d.suggestion
 // B1（did-you-mean）：undefined 变量/函数/类型（E3-001/002/003）且无显式建议时，
 // 从源码词法标识符计算最近候选，填充 {closest}（资源模板驱动，占位未满足自动隐藏）。
 if suggestion == nil, ["E3-001", "E3-002", "E3-003"].contains(d.diagnosticCode),
 let target = args["name"], !source.isEmpty,
 let closest = SuggestionEngine.suggest(target: target, candidates: SuggestionEngine.identifiers(in: source)) {
 args["closest"] = closest
 suggestion = DiagnosticResources.shared.suggestion(code: d.diagnosticCode, args: args, language: language)
 }
 return format(
 errorType: typeLabel(of: error, language: language),
 message: message(of: error, language: language),
 location: location(of: error),
 source: source,
 code: d.diagnosticCode,
 severity: d.diagnosticSeverity,
 suggestion: suggestion,
 span: d.span,
 colorize: colorize
 )
 }
 return "Error: \(error.localizedDescription)"
 }

 /// 错误类型标签（`language` 缺省用全局当前语言；经 TOML 资源切换，兜底中文）。
 public static func typeLabel(of error: Error, language: DiagnosticLanguage? = nil) -> String {
 let key: String
 let fallback: String
 switch error {
 case is LexerError: key = "lexer"; fallback = "词法错误"
 case is ParserError: key = "parser"; fallback = "语法错误"
 case is SemanticError: key = "semantic"; fallback = "语义错误"
 case is SemanticWarning: key = "semanticWarning"; fallback = "语义警告"
 case is TypeError: key = "type"; fallback = "类型错误"
 case is RuntimeError: key = "runtime"; fallback = "运行时错误"
 case is IRGenError: key = "irgen"; fallback = "IR 生成错误"
 case let e as PiniError:
 switch e {
 case .lexer: key = "lexer"; fallback = "词法错误"
 case .parser: key = "parser"; fallback = "语法错误"
 case .typeCheck: key = "type"; fallback = "类型错误"
 case .semantic: key = "semantic"; fallback = "语义错误"
 case .runtime: key = "runtime"; fallback = "运行时错误"
 case .io: key = "io"; fallback = "IO 错误"
 }
 default: key = "general"; fallback = "错误"
 }
 return DiagnosticResources.shared.label(key: key, language: language, fallback: fallback)
 }

 /// 从错误提取位置（协议诊断位置，含文件名）。
 public static func location(of error: Error) -> SourceLocation {
 if let d = error as? any DiagnosticProviding {
 return d.diagnosticLocation
 }
 return SourceLocation(line: 0, column: 0, fileName: "未知文件")
 }

 /// 错误消息：TOML 语言资源优先（code → 模板 + 参数填充），资源未覆盖时硬编码兜底。
 public static func message(of error: Error, language: DiagnosticLanguage? = nil) -> String {
 if let d = error as? any DiagnosticProviding {
 let args = diagnosticArgs(of: error)
 return DiagnosticResources.shared.message(
 code: d.diagnosticCode, args: args, language: language, fallback: hardcodedMessage(of: error))
 }
 return error.localizedDescription
 }

 /// 从错误 case 关联值提取模板参数（label → String）。位置参数不入参。
 static func diagnosticArgs(of error: Error) -> [String: String] {
 guard let child = Mirror(reflecting: error).children.first else { return [:] }
 var args: [String: String] = [:]
 for case let (label?, value) in Mirror(reflecting: child.value).children where label != "location" {
 args[label] = String(describing: value)
 }
 return args
 }

 /// 硬编码兜底消息（资源未覆盖该码时使用；与 zh 资源文案一致）。
 public static func hardcodedMessage(of error: Error) -> String {
 switch error {
 case let e as LexerError:
 switch e {
 case .invalidCharacter(let ch, _): return "invalid character '\(ch)'"
 case .unterminatedString: return "unterminated string literal"
 case .indentationError: return "indentation error"
 }
 case let e as ParserError:
 return parserMessage(e)
 case let e as SemanticError:
 return semanticMessage(e)
 case let e as TypeError:
 return typeMessage(e)
 case let e as RuntimeError:
 return runtimeMessage(e)
 case let e as IRGenError:
 return irgenMessage(e)
 case let e as PiniError:
 switch e {
 case .lexer(let d, _): return d
 case .parser(let d, _): return d
 case .typeCheck(let d, _): return d
 case .semantic(let d, _): return d
 case .runtime(let d, _): return d
 case .io(let d): return d
 }
 default:
 return error.localizedDescription
 }
 }

 // MARK: - 各错误类型消息（中文）

 private static func parserMessage(_ error: ParserError) -> String {
 switch error {
 case .unexpectedToken(let expected, let actual, _): return "expected \(expected), got \(actual)"
 case .expectedToken(let token, _): return "expected token \(token)"
 case .missingIndent: return "缺少缩进"
 case .missingDedent: return "缺少反缩进"
 case .invalidDeclaration(let reason, _): return "无效声明：\(reason)"
 case .invalidExpression(let reason, _): return "无效表达式：\(reason)"
 case .invalidStatement(let reason, _): return "无效语句：\(reason)"
 case .invalidType(let reason, _): return "无效类型：\(reason)"
 case .missingBlockBody: return "缺少块体"
 case .missingBlockEnd: return "缺少块结束"
 case .invalidModifier(let reason, _): return "无效修饰符：\(reason)"
 case .missingParameterName: return "缺少参数名"
 case .missingReturnType: return "缺少返回类型"
 case .missingFieldName: return "缺少字段名"
 case .missingCaseName: return "缺少 case 名"
 case .missingMethodName: return "缺少方法名"
 case .missingTraitName: return "缺少 trait 名"
 case .missingStructName: return "缺少结构名"
 case .missingObjectName: return "缺少对象名"
 case .missingEnumName: return "缺少枚举名"
 case .missingGenericParam: return "缺少泛型参数"
 case .missingLabel: return "缺少标签"
 case .unexpectedEOF: return "意外到达文件末尾"
 case .methodDefaultAssumptionTerminated: return "块内函数必须显式声明 self 修饰符（如 `方法名|self()` 或 `方法名|Self()`）"
 }
 }

 private static func semanticMessage(_ error: SemanticError) -> String {
 switch error {
 case .undefinedVariable(let name, _): return "未定义变量 '\(name)'"
 case .undefinedFunction(let name, _): return "未定义函数 '\(name)'"
 case .undefinedType(let name, _): return "未定义类型 '\(name)'"
 case .redeclaredSymbol(let name, _): return "符号重复声明 '\(name)'"
 case .inaccessibleSymbol(let name, let definedIn, let level, _): return "符号 '\(name)'（\(level.label)）定义于 '\(definedIn)'，从当前文件不可见"
 case .unknownMatchCase(let caseName, _): return "未知 match case '\(caseName)'"
 case .nonExhaustiveMatch(let missingCases, _): return "match 未穷尽覆盖枚举：缺少 case \(missingCases.joined(separator: ", "))（需覆盖全部 case，或用 `case _:` 兜底）"
 }
 }

 private static func typeMessage(_ error: TypeError) -> String {
 switch error {
 case .mismatch(let expected, let got, _): return "类型不匹配：期望 \(expected)，实际得到 \(got)"
 case .undefined(let name, _): return "未定义类型 '\(name)'"
 case .cannotInfer: return "无法推断类型"
 case .invalidOperation(let op, let type, _): return "对类型 '\(type)' 执行 '\(op)' 无效"
 case .argumentCountMismatch(let expected, let got, _): return "参数数量不匹配：期望 \(expected) 个，实际 \(got) 个"
 case .genericArgumentCountMismatch(let typeName, let expected, let got, _): return "泛型 '\(typeName)' 类型实参数量不匹配：期望 \(expected)，实际 \(got)"
 case .traitRequirementNotSatisfied(let typeName, let traitName, let methodName, _): return "类型 '\(typeName)' 声明实现 trait '\(traitName)' 但未提供抽象方法 '\(methodName)'"
 case .traitMethodSignatureMismatch(let typeName, let traitName, let methodName, let detail, _): return "类型 '\(typeName)' 实现 trait '\(traitName)' 的方法 '\(methodName)' 签名不符：\(detail)"
 case .unknownMember(let typeName, let memberName, _): return "类型 '\(typeName)' 没有成员 '\(memberName)'"
 case .reassignmentToImmutable(let variableName, _): return "不能对 'let' 不可变变量 '\(variableName)' 重新赋值"
 case .inaccessibleSymbol(let name, let definedIn, let level, _): return "符号 '\(name)'（\(level.label)）定义于 '\(definedIn)'，从当前文件不可见"
 case .inaccessibleField(let typeName, let fieldName, _): return "字段 '\(typeName).\(fieldName)' 为 type-private（仅 \(typeName) 类型自身的方法可访问）"
 case .sharedReferenceAcrossTasks(let typeName, let paramName, let functionName, _): return "不能把引用类型 '\(typeName)' 传给并发进程 '\(functionName)' 的形参 '\(paramName)'：跨任务共享可变引用不安全。改传值类型（struct），或让 '\(functionName)' 返回结果后用 `joinAll` 汇合"
 case .enumCaseArgumentLabel(let label, let caseName, _): return "枚举用例 '\(caseName)' 的构造为位置式，不允许具名实参 '\(label):'（请改为位置实参，如 `\(caseName)(值)`）"
 }
 }

 private static func irgenMessage(_ error: IRGenError) -> String {
 switch error {
 case .unsupportedType(let name, _): return "不支持的类型 '\(name)'"
 case .unsupportedExpression(let kind, _): return "不支持的表达式 '\(kind)'"
 case .unsupportedStatement(let kind, _): return "不支持的语句 '\(kind)'"
 case .unsupportedFeature(let feature, _): return "不支持的特性 '\(feature)'"
 case .typeMismatch(let expected, let got, _): return "类型不匹配：期望 '\(expected)'，实际 '\(got)'"
 }
 }

 private static func runtimeMessage(_ error: RuntimeError) -> String {
 switch error {
 case .undefinedVariable(let name, _): return "未定义变量 '\(name)'"
 case .immutableVariable(let name, _): return "不可修改的变量 '\(name)'"
 case .typeMismatch(let expected, let got, _): return "类型不匹配：期望 \(expected)，实际得到 \(got)"
 case .divisionByZero: return "除以零"
 case .indexOutOfRange: return "索引越界"
 case .invalidOperation(let reason, _): return "无效操作：\(reason)"
 case .mainNotFound: return "未找到 main 函数"
 case .notCallable: return "值不可调用"
 case .arityMismatch(let expected, let got, _): return "参数数量不匹配：期望 \(expected) 个，实际 \(got) 个"
 case .inaccessibleField(let typeName, let fieldName, _): return "无法访问私有字段 '\(typeName).\(fieldName)'：该字段为 type-private，仅 \(typeName) 类型自身的方法可访问"
 case .taskCancelled(let reason, _): return reason
 case .matchNotExhaustive(let value, _): return "match 未穷尽：值 '\(value)' 未匹配任何 case 且无 `case _:` 兜底"
 case .assertionFailed(let message, _): return "断言失败：\(message)"
 case .argumentCountMismatch(let name, let expected, let got, _): return "原生函数 \(name) 参数数量不匹配：期望 \(expected) 个，实际 \(got) 个"
 case .undefinedNativeFunction(let name, let available, _): return "未注册的原生函数 '\(name)'（`[名称|foreign]` 声明的 C 函数须在原生函数表内）；可用：\(available.isEmpty ? "（无）" : available.joined(separator: ", "))"
 case .libraryNotFound(let library, let searched, _): return "FFI 库 '\(library)' 未找到（已搜索：\(searched.isEmpty ? "（无搜索路径）" : searched.joined(separator: ", "))）"
 case .symbolNotFound(let library, let symbol, _): return "FFI 库 '\(library)' 中未找到符号 '\(symbol)'"
 }
 }

 // MARK: - 旧入口（向后兼容；统一转发到 formatDiagnostic；language 缺省用全局）

 public static func formatPiniError(_ error: PiniError, source: String, language: DiagnosticLanguage? = nil) -> String {
 formatDiagnostic(error, source: source, language: language)
 }
 public static func formatParserError(_ error: ParserError, source: String, language: DiagnosticLanguage? = nil) -> String {
 formatDiagnostic(error, source: source, language: language)
 }
 public static func formatSemanticError(_ error: SemanticError, source: String, language: DiagnosticLanguage? = nil) -> String {
 formatDiagnostic(error, source: source, language: language)
 }
 public static func formatTypeError(_ error: TypeError, source: String, language: DiagnosticLanguage? = nil) -> String {
 formatDiagnostic(error, source: source, language: language)
 }
 public static func formatRuntimeError(_ error: RuntimeError, source: String, language: DiagnosticLanguage? = nil) -> String {
 formatDiagnostic(error, source: source, language: language)
 }
}

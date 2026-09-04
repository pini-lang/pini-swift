import Foundation

/// 解析结果：成功产出的 AST 模块 + 收集到的全部解析错误。
/// 用于『多错误同报』场景（P2-4.1 / P2-4.3），配合 `Parser.parseModuleCollectingErrors()`。
public struct ParseResult {
 public let module: Module
 public let errors: [ParserError]

 public init(module: Module, errors: [ParserError]) {
 self.module = module
 self.errors = errors
 }
}

public class Parser {
 private let tokens: [Token]
 private let fileName: String
 private var position: Int = 0
 
 // 错误收集模式状态（P2-4.2 panic-mode 恢复）：收集模式下语句级错误就地记录并跳过恢复，
 // 而非向上冒泡导致整个声明体丢失并生成伪顶级声明。
 private var collectMode: Bool = false
 /// 批 6 D-4 前置：多项 import 块的首项之后的余项缓冲（parseModuleImpl 逐位排干）。
 private var pendingImportDecls: [ImportDecl] = []
 private var diagnostics: [ParserError] = []
 
 public init(tokens: [Token], fileName: String) {
 self.tokens = tokens
 self.fileName = fileName
 }
 
 // MARK: - 辅助方法
 
 private var currentToken: Token {
 guard position < tokens.count else {
 return .eof(SourceLocation(line: 0, column: 0, fileName: fileName))
 }
 return tokens[position]
 }
 
 private var currentLocation: SourceLocation {
 return currentToken.location
 }
 
 @discardableResult
 private func advance() -> Token {
 let token = currentToken
 position += 1
 return token
 }
 
 private func peek(offset: Int = 1) -> Token {
 let idx = position + offset
 guard idx < tokens.count else {
 return .eof(SourceLocation(line: 0, column: 0, fileName: fileName))
 }
 return tokens[idx]
 }
 
 private func check(_ expected: Token) -> Bool {
 switch (currentToken, expected) {
 case (.keyword(let k1, _), .keyword(let k2, _)): return k1 == k2
 case (.identifier(_, _), .identifier(_, _)): return true
 case (.integerLiteral(_, _), .integerLiteral(_, _)): return true
 case (.floatLiteral(_, _), .floatLiteral(_, _)): return true
 case (.stringLiteral(_, _), .stringLiteral(_, _)): return true
 case (.boolLiteral(_, _), .boolLiteral(_, _)): return true
 case (.plus(_), .plus(_)): return true
 case (.minus(_), .minus(_)): return true
 case (.star(_), .star(_)): return true
 case (.slash(_), .slash(_)): return true
 case (.percent(_), .percent(_)): return true
 case (.increment(_), .increment(_)): return true
 case (.decrement(_), .decrement(_)): return true
 case (.logicalAnd(_), .logicalAnd(_)): return true
 case (.logicalOr(_), .logicalOr(_)): return true
 case (.logicalNot(_), .logicalNot(_)): return true
 case (.equal(_), .equal(_)): return true
 case (.notEqual(_), .notEqual(_)): return true
 case (.lessThanOrEqual(_), .lessThanOrEqual(_)): return true
 case (.greaterThanOrEqual(_), .greaterThanOrEqual(_)): return true
 case (.lessThan(_), .lessThan(_)): return true
 case (.greaterThan(_), .greaterThan(_)): return true
 case (.bitwiseAnd(_), .bitwiseAnd(_)): return true
 case (.bitwiseXor(_), .bitwiseXor(_)): return true
 case (.bitwiseNot(_), .bitwiseNot(_)): return true
 case (.leftShift(_), .leftShift(_)): return true
 case (.rightShift(_), .rightShift(_)): return true
 case (.assign(_), .assign(_)): return true
 case (.plusAssign(_), .plusAssign(_)): return true
 case (.minusAssign(_), .minusAssign(_)): return true
 case (.multiplyAssign(_), .multiplyAssign(_)): return true
 case (.divideAssign(_), .divideAssign(_)): return true
 case (.moduloAssign(_), .moduloAssign(_)): return true
 case (.andAssign(_), .andAssign(_)): return true
 case (.orAssign(_), .orAssign(_)): return true
 case (.xorAssign(_), .xorAssign(_)): return true
 case (.leftShiftAssign(_), .leftShiftAssign(_)): return true
 case (.rightShiftAssign(_), .rightShiftAssign(_)): return true
 case (.leftParen(_), .leftParen(_)): return true
 case (.rightParen(_), .rightParen(_)): return true
 case (.leftBracket(_), .leftBracket(_)): return true
 case (.rightBracket(_), .rightBracket(_)): return true
 case (.leftBrace(_), .leftBrace(_)): return true
 case (.rightBrace(_), .rightBrace(_)): return true
 case (.colon(_), .colon(_)): return true
 case (.comma(_), .comma(_)): return true
 case (.arrow(_), .arrow(_)): return true
 case (.doubleArrow(_), .doubleArrow(_)): return true
 case (.pipe(_), .pipe(_)): return true
 case (.dot(_), .dot(_)): return true
 case (.indent(_), .indent(_)): return true
 case (.dedent(_), .dedent(_)): return true
 case (.newline(_), .newline(_)): return true
 case (.eof(_), .eof(_)): return true
 default: return false
 }
 }
 
 private func checkKeyword(_ keyword: Keyword) -> Bool {
 if case .keyword(keyword, _) = currentToken {
 return true
 }
 return false
 }
 
 private func expect(_ expected: Token) throws -> Token {
 if check(expected) {
 return advance()
 }
 let expectedDesc = tokenDescription(expected)
 let actualDesc = tokenDescription(currentToken)
 throw ParserError.unexpectedToken(expected: expectedDesc, actual: actualDesc, location: currentLocation)
 }
 
 private func expectKeyword(_ keyword: Keyword) throws {
 if case .keyword(keyword, _) = currentToken {
 advance()
 return
 }
 let actualDesc = tokenDescription(currentToken)
 throw ParserError.unexpectedToken(expected: keyword.rawValue, actual: actualDesc, location: currentLocation)
 }
 
 private func match(_ expected: Token) -> Bool {
 if check(expected) {
 advance()
 return true
 }
 return false
 }
 
 private func matchKeyword(_ keyword: Keyword) -> Bool {
 if case .keyword(keyword, _) = currentToken {
 advance()
 return true
 }
 return false
 }
 
 private func isNewline() -> Bool {
 if case .newline(_) = currentToken {
 return true
 }
 return false
 }
 
 private func skipNewlines() {
 while isNewline() {
 advance()
 }
 }

 private func peekPastNewlines(offset: Int = 1) -> Token {
 var idx = position + offset
 while idx < tokens.count {
 let t = tokens[idx]
 if case .newline = t {
 idx += 1
 continue
 }
 return t
 }
 return .eof(SourceLocation(line: 0, column: 0, fileName: fileName))
 }
 
 private func isEOF() -> Bool {
 if case .eof(_) = currentToken {
 return true
 }
 return false
 }
 
 private func tokenDescription(_ token: Token) -> String {
 switch token {
 case .indent: return "INDENT"
 case .dedent: return "DEDENT"
 case .newline: return "NEWLINE"
 case .eof: return "EOF"
 default: return token.lexeme
 }
 }
 
 // MARK: - 顶级解析
 
 // MARK: - 模块解析入口

 public func parseModule() throws -> Module {
 let result = parseModuleImpl(collectErrors: false)
 if let first = result.errors.first {
 throw first
 }
 return Desugar.desugar(result.module)
 }

 /// 收集模式入口：不抛出，返回 `(module, errors)`，单文件可一次性报多错（P2-4.1）。
 public func parseModuleCollectingErrors() -> ParseResult {
 let result = parseModuleImpl(collectErrors: true)
 return ParseResult(module: Desugar.desugar(result.module), errors: result.errors)
 }

 private func parseModuleImpl(collectErrors: Bool) -> ParseResult {
 var declarations: [TopLevelDecl] = []
 var imports: [ImportDecl] = []
 var exports: [ExportDecl] = []
 let startLocation = currentLocation
 self.collectMode = collectErrors
 if collectErrors { self.diagnostics = [] }

 skipNewlines()

 while !isEOF() {
 do {
 let decl = try parseTopLevelDecl()
 switch decl {
 case .importDecl(let imp):
 imports.append(imp)
 case .exportDecl(let exp):
 exports.append(exp)
 default:
 declarations.append(decl)
 }
 // 批 6 D-4 前置：排干多项 import 块的余项（保持书写顺序进 imports）
 if !pendingImportDecls.isEmpty {
 imports.append(contentsOf: pendingImportDecls)
 pendingImportDecls = []
 }
 } catch let error as ParserError {
 if !collectErrors {
 // 旧语义：遇首个错即抛
 return ParseResult(module: Module(declarations: declarations, location: startLocation),
 errors: [error])
 }
 // 收集模式：记录错误并 resync 到下一顶级声明继续解析
 self.diagnostics.append(error)
 resyncToNextTopLevelDecl()
 } catch {
 let wrapped = ParserError.unexpectedToken(
 expected: "—", actual: String(describing: error), location: currentLocation)
 if !collectErrors {
 return ParseResult(module: Module(declarations: declarations, location: startLocation),
 errors: [wrapped])
 }
 self.diagnostics.append(wrapped)
 resyncToNextTopLevelDecl()
 }
 skipNewlines()
 }

 return ParseResult(module: Module(declarations: declarations,
 imports: imports,
 exports: exports,
 location: startLocation),
 errors: collectErrors ? self.diagnostics : [])
 }

 /// 跳到下一源码行的起点，使顶级循环能尝试解析后续声明。
 /// 保证至少前进一次，避免在同一失败 token 上重试导致死循环（P2-4.1 resync）。
 private func resyncToNextTopLevelDecl() {
 var advanced = false
 var iterations = 0
 let maxIterations = tokens.count + 4
 while !isEOF() && iterations < maxIterations {
 iterations += 1
 let previousWasNewline = position > 0
 && (position - 1 < tokens.count)
 && isNewlineToken(tokens[position - 1])
 if advanced && previousWasNewline {
 return
 }
 advance()
 advanced = true
 }
 }

 private func isNewlineToken(_ token: Token) -> Bool {
 if case .newline = token { return true }
 return false
 }

 /// 在收集模式下尝试解析一条语句；失败时记录错误并跳过到下一行边界恢复，
 /// 使单个声明体内也能一次性收集多个语句级错误（P2-4.2 panic-mode 恢复）。
 /// 非收集模式下任一错误直接向上冒泡——保留『遇错即抛』旧语义，现有调用方零改动。
 private func parseStatementWithRecovery(into statements: inout [Statement]) throws {
 do {
 let stmt = try parseStatement()
 statements.append(stmt)
 } catch let error as ParserError {
 if !collectMode {
 throw error
 }
 diagnostics.append(error)
 resyncToNextLineOrBlockEnd()
 } catch {
 if !collectMode {
 throw error
 }
 diagnostics.append(ParserError.unexpectedToken(
 expected: "—", actual: String(describing: error), location: currentLocation))
 resyncToNextLineOrBlockEnd()
 }
 }

 /// 跳过当前损坏语句，定位到下一行起点（停在 NEWLINE 之前）或块结束（DEDENT / EOF）。
 /// 保证至少前进一次，避免在同一失败 token 上重试导致死循环（P2-4.2 恢复）。
 /// 不吞掉 DEDENT：停在它之前，由外层 `while !check(.dedent)` 自然结束块；停在 NEWLINE 之前，
 /// 由外层 `skipNewlines()` 跨过后即新行起点继续解析——从而在同一声明体内报多错。
 private func resyncToNextLineOrBlockEnd() {
 if check(.dedent(currentLocation)) || isEOF() {
 return
 }
 var advanced = false
 var iterations = 0
 let maxIterations = tokens.count + 4
 while !isEOF() && !check(.dedent(currentLocation)) && iterations < maxIterations {
 iterations += 1
 if advanced && isNewline() {
 // 当前 token 是 NEWLINE：停在它之前，下一轮 skipNewlines 后即新行起点
 return
 }
 advance()
 advanced = true
 }
 }
 
 // MARK: - 顶级声明解析
 
 private func parseTopLevelDecl() throws -> TopLevelDecl {
 // G52 批 1（2026-08-31）：顶级裸 `import X` / `export X` 语句已移除——
 // 块形式 `[当前文件名|import]` 是唯一顶级形态（本语言顶级无裸语句空间）。
 if checkKeyword(.import) {
 throw ParserError.invalidDeclaration(
 reason: "顶级裸 import 已移除（G52 批 1）：改用块形式 `[当前文件名|import]` 加 `别名 = 包路径字符串`",
 location: currentLocation
 )
 }
 if checkKeyword(.export) {
 throw ParserError.invalidDeclaration(
 reason: "顶级裸 export 已移除（G52 批 1）：改用块形式 `[当前文件名|export]` + `可见别名 = 原符号`",
 location: currentLocation
 )
 }

 // 根据括号类型分派（ADR-016 规则 3.2/3.14：行首 `((`/`{{`/`[[`/`<<` 双定界符 → 扩展块）
 switch currentToken {
 case .leftParen(_):
 if case .leftParen(_) = peek(offset: 1) {
 return .extensionDecl(try parseExtensionDecl())
 }
 return .structDecl(try parseStructDecl())
 case .leftBracket(_):
 if case .leftBracket(_) = peek(offset: 1) {
 return .extensionDecl(try parseExtensionDecl())
 }
 return try parseBracketDecl()
 case .leftBrace(_):
 if case .leftBrace(_) = peek(offset: 1) {
 return .extensionDecl(try parseExtensionDecl())
 }
 // 区分花括号函数声明 `{name}(...)` 与花括号对象声明 `{name}`
 if isBraceFuncDecl() {
 return .funcDecl(try parseFuncDecl(isTopLevel: true))
 } else {
 return .objectDecl(try parseObjectDecl())
 }
 case .lessThan(_):
 // 行首 `<<` → 特征扩展；`<名称>` → 特征声明
 if case .lessThan(_) = peek(offset: 1) {
 return .extensionDecl(try parseExtensionDecl())
 }
 // 特征体声明头：<名称>
 if isTopLevelDeclStart() {
 return .traitDecl(try parseTraitDecl())
 }
 // 否则作为表达式语句处理（< 用作比较运算符）
 return .statement(try parseStatement())
 default:
 // 检查是否是裸函数声明 `name(params,) -> (ret,)`
 if isBareFunctionDeclStart() {
 return .funcDecl(try parseBareFuncDecl(isTopLevel: true, allowUnsafeModifier: true))
 }
 // 否则可能是变量声明、表达式语句等
 return .statement(try parseStatement())
 }
 }

 // MARK: - import / export 声明解析（P4 模块化，Phase 2 仅解析暂存）

 /// 当前文件名（去 `.pini` 后缀）——import/export 块头名的校验基准（D-1）。
 private var currentFileBaseName: String {
 let base = (fileName as NSString).lastPathComponent
 return base.hasSuffix(".pini") ? String(base.dropLast(5)) : base
 }

 /// 解析 `[当前文件名|import]` 块：`别名 = "包路径"` 项集（顶格块，下一顶级形态行闭合）。
 private func parseImportBlock(headerName: String, location: SourceLocation) throws -> ImportDecl {
 guard headerName == currentFileBaseName else {
 throw ParserError.invalidDeclaration(
 reason: "import 块头名须为当前文件名 `\(currentFileBaseName)`（D-1：自识性标签），实际 `\(headerName)`",
 location: location
 )
 }
 var items: [(alias: String, path: String)] = []
 skipNewlines()
 while !isEOF() {
 // 项行形态：IDENT = STRING
 guard case .identifier(let alias, _) = currentToken else { break }
 guard case .assign(_) = peek() else { break }
 advance() // 别名
 advance() // =
 guard case .stringLiteral(let path, _) = currentToken else {
 throw ParserError.invalidDeclaration(
 reason: "import 项须为 `别名 = 包路径字符串`", location: currentLocation)
 }
 advance()
 items.append((alias: alias, path: path))
 skipNewlines()
 }
 guard let first = items.first else {
 throw ParserError.invalidDeclaration(reason: "import 块至少需要一项 `别名 = \"包路径\"`", location: location)
 }
 // 批 6 D-4 前置（原批 1 单项限制解除）：多项 `别名 = "包路径"` 各自成一条 ImportDecl；
 // 首项照旧返回，余项入 pending 缓冲，由 parseModuleImpl 在本声明位排干（保持声明顺序）。
 pendingImportDecls.append(contentsOf: items.dropFirst().map {
 ImportDecl(alias: $0.alias, packagePath: $0.path, location: location)
 })
 return ImportDecl(alias: first.alias, packagePath: first.path, location: location)
 }

 /// 解析 `[当前文件名|export]` 块：`可见别名 = 原符号` 项集。
 private func parseExportBlock(headerName: String, location: SourceLocation) throws -> ExportDecl {
 guard headerName == currentFileBaseName else {
 throw ParserError.invalidDeclaration(
 reason: "export 块头名须为当前文件名 `\(currentFileBaseName)`（D-1：自识性标签），实际 `\(headerName)`",
 location: location
 )
 }
 var renames: [ExportRename] = []
 skipNewlines()
 while !isEOF() {
 // 项行形态：IDENT = IDENT（下一顶级形态的行首即闭合——先看后吃）
 guard case .identifier(let alias, let itemLoc) = currentToken else { break }
 guard case .assign(_) = peek() else { break }
 advance()
 advance()
 guard case .identifier(let symbol, _) = currentToken else {
 throw ParserError.invalidDeclaration(
 reason: "export 项须为 `可见别名 = 原符号`", location: currentLocation)
 }
 advance()
 renames.append(ExportRename(alias: alias, symbol: symbol, location: itemLoc))
 skipNewlines()
 }
 guard !renames.isEmpty else {
 throw ParserError.invalidDeclaration(reason: "export 块至少需要一项 `可见别名 = 原符号`", location: location)
 }
 return ExportDecl(renames: renames, location: location)
 }

 private func parseBracketDecl() throws -> TopLevelDecl {
 let loc = currentLocation
 advance() // 跳过 [
 
 // 解析名称
 let name = try parseIdentifier()

 // 解析可选泛型形参 <T, E>（枚举/对象/引用均可带）
 var genericParams: [GenericParam] = []
 if case .lessThan(_) = currentToken {
 genericParams = try parseGenericParams()
 }

 // 检查是否有 | 修饰符
 var isObject = false
 var isEnum = false

 if case .pipe(_) = currentToken {
 advance()
 if checkKeyword(.object) {
 advance()
 isObject = true
 } else if checkKeyword(.enum) {
 advance()
 isEnum = true
 } else if checkKeyword(.foreign) {
 // Phase 2a（ADR-015 FFI， foreign-decl）：`[名称|foreign]` 外部 C 函数声明块。
 advance()
 try expect(.rightBracket(loc))
 return .foreignDecl(try parseForeignDecl(name: name, location: loc))
 } else if checkKeyword(.import) {
 // G52 批 1（D-1 裁决）：`[当前文件名|import]` 块——引入外部模块。
 advance()
 try expect(.rightBracket(loc))
 return .importDecl(try parseImportBlock(headerName: name, location: loc))
 } else if checkKeyword(.export) {
 // G52 批 1（D-1 裁决）：`[当前文件名|export]` 块——显式导出表。
 advance()
 try expect(.rightBracket(loc))
 return .exportDecl(try parseExportBlock(headerName: name, location: loc))
 } else {
 throw ParserError.invalidDeclaration(reason: "无效的方括号声明修饰符", location: loc)
 }
 } else {
 // 缺省关键字，默认为枚举
 isEnum = true
 }

 // 期望 ]
 try expect(.rightBracket(loc))

 if isObject {
 let objectDecl = try parseObjectDeclContent(name: name, genericParams: genericParams, location: loc)
 return .objectDecl(objectDecl)
 } else {
 let enumDecl = try parseEnumDeclContent(name: name, genericParams: genericParams, location: loc)
 return .enumDecl(enumDecl)
 }
 }

 // MARK: - foreign 块解析（Phase 2a ADR-015 FFI， foreign-decl）

 /// 解析 foreign 块内容（`[名称|foreign]` 的 `]` 已被消费）。
 /// 块内只允许外部 C 函数签名（无函数体）；块内函数自动视为 `|unsafe`。
 private func parseForeignDecl(name: String, location: SourceLocation) throws -> ForeignDecl {
 var funcs: [FuncDecl] = []
 skipNewlines()
 if case .indent(_) = currentToken { advance(); skipNewlines() }
 while !isEOF() {
 if case .dedent(_) = currentToken { advance(); break }
 // foreign 块结束：下一个顶层声明（顶格新声明头）
 if case .indent(_) = currentToken { advance(); skipNewlines(); continue }
 // 顶层函数 `name|func(...)` 或「裸函数签名 + 缩进体」→ foreign 块结束
 if isBareFuncWithFuncModifierStart() || isBareFunctionWithBodyStart() { break }
 // 类型 / 扩展块 / import 等声明头 → foreign 块结束。
 // 注意：不能用 isTopLevelDeclStart() 整体判断——裸函数签名（foreign 签名）也会命中。
 if isForeignBlockEndMarker() { break }
 guard case .identifier(_) = currentToken, isBareFunctionDeclStart() else {
 throw ParserError.invalidStatement(
 reason: "foreign 块内只允许外部 C 函数签名（无函数体）：块名 `\(name)`",
 location: currentLocation
 )
 }
 var sig = try parseBareFuncDecl(isTopLevel: false, allowEmptyBody: true, allowUnsafeModifier: true)
 if sig.body != nil {
 throw ParserError.invalidStatement(
 reason: "foreign 块内函数不可带函数体（仅签名声明外部 C 函数）：`\(sig.name)`",
 location: sig.location
 )
 }
 // ：块内函数自动视为 `|unsafe`。
 if !sig.modifiers.contains("unsafe") {
 sig = FuncDecl(
 name: sig.name,
 modifiers: sig.modifiers + ["unsafe"],
 genericParams: sig.genericParams,
 params: sig.params,
 returnTypes: sig.returnTypes,
 returnLabels: sig.returnLabels,
 isAsync: sig.isAsync,
 body: sig.body,
 location: sig.location,
 captured: sig.captured
 )
 }
 funcs.append(sig)
 skipNewlines()
 }
 return ForeignDecl(name: name, funcs: funcs, location: location)
 }

 /// Phase 2a（ADR-015 FFI）：判断当前裸函数签名后是否紧跟缩进体（= 带 body 的**函数定义**）。
 /// 用于 foreign 块循环区分「纯外部签名」与「顶层函数定义」——二者同为 `IDENT(...) -> (...)` 形态。
 private func isBareFunctionWithBodyStart() -> Bool {
 guard case .identifier(_) = currentToken else { return false }
 var offset = 1
 // 跳过可选的 |修饰符
 if case .pipe(_) = peek(offset: offset) {
 offset += 1
 if !isNameToken(peek(offset: offset)) { return false }
 offset += 1
 }
 // 跳过可选的泛型 <T,>
 if case .lessThan(_) = peek(offset: offset) {
 offset += 1
 var depth = 1
 while depth > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .lessThan(_) = tok { depth += 1 }
 if case .greaterThan(_) = tok { depth -= 1 }
 offset += 1
 }
 }
 guard case .leftParen(_) = peek(offset: offset) else { return false }
 offset += 1
 var parenDepth = 1
 while parenDepth > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .leftParen(_) = tok { parenDepth += 1 }
 if case .rightParen(_) = tok { parenDepth -= 1 }
 offset += 1
 }
 guard parenDepth == 0 else { return false }
 // 跳过 -> (rets)
 if case .arrow(_) = peek(offset: offset) {
 offset += 1
 if case .leftParen(_) = peek(offset: offset) {
 offset += 1
 var rp = 1
 while rp > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .leftParen(_) = tok { rp += 1 }
 if case .rightParen(_) = tok { rp -= 1 }
 offset += 1
 }
 }
 }
 // 跳过换行与块引导冒号（H-4），看是否 indent（函数体）
 while offset < tokens.count {
 let tok = peek(offset: offset)
 if case .newline(_) = tok { offset += 1; continue }
 // H-4（A8 选项 B）：带执行块的函数以 `:` 开块，前瞻须容忍它，否则
 // foreign 块等依赖本判定的循环无法识别「下一个是带体函数」而退出。
 if case .colon(_) = tok { offset += 1; continue }
 if case .indent(_) = tok { return true }
 return false
 }
 return false
 }

 /// Phase 2a（ADR-015 FFI）：foreign 块的结束标记——类型/扩展块/import 等非签名声明头。
 /// 裸函数签名（foreign 签名本身）不是结束标记。
 private func isForeignBlockEndMarker() -> Bool {
 switch currentToken {
 case .leftParen(_), .leftBrace(_), .leftBracket(_), .lessThan(_):
 return isTopLevelDeclStart()
 case .keyword(.import, _), .keyword(.export, _):
 return true
 default:
 return false
 }
 }

 // MARK: - 扩展块解析（ADR-016 规则 3.2/3.14， extension-decl）

 /// 解析扩展块 `((T))`/`{{T}}`/`[[T]]`/`<<T>>`。
 /// 数据与逻辑分离：类型体只含字段/用例，方法必须写在同文件扩展块并显式 `|self`/`|Self`；
 /// 扩展块内禁止自由函数（规则 3.14）。特征扩展 `<<T>>` 允许抽象方法签名（同 trait-body）。
 private func parseExtensionDecl() throws -> ExtensionDecl {
 let loc = currentLocation
 let kind: ExtensionDecl.Kind
 switch currentToken {
 case .leftParen(_): kind = .structExt
 case .leftBrace(_): kind = .objectExt
 case .leftBracket(_): kind = .enumExt
 case .lessThan(_): kind = .traitExt
 default:
 throw ParserError.invalidDeclaration(reason: "无法识别的扩展块起始定界符", location: loc)
 }
 advance() // 第一个定界符
 advance() // 第二个定界符

 let target = try parseIdentifier()

 // 可选泛型参数（`((盒<T>))` 泛型扩展；消费并校验，合并仍按 targetType 名称匹配）
 var genericParams: [GenericParam] = []
 if case .lessThan(_) = currentToken {
 genericParams = try parseGenericParams()
 }

 // 可选的 `: type-annotation`（泛型特化扩展限定，暂只解析存储，合并按 targetType 名称匹配）
 var targetAnnotation: TypeAnnotation? = nil
 if kind != .traitExt, case .colon(_) = currentToken {
 advance()
 targetAnnotation = try parseTypeAnnotation()
 }

 // 闭合定界符：)) / }} / ]] / >>
 switch kind {
 case .structExt:
 try expect(.rightParen(loc)); try expect(.rightParen(loc))
 case .objectExt:
 try expect(.rightBrace(loc)); try expect(.rightBrace(loc))
 case .enumExt:
 try expect(.rightBracket(loc)); try expect(.rightBracket(loc))
 case .traitExt:
 try expect(.greaterThan(loc)); try expect(.greaterThan(loc))
 }

 // 方法体（method-body / trait-body）：扩展块头与方法签名同顶格（0 层），方法体缩进；
 // 结束 = DEDENT / EOF / 下一个非 `|self` 顶级声明。
 var methods: [FuncDecl] = []
 skipNewlines()
 if case .indent(_) = currentToken { advance(); skipNewlines() }
 while !isEOF() {
 if case .dedent(_) = currentToken { advance(); break }
 let isTraitExt = (kind == .traitExt)
 if case .identifier(_) = currentToken, isBareFunctionDeclStart() {
 if !isTraitExt && !isSelfMethodStart() {
 // 类型扩展：顶格非 `|self`/`|own`（如 `main|func`、字段）→ 扩展块结束
 break
 }
 let funcDecl = try parseBareFuncDecl(isTopLevel: false, allowEmptyBody: isTraitExt)
 // 规则 3.14：类型扩展内只允许 |self/|own 方法（G50：Self 更名 own）；特征扩展保持 trait-body 宽松
 if !isTraitExt {
 let hasSelfModifier = funcDecl.modifiers.contains("self") || funcDecl.modifiers.contains("own")
 if !hasSelfModifier {
 throw ParserError.invalidStatement(
 reason: "扩展块内只允许 `|self`/`|own` 方法（规则 3.14）：`\(funcDecl.name)` 缺少 self 修饰符，自由函数应移至模块顶层",
 location: funcDecl.location
 )
 }
 }
 methods.append(funcDecl)
 skipNewlines()
 } else if isTopLevelDeclStart() {
 break
 } else {
 throw ParserError.invalidStatement(
 reason: "扩展块内只允许方法声明（规则 3.14）：自由函数应移至模块顶层",
 location: currentLocation
 )
 }
 }
 return ExtensionDecl(kind: kind, targetType: target, targetTypeAnnotation: targetAnnotation, methods: methods, location: loc)
 }

 /// 当前是否为 `方法名|self(...)` / `方法名|own(...)` 的方法声明头（扩展块方法预判；G50：Self 更名 own）。
 private func isSelfMethodStart() -> Bool {
 guard case .identifier(_) = currentToken else { return false }
 guard case .pipe(_) = peek(offset: 1) else { return false }
 if case .keyword(.self, _) = peek(offset: 2) { return true }
 if case .keyword(.own, _) = peek(offset: 2) { return true }
 return false
 }

 // MARK: - 结构块解析
 
 private func parseStructDecl() throws -> StructDecl {
 let loc = currentLocation
 advance() // 跳过 (
 
 // 解析名称
 let name = try parseIdentifier()
 
 // 内嵌组合：父类型名以「结构体内首行裸标识符」形式给出（下方 A3 检测），
 // 不再使用 (新|原) 管道语法（已移除）。
 var composedType: String? = nil
 
 // 检查泛型参数
 var genericParams: [GenericParam] = []
 if case .lessThan = currentToken {
 genericParams = try parseGenericParams()
 }
 
 // 期望 )
 try expect(.rightParen(loc))
 
 // 解析内容态（ADR-016 规则 3.2：类型体内只允许字段，方法移至扩展块）
 var fields: [FieldDecl] = []
 
 skipNewlines()

 // 内嵌组合：检测结构体内首行裸父类型名（原称 A3 简写）
 // 条件：当前 token 是 identifier，但不是裸函数也不是普通字段声明
 if composedType == nil,
 case .identifier(let bareName, let bareLoc) = currentToken,
 !isBareFunctionDeclStart() {
 let nextNonNewline = peekPastNewlines(offset: 1)
 switch nextNonNewline {
 case .colon, .pipe(_), .assign(_):
 break
 default:
 advance()
 composedType = bareName
 fields.append(FieldDecl(
 name: bareName,
 typeAnnotation: .simple(name: bareName, location: bareLoc),
 initializer: nil,
 location: bareLoc
 ))
 skipNewlines()
 }
 }
 
 while !isEOF() {
 skipNewlines()
 // 允许类型体首行缩进，并与 trait 体保持一致的缩进语义：
 // 遇到缩进 token 先消费；遇到反缩进（体结束）或下一个顶层声明即收尾。
 if case .indent(_) = currentToken { advance(); skipNewlines() }
 if case .dedent(_) = currentToken { advance(); break }
 // 类型体结束：顶格下一类型块头（`(`/`[`/`<`）；`{` 在类型体内是函数声明 → 报错。
 // 注意：不能用 isTopLevelDeclStart()——它把 `name(...)` 裸函数也当顶级声明，使规则 3.2 报错失效。
 if case .leftParen(_) = currentToken { break }
 if case .leftBracket(_) = currentToken { break }
 if case .lessThan(_) = currentToken { break }
 if case .leftBrace(_) = currentToken {
 // `{{` 是对象扩展块（下一顶级声明）→ 结束类型体；单 `{` 是类型体内函数声明 → 规则 3.2 报错
 if case .leftBrace(_) = peek(offset: 1) { break }
 // ADR-016 规则 3.2：类型体内禁止函数声明（旧 `{name|self}(...)` 方法形式已废止）
 throw ParserError.invalidStatement(
 reason: "类型体内禁止函数声明（规则 3.2）：`\(name)` 的方法应移至同文件扩展块 `((\(name)))` 中，并显式使用 `|self` 或 `|Self`",
 location: currentLocation
 )
 } else if case .identifier(_) = currentToken, isBareFunctionDeclStart() {
 // `name|func` 是顶级自由函数（类型体结束）；其余函数声明是类型体内方法（规则 3.2 报错）
 if isBareFuncWithFuncModifierStart() { break }
 throw ParserError.invalidStatement(
 reason: "类型体内禁止函数声明（规则 3.2）：`\(name)` 的方法应移至同文件扩展块 `((\(name)))` 中，并显式使用 `|self` 或 `|Self`",
 location: currentLocation
 )
 } else {
 // 字段声明
 let field = try parseFieldDecl()
 fields.append(field)
 }
 skipNewlines()
 }

 let (traits, remainingFields) = extractTraits(from: fields)
 return StructDecl(name: name, genericParams: genericParams, fields: remainingFields, methods: [], composedType: composedType, traits: traits, location: loc)
 }
 
 // MARK: - 对象块解析

 // 判断左花括号开头的是函数声明还是对象声明
 // 策略：预读 `{name}` 后，看下一个非换行 token 是不是 `(` —— 是则为函数，否则为对象
 private func isBraceFuncDecl() -> Bool {
 var offset = 1 // 跳过 {
 // 跳过标识符
 guard case .identifier(_) = peek(offset: offset) else { return false }
 offset += 1
 // 跳过可选的 |修饰符（如 {name|func}、{name|self}、{name|Self}）
 // 注：func/self/Self 是关键字，需同时接受 identifier 与 keyword
 if case .pipe(_) = peek(offset: offset) {
 offset += 1
 if !isNameToken(peek(offset: offset)) { return false }
 offset += 1
 }
 // 跳过可选的泛型参数 <T,>
 if case .lessThan(_) = peek(offset: offset) {
 offset += 1
 var depth = 1
 while depth > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .lessThan(_) = tok { depth += 1 }
 if case .greaterThan(_) = tok { depth -= 1 }
 offset += 1
 }
 }
 // 期望 }
 guard case .rightBrace(_) = peek(offset: offset) else { return false }
 offset += 1
 // } 之后第一个非换行 token 是 ( → 函数
 while offset < tokens.count {
 let tok = peek(offset: offset)
 if case .newline(_) = tok {
 offset += 1
 continue
 }
 if case .leftParen(_) = tok {
 return true
 }
 return false
 }
 return false
 }

 // 名称 token：identifier 或 keyword（用于修饰符位置，因为 func/self/Self 是关键字）
 private func isNameToken(_ token: Token) -> Bool {
 switch token {
 case .identifier(_): return true
 case .keyword(_): return true
 default: return false
 }
 }

 // 解析花括号对象声明 `{name}` 或 `{name|modifier}` 的头部，然后交由 parseObjectDeclContent 解析内容态
 private func parseObjectDecl() throws -> ObjectDecl {
 let loc = currentLocation
 try expect(.leftBrace(loc)) // 跳过 {

 // 解析名称
 let name = try parseIdentifier()

 // 解析可选的修饰符（兼容旧语法 `{name|object}`，但修饰符本身不影响对象语义）
 if case .pipe(_) = currentToken {
 advance()
 _ = try parseIdentifier() // 消费修饰符，不存储
 }

 // 解析泛型参数（可选）
 var genericParams: [GenericParam] = []
 if case .lessThan = currentToken {
 genericParams = try parseGenericParams()
 }

 // 期望 }
 try expect(.rightBrace(loc))

 return try parseObjectDeclContent(name: name, genericParams: genericParams, location: loc)
 }

 private func parseObjectDeclContent(name: String, genericParams: [GenericParam], location: SourceLocation) throws -> ObjectDecl {
 // 解析内容态（ADR-016 规则 3.2：对象体内只允许字段，方法移至扩展块）
 var fields: [FieldDecl] = []

 skipNewlines()

 while !isEOF() {
 skipNewlines()
 // 允许类型体首行缩进，并与 trait 体保持一致的缩进语义：
 // 遇到缩进 token 先消费；遇到反缩进（体结束）或下一个顶层声明即收尾。
 if case .indent(_) = currentToken { advance(); skipNewlines() }
 if case .dedent(_) = currentToken { advance(); break }
 // 类型体结束：顶格下一类型块头（`(`/`[`/`<`）；`{` 在类型体内是函数声明 → 报错。
 if case .leftParen(_) = currentToken { break }
 if case .leftBracket(_) = currentToken { break }
 if case .lessThan(_) = currentToken { break }
 if case .leftBrace(_) = currentToken {
 // `{{` 是对象扩展块（下一顶级声明）→ 结束类型体；单 `{` 是类型体内函数声明 → 规则 3.2 报错
 if case .leftBrace(_) = peek(offset: 1) { break }
 // ADR-016 规则 3.2：类型体内禁止函数声明（旧 `{name|self}(...)` 方法形式已废止）
 throw ParserError.invalidStatement(
 reason: "类型体内禁止函数声明（规则 3.2）：`\(name)` 的方法应移至同文件扩展块 `{{\(name)}}` 中，并显式使用 `|self` 或 `|Self`",
 location: currentLocation
 )
 } else if case .identifier(_) = currentToken, isBareFunctionDeclStart() {
 // `name|func` 是顶级自由函数（类型体结束）；其余函数声明是类型体内方法（规则 3.2 报错）
 if isBareFuncWithFuncModifierStart() { break }
 throw ParserError.invalidStatement(
 reason: "类型体内禁止函数声明（规则 3.2）：`\(name)` 的方法应移至同文件扩展块 `{{\(name)}}` 中，并显式使用 `|self` 或 `|Self`",
 location: currentLocation
 )
 } else {
 // 字段声明
 let field = try parseFieldDecl()
 fields.append(field)
 }
 skipNewlines()
 }

 let (traits, remainingFields) = extractTraits(from: fields)
 return ObjectDecl(name: name, genericParams: genericParams, fields: remainingFields, methods: [], traits: traits, location: location)
 }
 
 // MARK: - 枚举块解析
 
 private func parseEnumDeclContent(name: String, genericParams: [GenericParam], location: SourceLocation) throws -> EnumDecl {
 // 解析内容态（ADR-016 规则 3.2：枚举体内只允许用例，方法移至扩展块）
 var cases: [EnumCase] = []
 
 skipNewlines()
 
 while !isEOF() {
 skipNewlines()
 if case .indent(_) = currentToken { advance(); skipNewlines() }
 if case .dedent(_) = currentToken { advance(); break }
 // 枚举体结束：顶格下一类型块头（`(`/`[`/`<`）；`{` 是函数声明 → 报错
 if case .leftParen(_) = currentToken { break }
 if case .leftBracket(_) = currentToken { break }
 if case .lessThan(_) = currentToken { break }
 if case .leftBrace(_) = currentToken {
 // `{{` 是对象扩展块（下一顶级声明）→ 结束类型体；单 `{` 是类型体内函数声明 → 规则 3.2 报错
 if case .leftBrace(_) = peek(offset: 1) { break }
 // ADR-016 规则 3.2：类型体内禁止函数声明（旧 `{name|self}(...)` 方法形式已废止）
 throw ParserError.invalidStatement(
 reason: "类型体内禁止函数声明（规则 3.2）：`\(name)` 的方法应移至同文件扩展块 `[[\(name)]]` 中，并显式使用 `|self` 或 `|Self`",
 location: currentLocation
 )
 } else if case .identifier(_) = currentToken, isBareFunctionDeclStart() {
 // `name|func` 是顶级自由函数（类型体结束）；其余函数声明是类型体内方法（规则 3.2 报错）
 if isBareFuncWithFuncModifierStart() { break }
 throw ParserError.invalidStatement(
 reason: "类型体内禁止函数声明（规则 3.2）：`\(name)` 的方法应移至同文件扩展块 `[[\(name)]]` 中，并显式使用 `|self` 或 `|Self`",
 location: currentLocation
 )
 } else {
 // 用例声明
 let enumCase = try parseEnumCase()
 cases.append(enumCase)
 }
 skipNewlines()
 }
 
 return EnumDecl(name: name, genericParams: genericParams, cases: cases, methods: [], location: location)
 }
 
 private func parseEnumCase() throws -> EnumCase {
 let loc = currentLocation

 let name = try parseIdentifier()

 var associatedParams: [AssociatedParam] = []
 if case .leftParen(_) = currentToken {
 advance()
 while !check(.rightParen(loc)) && !isEOF() {
 // ADR-021/具名关联值决议（2026-08-29）：具名形参 `IDENT ':' 类型` 合法
 // （推翻规则 3.15 的具名拒绝；spec A.2.2 具名四形态收口）。默认值 / 裸字面量
 // / 表达式默认值仍拒绝（与具名无关）。
 var assocName: String? = nil
 if case .identifier(let possibleName, _) = currentToken, peekIsColon() {
 assocName = possibleName
 advance()
 advance()
 }
 if case .identifier(let badName, let al) = currentToken, peekIsAssign() {
 throw ParserError.invalidStatement(
 reason: "枚举用例关联值不允许默认值（`\(badName) = ...`）；位置类型注解不支持默认值",
 location: al
 )
 }
 switch currentToken {
 case .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
 throw ParserError.invalidStatement(
 reason: "枚举用例关联值不允许裸字面量；仅接受类型注解（如 `F64`、`I32`）",
 location: currentLocation
 )
 default:
 break
 }
 // `IDENT '('` 在类型位置永不合法（泛型写 `T<U>`、数组写 `[T]`），只可能是调用表达式默认值（如 `iota()`）。
 if case .identifier(_, let cl) = currentToken, case .leftParen(_) = peek(offset: 1) {
 throw ParserError.invalidStatement(
 reason: "枚举用例关联值不允许表达式默认值（如 `iota()`）；仅接受类型注解（如 `F64`、`I32`）",
 location: cl
 )
 }
 let type = try parseTypeAnnotation()
 associatedParams.append(AssociatedParam(name: assocName, type: type, defaultValue: nil))
 assocName = nil
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 }

 return EnumCase(name: name, associatedParams: associatedParams, location: loc)
 }

 /// 下一个 token 是否为 `:`（具名参数分隔符）。
 private func peekIsColon() -> Bool {
 if case .colon(_) = peek(offset: 1) { return true }
 return false
 }

 /// 下一个 token 是否为 `=`（关联值默认分隔符）。
 private func peekIsAssign() -> Bool {
 if case .assign(_) = peek(offset: 1) { return true }
 return false
 }


 
 // MARK: - 字段解析
 
 private func extractTraits(from fields: [FieldDecl]) -> (traits: [String], remaining: [FieldDecl]) {
 var traits: [String] = []
 var remaining: [FieldDecl] = []
 for field in fields {
 if field.name == "实现" {
 if case .simple(let tn, _) = field.typeAnnotation {
 traits.append(tn)
 }
 } else {
 remaining.append(field)
 }
 }
 return (traits, remaining)
 }

 private func parseFieldDecl() throws -> FieldDecl {
 let loc = currentLocation
 
 // 字段名
 let name = try parseIdentifier()
 
 // 期望 :
 try expect(.colon(loc))
 
 // 类型
 let type = try parseTypeAnnotation()
 
 // = initializer 可选
 let initializer: Expression?
 if case .assign(_) = currentToken {
 advance()
 initializer = try parseExpression()
 } else {
 initializer = nil
 }
 
 return FieldDecl(name: name, typeAnnotation: type, initializer: initializer, location: loc)
 }
 
 // MARK: - 函数块解析
 
 private func parseFuncDecl(isTopLevel: Bool) throws -> FuncDecl {
 let loc = currentLocation
 advance() // 跳过 {
 
 // 解析名称
 let name = try parseIdentifier()
 
 // 解析修饰符
 var modifiers: [String] = []
 if case .pipe(_) = currentToken {
 advance()
 let modifier = try parseIdentifier()
 modifiers.append(modifier)
 }
 
 // 期望 }
 try expect(.rightBrace(loc))
 
 // 解析泛型参数（可选）
 var genericParams: [GenericParam] = []
 if case .lessThan = currentToken {
 genericParams = try parseGenericParams()
 }
 
 // 参数元组 + 返回类型标注（具名函数与匿名函数共用）
 let (params, returnTypes, returnLabels, isAsync) = try parseFunctionSignature(loc: loc)

 // 解析函数体（Block）
 var body: Block? = nil
 // H-4（A8 选项 B，阶段 2 已强制）：带执行块的函数一律以 `:` 开块，与
 // `if` / `while` 一致。记录冒号是否出现；下方见 indent（执行体）时若无
 // 冒号即报错。无执行体的签名（trait 抽象方法）不受约束。
 var sawColon = false
 if case .colon(_) = currentToken {
 advance()
 sawColon = true
 }
 skipNewlines()
 if case .indent(_) = currentToken {
 guard sawColon else {
  throw ParserError.invalidDeclaration(
   reason: "带执行块的函数一律以 `:` 开块（H-4/A8 选项 B）：`\(name)` 的签名行需以冒号结尾",
   location: currentLocation
  )
 }
 body = try parseBlock()
 } else {
 // 任务 #13（草稿意图已采纳）：函数体必须按层次缩进且至少缩进一层，
 // 不再允许顶级内容态顶格累积语句（ func-body 已移除 `{ statement }` 分支）。
 throw ParserError.invalidStatement(
 reason: "函数体必须缩进至少一层（草稿意图已采纳）：`\(name)` 的语句请缩进书写，如 ` return ...`",
 location: currentLocation
 )
 }

 return FuncDecl(
 name: name,
 modifiers: modifiers,
 genericParams: genericParams,
 params: params,
 returnTypes: returnTypes,
 returnLabels: returnLabels,
 isAsync: isAsync,
 body: body,
 location: loc
 )
 }

 /// 解析「参数元组 + 返回类型标注」（`-> (返回,)` / `=> (返回,)`）。
 /// 具名函数（parseFuncDecl）与匿名函数（parseFuncLiteral）共用。
 private func parseFunctionSignature(loc: SourceLocation) throws -> (params: [Parameter], returnTypes: [TypeAnnotation], returnLabels: [String?], isAsync: Bool) {
 // 参数元组
 try expect(.leftParen(loc))
 var params: [Parameter] = []
 while !check(.rightParen(loc)) {
 let param = try parseParameter()
 params.append(param)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))

 // 返回类型
 var returnTypes: [TypeAnnotation] = []
 var returnLabels: [String?] = []
 var isAsync = false
 if case .arrow(_) = currentToken {
 advance()
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) && !isEOF() {
 // 可能是 "名称: 类型" 或直接 "类型"（草稿 A2，批次 1.3：命名返回的分量标签记录进 returnLabels）
 if case .identifier(let name, _) = currentToken {
 let nextTok = peek(offset: 1)
 if case .colon(_) = nextTok {
 advance() // 跳过名称
 advance() // 跳过 :
 returnLabels.append(name)
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 } else {
 returnLabels.append(nil)
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 }
 } else {
 returnLabels.append(nil)
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 }
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 } else if case .doubleArrow(_) = currentToken {
 advance()
 isAsync = true
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) {
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 returnLabels.append(nil)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 }
 return (params, returnTypes, returnLabels, isAsync)
 }

 /// H-1 capture 上下文：nil = 不在匿名函数体解析中；非 nil = 当前块嵌套深度
 ///（0 = 正在解析字面量头与体之间，1 = 缩进体顶层语句位，≥2 = 嵌套块内）。
 /// parseCaptureStmt 依据此判定「仅匿名函数体顶层语句位」。
 private var anonCaptureDepth: Int? = nil

 /// 解析匿名函数字面量（spec G29）：`func (形式参数元组,) -> (返回元组,):` + 块体。
 /// `=> (返回元组,)` 为 async 形式。产出 `Expression.funcLiteral`（FuncDecl 同构表示）。
 private func parseFuncLiteral() throws -> Expression {
 let loc = currentLocation
 advance() // 跳过 func

 let (params, returnTypes, returnLabels, isAsync) = try parseFunctionSignature(loc: loc)

 // 匿名函数是「引导子块关键字」，带 `:` 尾缀
 try expect(.colon(loc))
 skipNewlines()
 // H-1：capture 声明的合法性上下文——仅本匿名函数缩进体的顶层语句位。
 // 深度基准清零后，parseBlock 逐层 +1，parseCaptureStmt 要求深度恰为 1。
 let savedCaptureDepth = anonCaptureDepth
 anonCaptureDepth = 0
 defer { anonCaptureDepth = savedCaptureDepth }
 let body: Block
 if case .indent(_) = currentToken {
 body = try parseBlock()
 } else {
 // 单行体：`return 某值` 或单表达式
 let stmt = try parseStatement()
 body = Block(statements: [stmt], location: loc)
 }

 // H-1：capture 声明聚入 FuncDecl.captured（每行恰一个，体顶层语句序即声明序）
 let captured = body.statements.compactMap { stmt -> String? in
 if case .captureStatement(let n, _) = stmt { return n }
 return nil
 }
 let decl = FuncDecl(
 name: "<anon>",
 modifiers: [],
 genericParams: [],
 params: params,
 returnTypes: returnTypes,
 returnLabels: returnLabels,
 isAsync: isAsync,
 body: body,
 location: loc,
 captured: captured
 )
 return .funcLiteral(decl: decl, location: loc)
 }

 private func parseFuncDeclInTypeContext() throws -> FuncDecl {
 // 在类型上下文中解析方法声明
 let loc = currentLocation
 advance() // 跳过 {
 
 // 解析名称
 let name = try parseIdentifier()
 
 // 解析修饰符
 var modifiers: [String] = []
 if case .pipe(_) = currentToken {
 advance()
 let modifier = try parseIdentifier()
 modifiers.append(modifier)
 }
 
 // 期望 }
 try expect(.rightBrace(loc))
 
 // 解析泛型参数（可选）
 var genericParams: [GenericParam] = []
 if case .lessThan = currentToken {
 genericParams = try parseGenericParams()
 }
 
 // 参数元组
 try expect(.leftParen(loc))
 var params: [Parameter] = []
 while !check(.rightParen(loc)) {
 let param = try parseParameter()
 params.append(param)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 
 // 返回类型
 var returnTypes: [TypeAnnotation] = []
 var isAsync = false
 if case .arrow(_) = currentToken {
 advance()
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) && !isEOF() {
 // 可能是 "名称: 类型" 或直接 "类型"
 if case .identifier(_) = currentToken {
 let nextTok = peek(offset: 1)
 if case .colon(_) = nextTok {
 advance() // 跳过名称
 advance() // 跳过 :
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 } else {
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 }
 } else {
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 }
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 } else if case .doubleArrow(_) = currentToken {
 advance()
 isAsync = true
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) {
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 }

 // 解析方法体（Block）
 var body: Block? = nil
 // H-4（A8 选项 B，阶段 2 已强制）：带执行块的函数一律以 `:` 开块，与
 // `if` / `while` 一致。记录冒号是否出现；下方见 indent（执行体）时若无
 // 冒号即报错。无执行体的签名（trait 抽象方法）不受约束。
 var sawColon = false
 if case .colon(_) = currentToken {
 advance()
 sawColon = true
 }
 skipNewlines()
 if case .indent(_) = currentToken {
 guard sawColon else {
  throw ParserError.invalidDeclaration(
   reason: "带执行块的函数一律以 `:` 开块（H-4/A8 选项 B）：`\(name)` 的签名行需以冒号结尾",
   location: currentLocation
  )
 }
 body = try parseBlock()
 }

 return FuncDecl(
 name: name,
 modifiers: modifiers,
 genericParams: genericParams,
 params: params,
 returnTypes: returnTypes,
 isAsync: isAsync,
 body: body,
 location: loc
 )
 }

 // MARK: - 裸函数声明解析（新语法）

 // 判断标识符开头的是不是裸函数声明
 // 策略：预读 `name[(params)] ->` 或 `name[(params)] =>`，即参数元组后跟返回箭头
 // 用于区分字段声明（`name: Type = value`）与裸函数声明（`name|self(...) -> (...)`）
 private func isBareFunctionDeclStart() -> Bool {
 guard case .identifier(_) = currentToken else { return false }

 var offset = 1 // 跳过标识符
 // 跳过可选的 |修饰符（func/self/Self 是关键字，需用 isNameToken）
 if case .pipe(_) = peek(offset: offset) {
 offset += 1
 if !isNameToken(peek(offset: offset)) { return false }
 offset += 1
 }
 // 跳过可选的泛型 <T,>
 if case .lessThan(_) = peek(offset: offset) {
 offset += 1
 var depth = 1
 while depth > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .lessThan(_) = tok { depth += 1 }
 if case .greaterThan(_) = tok { depth -= 1 }
 offset += 1
 }
 }
 // 下一个必须是 (
 guard case .leftParen(_) = peek(offset: offset) else { return false }
 offset += 1
 // 找到匹配的 )
 var parenDepth = 1
 while parenDepth > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .leftParen(_) = tok { parenDepth += 1 }
 if case .rightParen(_) = tok { parenDepth -= 1 }
 offset += 1
 }
 guard parenDepth == 0 else { return false }
 // ) 之后第一个非换行 token 是 -> 或 => → 是裸函数
 while offset < tokens.count {
 let tok = peek(offset: offset)
 if case .newline(_) = tok {
 offset += 1
 continue
 }
 if case .arrow(_) = tok { return true }
 if case .doubleArrow(_) = tok { return true }
 return false
 }
 return false
 }

 /// 判断是否是 `name|func(...)` 形式的裸函数（顶级自由函数，类型体内遇到即结束类型体）。
 /// ADR-016 规则 3.2 后类型体循环用它区分「顶级函数（break）」与「类型体内方法/函数（报错）」。
 private func isBareFuncWithFuncModifierStart() -> Bool {
 guard case .identifier(_) = currentToken else { return false }
 guard case .pipe(_) = peek(offset: 1) else { return false }
 guard case .keyword(.func, _) = peek(offset: 2) else { return false }
 var offset = 3
 // 跳过可选的泛型 <T,>
 if case .lessThan(_) = peek(offset: offset) {
 offset += 1
 var depth = 1
 while depth > 0 && offset < tokens.count {
 let tok = peek(offset: offset)
 if case .lessThan(_) = tok { depth += 1 }
 if case .greaterThan(_) = tok { depth -= 1 }
 offset += 1
 }
 }
 // 必须后跟 ( 才是函数声明
 if case .leftParen(_) = peek(offset: offset) { return true }
 return false
 }

 // 解析裸函数声明：`name[|修饰符][<泛型>](参数,) -> (返回,)`
 // 用于：对象/枚举/结构内的方法声明（新语法），以及顶级裸函数声明
 private func parseBareFuncDecl(isTopLevel: Bool, allowEmptyBody: Bool = false, allowUnsafeModifier: Bool = false) throws -> FuncDecl {
 let loc = currentLocation

 // 解析名称
 let name = try parseIdentifier()

 // 解析修饰符
 var modifiers: [String] = []
 if case .pipe(_) = currentToken {
 advance()
 let modifier = try parseIdentifier()
 // Phase 2a（ADR-015 FFI）：`|unsafe` 仅限自由函数（顶层函数或
 // `[名称|foreign]` 块签名）；禁止用于类型扩展方法 / trait 签名。
 if modifier == "unsafe" && !allowUnsafeModifier {
 throw ParserError.invalidStatement(
 reason: "`|unsafe` 仅限自由函数（顶层函数或 `[名称|foreign]` 块签名）：`\(name)` 不在此列",
 location: loc
 )
 }
 modifiers.append(modifier)
 }

 // 解析泛型参数（可选）
 var genericParams: [GenericParam] = []
 if case .lessThan = currentToken {
 genericParams = try parseGenericParams()
 }

 // 参数元组
 try expect(.leftParen(loc))
 var params: [Parameter] = []
 while !check(.rightParen(loc)) {
 let param = try parseParameter()
 params.append(param)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))

 // 返回类型
 var returnTypes: [TypeAnnotation] = []
 var returnLabels: [String?] = []
 var isAsync = false
 if case .arrow(_) = currentToken {
 advance()
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) && !isEOF() {
 if case .identifier(let name, _) = currentToken {
 let nextTok = peek(offset: 1)
 if case .colon(_) = nextTok {
 advance() // 跳过名称
 advance() // 跳过 :
 returnLabels.append(name)
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 } else {
 returnLabels.append(nil)
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 }
 } else {
 returnLabels.append(nil)
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 }
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 } else if case .doubleArrow(_) = currentToken {
 advance()
 isAsync = true
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) {
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 returnLabels.append(nil)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 }

 // 解析函数体（Block）
 var body: Block? = nil
 // H-4（A8 选项 B，阶段 2 已强制）：带执行块的函数一律以 `:` 开块，与
 // `if` / `while` 一致。记录冒号是否出现；下方见 indent（执行体）时若无
 // 冒号即报错。无执行体的签名（trait 抽象方法）不受约束。
 var sawColon = false
 if case .colon(_) = currentToken {
 advance()
 sawColon = true
 }
 skipNewlines()
 if case .indent(_) = currentToken {
 guard sawColon else {
  throw ParserError.invalidDeclaration(
   reason: "带执行块的函数一律以 `:` 开块（H-4/A8 选项 B）：`\(name)` 的签名行需以冒号结尾",
   location: currentLocation
  )
 }
 body = try parseBlock()
 } else if !allowEmptyBody {
 // 任务 #13（草稿意图已采纳）：函数体必须按层次缩进且至少缩进一层，
 // 不再允许顶级内容态顶格累积语句（ func-body 已移除 `{ statement }` 分支）。
 // trait 抽象方法（allowEmptyBody）除外——签名可无 body。
 throw ParserError.invalidStatement(
 reason: "函数体必须缩进至少一层（草稿意图已采纳）：`\(name)` 的语句请缩进书写，如 ` return ...`",
 location: currentLocation
 )
 }

 return FuncDecl(
 name: name,
 modifiers: modifiers,
 genericParams: genericParams,
 params: params,
 returnTypes: returnTypes,
 returnLabels: returnLabels,
 isAsync: isAsync,
 body: body,
 location: loc
 )
 }

 // MARK: - 特征体解析
 
 private func parseTraitDecl() throws -> TraitDecl {
 let loc = currentLocation
 advance() // 跳过 <

 // 解析名称
 let name = try parseIdentifier()

 // 期望 >
 try expect(.greaterThan(loc))

 // 泛型参数（可选，暂不处理）
 let genericParams: [GenericParam] = []

 // 解析内容态：函数签名（可带 body 作为默认实现）和变量签名
 var signatures: [FuncDecl] = []

 skipNewlines()

 while !isEOF() {
 skipNewlines()
 var justDedented = false
 indentLoop: while true {
 switch currentToken {
 case .indent:
 advance()
 skipNewlines()
 case .dedent:
 justDedented = true
 advance()
 skipNewlines()
 default:
 break indentLoop
 }
 }

 if isEOF() { break }

 if justDedented {
 if isTopLevelDeclStart() { break }
 if case .identifier(_) = currentToken, isBareFunctionDeclStart() { break }
 }

 if case .leftBrace(_) = currentToken {
 let sig = try parseFuncDeclInTypeContext()
 signatures.append(sig)
 } else if case .identifier(_) = currentToken, isBareFunctionDeclStart() {
 let sig = try parseBareFuncDecl(isTopLevel: false, allowEmptyBody: true)
 signatures.append(sig)
 } else {
 let sig = try parseTraitVarSignature()
 let funcSig = FuncDecl(
 name: sig.name,
 modifiers: [],
 genericParams: [],
 params: [],
 returnTypes: [sig.typeAnnotation],
 body: nil,
 location: sig.location
 )
 signatures.append(funcSig)
 }
 }

 return TraitDecl(name: name, genericParams: genericParams, signatures: signatures, location: loc)
 }
 
 private func parseTraitFuncSignature() throws -> FuncDecl {
 let loc = currentLocation
 advance() // 跳过 {
 
 // 解析名称
 let name = try parseIdentifier()
 
 // 期望 }
 try expect(.rightBrace(loc))
 
 // 参数元组
 try expect(.leftParen(loc))
 var params: [Parameter] = []
 while !check(.rightParen(loc)) {
 let param = try parseParameter()
 params.append(param)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 
 // 返回类型
 var returnTypes: [TypeAnnotation] = []
 if case .arrow(_) = currentToken {
 advance()
 try expect(.leftParen(loc))
 while !check(.rightParen(loc)) && !isEOF() {
 // 可能是 "名称: 类型" 或直接 "类型"
 if case .identifier(_) = currentToken {
 let nextTok = peek(offset: 1)
 if case .colon(_) = nextTok {
 advance() // 跳过名称
 advance() // 跳过 :
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 } else {
 let type = try parseTypeAnnotation()
 returnTypes.append(type)
 }
 } else {
 let returnType = try parseTypeAnnotation()
 returnTypes.append(returnType)
 }
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 }
 
 return FuncDecl(
 name: name,
 modifiers: [],
 genericParams: [],
 params: params,
 returnTypes: returnTypes,
 body: nil,
 location: loc
 )
 }
 
 private struct TraitVarSignature {
 let name: String
 let typeAnnotation: TypeAnnotation
 let location: SourceLocation
 }
 
 private func parseTraitVarSignature() throws -> TraitVarSignature {
 let loc = currentLocation
 
 // 变量名
 let name = try parseIdentifier()
 
 // 期望 :
 try expect(.colon(loc))
 
 // 类型
 let type = try parseTypeAnnotation()
 
 return TraitVarSignature(name: name, typeAnnotation: type, location: loc)
 }
 
 // MARK: - Block解析
 
 /// H-1：capture 声明（A1 裁决：体内部、每行恰一个外部标识符、散落多条）。
 /// 位置合法性在此由 `anonCaptureDepth` 强制：仅匿名函数缩进体的顶层语句位。
 private func parseCaptureStmt() throws -> Statement {
 // H-1 位置合法性：仅匿名函数缩进体的顶层语句位（深度恰为 1）
 guard let depth = anonCaptureDepth, depth == 1 else {
 throw ParserError.invalidStatement(
 reason: "capture 仅允许出现在匿名函数体的缩进体顶层语句位（H-1）",
 location: currentLocation
 )
 }
 let loc = currentLocation
 advance() // 跳过 capture
 guard case .identifier(let name, let nameLoc) = currentToken else {
 throw ParserError.invalidStatement(
 reason: "capture 后须恰有一个标识符：`capture 名字`",
 location: currentLocation
 )
 }
 advance()
 // 每行恰一个捕获：逗号清单与多余标识符均不合法
 if isEOF() { return .captureStatement(name: name, location: nameLoc) }
 switch currentToken {
 case .newline, .dedent:
 break
 default:
 throw ParserError.invalidStatement(
 reason: "capture 每行仅允许一个标识符（多条捕获请分行书写）",
 location: currentLocation
 )
 }
 return .captureStatement(name: name, location: nameLoc)
 }

 private func parseBlock() throws -> Block {
 let loc = currentLocation
 // H-1：进入任何嵌套块都离开「体顶层」——深度 +1，退出恢复
 let savedCaptureDepth = anonCaptureDepth
 if savedCaptureDepth != nil { anonCaptureDepth = savedCaptureDepth! + 1 }
 defer { anonCaptureDepth = savedCaptureDepth }
 
 // INDENT
 try expect(.indent(loc))
 
 var statements: [Statement] = []
 
 while !check(.dedent(loc)) && !isEOF() {
 skipNewlines()
 if check(.dedent(loc)) {
 break
 }
 try parseStatementWithRecovery(into: &statements)
 skipNewlines()
 }
 
 // DEDENT（收集模式下若已到 EOF 则容错收尾，避免假性 DEDENT 错误）
 if !collectMode {
 try expect(.dedent(loc))
 } else if check(.dedent(loc)) {
 advance()
 }
 
 return Block(statements: statements, location: loc)
 }
 
 private func parseControlBlock() throws -> Block {
 let loc = currentLocation
 
 // 期望 :
 try expect(.colon(loc))
 
 skipNewlines()
 
 // 检查是否是单行表达式
 if !check(.indent(loc)) {
 // 单行表达式
 let expr = try parseExpression()
 let stmt = Statement.expressionStmt(expr: expr, location: loc)
 return Block(statements: [stmt], location: loc)
 }
 
 // INDENT 开始
 try expect(.indent(loc))
 // H-1：控制块同样离开「匿名函数体顶层」——深度 +1，退出恢复
 let savedCaptureDepth = anonCaptureDepth
 if savedCaptureDepth != nil { anonCaptureDepth = savedCaptureDepth! + 1 }
 defer { anonCaptureDepth = savedCaptureDepth }
 
 var statements: [Statement] = []
 
 while !check(.dedent(loc)) && !isEOF() {
 skipNewlines()
 if check(.dedent(loc)) {
 break
 }
 try parseStatementWithRecovery(into: &statements)
 skipNewlines()
 }
 
 // DEDENT（收集模式下若已到 EOF 则容错收尾，避免假性 DEDENT 错误）
 if !collectMode {
 try expect(.dedent(loc))
 } else if check(.dedent(loc)) {
 advance()
 }
 
 return Block(statements: statements, location: loc)
 }
 
 // MARK: - Statement解析
 
 private func parseStatement() throws -> Statement {
 let loc = currentLocation

 // H-1：capture 声明（合法性上下文见 parseCaptureStmt）
 if case .keyword(.capture, _) = currentToken {
 return try parseCaptureStmt()
 }

 // ADR-014（规则 3.13）：`标签|控制流关键字` 前缀 → 带标签语句。
 // 仅当 `IDENT '|'` 后为控制流关键字（if/while/for）时才识别为标签；
 // 否则（方法调用 `obj|m` / 按位或 `a|b`）回退为表达式，交由 default 分支处理。
 if case .identifier(let labelName, _) = currentToken,
 case .pipe(_) = peek(),
 case .keyword(let cfKeyword, _) = peek(offset: 2) {
 switch cfKeyword {
 case .if:
 advance() // 跳过标签标识符
 advance() // 跳过 |
 return try parseIf(label: labelName)
 case .while:
 advance()
 advance()
 return try parseWhile(label: labelName)
 case .for:
 advance()
 advance()
 return try parseFor(label: labelName)
 default:
 break
 }
 }

 switch currentToken {
 case .keyword(.var, _):
 return try parseVarDecl(isMutable: true)
 case .keyword(.let, _):
 return try parseVarDecl(isMutable: false)
 case .keyword(.return, _):
 return try parseReturn()
 case .keyword(.break, _):
 return try parseBreak()
 case .keyword(.continue, _):
 return try parseContinue()
 case .keyword(.if, _):
 return try parseIf()
 case .keyword(.while, _):
 return try parseWhile()
 case .keyword(.for, _):
 return try parseFor()
 case .keyword(.scope, let l):
 // ADR-014（G44）：`scope 块标签:` 语法已废弃 → 标签改用 `标签|控制流关键字`（规则 3.13）。
 throw ParserError.invalidStatement(reason: "scope 关键字已废弃：带标签控制流改用 `标签|while`/`标签|for`/`标签|if`（见规则 3.13）", location: l)
 case .keyword(.match, _):
 return try parseMatch()
 case .keyword(.try, _):
 return try parseTry()
 case .keyword(.defer, _):
 return try parseDefer()
 case .keyword(.detach, let detachLoc):
 // 任务 #13（ detach-expr-stmt）：`detach <expr>` 语句形式（fire-and-forget）。
 advance() // 跳过 detach
 let expr = try parseExpression()
 return Statement.detachStatement(expression: expr, location: detachLoc)
 case .keyword(.func, _):
 let funcLoc = currentLocation
 return Statement.expressionStmt(expr: try parseFuncLiteral(), location: funcLoc)
 case .keyword(.pass, let l):
 advance()
 return .passStatement(location: l)
 case .keyword(.elif, let l):
 // 草稿 A4（批次 2）：elif/else 是 if 专属延续关键字——走到此处必为「孤儿」：
 // 无同级 if 可匹配（跨级被 dedent 拦截、其他块关键字不消费它们）。明确报错，
 // 而非落入表达式解析给出笼统的「无效的表达式」。
 throw ParserError.invalidStatement(reason: "elif 前必须有同级 if（elif 只与同级 if/elif 匹配）", location: l)
 case .keyword(.else, let l):
 throw ParserError.invalidStatement(reason: "else 前必须有同级 if（else 只与同级 if 匹配）", location: l)
 default:
 return try parseAssignOrExpr()
 }
 }
 
 private func parseVarDecl(isMutable: Bool) throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 var 或 let

 // 草稿 A1（批次 1）：左值模式元组解构 `var (t, e) = rhs`——括号开头走解构路径，
 // 模式元组与 for-in 同构（parsePatternTuple 共享），`_` 占位忽略。
 if case .leftParen(_) = currentToken {
 let names = try parsePatternTuple()
 var typeAnnotation: TypeAnnotation? = nil
 if case .colon(_) = currentToken {
 advance()
 typeAnnotation = try parseTypeAnnotation()
 }
 guard case .assign(_) = currentToken else {
 throw ParserError.invalidStatement(reason: "解构声明必须有初始值 `var (a, b) = ...`", location: loc)
 }
 advance()
 let initializer = try parseExpression()
 return Statement.varDestructure(
 names: names,
 typeAnnotation: typeAnnotation,
 initializer: initializer,
 isMutable: isMutable,
 location: loc
 )
 }

 // 变量名
 let name = try parseIdentifier()
 
 // 类型标注（可选）
 var typeAnnotation: TypeAnnotation? = nil
 if case .colon(_) = currentToken {
 advance()
 typeAnnotation = try parseTypeAnnotation()
 }
 
 // 初始值（可选）
 var initializer: Expression? = nil
 if case .assign(_) = currentToken {
 advance()
 initializer = try parseExpression()
 }
 
 return Statement.varDecl(
 name: name,
 typeAnnotation: typeAnnotation,
 initializer: initializer,
 isMutable: isMutable,
 location: loc
 )
 }
 
 private func parseAssignOrExpr() throws -> Statement {
 let loc = currentLocation

 // 解析表达式
 let expr = try parseExpression()

 // 检查是否是赋值
 if isAssignmentOperator() {
 let op = advance()
 let value = try parseExpression()

 // 构造赋值目标
 let target: AssignTarget
 switch expr {
 case .identifier(let name, _):
 target = .identifier(name: name)
 case .member(let object, let name, _):
 target = .member(object: object, name: name)
 case .subscript(let container, let index, _):
 target = .subscript(expr: container, index: index)
 default:
 throw ParserError.invalidStatement(reason: "无效的赋值目标", location: loc)
 }

 // 复合赋值运算符：x op= y 等价于 x = x op y
 if let binOp = compoundAssignmentBinaryOp(op) {
 let combinedValue = Expression.binary(left: expr, op: binOp, right: value, location: loc)
 return Statement.assign(target: target, value: combinedValue, location: loc)
 }

 return Statement.assign(target: target, value: value, location: loc)
 }

 return Statement.expressionStmt(expr: expr, location: loc)
 }

 private func isAssignmentOperator() -> Bool {
 switch currentToken {
 case .assign(_), .plusAssign(_), .minusAssign(_), .multiplyAssign(_),
 .divideAssign(_), .moduloAssign(_), .andAssign(_), .orAssign(_),
 .xorAssign(_), .leftShiftAssign(_), .rightShiftAssign(_):
 return true
 default:
 return false
 }
 }

 // 将复合赋值 token 映射为对应的二元运算符；普通赋值返回 nil
 private func compoundAssignmentBinaryOp(_ token: Token) -> BinaryOperator? {
 switch token {
 case .plusAssign(_): return .plus
 case .minusAssign(_): return .minus
 case .multiplyAssign(_): return .multiply
 case .divideAssign(_): return .divide
 case .moduloAssign(_): return .modulo
 case .andAssign(_): return .bitwiseAnd
 case .orAssign(_): return .bitwiseOr
 case .xorAssign(_): return .bitwiseXor
 case .leftShiftAssign(_): return .leftShift
 case .rightShiftAssign(_): return .rightShift
 default: return nil
 }
 }
 
 private func parseReturn() throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 return
 
 // 可选的返回值
 var value: Expression? = nil
 if !isNewline() && !isEOF() && !check(.dedent(loc)) {
 value = try parseExpression()
 }
 
 return Statement.returnStatement(value: value, location: loc)
 }
 
 private func parseBreak() throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 break
 
 // 可选的标签
 var label: String? = nil
 if case .identifier(let name, _) = currentToken {
 label = name
 advance()
 }
 
 return Statement.breakStatement(label: label, location: loc)
 }
 
 private func parseContinue() throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 continue
 
 // 可选的标签
 var label: String? = nil
 if case .identifier(let name, _) = currentToken {
 label = name
 advance()
 }
 
 return Statement.continueStatement(label: label, location: loc)
 }
 
 private func parseIf(label: String? = nil) throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 if
 
 // 条件表达式
 let condition = try parseExpression()
 
 // then块
 let thenBlock = try parseControlBlock()
 
 // elif块（可选）
 var elifs: [ElifBranch] = []
 skipNewlines()
 while checkKeyword(.elif) {
 advance()
 let elifCondition = try parseExpression()
 let elifBlock = try parseControlBlock()
 elifs.append(ElifBranch(condition: elifCondition, block: elifBlock, location: currentLocation))
 skipNewlines()
 }
 
 // else块（可选）
 var elseBlock: Block? = nil
 if checkKeyword(.else) {
 advance()
 elseBlock = try parseControlBlock()
 }
 
 return Statement.ifStatement(
 condition: condition,
 thenBlock: thenBlock,
 elifs: elifs,
 elseBlock: elseBlock,
 label: label,
 location: loc
 )
 }
 
 private func parseWhile(label: String? = nil) throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 while

 // 注（ADR-014，规则 3.13）：标签重新绑回 while 本体（`标签|while 条件:`），
 // 由 parseStatement 的 `标签|控制流关键字` 前缀解析；`scope 块标签:` 已废弃（G44）。

 // 条件表达式
 let condition = try parseExpression()

 // 循环体
 let body = try parseControlBlock()

 // 可选 step 步进块：step 向前就近匹配 while，
 // 在每个循环体正常结束（含 continue）后执行，break 跳过（P1-3 落实语义）。
 var step: Block? = nil
 skipNewlines()
 if checkKeyword(.step) {
 advance() // 跳过 step 关键字
 step = try parseControlBlock()
 }

 return Statement.whileStatement(
 condition: condition,
 body: body,
 step: step,
 label: label,
 location: loc
 )
 }

 /// 解析左值模式元组 `( 标识符|_ {, 标识符|_} )`——for-in（G36）与元组解构（草稿 A1，批次 1）共用。
 /// `_` 占位保留在数组中原样返回，由上层语义按「忽略」处理。
 private func parsePatternTuple() throws -> [String] {
 guard case .leftParen(_) = currentToken else {
 throw ParserError.invalidExpression(reason: "应为 ( 模式元组 )", location: currentLocation)
 }
 advance()
 var pattern: [String] = []
 while true {
 if case .identifier(let name, _) = currentToken {
 pattern.append(name)
 advance()
 } else {
 throw ParserError.invalidExpression(reason: "模式元组应含标识符或 _", location: currentLocation)
 }
 if case .comma(_) = currentToken {
 advance()
 if case .rightParen(_) = currentToken { break } // 尾随逗号（(v,) 惯例）
 continue
 }
 break
 }
 guard case .rightParen(_) = currentToken else {
 throw ParserError.invalidExpression(reason: "模式元组后应为 )", location: currentLocation)
 }
 advance()
 return pattern
 }

 /// `for [@label] (模式元组,) in 集合值: body [step: block]`（G36）
 /// 模式元组 = 标识符/`_` 列表，与集合元素**一一对应**绑定（数组/集合=1 字段、字典=2 字段 (k,v)）；`_` 占位忽略。
 private func parseFor(label: String? = nil) throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 for

 // 注（ADR-014，规则 3.13）：标签重新绑回 for 本体（`标签|for ... in ...:`），
 // 由 parseStatement 的 `标签|控制流关键字` 前缀解析；`scope 块标签:` 已废弃（G44）。

 // 模式元组：( 标识符|_ {, 标识符|_} )
 let pattern = try parsePatternTuple()

 // in 关键字
 guard checkKeyword(.in) else {
 throw ParserError.invalidExpression(reason: "模式元组后应为 in", location: currentLocation)
 }
 advance()

 // 集合值表达式
 let iterable = try parseExpression()

 // 循环体
 let body = try parseControlBlock()

 // 可选 step 步进块（与 while 一致）
 var step: Block? = nil
 skipNewlines()
 if checkKeyword(.step) {
 advance()
 step = try parseControlBlock()
 }

 return Statement.forStatement(pattern: pattern, iterable: iterable, body: body, step: step, label: label, location: loc)
 }
 
 // ADR-014（G44）：`scope` 关键字已废弃（改为 `标签|控制流关键字`，规则 3.13）。
 // parseScope 已移除；scopedBlock AST 节点与 Interpreter.executeScope 暂保留为遗留兼容，后续清理。

 private func parseMatch() throws -> Statement {
 let loc = currentLocation
 advance()
 
 let value = try parseExpression()
 
 try expect(.colon(loc))
 skipNewlines()
 
 // D3①（2026-08-23，G28 更新）：match 子块结构——`match 值:` 后必须缩进子块，
 // `case` 在子块内（与 match 差一级）；通配=`case _:`；default:/pass 通配子块一次性移除（R2=删除）。
 guard case .indent(_) = currentToken else {
 throw ParserError.invalidStatement(
 reason: "match 后必须缩进子块：`case` 分支须与 `match` 差一级缩进（case 与 match 同级写法已随 G28 更新废弃）",
 location: loc
 )
 }
 advance() // 消费 indent
 
 var cases: [MatchCase] = []
 while !check(.dedent(loc)) && !isEOF() {
 skipNewlines()
 if check(.dedent(loc)) { break }
 
 guard checkKeyword(.case) else {
 // R2：default:/pass 通配子块已删除——给出专属提示帮助迁移。
 if case .identifier("default", let dl) = currentToken {
 throw ParserError.invalidStatement(
 reason: "`default:` 已废弃，请改用 `case _:` 通配兜底",
 location: dl
 )
 }
 throw ParserError.invalidStatement(
 reason: "match 子块内只允许 `case` 分支（pass 通配子块已随 G28 更新移除，请改用 `case _:`）",
 location: currentLocation
 )
 }
 
 let caseLoc = currentLocation
 advance()
 
 let pattern: MatchPattern
 if case .identifier("_", _) = currentToken {
 advance()
 pattern = .wildcard
 } else if case .integerLiteral(let n, _) = currentToken {
 advance()
 pattern = .intLiteral(n)
 } else if case .floatLiteral(let f, _) = currentToken {
 advance()
 pattern = .floatLiteral(f)
 } else if case .stringLiteral(let s, _) = currentToken {
 advance()
 pattern = .stringLiteral(s)
 } else if case .boolLiteral(let b, _) = currentToken {
 advance()
 pattern = .boolLiteral(b)
 } else if case .identifier(let name, _) = currentToken {
 advance()
 pattern = .enumCase(name)
 } else if case .keyword(.nil, _) = currentToken {
 advance()
 // `nil` 在匹配模式中 = `Optional.none`；映射为 `.enumCase("none")`
 // （与既有 `case none:` 同构，解释器 matchCaseMatches 按 caseName == "none" 命中）。
 pattern = .enumCase("none")
 } else {
 throw ParserError.unexpectedToken(expected: "match pattern (case name / literal / _)", actual: currentToken.typeName, location: currentLocation)
 }

 var bindings: [MatchBinding] = []
 if case .enumCase = pattern, case .leftParen(_) = currentToken {
 advance()
 while !check(.rightParen(caseLoc)) {
 let firstTok = currentToken
 if case .identifier(let possibleName, let nameLoc) = firstTok {
 let nextTok = peek(offset: 1)
 if case .colon(let colonLoc) = nextTok {
 // ADR 具名关联值决议（2026-08-29）：具名绑定 `关联值名: 变量` 解禁
 // （推翻 3.15 具名绑定拒绝；语义 = 按关联值名对位绑定）。
 advance()
 advance()
 guard case .identifier(let varIdent, _) = currentToken else {
 throw ParserError.unexpectedToken(expected: "identifier (binding variable)", actual: currentToken.typeName, location: currentLocation)
 }
 advance()
 bindings.append(MatchBinding(paramName: possibleName, varName: varIdent))
 _ = colonLoc
 } else if possibleName == "_" {
 // `_` 占位：占一个关联值位置但不产生绑定变量（按位忽略）
 advance()
 bindings.append(MatchBinding(paramName: nil, varName: "_"))
 } else {
 advance()
 bindings.append(MatchBinding(paramName: nil, varName: possibleName))
 }
 } else {
 throw ParserError.unexpectedToken(expected: "identifier", actual: currentToken.typeName, location: currentLocation)
 }
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(caseLoc))
 }
 
 let caseBlock = try parseControlBlock()
 
 cases.append(MatchCase(
 pattern: pattern,
 bindings: bindings,
 block: caseBlock,
 location: caseLoc
 ))
 
 skipNewlines()
 }
 
 // DEDENT（收集模式下若已到 EOF 则容错收尾，避免假性 DEDENT 错误）
 if !collectMode {
 try expect(.dedent(loc))
 } else if check(.dedent(loc)) {
 advance()
 }

 return Statement.matchStatement(
 value: value,
 cases: cases,
 location: loc
 )
 }
 
 private func parseTry() throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 try
 
 // 表达式
 let expr = try parseExpression()
 
 // try块
 let tryBlock = try parseControlBlock()
 
 // except块
 var exceptClauses: [ExceptClause] = []
 skipNewlines()
 while checkKeyword(.except) {
 advance()
 let errorVar = try parseIdentifier()
 let exceptBlock = try parseControlBlock()
 exceptClauses.append(ExceptClause(
 errorVar: errorVar,
 body: exceptBlock,
 location: currentLocation
 ))
 skipNewlines()
 }
 
 return Statement.tryStatement(
 expression: expr,
 tryBlock: tryBlock,
 exceptClauses: exceptClauses,
 location: loc
 )
 }
 
 private func parseDefer() throws -> Statement {
 let loc = currentLocation
 advance() // 跳过 defer
 
 // G51④/P0（2026-08-31）：defer 双形态——
 // ①相邻单行：`defer 语句`（宿主现行）；
 // ②块形式：`defer:` + 缩进体（草稿 §defer 块退出前清理）。
 // 块形式 AST 复用 deferStatement(scopedBlock)：整个块作为**一个** defer 项入
 // deferStack，包含块退出时按书写序执行（跨 defer 的 LIFO 由 deferStack 保证）。
 if case .colon(_) = currentToken {
 let body = try parseControlBlock()
 let inner = Statement.scopedBlock(label: nil, body: body, location: loc)
 return Statement.deferStatement(statement: inner, location: loc)
 }
 
 // defer 后面可以跟赋值或表达式语句
 let stmt = try parseAssignOrExpr()
 
 return Statement.deferStatement(statement: stmt, location: loc)
 }

 // MARK: - Expression解析（运算符优先级爬升）
 
 private func parseExpression() throws -> Expression {
 return try parseAssignment()
 }
 
 private func parseAssignment() throws -> Expression {
 // 赋值是语句而非表达式，这里处理非赋值的表达式
 return try parseOr()
 }
 
 private func parseOr() throws -> Expression {
 var left = try parseAnd()
 
 while case .logicalOr(_) = currentToken {
 let loc = currentLocation
 advance()
 let right = try parseAnd()
 left = Expression.binary(left: left, op: .or, right: right, location: loc)
 }
 
 return left
 }
 
 private func parseAnd() throws -> Expression {
 var left = try parseEquality()
 
 while case .logicalAnd(_) = currentToken {
 let loc = currentLocation
 advance()
 let right = try parseEquality()
 left = Expression.binary(left: left, op: .and, right: right, location: loc)
 }
 
 return left
 }
 
 private func parseEquality() throws -> Expression {
 var left = try parseComparison()
 
 while true {
 let op: BinaryOperator?
 if case .equal(_) = currentToken {
 op = .equal
 } else if case .notEqual(_) = currentToken {
 op = .notEqual
 } else {
 op = nil
 }
 
 guard let binaryOp = op else { break }
 
 let loc = currentLocation
 advance()
 let right = try parseComparison()
 left = Expression.binary(left: left, op: binaryOp, right: right, location: loc)
 }
 
 return left
 }
 
 private func parseComparison() throws -> Expression {
 var left = try parseBitwise()
 
 while isComparisonOperator() {
 let loc = currentLocation
 let op: BinaryOperator = try getComparisonOperator()
 advance()
 let right = try parseBitwise()
 left = Expression.binary(left: left, op: op, right: right, location: loc)
 }
 
 return left
 }
 
 private func isComparisonOperator() -> Bool {
 switch currentToken {
 case .lessThan(_), .greaterThan(_), .lessThanOrEqual(_), .greaterThanOrEqual(_):
 return true
 default:
 return false
 }
 }
 
 private func getComparisonOperator() throws -> BinaryOperator {
 switch currentToken {
 case .lessThan(_): return .lessThan
 case .greaterThan(_): return .greaterThan
 case .lessThanOrEqual(_): return .lessThanOrEqual
 case .greaterThanOrEqual(_): return .greaterThanOrEqual
 default:
 throw ParserError.invalidExpression(reason: "无效的比较运算符", location: currentLocation)
 }
 }
 
 private func parseBitwise() throws -> Expression {
 var left = try parseTerm()
 
 while isBitwiseOperator() {
 let loc = currentLocation
 let op: BinaryOperator = try getBitwiseOperator()
 advance()
 let right = try parseTerm()
 left = Expression.binary(left: left, op: op, right: right, location: loc)
 }
 
 return left
 }
 
 private func isBitwiseOperator() -> Bool {
 switch currentToken {
 case .bitwiseAnd(_), .bitwiseXor(_), .leftShift(_), .rightShift(_):
 return true
 default:
 return false
 }
 }
 
 private func getBitwiseOperator() throws -> BinaryOperator {
 switch currentToken {
 case .bitwiseAnd(_): return .bitwiseAnd
 case .bitwiseXor(_): return .bitwiseXor
 case .leftShift(_): return .leftShift
 case .rightShift(_): return .rightShift
 default:
 throw ParserError.invalidExpression(reason: "无效的位运算符", location: currentLocation)
 }
 }
 
 private func parseTerm() throws -> Expression {
 var left = try parseFactor()
 
 while true {
 let op: BinaryOperator?
 if case .plus(_) = currentToken {
 op = .plus
 } else if case .minus(_) = currentToken {
 op = .minus
 } else {
 op = nil
 }
 
 guard let binaryOp = op else { break }
 
 let loc = currentLocation
 advance()
 let right = try parseFactor()
 left = Expression.binary(left: left, op: binaryOp, right: right, location: loc)
 }
 
 return left
 }
 
 private func parseFactor() throws -> Expression {
 var left = try parseUnary()
 
 while true {
 let op: BinaryOperator?
 if case .star(_) = currentToken {
 op = .multiply
 } else if case .slash(_) = currentToken {
 op = .divide
 } else if case .percent(_) = currentToken {
 op = .modulo
 } else {
 op = nil
 }
 
 guard let binaryOp = op else { break }
 
 let loc = currentLocation
 advance()
 let right = try parseUnary()
 left = Expression.binary(left: left, op: binaryOp, right: right, location: loc)
 }
 
 return left
 }
 
 private func parseUnary() throws -> Expression {
 let loc = currentLocation

 // ADR-012：`await`/`wait` 前缀 = join / 挂起 await，取代立场 B 的 `<=` 前缀。
 // `await` 用于异步函数体（=>` 派发）内的挂起等待；`wait` 用于同步上下文的阻塞 join；
 // 二者均映射到既有 `.join` AST 节点（运行时按 suspendMode 上下文敏感，与立场 B 的 `<=` 行为一致）。
 // `await`/`wait` 仅作表达式起始位的前缀——`<=` 在此已回归纯比较运算符（中缀比较见 parseComparison）。
 if case .keyword(.await, _) = currentToken {
 advance()
 let operand = try parseUnary()
 return .join(operand, loc)
 }
 if case .keyword(.wait, _) = currentToken {
 advance()
 let operand = try parseUnary()
 return .join(operand, loc)
 }

 if case .logicalNot(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unary(op: .not, operand: operand, location: loc)
 }
 
 if case .increment(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unary(op: .increment, operand: operand, location: loc)
 }
 
 if case .decrement(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unary(op: .decrement, operand: operand, location: loc)
 }
 
 if case .bitwiseNot(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unary(op: .bitwiseNot, operand: operand, location: loc)
 }
 
 if case .plus(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unary(op: .plus, operand: operand, location: loc)
 }
 
 if case .minus(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unary(op: .minus, operand: operand, location: loc)
 }

 // 草稿 A2（批次 1.4，D2）：`^` 前缀右值糖——`^expr` 解包 Result 值。
 // 仅在操作数起始位（parseUnary 在取得左操作数后被 parseFactor 调用，
 // 中缀位异或 `^` 由 parseBitwise 消费），与类型糖 `^T` 上下文分离。
 if case .bitwiseXor(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.resultUnwrap(operand: operand, location: loc)
 }

 // Phase 2a（ADR-015 FFI）：`unsafe` 不安全消耗点前缀。
 if case .keyword(.unsafe, _) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.unsafe(operand: operand, location: loc)
 }

 // Phase 2a（ADR-015 FFI）：`&` 不安全取地址前缀（复用 .bitwiseAnd token，
 // 前缀位置与中缀按位与靠语法位置消歧——parseUnary 在操作数起始位消费）。
 if case .bitwiseAnd(_) = currentToken {
 advance()
 let operand = try parseUnary()
 return Expression.addressOf(operand: operand, location: loc)
 }
 
 return try parsePrimary()
 }
 
 private func parsePrimary() throws -> Expression {
 let expr = try parsePrimaryAtom()
 return try parsePrimarySuffix(expr: expr)
 }
 
 private func parsePrimaryAtom() throws -> Expression {
 let loc = currentLocation
 
 switch currentToken {
 case .identifier(let name, _):
 advance()
 // 右值位置下的泛型构造调用前瞻识别：identifier < 类型 > ( args )
 if case .lessThan(_) = currentToken {
 if let construct = try? parseGenericConstructLookahead(
 typeName: name,
 location: loc
 ) {
 return construct
 }
 }
 return .identifier(name: name, location: loc)
 case .keyword(.self, _):
 advance()
 return .selfKeyword(location: loc)
 // G50：`own`（原 Self）在表达式位置仍产出 selfTypeKeyword 节点（AST case 名暂不改，最小迁移面）
 case .keyword(.own, _):
 advance()
 return .selfTypeKeyword(location: loc)
 case .keyword(.func, _):
 return try parseFuncLiteral()
 case .integerLiteral(let value, _):
 advance()
 return .integerLiteral(value: value, location: loc)
 case .floatLiteral(let value, _):
 advance()
 return .floatLiteral(value: value, location: loc)
 case .stringLiteral(let value, _):
 advance()
 return .stringLiteral(value: value, location: loc)
 case .interpolatedString(let segments, _):
 advance()
 var astSegments: [InterpolationSegment] = []
 for seg in segments {
 switch seg {
 case .literal(let s):
 astSegments.append(.literal(s))
 case .expression(let src):
 let subLexer = Lexer(source: src, fileName: fileName)
 let rawSubTokens = try subLexer.tokenize()
 let subTokens = rawSubTokens.filter { token in
 switch token {
 case .indent, .dedent, .newline: return false
 default: return true
 }
 }
 let subParser = Parser(tokens: subTokens, fileName: fileName)
 let expr = try subParser.parseExpression()
 astSegments.append(.expression(expr))
 }
 }
 return .stringInterpolation(segments: astSegments, location: loc)
 case .boolLiteral(let value, _):
 advance()
 return .boolLiteral(value: value, location: loc)
 case .keyword(.nil, _):
 advance()
 // `nil` 是 `Optional.none` 的等效常量关键字：映射为与 `Optional.none`
 // 完全同构的 `.member(identifier("Optional"), "none")` AST，全链路复用其既有
 // 类型推断 / 解释器 / IR 路径（spec G30，零新增 Expression/Value case）。
 return .member(object: .identifier(name: "Optional", location: loc), name: "none", location: loc)
 case .leftParen(_):
 // 可能是元组或优先结合表达式
 return try parseTupleOrParen()
 case .leftBracket(_):
 return try parseCollectionLiteral()
 case .leftBrace(_):
 return try parseSetLiteral()
 case .dot(_):
 // 点号用例构造（proposal-dot-case-construction，D-1：与 Swift UnresolvedMemberExpr
 // 同构）：前导点 = 成员意图标记，解析期仅携带名字的未解析节点，决议在类型检查
 // 阶段按期望类型完成（期望类型命中 → 该枚举；唯一父枚举 → 回退；歧义/无 → 报错
 // 要求限定或期望类型）。带实参形态 `.caseName(args)` 由 parsePrimarySuffix 的
 // 调用后缀自然包裹为 .call(.dotCaseRef, args)——与 Swift 的实参挂外层 Apply 同构。
 advance()
 let name = try parseIdentifier()
 return .dotCaseRef(name: name, location: loc)
 default:
 throw ParserError.invalidExpression(reason: "无效的表达式", location: loc)
 }
 }

 /// 前瞻判定 identifier<...> 是否为泛型构造调用
 /// 判定条件：< 后跟合法类型注解，且以 > 闭合，且 > 后跟 ( 或 .
 /// 若判定失败返回 nil，调用方回退为比较运算符
 private func parseGenericConstructLookahead(typeName: String, location: SourceLocation) throws -> Expression? {
 // 保存当前位置以便回溯
 let savedPosition = position

 // 消费 <
 advance() // lessThan

 // 尝试解析类型参数列表
 var typeArgs: [TypeAnnotation] = []
 while !isEOF() {
 // 跳过前导逗号（列表分隔）
 if case .comma(_) = currentToken {
 advance()
 continue
 }
 // 遇到 > 表示列表结束
 if case .greaterThan(_) = currentToken {
 break
 }
 // 遇到 rightShift（>>）表示嵌套泛型闭合——本计划不支持嵌套，回退
 if case .rightShift(_) = currentToken {
 position = savedPosition
 return nil
 }
 // 尝试解析类型注解
 guard let typeArg = try? parseTypeAnnotationForLookahead() else {
 position = savedPosition
 return nil
 }
 typeArgs.append(typeArg)
 }

 // 期望 > 闭合
 guard case .greaterThan(_) = currentToken else {
 position = savedPosition
 return nil
 }
 advance() // 消费 >

 // > 后必须跟 ( 或 . 才认定为泛型构造调用
 let nextTok = currentToken
 let isConstructCall = { () -> Bool in
 if case .leftParen(_) = nextTok { return true }
 if case .dot(_) = nextTok { return true }
 return false
 }()

 guard isConstructCall else {
 position = savedPosition
 return nil
 }

 // 判定通过：解析为 genericConstruct
 // 若 > 后跟 (，解析参数；若跟 .，先构造无参 genericConstruct，后续由 parsePrimarySuffix 处理成员访问
 var arguments: [CallArgument] = []
 if case .leftParen(_) = currentToken {
 let parenLoc = currentLocation
 advance() // 消费 (
 while !check(.rightParen(parenLoc)) && !isEOF() {
 let firstTok = currentToken
 var label: String? = nil
 if case .identifier(let possibleLabel, _) = firstTok {
 let nextTok = peek(offset: 1)
 // 批 3（proposal-paren-equals-binding）：实参标签用 `=`（值的注入方向统一为 `=`）；
 // 旧写法 `f(a: 1)` 已废弃（D-1）——此处给迁移提示后报错。
 if case .assign(_) = nextTok {
 advance()
 advance()
 label = possibleLabel
 } else if case .colon(_) = nextTok {
 throw ParserError.invalidExpression(
 reason: "实参标签须用 `=`（如 `f(\(possibleLabel) = 值)`）；旧写法 `f(\(possibleLabel): 值)` 已废弃",
 location: currentLocation)
 }
 }
 let expr = try parseExpression()
 arguments.append(CallArgument(label: label, expression: expr))
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(parenLoc))
 }

 return .genericConstruct(typeName: typeName, typeArgs: typeArgs, arguments: arguments, location: location)
 }

 /// 前瞻用类型注解解析（不消费 >，由调用方处理）
 private func parseTypeAnnotationForLookahead() throws -> TypeAnnotation? {
 let loc = currentLocation

 // 简单类型（可能带嵌套泛型，但嵌套回退已在调用方处理）
 guard case .identifier(let name, _) = currentToken else {
 return nil
 }
 advance()

 // 检查是否是嵌套泛型——本计划不支持，返回 nil 触发回退
 if case .lessThan(_) = currentToken {
 return nil
 }

 return .simple(name: name, location: loc)
 }

 private func parseTupleOrParen() throws -> Expression {
 let loc = currentLocation
 advance() // 跳过 (
 
 // 检查是否是空元组
 if case .rightParen(_) = currentToken {
 advance()
 return .tuple(labels: [], elements: [], location: loc)
 }

 // 草稿 A2（批次 1.3，D1）：命名元组 `(a: 1, b: 2,)`——元素为 `标识符: 表达式`。
 // 识别规则：当前为 identifier 且下一 token 为 `:` 即命名元素；否则为位置元素（label=nil）。
 var labels: [String?] = []
 var elements: [Expression] = []

 func parseElement() throws -> Expression {
 // 批 3（D-4）：标签元组元素同样用 `=`（构造侧 = 值的注入方向）。
 if case .identifier(let name, _) = currentToken,
 case .assign(_) = peek(offset: 1) {
 advance() // 消费标识符
 advance() // 消费等号
 labels.append(name)
 return try parseExpression()
 }
 if case .identifier(let name, _) = currentToken,
 case .colon(_) = peek(offset: 1) {
 throw ParserError.invalidExpression(
 reason: "元组标签须用 `=`（如 `(\(name) = 值,)`）；旧写法 `(\(name): 值,)` 已废弃",
 location: currentLocation)
 }
 labels.append(nil)
 return try parseExpression()
 }

 let firstElement = try parseElement()
 elements.append(firstElement)
 
 // 检查是否有逗号
 if case .comma(_) = currentToken {
 // 元组
 advance() // 跳过逗号
 
 while !check(.rightParen(loc)) {
 let element = try parseElement()
 elements.append(element)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 
 try expect(.rightParen(loc))
 return .tuple(labels: labels, elements: elements, location: loc)
 }
 
 // 优先结合表达式：括号仅为分组，语义为零，直接返回内层表达式（不在核心 AST 构造 paren 节点）。
 // 例外：单元素命名元组 `(a: 1)` 无逗号，仍须保留为命名元组（标签信息不可丢）。
 try expect(.rightParen(loc))
 if labels.count == 1, labels[0] != nil {
 return .tuple(labels: labels, elements: elements, location: loc)
 }
 return firstElement
 }

 /// 解析集合字面量：数组 [a, b] 或字典 [k: v, ...]（靠元素是否含 : 消歧）
 private func parseCollectionLiteral() throws -> Expression {
 let loc = currentLocation
 advance() // 消费 [

 if case .rightBracket(_) = currentToken {
 advance()
 return .arrayLiteral(elements: [], location: loc)
 }

 let first = try parseExpression()
 // 批 3（D-2）：字典条目用 `=`（键 → 值的关联与实参绑定同记号）；`[:]` 全切片不受影响。
 if case .colon(_) = currentToken {
 throw ParserError.invalidExpression(
 reason: "字典条目须用 `=`（如 `[键 = 值]`）；旧写法 `[键: 值]` 已废弃（`[:]` 为全切片）",
 location: loc)
 }
 if case .assign(_) = currentToken {
 // 字典
 advance() // 消费 =
 var entries: [DictEntry] = []
 let firstVal = try parseExpression()
 entries.append(DictEntry(key: first, value: firstVal))
 while case .comma(_) = currentToken {
 advance()
 guard !check(.rightBracket(loc)) else { break }
 let k = try parseExpression()
 guard case .assign(_) = currentToken else {
 throw ParserError.invalidExpression(reason: "字典元素必须是 键 = 值", location: loc)
 }
 advance()
 let v = try parseExpression()
 entries.append(DictEntry(key: k, value: v))
 }
 try expect(.rightBracket(loc))
 return .dictionaryLiteral(entries: entries, location: loc)
 } else {
 // 数组
 var elements: [Expression] = [first]
 while case .comma(_) = currentToken {
 advance()
 guard !check(.rightBracket(loc)) else { break }
 elements.append(try parseExpression())
 }
 try expect(.rightBracket(loc))
 return .arrayLiteral(elements: elements, location: loc)
 }
 }

 /// 解析集合字面量：集合 {a, b, c}
 private func parseSetLiteral() throws -> Expression {
 let loc = currentLocation
 advance() // 消费 {

 if case .rightBrace(_) = currentToken {
 advance()
 return .setLiteral(elements: [], location: loc)
 }

 var elements: [Expression] = []
 while !check(.rightBrace(loc)) && !isEOF() {
 elements.append(try parseExpression())
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightBrace(loc))
 return .setLiteral(elements: elements, location: loc)
 }

 private func parsePrimarySuffix(expr: Expression) throws -> Expression {
 var result = expr
 
 while true {
 let loc = currentLocation
 
 // 调用 ()
 if case .leftParen(_) = currentToken {
 advance()
 var arguments: [CallArgument] = []
 while !check(.rightParen(loc)) {
 let firstTok = currentToken
 var label: String? = nil
 if case .identifier(let possibleLabel, _) = firstTok {
 let nextTok = peek(offset: 1)
 // 批 3（proposal-paren-equals-binding）：实参标签用 `=`（值的注入方向统一为 `=`）；
 // 旧写法 `f(a: 1)` 已废弃（D-1）——此处给迁移提示后报错。
 if case .assign(_) = nextTok {
 advance()
 advance()
 label = possibleLabel
 } else if case .colon(_) = nextTok {
 throw ParserError.invalidExpression(
 reason: "实参标签须用 `=`（如 `f(\(possibleLabel) = 值)`）；旧写法 `f(\(possibleLabel): 值)` 已废弃",
 location: currentLocation)
 }
 }
 let expr = try parseExpression()
 arguments.append(CallArgument(label: label, expression: expr))
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 result = Expression.call(callee: result, arguments: arguments, location: loc)
 continue
 }
 
 // 成员访问 . 或 元组位置访问 .0
 if case .dot(_) = currentToken {
 advance()
 // 草稿 A2（批次 1）：`.` 后随整数 = 元组位置访问 `.index`（如 `some_thing_error().0`）；
 // 否则为成员访问 `.名称`。与 `3.14` 浮点无冲突（`.` 前非数字）。
 if case .integerLiteral(let idx, _) = currentToken, idx >= 0 {
 advance()
 result = Expression.tupleIndex(object: result, index: idx, location: loc)
 continue
 }
 let name = try parseIdentifier()
 result = Expression.member(object: result, name: name, location: loc)
 continue
 }

 // 下标访问 [index]：容器是任意前序表达式（call/member/subscript/元组/...），非 identifier-only——
 // 解析累积到 `result`，故 (expr)[i] 天然支持（架构演进 #45 固化的契约）。
 // P2-B：检测到冒号即进入切片语法脱糖（见 sliceSugar 助手），`a[i:j]`/`a[i:]`/`a[:j]`/`a[:]`。
 if case .leftBracket(_) = currentToken {
 advance()
 // 切片形态一：起始省略 `a[:j]` / `a[:]`
 if case .colon(_) = currentToken {
 advance() // 消费起始冒号，随后解析终止边界
 let start = sliceNilLiteral(loc)
 let end: Expression
 if case .rightBracket(_) = currentToken {
 end = sliceNilLiteral(loc)
 advance() // 消费 ]
 } else {
 end = try parseExpression()
 try expect(.rightBracket(loc))
 }
 result = sliceSugar(base: result, start: start, end: end, location: loc)
 continue
 }
 let indexExpr = try parseExpression()
 // 切片形态二：起始给定，`a[i:j]` / `a[i:]`
 if case .colon(_) = currentToken {
 advance()
 let end: Expression
 if case .rightBracket(_) = currentToken {
 end = sliceNilLiteral(loc)
 advance() // 消费 ]
 } else {
 end = try parseExpression()
 try expect(.rightBracket(loc))
 }
 result = sliceSugar(base: result, start: indexExpr, end: end, location: loc)
 continue
 }
 try expect(.rightBracket(loc))
 result = Expression.subscript(expr: result, index: indexExpr, location: loc)
 continue
 }

 // 后缀强制解包 `!`：紧接 primary/后缀表达式（标识符、调用、成员、下标、元组位置…）之后。
 // 与前缀逻辑非 `!` 同字符，按位置消歧——parseUnary 在操作数起始位消费前缀 `!`（→ .not），
 // 此处仅在已取得左操作数后的后缀位消费 `!`（→ .forceUnwrap），如 `a[i]!`、`m[i]![j]`。
 // `!=` 已被词法归并为单独 .notEqual token，故后缀位出现的 .logicalNot 必为强制解包。
 if case .logicalNot(_) = currentToken {
 advance()
 result = Expression.unary(op: .forceUnwrap, operand: result, location: loc)
 continue
 }

 break
 }

 return result
}

// MARK: - 切片语法脱糖（P2-B）

/// 开放边界字面量：复用 `nil` 的 AST 形态（= `.member(identifier("Optional"), "none")`），
/// 运行时求值为 `Optional.none`，切片实现据此识别为"省略该边界"。
private func sliceNilLiteral(_ loc: SourceLocation) -> Expression {
 return .member(object: .identifier(name: "Optional", location: loc), name: "none", location: loc)
}

/// 将切片语法 `base[start:end]` 脱糖为成员调用 `base.slice(start, end)`，
/// 复用既有的数组 / 字符串成员方法通道（evaluateMember + defineMethod），
/// 不新增 AST 节点、不触碰 ~25 处 Expression 穷尽 switch。
private func sliceSugar(base: Expression, start: Expression, end: Expression, location: SourceLocation) -> Expression {
 return .call(
 callee: .member(object: base, name: "slice", location: location),
 arguments: [CallArgument(expression: start), CallArgument(expression: end)],
 location: location
 )
}

// MARK: - TypeAnnotation解析
 
 private func parseTypeAnnotation() throws -> TypeAnnotation {
 let loc = currentLocation

 // 前缀可选类型糖 ?T === Optional<T>（spec G31 / G31）
 // 在类型注解起始处特判 ?，递归解析内层类型后映射为既有 Optional 泛型。
 if case .questionMark(_) = currentToken {
 advance()
 let inner = try parseTypeAnnotation()
 return .generic(name: "Optional", params: [inner], location: loc)
 }

 // 前缀结果类型糖 ^T === Result<T>（类型上下文内 ^ 仅表 Result 糖，
 // 类比 <?T> 复用 < 的上下文消歧，与表达式上下文的位异或 ^ 不冲突）。
 // 类型注解起始处特判 ^（复用 .bitwiseXor token）。
 if case .bitwiseXor(_) = currentToken {
 advance()
 let inner = try parseTypeAnnotation()
 return .generic(name: "Result", params: [inner], location: loc)
 }

 // Phase 2a（ADR-015 FFI）：前缀指针类型糖 *T ≡ 原始指针（复用 .star token）。
 // 元素类型为 C 兼容类型（标量/纯值结构体/另一指针）；T 禁 object（ARC 隔离）。
 if case .star(_) = currentToken {
 advance()
 let inner = try parseTypeAnnotation()
 return .pointer(element: inner, location: loc)
 }

 // 数组类型 [T]
 if case .leftBracket(_) = currentToken {
 advance()
 let elemType = try parseTypeAnnotation()
 if case .colon(_) = currentToken {
 // 字典类型 [K: V]
 advance()
 let valType = try parseTypeAnnotation()
 try expect(.rightBracket(loc))
 return .generic(name: "Dictionary", params: [elemType, valType], location: loc)
 }
 try expect(.rightBracket(loc))
 return .generic(name: "Array", params: [elemType], location: loc)
 }

 // 集合类型 {T}
 if case .leftBrace(_) = currentToken {
 advance()
 let elemType = try parseTypeAnnotation()
 try expect(.rightBrace(loc))
 return .generic(name: "Set", params: [elemType], location: loc)
 }

 // 简单类型
 if case .identifier(let name, _) = currentToken {
 advance()
 
 // 检查是否是泛型类型
 if case .lessThan = currentToken {
 // 注意：这里的 < 可能是泛型参数，需要检查后续是否是 >
 // 但由于 < 也是比较运算符，需要特殊处理
 // 暂时简化处理：假设是泛型类型
 advance()
 var params: [TypeAnnotation] = []
 while !check(.greaterThan(loc)) {
 let paramType = try parseTypeAnnotation()
 params.append(paramType)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 // 这里需要检查 greaterThan token，但Token中没有 greaterThan 作为闭合符
 // 暂时跳过
 if case .greaterThan = currentToken {
 advance()
 }
 
 return .generic(name: name, params: params, location: loc)
 }
 
 return .simple(name: name, location: loc)
 }
 
 // 元组类型
 if case .leftParen(_) = currentToken {
 advance()
 var labels: [String?] = []
 var elements: [TypeAnnotation] = []
 while !check(.rightParen(loc)) {
 // 草稿 A2（批次 1.3，D1）：命名元组类型元素 `标识符: 类型`（如 `-> (商: I32, 余: I32,)`）。
 if case .identifier(let name, _) = currentToken,
 case .colon(_) = peek(offset: 1) {
 advance()
 advance()
 labels.append(name)
 elements.append(try parseTypeAnnotation())
 } else {
 labels.append(nil)
 elements.append(try parseTypeAnnotation())
 }
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 
 // 检查是否是函数类型
 if case .arrow(_) = currentToken {
 advance()
 try expect(.leftParen(loc))
 var returns: [TypeAnnotation] = []
 while !check(.rightParen(loc)) {
 let returnType = try parseTypeAnnotation()
 returns.append(returnType)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 // 函数类型参数元组中的 `名: 类型` 视为参数名，不落入 tuple labels（.function 用 elements）。
 return .function(params: elements, returns: returns, captured: [], location: loc)
 } else if case .doubleArrow(_) = currentToken {
 advance()
 try expect(.leftParen(loc))
 var returns: [TypeAnnotation] = []
 while !check(.rightParen(loc)) {
 let returnType = try parseTypeAnnotation()
 returns.append(returnType)
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 }
 try expect(.rightParen(loc))
 return .function(params: elements, returns: returns, captured: [], location: loc)
 }
 
 return .tuple(labels: labels, elements: elements, location: loc)
 }
 
 // self 和 own 类型（G50：Self 更名 own）
 if checkKeyword(.self) {
 advance()
 return .simple(name: "self", location: loc)
 }

 if checkKeyword(.own) {
 advance()
 return .simple(name: "own", location: loc)
 }
 
 throw ParserError.invalidType(reason: "无效的类型标注", location: loc)
 }
 
 private func parseGenericParams() throws -> [GenericParam] {
 // <T|约束,>
 var params: [GenericParam] = []
 
 // 这里需要处理 <，但由于 < 也是比较运算符，需要特殊处理
 // 暂时假设是泛型参数
 if case .lessThan = currentToken {
 advance()
 }
 
 while true {
 let name = try parseIdentifier()
 
 // 可选的约束（H-2/A9 裁决，2026-08-31）：分隔符为 `:`，与扩展块特征约束
 // `((块:特征))` 同形；旧 `|` 分隔废除（顶级 `|` 右侧是块形态关键字位）。
 var constraint: TypeAnnotation? = nil
 if case .colon(_) = currentToken {
 advance()
 constraint = try parseTypeAnnotation()
 } else if case .pipe(_) = currentToken {
 throw ParserError.invalidType(
 reason: "泛型约束分隔符已改为 `:`（H-2/A9）：写作 `<T: 约束,>`",
 location: currentLocation
 )
 }
 
 params.append(GenericParam(name: name, constraint: constraint))
 
 if case .comma(_) = currentToken {
 advance()
 } else {
 break
 }
 
 // 检查是否到达结束
 if case .greaterThan = currentToken {
 break
 }
 }
 
 // 结束符 >
 if case .greaterThan = currentToken {
 advance()
 }
 
 return params
 }
 
 private func parseParameter() throws -> Parameter {
 let loc = currentLocation
 
 // 参数名
 let name = try parseIdentifier()
 
 // 类型标注（可选）
 var typeAnnotation: TypeAnnotation? = nil
 if case .colon(_) = currentToken {
 advance()
 typeAnnotation = try parseTypeAnnotation()
 }
 
 // 默认值（可选）
 // 注意：参数默认值在参数元组中使用 = 表达式 形式
 // 但这里暂时不处理
 
 return Parameter(name: name, typeAnnotation: typeAnnotation)
 }
 
 // MARK: - 辅助
 
 private func parseIdentifier() throws -> String {
 switch currentToken {
 case .identifier(let name, _):
 advance()
 return name
 case .keyword(.self, _):
 advance()
 return "self"
 case .keyword(.own, _):
 advance()
 return "own"
 case .keyword(.func, _):
 advance()
 return "func"
 case .keyword(.unsafe, _):
 // Phase 2a（ADR-015 FFI， modifier）：`|unsafe` 函数修饰符。
 advance()
 return "unsafe"
 case .keyword(.foreign, _):
 // Phase 2a（ADR-015 FFI， modifier）：`[名称|foreign]` 块修饰符。
 advance()
 return "foreign"
 case .keyword(.test, _):
 // G51：`名称|test` 测试函数块修饰符（G41）——宿主词法对齐自举 kw_test。
 advance()
 return "test"
 default:
 throw ParserError.expectedToken(token: "identifier", location: currentLocation)
 }
 }
 
 private func isTopLevelDeclStart() -> Bool {
 switch currentToken {
 case .leftParen(_), .leftBracket(_):
 return true
 case .keyword(.import, _), .keyword(.export, _):
 return true
 case .leftBrace(_):
 // ADR-016 规则 3.2：类型体内禁止函数声明后，行首 `{` 恒为顶级声明
 //（`{name|func}` 函数块或 `{name}` 对象块），不再需要方法缺省假定区分。
 return true
 case .lessThan(_):
 // 特征体声明头：<identifier>
 let token1 = peek(offset: 1)
 if case .identifier(_, _) = token1 {
 let token2 = peek(offset: 2)
 if case .greaterThan(_) = token2 {
 return true
 }
 }
 return false
 case .identifier(_):
 // 裸函数声明：`name(params,) -> (ret,)`
 return isBareFunctionDeclStart()
 default:
 return false
 }
 }
}
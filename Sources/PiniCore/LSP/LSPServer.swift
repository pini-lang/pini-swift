import Foundation

/// LSP 服务主循环：stdio JSON-RPC 收发 + method dispatch。
/// 覆盖 LSP method 子集：initialize / didOpen / didChange / completion / definition / shutdown / exit。
public final class LSPServer {
 private let transport: LSPTransport
 private let encoder = JSONEncoder()
 private let decoder = JSONDecoder()
 
 /// 当前打开的文档：uri → (text, version)
 private var documents: [String: (text: String, version: Int)] = [:]
 
 /// 文档解析/检查后的 Scope 缓存
 private var documentScopes: [String: Scope] = [:]
 
 /// 文档的包级索引缓存
 private var documentIndex: [String: PackageSymbolIndex] = [:]

 /// LSP 诊断语言（T11 解耦）：由 `initialize` 的 `locale` 决定（zh* → 中文，否则英文），
 /// 独立于 CLI --lang 全局状态；未收到 locale 时默认英文。
 private var diagnosticLanguage: DiagnosticLanguage = .en

 /// 按 LSP locale 决定诊断语言（LSP 规范：客户端 locale，如 "zh-CN"）。
 static func language(fromLocale locale: String?) -> DiagnosticLanguage {
 guard let l = locale?.lowercased() else { return .en }
 return l.hasPrefix("zh") ? .zh : .en
 }

 public init(transport: LSPTransport = LSPTransport()) {
 self.transport = transport
 }

 /// 启动主循环（阻塞）
 public func start() {
 while true {
 let data: Data?
 do {
 data = try transport.readMessage()
 } catch {
 // 单帧解析/帧错误：记录后继续读取下一条，避免整服崩溃退出。
 // EOF 由 readMessage 返回 nil 表达，走下面 guard 干净退出。
 FileHandle.standardError.write(Data("LSP transport error: \(error)\n".utf8))
 continue
 }
 guard let data else { break } // EOF → 干净退出
 handleMessage(data)
 }
 }

 // MARK: - Message dispatch

 private func handleMessage(_ data: Data) {
 // 通知与请求都含 jsonrpc/method，但请求必有 id；
 // 因 RequestMessage.id 可选，通知也会成功解码成 RequestMessage(id==nil)，
 // 必须以 id 是否存在区分，否则通知会被 dispatchRequest 的 guard 直接吞掉，
 // 导致 didOpen/didChange/exit 等通知永不生效（诊断在真实编辑器里失效）。
 if let req = try? transport.decodeRequest(data), req.id != nil {
 dispatchRequest(req)
 return
 }
 if let notif = try? transport.decodeNotification(data) {
 dispatchNotification(notif)
 return
 }
 }

 private func dispatchRequest(_ req: RequestMessage) {
 guard let id = req.id else {
 // 无 id 的 request 视为 notification
 return
 }
 do {
 switch req.method {
 case "initialize":
 let result = try handleInitialize(req)
 try transport.sendResponse(id: id, result: result)
 case "shutdown":
 try transport.sendResponse(id: id, result: .object(["success": .bool(true)]))
 case "textDocument/completion":
 let result = try handleCompletion(req)
 try transport.sendResponse(id: id, result: result)
 case "textDocument/definition":
 let result = try handleDefinition(req)
 try transport.sendResponse(id: id, result: result)
 default:
 try transport.sendError(id: id, error: .methodNotFound)
 }
 } catch {
 try? transport.sendError(id: id, error: .internalError)
 }
 }

 private func dispatchNotification(_ notif: NotificationMessage) {
 switch notif.method {
 case "initialized":
 // no-op, client is ready
 break
 case "textDocument/didOpen":
 handleDidOpen(notif)
 case "textDocument/didChange":
 handleDidChange(notif)
 case "textDocument/didClose":
 handleDidClose(notif)
 case "exit":
 exit(0)
 default:
 break
 }
 }

 // MARK: - Handlers

 private func handleInitialize(_ req: RequestMessage) throws -> JSONValue {
 // T11（解耦）：诊断语言跟随 LSP 客户端 locale（InitializeParams.locale），不随 CLI --lang。
 if let params = req.params, let obj = params.objectValue,
 let locale = obj["locale"]?.stringValue {
 diagnosticLanguage = Self.language(fromLocale: locale)
 }
 return try encoder.encodeJSONValue(InitializeResult(
 capabilities: .default,
 serverInfo: ServerInfo(name: "pini-lsp", version: "0.1.0")
 ))
 }

 private func handleDidOpen(_ notif: NotificationMessage) {
 guard let params = notif.params,
 let obj = params.objectValue,
 let td = obj["textDocument"]?.objectValue,
 let uri = td["uri"]?.stringValue,
 let text = td["text"]?.stringValue,
 let version = td["version"]?.intValue else { return }

 documents[uri] = (text, version)
 publishDiagnostics(uri: uri, text: text)
 }

 private func handleDidChange(_ notif: NotificationMessage) {
 guard let params = notif.params,
 let obj = params.objectValue,
 let td = obj["textDocument"]?.objectValue,
 let uri = td["uri"]?.stringValue else { return }

 // 读取 contentChanges（Full sync）
 var contentChanges: [JSONValue] = []
 if let cc = obj["contentChanges"]?.arrayValue {
 contentChanges = cc
 }
 // 回退到上次文本：contentChanges 缺失/为空时（不合法负载或增量同步场景），
 // 不能用空串覆盖，否则会用空文档重跑诊断、冲掉已有诊断并把 scope/index 清空。
 var text = documents[uri]?.text ?? ""
 var version: Int = 0
 if let ver = td["version"]?.intValue {
 version = ver
 }

 // 取最后一次全文变更
 if let lastChange = contentChanges.last,
 let changeObj = lastChange.objectValue,
 let newText = changeObj["text"]?.stringValue {
 text = newText
 }

 documents[uri] = (text, version)
 publishDiagnostics(uri: uri, text: text)
 }

 private func handleDidClose(_ notif: NotificationMessage) {
 guard let params = notif.params,
 let obj = params.objectValue,
 let td = obj["textDocument"]?.objectValue,
 let uri = td["uri"]?.stringValue else { return }
 // 释放该文档的缓存，避免长会话内存只增不减
 documents.removeValue(forKey: uri)
 documentScopes.removeValue(forKey: uri)
 documentIndex.removeValue(forKey: uri)
 }

 // MARK: - Diagnostic Pipeline

 private func publishDiagnostics(uri: String, text: String) {
 let fileName = Self.fileNameFromURI(uri)

 // Step 1: Parser
 let lexer = Lexer(source: text, fileName: fileName)
 let tokens: [Token]
 do {
 tokens = try lexer.tokenize()
 } catch {
 // 词法错误直接发布（无 ParserError 结构体 → 暂用空数组）
 publishDiagnostics(uri: uri, parserErrors: [],
 semanticErrors: [], typeErrors: [], source: text)
 return
 }

 let parser = Parser(tokens: tokens, fileName: fileName)
 let parseResult = parser.parseModuleCollectingErrors()

 let parserErrors = parseResult.errors
 var semanticErrors: [SemanticError] = []
 var typeErrors: [TypeError] = []
 var semanticWarnings: [SemanticWarning] = []

 // Step 2: 如果 Parser 有结构性错误，跳过语义阶段
 let hasStructuralError = parserErrors.contains { err in
 if case .unexpectedEOF = err { return true }
 if case .missingBlockEnd = err { return true }
 if case .missingBlockBody = err { return true }
 return false
 }

 if !hasStructuralError {
 // Step 3: Semantic + Type check
 let module = parseResult.module
 let analyzer = SemanticAnalyzer()
 semanticErrors = analyzer.analyzeCollecting(module: module)
 semanticWarnings = analyzer.warnings // B2：warning 随诊断一起发布（severity: .warning）

 let checker = TypeChecker()
 typeErrors = checker.checkCollecting(module: module)

 // 保存 scope 供补全/跳转使用
 documentScopes[uri] = analyzer.symbolTable.current

 // 构建包级索引（单文件场景）
 let pkg = Package.singleFile(name: fileName, fileName: fileName, module: module)
 documentIndex[uri] = PackageSymbolIndex(package: pkg)
 }

 publishDiagnostics(uri: uri, parserErrors: parserErrors,
 semanticErrors: semanticErrors, typeErrors: typeErrors,
 semanticWarnings: semanticWarnings)
 }

 private func publishDiagnostics(uri: String,
 parserErrors: [ParserError],
 semanticErrors: [SemanticError],
 typeErrors: [TypeError],
 semanticWarnings: [SemanticWarning] = [],
 source: String = "") {
 let publisher = DiagnosticPublisher()
 let params = publisher.publish(
 parserErrors: parserErrors,
 semanticErrors: semanticErrors,
 typeErrors: typeErrors,
 semanticWarnings: semanticWarnings,
 uri: uri,
 source: source,
 language: diagnosticLanguage
 )
 try? transport.sendNotification(method: "textDocument/publishDiagnostics", params: params)
 }

 // MARK: - Completion Handler

 private func handleCompletion(_ req: RequestMessage) throws -> JSONValue {
 guard let params = req.params,
 let obj = params.objectValue,
 let td = obj["textDocument"]?.objectValue,
 let uri = td["uri"]?.stringValue,
 let posObj = obj["position"]?.objectValue,
 let line = posObj["line"]?.intValue,
 let char = posObj["character"]?.intValue else {
 return try encoder.encodeJSONValue(CompletionList(isIncomplete: false, items: []))
 }

 let provider = CompletionProvider()
 let scope = documentScopes[uri]
 let fullList = provider.complete(in: scope)

 // 根据光标处已输入的前缀过滤
 if let text = documents[uri]?.text {
 let prefix = extractWordAt(text: text, line: line, character: char, before: true)
 let filtered = fullList.items.filter { $0.label.hasPrefix(prefix) || prefix.isEmpty }
 let list = CompletionList(isIncomplete: false, items: filtered)
 return try encoder.encodeJSONValue(list)
 }

 return try encoder.encodeJSONValue(fullList)
 }

 // MARK: - Definition Handler

 private func handleDefinition(_ req: RequestMessage) throws -> JSONValue {
 guard let params = req.params,
 let obj = params.objectValue,
 let td = obj["textDocument"]?.objectValue,
 let uri = td["uri"]?.stringValue,
 let posObj = obj["position"]?.objectValue,
 let line = posObj["line"]?.intValue,
 let char = posObj["character"]?.intValue else {
 return .null
 }

 // 提取光标处的标识符名
 guard let text = documents[uri]?.text else { return .null }
 let identifier = extractWordAt(text: text, line: line, character: char, before: false)
 guard !identifier.isEmpty else { return .null }

 let provider = DefinitionProvider()
 let scope = documentScopes[uri]
 let index = documentIndex[uri]

 if let result = provider.findDefinition(name: identifier, scope: scope, index: index, currentURI: uri) {
 return try encoder.encodeJSONValue(result)
 }

 return .null
 }

 // MARK: - Utility

 /// 从文本中提取光标位置处的标识符（字母/数字/下划线连续串）。
 /// - Parameter before: true=只取光标前的部分，false=取完整标识符
 /// - Note: LSP `character` 是 **UTF-16 码元偏移**，必须用 `utf16` 视图索引，
 /// 不能用 Swift `String` 的 grapheme/Character 索引——非 ASCII 标识符
 /// （如中文名）在两者下偏移不同，用错会补全/跳转错位。
 func extractWordAt(text: String, line: Int, character: Int, before: Bool) -> String {
 let lines = text.components(separatedBy: "\n")
 guard line < lines.count else { return "" }
 let lineText = lines[line]
 let utf16 = lineText.utf16
 let count = utf16.count
 let idx = min(character, count)

 func isIdChar(_ i: Int) -> Bool {
 guard i >= 0, i < count else { return false }
 let cu = utf16[utf16.index(utf16.startIndex, offsetBy: i)]
 // 代理项（surrogate）不会出现在合法标识符中；直接视为非标识符字符，
 // 避免对代理项调用 UnicodeScalar(_: UInt16) 强制解包崩溃。
 let isSurrogate = (0xD800...0xDBFF).contains(cu) || (0xDC00...0xDFFF).contains(cu)
 guard !isSurrogate else { return false }
 let ch = Character(UnicodeScalar(cu)!)
 return ch.isLetter || ch.isNumber || ch == "_"
 }

 if before {
 // 提取光标前的连续标识符字符（用于补全前缀匹配）
 var i = idx - 1
 while i >= 0, isIdChar(i) { i -= 1 }
 let start = utf16.index(utf16.startIndex, offsetBy: i + 1)
 let end = utf16.index(utf16.startIndex, offsetBy: idx)
 return Self.string(fromUTF16: utf16[start..<end])
 } else {
 // 提取完整标识符（向前+向后扫描）
 var start = idx
 while start > 0, isIdChar(start - 1) { start -= 1 }
 var end = idx
 while end < count, isIdChar(end) { end += 1 }
 let s = utf16.index(utf16.startIndex, offsetBy: start)
 let e = utf16.index(utf16.startIndex, offsetBy: end)
 return Self.string(fromUTF16: utf16[s..<e])
 }
 }

 /// 将 UTF-16 子序列还原为 String（标识符位于 BMP，单码元=单 scalar）
 private static func string(fromUTF16 sub: String.UTF16View.SubSequence) -> String {
 var view = String.UnicodeScalarView()
 for cu in sub { view.append(UnicodeScalar(cu)!) }
 return String(view)
 }

 private static func fileNameFromURI(_ uri: String) -> String {
 if uri.hasPrefix("file://") {
 return String(uri.dropFirst(7))
 }
 return uri
 }
}

// MARK: - JSONValue helpers

extension JSONValue {
 var objectValue: [String: JSONValue]? {
 if case .object(let dict) = self { return dict }
 return nil
 }
 var stringValue: String? {
 if case .string(let s) = self { return s }
 return nil
 }
 var intValue: Int? {
 if case .int(let i) = self { return i }
 return nil
 }
 var arrayValue: [JSONValue]? {
 if case .array(let arr) = self { return arr }
 return nil
 }
}

// MARK: - JSONEncoder helper

extension JSONEncoder {
 func encodeJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
 let data = try self.encode(value)
 let obj = try JSONSerialization.jsonObject(with: data)
 return convertToJSONValue(obj)
 }

 private func convertToJSONValue(_ obj: Any) -> JSONValue {
 switch obj {
 case let s as String: return .string(s)
 case let n as Int: return .int(n)
 case let n as Double: return .double(n)
 case let b as Bool: return .bool(b)
 case let a as [Any]: return .array(a.map(convertToJSONValue))
 case let d as [String: Any]: return .object(d.mapValues(convertToJSONValue))
 case is NSNull: return .null
 default: return .null
 }
 }
}

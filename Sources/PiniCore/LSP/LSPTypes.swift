import Foundation

// MARK: - Scope Extension (Phase 1: Core Enhancement)

extension Scope {
 /// 返回当前作用域所有已定义符号
 public var allSymbols: [Symbol] { Array(symbols.values) }
 
 /// 递归收集当前作用域及其所有祖先作用域的符号（去重，子 scope 覆盖父 scope）
 public func allSymbolsRecursive() -> [Symbol] {
 var seen: Set<String> = []
 var result: [Symbol] = []
 var current: Scope? = self
 while let scope = current {
 for sym in scope.symbols.values {
 if seen.insert(sym.name).inserted {
 result.append(sym)
 }
 }
 current = scope.parent
 }
 return result
 }
}

// MARK: - JSON-RPC Base Types

public enum JSONValue: Codable, Equatable {
 case string(String)
 case int(Int)
 case double(Double)
 case bool(Bool)
 case array([JSONValue])
 case object([String: JSONValue])
 case null

 public init(from decoder: Decoder) throws {
 let container = try decoder.singleValueContainer()
 if container.decodeNil() { self = .null; return }
 if let v = try? container.decode(String.self) { self = .string(v); return }
 if let v = try? container.decode(Int.self) { self = .int(v); return }
 if let v = try? container.decode(Double.self) { self = .double(v); return }
 if let v = try? container.decode(Bool.self) { self = .bool(v); return }
 if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
 if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
 throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
 }

 public func encode(to encoder: Encoder) throws {
 var container = encoder.singleValueContainer()
 switch self {
 case .string(let v): try container.encode(v)
 case .int(let v): try container.encode(v)
 case .double(let v): try container.encode(v)
 case .bool(let v): try container.encode(v)
 case .array(let v): try container.encode(v)
 case .object(let v): try container.encode(v)
 case .null: try container.encodeNil()
 }
 }
}

public struct RequestMessage: Codable {
 let jsonrpc: String
 let id: JSONValue?
 let method: String
 let params: JSONValue?
}

public struct ResponseMessage: Codable {
 let jsonrpc: String
 let id: JSONValue
 let result: JSONValue?
 let error: ResponseError?
 
 init(id: JSONValue, result: JSONValue) {
 self.jsonrpc = "2.0"
 self.id = id
 self.result = result
 self.error = nil
 }
 
 init(id: JSONValue, error: ResponseError) {
 self.jsonrpc = "2.0"
 self.id = id
 self.result = nil
 self.error = error
 }
}

public struct ResponseError: Codable {
 let code: Int
 let message: String
 let data: JSONValue?
 
 static let methodNotFound = ResponseError(code: -32601, message: "Method not found", data: nil)
 static let parseError = ResponseError(code: -32700, message: "Parse error", data: nil)
 static let invalidRequest = ResponseError(code: -32600, message: "Invalid Request", data: nil)
 static let internalError = ResponseError(code: -32603, message: "Internal error", data: nil)
}

public struct NotificationMessage: Codable {
 let jsonrpc: String
 let method: String
 let params: JSONValue?
}

// MARK: - LSP Protocol Types

public struct Position: Codable {
 let line: Int // 0-based
 let character: Int // 0-based
}

public struct LSPRange: Codable {
 let start: Position
 let end: Position
}

public struct Location: Codable {
 let uri: String
 let range: LSPRange
}

public enum DiagnosticSeverity: Int, Codable {
 case error = 1
 case warning = 2
 case information = 3
 case hint = 4
}

public struct Diagnostic: Codable {
 let range: LSPRange
 let severity: DiagnosticSeverity?
 let code: String?
 let source: String?
 let message: String
 
 init(range: LSPRange, severity: DiagnosticSeverity, source: String, message: String) {
 self.range = range
 self.severity = severity
 self.code = nil
 self.source = source
 self.message = message
 }
}

public struct TextDocumentIdentifier: Codable {
 let uri: String
}

public struct TextDocumentItem: Codable {
 let uri: String
 let languageId: String
 let version: Int
 let text: String
}

public struct VersionedTextDocumentIdentifier: Codable {
 let uri: String
 let version: Int
}

public struct TextDocumentContentChangeEvent: Codable {
 let text: String
}

// MARK: - Completion Types

public struct CompletionParams: Codable {
 let textDocument: TextDocumentIdentifier
 let position: Position
}

public enum CompletionItemKind: Int, Codable {
 case text = 1
 case method = 2
 case function = 3
 case constructor = 4
 case field = 5
 case variable = 6
 case `class` = 7
 case interface = 8
 case module = 9
 case property = 10
 case unit = 11
 case value = 12
 case `enum` = 13
 case keyword = 14
 case snippet = 15
 case color = 16
 case file = 17
 case reference = 18
 case folder = 19
 case enumMember = 20
 case constant = 21
 case `struct` = 22
 case event = 23
 case `operator` = 24
 case typeParameter = 25
}

public struct CompletionItem: Codable {
 let label: String
 let kind: CompletionItemKind?
 let detail: String?
 let documentation: String?
 
 init(label: String, kind: CompletionItemKind?, detail: String? = nil, documentation: String? = nil) {
 self.label = label
 self.kind = kind
 self.detail = detail
 self.documentation = documentation
 }
}

public struct CompletionList: Codable {
 let isIncomplete: Bool
 let items: [CompletionItem]
}

// MARK: - Definition Types

public struct DefinitionParams: Codable {
 let textDocument: TextDocumentIdentifier
 let position: Position
}

// MARK: - Capabilities

public struct TextDocumentSyncOptions: Codable {
 let openClose: Bool
 let change: Int // 1 = Full
 
 static let full = TextDocumentSyncOptions(openClose: true, change: 1)
}

public struct CompletionOptions: Codable {
 let triggerCharacters: [String]?
 
 static let `default` = CompletionOptions(triggerCharacters: [".", ":"])
}

public struct DefinitionOptions: Codable {
 let workDoneProgress: Bool?
 
 static let `default` = DefinitionOptions(workDoneProgress: false)
}

public struct ServerCapabilities: Codable {
 let textDocumentSync: TextDocumentSyncOptions
 let completionProvider: CompletionOptions?
 let definitionProvider: DefinitionOptions?
 
 static let `default` = ServerCapabilities(
 textDocumentSync: .full,
 completionProvider: .default,
 definitionProvider: .default
 )
}

// MARK: - Initialize

public struct InitializeParams: Codable {
 let processId: Int?
 let capabilities: JSONValue?
 /// LSP 规范：客户端 locale（如 "en-US" / "zh-CN"）。Pini 据此决定诊断消息语言（T11 解耦，不随 CLI --lang）。
 let locale: String?
}

public struct InitializeResult: Codable {
 let capabilities: ServerCapabilities
 let serverInfo: ServerInfo?
}

public struct ServerInfo: Codable {
 let name: String
 let version: String?
}

// MARK: - Diagnostics Publish

public struct PublishDiagnosticsParams: Codable {
 let uri: String
 let version: Int?
 let diagnostics: [Diagnostic]
}

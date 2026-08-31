import Testing
import Foundation
@testable import PiniCore

// MARK: - DiagnosticPublisher Tests

@Suite("LSP — DiagnosticPublisher 错误映射") struct DiagnosticPublisherTests {

    @Test("TypeError 单字符跨度映射")
    /// 意图：TypeError.mismatch 应映射为单字符跨度的 error 诊断，1-based 行列转 0-based，source 为 pini-type
    func testTypeErrorMapping() {
        let publisher = DiagnosticPublisher()
        let err = TypeError.mismatch(
            expected: "I32", got: "String",
            location: SourceLocation(line: 5, column: 12, fileName: "test.pini")
        )
        let params = publisher.publish(
            parserErrors: [], semanticErrors: [],
            typeErrors: [err], uri: "file:///test.pini",
        language: .en
        )
        #expect(params.uri == "file:///test.pini")
        #expect(params.diagnostics.count == 1)
        let diag = params.diagnostics[0]
        #expect(diag.range.start.line == 4)    // 1-based → 0-based
        #expect(diag.range.start.character == 11)
        #expect(diag.range.end.line == 4)
        #expect(diag.range.end.character == 12) // single-char span
        #expect(diag.severity == .error)
        #expect(diag.source == "pini-type")
        #expect(diag.message.contains("type mismatch"))
    }

    @Test("ParserError 跳过语义阶段时仍产出诊断")
    /// 意图：仅传 parserError 时仍应产出 1 条诊断（跳过语义阶段），source 为 pini-parser
    func testParserErrorSkipsSemantic() {
        let publisher = DiagnosticPublisher()
        let perr = ParserError.unexpectedEOF(
            location: SourceLocation(line: 10, column: 1, fileName: "broken.pini")
        )
        let params = publisher.publish(
            parserErrors: [perr], semanticErrors: [],
            typeErrors: [], uri: "file:///broken.pini",
        language: .en
        )
        #expect(params.diagnostics.count == 1)
        #expect(params.diagnostics[0].source == "pini-parser")
    }

    @Test("三类错误合并发布")
    /// 意图：parser/semantic/type 三类错误应合并为 3 条诊断，source 依次为 pini-parser/pini-semantic/pini-type
    func testAllThreeErrorTypes() {
        let publisher = DiagnosticPublisher()
        let params = publisher.publish(
            parserErrors: [
                ParserError.unexpectedToken(expected: ")", actual: "}",
                    location: SourceLocation(line: 1, column: 1, fileName: "all.pini"))
            ],
            semanticErrors: [
                SemanticError.undefinedVariable(
                    name: "x", location: SourceLocation(line: 3, column: 5, fileName: "all.pini"))
            ],
            typeErrors: [
                TypeError.argumentCountMismatch(
                    expected: 2, got: 1,
                    location: SourceLocation(line: 5, column: 1, fileName: "all.pini"))
            ],
            uri: "file:///all.pini",
        language: .en
        )
        #expect(params.diagnostics.count == 3)
        #expect(params.diagnostics[0].source == "pini-parser")
        #expect(params.diagnostics[1].source == "pini-semantic")
        #expect(params.diagnostics[2].source == "pini-type")
    }

    @Test("LSP 诊断语言跟随 locale（T11 解耦：InitializeParams.locale，不随 CLI --lang）")
    /// 意图：locale 前缀 zh → 中文；其余/缺省 → 英文（LSP 规范语义）。
    func testLanguageFromLocale() {
        #expect(LSPServer.language(fromLocale: nil) == .en)
        #expect(LSPServer.language(fromLocale: "en-US") == .en)
        #expect(LSPServer.language(fromLocale: "zh-CN") == .zh)
        #expect(LSPServer.language(fromLocale: "zh-Hans") == .zh)
        #expect(LSPServer.language(fromLocale: "ZH-cn") == .zh, "大小写不敏感")
    }

    @Test("DiagnosticPublisher per-call 语言（同错误 zh/en 各自渲染，不依赖全局）")
    /// 意图：显式传 language 时消息随语言变化；全局语言被 CLI 改 zh 也不影响显式 en。
    func testPublisherPerCallLanguage() {
        let publisher = DiagnosticPublisher()
        let err = TypeError.argumentCountMismatch(
            expected: 3, got: 1,
            location: SourceLocation(line: 1, column: 1, fileName: "t.pini"))
        let en = publisher.publish(parserErrors: [], semanticErrors: [], typeErrors: [err],
                                   uri: "file:///t.pini", language: .en)
        let zh = publisher.publish(parserErrors: [], semanticErrors: [], typeErrors: [err],
                                   uri: "file:///t.pini", language: .zh)
        #expect(en.diagnostics[0].message.contains("argument count mismatch"))
        #expect(zh.diagnostics[0].message.contains("参数数量不匹配"))
        #expect(!en.diagnostics[0].message.contains("参数数量不匹配"))
    }

    @Test("LSP 语义警告发布为 severity: .warning（B2）")
    /// 意图：SemanticWarning 经 DiagnosticPublisher 映射为 LSP warning 诊断（非 error）。
    func testSemanticWarningPublishedAsWarningSeverity() {
        let publisher = DiagnosticPublisher()
        let warning = SemanticWarning.unusedVariable(
            name: "unused", location: SourceLocation(line: 2, column: 5, fileName: "t.pini"))
        let params = publisher.publish(
            parserErrors: [], semanticErrors: [], typeErrors: [],
            semanticWarnings: [warning], uri: "file:///t.pini", language: .en)
        #expect(params.diagnostics.count == 1)
        #expect(params.diagnostics[0].severity == .warning)
        #expect(params.diagnostics[0].source == "pini-semantic")
        #expect(params.diagnostics[0].message.contains("unused variable 'unused'"))
    }
}

// MARK: - CompletionProvider Tests

@Suite("LSP — CompletionProvider 补全") struct CompletionProviderTests {

    @Test("空作用域仅返回关键字和内置类型")
    /// 意图：空作用域补全应返回关键字（let/if/return/step/nil）与内置类型（I32/String），isIncomplete 为 false
    func testEmptyScopeReturnsKeywordsAndTypes() {
        let provider = CompletionProvider()
        let list = provider.complete(in: nil)
        #expect(!list.items.isEmpty)
        #expect(list.isIncomplete == false)
        // 应包含关键字
        let labels = list.items.map(\.label)
        #expect(labels.contains("let"))
        #expect(labels.contains("if"))
        #expect(labels.contains("return"))
        #expect(labels.contains("step"))
        #expect(labels.contains("nil"))
        // 应包含内置类型
        #expect(labels.contains("I32"))
        #expect(labels.contains("String"))
    }

    @Test("作用域符号出现在补全列表中")
    /// 意图：作用域中定义的函数 myFunc 与变量 myVar 应出现在补全列表的 label 中
    func testScopeSymbolsInCompletion() {
        let scope = Scope(name: "global")
        scope.define(Symbol(name: "myFunc", kind: .function, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))
        scope.define(Symbol(name: "myVar", kind: .variable(isMutable: true), location: SourceLocation(line: 2, column: 1, fileName: "test.pini")))

        let provider = CompletionProvider()
        let list = provider.complete(in: scope)
        let labels = list.items.map(\.label)
        #expect(labels.contains("myFunc"))
        #expect(labels.contains("myVar"))
    }

    @Test("符号类型映射到 LSP CompletionItemKind")
    /// 意图：符号类型应映射为对应 CompletionItemKind：function→.function、struct→.struct、enum→.enum
    func testSymbolKindMapping() {
        let scope = Scope(name: "global")
        scope.define(Symbol(name: "f", kind: .function, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))
        scope.define(Symbol(name: "s", kind: .struct, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))
        scope.define(Symbol(name: "e", kind: .enum, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))

        let provider = CompletionProvider()
        let list = provider.complete(in: scope, includingKeywords: false)
        let items = list.items
        #expect(items.first(where: { $0.label == "f" })?.kind == .function)
        #expect(items.first(where: { $0.label == "s" })?.kind == .struct)
        #expect(items.first(where: { $0.label == "e" })?.kind == .enum)
    }
}

// MARK: - DefinitionProvider Tests

@Suite("LSP — DefinitionProvider 跳转定义") struct DefinitionProviderTests {

    @Test("本地作用域符号跳转")
    /// 意图：本地作用域中已定义的符号应返回其声明位置，(42,5) 按 1-based→0-based 映射为 (41,4)
    func testLocalDefinition() {
        let scope = Scope(name: "global")
        scope.define(Symbol(name: "target", kind: .function, location: SourceLocation(line: 42, column: 5, fileName: "main.pini")))

        let provider = DefinitionProvider()
        let loc = provider.findDefinition(
            name: "target", scope: scope, index: nil,
            currentURI: "file:///project/main.pini"
        )
        #expect(loc != nil)
        #expect(loc?.range.start.line == 41) // 1-based → 0-based
        #expect(loc?.range.start.character == 4)
    }

    @Test("未定义符号返回 nil")
    /// 意图：作用域中未定义的符号应返回 nil，表示无可跳转的定义
    func testUndefinedSymbolReturnsNil() {
        let scope = Scope(name: "global")
        let provider = DefinitionProvider()
        let loc = provider.findDefinition(
            name: "nonexistent", scope: scope, index: nil,
            currentURI: "file:///test.pini"
        )
        #expect(loc == nil)
    }

    @Test("跨文件符号通过 PackageSymbolIndex 查找")
    /// 意图：跨文件跳转应通过 PackageSymbolIndex 查找；空 Module 中不存在 main 时应返回 nil
    func testCrossFileDefinition() {
        let module = Module(declarations: [],
                            location: SourceLocation(line: 0, column: 0, fileName: "lib.pini"))
        let pkg = Package.singleFile(name: "lib", fileName: "lib.pini", module: module)
        // PackageSymbolIndex 从类型层构建（先到先得），这里用空 Module 验证结构可用性
        let index = PackageSymbolIndex(package: pkg)
        let provider = DefinitionProvider()
        let loc = provider.findDefinition(
            name: "main", scope: nil, index: index,
            currentURI: "file:///other.pini"
        )
        // main 不在空 Module 中 → nil
        #expect(loc == nil) // 预期行为：PackageSymbolIndex 不含 main
    }
}

// MARK: - Scope Extension Tests

@Suite("LSP — Scope 扩展") struct ScopeExtensionTests {

    @Test("allSymbols 返回当前作用域所有符号")
    /// 意图：allSymbols 应返回当前作用域全部符号（a 与 b 共 2 个）
    func testAllSymbols() {
        let scope = Scope(name: "test")
        scope.define(Symbol(name: "a", kind: .function, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))
        scope.define(Symbol(name: "b", kind: .variable(isMutable: false), location: SourceLocation(line: 2, column: 1, fileName: "test.pini")))
        let all = scope.allSymbols
        #expect(all.count == 2)
    }

    @Test("allSymbolsRecursive 包含祖先作用域符号")
    /// 意图：allSymbolsRecursive 应递归收集子作用域与祖先作用域符号，parentFunc 与 childVar 均应包含
    func testAllSymbolsRecursive() {
        let parent = Scope(name: "parent")
        parent.define(Symbol(name: "parentFunc", kind: .function, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))
        let child = Scope(name: "child", parent: parent)
        child.define(Symbol(name: "childVar", kind: .variable(isMutable: true), location: SourceLocation(line: 5, column: 1, fileName: "test.pini")))
        let all = child.allSymbolsRecursive()
        #expect(all.contains(where: { $0.name == "parentFunc" }))
        #expect(all.contains(where: { $0.name == "childVar" }))
    }

    @Test("递归符号去重（子 scope 覆盖父 scope）")
    /// 意图：父子作用域同名符号 x 应去重，仅保留子作用域的 x（父作用域被覆盖）
    func testRecursiveDedup() {
        let parent = Scope(name: "parent")
        parent.define(Symbol(name: "x", kind: .function, location: SourceLocation(line: 1, column: 1, fileName: "test.pini")))
        let child = Scope(name: "child", parent: parent)
        child.define(Symbol(name: "x", kind: .variable(isMutable: true), location: SourceLocation(line: 10, column: 1, fileName: "test.pini")))
        let all = child.allSymbolsRecursive()
        #expect(all.filter { $0.name == "x" }.count == 1) // 去重
    }
}

// MARK: - LSP Transport Tests

@Suite("LSP — Transport 帧协议") struct TransportTests {

    @Test("Content-Length 帧编码")
    /// 意图：writeMessage 应写出以 Content-Length: 头开头的帧，且消息体包含原始 JSON
    func testContentLengthFraming() throws {
        let pipe = Pipe()
        let transport = LSPTransport(input: pipe.fileHandleForReading, output: pipe.fileHandleForWriting)

        let testJSON = "{\"jsonrpc\":\"2.0\",\"result\":{}}"
        let testData = testJSON.data(using: .utf8)!
        try transport.writeMessage(testData)

        // 关闭写端，让 readDataToEndOfFile 能正常结束
        try pipe.fileHandleForWriting.close()

        // 从 pipe 读取写出的帧
        let written = pipe.fileHandleForReading.readDataToEndOfFile()
        let writtenStr = String(data: written, encoding: .utf8)!
        #expect(writtenStr.hasPrefix("Content-Length: "))
        #expect(writtenStr.contains(testJSON))
    }
}

// MARK: - DiagnosticPublisher with ErrorFormatter tests

@Suite("LSP — DiagnosticPublisher 错误消息格式化") struct DiagnosticFormatterTests {

    @Test("TypeError 消息包含错误详情")
    /// 意图：TypeError.argumentCountMismatch 的诊断消息应包含 argument 相关错误详情
    func testTypeErrorMessageFormat() {
        let publisher = DiagnosticPublisher()
        let err = TypeError.argumentCountMismatch(
            expected: 3, got: 1,
            location: SourceLocation(line: 1, column: 1, fileName: "test.pini")
        )
        let params = publisher.publish(
            parserErrors: [], semanticErrors: [],
            typeErrors: [err], uri: "file:///test.pini",
        language: .en
        )
        #expect(params.diagnostics[0].message.contains("argument count mismatch"))
    }

    @Test("SemanticError undefined 消息包含名称")
    /// 意图：SemanticError.undefinedVariable 的诊断消息应包含变量名 unknownVar
    func testSemanticErrorMessageFormat() {
        let publisher = DiagnosticPublisher()
        let err = SemanticError.undefinedVariable(
            name: "unknownVar",
            location: SourceLocation(line: 10, column: 3, fileName: "test.pini")
        )
        let params = publisher.publish(
            parserErrors: [], semanticErrors: [err],
            typeErrors: [], uri: "file:///test.pini",
        language: .en
        )
        #expect(params.diagnostics[0].message.contains("unknownVar"))
    }
}

// MARK: - LSP Server Integration Tests (dispatch loop)

@Suite("LSP — Server 派发循环集成") struct LSPServerTests {

    /// 构造一条 LSP 通知帧（Content-Length 封装）
    private func frame(method: String, params: [String: Any]) throws -> Data {
        let notif: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: notif)
        let header = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        return header + data
    }

    @Test("didOpen 通知触发 publishDiagnostics（回归：通知派发死代码）")
    /// 意图：didOpen 通知应触发服务器发布 publishDiagnostics（回归：修复前通知被 dispatchRequest 吞掉）
    func testDidOpenPublishesDiagnostics() throws {
        let input = Pipe()
        let output = Pipe()
        let transport = LSPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let server = LSPServer(transport: transport)

        let didOpen = try frame(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri": "file:///sample.pini",
                "languageId": "pini",
                "version": 1,
                "text": "let x = 1\n"
            ]
        ])

        // 后台收集服务器输出，避免主线程阻塞在 readDataToEndOfFile
        let readGroup = DispatchGroup()
        readGroup.enter()
        var collected = Data()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break } // 输出写端关闭 → EOF
                collected.append(chunk)
            }
            readGroup.leave()
        }

        // 后台启动服务器主循环
        let serverGroup = DispatchGroup()
        serverGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            server.start()
            serverGroup.leave()
        }

        input.fileHandleForWriting.write(didOpen)
        input.fileHandleForWriting.closeFile() // 触发 EOF，让服务器退出循环

        // 服务器应在超时内于 EOF 后退出
        let exited = serverGroup.wait(timeout: .now() + .seconds(5))
        #expect(exited == .success)

        // 关闭输出写端，解锁后台读取
        output.fileHandleForWriting.closeFile()
        _ = readGroup.wait(timeout: .now() + .seconds(2))

        let out = String(data: collected, encoding: .utf8) ?? ""
        // 关键断言：修复前 didOpen 被 dispatchRequest 吞掉，永远收不到 publishDiagnostics
        #expect(out.contains("publishDiagnostics"))
        #expect(out.contains("sample.pini"))      // JSON 将 / 转义为 \/，故用文件名匹配
        #expect(out.contains("\"diagnostics\""))
    }
}

// MARK: - MEDIUM 修复回归：didChange 空 contentChanges 保留旧文本

@Suite("LSP — didChange 保留旧文档") struct DidChangeRetainsTextTests {

    private func runServer(frames: [Data]) throws -> String {
        let input = Pipe()
        let output = Pipe()
        let transport = LSPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let server = LSPServer(transport: transport)

        let readGroup = DispatchGroup(); readGroup.enter()
        var collected = Data()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            readGroup.leave()
        }
        let serverGroup = DispatchGroup(); serverGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { server.start(); serverGroup.leave() }

        for f in frames { input.fileHandleForWriting.write(f) }
        input.fileHandleForWriting.closeFile()

        _ = serverGroup.wait(timeout: .now() + .seconds(5))
        output.fileHandleForWriting.closeFile()
        _ = readGroup.wait(timeout: .now() + .seconds(2))
        return String(data: collected, encoding: .utf8) ?? ""
    }

    private func notificationFrame(method: String, params: [String: Any]) throws -> Data {
        let notif: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: notif)
        let header = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        return header + data
    }

    private func requestFrame(id: Any, method: String, params: [String: Any]) throws -> Data {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: req)
        let header = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        return header + data
    }

    @Test("didChange 空 contentChanges 时保留 didOpen 的文档（不冲掉诊断）")
    /// 意图：空 contentChanges 的 didChange 不应清空已打开文档，最后一次诊断仍应含原解析错误 invalid expression
    func testEmptyContentChangesKeepsDocument() throws {
        // 用解析错误（"let x = ("）作为可观测的诊断：修复前空 contentChanges 会把文档
        // 清空成 ""，第二次诊断变空；修复后保留原文本，第二次诊断仍含该解析错误。
        let didOpen = try notificationFrame(method: "textDocument/didOpen", params: [
            "textDocument": ["uri": "file:///sample.pini", "languageId": "pini",
                             "version": 1, "text": "let x = (\n"]
        ])
        let didChange = try notificationFrame(method: "textDocument/didChange", params: [
            "textDocument": ["uri": "file:///sample.pini", "version": 2],
            "contentChanges": []
        ])

        let out = try runServer(frames: [didOpen, didChange])
        // 取最后一次 publishDiagnostics（didChange 触发的那次）
        let segments = out.components(separatedBy: "textDocument/publishDiagnostics")
        let lastSegment = segments.last ?? ""
        #expect(lastSegment.contains("invalid expression"))
    }
}

// MARK: - MEDIUM 修复回归：UTF-16 光标偏移

@Suite("LSP — extractWordAt UTF-16 偏移") struct UTF16OffsetTests {

    @Test("UTF-16 偏移：非 BMP 字符（🌟）前导时光标位置正确")
    /// 意图：非 BMP 字符（🌟 占 2 个 UTF-16 单元）分隔时提取应正确：光标在 🌟 后取空、在 x 后取完整 x
    func testUTF16OffsetWithAstralSeparator() {
        let server = LSPServer()
        // "let" 占 3 个 UTF-16 单元，🌟 占 2 个（D83C DF04），x 占 1 个。
        // utf16 索引：l0 e1 t2 🌟3 🌟4 x5 空格6 =7 空格8 1 9 \n10
        let text = "let🌟x = 1\n"
        // character=5：光标在 🌟 之后、x 之前（between utf16[4] and [5]）
        let before = server.extractWordAt(text: text, line: 0, character: 5, before: true)
        #expect(before == "")            // 光标前是 🌟（代理项，非标识符），不应误含 x
        // character=6：光标在 x 之后
        let full = server.extractWordAt(text: text, line: 0, character: 6, before: false)
        #expect(full == "x")              // 完整标识符 x
    }

    @Test("UTF-16 偏移：中文标识符在 BMP 下正确提取")
    /// 意图：光标置于「字」后（UTF-16 偏移 5）时，应整体提取中文标识符"名字"
    func testUTF16OffsetChineseIdentifier() {
        let server = LSPServer()
        let text = "let 名字 = 1\n"
        // 光标置于「字」之后（character = 5：l,e,t,空格,名,字 → 0-based 5）
        let full = server.extractWordAt(text: text, line: 0, character: 5, before: false)
        #expect(full == "名字")
    }
}

// MARK: - MEDIUM 修复回归：多 header / Content-Length 非首行

@Suite("LSP — Transport 多 header") struct MultiHeaderTests {

    @Test("Content-Length 不在首行、且含 Content-Type 时仍可拆帧")
    /// 意图：Content-Length 头不在首行（多 header 帧）时仍应正确拆帧并还原原 JSON 消息体
    func testContentLengthNotFirstLine() throws {
        let input = Pipe()
        let output = Pipe()
        let transport = LSPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)

        let body = "{\"jsonrpc\":\"2.0\"}".data(using: .utf8)!
        let header = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
                   + "Content-Length: \(body.count)\r\n\r\n"
        input.fileHandleForWriting.write(header.data(using: .utf8)!)
        input.fileHandleForWriting.write(body)
        input.fileHandleForWriting.closeFile()

        let data = try transport.readMessage()
        #expect(data != nil)
        #expect(String(data: data!, encoding: .utf8) == "{\"jsonrpc\":\"2.0\"}")
    }
}

// MARK: - MEDIUM 修复回归：字符串型 request id

@Suite("LSP — 字符串型 request id") struct StringIdTests {

    @Test("客户端发送字符串 id 时，响应回显同一字符串 id")
    /// 意图：字符串型 request id（abc）应在响应中原样回显（修复前 id 写死 Int 会被静默丢弃）
    func testStringRequestIdEchoed() throws {
        let input = Pipe()
        let output = Pipe()
        let transport = LSPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let server = LSPServer(transport: transport)

        let readGroup = DispatchGroup(); readGroup.enter()
        var collected = Data()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            readGroup.leave()
        }
        let serverGroup = DispatchGroup(); serverGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { server.start(); serverGroup.leave() }

        let req: [String: Any] = ["jsonrpc": "2.0", "id": "abc", "method": "shutdown", "params": [:]]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        let reqFrame = "Content-Length: \(reqData.count)\r\n\r\n".data(using: .utf8)! + reqData
        input.fileHandleForWriting.write(reqFrame)
        input.fileHandleForWriting.closeFile()

        _ = serverGroup.wait(timeout: .now() + .seconds(5))
        output.fileHandleForWriting.closeFile()
        _ = readGroup.wait(timeout: .now() + .seconds(2))

        let out = String(data: collected, encoding: .utf8) ?? ""
        // 响应应回显字符串 id "abc"（修复前 id 写死 Int，字符串 id 会被静默丢弃）
        #expect(out.contains("\"id\":\"abc\""))
    }
}

// MARK: - LOW 修复回归：didClose 清理 + 诊断源码片段

@Suite("LSP — didClose 与诊断源码片段") struct DidCloseAndSourceTests {

    private func runServer(frames: [Data]) throws -> String {
        let input = Pipe()
        let output = Pipe()
        let transport = LSPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let server = LSPServer(transport: transport)

        let readGroup = DispatchGroup(); readGroup.enter()
        var collected = Data()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            readGroup.leave()
        }
        let serverGroup = DispatchGroup(); serverGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { server.start(); serverGroup.leave() }

        for f in frames { input.fileHandleForWriting.write(f) }
        input.fileHandleForWriting.closeFile()

        _ = serverGroup.wait(timeout: .now() + .seconds(5))
        output.fileHandleForWriting.closeFile()
        _ = readGroup.wait(timeout: .now() + .seconds(2))
        return String(data: collected, encoding: .utf8) ?? ""
    }

    private func notificationFrame(method: String, params: [String: Any]) throws -> Data {
        let notif: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: notif)
        let header = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        return header + data
    }

    private func requestFrame(id: Any, method: String, params: [String: Any]) throws -> Data {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: req)
        let header = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        return header + data
    }

    @Test("didClose 后服务器仍正常服务（清理路径不崩溃）")
    /// 意图：didClose 清理后服务器应继续正常服务，后续 completion 仍返回 items 与 isIncomplete
    func testDidCloseKeepsServing() throws {
        let didOpen = try notificationFrame(method: "textDocument/didOpen", params: [
            "textDocument": ["uri": "file:///sample.pini", "languageId": "pini",
                             "version": 1, "text": "let x = 1\n"]
        ])
        let didClose = try notificationFrame(method: "textDocument/didClose", params: [
            "textDocument": ["uri": "file:///sample.pini"]
        ])
        let completion = try requestFrame(id: 2, method: "textDocument/completion", params: [
            "textDocument": ["uri": "file:///sample.pini"],
            "position": ["line": 0, "character": 0]
        ])
        let out = try runServer(frames: [didOpen, didClose, completion])
        // didClose 后补全仍返回合法列表（证明 didClose 分支被正确处理，未崩溃）
        #expect(out.contains("\"items\""))
        #expect(out.contains("\"isIncomplete\""))
    }

    @Test("诊断消息包含源码片段（LOW：透传 source text）")
    /// 意图：publish 传入 source 时，诊断消息应包含出错源码行 "let x = 1"（修复前 source 传空串）
    func testDiagnosticMessageIncludesSourceLine() {
        let publisher = DiagnosticPublisher()
        let err = TypeError.argumentCountMismatch(
            expected: 3, got: 1,
            location: SourceLocation(line: 1, column: 1, fileName: "test.pini")
        )
        let params = publisher.publish(
            parserErrors: [], semanticErrors: [],
            typeErrors: [err], uri: "file:///test.pini",
            source: "let x = 1\n"
        )
        // 修复前 source 传 ""，消息不含源码行；现应含出错行 "let x = 1"
        #expect(params.diagnostics[0].message.contains("let x = 1"))
    }
}


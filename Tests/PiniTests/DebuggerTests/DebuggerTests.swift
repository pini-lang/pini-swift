import Testing
import Foundation
@testable import PiniCore

// MARK: - 测试辅助

/// 记录每次停止事件的驱动（引用类型，便于断言）。
final class RecordingDebugDriver: DebugDriver {
    var commands: [DebugCommand]
    var stops: [StopEvent] = []
    init(_ commands: [DebugCommand]) { self.commands = commands }
    func nextCommand(_ event: StopEvent) -> DebugCommand {
        stops.append(event)
        return commands.isEmpty ? .quit : commands.removeFirst()
    }
}

private func dbgParse(_ source: String, _ fileName: String) -> Module {
    let tokens = try! Lexer(source: source, fileName: fileName).tokenize()
    let parser = Parser(tokens: tokens, fileName: fileName)
    return parser.parseModuleCollectingErrors().module
}

private let sampleProgram = try! loadPiniFixture("_sampleProgram", filePath: #filePath)

/// 一台可被调试的引擎（LR-4 P4-3）。
///
/// 调试用例按这个维度参数化：同一份场景在两台引擎上各跑一遍，两边都必须给出
/// 同样的停止结果 —— 「调试面在 HIR 下也能用」由此成为断言，而不是一句声明。
/// 在此之前这些用例直接驱动具体 `Interpreter`，所以全绿**只**说明 AST 侧没问题。
enum DebugEngine: String, CaseIterable, CustomTestStringConvertible {
    case ast, hir
    var testDescription: String { "engine=\(rawValue)" }
}

/// 把一份「已解析但未检查」的程序交给指定引擎跑，并接上调试器。
///
/// HIR 侧要先检查再 lower，而「谁来 lower」的答案是**调用方**（`DebugRun` 的注释
/// 里有完整理由），测试侧同样是调用方。
private func dbgDrive(_ engine: DebugEngine, module: Module, dbg: Debugger,
                      suppressOutput: Bool = false) throws {
    switch engine {
    case .ast:
        let interpreter = Interpreter()
        if suppressOutput { interpreter.outputSink = { _ in } }
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)
    case .hir:
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        try #require(errors.isEmpty, "the debugger fixtures must typecheck: \(errors)")
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let hir = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        let executor = HIRExecutor()
        if suppressOutput { executor.outputSink = { _ in } }
        executor.debugHook = { ctx in try dbg.consult(ctx) }
        try executor.run(module: hir)
    }
}

/// 同上，输入是包（多文件）：HIR 侧走整包降载。
private func dbgDrive(_ engine: DebugEngine, package: Package, dbg: Debugger,
                      suppressOutput: Bool = false) throws {
    switch engine {
    case .ast:
        let interpreter = Interpreter()
        if suppressOutput { interpreter.outputSink = { _ in } }
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(package: package)
    case .hir:
        let checker = TypeChecker()
        try checker.check(package: package)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let hir = try HIRLowerer.lower(package: package, typeInference: checker.typeInference)
        let executor = HIRExecutor()
        if suppressOutput { executor.outputSink = { _ in } }
        executor.debugHook = { ctx in try dbg.consult(ctx) }
        try executor.run(module: hir)
    }
}

/// 造一台 HIR 引擎交给 DAP 适配器（LR-4 P4-3）。
///
/// lower 放在 `start` 里而不是这里，是为了让降载期错误与运行期错误走同一条上报
/// 通道 —— 适配器对两者一视同仁，都是会话内的失败。
private func dbgMakeRunHIR(module: Module?) -> DebugRun {
    let executor = HIRExecutor()
    guard let module else { return DebugRun(host: executor) {} }
    let checker = TypeChecker()
    _ = checker.checkCollecting(module: module)
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    return DebugRun(host: executor) {
        let hir = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        try executor.run(module: hir)
    }
}


@Suite("P7-4 Debugger")
struct DebuggerTests {

    @Test("SourceMap 按行返回源码文本")
    /// 意图：验证 SourceMap 按文件名+行号返回源码文本，越界行与未知文件返回 nil。
    func testSourceMapLine() {
        let sm = SourceMap(source: "a\nb\nc", fileName: "f.pini")
        #expect(sm.line("f.pini", 1) == "a")
        #expect(sm.line("f.pini", 2) == "b")
        #expect(sm.line("f.pini", 3) == "c")
        #expect(sm.line("f.pini", 4) == nil)
        #expect(sm.line("other.pini", 1) == nil)
    }

    @Test("断点命中后 continue 完成运行（仅停一次）", arguments: DebugEngine.allCases)
    /// 意图：验证断点命中后 continue 完成运行，仅停一次且停在断点行 line 2。
    func testBreakpointThenContinue(engine: DebugEngine) throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]
        dbg.sourceMap = SourceMap(source: sampleProgram, fileName: "sample.pini")

        try dbgDrive(engine, module: module, dbg: dbg)

        #expect(driver.stops.contains { $0.location.line == 2 })
        #expect(driver.stops.count == 1)
    }

    @Test("stepOver 命中点后停在下一条同深度语句", arguments: DebugEngine.allCases)
    /// 意图：验证 stepOver 从断点行停到下一同深度语句（[2,3]），且 line 3 时快照可见 line 2 绑定的变量 a。
    func testStepOverStopsNextLine(engine: DebugEngine) throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.stepOver, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        try dbgDrive(engine, module: module, dbg: dbg)

        let lines = driver.stops.map { $0.location.line }
        #expect(lines == [2, 3])
        // 停在 line 3 时，line 2 的 `a` 已绑定，变量快照应可见
        let stopAt3 = driver.stops.first { $0.location.line == 3 }
        #expect(stopAt3?.variables.contains(where: { $0.name == "a" }) == true)
    }

    @Test("stepInto 逐行停下（无函数调用时等价于逐行）", arguments: DebugEngine.allCases)
    /// 意图：验证 stepInto 逐行停止（无函数调用时等价于逐行），停行序列为 [2,3,4]。
    func testStepIntoStopsEveryLine(engine: DebugEngine) throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.stepIn, .stepIn, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        try dbgDrive(engine, module: module, dbg: dbg)

        let lines = driver.stops.map { $0.location.line }
        #expect(lines == [2, 3, 4])
    }

    @Test("quit 中止程序并抛出 DebuggerError.quit", arguments: DebugEngine.allCases)
    /// 意图：验证 quit 命令中止运行并抛 DebuggerError，驱动仅停一次。
    func testQuitAborts(engine: DebugEngine) throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.quit])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        #expect(throws: DebuggerError.self) {
            try dbgDrive(engine, module: module, dbg: dbg)
        }
        #expect(driver.stops.count == 1)
    }

    @Test("无断点无单步时全程不停", arguments: DebugEngine.allCases)
    /// 意图：验证无断点且无单步时全程不停（stops 为空）。
    func testNoBreakpointNoStop(engine: DebugEngine) throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }

        try dbgDrive(engine, module: module, dbg: dbg)

        #expect(driver.stops.isEmpty)
    }

    @Test("stopAtEntry 在首条语句自动停下（一次）", arguments: DebugEngine.allCases)
    /// 意图：验证 stopAtEntry 在入口首条语句（line 2）自动停一次，continue 后跑完。
    func testStopAtEntry(engine: DebugEngine) throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.stopAtEntry = true

        try dbgDrive(engine, module: module, dbg: dbg)

        // 首条语句（line 2）自动停一次，continue 后跑完
        #expect(driver.stops.count == 1)
        #expect(driver.stops.first?.location.line == 2)
    }

    // MARK: - P7-4 P2：表达式语句断点 / 单步

    private let exprStmtProgram = try! loadPiniFixture("testStopAtEntry", filePath: #filePath)

    @Test("P2 表达式语句（print）可命中其行断点", arguments: DebugEngine.allCases)
    /// 意图：验证表达式语句（print(x) 所在 line 3）可命中其行断点。
    func testExpressionStatementBreakpoint(engine: DebugEngine) throws {
        let module = dbgParse(exprStmtProgram, "e.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "e.pini", line: 3)] // print(x)

        try dbgDrive(engine, module: module, dbg: dbg, suppressOutput: true)

        #expect(driver.stops.contains { $0.location.line == 3 })
    }

    @Test("P2 stepOver 逐条同深度语句停下（含表达式语句）", arguments: DebugEngine.allCases)
    /// 意图：验证含表达式语句时 stepOver 逐条同深度语句停下（2→3→4→5）。
    func testExpressionStatementStepOver(engine: DebugEngine) throws {
        let module = dbgParse(exprStmtProgram, "e.pini")
        // 断点 line 2，连续 3 次 stepOver 应收敛于 2→3→4→5（print 也是表达式语句）
        let driver = RecordingDebugDriver([.stepOver, .stepOver, .stepOver, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "e.pini", line: 2)]

        try dbgDrive(engine, module: module, dbg: dbg, suppressOutput: true)

        let lines = driver.stops.map { $0.location.line }
        #expect(lines == [2, 3, 4, 5])
    }

    @Test("P2 函数体内表达式语句受断点控制（跨调用）", arguments: DebugEngine.allCases)
    /// 意图：验证函数体内表达式语句受断点控制，跨调用命中 helper 内 print("hi") 所在行。
    func testExpressionStatementWithFunctionCall(engine: DebugEngine) throws {
        let src = try loadPiniFixture("testExpressionStatementWithFunctionCall", filePath: #filePath)
        let module = dbgParse(src, "call.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "call.pini", line: 2)] // helper 内 print("hi")

        try dbgDrive(engine, module: module, dbg: dbg, suppressOutput: true)

        #expect(driver.stops.contains { $0.location.line == 2 })
    }

    // MARK: - P7-4 P3：多文件 / 目录调试

    @Test("P3 跨文件断点命中（run(package:)）", arguments: DebugEngine.allCases)
    /// 意图：验证 run(package:) 下跨文件断点命中（helper.pini 的 line 2）。
    func testCrossFileBreakpoint(engine: DebugEngine) throws {
        let mainSrc = try loadPiniFixture("testCrossFileBreakpoint", filePath: #filePath)
        let helperSrc = try loadPiniFixture("testCrossFileBreakpoint_2", filePath: #filePath)
        let mainMod = dbgParse(mainSrc, "main.pini")
        let helperMod = dbgParse(helperSrc, "helper.pini")
        let pkg = Package(name: "m", fileUnits: [
            FileUnit(fileName: "main.pini", module: mainMod),
            FileUnit(fileName: "helper.pini", module: helperMod),
        ])
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "helper.pini", line: 2)]

        try dbgDrive(engine, package: pkg, dbg: dbg, suppressOutput: true)

        #expect(driver.stops.contains { $0.location.fileName == "helper.pini" && $0.location.line == 2 })
    }

    @Test("P3 多文件 SourceMap 按文件名取行")
    /// 意图：验证多文件 SourceMap 按文件名取行正确，越界行返回 nil。
    func testMultiFileSourceMap()  throws {
        let sm = SourceMap(sources: [
            "main.pini": "main|func() -> ():\n    return\n",
            "helper.pini": "helper|func() -> ():\n    let z = 5\n    return\n",
        ])
        #expect(sm.line("helper.pini", 2) == "    let z = 5")
        #expect(sm.line("main.pini", 1) == "main|func() -> ():")
        #expect(sm.line("helper.pini", 99) == nil)
    }

    @Test("P3 断点全路径运行时 location 与基名输入容差匹配")
    /// 意图：验证断点基名与运行时全路径 fileName 容差匹配命中，且 location 保留全路径。
    func testBreakpointFullPathMatchesBasename() throws {
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        // 用户输入常为基名 "helper.pini"，运行时 fileName 为全路径
        dbg.breakpoints = [Breakpoint(fileName: "helper.pini", line: 2)]
        let loc = SourceLocation(line: 2, column: 1, fileName: "/abs/path/helper.pini")
        let ctx = DebugContext(location: loc, depth: 2, callStack: ["helper", "main"], variables: [])
        _ = try dbg.consult(ctx)
        #expect(driver.stops.count == 1)
        #expect(driver.stops.first?.location.fileName == "/abs/path/helper.pini")
    }

    // MARK: - P7-4 P4：DAP 适配器

    @Test("P4 DAPDebugDriver 阻塞直至 resume 唤醒")
    /// 意图：验证 DAPDebugDriver.nextCommand 阻塞直至 resume 唤醒，resume(.stepOver) 后返回 .stepOver。
    func testDAPDebugDriverResume()  throws {
        let driver = DAPDebugDriver()
        let event = StopEvent(location: SourceLocation(line: 1, column: 1, fileName: "f.pini"),
                              depth: 1, callStack: ["main"], variables: [])
        let group = DispatchGroup()
        group.enter()
        var received: DebugCommand?
        DispatchQueue.global().async {
            received = driver.nextCommand(event)
            group.leave()
        }
        // 未 resume 前应仍处于阻塞（短暂等待后仍未返回）
        let immediate = group.wait(timeout: .now() + 0.2)
        #expect(immediate == .timedOut)
        driver.resume(.stepOver)
        let done = group.wait(timeout: .now() + 2)
        #expect(done == .success)
        #expect(received == .stepOver)
    }

    @Test("P4 DAP 端到端（内存流驱动）：initialize→launch→断点→stopped→continue→exited",
          arguments: DebugEngine.allCases)
    /// 意图：验证 DAP 端到端会话（initialize→launch→断点→stopped→continue→exited）完整跑通，三个事件均出现。
    func testDAPSessionEndToEnd(engine: DebugEngine) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dap_inproc_\(Int.random(in: 0..<1_000_000)).pini")
        let src = try loadPiniFixture("testDAPSessionEndToEnd", filePath: #filePath)
        try src.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 内存输入队列：readChunk 阻塞直至测试压入数据或关闭（避免子进程/管道竞态）。
        let inCond = NSCondition()
        var inBuffer = Data()
        var inClosed = false
        // 内存输出缓冲。
        let outCond = NSCondition()
        var outBuffer = Data()

        let server = DAPServer()
        // P4-3：把引擎交给适配器（仅 .hir 需要；.ast 走适配器自己的默认路径）。
        if engine == .hir {
            server.makeRun = { mod, _ in dbgMakeRunHIR(module: mod) }
        }
        server.readChunk = { size in
            inCond.lock()
            while inBuffer.count < size && !inClosed { inCond.wait() }
            if inBuffer.isEmpty && inClosed { inCond.unlock(); return Data() }
            let take = inBuffer.prefix(size)
            inBuffer.removeSubrange(0..<take.count)
            inCond.unlock()
            return Data(take)
        }
        server.writeChunk = { data in
            outCond.lock()
            outBuffer.append(data)
            outCond.signal()
            outCond.unlock()
        }

        let group = DispatchGroup()
        group.enter()
        let serverThread = Thread { server.run(); group.leave() }
        serverThread.start()

        func push(_ dict: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return }
            var frame = "Content-Length: \(d.count)\r\n\r\n".data(using: .utf8)!
            frame.append(d)
            inCond.lock(); inBuffer.append(frame); inCond.signal(); inCond.unlock()
        }
        push(["type": "request", "seq": 1, "command": "initialize", "arguments": [:]])
        push(["type": "request", "seq": 2, "command": "launch", "arguments": ["program": tmp.path, "stopOnEntry": false]])
        push(["type": "request", "seq": 3, "command": "setBreakpoints", "arguments": ["source": ["path": tmp.path], "lines": [3]]])
        push(["type": "request", "seq": 4, "command": "configurationDone", "arguments": [:]])
        push(["type": "request", "seq": 5, "command": "continue", "arguments": [:]])

        // 等待输出中出现 exited 事件（带超时），并累计 initialized/stopped。
        var initialized = false, stopped = false, exited = false
        let deadline = Date().addingTimeInterval(5)
        outCond.lock()
        while Date() < deadline {
            while let m = parseOneDAP(&outBuffer) {
                if let t = m["type"] as? String, t == "event", let ev = m["event"] as? String {
                    if ev == "initialized" { initialized = true }
                    else if ev == "stopped" { stopped = true }
                    else if ev == "exited" { exited = true }
                }
            }
            if exited { break }
            outCond.wait(until: deadline)
        }
        outCond.unlock()

        #expect(initialized)
        #expect(stopped)
        #expect(exited)

        // 关闭输入，令 run() 主循环退出并回收后台线程。
        inCond.lock(); inClosed = true; inCond.signal(); inCond.unlock()
        _ = group.wait(timeout: .now() + 2)
    }

    // MARK: - P1-5：调试面接缝

    @Test("调试面接缝：两台引擎同形，装配不提及具体类型，且两侧都真命中断点")
    /// 意图：验证 `DebugHookHost` 同时被 AST 与 HIR 两台引擎符合，且仅持协议面即可装配调试器；
    /// P4-3 之前 HIR 侧只是「同形可装配」（无暂停点），现在两台都具备暂停点 ⇒ 同一个断点在
    /// 两侧都真命中同一行。
    func testDebugSurfaceIsEngineAgnostic() throws {
        // 两台引擎唯一的共同点就是协议面本身 —— 装配全程不出现任何一种引擎的具体调试类型。
        let driver = RecordingDebugDriver([.continue, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        let hosts: [any DebugHookHost] = [Interpreter(), HIRExecutor()]
        for host in hosts {
            // 同一个动作装到两台引擎上：装配只认协议面，不认引擎。
            host.debugHook = { ctx in try dbg.consult(ctx) }
            #expect(host.debugHook != nil)
        }

        // 同一份程序在两台引擎上各跑一遍：断点都在 line 2 命中。
        for engine in DebugEngine.allCases {
            try dbgDrive(engine, module: dbgParse(sampleProgram, "sample.pini"), dbg: dbg)
            #expect(driver.stops.last?.location.line == 2)
        }
        #expect(driver.stops.count == 2)
    }

    @Test("两引擎停在逐项相同的行上（同一程序，同一批命令）")
    /// 意图：P4-3 的核心判据 —— 同一份源码在两台引擎下产生**逐项相同**的停止行序列。
    /// 这比「各自绿」更强：它要求位置供给落在与解释器同一批行上。HIR 的位置来自
    /// `lowerBlock`（记的是 `Statement.location`），解释器的暂停点读的也是它，
    /// 所以两侧同源 —— 这个用例把「同源」变成可观测的事实。
    func testBothEnginesStopOnTheSameLines() throws {
        let src = try loadPiniFixture("_sampleProgram", filePath: #filePath)
        var recorded: [DebugEngine: [Int]] = [:]
        for engine in DebugEngine.allCases {
            let driver = RecordingDebugDriver([.stepIn, .stepIn, .stepIn, .continue])
            let dbg = Debugger(driver: driver)
            dbg.output = { _ in }
            dbg.stopAtEntry = true
            try dbgDrive(engine, module: dbgParse(src, "sample.pini"), dbg: dbg)
            recorded[engine] = driver.stops.map { $0.location.line }
        }
        #expect(recorded[.hir]?.isEmpty == false, "the HIR engine must stop at least once")
        #expect(recorded[.ast] == recorded[.hir])
    }
}

// MARK: - DAP 测试辅助（内存流分帧解析）

/// 从可变的 Data 缓冲中解析一条 Content-Length 分帧消息并消费之；不足一条时返回 nil。
private func parseOneDAP(_ buf: inout Data) -> [String: Any]? {
    guard let r = buf.range(of: Data([13, 10, 13, 10])) ?? buf.range(of: Data([10, 10])) else {
        return nil
    }
    let headerEnd = r.upperBound
    let headerText = String(data: buf.subdata(in: 0..<headerEnd), encoding: .utf8) ?? ""
    var cl = 0
    for line in headerText.components(separatedBy: "\n") {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if l.lowercased().hasPrefix("content-length:") {
            cl = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    guard buf.count >= headerEnd + cl else { return nil }
    let body = buf.subdata(in: headerEnd..<(headerEnd + cl))
    buf.removeSubrange(0..<(headerEnd + cl))
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}

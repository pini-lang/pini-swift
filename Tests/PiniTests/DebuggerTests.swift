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

private let sampleProgram = """
main|func() -> ()
    let a = 10
    let b = 20
    let c = a + b
    return
"""

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

    @Test("断点命中后 continue 完成运行（仅停一次）")
    /// 意图：验证断点命中后 continue 完成运行，仅停一次且停在断点行 line 2。
    func testBreakpointThenContinue() throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]
        dbg.sourceMap = SourceMap(source: sampleProgram, fileName: "sample.pini")

        let interpreter = Interpreter()
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        #expect(driver.stops.contains { $0.location.line == 2 })
        #expect(driver.stops.count == 1)
    }

    @Test("stepOver 命中点后停在下一条同深度语句")
    /// 意图：验证 stepOver 从断点行停到下一同深度语句（[2,3]），且 line 3 时快照可见 line 2 绑定的变量 a。
    func testStepOverStopsNextLine() throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.stepOver, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        let interpreter = Interpreter()
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        let lines = driver.stops.map { $0.location.line }
        #expect(lines == [2, 3])
        // 停在 line 3 时，line 2 的 `a` 已绑定，变量快照应可见
        let stopAt3 = driver.stops.first { $0.location.line == 3 }
        #expect(stopAt3?.variables.contains(where: { $0.name == "a" }) == true)
    }

    @Test("stepInto 逐行停下（无函数调用时等价于逐行）")
    /// 意图：验证 stepInto 逐行停止（无函数调用时等价于逐行），停行序列为 [2,3,4]。
    func testStepIntoStopsEveryLine() throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.stepIn, .stepIn, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        let interpreter = Interpreter()
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        let lines = driver.stops.map { $0.location.line }
        #expect(lines == [2, 3, 4])
    }

    @Test("quit 中止程序并抛出 DebuggerError.quit")
    /// 意图：验证 quit 命令中止运行并抛 DebuggerError，驱动仅停一次。
    func testQuitAborts() throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.quit])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "sample.pini", line: 2)]

        let interpreter = Interpreter()
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }

        #expect(throws: DebuggerError.self) {
            try interpreter.run(module: module)
        }
        #expect(driver.stops.count == 1)
    }

    @Test("无断点无单步时全程不停")
    /// 意图：验证无断点且无单步时全程不停（stops 为空）。
    func testNoBreakpointNoStop() throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }

        let interpreter = Interpreter()
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        #expect(driver.stops.isEmpty)
    }

    @Test("stopAtEntry 在首条语句自动停下（一次）")
    /// 意图：验证 stopAtEntry 在入口首条语句（line 2）自动停一次，continue 后跑完。
    func testStopAtEntry() throws {
        let module = dbgParse(sampleProgram, "sample.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.stopAtEntry = true

        let interpreter = Interpreter()
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        // 首条语句（line 2）自动停一次，continue 后跑完
        #expect(driver.stops.count == 1)
        #expect(driver.stops.first?.location.line == 2)
    }

    // MARK: - P7-4 P2：表达式语句断点 / 单步

    private let exprStmtProgram = """
main|func() -> ()
    let x = 1
    print(x)
    let y = x + 2
    print(y)
    return
"""

    @Test("P2 表达式语句（print）可命中其行断点")
    /// 意图：验证表达式语句（print(x) 所在 line 3）可命中其行断点。
    func testExpressionStatementBreakpoint() throws {
        let module = dbgParse(exprStmtProgram, "e.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "e.pini", line: 3)] // print(x)

        let interpreter = Interpreter()
        interpreter.outputSink = { _ in } // 抑制 print 输出
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        #expect(driver.stops.contains { $0.location.line == 3 })
    }

    @Test("P2 stepOver 逐条同深度语句停下（含表达式语句）")
    /// 意图：验证含表达式语句时 stepOver 逐条同深度语句停下（2→3→4→5）。
    func testExpressionStatementStepOver() throws {
        let module = dbgParse(exprStmtProgram, "e.pini")
        // 断点 line 2，连续 3 次 stepOver 应收敛于 2→3→4→5（print 也是表达式语句）
        let driver = RecordingDebugDriver([.stepOver, .stepOver, .stepOver, .continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "e.pini", line: 2)]

        let interpreter = Interpreter()
        interpreter.outputSink = { _ in }
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        let lines = driver.stops.map { $0.location.line }
        #expect(lines == [2, 3, 4, 5])
    }

    @Test("P2 函数体内表达式语句受断点控制（跨调用）")
    /// 意图：验证函数体内表达式语句受断点控制，跨调用命中 helper 内 print("hi") 所在行。
    func testExpressionStatementWithFunctionCall() throws {
        let src = """
helper|func() -> ()
    print("hi")
    return

main|func() -> ()
    helper()
    return
"""
        let module = dbgParse(src, "call.pini")
        let driver = RecordingDebugDriver([.continue])
        let dbg = Debugger(driver: driver)
        dbg.output = { _ in }
        dbg.breakpoints = [Breakpoint(fileName: "call.pini", line: 2)] // helper 内 print("hi")

        let interpreter = Interpreter()
        interpreter.outputSink = { _ in }
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(module: module)

        #expect(driver.stops.contains { $0.location.line == 2 })
    }

    // MARK: - P7-4 P3：多文件 / 目录调试

    @Test("P3 跨文件断点命中（run(package:)）")
    /// 意图：验证 run(package:) 下跨文件断点命中（helper.pini 的 line 2）。
    func testCrossFileBreakpoint() throws {
        let mainSrc = """
main|func() -> ()
    helper()
    return
"""
        let helperSrc = """
helper|func() -> ()
    let z = 5
    return
"""
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

        let interpreter = Interpreter()
        interpreter.outputSink = { _ in }
        interpreter.debugHook = { ctx in try dbg.consult(ctx) }
        try interpreter.run(package: pkg)

        #expect(driver.stops.contains { $0.location.fileName == "helper.pini" && $0.location.line == 2 })
    }

    @Test("P3 多文件 SourceMap 按文件名取行")
    /// 意图：验证多文件 SourceMap 按文件名取行正确，越界行返回 nil。
    func testMultiFileSourceMap() {
        let sm = SourceMap(sources: [
            "main.pini": "main|func() -> ()\n    return\n",
            "helper.pini": "helper|func() -> ()\n    let z = 5\n    return\n",
        ])
        #expect(sm.line("helper.pini", 2) == "    let z = 5")
        #expect(sm.line("main.pini", 1) == "main|func() -> ()")
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
    func testDAPDebugDriverResume() {
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

    @Test("P4 DAP 端到端（内存流驱动）：initialize→launch→断点→stopped→continue→exited")
    /// 意图：验证 DAP 端到端会话（initialize→launch→断点→stopped→continue→exited）完整跑通，三个事件均出现。
    func testDAPSessionEndToEnd() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dap_inproc_\(Int.random(in: 0..<1_000_000)).pini")
        let src = """
main|func() -> ()
    let a = 1
    let b = 2
    return
"""
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

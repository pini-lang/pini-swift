import Foundation

// MARK: - DAP 调试驱动

/// DAP 调试驱动：作为 `DebugDriver` 接进 `Debugger`。`consult` 每次停下都调 `nextCommand`，
/// 本驱动用 `NSCondition` 阻塞它，直到 DAP 线程处理 continue/next/stepIn 时调 `resume(_:)` 唤醒。
/// 于是解释器线程停在「停止态」，DAP 线程持续收发协议消息，两者解耦。
public final class DAPDebugDriver: DebugDriver {
    private let condition = NSCondition()
    private var pending: DebugCommand? = nil

    public init() {}

    /// 由 DAP 线程调用：注入下一条命令并唤醒阻塞在 `nextCommand` 的解释器线程。
    public func resume(_ command: DebugCommand) {
        condition.lock()
        pending = command
        condition.signal()
        condition.unlock()
    }

    public func nextCommand(_ event: StopEvent) -> DebugCommand {
        condition.lock()
        while pending == nil {
            condition.wait()
        }
        let cmd = pending!
        pending = nil
        condition.unlock()
        return cmd
    }
}

// MARK: - DAP 调试适配器（P7-4 P4）

/// VS Code / 任意 DAP 客户端的调试适配器：stdio + `Content-Length` 分帧（与 LSP 同形），协议流与 debuggee 输出严格分离 ——
/// 引擎 output sink 把 `print` 重定向成 `output` 事件。生命周期：initialize → launch（只装配）→ setBreakpoints → configurationDone。
/// 状态分两片：`stateLock` 守可观测状态、`writeLock` 串行化出站写；两条线程是固定形状，故免隔离由这两把锁承担。
public final class DAPServer: @unchecked Sendable {

    private let driver = DAPDebugDriver()
    private var debugger: Debugger!
    private var launchRun: DebugRun?

    /// 引擎装配点：注入方交进「引擎 + 启动动作」，默认 nil 时适配器自建。之所以是可注入的闭包而不是引擎种类枚举，
    /// 是因为源码要先检查再 lower，而「谁来 lower」的答案在调用方（见 `DebugRun`），注入方本来就握着那份信息。
    /// 注入点在只剩一台引擎之后仍保留：它服务的是「调用方决定怎么 lower」，不是「选哪台引擎」。
    public var makeRun: ((Module?, Package?) -> DebugRun)?
    private var module: Module?
    private var package: Package?
    private var sources: [String: String] = [:]
    private var lastStopEvent: StopEvent?
    private var exited = false

    private let threadId = 1
    private let localsRef = 1000
    private var serverSeq = 1

    private let writeLock = NSLock()
    private let stateLock = NSLock()

    /// 可注入的传输层（便于测试用内存流驱动，避免子进程/管道在测试二进制上下文中的竞态）。
    /// 默认接 stdin/stdout；测试可替换为内存队列。
    internal var readChunk: (Int) -> Data = { FileHandle.standardInput.readData(ofLength: $0) }
    internal var writeChunk: (Data) -> Void = { FileHandle.standardOutput.write($0) }

    public init() {}

    // MARK: - 入口

    /// 启动 DAP 事件循环：从 stdin 读取分帧消息，分发请求，直至 EOF 或 disconnect。
    public func run() {
        // 标准 stdio 协议适配器：忽略 SIGPIPE，避免对端（IDE/测试）关闭管道时进程被信号杀死。
        // 管道断开时写操作失败即静默返回，由 run() 主循环在下次 readMessage 返回 nil 时自然退出。
        signal(SIGPIPE, SIG_IGN)
        while let msg = readMessage() {
            guard let type = msg["type"] as? String, type == "request" else { continue }
            handleRequest(msg)
        }
    }

    // MARK: - 请求分发

    private func handleRequest(_ msg: [String: Any]) {
        let command = msg["command"] as? String ?? ""
        switch command {
        case "initialize":
            handleInitialize(msg)
        case "launch":
            handleLaunch(msg)
        case "setBreakpoints":
            handleSetBreakpoints(msg)
        case "configurationDone":
            sendResponse(to: msg, body: [:])
            startProgram()
        case "threads":
            sendResponse(to: msg, body: ["threads": [["id": threadId, "name": "main"]]])
        case "stackTrace":
            handleStackTrace(msg)
        case "scopes":
            handleScopes(msg)
        case "variables":
            handleVariables(msg)
        case "continue":
            driver.resume(.continue)
            sendResponse(to: msg, body: ["allThreadsContinued": true])
        case "next":
            driver.resume(.stepOver)
            sendResponse(to: msg, body: [:])
        case "stepIn":
            driver.resume(.stepIn)
            sendResponse(to: msg, body: [:])
        case "pause":
            // 解释器无异步暂停点；P4 阶段返回 ack（不实际暂停）。
            sendResponse(to: msg, body: [:])
        case "disconnect":
            sendResponse(to: msg, body: [:])
            exit(0)
        default:
            sendResponse(to: msg, body: [:])
        }
    }

    private func handleInitialize(_ msg: [String: Any]) {
        let capabilities: [String: Any] = [
            "supportsConfigurationDoneRequest": true,
            "supportsStepOver": true,
            "supportsStepIn": true,
            "supportsStepOut": false,
            "supportsBreakpointLocationsRequest": false,
            "supportsDelayedStackTraceLoading": false,
        ]
        sendResponse(to: msg, body: capabilities)
        sendEvent("initialized", body: [:])
    }

    private func handleLaunch(_ msg: [String: Any]) {
        let args = msg["arguments"] as? [String: Any] ?? [:]
        let program = (args["program"] as? String) ?? ""
        let stopOnEntry = (args["stopOnEntry"] as? Bool) ?? false

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: program, isDirectory: &isDir), isDir.boolValue {
            do {
                package = try FileLoader.loadDirectory(path: program)
            } catch {
                sendOutput(category: "stderr", output: "Error loading module: \(error)\n")
                sendResponse(to: msg, success: false, body: [:])
                return
            }
            for unit in package!.fileUnits {
                if let src = try? String(contentsOfFile: unit.fileName, encoding: .utf8) {
                    sources[unit.fileName] = src
                }
            }
        } else {
            guard let src = try? String(contentsOfFile: program, encoding: .utf8) else {
                sendOutput(category: "stderr", output: "Error: cannot read file: \(program)\n")
                sendResponse(to: msg, success: false, body: [:])
                return
            }
            module = parseModule(source: src, fileName: program)
            sources = [program: src]
        }

        // 引擎在这里装：适配器只拿到「协议面 + 一个开始跑的动作」，故它不认识任何一种引擎（见 `DebugRun`），
        // lowering 的归属仍在调用方。无注入时默认自建 IR 引擎并在 `start` 里完成 check 与 lower，
        // 错误与运行期失败走同一条上报通道；`makeRun` 供调用方注入引擎，双引擎验证与将来的默认切换都只动这一处。
        let launchPackage = package
        let launchModule = module
        let launch: DebugRun
        if let makeRun = makeRun {
            launch = makeRun(launchModule, launchPackage)
        } else {
            let exec = IRExecutor()
            // 启动动作把「跑哪个输入形状」也一并封进去：startProgram 不再分派。
            // check 与 lower 都留在 `start` 里，与运行期错误走同一条上报通道 ——
            // 适配器对三者一视同仁，都是会话内的失败。
            launch = DebugRun(host: exec) {
                if let pkg = launchPackage {
                    let checker = TypeChecker()
                    try checker.check(package: pkg)
                    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
                    let ir = try IRLowerer.lower(package: pkg, typeInference: checker.typeInference)
                    try exec.run(module: ir)
                } else if let mod = launchModule {
                    let checker = TypeChecker()
                    let errors = checker.checkCollecting(module: mod)
                    guard errors.isEmpty else {
                        throw ProgramRunError.typeCheck(
                            errors.map { ErrorFormatter.formatTypeError($0, source: "") }
                        )
                    }
                    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
                    let ir = try IRLowerer.lower(module: mod, typeInference: checker.typeInference)
                    try exec.run(module: ir)
                }
            }
        }
        launchRun = launch
        // debuggee 的 print 输出 → DAP output 事件，与协议流分离。
        launch.host.outputSink = { [weak self] line in
            self?.sendOutput(category: "stdout", output: line + "\n")
        }
        debugger = Debugger(driver: driver)
        debugger.stopAtEntry = stopOnEntry
        debugger.sourceMap = SourceMap(sources: sources)
        // 停止横幅重定向为 console 输出事件（不污染协议流）。
        debugger.output = { [weak self] line in
            self?.sendOutput(category: "console", output: line + "\n")
        }
        debugger.onStop = { [weak self] (event: StopEvent, reason: StopReason) in
            self?.handleStop(event: event, reason: reason)
        }
        launch.host.debugHook = { [weak self] ctx in
            try self?.debugger.consult(ctx) ?? .run
        }

        sendResponse(to: msg, body: [:])
    }

    private func handleSetBreakpoints(_ msg: [String: Any]) {
        let args = msg["arguments"] as? [String: Any] ?? [:]
        guard let source = args["source"] as? [String: Any],
            let path = source["path"] as? String
        else {
            sendResponse(to: msg, success: false, body: [:])
            return
        }
        let lines = (args["lines"] as? [Int]) ?? []
        // 清除该文件（按基名容差）既有断点，再按新行号重置。
        let base = (path as NSString).lastPathComponent
        debugger.breakpoints = debugger.breakpoints.filter {
            (($0.fileName as NSString).lastPathComponent != base)
        }
        for line in lines {
            debugger.breakpoints.insert(Breakpoint(fileName: path, line: line))
        }
        let bpBodies = lines.map { ["line": $0, "verified": true] }
        sendResponse(to: msg, body: ["breakpoints": bpBodies])
    }

    private func handleStackTrace(_ msg: [String: Any]) {
        stateLock.lock()
        let event = lastStopEvent
        stateLock.unlock()
        guard let event = event else {
            sendResponse(to: msg, body: ["stackFrames": [], "totalFrames": 0])
            return
        }
        var frames: [[String: Any]] = []
        // callStack[0] 为 main（栈底），末位为当前函数（栈顶）；反转使栈顶在前。
        for (i, name) in event.callStack.reversed().enumerated() {
            let isTop = (i == 0)
            var frame: [String: Any] = [
                "id": i,
                "name": name,
                "line": isTop ? event.location.line : 1,
                "column": isTop ? max(event.location.column, 1) : 1,
            ]
            if isTop {
                frame["source"] = ["path": event.location.fileName]
            }
            frames.append(frame)
        }
        sendResponse(to: msg, body: ["stackFrames": frames, "totalFrames": frames.count])
    }

    private func handleScopes(_ msg: [String: Any]) {
        let body: [String: Any] = [
            "scopes": [["name": "Locals", "variablesReference": localsRef, "expensive": false]]
        ]
        sendResponse(to: msg, body: body)
    }

    private func handleVariables(_ msg: [String: Any]) {
        let args = msg["arguments"] as? [String: Any] ?? [:]
        let ref = (args["variablesReference"] as? Int) ?? 0
        var vars: [[String: Any]] = []
        if ref == localsRef {
            stateLock.lock()
            let event = lastStopEvent
            stateLock.unlock()
            if let event = event {
                for (name, value) in event.variables {
                    vars.append(["name": name, "value": value, "variablesReference": 0])
                }
            }
        }
        sendResponse(to: msg, body: ["variables": vars])
    }

    // MARK: - 停止 / 输出

    private func handleStop(event: StopEvent, reason: StopReason) {
        stateLock.lock()
        lastStopEvent = event
        stateLock.unlock()
        let reasonStr: String = {
            switch reason {
            case .entry: return "entry"
            case .breakpoint: return "breakpoint"
            case .step: return "step"
            }
        }()
        sendEvent(
            "stopped",
            body: [
                "reason": reasonStr,
                "threadId": threadId,
                "allThreadsStopped": true,
            ])
    }

    private func sendOutput(category: String, output: String) {
        sendEvent("output", body: ["category": category, "output": output])
    }

    private func sendExited() {
        sendEvent("exited", body: ["exitCode": 0])
        sendEvent("terminated", body: [:])
    }

    // MARK: - 解释器线程

    private func startProgram() {
        let t = Thread { [weak self] in
            guard let self = self else { return }
            do {
                try self.launchRun?.start()
            } catch is DebuggerError {
                // 用户/驱动器请求 quit：正常结束会话。
            } catch {
                self.sendOutput(category: "stderr", output: "Runtime error: \(error)\n")
            }
            self.stateLock.lock()
            self.exited = true
            self.stateLock.unlock()
            self.sendExited()
        }
        t.start()
    }

    // MARK: - 传输层（Content-Length 分帧）

    /// 从 stdin 读取一条完整的 Content-Length 分帧消息。
    /// `FileHandle.readData(ofLength: n)` 会阻塞至读满 n 字节或 EOF，而常开管道（VS Code、测试子进程）不会立即 EOF，
    /// 用大块读取会永远等不满而挂死；故头部逐字节读（有数据即返回），body 按已知长度读（通常已在管道中）。
    private func readMessage() -> [String: Any]? {
        var buffer = Data()
        // 1) 逐字节累积，直至定位头部结束符（\r\n\r\n 或 \n\n）。
        while findHeaderEnd(buffer) == nil {
            let byte = readChunk(1)
            if byte.isEmpty {
                return nil  // EOF：管道关闭或连接断开
            }
            buffer.append(byte)
        }
        guard let headerEnd = findHeaderEnd(buffer) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var contentLength = 0
        for line in headerText.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if l.lowercased().hasPrefix("content-length:") {
                let v = l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(v) ?? 0
            }
        }

        // 2) 读取 body：需要的剩余字节已在管道中，readData 立即返回，不会挂死。
        while buffer.count < headerEnd + contentLength {
            let need = headerEnd + contentLength - buffer.count
            let chunk = readChunk(min(need, 4096))
            if chunk.isEmpty { return nil }  // EOF 且 body 不完整
            buffer.append(chunk)
        }
        let bodyData = buffer.subdata(in: headerEnd..<(headerEnd + contentLength))

        guard let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 返回头部结束符之后（即 body 起始）的字节下标；未找到返回 nil。
    private func findHeaderEnd(_ buf: Data) -> Int? {
        if let r = buf.range(of: Data([13, 10, 13, 10])) {
            return r.upperBound
        }
        if let r = buf.range(of: Data([10, 10])) {
            return r.upperBound
        }
        return nil
    }

    private func writeMessage(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        writeLock.lock()
        if let headerData = header.data(using: .utf8) {
            writeChunk(headerData)
        }
        writeChunk(data)
        writeLock.unlock()
    }

    private func sendResponse(to msg: [String: Any], success: Bool = true, body: [String: Any]) {
        let seq = (msg["seq"] as? Int) ?? 0
        let command = (msg["command"] as? String) ?? ""
        let dict: [String: Any] = [
            "type": "response",
            "request_seq": seq,
            "success": success,
            "command": command,
            "body": body,
        ]
        writeMessage(dict)
    }

    private func sendEvent(_ name: String, body: [String: Any]) {
        let dict: [String: Any] = [
            "type": "event",
            "seq": serverSeq,
            "event": name,
            "body": body,
        ]
        serverSeq += 1
        writeMessage(dict)
    }

    // MARK: - 解析助手

    /// 由源码解析出 `Module`（与 CLI `parseOrReport` 同路径：Lexer + Parser）。
    /// 调试目标预期为合法程序；解析失败按既定模式直接 fatal（与测试文件解析一致）。
    private func parseModule(source: String, fileName: String) -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        return try! parser.parseModule()
    }
}

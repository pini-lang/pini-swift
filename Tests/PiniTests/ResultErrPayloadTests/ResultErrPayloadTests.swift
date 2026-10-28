import Foundation
import PiniCore
import Testing

/// `Result` 的 **err 载荷**的判据。
///
/// 靶 = 「err 槽那一个类型擦除的字」在**四面**上都可用：构造（`err(Error(...))` /
/// `err(CancelError(...))`）· 判别（`isCancel`）· 读消息（`e.message`）· 打印（`print(e)`）。
///
/// ⚠️ 本套件的前身是一个**双未定义**的发射形态：`err(CancelError("x"))` 曾产出
/// `call %struct.CancelError* @CancelError(i8*)` —— 类型没有定义、函数也没有实现，
/// lli 在 `use of undefined type` 处回绝。故 `emitUsesRuntimeErrorShims` 那一条守的是
/// 「产物里不再出现那个名字」，而不只是「输出对不对」。
///
/// ⭐ 两通道都用**手写期望**当参照物，⛔ 不以「另一条通道的输出」为判据 —— 两条同时错
/// 会互相认证。
struct ResultErrPayloadTests {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 前端四道门：词法 → 语法 → 语义 → 类型。任一拒绝即抛出首条诊断。
    private func typeChecked(_ source: String) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        return (module, checker)
    }

    /// 完整跑一遍解释器通道，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    /// 只到降载 → 发射，拿 IR 文本（⛔ 不跑 lli）。
    private func emitIR(_ source: String) throws -> String {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        return IREmitter().emit(module: lowered)
    }

    /// 把「抛出的诊断」摊平成「判定码 + 文案」；没抛则返回 nil。
    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    /// 定位命令行产物：先看环境变量，再按仓根兜底。
    private func cliPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv) {
            return fromEnv
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        let candidates = ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
            .map { repoRoot + $0 }
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 两通道用例本次未取") {
            Issue.record("err 载荷的两通道判据本次没有跑")
        }
        return nil
    }

    private func launch(
        _ binary: String, _ arguments: [String], workingDirectory: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    /// 读一个错误绑定：判别 + 两种读消息的写法，各打一行。
    private func readBindings(_ constructor: String, _ message: String) -> String {
        #"""
        main|func() -> ():
            var a: Result<String, Error> = err(\#(constructor)("\#(message)"))
            match a:
                case ok(v): print("unreachable")
                case err(e):
                    print(isCancel(e))
                    print(e.message)
                    print(e)
            return
        """#
    }

    // MARK: - 四面（解释器通道，逐项钉）

    @Test("CancelError 的载荷：isCancel 真、消息可读、print 打消息")
    func cancelErrorCarriesItsMessage() throws {
        /// 意图：取消类错误的三面一次钉住 —— 判别为真、字段与 print 读的是**同一条**消息。
        /// 驳回性：把 `bk_cancel_error_create` 与 `bk_error_create` 接反，第一行会变 false。
        let lines = try runOutput(readBindings("CancelError", "cmsg"))
        #expect(lines == ["true", "cmsg", "cmsg"], "实际：\(lines)")
    }

    @Test("Error 的载荷：isCancel 假、消息同样可读")
    func plainErrorIsNotCancellation() throws {
        /// 意图：两种错误的**消息面完全同形**，区分只在那个标志位 —— 故本条的 false
        /// 与上一条的 true 必须成对成立，只钉一侧的实现会漏掉接反。
        let lines = try runOutput(readBindings("Error", "emsg"))
        #expect(lines == ["false", "emsg", "emsg"], "实际：\(lines)")
    }

    @Test("try-else 绑定的错误同样可打印")
    func tryElseBindingIsPrintable() throws {
        /// 意图：`try-else` 的 `errorVar` 与 `match` 的 `case err(e)` 是**同一个**读口 ——
        /// 两处若各接一套，先到的那一套会被当成语义。
        let source = #"""
        main|func() -> ():
            var a: Result<String, Error> = err(Error("trymsg"))
            try a else e:
                print(e)
                return
            print("ok-path")
            return
        """#
        let lines = try runOutput(source)
        #expect(lines == ["trymsg"], "实际：\(lines)")
    }

    // MARK: - 发射形态（这组是「不再有未定义符号」的机械证据）

    @Test("发射产物只经运行时 shim 碰 err 字，不再出现未定义的名义类型")
    func emitUsesRuntimeErrorShims() throws {
        /// 意图：钉住本批**修掉的那个形态本身** —— 旧产物里的 `@CancelError` / `@Error` /
        /// `struct.CancelError` 三者必须一个都不剩。
        /// 驳回性：只要把符号映射删掉（回到默认改名），本条立刻红，而上面的行为用例
        /// 在解释器通道上**不会**红 —— 这就是本条不可替代的理由。
        let ir = try emitIR(readBindings("CancelError", "cmsg"))
        #expect(!ir.contains("@CancelError"), "产物里仍有未定义的 @CancelError")
        #expect(!ir.contains("struct.CancelError"), "产物里仍有未定义的名义类型 struct.CancelError")
        #expect(ir.contains("declare i64 @bk_cancel_error_create(ptr)"), "缺构造符号的声明")
        #expect(ir.contains("declare i32 @bk_error_is_cancel(i64)"), "缺判别符号的声明")
        #expect(ir.contains("declare ptr @bk_error_message(i64)"), "缺消息符号的声明")
        /// ⚠️ 调用签名必须与声明**逐字同型**：`call i1` 对 `declare i32` 在 arm64 上
        /// 靠返回寄存器低位「碰巧能跑」，那不是 ABI。
        #expect(ir.contains("call i32 @bk_error_is_cancel("), "判别调用与声明的返回型不一致")
    }

    @Test("打印整个 Result 仍被拒 —— 本批只放了 err 载荷，没有放宽这一格")
    func printingResultStaysGated() throws {
        /// 意图：钉住边界。`print(e)` 可用之后，最容易被顺手读成「Result 也能打了」。
        let source = #"""
        main|func() -> ():
            var a: Result<String, Error> = ok("x")
            print(a)
            return
        """#
        let diagnosed = failure { _ = try emitIR(source) }
        #expect(diagnosed?.code == "E6-004", "期望 E6-004，实际：\(diagnosed?.code ?? "未抛出")")
        #expect(
            diagnosed?.message.contains("printing a Result value") == true,
            "文案不符：\(diagnosed?.message ?? "")")
    }

    // MARK: - 两通道

    @Test("两通道：err 载荷的四面在手写期望上一致")
    func errPayloadAgreesAcrossChannels() throws {
        /// 意图：同一份语料在两个后端上给出**同一份**手写期望。
        /// ⚠️ 参照物是手写期望，⛔ 不是「另一条通道」。
        guard let cli = cliPath() else { return }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-errpay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let source = #"""
        main|func() -> ():
            var a: Result<String, Error> = err(CancelError("cmsg"))
            match a:
                case ok(v): print("unreachable")
                case err(e):
                    print(isCancel(e))
                    print(e.message)
                    print(e)
            var b: Result<String, Error> = err(Error("emsg"))
            match b:
                case ok(v): print("unreachable")
                case err(e):
                    print(isCancel(e))
                    print(e.message)
                    print(e)
            return
        """#
        let script = sandbox.appendingPathComponent("errpay.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let expected = ["true", "cmsg", "cmsg", "false", "emsg", "emsg"]
        let a = try launch(cli, ["run", script.path], workingDirectory: sandbox)
        #expect(
            a.stdout.split(separator: "\n").map(String.init) == expected,
            "解释器通道与手写期望不符：\(a.stdout) / stderr \(a.stderr.prefix(300))")
        let b = try launch(cli, ["run-llvm", script.path], workingDirectory: sandbox)
        #expect(
            b.stdout.split(separator: "\n").map(String.init) == expected,
            "LLVM 通道与手写期望不符：\(b.stdout) / stderr \(b.stderr.prefix(300))")
        #expect(a.status == 0, "解释器通道退出码 \(a.status)")
        #expect(b.status == 0, "LLVM 通道退出码 \(b.status)")
    }
}

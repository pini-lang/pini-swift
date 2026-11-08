import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackendLLVM
import PiniHost

/// 取回的判据：`fromCString(*U8)` 读到 NUL 为止，复制成 Pini 串；C 的缓冲此后可以释放。
/// 两通道同一语义，空指针读成空串；份额由 Pini 侧持有，作用域退出时归还。
@Suite("取回的字符串")
struct StringRetrieveTests: Sendable, PiniSourceLowering {

    @Test("取回内建登记为 (*U8) -> String，别的实参类型被拒")
    func testBuiltinSignature() throws {
        let (_, checker) = try typeChecked(
            """
            main|func() -> (I32,):
                return 0
            """)
        let signature = checker.typeInference.environment?.lookupFunction(name: "fromCString")
        #expect(signature != nil, "取回内建未登记签名")
        #expect(signature?.params.count == 1, "取回只收一个实参")

        let failed = failure {
            _ = try typeChecked(
                """
                main|func() -> (I32,):
                    var s = fromCString(1)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-001", "实参类型不符须在 check 期报：\(String(describing: failed))")
        #expect(failed?.message.contains("U8") == true, "实际：\(String(describing: failed))")
    }

    @Test("取回的串在 C 缓冲释放后仍然可用")
    func testRetrievedCopySurvivesTheSourceBuffer() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "retrieve")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            [libc|foreign]
            toCString: (String,) -> (*U8,)
            free: (*U8,) -> ()

            main|func() -> (I32,):
                var p = unsafe toCString("héllo")
                var s = fromCString(p)
                unsafe free(p)
                print(s)
                print(len(s))
                return 0
            """.write(to: dir.appendingPathComponent("retr.pini"), atomically: true, encoding: .utf8)

        for channel in ["run", "run-llvm"] {
            let result = try runCLI(cli, arguments: [channel, "retr.pini"], cwd: dir)
            #expect(result.status == 0, "\(channel) 失败：\(result.stderr)")
            #expect(result.stdout == "héllo\n5\n", "\(channel) 读数：\(result.stdout)")
        }
    }

    @Test("空指针读成空串：两通道同一答案")
    func testNullPointerReadsAsEmpty() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "retrieve-null")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            [libc|foreign]
            toCString: (String,) -> (*U8,)
            free: (*U8,) -> ()
            getenv: (*U8,) -> (*U8,)

            main|func() -> (I32,):
                var name = unsafe toCString("PINI_NO_SUCH_VAR_12345")
                var p = unsafe getenv(name)
                unsafe free(name)
                var s = fromCString(p)
                print(len(s))
                print(s == "")
                return 0
            """.write(to: dir.appendingPathComponent("nil.pini"), atomically: true, encoding: .utf8)

        for channel in ["run", "run-llvm"] {
            let result = try runCLI(cli, arguments: [channel, "nil.pini"], cwd: dir)
            #expect(result.status == 0, "\(channel) 失败：\(result.stderr)")
            #expect(result.stdout == "0\ntrue\n", "\(channel) 读数：\(result.stdout)")
        }
    }

    @Test("发射层接运行时段，结果按新份额入账并在退出时归还")
    func testEmitterWiresTheRuntimeAndReleasesTheResult() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            toCString: (String,) -> (*U8,)

            main|func() -> (I32,):
                var p = unsafe toCString("abc")
                var s = fromCString(p)
                print(s)
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("declare ptr @bk_str_from_cstr(ptr)"), "缺声明：\(listing)")
        #expect(listing.contains("call i8* @bk_str_from_cstr(ptr"), "缺调用：\(listing)")
        #expect(listing.contains("call void @bk_str_release(ptr"), "取回结果未归还：\(listing)")
    }

    // MARK: - 命令行

    private func cliPathOrSkip() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    private func makeTemporaryDirectory(tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runCLI(
        _ cli: String, arguments: [String], cwd: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = PiniTestEnvironment.childEnvironment()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            let message = (error as? any DiagnosticProviding).map { "\($0.diagnosticCode)" } ?? ""
            return (message, String(describing: error))
        }
    }
}

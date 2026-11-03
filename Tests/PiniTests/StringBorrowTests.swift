import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackends
@testable import PiniBackendLLVM
@testable import PiniHost

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 借出的判据：`String` 形参在边界上就是 UTF-8、NUL 结尾的 `const char*`，只在本次调用期间有效。
/// 解释器临时编码一份、调用后释放；LLVM 直接交串值。导出面反过来，转发层复制一份再交给 Pini。
@Suite("借出的字符串")
struct StringBorrowTests: Sendable, PiniSourceLowering {

    // MARK: - 类型与发射

    @Test("String 形参归一成 cString，declare 写成 i8*")
    func testStringParameterReachesTheDeclaration() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            atoi: (String,) -> (I32,)

            main|func() -> (I32,):
                return 0
            """)
        let symbol = try #require(ir.foreigns.first?.funcs.first { $0.name == "atoi" })
        #expect(symbol.params == [.cString])
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("declare i32 @atoi(i8*)"), "实际：\(listing)")
    }

    @Test("导出形参在头文件里写成 const char*")
    func testExportHeaderSpellsConstCharPointer() throws {
        let ir = try lowered(
            """
            长度(s: String,) -> (I32,):
                return len(s)

            [greet|export]
            greet_len|c = 长度

            main|func() -> (I32,):
                return 0
            """,
            fileName: "greet.pini")
        let header = try CHeaderBackend().emit(module: ir)
        #expect(header.contains("int32_t greet_len(const char*);"), "实际：\(header)")
    }

    @Test("导出转发层先复制再调用，调用一返回就释放")
    func testExportCopiesThenReleases() throws {
        let ir = try lowered(
            """
            长度(s: String,) -> (I32,):
                return len(s)

            [greet|export]
            greet_len|c = 长度

            main|func() -> (I32,):
                return 0
            """,
            fileName: "greet.pini")
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("call i8* @bk_str_dup(i8* %a0)"), "实际：\(listing)")
        #expect(listing.contains("call void @bk_str_release(i8*"), "实际：\(listing)")
        let wrapper = try #require(listing.range(of: "define i32 @greet_len"))
        let body = listing[wrapper.lowerBound...].prefix(240)
        #expect(body.contains("bk_str_release"), "释放须发生在转发体内：\(body)")
    }

    @Test("导出返回位写 String 仍被拒")
    func testExportStringReturnIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                回声(s: String,) -> (String,):
                    return s

                [greet|export]
                greet_echo|c = 回声
                """,
                fileName: "greet.pini")
        }
        #expect(failed?.code == "E4-026", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("String") == true)
    }

    // MARK: - shim 的形状判据

    @Test("shim 只在声明形状相容时命中")
    func testShimServesOnlyMatchingShapes() {
        #expect(RuntimeOps.libcShim(named: "strlen", params: [.pointer(.u8)]) != nil)
        #expect(RuntimeOps.libcShim(named: "strlen", params: [.cString]) == nil, "借出的串与 *T 不是一个形状")
        #expect(RuntimeOps.libcShim(named: "strlen", params: []) == nil, "元数不同不算相容")
        #expect(RuntimeOps.libcShim(named: "cstr", params: [.cString]) != nil, "cstr 自己的声明就是借出")
        #expect(RuntimeOps.libcShim(named: "malloc", params: [.u64]) != nil)
        #expect(RuntimeOps.libcShim(named: "malloc", params: [.cString]) == nil)
    }

    // MARK: - 两通道端到端

    private let twoChannelSource = """
        [libc|foreign]
        atoi: (String,) -> (I32,)
        strlen: (String,) -> (U64,)
        puts: (String,) -> (I32,)

        main|func() -> (I32,):
            print(unsafe atoi("123"))
            print(unsafe strlen("héllo"))
            print(unsafe atoi("12" + "3"))
            unsafe puts("借出")
            return 0
        """

    @Test("两通道交出的字节一致：ASCII、UTF-8、临时拼接串")
    func testBothChannelsBorrowTheSameBytes() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "borrow")
        defer { try? FileManager.default.removeItem(at: dir) }
        try twoChannelSource.write(
            to: dir.appendingPathComponent("borrow.pini"), atomically: true, encoding: .utf8)

        for channel in ["run", "run-llvm"] {
            let result = try runCLI(cli, arguments: [channel, "borrow.pini"], cwd: dir)
            #expect(result.status == 0, "\(channel) 失败：\(result.stderr)")
            #expect(
                result.stdout == "123\n6\n123\n借出\n",
                "\(channel) 读数：\(result.stdout) 错误：\(result.stderr)")
        }
    }

    // MARK: - C 侧进 Pini

    @Test("C 传栈缓冲与空指针都安全：入口复制发生在读取之前")
    func testCStackBufferAndNullReachPini() throws {
        guard let cli = cliPathOrSkip(runtimeRequired: true) else { return }
        let dir = try makeTemporaryDirectory(tag: "borrow-shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            长度(s: String,) -> (U64,):
                return unsafe strlen(s)

            [libc|foreign]
            strlen: (String,) -> (U64,)

            [greet|export]
            greet_len|c = 长度
            """.write(to: dir.appendingPathComponent("greet.pini"), atomically: true, encoding: .utf8)

        let build = try runCLI(cli, arguments: ["build", "--shared", "greet.pini"], cwd: dir)
        #expect(build.status == 0, "构建失败：\(build.stderr)")
        let library = dir.appendingPathComponent("libgreet.\(librarySuffix)")
        let handle = try #require(dlopen(library.path, RTLD_NOW), "加载失败：\(dlErrorMessage())")
        defer { _ = dlclose(handle) }

        let symbol = try #require(dlsym(handle, "greet_len"), "找不到 greet_len")
        let length = unsafeBitCast(
            symbol, to: (@convention(c) (UnsafePointer<CChar>?) -> UInt64).self)
        var buffer = [CChar](repeating: 0, count: 16)
        for (index, byte) in Array("héllo".utf8).enumerated() {
            buffer[index] = CChar(bitPattern: byte)
        }
        #expect(buffer.withUnsafeBufferPointer { length($0.baseAddress) } == 6, "按字节算，不是字素")
        #expect(length(nil) == 0, "空指针按空串处理")
    }

    // MARK: - 命令行

    private var librarySuffix: String {
        #if os(macOS)
        return "dylib"
        #else
        return "so"
        #endif
    }

    private func cliPathOrSkip(runtimeRequired: Bool = false) -> String? {
        guard let cli = PiniTestEnvironment.cliPath() else {
            withKnownIssue("缺 PINI_CLI_BIN ⇒ 借出用例本次未取") {
                Issue.record("没有命令行产物可跑")
            }
            return nil
        }
        if runtimeRequired, runtimePath(near: cli) == nil {
            withKnownIssue("缺 libPiniRuntime ⇒ 共享库用例本次未取") {
                Issue.record("没有运行时产物可跑")
            }
            return nil
        }
        return cli
    }

    private func runtimePath(near cli: String) -> String? {
        let dir = (cli as NSString).deletingLastPathComponent
        return ["dylib", "so"]
            .map { (dir as NSString).appendingPathComponent("libPiniRuntime.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0) }
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
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func dlErrorMessage() -> String {
        String(cString: dlerror())
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

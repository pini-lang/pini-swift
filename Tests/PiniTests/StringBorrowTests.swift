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
        guard let cc = cCompiler() else {
            Issue.record("未找到 C 编译器 ⇒ 本判据本次未取")
            return
        }
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
        let header = try runCLI(
            cli, arguments: ["emit", "greet.pini", "greet.h", "--backend", "c"], cwd: dir)
        #expect(header.status == 0, "头文件失败：\(header.stderr)")

        /// 调用方是独立进程：进程内 `dlopen` 会让测试与库各持一份运行时全局，栈上写坏的地址
        /// 落在运行时元数据上，Linux 上必崩。
        try """
            #include <stdio.h>
            #include "greet.h"

            int main(void) {
                greet_init();
                printf("%llu\\n", (unsigned long long)greet_len("héllo"));
                printf("%llu\\n", (unsigned long long)greet_len(0));
                return 0;
            }
            """.write(to: dir.appendingPathComponent("caller.c"), atomically: true, encoding: .utf8)

        let compile = try runCLI(
            cc,
            arguments: ["caller.c", "-L.", "-lgreet", "-Wl,-rpath,.", "-o", "caller"],
            cwd: dir)
        #expect(compile.status == 0, "C 调用方编译失败：\(compile.stderr)")

        let run = try runCLI(dir.appendingPathComponent("caller").path, arguments: [], cwd: dir)
        #expect(run.status == 0, "C 调用方失败：\(run.stderr)")
        #expect(run.stdout == "6\n0\n", "按字节算而不是字素；空指针按空串处理。读数：\(run.stdout)")
    }

    // MARK: - 命令行

    /// C 编译器：CI 镜像里 clang 不在 `/usr/bin`，故由工具链解析兜底。
    private func cCompiler() -> String? {
        for candidate in ["/usr/bin/cc", "/usr/bin/clang"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return LLVMToolchain.clangPath
    }

    private var librarySuffix: String {
        #if os(macOS)
        return "dylib"
        #else
        return "so"
        #endif
    }

    private func cliPathOrSkip(runtimeRequired: Bool = false) -> String? {
        guard let cli = PiniTestEnvironment.cliPath() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_CLI_BIN")
            return nil
        }
        if runtimeRequired, runtimePath(near: cli) == nil {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "libPiniRuntime")
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
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
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

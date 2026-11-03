import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackends
@testable import PiniBackendLLVM
@testable import PiniHost
import PiniRuntime

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 字符串句柄：C 要存下串时收的那个不透明指针。
/// 三条判据 —— 形参位创建即复制、返回位原样交出、普通代码里不成立（E4-035）；
/// 通道只有 LLVM 与 `build --shared`，解释器在调用点拒绝（E5-020）。
@Suite("字符串句柄")
struct StringHandleTests: Sendable, PiniSourceLowering {

    // MARK: - 类型与发射

    @Test("声明归一成 stringHandle：形参与返回都成立")
    func testHandleReachesIR() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            bk_str_handle_new: (String,) -> (StringHandle,)
            bk_str_handle_len: (StringHandle,) -> (I64,)

            main|func() -> (I32,):
                return 0
            """)
        let block = try #require(ir.foreigns.first)
        let new = try #require(block.funcs.first { $0.name == "bk_str_handle_new" })
        #expect(new.params == [.cString])
        #expect(new.returnType == .stringHandle)
        let len = try #require(block.funcs.first { $0.name == "bk_str_handle_len" })
        #expect(len.params == [.stringHandle])
        #expect(len.returnType == .i64)
    }

    @Test("declare 把句柄写成裸 ptr")
    func testDeclarationSpellsHandleAsPointer() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            bk_str_handle_len: (StringHandle,) -> (I64,)

            main|func() -> (I32,):
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("declare i64 @bk_str_handle_len(ptr)"), "实际：\(listing)")
    }

    @Test("句柄形参位上的 Pini 串包一次 bk_str_handle_new")
    func testHandleParameterWrapsString() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            bk_str_handle_len: (StringHandle,) -> (I64,)

            main|func() -> (I32,):
                print(unsafe bk_str_handle_len("你好"))
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("call ptr @bk_str_handle_new(i8*"), "实际：\(listing)")
        #expect(listing.contains("call i64 @bk_str_handle_len(ptr"), "实际：\(listing)")
        /// 创建只发生一次：转换是调用点的事，不是每个求值点的事。
        #expect(occurrences(of: "@bk_str_handle_new", in: listing) == 2, "实际：\(listing)")
    }

    @Test("已是句柄的实参原样传，不再包一层")
    func testHandleArgumentPassesThrough() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            h_new: (String,) -> (StringHandle,)
            h_len: (StringHandle,) -> (I64,)

            main|func() -> (I32,):
                var h = unsafe h_new("x")
                print(unsafe h_len(h))
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(occurrences(of: "@h_new", in: listing) == 2, "声明一次、调用一次：\(listing)")
        #expect(!listing.contains("@bk_str_handle_new"), "句柄实参不该再包一层：\(listing)")
    }

    @Test("返回位的句柄不参与字符串计数")
    func testHandleValueIsNotRefcounted() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            h_new: (String,) -> (StringHandle,)

            main|func() -> (I32,):
                var h = unsafe h_new("x")
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(!listing.contains("@bk_str_release"), "句柄不是计数串：\(listing)")
        #expect(!listing.contains("@bk_str_retain"), "句柄落槽不保留：\(listing)")
    }

    // MARK: - 负例

    @Test("变参尾不收句柄")
    func testHandleInVariadicTailIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                h_new: () -> (StringHandle,)
                apply|varargs: (I64,) -> (I64,)

                main|func() -> (I32,):
                    var h = unsafe h_new()
                    unsafe apply(1, h)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-034", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("StringHandle") == true, "实际：\(String(describing: failed))")
    }

    @Test("句柄不能作外部数据符号")
    func testHandleAsDataSymbolIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                版本: StringHandle

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("数据符号") == true, "实际：\(String(describing: failed))")
    }

    @Test("回调签名里不收句柄")
    func testHandleInCallbackIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                qsort: (*U8, U64, U64, (StringHandle,) -> (I32,),) -> ()

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("回调") == true, "实际：\(String(describing: failed))")
    }

    @Test("普通函数签名写句柄被拒：它不是 Pini 的通用类型")
    func testHandleOutsideCFaceIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                bk_str_handle_len: (StringHandle,) -> (I64,)

                取长(h: StringHandle,) -> (I64,):
                    return 0

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-035", "实际：\(String(describing: failed))")
    }

    @Test("嵌套位上的句柄同样被拒")
    func testNestedHandleOutsideCFaceIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                取长(p: *StringHandle,) -> (I64,):
                    return 0

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-035", "实际：\(String(describing: failed))")
    }

    // MARK: - 导出面

    @Test("被 |c 引用的函数签名可以写句柄，头文件写成不透明指针")
    func testExportedSignatureTakesHandle() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            bk_str_handle_len: (StringHandle,) -> (I64,)

            取长(h: StringHandle,) -> (I64,):
                return unsafe bk_str_handle_len(h)

            [calc|export]
            calc_len|c = 取长

            main|func() -> (I32,):
                return 0
            """, fileName: "calc.pini")
        let header = try CHeaderBackend().emit(module: ir)
        #expect(header.contains("typedef struct bk_str_handle bk_str_handle;"), "实际：\(header)")
        #expect(header.contains("int64_t calc_len(bk_str_handle*)"), "实际：\(header)")
        #expect(header.contains("void bk_str_handle_release(bk_str_handle*)"), "实际：\(header)")
    }

    @Test("不碰句柄的导出面不带那段声明")
    func testHeaderWithoutHandleStaysClean() throws {
        let ir = try lowered(
            """
            加法(a: I32, b: I32,) -> (I32,):
                return a + b

            [calc|export]
            calc_add|c = 加法

            main|func() -> (I32,):
                return 0
            """, fileName: "calc.pini")
        let header = try CHeaderBackend().emit(module: ir)
        #expect(!header.contains("bk_str_handle"), "零回归：\(header)")
    }

    // MARK: - 警告

    @Test("声明处提醒一次：句柄只在 LLVM 与 build --shared 成立")
    func testHandleDeclarationWarns() throws {
        let all = try warnings(
            """
            [libc|foreign]
            bk_str_handle_len: (StringHandle,) -> (I64,)

            main|func() -> (I32,):
                return 0
            """)
        let codes = all.map(\.diagnosticCode)
        #expect(codes.contains("E7-007"), "实际：\(codes)")
    }

    // MARK: - 运行时段

    @Test("运行时段：创建即复制，长度按字节，计数成对")
    func testRuntimeHandleBytesAndLength() {
        let handle = bk_str_handle_new("héllo")
        let raw = handle.map { UnsafeRawPointer($0) }
        #expect(bk_str_handle_len(raw) == 6, "é 是两个字节")
        let bytes = bk_str_handle_bytes(raw)
        #expect(bytes?[0] == UInt8(ascii: "h"))
        #expect(bk_str_handle_retain(raw) != nil)
        bk_str_handle_release(raw)
        /// 还剩一份：再释放一次不崩，句柄随之归零。
        bk_str_handle_release(raw)
    }

    @Test("运行时段：空句柄读成空串，释放是无操作")
    func testRuntimeNilHandle() {
        #expect(bk_str_handle_len(nil) == 0)
        #expect(bk_str_handle_bytes(nil) == nil)
        #expect(bk_str_handle_retain(nil) == nil)
        bk_str_handle_release(nil)
    }

    // MARK: - 两通道端到端

    @Test("LLVM 读得到字节数，解释器在调用点拒绝")
    func testBothChannels() throws {
        guard let cli = PiniTestEnvironment.cliPath() else {
            Issue.record("未提供 PINI_CLI_BIN ⇒ 本判据本次未取")
            return
        }
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeHandleFixture(into: directory)

        let llvm = try runProcess(cli, arguments: ["run-llvm", "h.pini"], cwd: directory)
        #expect(llvm.status == 0, "run-llvm 失败：\(llvm.stderr)")
        /// "héllo" 是 6 字节，"你好" 也是 6 字节：长度按字节而不是字素。
        #expect(llvm.stdout == "6\n6\n", "读数：\(llvm.stdout) 错误：\(llvm.stderr)")

        let interpreter = try runProcess(cli, arguments: ["run", "h.pini"], cwd: directory)
        #expect(interpreter.status != 0, "解释器应当拒绝句柄调用")
        #expect(
            interpreter.stderr.contains("E5-020") || interpreter.stdout.contains("E5-020"),
            "实际：\(interpreter.stdout) \(interpreter.stderr)")
    }

    @Test("导出面端到端：C 创建句柄、Pini 读长度、C 释放")
    func testExportedHandleRoundTrip() throws {
        guard let cli = PiniTestEnvironment.cliPath() else {
            Issue.record("未提供 PINI_CLI_BIN ⇒ 本判据本次未取")
            return
        }
        guard let cc = Self.cCompiler() else {
            Issue.record("未找到 C 编译器 ⇒ 本判据本次未取")
            return
        }
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeExportFixture(into: directory)

        let build = try runProcess(cli, arguments: ["build", "--shared", "calc.pini"], cwd: directory)
        #expect(build.status == 0, "构建失败：\(build.stderr)")
        let header = try runProcess(
            cli, arguments: ["emit", "calc.pini", "calc.h", "--backend", "c"], cwd: directory)
        #expect(header.status == 0, "头文件失败：\(header.stderr)")

        let compile = try runProcess(
            cc, arguments: Self.callerArguments, cwd: directory)
        #expect(compile.status == 0, "C 调用方编译失败：\(compile.stderr)")
        let run = try runProcess(
            directory.appendingPathComponent("caller").path, arguments: [], cwd: directory)
        #expect(run.status == 0, "C 调用方失败：\(run.stderr)")
        #expect(run.stdout == "5 5\n", "读数：\(run.stdout)")
    }

    // MARK: - 辅助

    /// C 调用方要直接调运行时段的 `bk_str_handle_*`：它们不在 libcalc 的导出面里，
    /// 故让链接器把这三个符号留到运行期，由 libcalc 依赖的 libPiniRuntime 提供。
    private static var callerArguments: [String] {
        #if canImport(Darwin)
        let link = "-Wl,-undefined,dynamic_lookup"
        #else
        let link = "-Wl,--unresolved-symbols=ignore-all"
        #endif
        return ["caller.c", "-L.", "-lcalc", "-Wl,-rpath,.", link, "-o", "caller"]
    }

    private func warnings(_ source: String) throws -> [SemanticWarning] {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)
        return analyzer.warnings
    }

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            let code = (error as? any DiagnosticProviding)?.diagnosticCode ?? ""
            return (code, String(describing: error))
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func cCompiler() -> String? {
        for candidate in ["/usr/bin/cc", "/usr/bin/clang"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pini-handle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 夹具：句柄从运行时段直接建，长度按字节读。
    private static func writeHandleFixture(into directory: URL) throws {
        try """
        [libc|foreign]
        bk_str_handle_new: (String,) -> (StringHandle,)
        bk_str_handle_len: (StringHandle,) -> (I64,)
        bk_str_handle_release: (StringHandle,) -> ()

        main|func() -> (I32,):
            var h = unsafe bk_str_handle_new("héllo")
            print(unsafe bk_str_handle_len(h))
            unsafe bk_str_handle_release(h)
            print(unsafe bk_str_handle_len("你好"))
            return 0
        """.write(
            to: directory.appendingPathComponent("h.pini"), atomically: true, encoding: .utf8)
    }

    /// 夹具：导出的 Pini 函数收句柄、转手问运行时段要长度。
    private static func writeExportFixture(into directory: URL) throws {
        try """
        [hs|foreign]
        bk_str_handle_len: (StringHandle,) -> (I64,)

        取长(h: StringHandle,) -> (I64,):
            return unsafe bk_str_handle_len(h)

        [calc|export]
        calc_len|c = 取长
        """.write(
            to: directory.appendingPathComponent("calc.pini"), atomically: true, encoding: .utf8)
        try """
        #include <stdio.h>
        #include <stdint.h>
        #include "calc.h"

        int main(void) {
            bk_str_handle *h = bk_str_handle_new("hello");
            printf("%lld %lld\\n", (long long)calc_len(h), (long long)bk_str_handle_len(h));
            bk_str_handle_release(h);
            return 0;
        }
        """.write(
            to: directory.appendingPathComponent("caller.c"), atomically: true, encoding: .utf8)
    }

    private func runProcess(
        _ executable: String, arguments: [String], cwd: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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
}

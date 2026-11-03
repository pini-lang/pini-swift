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

/// 变参的判据：声明里的形参表是固定前缀，调用点可以多传；多传的实参按 C 的默认实参提升传。
/// 提升必须由发射层自己做——LLVM 看到的是 IR，不是源码。
@Suite("C 变参")
struct VariadicTests: Sendable, PiniSourceLowering {

    // MARK: - 声明与发射

    @Test("|varargs 进 IR：固定前缀照旧，标志记在函数条目上")
    func testVariadicFlagReachesIR() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            printf|varargs: (*U8,) -> (I32,)

            main|func() -> (I32,):
                return 0
            """)
        let symbol = try #require(ir.foreigns.first?.funcs.first { $0.name == "printf" })
        #expect(symbol.isVariadic)
        #expect(symbol.params == [.pointer(.u8)])
    }

    @Test("declare 写成尾部省略号")
    func testDeclarationCarriesEllipsis() throws {
        let ir = try lowered(
            """
            [va|foreign]
            va_sum|varargs: (I64,) -> (I64,)

            main|func() -> (I32,):
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("declare i64 @va_sum(i64, ...)"), "实际：\(listing)")
    }

    @Test("调用写全函数类型，变参尾按提升表改写形状")
    func testCallSpellsFunctionTypeAndPromotes() throws {
        let ir = try lowered(
            """
            [va|foreign]
            va_sum|varargs: (I64,) -> (I64,)
            c_i8: () -> (I8,)
            c_u8: () -> (U8,)

            main|func() -> (I32,):
                var a = unsafe c_i8()
                var b = unsafe c_u8()
                print(unsafe va_sum(3, a, b, true))
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        /// 函数类型不能省：按实参表推出来的 `i64 (i64, i32, i32, i32)` 不是声明的变参类型，
        /// 后端会据此按非变参摆放实参，C 侧 `va_arg` 读到的是栈上的旧值。
        #expect(listing.contains("call i64 (i64, ...) @va_sum(i64 3,"), "实际：\(listing)")
        #expect(listing.contains("sext i8"), "I8 实参要按有符号扩展：\(listing)")
        #expect(listing.contains("zext i8"), "U8 实参要按无符号扩展：\(listing)")
        #expect(listing.contains("zext i1 true to i32"), "Bool 要零扩展成 i32：\(listing)")
    }

    @Test("不带标志的函数仍按固定 arity 声明与调用")
    func testPlainFunctionKeepsFixedArity() throws {
        let ir = try lowered(
            """
            [va|foreign]
            va_fixed: (I64,) -> (I64,)

            main|func() -> (I32,):
                print(unsafe va_fixed(7))
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("declare i64 @va_fixed(i64)"), "实际：\(listing)")
        #expect(listing.contains("call i64 @va_fixed(i64 7)"), "实际：\(listing)")
    }

    @Test("String 可以作变参：借出的字节按 ptr 传")
    func testBorrowedStringInVariadicTail() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            printf|varargs: (String,) -> (I32,)

            main|func() -> (I32,):
                unsafe printf("%s\\n", "ok")
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("call i32 (i8*, ...) @printf(i8* "), "实际：\(listing)")
    }

    // MARK: - 负例

    @Test("|varargs 写在数据条目上被拒")
    func testVarargsOnDataSymbolIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                版本|varargs: I32

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-033", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("版本") == true, "实际：\(String(describing: failed))")
    }

    @Test("对象作变参被拒：没有 C 布局")
    func testObjectInVariadicTailIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                {人}
                    名字: String = "x"

                [libc|foreign]
                va_sum|varargs: (I64,) -> (I64,)

                main|func() -> (I32,):
                    var p = 人()
                    unsafe va_sum(1, p)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-034", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("position: 2") == true, "实际：\(String(describing: failed))")
    }

    @Test("少传固定前缀被拒：放宽的是上限，不是下限")
    func testTooFewArgumentsIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                va_sum|varargs: (I64, I64,) -> (I64,)

                main|func() -> (I32,):
                    unsafe va_sum(1)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-005", "实际：\(String(describing: failed))")
    }

    @Test("回调名作变参被拒：变参尾没有类型标记")
    func testCallbackInVariadicTailIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                apply|varargs: (I64,) -> (I64,)

                比较(a: *U8, b: *U8,) -> (I32,):
                    return 0

                main|func() -> (I32,):
                    unsafe apply(1, 比较)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-034", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("函数指针") == true, "实际：\(String(describing: failed))")
    }

    @Test("数据标志仍不能写在函数条目上")
    func testDataFlagOnFunctionIsStillRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                foo|readonly: (I32,) -> (I32,)

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E2-007", "实际：\(String(describing: failed))")
    }

    // MARK: - 警告

    @Test("声明变参时提醒一次：只有 LLVM 通道能调")
    func testVariadicDeclarationWarns() throws {
        let all = try warnings(
            """
            [libc|foreign]
            printf|varargs: (String,) -> (I32,)

            main|func() -> (I32,):
                return 0
            """)
        let codes = all.map(\.diagnosticCode)
        #expect(codes.contains("E7-006"), "实际：\(codes)")
    }

    // MARK: - 两通道端到端

    @Test("I8 / U8 / Bool 的提升在 C 侧读得对")
    func testPromotionsReachTheCSide() throws {
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
        try Self.writeFixture(into: directory)
        let build = try runProcess(
            cc, arguments: [
                "-shared", "-o", directory.appendingPathComponent("lib/libva.dylib").path,
                directory.appendingPathComponent("lib/va.c").path,
            ], cwd: directory)
        #expect(build.status == 0, "C 夹具编译失败：\(build.stderr)")

        let result = try runProcess(cli, arguments: ["run-llvm", "va.pini"], cwd: directory)
        #expect(result.status == 0, "run-llvm 失败：\(result.stderr)")
        /// -3（sext）+ 200（zext）+ 1（Bool）+ 41 = 239。
        #expect(result.stdout == "198\n41\n", "读数：\(result.stdout) 错误：\(result.stderr)")

        let interpreter = try runProcess(cli, arguments: ["run", "."], cwd: directory)
        #expect(interpreter.status != 0, "解释器应当拒绝变参调用")
        #expect(
            interpreter.stderr.contains("E5-019") || interpreter.stdout.contains("E5-019"),
            "实际：\(interpreter.stdout) \(interpreter.stderr)")
    }

    @Test("printf 的变参在 LLVM 通道上按格式输出")
    func testPrintfFormatsOnLLVMChannel() throws {
        guard let cli = PiniTestEnvironment.cliPath() else {
            Issue.record("未提供 PINI_CLI_BIN ⇒ 本判据本次未取")
            return
        }
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        [libc|foreign]
        printf|varargs: (String,) -> (I32,)

        main|func() -> (I32,):
            unsafe printf("n=%d s=%s f=%.1f\\n", 42, "ok", 1.5)
            return 0
        """.write(
            to: directory.appendingPathComponent("fmt.pini"), atomically: true, encoding: .utf8)

        let result = try runProcess(cli, arguments: ["run-llvm", "fmt.pini"], cwd: directory)
        #expect(result.status == 0, "run-llvm 失败：\(result.stderr)")
        #expect(result.stdout == "n=42 s=ok f=1.5\n", "读数：\(result.stdout)")
    }

    // MARK: - 辅助

    /// 只走到语义分析：E7-006 在那一层的 warnings 里。
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

    private static func cCompiler() -> String? {
        for candidate in ["/usr/bin/cc", "/usr/bin/clang"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pini-variadic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        return directory
    }

    /// 夹具：C 侧求和读 `int`（默认实参提升后的宽度），另给两个窄类型来源。
    private static func writeFixture(into directory: URL) throws {
        try """
        [package]
        name = "va"
        version = "0.1.0"

        [ffi]
        abi = "C"
        search_paths = ["lib"]
        libs = ["va"]
        """.write(
            to: directory.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        try """
        #include <stdarg.h>
        #include <stdint.h>

        int64_t va_sum(int64_t n, ...) {
            va_list ap;
            va_start(ap, n);
            int64_t total = 0;
            for (int64_t i = 0; i < n; i++) total += va_arg(ap, int);
            va_end(ap);
            return total;
        }

        int8_t c_i8(void) { return -3; }
        uint8_t c_u8(void) { return 200; }
        """.write(
            to: directory.appendingPathComponent("lib/va.c"), atomically: true, encoding: .utf8)
        try """
        [va|foreign]
        va_sum|varargs: (I64,) -> (I64,)
        c_i8: () -> (I8,)
        c_u8: () -> (U8,)

        main|func() -> (I32,):
            var a = unsafe c_i8()
            var b = unsafe c_u8()
            print(unsafe va_sum(3, a, b, true))
            print(unsafe va_sum(1, 41))
            return 0
        """.write(
            to: directory.appendingPathComponent("va.pini"), atomically: true, encoding: .utf8)
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

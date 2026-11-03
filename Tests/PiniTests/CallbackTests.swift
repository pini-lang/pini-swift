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

/// 回调的判据：C 函数指针在 IR 里是 `cFunction`（裸 `ptr`），不是 Pini 的 `{code, env}` 胖指针。
/// 传出去的是顶层自由函数的符号本身；C 传进来的裸地址在转发层包成胖指针。
@Suite("C 回调")
struct CallbackTests: Sendable, PiniSourceLowering {

    // MARK: - 类型与发射

    @Test("qsort 的函数指针形参归一成 callback")
    func testCallbackParameterIsRepresentable() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

            main|func() -> (I32,):
                return 0
            """)
        let symbol = try #require(ir.foreigns.first?.funcs.first { $0.name == "qsort" })
        #expect(
            symbol.params == [
                .pointer(.u8), .u64, .u64, .callback(params: [.pointer(.u8), .pointer(.u8)], returnType: .i32),
            ],
            "实际：\(symbol.params)")
        #expect(symbol.returnType == nil)
    }

    @Test("declare 把函数指针写成裸 ptr")
    func testDeclarationSpellsCallbackAsPointer() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

            main|func() -> (I32,):
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("declare void @qsort(ptr, i64, i64, ptr)"), "实际：\(listing)")
    }

    @Test("调用点降载成函数地址节点，类型是 cFunction")
    func testCallSiteLowersToFunctionAddress() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            malloc: (U64,) -> (*U8,)
            qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

            比较(a: *U8, b: *U8,) -> (I32,):
                return 0

            main|func() -> (I32,):
                var buf = unsafe malloc(4)
                unsafe qsort(buf, 0, 0, 比较)
                return 0
            """)
        let call = try #require(try firstCall(in: ir))
        guard case .call(_, let arguments, _) = call else {
            Issue.record("main 的第一条语句不是 call：\(call)")
            return
        }
        let address = try #require(arguments.last)
        guard case .cFunctionAddress(let name, let type) = address else {
            Issue.record("最后一个实参不是 cFunctionAddress：\(address)")
            return
        }
        #expect(name == "比较")
        let expected: IRType = .cFunction(
            params: [.pointer(element: .u8), .pointer(element: .u8)], returnType: .i32)
        #expect(type == expected, "实际：\(type.describe())")
    }

    @Test("发射出来的是函数符号本身，不包适配器")
    func testEmissionUsesTheSymbolItself() throws {
        let ir = try lowered(
            """
            [libc|foreign]
            malloc: (U64,) -> (*U8,)
            qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

            比较(a: *U8, b: *U8,) -> (I32,):
                return 0

            main|func() -> (I32,):
                var buf = unsafe malloc(4)
                unsafe qsort(buf, 0, 0, 比较)
                return 0
            """)
        let listing = try IREmitter().emit(module: ir)
        let mangled = IRName.mangle("比较")
        #expect(listing.contains("@\(mangled)"))
        #expect(listing.contains("call void @qsort("), "实际：\(listing)")
        #expect(listing.contains(", ptr @\(mangled))"), "实际：\(listing)")
        #expect(!listing.contains("__adapter_\(mangled)"), "回调不应经过闭包适配器")
    }

    @Test("导出形参在头文件里写成函数指针")
    func testExportHeaderSpellsFunctionPointer() throws {
        let ir = try lowered(
            """
            映射(f: (I32,) -> (I32,), x: I32,) -> (I32,):
                return f(x)

            [calc|export]
            calc_map|c = 映射

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let header = try CHeaderBackend().emit(module: ir)
        #expect(header.contains("int32_t calc_map(int32_t (*)(int32_t), int32_t);"), "实际：\(header)")
    }

    @Test("导出转发层把裸地址包成胖指针，经适配 thunk 回调")
    func testExportWrapsPointerIntoFatValue() throws {
        let ir = try lowered(
            """
            映射(f: (I32,) -> (I32,), x: I32,) -> (I32,):
                return f(x)

            [calc|export]
            calc_map|c = 映射

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("define i32 @calc_map(ptr %a0, i32 %a1)"), "实际：\(listing)")
        #expect(listing.contains("define i32 @__pini_cb_0(ptr %env, i32 %c0)"), "实际：\(listing)")
        #expect(listing.contains("call i32 %env(i32 %c0)"), "实际：\(listing)")
        #expect(listing.contains("insertvalue { ptr, ptr }"), "实际：\(listing)")
    }

    // MARK: - 语义拒绝

    @Test("闭包变量不能当回调：取址只取到胖指针的一半")
    func testClosureVariableIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                malloc: (U64,) -> (*U8,)
                qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

                main|func() -> (I32,):
                    var f = func(a: *U8, b: *U8,) -> (I32,):
                        return 0
                    var buf = unsafe malloc(4)
                    unsafe qsort(buf, 0, 0, f)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-031", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("变量") == true, "实际：\(String(describing: failed))")
    }

    @Test("签名不逐位相同被拒")
    func testSignatureMismatchIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                malloc: (U64,) -> (*U8,)
                qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

                比较(a: I32, b: *U8,) -> (I32,):
                    return 0

                main|func() -> (I32,):
                    var buf = unsafe malloc(4)
                    unsafe qsort(buf, 0, 0, 比较)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-031", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("逐位相同") == true, "实际：\(String(describing: failed))")
    }

    @Test("main 不能当回调")
    func testMainIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                malloc: (U64,) -> (*U8,)
                qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

                main|func() -> (I32,):
                    var buf = unsafe malloc(4)
                    unsafe qsort(buf, 0, 0, main)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-031", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("main") == true, "实际：\(String(describing: failed))")
    }

    @Test("内联闭包字面量不是标识符，被拒")
    func testClosureLiteralIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                apply: (I32, (I32,) -> (I32,),) -> (I32,)

                main|func() -> (I32,):
                    unsafe apply(1, func(x: I32,) -> (I32,): return x)
                    return 0
                """)
        }
        #expect(failed?.code == "E4-031", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("表达式") == true, "实际：\(String(describing: failed))")
    }

    @Test("回调签名里的 Bool 被拒")
    func testBooleanInCallbackIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                qsort: (*U8, U64, U64, (*U8, *U8,) -> (Bool,),) -> ()

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-032", "实际：\(String(describing: failed))")
    }

    @Test("外部函数返回函数指针被拒")
    func testFunctionPointerReturnIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                取函数: (I32,) -> ((I32,) -> (I32,),)

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("返回位") == true, "实际：\(String(describing: failed))")
    }

    @Test("导出回调签名里的 String 被拒")
    func testStringInExportCallbackIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                映射(f: (String,) -> (I32,), x: I32,) -> (I32,):
                    return x

                [export_string|export]
                calc_map|c = 映射
                """,
                fileName: "export_string.pini")
        }
        #expect(failed?.code == "E4-026", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("回调") == true, "实际：\(String(describing: failed))")
    }

    // MARK: - 端到端（需要 CLI 与 C 编译器）

    @Test("qsort 回调在两条通道上排出同一个序")
    func testQsortRunsOnBothChannels() throws {
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
                "-shared", "-o", directory.appendingPathComponent("lib/libcbtest.dylib").path,
                directory.appendingPathComponent("lib/cbtest.c").path,
            ], cwd: directory)
        #expect(build.status == 0, "C 夹具编译失败：\(build.stderr)")

        /// 两条通道取参形态不同：`run` 认模块目录并读 `pini.toml` 的搜索路径，
        /// `run-llvm` 认文件、从文件所在目录读同一份清单。这是既有入口差异，与回调无关。
        for (channel, argument) in [("run", "."), ("run-llvm", "sort.pini")] {
            let result = try runProcess(cli, arguments: [channel, argument], cwd: directory)
            #expect(result.status == 0, "\(channel) 失败：\(result.stderr)")
            #expect(result.stdout == "1\n10\n", "\(channel) 读数：\(result.stdout)")
        }
    }

    @Test("导出的 C 面接收函数指针，Pini 侧调它")
    func testExportedFunctionCallsBackIntoCSuppliedPointer() throws {
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
        try """
        映射(f: (I32,) -> (I32,), x: I32,) -> (I32,):
            return f(x)

        [calc|export]
        calc_map|c = 映射
        """.write(
            to: directory.appendingPathComponent("calc.pini"), atomically: true,
            encoding: .utf8)
        let build = try runProcess(cli, arguments: ["build", "--shared", "calc.pini"], cwd: directory)
        #expect(build.status == 0, "构建失败：\(build.stderr)")
        let header = try runProcess(cli, arguments: ["emit", "calc.pini", "calc.h", "--backend", "c"],
                                    cwd: directory)
        #expect(header.status == 0, "头文件失败：\(header.stderr)")

        try """
        #include <stdio.h>
        #include <stdint.h>
        #include "calc.h"

        static int32_t twice(int32_t v) { return v * 2; }
        static int32_t minus_one(int32_t v) { return v - 1; }

        int main(void) {
            printf("%d %d\\n", calc_map(twice, 21), calc_map(minus_one, 5));
            return 0;
        }
        """.write(
            to: directory.appendingPathComponent("caller.c"), atomically: true,
            encoding: .utf8)
        let library = directory.appendingPathComponent("libcalc.\(Self.librarySuffix)")
        let compile = try runProcess(
            cc, arguments: [
                "caller.c", "-L.", "-lcalc", "-Wl,-rpath,.", "-o", "caller",
            ], cwd: directory)
        #expect(compile.status == 0, "C 调用方编译失败：\(compile.stderr)")
        #expect(FileManager.default.fileExists(atPath: library.path))
        let run = try runProcess(directory.appendingPathComponent("caller").path, arguments: [], cwd: directory)
        #expect(run.status == 0, "C 调用方失败：\(run.stderr)")
        #expect(run.stdout == "42 4\n", "读数：\(run.stdout)")
    }

    // MARK: - 辅助

    /// `pini build --shared` 的产物后缀随平台：Darwin 发 `.dylib`，其余发 `.so`。
    private static var librarySuffix: String {
        #if canImport(Darwin)
        "dylib"
        #else
        "so"
        #endif
    }

    private func firstCall(in module: IRModule) throws -> IRExpr? {
        guard let function = module.functions.first(where: { $0.name == "main" }) else { return nil }
        return Self.findCall(named: "qsort", in: function.body)
    }

    private static func findCall(named name: String, in block: IRBlock) -> IRExpr? {
        for statement in block.statements {
            let candidate: IRExpr?
            switch statement {
            case .exprStmt(let expression): candidate = expression
            case .returnStmt(let expression, _): candidate = expression
            default: candidate = nil
            }
            if case .call(let function, _, _)? = candidate, function == name { return candidate }
        }
        return nil
    }

    private static func cCompiler() -> String? {
        for candidate in ["/usr/bin/cc", "/usr/bin/clang"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return LLVMToolchain.clangPath
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pini-callback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        return directory
    }

    /// 夹具：C 侧填缓冲、求和、取首字节；`qsort` 来自 libc。
    private static func writeFixture(into directory: URL) throws {
        try """
        [package]
        name = "cbtest"
        version = "0.1.0"

        [ffi]
        abi = "C"
        search_paths = ["lib"]
        libs = ["cbtest"]
        """.write(
            to: directory.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        try """
        #include <stdint.h>

        void cb_fill(uint8_t *p, int64_t n) {
            for (int64_t i = 0; i < n; i++) p[i] = (uint8_t)(n - i);
        }

        int64_t cb_sum(const uint8_t *p, int64_t n) {
            int64_t total = 0;
            for (int64_t i = 0; i < n; i++) total += p[i];
            return total;
        }

        int64_t cb_first(const uint8_t *p) { return p[0]; }
        """.write(
            to: directory.appendingPathComponent("lib/cbtest.c"), atomically: true, encoding: .utf8)
        try """
        [cbtest|foreign]
        malloc: (U64,) -> (*U8,)
        cb_fill: (*U8, I64,) -> ()
        cb_sum: (*U8, I64,) -> (I64,)
        cb_first: (*U8,) -> (I64,)
        qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

        比较(a: *U8, b: *U8,) -> (I32,):
            if load(a) < load(b):
                return -1
            if load(a) > load(b):
                return 1
            return 0

        main|func() -> (I32,):
            var buf = unsafe malloc(4)
            unsafe cb_fill(buf, 4)
            unsafe qsort(buf, 4, 1, 比较)
            print(unsafe cb_first(buf))
            print(unsafe cb_sum(buf, 4))
            return 0
        """.write(
            to: directory.appendingPathComponent("sort.pini"), atomically: true, encoding: .utf8)
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

    @discardableResult
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

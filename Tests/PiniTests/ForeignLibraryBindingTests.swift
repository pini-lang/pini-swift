import Foundation
import Testing
import PiniHost

/// 库绑定的判据：块名只是标签，库从 `[ffi].libs` 来。
/// 正反例成对取：同一个块名 `not_a_library` 在「清单没写库」时照样解析得到进程映像里的符号，
/// 而清单写了不存在的库时当场报 E5-016 —— 这两条合起来才是「块名不再是加载键」的可观察差别。
@Suite("外部库绑定")
struct ForeignLibraryBindingTests {
    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ arguments: [String], cwd: URL) throws -> RunResult {
        let cli = try #require(PiniTestEnvironment.cliPath(), "缺 PINI_CLI_BIN 与仓内产物")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func makeDirectory(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-ffi-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("块名只是标签：没写 [ffi].libs 也能解析进程映像里的符号")
    func blockNameIsOnlyALabel() throws {
        /// 意图：旧行为按块名 `dlopen`，这个块会去找 `libnot_a_library.dylib` 并失败。
        /// 现在块名不参与解析，`strlen` 从进程映像来 —— 这条用例红，说明块名还在当库键。
        let dir = try makeDirectory("label")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = """
            [not_a_library|foreign]
            strlen: (String,) -> (U64,)

            main|func() -> (I32,):
                print(unsafe strlen("abcd"))
                return 0
            """
        try source.write(
            to: dir.appendingPathComponent("prog.pini"), atomically: true, encoding: .utf8)
        let result = try run(["run", "prog.pini"], cwd: dir)
        #expect(result.status == 0, "退出码 \(result.status)：\(result.stderr)")
        #expect(result.stdout == "4\n", "读到 \(result.stdout.debugDescription)")
    }

    @Test("缺符号：报 E5-017，且点出符号名")
    func missingSymbolIsReported() throws {
        let dir = try makeDirectory("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = """
            [libc|foreign]
            no_such_symbol_xyz: () -> ()

            main|func() -> (I32,):
                unsafe no_such_symbol_xyz()
                return 0
            """
        try source.write(
            to: dir.appendingPathComponent("prog.pini"), atomically: true, encoding: .utf8)
        let result = try run(["run", "prog.pini"], cwd: dir)
        #expect(result.status != 0, "缺符号应当拒绝运行，实际通过：\(result.stdout)")
        #expect(result.stderr.contains("E5-017"), "实际：\(result.stderr)")
        #expect(result.stderr.contains("no_such_symbol_xyz"), "实际：\(result.stderr)")
    }

    @Test("清单声明的库被预加载：符号从 vendored 库解析")
    func librariesFromManifestArePreloaded() throws {
        /// 意图：`[ffi].libs` 是解释器唯一的加载来源。库编译自示例里的同一份 C 源，
        /// 符号在进程映像里没有，只能从这份库来。
        let dir = try makeDirectory("preload")
        defer { try? FileManager.default.removeItem(at: dir) }
        let libDir = dir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let sourceC = PiniTestEnvironment.repositoryRoot
            .appendingPathComponent("examples/ffi_module/lib/ffilib.c")
        let copiedC = libDir.appendingPathComponent("ffilib.c")
        try FileManager.default.copyItem(at: sourceC, to: copiedC)
        #if canImport(Darwin)
        let libName = "libffilib.dylib"
        let ccArguments = ["-shared", "-o", libName, "ffilib.c"]
        #else
        let libName = "libffilib.so"
        let ccArguments = ["-shared", "-fPIC", "-o", libName, "ffilib.c"]
        #endif
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ccArguments
        cc.currentDirectoryURL = libDir
        try cc.run()
        cc.waitUntilExit()
        #expect(cc.terminationStatus == 0, "编译 vendored 库失败")

        let manifest = """
            [package]
            name = "ffibind"
            version = "0.1.0"

            [ffi]
            search_paths = ["lib"]
            libs = ["ffilib"]
            """
        try manifest.write(
            to: dir.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        let program = """
            [ffilib|foreign]
            toCString: (String,) -> (*U8,)
            ffi_free: (*U8,) -> ()
            ffi_atoi: (*U8,) -> (I32,)

            main|func() -> (I32,):
                var p = unsafe toCString("123")
                print(unsafe ffi_atoi(p))
                unsafe ffi_free(p)
                return 0
            """
        try program.write(
            to: dir.appendingPathComponent("prog.pini"), atomically: true, encoding: .utf8)
        let result = try run(["run", "."], cwd: dir)
        #expect(result.status == 0, "退出码 \(result.status)：\(result.stderr)")
        #expect(result.stdout == "123\n", "读到 \(result.stdout.debugDescription)（\(libName)）")
    }

    @Test("清单里的库打不开：报 E5-016，不静默跳过")
    func missingLibraryIsReported() throws {
        let dir = try makeDirectory("nolib")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = """
            [package]
            name = "ffibind"
            version = "0.1.0"

            [ffi]
            search_paths = ["lib"]
            libs = ["no_such_library_xyz"]
            """
        try manifest.write(
            to: dir.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        let program = """
            [libc|foreign]
            strlen: (String,) -> (U64,)

            main|func() -> (I32,):
                print(unsafe strlen("x"))
                return 0
            """
        try program.write(
            to: dir.appendingPathComponent("prog.pini"), atomically: true, encoding: .utf8)
        let result = try run(["run", "."], cwd: dir)
        #expect(result.status != 0, "缺库应当拒绝运行，实际通过：\(result.stdout)")
        #expect(result.stderr.contains("E5-016"), "实际：\(result.stderr)")
        #expect(result.stderr.contains("no_such_library_xyz"), "实际：\(result.stderr)")
    }
}

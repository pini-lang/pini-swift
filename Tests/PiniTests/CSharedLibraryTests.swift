import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `build --shared` 的判据：一条命令出库，C 侧能按导出块的键找到符号并调用。
/// 只看产物能不能加载、能不能调 —— 头文件契约由导出面套件钉住，这里不重复。
@Suite("共享库产物")
struct CSharedLibraryTests {

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @Test("无 main 的模块一条命令出库，符号可加载可调用")
    func buildsLoadableLibraryWithoutMain() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-build")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [消息|given]
            n: I32 = 0

        加法(a: I32, b: I32,) -> (I32,):
            return a + b

        [calc|c]
        calc_add = 加法
        calc_state: 消息
        """.write(to: dir.appendingPathComponent("calc.pini"), atomically: true, encoding: .utf8)

        let result = try runCLI(cli, arguments: ["build", "--shared", "calc.pini"], cwd: dir)
        #expect(result.status == 0, "构建失败（rc=\(result.status)）：\(result.stderr)")
        let library = dir.appendingPathComponent("libcalc.\(librarySuffix)")
        #expect(FileManager.default.fileExists(atPath: library.path), "产物不在当前目录：\(result.stdout)")

        let handle = try #require(dlopen(library.path, RTLD_NOW), "加载失败：\(dlErrorMessage())")
        defer { _ = dlclose(handle) }
        let addSymbol = try #require(dlsym(handle, "calc_add"), "找不到 calc_add")
        let add = unsafeBitCast(addSymbol, to: (@convention(c) (Int32, Int32) -> Int32).self)
        #expect(add(2, 3) == 5)

        let initSymbol = try #require(dlsym(handle, "calc_init"), "找不到 calc_init")
        unsafeBitCast(initSymbol, to: (@convention(c) () -> Void).self)()
        let stateSymbol = try #require(dlsym(handle, "calc_state_get"), "找不到 calc_state_get")
        let getState = unsafeBitCast(
            stateSymbol, to: (@convention(c) () -> UnsafeMutablePointer<Int32>?).self)
        let field = try #require(getState(), "给定块取址为空")
        #expect(field.pointee == 0)
        field.pointee = 42
        #expect(getState()?.pointee == 42, "C 写进字段区的值，下一次取址必须读到")
    }

    @Test("模块目录与 -o 一起生效，产物落在指定路径")
    func buildsModuleDirectoryIntoExplicitPath() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-module")
        defer { try? FileManager.default.removeItem(at: dir) }
        let module = dir.appendingPathComponent("mod")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "[package]\nname = \"calcmod\"\nversion = \"0.1.0\"\n"
            .write(to: module.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        try "乘法(a: I32, b: I32,) -> (I32,):\n    return a * b\n"
            .write(to: module.appendingPathComponent("core.pini"), atomically: true, encoding: .utf8)
        try "[calcmod|c]\ncm_mul = 乘法\n"
            .write(to: module.appendingPathComponent("surface.pini"), atomically: true, encoding: .utf8)

        let output = dir.appendingPathComponent("out/libcalcmod.\(librarySuffix)")
        let result = try runCLI(
            cli, arguments: ["build", "--shared", module.path, "-o", output.path], cwd: dir)
        #expect(result.status == 0, "构建失败（rc=\(result.status)）：\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: output.path), "产物不在 -o 指定的路径")

        let handle = try #require(dlopen(output.path, RTLD_NOW), "加载失败：\(dlErrorMessage())")
        defer { _ = dlclose(handle) }
        let symbol = try #require(dlsym(handle, "cm_mul"), "找不到 cm_mul")
        let multiply = unsafeBitCast(symbol, to: (@convention(c) (Int32, Int32) -> Int32).self)
        #expect(multiply(3, 4) == 12)
    }

    @Test("没有导出块时响亮拒绝，不产出匿名库")
    func rejectsModuleWithoutExportBlock() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-reject")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "f() -> (I32,):\n    return 1\n"
            .write(to: dir.appendingPathComponent("plain.pini"), atomically: true, encoding: .utf8)

        let result = try runCLI(cli, arguments: ["build", "--shared", "plain.pini"], cwd: dir)
        #expect(result.status != 0, "没有导出块却报成功：\(result.stdout)")
        #expect(result.stderr.contains("导出块"), "诊断没说到点子上：\(result.stderr)")
        let stray = dir.appendingPathComponent("libplain.\(librarySuffix)")
        #expect(!FileManager.default.fileExists(atPath: stray.path), "拒绝之后仍留下了产物")
    }

    // MARK: - helper

    private var librarySuffix: String {
        #if os(macOS)
        return "dylib"
        #else
        return "so"
        #endif
    }

    /// 命令行与运行时缺一份就记一条 known issue：本用例要的是「真能出一份 C 能加载的库」，
    /// 缺构建产物时跳过，不让「绿了」与「根本没跑」在读数上长得一样。
    private func cliPathOrSkip() -> String? {
        guard let cli = PiniTestEnvironment.cliPath(), runtimePath(near: cli) != nil else {
            withKnownIssue("缺 PINI_CLI_BIN 或其同目录的 libPiniRuntime ⇒ 共享库用例本次未取") {
                Issue.record("没有命令行产物可跑")
            }
            return nil
        }
        return cli
    }

    /// 运行时定位与命令行同规：与 pini 可执行文件同目录。
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

    private func runCLI(_ cli: String, arguments: [String], cwd: URL) throws -> RunResult {
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
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func dlErrorMessage() -> String {
        guard let message = dlerror() else { return "未知原因" }
        return String(cString: message)
    }
}

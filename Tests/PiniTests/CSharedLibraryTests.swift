import Foundation
import PiniBackendLLVM
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
import PiniHost
#endif

/// `build --shared` 的判据：一条命令出库，C 侧能按 `|c` 条目的对外名找到符号并调用。
/// 只看产物能不能加载、能不能调 —— 头文件契约由 C 面套件钉住，这里不重复。
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
        try librarySource.write(
            to: dir.appendingPathComponent("calc.pini"), atomically: true, encoding: .utf8)

        let result = try runCLI(cli, arguments: ["build", "--shared", "calc.pini"], cwd: dir)
        #expect(result.status == 0, "构建失败（rc=\(result.status)）：\(result.stderr)")
        let library = dir.appendingPathComponent("libcalc.\(librarySuffix)")
        #expect(FileManager.default.fileExists(atPath: library.path), "产物不在当前目录：\(result.stdout)")

        let handle = try openSharedLibrary(library.path)
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

    @Test("库模块不要求 main：头文件与动态库都能从同一份声明出")
    func emitsBothArtifactsForLibraryModule() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-header")
        defer { try? FileManager.default.removeItem(at: dir) }
        try librarySource.write(
            to: dir.appendingPathComponent("calc.pini"), atomically: true, encoding: .utf8)

        let header = try runCLI(
            cli, arguments: ["emit", "calc.pini", "calc.h", "--backend", "c"], cwd: dir)
        #expect(header.status == 0, "出头文件失败（rc=\(header.status)）：\(header.stderr)")
        let text = try String(contentsOf: dir.appendingPathComponent("calc.h"), encoding: .utf8)
        #expect(text.contains("int32_t calc_add(int32_t, int32_t);"), "头文件缺函数原型")
        #expect(text.contains("calc_state_t* calc_state_get(void);"), "头文件缺量的取址函数")

        let library = try runCLI(cli, arguments: ["build", "--shared", "calc.pini"], cwd: dir)
        #expect(library.status == 0, "出库失败（rc=\(library.status)）：\(library.stderr)")
        let artifact = dir.appendingPathComponent("libcalc.\(librarySuffix)")
        #expect(FileManager.default.fileExists(atPath: artifact.path), "产物不在当前目录")
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
        try "[calcmod|export]\ncm_mul|c = 乘法\n"
            .write(to: module.appendingPathComponent("calcmod.pini"), atomically: true, encoding: .utf8)

        let output = dir.appendingPathComponent("out/libcalcmod.\(librarySuffix)")
        let result = try runCLI(
            cli, arguments: ["build", "--shared", module.path, "-o", output.path], cwd: dir)
        #expect(result.status == 0, "构建失败（rc=\(result.status)）：\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: output.path), "产物不在 -o 指定的路径")

        let handle = try openSharedLibrary(output.path)
        let symbol = try #require(dlsym(handle, "cm_mul"), "找不到 cm_mul")
        let multiply = unsafeBitCast(symbol, to: (@convention(c) (Int32, Int32) -> Int32).self)
        #expect(multiply(3, 4) == 12)
    }

    @Test("没有 |c 条目时响亮拒绝，不产出匿名库")
    func rejectsModuleWithoutCSurface() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-reject")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "f() -> (I32,):\n    return 1\n"
            .write(to: dir.appendingPathComponent("plain.pini"), atomically: true, encoding: .utf8)

        let result = try runCLI(cli, arguments: ["build", "--shared", "plain.pini"], cwd: dir)
        #expect(result.status != 0, "没有 |c 条目却报成功：\(result.stdout)")
        #expect(result.stderr.contains("|c"), "诊断没说到点子上：\(result.stderr)")
        let stray = dir.appendingPathComponent("libplain.\(librarySuffix)")
        #expect(!FileManager.default.fileExists(atPath: stray.path), "拒绝之后仍留下了产物")

        // 只有 pini 条目的模块同样不算库：放行只认 `|c`，不认 export 块本身。
        try """
        [plain|export]
        公开 = f

        f() -> (I32,):
            return 1
        """.write(to: dir.appendingPathComponent("plain.pini"), atomically: true, encoding: .utf8)
        let piniOnly = try runCLI(cli, arguments: ["build", "--shared", "plain.pini"], cwd: dir)
        #expect(piniOnly.status != 0, "只有 pini 条目却报成功：\(piniOnly.stdout)")
        #expect(piniOnly.stderr.contains("|c"), "诊断没说到点子上：\(piniOnly.stderr)")

        let emitted = try runCLI(cli, arguments: ["emit", "plain.pini"], cwd: dir)
        #expect(emitted.status != 0, "无 main 又无 |c 条目的模块不该通过 emit")
        #expect(emitted.stderr.contains("main"), "诊断应指向缺入口：\(emitted.stderr)")
    }

    @Test("同模块两个 C 面被拒，不留产物")
    func rejectsTwoCSurfacesInOneModule() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-two-faces")
        defer { try? FileManager.default.removeItem(at: dir) }
        let module = dir.appendingPathComponent("mod")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "[package]\nname = \"two\"\nversion = \"0.1.0\"\n"
            .write(to: module.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        try "fa() -> (I32,):\n    return 1\n\n[a|export]\na_f|c = fa\n"
            .write(to: module.appendingPathComponent("a.pini"), atomically: true, encoding: .utf8)
        try "fb() -> (I32,):\n    return 2\n\n[b|export]\nb_f|c = fb\n"
            .write(to: module.appendingPathComponent("b.pini"), atomically: true, encoding: .utf8)

        let output = dir.appendingPathComponent("out/libtwo.\(librarySuffix)")
        let result = try runCLI(
            cli, arguments: ["build", "--shared", module.path, "-o", output.path], cwd: dir)
        #expect(result.status != 0, "两个 C 面却报成功：\(result.stdout)")
        #expect(result.stderr.contains("都带"), "诊断没点名两个文件：\(result.stderr)")
        #expect(result.stderr.contains("a.pini"), "诊断缺第一个文件名：\(result.stderr)")
        #expect(result.stderr.contains("b.pini"), "诊断缺第二个文件名：\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: output.path), "拒绝之后仍留下了产物")
    }

    @Test("错误码经 strerror 还原成名字，未登记的码答空")
    func strerrorMapsCodesBackToNames() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "shared-strerror")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [文件错误]
            实现: 错误
            不存在

        读() -> (Result<I32, 文件错误>,):
            return err(文件错误.不存在)

        [calc|export]
        calc_read|c = 读
        """.write(to: dir.appendingPathComponent("calc.pini"), atomically: true, encoding: .utf8)

        let result = try runCLI(cli, arguments: ["build", "--shared", "calc.pini"], cwd: dir)
        #expect(result.status == 0, "构建失败（rc=\(result.status)）：\(result.stderr)")
        let library = dir.appendingPathComponent("libcalc.\(librarySuffix)")
        let handle = try openSharedLibrary(library.path)
        let readSymbol = try #require(dlsym(handle, "calc_read"), "找不到 calc_read")
        let read = unsafeBitCast(
            readSymbol,
            to: (@convention(c) (Int32, UnsafeMutablePointer<Int32>?) -> Int32).self)
        var out: Int32 = -1
        let code = read(0, &out)
        #expect(code == 0x0100, "派生码应是类型序 1 的基址，实际 \(code)")

        let strerrorSymbol = try #require(dlsym(handle, "calc_strerror"), "找不到 calc_strerror")
        let strerror = unsafeBitCast(
            strerrorSymbol, to: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self)
        #expect(strerror(code).map { String(cString: $0) } == "文件错误.不存在")
        #expect(strerror(0).map { String(cString: $0) } == "success")
        #expect(strerror(999) == nil, "未登记的码应返回 NULL")
    }

    @Test("清单的 libs 进链接：库与可执行四条命令都能调到外部 C")
    func linksDeclaredForeignLibraries() throws {
        guard let cli = cliPathOrSkip() else { return }
        guard let clang = LLVMToolchain.clangPath, LLVMToolchain.lliPath != nil else {
            _ = PiniTestEnvironment.requireToolchain(["PINI_LLVM_BIN"])
            return
        }
        let dir = try makeTemporaryDirectory(tag: "shared-ffi-link")
        defer { try? FileManager.default.removeItem(at: dir) }
        let libDir = dir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)

        // 外部库：install name 带 @rpath，产物运行期才找得到它。
        let source = dir.appendingPathComponent("demo.c")
        try "int demo_twice(int x) { return x * 2; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let libPath = libDir.appendingPathComponent("libdemo.\(librarySuffix)")
        var libArgs = ["-shared", "-o", libPath.path, source.path]
        #if os(macOS)
        libArgs.insert(contentsOf: ["-install_name", "@rpath/libdemo.\(librarySuffix)"], at: 1)
        #endif
        let buildLibrary = Process()
        buildLibrary.executableURL = URL(fileURLWithPath: clang)
        buildLibrary.arguments = libArgs
        try buildLibrary.run()
        buildLibrary.waitUntilExit()
        #expect(buildLibrary.terminationStatus == 0, "外部库构建失败")

        try """
        [package]
        name = "ffilink"
        version = "0.1.0"

        [ffi]
        search_paths = ["lib"]
        libs = ["demo"]
        """.write(to: dir.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)

        // 两个文件各声明一次同一个外部符号：同名 declare 只能发一次，否则 clang 判重定义。
        try """
        [demo|foreign]
        demo_twice: (I32,) -> (I32,)

        翻倍|unsafe(x: I32,) -> (I32,):
            return demo_twice(x)
        """.write(to: dir.appendingPathComponent("ffi.pini"), atomically: true, encoding: .utf8)
        try """
        [demo|foreign]
        demo_twice: (I32,) -> (I32,)

        双倍|unsafe(x: I32,) -> (I32,):
            return demo_twice(x)

        [calc|export]
        calc_twice|c = 双倍
        """.write(to: dir.appendingPathComponent("calc.pini"), atomically: true, encoding: .utf8)

        let result = try runCLI(cli, arguments: ["build", "--shared", dir.path], cwd: dir)
        #expect(result.status == 0, "构建失败（rc=\(result.status)）：\(result.stderr)")
        let library = dir.appendingPathComponent("libcalc.\(librarySuffix)")
        let handle = try openSharedLibrary(library.path)
        let symbol = try #require(dlsym(handle, "calc_twice"), "找不到 calc_twice")
        let twice = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Int32).self)
        #expect(twice(21) == 42, "外部库没被链上：算出来的不是 demo_twice 的结果")

        // 可执行侧同规：`compile` 走 clang 链接，`run-llvm` 走 lli 的 `--dlopen`。
        try """
        [demo|foreign]
        demo_twice: (I32,) -> (I32,)

        main|unsafe() -> (I32,):
            print(demo_twice(21))
            return 0
        """.write(to: dir.appendingPathComponent("prog.pini"), atomically: true, encoding: .utf8)
        let compiled = try runCLI(cli, arguments: ["compile", "prog.pini"], cwd: dir)
        #expect(
            compiled.stdout.contains("42"),
            "compile 没链上外部库：\(compiled.stdout)\(compiled.stderr)")
        let jitted = try runCLI(cli, arguments: ["run-llvm", "prog.pini"], cwd: dir)
        #expect(
            jitted.stdout.contains("42"),
            "run-llvm 没预载外部库：\(jitted.stdout)\(jitted.stderr)")

        try """
        [demo|foreign]
        demo_twice: (I32,) -> (I32,)

        翻倍是四十二|test() -> (Bool,):
            return 翻倍(21) == 42
        """.write(to: dir.appendingPathComponent("probe.pini"), atomically: true, encoding: .utf8)
        let tested = try runCLI(cli, arguments: ["test-llvm"], cwd: dir)
        #expect(
            tested.stdout.contains("1 通过"),
            "test-llvm 没链上外部库：\(tested.stdout)\(tested.stderr)")
    }

    // MARK: - helper

    /// 无 `main` 的库模块：`|c` 条目就位、给定块可读，正好压到「库不需要进程入口」这条口径。
    private var librarySource: String {
        """
        [消息|given]
            n: I32 = 0

        加法(a: I32, b: I32,) -> (I32,):
            return a + b

        [calc|export]
        calc_add|c = 加法
        calc_state|c = 消息
        """
    }

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
        guard let cli = PiniTestEnvironment.cliPath() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_CLI_BIN")
            return nil
        }
        guard runtimePath(near: cli) != nil else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "libPiniRuntime")
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
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// 加载共享库，句柄留到进程结束。Linux 的 `dlclose` 会真卸载图像，Swift 运行时的镜像表
    /// 却仍留着这些段的指针，之后进程里任何一次 `as?` 都会踩已释放的内存。
    private func openSharedLibrary(_ path: String) throws -> UnsafeMutableRawPointer {
        return try #require(dlopen(path, RTLD_NOW), "加载失败：\(dlErrorMessage())")
    }

    private func dlErrorMessage() -> String {
        guard let message = dlerror() else { return "未知原因" }
        return String(cString: message)
    }
}

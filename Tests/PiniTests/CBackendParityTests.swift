import Foundation
@testable import PiniCore
import Testing

/// C 后端在真实工具链下的行为判据。参照物是手写期望，不是另一条通道 —— 三条通道同时错会互相认证，
/// 故每条语料写死输出，各通道各自与它比。判据对象就是 `--emit-c` 落出来的那份源：
/// 本套件自己把它交给 cc 再跑，所以「被检查的那份 C」与「跑起来的那份」是同一个文件。
@Suite("C 后端端到端")
struct CBackendParityTests {

    struct Corpus: Sendable, CustomStringConvertible {
        let label: String
        let source: String
        /// 完整的标准输出，含末尾换行 —— 逐字节比对，不裁剪。
        let expected: String

        var description: String { label }
    }

    /// 语料覆盖骨架期开出来的类型面与控件流面：字符串 · 整数 · 分支 · 循环 ·
    /// 跨层跳出（要 `goto`）· 多函数递归 · 布尔与浮点（要运行时段）。全部以 `main` 为入口。
    private static let corpora: [Corpus] = [
        Corpus(
            label: "问候",
            source: #"""
            main|func() -> ():
                print("Hello, World!")
                print("欢迎使用Pini语言")
                return
            """#,
            expected: "Hello, World!\n欢迎使用Pini语言\n"
        ),
        Corpus(
            label: "分支与循环",
            source: #"""
            main|func() -> ():
                var i = 0
                while i < 3:
                    if i == 1:
                        print("一")
                    else:
                        print(i)
                    i = i + 1
                return
            """#,
            expected: "0\n一\n2\n"
        ),
        Corpus(
            label: "带标签跳出",
            source: #"""
            main|func() -> ():
                var k = 0
                outer|while k < 2:
                    var m = 0
                    while m < 3:
                        if m == 1:
                            break outer
                        print(m)
                        m = m + 1
                    k = k + 1
                print("done")
                return
            """#,
            expected: "0\ndone\n"
        ),
        Corpus(
            label: "递归与多函数",
            source: #"""
            阶乘|func(n: I32,) -> (I32,):
                if n <= 1:
                    return 1
                return n * 阶乘(n - 1)

            main|func() -> ():
                print(阶乘(5))
                return
            """#,
            expected: "120\n"
        ),
        Corpus(
            label: "布尔与浮点",
            source: #"""
            main|func() -> ():
                print(true)
                print(3.5)
                return
            """#,
            expected: "true\n3.5\n"
        ),
    ]

    @Test("每条语料的 C 产物跑出的字节与手写期望相同")
    func artifactMatchesHandWrittenExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let cc = cCompilerPath() else { return }
        for corpus in Self.corpora {
            let result = try runThroughCBackend(corpus, cli: cli, cc: cc)
            #expect(result.status == 0, "\(corpus.label)：退出码 \(result.status) \(result.stderr)")
            #expect(result.stdout == corpus.expected, "\(corpus.label)：输出与手写期望不符")
        }
    }

    /// 产物得能离开编译器单独使用：头文件与 `.c` 同目录，源里按名字引用它。
    /// 这条不跑 cc —— 它守的是「`--emit-c` 交代清楚了自己依赖什么」，编译那一半由上一条覆盖。
    @Test("--emit-c 落出的源与头同目录，且不含预置声明的函数")
    func artifactIsSelfContained() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        try Self.corpora[0].source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let source = outDir.appendingPathComponent("fixture.c")
        let header = outDir.appendingPathComponent(PiniRTHeader.fileName)
        #expect(FileManager.default.fileExists(atPath: source.path), "没有落出 .c")
        #expect(FileManager.default.fileExists(atPath: header.path), "没有落出 pini_rt.h")

        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("#include \"\(PiniRTHeader.fileName)\""), "源没有引用运行时段头")
        #expect(text.contains("int main(void) {"), "入口签名不是 int main(void)")
        // 驳回性：预置声明里的调度器方法体不该进产物（进了就说明按来源剪枝没生效）。
        #expect(!text.contains("pini__u6536"), "预置声明的函数进了产物")
    }

    // MARK: - 驱动

    /// 发源 → cc → 跑产物。三步都用 `--emit-c` 落出的那份 `.c`，中途不重新发射。
    private func runThroughCBackend(
        _ corpus: Corpus, cli: String, cc: String
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        guard emit.status == 0 else {
            return (emit.status, "", "发源失败：\(emit.stderr)")
        }
        let source = outDir.appendingPathComponent("fixture.c")
        let product = outDir.appendingPathComponent("fixture")
        // 头与 .c 同目录，`#include "pini_rt.h"` 按相对路径即可命中。
        let runtimeDir = URL(fileURLWithPath: cli).deletingLastPathComponent().path
        let build = try launch(
            cc,
            ["-std=c23", "-O2", "-o", product.path, source.path,
             "-L\(runtimeDir)", "-lPiniRuntime", "-Wl,-rpath,\(runtimeDir)"])
        guard build.status == 0 else {
            return (build.status, "", "cc 失败：\(build.stderr)")
        }
        return try launch(product.path, [])
    }

    /// 命令行产物：`PINI_CLI_BIN` 优先，否则从 `#filePath` 反推仓根再找构建输出。
    /// 两者都取不到时记一条已知问题，不让这一族判据静默通过。
    private func cliPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv) {
            return fromEnv
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        for candidate in ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
        where FileManager.default.isExecutableFile(atPath: repoRoot + candidate) {
            return repoRoot + candidate
        }
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 本套件本次未取（跳过 +1）") {
            Issue.record("C 后端端到端未取：本批判据本次没有跑")
        }
        return nil
    }

    /// 系统 C 编译器。⛔ 不借用 `LLVMToolchain`：这条通道的存在理由之一就是不依赖 LLVM。
    private func cCompilerPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CC"] ?? ""
        for candidate in [fromEnv, "/usr/bin/cc", "/usr/bin/gcc"]
        where !candidate.isEmpty && FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        withKnownIssue("未找到 C 编译器 ⇒ 本套件本次未取（跳过 +1）") {
            Issue.record("C 后端端到端未取：本批判据本次没有跑")
        }
        return nil
    }

    private func launch(
        _ binary: String, _ arguments: [String], workingDirectory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
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

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-c-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

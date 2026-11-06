import Foundation
import Testing

@testable import PiniBackendLLVM
@testable import PiniIR

/// 聚合作为数组元素：元素槽里放的是结构体本身，成员份额不能靠字节复制带走 ——
/// 深拷要逐成员保留、销毁要逐成员归还，而布局只在发射层，故由合成的钩子承担。
/// 判据分两层：产物里钩子确实挂在创建与切片上；两通道的读数一致。
@Suite(.serialized)
struct AggregateElementTests: PiniSourceLowering, Sendable {

    private func emitted(_ source: String) throws -> String {
        try IREmitter().emit(module: try lowered(source))
    }

    @Test("聚合元素登记成员钩子，宽度按该结构体的布局算")
    func 钩子与宽度() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                var a: Optional<String> = .some("x")
                var xs = [a, a]
                print(len(xs))
                return
            """)
        #expect(ir.contains("call void @bk_array_set_element_hooks"), "聚合元素要登记钩子")
        #expect(ir.contains("define void @__bk_agg_0_retain"), "保留侧钩子要合成")
        #expect(ir.contains("define void @__bk_agg_0_release"), "归还侧钩子要合成")
        #expect(
            ir.contains("ptrtoint (ptr getelementptr ({ i64, i8* }, ptr null, i32 1) to i64)"),
            "宽度只能由后端按布局求值，不能写死")
        #expect(ir.contains("i32 8)"), "聚合元素的 tag 是 8")
    }

    @Test("切片复制字节时替成员留一份")
    func 切片留份额() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                var a: Optional<String> = .some("x")
                var xs = [a, a]
                var ys = xs.slice(0, 2)
                print(len(ys))
                return
            """)
        #expect(ir.contains("call void @__bk_agg_0_retain(ptr"), "新数组也持有成员 ⇒ 要保留")
    }

    @Test("成员全是标量的聚合不登记钩子：空名单是零动作")
    func 标量聚合无钩子() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                var t = (1, 2)
                var ts = [t, t]
                print(len(ts))
                return
            """)
        #expect(!ir.contains("call void @bk_array_set_element_hooks"), "没有计数成员就不需要成员动作")
    }

    @Test("两通道对聚合元素给同一读数：取元素、切片、覆盖写都不串")
    func 端到端() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "agg-element")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            main|func() -> ():
                var a: Optional<String> = .some("汉字x")
                var c: Optional<String> = .some("yz")
                var xs = [a, c]
                var ys = xs.slice(0, 2)
                ys[0] = c
                print(xs[0])
                print(ys[0])
                print(len(ys))
                return
            """.write(
            to: dir.appendingPathComponent("agg.pini"), atomically: true, encoding: .utf8)
        for channel in ["run", "run-llvm"] {
            let result = try runCLI(cli, arguments: [channel, "agg.pini"], cwd: dir)
            #expect(result.status == 0, "\(channel) 失败：\(result.stderr)")
            #expect(result.stdout == "some(汉字x)\nsome(yz)\n2\n", "\(channel) 读数：\(result.stdout)")
        }
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
}

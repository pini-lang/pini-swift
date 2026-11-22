import Foundation
import Testing

/// 尾表达式与丢弃值：值返回体的末句就是返回值，丢弃的临时值在语句尾归还份额。
/// 同一份源码两条通道各跑一次，两次 stdout 逐字节比对。
@Suite("尾表达式", .serialized)
struct TrailingExpressionTests {

    private func cliOrSkip() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    /// 同一份源码走 `run` 与 `compile`，返回两次 stdout。只比 stdout：警告与诊断走 stderr。
    private func bothChannels(
        _ source: String, tag: String
    ) throws -> (run: String, compile: String) {
        guard let cli = cliOrSkip() else { return ("", "") }
        let dir = try PiniTestEnvironment.makeTemporaryDirectory(tag: tag)
        defer { try? FileManager.default.removeItem(at: dir) }
        try source.write(
            to: dir.appendingPathComponent("case.pini"), atomically: true, encoding: .utf8)
        let 解释 = try PiniTestEnvironment.runCLI(cli, arguments: ["run", "case.pini"], cwd: dir)
        let 编译 = try PiniTestEnvironment.runCLI(cli, arguments: ["compile", "case.pini"], cwd: dir)
        #expect(解释.status == 0, "run 失败：\(解释.stderr)")
        #expect(编译.status == 0, "compile 失败：\(编译.stderr)")
        return (解释.stdout, 编译.stdout)
    }

    @Test("值返回体的末句表达式就是返回值，函数与闭包两处都成立")
    func trailingExpressionIsTheReturnValue() throws {
        let readings = try bothChannels(
            #"""
            取|func() -> (I64,):
                40 + 2

            挑|func(_甲: I32, _乙: I32,) -> (I32,):
                var 大 = func(_左: I32, _右: I32,) -> (Bool,):
                    _左 > _右
                if 大(_甲, _乙):
                    return _甲
                return _乙

            main|func() -> ():
                print(取(),)
                print(挑(2, 9),)
                return
            """#, tag: "trailing-value")
        guard !readings.run.isEmpty else { return }
        #expect(readings.run == "42\n9\n", "解释通道读数：\(readings.run)")
        #expect(
            readings.run == readings.compile,
            "两通道不一致：run=\(readings.run) compile=\(readings.compile)")
    }

    @Test("尾位上的 pass 交出常量零，两通道同值")
    func trailingPassYieldsZero() throws {
        let readings = try bothChannels(
            #"""
            桩|func() -> (I32,):
                pass

            main|func() -> ():
                print(桩(),)
                return
            """#, tag: "trailing-pass")
        guard !readings.run.isEmpty else { return }
        #expect(readings.run == "0\n", "解释通道读数：\(readings.run)")
        #expect(
            readings.run == readings.compile,
            "两通道不一致：run=\(readings.run) compile=\(readings.compile)")
    }

    @Test("丢弃的临时对象在语句尾释放，析构早于下一条语句")
    func discardedTemporaryIsReleasedAtTheStatement() throws {
        let readings = try bothChannels(
            #"""
            {票}
            号: I32 = 0

            {{票}}

            deinit|self() -> ():
                print("析构",)
                return

            main|func() -> ():
                票()
                print("之后",)
                return
            """#, tag: "discard-temporary")
        guard !readings.run.isEmpty else { return }
        #expect(readings.run == "析构\n之后\n", "解释通道读数：\(readings.run)")
        #expect(
            readings.run == readings.compile,
            "两通道不一致：run=\(readings.run) compile=\(readings.compile)")
    }

    @Test("丢弃的临时串在发射文本里有归还，不留一份孤份额")
    func discardedStringIsReleasedInTheEmittedText() throws {
        guard let cli = cliOrSkip() else { return }
        let dir = try PiniTestEnvironment.makeTemporaryDirectory(tag: "discard-string")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"""
        造|func() -> (String,):
            return "abc" + "def"

        main|func() -> ():
            造()
            print("之后",)
            return
        """#.write(
            to: dir.appendingPathComponent("case.pini"), atomically: true, encoding: .utf8)
        let emitted = try PiniTestEnvironment.runCLI(
            cli, arguments: ["emit", "case.pini"], cwd: dir)
        #expect(emitted.status == 0, "emit 失败：\(emitted.stderr)")
        /// 判据是「紧跟着那条造串调用的一行释放」：临时值的消费点就在语句尾，
        /// 只认这一处，免得把别处的释放算进来。
        let lines = emitted.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var released = false
        for index in 1..<max(lines.count, 1) {
            let previous = lines[index - 1]
            guard previous.contains("= call i8* @"), let equals = previous.firstIndex(of: "=") else {
                continue
            }
            let temp = previous[previous.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let current = lines[index]
            if current.contains("bk_str_release(ptr \(temp))") { released = true }
        }
        #expect(released, "发射文本里没有紧跟着造串调用的释放：\n\(emitted.stdout)")
    }
}

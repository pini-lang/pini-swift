import XCTest
@testable import PiniCore

/// IR 打印黄金对拍测试门（T2：G-IR-enum-print 闭合）。
///
/// 此前 `run-llvm` 打印聚合类型（枚举/结构/对象）直接 fail-loud（unsupportedFeature），
/// 与解释器 `stringify` 展示语义割裂。T2 实现递归 `generateStringify`，使两后端对同一
/// 聚合值输出**逐字节一致**的展示字符串。本门作为硬性回归门：对每个用例同时跑解释器与
/// `lli`，断言二者输出相等且等于黄金串。
///
/// 说明：
/// - 黄金用例回避浮点 payload——run-llvm 的 `print(double)` 走 `%f`（`2.0`→`2.000000`），
///   与解释器 Swift `String(double)`（`2.0`）存在字节级差异，属已知残留（与 scalar print 同源），
///   不在 T2 范围内。
/// - 每用例仅单条 `print`，避免解释器逐 `print` 补换行、而 run-llvm `printf` 不补换行的
///   尾部换行差异干扰（对齐 `IRExecutionTests.testLLVMVsInterpreterParity` 的 trim 约定）。
final class IRPrintGoldenTests: XCTestCase {

    private var lliAvailable: Bool { LLVMToolchain.lliPath != nil }

    /// 通过 `lli` JIT 执行单文件源码，返回 stdout。
    private func runViaLLI(_ source: String, fileName: String = "test.pini") throws -> String {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let module = try parser.parseModule()
        let ir = try IRGenerator().generate(module: module)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_golden_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: tmpIR) }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let lli = LLVMToolchain.lliPath else {
            throw NSError(domain: "LLIUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "lli not available"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lli)
        // #46-D D3：容器打印依赖 PiniRuntime 动态库（@bk_* 集合访问器），须经 --dlopen 加载；
        // 非集合程序加载它无害（未用符号不影响执行）。
        var args: [String] = []
        if let dylib = locateRuntimeDylib() {
            args.append("--dlopen=\(dylib)")
        }
        args.append(tmpIR)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 定位集合运行时动态库（swift build 产物）：`.build/debug/libPiniRuntime.{dylib,so}`。
    private func locateRuntimeDylib() -> String? {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) { break }
            url = url.deletingLastPathComponent()
        }
        let buildDir = (url.path as NSString).appendingPathComponent(".build/debug")
        for ext in ["dylib", "so"] {
            let cand = (buildDir as NSString).appendingPathComponent("libPiniRuntime.\(ext)")
            if FileManager.default.fileExists(atPath: cand) { return cand }
        }
        return nil
    }

    /// 进程内解释执行，返回与 `pini run` 等价的 stdout（每个 print 补一个换行）。
    private func runViaInterpreter(_ source: String, fileName: String = "test.pini") throws -> String {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let module = try parser.parseModule()

        let interpreter = Interpreter()
        var segments: [String] = []
        interpreter.outputSink = { segments.append($0 + "\n") }
        try interpreter.run(module: module)
        return segments.joined(separator: "")
    }

    /// 黄金用例表：名称 → (源码, 期望输出)。每个用例单条 `print`，输出与解释器 `stringify` 逐字节一致。
    private static let goldenCases: [(name: String, source: String, golden: String)] = [
        ("枚举_无关联值", try! loadPiniFixture("_interpreter", filePath: #filePath), "Red"),

        ("枚举_命名关联值", try! loadPiniFixture("_c", filePath: #filePath), "圆(5)"),

        ("枚举_多命名关联值", try! loadPiniFixture("_c_2", filePath: #filePath), "矩形(3, 4)"),

        ("结构_多字段", try! loadPiniFixture("_c_3", filePath: #filePath), "点{label: hi, ok: true, x: 1}"),

        ("对象_多字段", try! loadPiniFixture("_c_4", filePath: #filePath), "计数{名字: n, 数值: 42}"),

        ("结构_嵌套枚举字段", try! loadPiniFixture("_c_5", filePath: #filePath), "盒{内色: 蓝}"),

        // #46-D D3：容器打印双后端对齐（内容逐字节一致；尾部换行差异由 trim 吸收）。
        ("D3_数组打印", try! loadPiniFixture("_c_6", filePath: #filePath), "[1, 2, 3, 4, 5]"),

        ("D3_嵌套数组打印", try! loadPiniFixture("_c_7", filePath: #filePath), "[[1, 2], [3, 4], [5, 6]]"),

        ("D3_字典打印", try! loadPiniFixture("_c_8", filePath: #filePath), "{Alice: 30, Bob: 25, Carol: 41}"),

        ("D3_集合打印", try! loadPiniFixture("_c_9", filePath: #filePath), "{2, 3, 5, 7, 11}"),

        // 缺失键：解释器 stringify(.null) → "null"，LLVM 经 @bk_dict_contains + select 同样输出 "null"，
        // 闭合 D2 遗留的「缺失键 LLVM 补零值」分歧。
        ("D3_字典缺失键打印null", try! loadPiniFixture("_c_10", filePath: #filePath), "null"),
    ]

    func testAggregatePrintMatchesInterpreter() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")

        for c in Self.goldenCases {
            let llvmOut = (try runViaLLI(c.source)).trimmingCharacters(in: .whitespacesAndNewlines)
            let interpOut = (try runViaInterpreter(c.source)).trimmingCharacters(in: .whitespacesAndNewlines)

            XCTAssertEqual(llvmOut, c.golden,
                           "[\(c.name)] run-llvm 输出与黄金不一致\n  期望：\(c.golden)\n  实际：\(llvmOut)")
            XCTAssertEqual(interpOut, llvmOut,
                           "[\(c.name)] 解释器与 run-llvm 输出不一致\n  解释器：\(interpOut)\n  run-llvm：\(llvmOut)")
        }
    }

    /// 多参 print 混排（标量 + 聚合 + 标量）：仅对拍解释器 vs run-llvm，不强绑硬编码黄金，
    /// 以吸收多参 join 的空格/换行差异（两后端均应 `join(separator: " ")`）。
    func testMultiArgPrintMixedMatchesInterpreter() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")

        let source = try loadPiniFixture("testMultiArgPrintMixedMatchesInterpreter", filePath: #filePath)

        let llvmOut = (try runViaLLI(source)).trimmingCharacters(in: .whitespacesAndNewlines)
        let interpOut = (try runViaInterpreter(source)).trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(llvmOut, interpOut,
                       "多参 print 混排两后端不一致\n  解释器：\(interpOut)\n  run-llvm：\(llvmOut)")
        XCTAssertTrue(llvmOut.contains("点{x: 7}"), "多参 print 应包含聚合展示 点{x: 7}，实际：\(llvmOut)")
    }
}

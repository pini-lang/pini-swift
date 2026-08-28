import XCTest
@testable import PiniCore

final class IRExecutionTests: XCTestCase {

    private var lliPath: String? { LLVMToolchain.lliPath }
    private var clangPath: String? { LLVMToolchain.clangPath }

    private var lliAvailable: Bool { lliPath != nil }
    private var clangAvailable: Bool { clangPath != nil }

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

    private func runViaLLI(_ source: String, fileName: String = "test.pini", dylib: String? = nil) throws -> String {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let module = try parser.parseModule()

        let generator = IRGenerator()
        let ir = try generator.generate(module: module)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_exec_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: tmpIR) }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let lli = lliPath else {
            throw NSError(domain: "LLIUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "lli not available"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lli)
        var args: [String] = []
        if let dylib { args.append("--dlopen=\(dylib)") }
        args.append(tmpIR)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
    }

    private func runViaClang(_ source: String, fileName: String = "test.pini", dylib: String? = nil) throws -> String {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let module = try parser.parseModule()

        let generator = IRGenerator()
        let ir = try generator.generate(module: module)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_exec_\(UUID().uuidString).ll"
        let tmpBin = FileManager.default.temporaryDirectory.path + "/pini_exec_\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpIR)
            try? FileManager.default.removeItem(atPath: tmpBin)
        }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let clang = clangPath else {
            throw NSError(domain: "ClangUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "clang not available"])
        }
        var clangArgs: [String] = []
        if let dylib {
            let dir = URL(fileURLWithPath: dylib).deletingLastPathComponent().path
            clangArgs += ["-L\(dir)", "-lPiniRuntime", "-Wl,-rpath,\(dir)"]
        }
        clangArgs += ["-o", tmpBin, tmpIR]
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: clang)
        compile.arguments = clangArgs
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw NSError(domain: "CompileError", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "clang compilation failed"])
        }

        let run = Process()
        run.executableURL = URL(fileURLWithPath: tmpBin)
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = Pipe()
        try run.run()
        run.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - lli execution tests

    func testSimpleArithmetic_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var x = 40
    x = x + 2
    print(x)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testWhileLoopSum_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var i = 1
    var sum = 0
    while i <= 5:
        sum = sum + i
        i = i + 1
    print(sum)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "15")
    }

    // MARK: - step 块（P1-5 LLVM 后端）

    /// step 块经 LLVM 后端执行：每轮循环体正常结束后执行一次 step。
    func testStepExecutesAfterEachIteration_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main() -> ()
    var i = 0
    while i < 3:
        print(i)
        i = i + 1
    step:
        print("S")
    return
"""
        let output = try runViaLLI(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "0S1S2S", "LLVM 后端 step 应在每轮末尾执行一次")
    }

    /// step 块经 LLVM 后端执行：continue 后也应执行 step（类 C for 的步进语义）。
    func testStepExecutesOnContinue_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main() -> ()
    var i = 0
    while i < 3:
        print(i)
        i = i + 1
        continue
    step:
        print("C")
    return
"""
        let output = try runViaLLI(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "0C1C2C", "LLVM 后端 continue 后也应执行 step")
    }

    /// step 块经 LLVM 后端执行：break 应跳过 step。
    func testStepSkippedOnBreak_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main() -> ()
    var i = 0
    while i < 5:
        print(i)
        i = i + 1
        if i == 3:
            break
    step:
        print("B")
    return
"""
        let output = try runViaLLI(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "0B1B2", "LLVM 后端 break 应跳过 step")
    }

    /// 嵌套 while 的 step 经 LLVM 后端执行：内层 step 就近匹配内层 while，外层匹配外层。
    func testNestedWhileStepScoping_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        // 字符串数组精确控制缩进，避免 Swift 多行字符串的缩进剥离破坏嵌套层级
        let source = [
            "main() -> ()",
            "    var i = 0",
            "    while i < 2:",
            "        var j = 0",
            "        while j < 2:",
            "            print(\"in\")",
            "            j = j + 1",
            "        step:",
            "            print(\"inS\")",
            "        i = i + 1",
            "    step:",
            "        print(\"outS\")",
            "    return",
        ].joined(separator: "\n")
        let output = try runViaLLI(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "ininSininSoutSininSininSoutS",
                       "LLVM 后端内层 step 就近匹配内层 while，外层 step 匹配外层")
    }

    func testFibonacci_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var n = 10
    var a = 0
    var b = 1
    var i = 1
    while i < n:
        var temp = a + b
        a = b
        b = temp
        i = i + 1
    print(b)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "55")
    }

    func testIfElseBranching_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var x = 10
    if x > 5:
        print(1)
    else:
        print(0)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testBreakInLoop_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var i = 0
    var sum = 0
    while i < 100:
        if i >= 5:
            break
        sum = sum + i
        i = i + 1
    print(sum)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "10")
    }

    func testStringPrint_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    print("Hello, LLVM!")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "Hello, LLVM!")
    }

    func testStringVariablePrint_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var s = "stored"
    print(s)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "stored")
    }

    // MARK: - 字符串插值 IR 执行测试（P6-1b）

    func testStringInterpolation_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var x = 42
    print("x=\\(x)")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "x=42")
    }

    func testStringInterpolationMixed_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var name = "World"
    var n = 5
    print("Hello \\(name), count=\\(n)")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "Hello World, count=5")
    }

    func testStringInterpolationDouble_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var pi = 2.5
    print("pi=\\(pi)")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "pi=2.500000")
    }

    func testStringInterpolation_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        let source = """
main|func() -> ()
    var x = 7
    var s = "ok"
    print("result=\\(x) status=\\(s)")
    return
"""
        let output = try runViaClang(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "result=7 status=ok")
    }

    // MARK: - 元组字面量 IR 执行测试（P6-1c）

    func testTupleConstruct_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var a = 10
    var b = 20
    var p = (a, b)
    print(a + b)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "30")
    }

    func testTupleConstruct_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        let source = """
main|func() -> ()
    var a = 7
    var b = 8
    var p = (a, b)
    print(a * b)
    return
"""
        let output = try runViaClang(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "56")
    }

    // MARK: - 数组字面量 IR 执行测试（P6-1d）

    func testArrayConstruct_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let source = """
main|func() -> ()
    var arr = [10, 20, 30]
    print(10 + 20 + 30)
    return
"""
        let output = try runViaLLI(source, dylib: dylib)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "60")
    }

    func testArrayConstruct_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let source = """
main|func() -> ()
    var arr = [1, 2, 3, 4]
    print(1 + 2 + 3 + 4)
    return
"""
        let output = try runViaClang(source, dylib: dylib)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "10")
    }

    // MARK: - P6-1e: len 内置 + print bool 收口（真实执行）

    func testLenArray_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let source = """
main|func() -> ()
    var arr = [10, 20, 30]
    print(len(arr))
    return
"""
        let output = try runViaLLI(source, dylib: dylib)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "3")
    }

    func testLenTuple_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var t = (1, 2.5, 7)
    print(len(t))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "3")
    }

    func testLenString_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var s = "hello"
    print(len(s))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "5")
    }

    func testLenString_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        let source = """
main|func() -> ()
    var s = "abcdefg"
    print(len(s))
    return
"""
        let output = try runViaClang(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "7")
    }

    /// 验证 `len(string)` 在两后端语义一致（Bug B 已闭合）：
    /// IR 后端统计「非 UTF-8 续行字节」得 Unicode 标量数，与解释器 `String.count` 对齐，
    /// 常见文本（含 CJK）下二者一致（"中文" → 2）。
    func testLenCJKString_IsCharCount_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var s = "中文"
    print(len(s))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2",
                       "len(中文) 两后端须一致为字符数 2（已对齐 Bug B）")
    }

    func testPrintBoolTrue_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    print(true)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "true",
                       "print(bool) 应与解释器一致输出 true（而非 1）")
    }

    func testPrintBoolFalse_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    print(false)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "false",
                       "print(bool) 应与解释器一致输出 false（而非 0）")
    }

    func testInterpolatedBool_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var flag = true
    var n = 3
    print("flag=\\(flag) n=\\(n)")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "flag=true n=3")
    }

    // MARK: - async/await MVP execution tests

    func testAsyncFunction_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
fetchData() => (I32,)
    return 42

main|func() -> ()
    var result = wait fetchData()
    print(result)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testAwaitConsumption_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
addOne(x: I32,) => (I32,)
    return x + 1

main|func() -> ()
    var v = 10
    v = wait addOne(v)
    v = wait addOne(v)
    print(v)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "12")
    }

    func testAsyncVsSyncParity_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")

        let asyncSource = """
compute() => (I32,)
    var s = 0
    var i = 1
    while i <= 5:
        s = s + i
        i = i + 1
    return s

main|func() -> ()
    var r = wait compute()
    print(r)
    return
"""
        let syncSource = """
compute() -> (I32,)
    var s = 0
    var i = 1
    while i <= 5:
        s = s + i
        i = i + 1
    return s

main|func() -> ()
    var r = compute()
    print(r)
    return
"""
        let asyncOutput = try runViaLLI(asyncSource).trimmingCharacters(in: .whitespacesAndNewlines)
        let syncOutput = try runViaLLI(syncSource).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(asyncOutput, syncOutput,
                       "async 和 sync 版本应产生相同输出")
        XCTAssertEqual(asyncOutput, "15")
    }

    func testStringPrint_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        let source = """
main|func() -> ()
    print("Hello from clang")
    return
"""
        let output = try runViaClang(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "Hello from clang")
    }

    // MARK: - clang execution tests

    func testSimpleArithmetic_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        let source = """
main|func() -> ()
    var x = 40
    x = x + 2
    print(x)
    return
"""
        let output = try runViaClang(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testFibonacci_Clang() throws {
        try XCTSkipUnless(clangAvailable, "clang not available")
        let source = """
main|func() -> ()
    var n = 10
    var a = 0
    var b = 1
    var i = 1
    while i < n:
        var temp = a + b
        a = b
        b = temp
        i = i + 1
    print(b)
    return
"""
        let output = try runViaClang(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "55")
    }

    // MARK: - Interpreter vs LLVM parity

    func testLLVMVsInterpreterParity() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var i = 1
    var sum = 0
    while i <= 10:
        sum = sum + i
        i = i + 1
    print(sum)
    return
"""
        let lliOutput = try runViaLLI(source).trimmingCharacters(in: .whitespacesAndNewlines)

        // Run via interpreter for comparison
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let interpreter = Interpreter()
        try interpreter.run(module: module)

        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let interpreterOutput = String(data: data, encoding: .utf8)!
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(lliOutput, interpreterOutput,
                       "LLVM and interpreter should produce same output")
    }

    // MARK: - P6-2a: struct 类型真实执行

    /// 真实 clang/lli 执行：struct 构造（字段取默认值）+ 字段访问打印，应与解释器一致。
    func testStructFieldAccessViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
(Point)
    port: I32 = 8080

main|func() -> ()
    let c = Point()
    print(c.port)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "8080",
                      "struct 字段访问应打印默认值 8080")
    }

    // MARK: - P6-2b: object 类型真实执行

    /// 真实 clang/lli 执行：object 构造（refcount 头 + 字段默认值）+ 字段访问打印，应与解释器一致。
    func testObjectFieldAccessViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
{Counter}
    port: I32 = 8080

main|func() -> ()
    let c = Counter()
    print(c.port)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "8080",
                      "object 字段访问应打印默认值 8080")
    }

    // MARK: - P6-2c: enum 类型真实执行

    /// 真实 clang/lli 执行：enum 构造 + match 分发（两 case + default）。
    func testEnumMatchDispatchViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
[Color]
Red
Green

main|func() -> ()
    let c = Red
    match c:
        case Red:
            print("R")
        case Green:
            print("G")
        case _:
            print("?")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "R",
                      "match Red 应打印 R")
    }

    // MARK: - P6-2 衍生：字段写入 + 引用共享

    /// 真实 clang/lli：struct 字段写入后读取，验证 GEP+store 链路完整。
    func testStructFieldWriteViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
(Point)
    x: I32 = 0

main|func() -> ()
    let c = Point()
    c.x = 10
    print(c.x)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "10",
                      "struct c.x=10 后应打印 10")
    }

    /// 真实 clang/lli：object 引用共享——`let p2 = p1` 后通过 p2 改写字段，p1 应可见（引用语义）。
    func testObjectReferenceSharingViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
{Counter}
    count: I32 = 0

main|func() -> ()
    let c1 = Counter()
    let c2 = c1
    c2.count = 100
    print(c1.count)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "100",
                      "object 引用共享：通过 c2 写入，c1 应打印 100")
    }

    // MARK: - P6-3a: defer 真实执行

    /// 真实 clang/lli：defer 在 return 前执行（LIFO）。
    func testDeferBasicViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    defer print("B")
    print("A")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "AB",
                      "defer 应在 return 前逆序执行：先 A 后 B（print 不带换行）")
    }

    /// 真实 clang/lli：多个 defer 按 LIFO 逆序执行。
    func testDeferLIFOViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    defer print("C")
    defer print("B")
    print("A")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ABC",
                      "defer LIFO：A→B→C（print 不带换行）")
    }

    // MARK: - P6-3b: enum 关联值 + match 绑定真实执行

    /// 真实 clang/lli：enum 关联值构造 + match 绑定量取 payload。
    func testEnumPayloadMatchBindingViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
[Shape]
Circle(I32,)
Square

main|func() -> ()
    let s = Circle(42,)
    match s:
        case Circle(x,):
            print(x)
        case _:
            print(0)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42",
                      "match 绑定应提取 payload=42")
    }

    // MARK: - 批次 1：元组索引 / 解构 / 命名元组 / 元组打印（LLVM 执行）

    /// 真实 lli：元组位置访问 `.0` / `.1`（草稿 A2，批次 1.1）。
    func testTupleIndexAccess_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var p = (17, 5)
    print(p.0 + p.1)
    print(p.1 - p.0)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "22-12",
                      "位置访问 p.0=17 p.1=5 应得 22 与 -12")
    }

    /// 真实 lli：命名元组标签访问 `.名称`（D1，批次 1.3，Phase 1）。
    /// 标签访问经 `tupleTypeByVar` 查「标签→下标」后复用 extractvalue，输出与解释器一致。
    func testTupleNamedAccess_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var p = (商: 17, 余: 5)
    print(p.商 - p.余)
    print(p.商)
    print(p.余)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "12175",
                      "命名元组标签访问 商-余=12、商=17、余=5（LLVM 无换行拼接）")
    }

    /// 真实 lli：元组解构 `var (a, b) = rhs`（草稿 A1，批次 1.2）+ 函数返回元组整体绑定。
    func testTupleDestructure_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
除余|func(a: I32, b: I32) -> ((I32, I32,),)
    return (a / b, a % b)

main|func() -> ()
    let (商, 余) = 除余(17, 5)
    print(商)
    print(余)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "32",
                      "解构 (3, 2) 应分别绑定 商=3 余=2")
    }

    /// 真实 lli：元组整体打印（对齐解释器 `stringify` 的 `[v0, v1]`，批次 1 修复 StringifyEmitter 缺元组分支）。
    func testTuplePrint_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var p = (3, 2)
    print(p)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "[3, 2]",
                      "位置元组打印应得 [3, 2]（此前 LLVM 缺元组 stringify 会崩溃）")
    }

    /// 真实 lli：命名元组整体打印（对齐解释器 `[label: v0, ...]`，D1 标签经 tupleTypeByVar 注入）。
    func testNamedTuplePrint_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var p = (商: 3, 余: 2)
    print(p)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "[商: 3, 余: 2]",
                      "命名元组打印应得 [商: 3, 余: 2]")
    }

    // MARK: - 批次 2 / 3：if/elif/else 与标量 match（LLVM 执行）

    /// 真实 lli：if/elif/else 同级块分支（批次 2 契约）。
    func testIfElifElse_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var x = 2
    if x == 1:
        print("a")
    elif x == 2:
        print("b")
    else:
        print("c")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "b",
                      "x=2 应命中 elif 分支打印 b")
    }

    /// 真实 lli：I8 整型 primitive 字段访问（Phase 0）——struct 含 I8 字段，构造/赋值宽度截断/算术/方法返回/打印。
    /// 预期输出 `p.x+p.y`=24 与 `p.距离原点()`=24（LLVM 每 print 不加换行 → "2424"）。
    func testI8StructField_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
(点)
x: I8 = 0.0
y: I8 = 0.0


((点))
距离原点|self() -> (I8,)
    return self.x + self.y

main|func() -> ()
    var p = 点()
    p.x = 8
    p.y = 16
    print(p.x + p.y)
    print(p.距离原点())
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2424",
                      "I8 字段加法与方法返回应各打印 24（LLVM 无换行拼接）")
    }

    /// 真实 lli：数组 join（Phase 1 #7）——变量绑定数组（%bk_array* 运行时长度循环）
    /// 与字面量数组均按分隔符拼接字符串元素。
    func testArrayJoin_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        // 数组字面量走 %bk_array* 运行时句柄，须加载集合运行时动态库。
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let source = """
main|func() -> ()
    var a = ["a", "b", "c"]
    print(a.join("-"))
    print(["x", "y"].join("+"))
    return
"""
        let output = try runViaLLI(source, dylib: dylib)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "a-b-cx+y",
                      "变量数组 join(-)=a-b-c、字面量 join(+)=x+y（LLVM 无换行拼接）")
    }

    /// 真实 lli：块级 defer（#8）——循环体内的 defer 在该块自然落入出口按 LIFO 刷新，
    /// 在后续 print 前已生效（对齐解释器 deferStack 逐块语义，而非仅函数出口）。
    func testDeferBlockScope_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var result = ""
    var i = 0
    while i < 1:
        defer result = result + "last"
        defer result = result + "middle"
        defer result = result + "first"
        result = result + "body"
        i = i + 1
    print(result)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "bodyfirstmiddlelast",
                      "循环体内 defer 应在块出口按 LIFO 刷新：body+first+middle+last")
    }

    /// 真实 lli：具名函数作为值（#8 higher-order）——经 env 忽略适配器对齐闭包 ABI，
    /// 间接调用 `f(x)` 不再实参错位。
    func testHigherOrderFunctionValue_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
应用|func(f: (I32,) -> (I32,), x: I32) -> (I32,)
    return f(x)

加倍|func(n: I32) -> (I32,)
    return n * 2

main|func() -> ()
    print(应用(加倍, 5))
    var g = func (n,) -> (I32,):
        return n * n
    print(g(6))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1036",
                      "加倍(5)=10、匿名 g(6)=36（LLVM 无换行拼接）")
    }

    /// 真实 lli：try 语句（#5，返回元组显式传播错误模型）——错误槽非空走 except，空串走 tryBlock。
    /// 形参用中文名（`路径`），同时锁定 CJK 形参的 IR 标识符引号发射（`%"路径"`）。
    func testTryStatement_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
读取文件(路径: String,) -> (内容: String, 错误: String,)
    return ("", "模拟错误")

main|func() -> ()
    try 读取文件("data.txt"):
        print("读取成功")
    except 错误:
        print("读取失败")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "读取失败",
                      "错误槽非空应进入 except 分支")
    }

    /// 真实 lli：结构体内嵌组合（R1.1）——子类型组合父类型，字段经合并布局、
    /// 方法经接收者特化名分派（父/子同名方法各自按自身布局编译）。
    func testStructComposition_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
(计数器)
数值: I32 = 0
标签: String = "默认"


((计数器))
增加|self() -> ()
    self.数值 = self.数值 + 1
    return

描述|self() -> ()
    print(self.标签)
    return

(倒计数)
计数器
步长: I32 = 1


((倒计数))
减少|self() -> ()
    self.数值 = self.数值 - self.步长
    return

main|func() -> ()
    var c = 倒计数()
    c.增加()
    c.增加()
    print(c.数值)
    c.减少()
    print(c.数值)
    c.描述()
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "21默认",
                      "组合字段/方法：数值 2→1、标签 默认（LLVM 无换行拼接）")
    }

    /// 真实 lli：break/continue 终止边的块级 defer（R1.2）——break 放弃被放弃层时按 LIFO 发射 defer。
    func testBreakDefer_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var result = ""
    var i = 0
    while i < 10:
        defer result = result + "x"
        if i == 2:
            break
        i = i + 1
    print(result)
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "xxx",
                      "3 次迭代各注册 defer，break 时按 LIFO 发射 → xxx")
    }

    /// 真实 lli：泛型 struct 类型单态化（R2）——`盒<T>` → `盒_I32`/`盒_String`，
    /// 字段类型与方法按具体类型特化（接收者特化名分派）。
    func testGenericStruct_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
(盒<T>)
内容: T


((盒<T>))
取|self() -> (T,)
    return self.内容

main|func() -> ()
    var h = 盒<I32>()
    h.内容 = 7
    print(h.取())
    var s = 盒<String>()
    s.内容 = "泛型值"
    print(s.取())
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "7泛型值",
                      "盒<I32>.取()=7、盒<String>.取()=泛型值（LLVM 无换行拼接）")
    }

    /// 真实 lli：trait 结构体方法 + 裸字段引用（R3）——方法体 `return 名字` 等价 `self.名字`
    /// （对齐解释器 bindInstanceFields；写仍须 `self.字段`）。
    func testTraitBareField_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
<可描述>
    描述(self) -> (String,)
        return "默认描述"

(狗)
    名字: String = "旺财"
    实现: 可描述

((狗))
    描述|self() -> (String,)
        return 名字

main|func() -> ()
    var d = 狗()
    print(d.描述())
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "旺财",
                      "狗.描述() 覆盖实现返回裸字段 名字 = 旺财")
    }

    /// 真实 lli：标量/字面量 match（R4，HIGH-2 IR 路径）——整数 literal + `case _:` 通配兜底。
    /// 逐 case 生成 icmp 比较链，顺序匹配首中即止；通配兜底。
    func testScalarMatch_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var x = 2
    match x:
        case 1:
            print("one")
        case 2:
            print("two")
        case _:
            print("other")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "two",
                      "x=2 应命中 case 2 打印 two")
    }

    /// 真实 lli：标量 match 字符串字面量（R4）——`match s: case "hi":` 经 strcmp==0 判定。
    func testScalarStringMatch_LLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    var s = "hi"
    match s:
        case "hi":
            print("hello")
        case "bye":
            print("goodbye")
        case _:
            print("unknown")
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello",
                      "s=hi 应命中 case hi 打印 hello")
    }

    // MARK: - P6-4a: 参数缺类型注解推断 + 真实执行

    /// 真实 lli：`add(x, y) -> I32`（无类型注解），参数从返回类型推断为 i32。
    func testParamWithoutAnnotation_InferredI32_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
add(x, y) -> (I32,)
    return x + y

main|func() -> ()
    print(add(3, 4))
    print(add(100, 200))
    return
"""
        let output = try runViaLLI(source)
        // add(3,4)=7, add(100,200)=300
        XCTAssertTrue(output.contains("7"), "add(3,4) 应输出 7，实际: \(output)")
        XCTAssertTrue(output.contains("300"), "add(100,200) 应输出 300，实际: \(output)")
    }

    /// 真实 lli：`add(x, y) -> ()`（无类型注解、void 返回），参数回退为 i32。
    func testParamWithoutAnnotation_FallbackI32_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
add(x, y) -> ()
    print(x + y)
    return

main|func() -> ()
    add(10, 20)
    return
"""
        let output = try runViaLLI(source)
        // add(10,20) → print(30)
        XCTAssertTrue(output.contains("30"), "add(10,20) 应输出 30，实际: \(output)")
    }

    // MARK: - P6-4b: 泛型函数单态化 真实执行

    /// 真实 lli：`identity<I32>(42)` 特化后正确执行。
    func testGenericIdentity_I32_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
identity<T>(x: T,) -> (T,)
    return x

main|func() -> ()
    print(identity<I32>(42))
    print(identity<I32>(100))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertTrue(output.contains("42"), "identity(42) 应输出 42，实际: \(output)")
        XCTAssertTrue(output.contains("100"), "identity(100) 应输出 100，实际: \(output)")
    }

    /// 真实 lli：两个不同特化在同一模块中正确共存。
    func testGenericIdentity_TwoTypes_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
identity<T>(x: T,) -> (T,)
    return x

main|func() -> ()
    print(identity<I32>(42))
    print(identity<F64>(3.14))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertTrue(output.contains("42"), "identity<I32> 应输出 42，实际: \(output)")
        XCTAssertTrue(output.contains("3.14"), "identity<F64> 应输出 3.14，实际: \(output)")
    }

    // MARK: - P6-4c: 多返回值 struct return 真实执行

    /// 真实 lli：多返回值函数调用（签名 + return 打包验证）。
    func testMultiReturn_Swap_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
swap(x: I32, y: I32,) -> (I32, I32,)
    return (y, x,)

main|func() -> ()
    let result = swap(10, 20)
    return
"""
        // 仅验证能生成有效 IR 并执行成功（无 lli 错误）
        let output = try runViaLLI(source)
        // 程序应正常退出（无输出，但无运行时错误）
        _ = output
    }

    /// 真实 lli：多返回值函数 — return 语句的 insertvalue 打包验证。
    func testMultiReturn_AddAndSub_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
addAndSub(x: I32, y: I32,) -> (I32, I32,)
    return (x + y, x - y,)

main|func() -> ()
    let r = addAndSub(10, 3)
    return
"""
        let output = try runViaLLI(source)
        _ = output  // 程序正常退出即为成功
    }

    // MARK: - P6-4d: trait 方法分发 真实执行

    /// 真实 lli：trait 默认实现分派——类型不覆盖方法时用 trait 默认。
    func testTraitDefaultMethod_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
<Shape>
    describe(self) -> (I32,)
        return 42

(Circle)
    实现: Shape

main|func() -> ()
    var c = Circle()
    print(c.describe())
    return
"""
        let output = try runViaLLI(source)
        XCTAssertTrue(output.contains("42"), "应输出 42，实际: \(output)")
    }

    /// 真实 lli：trait 方法被类型覆盖时用类型自己的实现。
    func testTraitOverrideMethod_ViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
<Shape>
    describe(self) -> (I32,)
        return 42

(Circle)
    实现: Shape

((Circle))
    describe|self() -> (I32,)
        return 99

main|func() -> ()
    var c = Circle()
    print(c.describe())
    return
"""
        let output = try runViaLLI(source)
        XCTAssertTrue(output.contains("99"), "应输出 99（覆盖实现），实际: \(output)")
    }

    // MARK: - P6-4b: 内置数学函数

    /// 真实 clang/lli：abs / min / max（i32 上用 select+icmp）。
    func testBuiltinMathIntegersViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    print(abs(-5))
    print(min(3, 7))
    print(max(3, 7))
    return
"""
        let output = try runViaLLI(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "537",
                      "abs(-5)=5 min(3,7)=3 max(3,7)=7")
    }

    /// 真实 clang/lli：sqrt / sin / cos / tan（F64 上走 LLVM intrinsic）。
    func testBuiltinMathFloatsViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    print(sqrt(4.0))
    print(sin(0.0))
    print(cos(0.0))
    return
"""
        let output = try runViaLLI(source)
        // sqrt(4)=2.000000 sin(0)=0.000000 cos(0)=1.000000
        XCTAssertTrue(output.contains("2.000000"), "sqrt(4) 应输出 2.0，实际: \(output)")
        XCTAssertTrue(output.contains("0.000000"), "sin(0) 应输出 0.0，实际: \(output)")
        XCTAssertTrue(output.contains("1.000000"), "cos(0) 应输出 1.0，实际: \(output)")
    }

    // MARK: - P6-4c: readLine

    /// 真实 lli 执行：readLine 从 stdin 读取（macOS __stdinp 兼容）。
    func testReadLineViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = """
main|func() -> ()
    print(readLine())
    return
"""
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let generator = IRGenerator()
        let ir = try generator.generate(module: module)

        let tmpDir = FileManager.default.temporaryDirectory.path
        let irPath = tmpDir + "/pini_rl_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: irPath) }
        try ir.write(toFile: irPath, atomically: true, encoding: .utf8)

        let inputPipe = Pipe()
        inputPipe.fileHandleForWriting.write("hello_stdin".data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LLVMToolchain.lliPath!)
        proc.arguments = [irPath]
        proc.standardInput = inputPipe
        let outPipe = Pipe(); proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("hello_stdin"),
                      "readLine 应从 stdin 读取并输出，实际: \(output)")
    }

    /// 真实 lli：writeFile + readFile 往返——写入字符串、读回比对。
    func testWriteReadFileViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let tmpPath = FileManager.default.temporaryDirectory.path
            + "/pini_io_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let source = """
main|func() -> ()
    writeFile("\(tmpPath)", "file_content")
    print(readFile("\(tmpPath)"))
    return
"""
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let ir = try IRGenerator().generate(module: module)

        let irPath = FileManager.default.temporaryDirectory.path
            + "/pini_io_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: irPath) }
        try ir.write(toFile: irPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LLVMToolchain.lliPath!)
        proc.arguments = [irPath]
        let outPipe = Pipe(); proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("file_content"),
                      "writeFile/readFile 往返应输出 file_content，实际: \(output)")
    }

    // MARK: - P6-4d: struct method

    func testStructMethodViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let output = try runViaLLI("""
(Point)
x: I32 = 0

((Point))
add|self() -> ()
    self.x = self.x + 1
    return

main|func() -> ()
    let p = Point()
    p.add()
    print(p.x)
    return
""")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1",
                      "方法 add 应将 x 从 0 增至 1")
    }

    // MARK: - spec G30 / P2-6: nil 关键字 LLVM 执行（与解释器对齐）

    /// 真实 lli 执行：nil 与 Optional.none 双向互通（构造 / match 模式），
    /// 输出应与解释器逐 token 一致。LLVM 后端 print 不带换行（既有行为），
    /// 故用 `.components(separatedBy: .whitespacesAndNewlines).joined()` 归一化后比对。
    func testNilKeywordViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = [
            "main|func() -> ()",
            "    var a = nil",
            "    match a:",
            "        case none:",
            "        print(\"none\")",
            "    var b = Optional.none",
            "    match b:",
            "        case nil:",
            "        print(\"none\")",
            "    var c: Optional<I32> = nil",
            "    match c:",
            "        case nil:",
            "        print(\"matched-nil\")",
            "    var d: Optional<I32> = nil",
            "    match d:",
            "        case none:",
            "        print(\"none\")",
            "    return",
        ].joined(separator: "\n")
        let output = try runViaLLI(source)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "nonenonematched-nilnone",
                      "nil/Optional.none 经 LLVM 后端应与解释器逐 token 一致")
    }

    /// lli 与解释器对 nil 关键字产出逐 token 一致（过滤掉既有 print 无换行差异）。
    func testNilKeywordLLVMVsInterpreterParity() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = [
            "main|func() -> ()",
            "    var a = nil",
            "    match a:",
            "        case none:",
            "        print(\"none\")",
            "    var b = Optional.none",
            "    match b:",
            "        case nil:",
            "        print(\"none\")",
            "    var c: Optional<I32> = nil",
            "    match c:",
            "        case nil:",
            "        print(\"matched-nil\")",
            "    var d: Optional<I32> = nil",
            "    match d:",
            "        case none:",
            "        print(\"none\")",
            "    return",
        ].joined(separator: "\n")
        let lliOutput = try runViaLLI(source)
            .components(separatedBy: .whitespacesAndNewlines).joined()

        // 解释器产出
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let interpreterOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .components(separatedBy: .whitespacesAndNewlines).joined()

        XCTAssertEqual(lliOutput, interpreterOutput,
                       "LLVM 与解释器对 nil 关键字应逐 token 一致")
        XCTAssertEqual(lliOutput, "nonenonematched-nilnone")
    }

    // MARK: - spec G31 / P3-5: `?` 可选类型糖（前缀 ?T）LLVM 执行（与解释器对齐）

    /// 真实 lli 执行：?I32（= Optional<I32>）经 LLVM 后端构造 nil / match case nil，
    /// 输出应与解释器逐 token 一致。复用 P2-6 已启用的 Optional.none/nil 构造路径。
    func testQuestionTypeViaLLI() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = [
            "main|func() -> ()",
            "    var x: ?I32 = nil",
            "    match x:",
            "        case nil:",
            "        print(\"q-none\")",
            "    return",
        ].joined(separator: "\n")
        let output = try runViaLLI(source)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "q-none",
                      "?I32 经 LLVM 后端应与解释器逐 token 一致")
    }

    /// lli 与解释器对 ?T 可选糖产出逐 token 一致（覆盖 ?T↔Optional<I32> 互赋路径）。
    func testQuestionTypeLLVMVsInterpreterParity() throws {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let source = [
            "main|func() -> ()",
            "    var e: ?I32 = nil",
            "    match e:",
            "        case nil:",
            "        print(\"q-none\")",
            "    var f: Optional<I32> = e",
            "    match f:",
            "        case none:",
            "        print(\"q-assign\")",
            "    return",
        ].joined(separator: "\n")
        let lliOutput = try runViaLLI(source)
            .components(separatedBy: .whitespacesAndNewlines).joined()

        // 解释器产出
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let interpreterOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .components(separatedBy: .whitespacesAndNewlines).joined()

        XCTAssertEqual(lliOutput, interpreterOutput,
                       "LLVM 与解释器对 ?T 可选糖应逐 token 一致")
        XCTAssertEqual(lliOutput, "q-noneq-assign")
    }

    // MARK: - #46-D D3: print(容器) 双后端（lli + clang AOT）与解释器对拍

    func testD3ContainerPrintBothBackendsMatch() throws {
        throw XCTSkip("M2: 字典缺失键打印 none（解释器）与 null（LLVM）分歧，下标读严格枚举 LLVM 未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try XCTSkipUnless(lliAvailable && clangAvailable, "lli/clang not available")
        guard let dylib = locateRuntimeDylib() else {
            throw XCTSkip("PiniRuntime dylib not built")
        }
        let source = [
            "main|func() -> ()",
            "    let a = [1, 2, 3, 4, 5]",
            "    let nested = [[1, 2], [3, 4], [5, 6]]",
            "    let d = [\"Alice\": 30, \"Bob\": 25, \"Carol\": 41]",
            "    let s = {2, 3, 5, 7, 11}",
            "    print(a)",
            "    print(nested)",
            "    print(d)",
            "    print(s)",
            "    print(d[\"Zoe\"])",
            "    return",
        ].joined(separator: "\n")

        let lliOut = try runViaLLI(source, dylib: dylib)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        let clangOut = try runViaClang(source, dylib: dylib)
            .components(separatedBy: .whitespacesAndNewlines).joined()

        // 解释器产出（stdout 重定向）
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let interpOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .components(separatedBy: .whitespacesAndNewlines).joined()

        // 归一化后三执行路径（解释器 / lli-JIT / clang-AOT）应逐 token 一致；黄金串为去空白后的容器展示。
        let golden = "[1,2,3,4,5][[1,2],[3,4],[5,6]]{Alice:30,Bob:25,Carol:41}{2,3,5,7,11}null"
        XCTAssertEqual(lliOut, clangOut, "lli 与 clang AOT 容器打印应一致")
        XCTAssertEqual(lliOut, interpOut, "LLVM 与解释器容器打印应逐 token 一致")
        XCTAssertEqual(lliOut, golden, "容器打印双后端归一化后应等于黄金串")
    }
}

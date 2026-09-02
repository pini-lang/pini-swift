import XCTest
import PiniCore
import Foundation

/// 基础 IO 行为测试
/// 格式化输出（print 多参）、文件读写（readFile/writeFile）、标准输入（readLine）。
/// 全部走真实解释器公共接口，不 mock 内部实现；stdout 捕获，stdin **统一接管**为注入管道
/// （确定性环境——空串即 EOF，不依赖测试进程的真实 stdin，交互终端下也不会阻塞）。
final class IOTests: XCTestCase {

    private func runProgram(_ source: String, stdin: String = "", programBase: String? = nil) throws -> String {
        let lexer = Lexer(source: source, fileName: "io.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "io.pini")
        let module = try parser.parseModule()

        let outPipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        // 始终把 stdin 接管为注入管道（确定性环境，不依赖测试进程真实 stdin）：
        // - stdin 为空串 → 写端立即关闭 → readLine 得到 EOF（testReadLineEOF 场景）；
        // - stdin 非空 → 写入数据后关闭写端 → readLine 读到数据行后 EOF。
        let inPipe = Pipe()
        let originalStdin = dup(STDIN_FILENO)
        dup2(inPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        if stdin.isEmpty {
            inPipe.fileHandleForWriting.closeFile()
        } else {
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            inPipe.fileHandleForWriting.closeFile()
        }

        do {
            // 批 5（G58）：可选注入程序基准；nil 保持既有行为（CWD 兜底）。
            let interpreter = Interpreter(programBase: programBase)
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            dup2(originalStdin, STDIN_FILENO)
            close(originalStdin)
            throw error
        }

        fflush(stdout)
        outPipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        dup2(originalStdin, STDIN_FILENO)
        close(originalStdin)
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - TDD#1 格式化输出（print 多参）

    /// 意图：print 接受多个参数，以空格连接输出，末尾换行；单参行为不变
    /// 推进性测量：print("a", "b", 3) == "a b 3\n"
    func testPrintMultipleArgs() throws {
        let source = try loadPiniFixture("testPrintMultipleArgs", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "a b 3\nsingle\n", "print 多参应以空格连接并换行")
        // 驳回性测量：末尾必须含换行，不得缺失
        XCTAssertNotEqual(output, "a b 3single", "print 多参末尾必须换行")
    }

    // MARK: - TDD#2 文件读取 readFile

    /// 意图：readFile(path) 读取文本文件全文并返回 String
    /// 推进性测量：读取预写临时文件，输出其内容与换行一致
    func testReadFile() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pini_read_\(UUID().uuidString).txt")
        try "hello file".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let source = try loadPiniFixture("testReadFile", filePath: #filePath).replacingOccurrences(of: "__PATH__", with: path)
        let output = try runProgram(source)
        XCTAssertEqual(output, "hello file\n", "readFile 应返回文件全文")
        // 驳回性测量：不得返回空内容
        XCTAssertNotEqual(output, "\n", "readFile 不应返回空内容")
    }

    // MARK: - TDD#3 文件写入 writeFile

    /// 意图：writeFile(path, content) 将文本写入文件（返回 null）
    /// 推进性测量：Pini 写文件后，Swift 侧读回内容一致
    func testWriteFile() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pini_write_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let source = try loadPiniFixture("testWriteFile", filePath: #filePath).replacingOccurrences(of: "__PATH__", with: path)
        _ = try runProgram(source)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, "written by pini", "writeFile 应将内容写入文件")
        // 驳回性测量：写入内容不得为空
        XCTAssertNotEqual(content, "", "writeFile 不得写入空内容")
    }

    // MARK: - TDD#4 标准输入 readLine

    /// 意图：readLine() 从 stdin 读取一行（去除换行）返回 String
    /// 推进性测量：注入 "world\n"，print(readLine()) 输出 "world\n"
    func testReadLine() throws {
        let source = try loadPiniFixture("testReadLine", filePath: #filePath)
        let output = try runProgram(source, stdin: "world\n")
        XCTAssertEqual(output, "world\n", "readLine 应读取 stdin 一行")
        // 驳回性测量：必须打印读取到的行，不得为空（此处 stdin 非空）
        XCTAssertNotEqual(output, "\n", "readLine 不得返回空输出")
    }

    // MARK: - TDD#5 错误与边界路径

    /// 意图：readFile 读取不存在的文件应抛出 RuntimeError.invalidOperation（不崩溃、不静默返回）
    /// 驳回性测量：错误类型必须精确匹配，而非其它错误
    func testReadFileMissingPathThrows()  throws {
        let missing = (NSTemporaryDirectory() as NSString).appendingPathComponent("pini_missing_\(UUID().uuidString).txt")
        let source = try loadPiniFixture("testReadFileMissingPathThrows", filePath: #filePath).replacingOccurrences(of: "__PATH__", with: missing)
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.invalidOperation = error else {
                XCTFail("应为 RuntimeError.invalidOperation，实际: \(error)")
                return
            }
        }
    }

    /// 意图：readLine 在空 stdin（EOF）时应返回空串，print 输出一个换行，不崩溃
    /// 推进性测量：注入空 stdin，输出 "\n"
    /// 驳回性测量：不得因 EOF 抛出运行时错误
    func testReadLineEOF() throws {
        let source = try loadPiniFixture("testReadLineEOF", filePath: #filePath)
        let output = try runProgram(source, stdin: "")
        XCTAssertEqual(output, "\n", "readLine 在 EOF 时应返回空串")
    }

    // MARK: - G58 IO 路径基准（批 5，方案 A 三段式 / ADR-030）

    /// 临时目录辅助：唯一路径 + 清理。
    private func makeTempDir(_ label: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_g58_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// 意图：无前缀相对路径相对**程序基准**解析（模块根情形），而非 CWD——
    /// 基准目录下有资源文件、CWD 下没有，读成功即证明走了基准。
    /// 推进性测量：readFile("res.txt") == 基准目录文件内容。
    func testUnprefixedPathResolvesProgramBase() throws {
        let base = try makeTempDir("base")
        try "模块资源".write(toFile: (base as NSString).appendingPathComponent("res.txt"),
                            atomically: true, encoding: .utf8)
        let source = """
        main|func() -> ():
            print(readFile("res.txt"))
            return
        """
        let output = try runProgram(source, programBase: base)
        XCTAssertEqual(output, "模块资源\n", "无前缀相对路径应相对程序基准解析")
    }

    /// 意图：无前缀相对路径写入同样落程序基准（writeFile 与 readFile 同一基准）。
    func testUnprefixedWriteLandsInProgramBase() throws {
        let base = try makeTempDir("write")
        let source = """
        main|func() -> ():
            writeFile("out.txt", "写入基准")
            return
        """
        _ = try runProgram(source, programBase: base)
        let landed = try String(contentsOfFile: (base as NSString).appendingPathComponent("out.txt"),
                                encoding: .utf8)
        XCTAssertEqual(landed, "写入基准", "writeFile 无前缀应落程序基准目录")
    }

    /// 意图：`./` 前缀相对**运行时 CWD**（用户/shell 视角），即使基准目录存在同名文件也不得误用基准——
    /// 这是 D-1 方案 A 的核心区分（CWD 通道与基准通道互不污染）。
    func testDotSlashResolvesRuntimeCWDNotBase() throws {
        let base = try makeTempDir("dotbase")
        let cwdDir = try makeTempDir("dotcwd")
        try "来自基准(不应读到)".write(toFile: (base as NSString).appendingPathComponent("f.txt"),
                                    atomically: true, encoding: .utf8)
        try "用户文件".write(toFile: (cwdDir as NSString).appendingPathComponent("f.txt"),
                            atomically: true, encoding: .utf8)

        let original = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(cwdDir))
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        let source = """
        main|func() -> ():
            print(readFile("./f.txt"))
            return
        """
        let output = try runProgram(source, programBase: base)
        XCTAssertEqual(output, "用户文件\n", "`./` 前缀应相对运行时 CWD，不得误用程序基准")
    }

    /// 意图：绝对路径完全不受基准影响（三段式第一段）。
    func testAbsolutePathUnaffectedByBase() throws {
        let base = try makeTempDir("absbase")
        let elsewhere = try makeTempDir("elsewhere")
        let target = (elsewhere as NSString).appendingPathComponent("abs.txt")
        try "绝对路径".write(toFile: target, atomically: true, encoding: .utf8)
        let source = """
        main|func() -> ():
            print(readFile("\(target)"))
            return
        """
        let output = try runProgram(source, programBase: base)
        XCTAssertEqual(output, "绝对路径\n", "绝对路径应原样解析")
    }

    /// 意图：moduleRoot() 返回注入的程序基准（绝对路径）；未注入时如实返回 CWD（不伪造模块根）。
    /// 推进性测量：moduleRoot() == 基准；nil 基准时 == 进程 CWD。
    func testModuleRootBuiltin() throws {
        let base = try makeTempDir("root")
        let source = "main|func() -> ():\n    print(moduleRoot())\n    return\n"
        let withBase = try runProgram(source, programBase: base)
        XCTAssertEqual(withBase, base + "\n", "moduleRoot() 应返回注入的程序基准")

        let withoutBase = try runProgram(source)
        XCTAssertEqual(withoutBase, FileManager.default.currentDirectoryPath + "\n",
                       "未注入基准时 moduleRoot() 应如实返回 CWD")
    }
}

import XCTest
import PiniCore
import Foundation

/// 基础 IO 行为测试
/// 格式化输出（print 多参）、文件读写（readFile/writeFile）、标准输入（readLine）。
/// 全部走真实解释器公共接口，不 mock 内部实现；stdout 捕获，stdin **统一接管**为注入管道
/// （确定性环境——空串即 EOF，不依赖测试进程的真实 stdin，交互终端下也不会阻塞）。
final class IOTests: XCTestCase {

    private func runProgram(_ source: String, stdin: String = "") throws -> String {
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
            let interpreter = Interpreter()
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
}

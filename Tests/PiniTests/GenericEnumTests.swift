import XCTest
import PiniCore
import Foundation

/// 泛型枚举特化路径（闭合架构风险 R1）。
/// 此前类型系统仅支持泛型结构体（defineGenericStruct），泛型枚举（如 Result<T,E> / Future<T,Error>）无注册与特化路径。
/// 本测试验证：泛型枚举可声明、可携带不同 T/E 实例化、match 进入 ok/err 分支取回关联值、实参个数错误被拒。
final class GenericEnumTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "generic_enum_test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "generic_enum_test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func checkCollecting(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "generic_enum_test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "generic_enum_test.pini")
        let module = try! parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    /// 意图：泛型枚举 Result<T,E> 可声明，ok(42) 经 ok<I32,String>(42) 构造后 match 进入 ok 分支取回 42。
    /// 推进性测量：输出精确为 "42\n"。
    func testGenericEnumConstructionAndMatch() throws {
        let source = """
        [结果<T, E>]
        ok(T)
        err(E)

        main|func() -> ()
            var a = ok<I32, String>(42)
            match a:
                case ok(v):
                    print(v)
                    return
                case err(e):
                    print(e)
                    return
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "42\n", "泛型枚举 ok 分支应取回关联值 42")
    }

    /// 意图：err 分支携带错误值，match 进入 err 分支取回。
    /// 推进性测量：输出精确为 "boom\n"。
    func testGenericEnumErrBranch() throws {
        let source = """
        [结果<T, E>]
        ok(T)
        err(E)

        main|func() -> ()
            var e = err<I32, String>("boom")
            match e:
                case err(m):
                    print(m)
                    return
                case ok(v):
                    print(v)
                    return
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "boom\n", "泛型枚举 err 分支应取回关联值 boom")
    }

    /// 意图：同一泛型枚举名携带不同 T/E 实例化（满<I32> 与 空<String>），各自 match 取回正确值。
    /// 推进性测量：输出精确为 "5\nnone\n"。
    func testGenericEnumDistinctSpecializations() throws {
        let source = """
        [盒子<T>]
        满(T)
        空()

        main|func() -> ()
            var x = 满<I32>(5)
            match x:
                case 满(v):
                    print(v)
                case 空:
                    print(0)
            var y = 空<String>()
            match y:
                case 空:
                    print("none")
                case 满(v):
                    print(v)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "5\nnone\n", "两种特化的泛型枚举应各自取回正确关联值")
    }

    /// 意图：构造泛型枚举时类型实参个数与声明不符必须抛错（防止退化成静默构造）。
    /// 推进性测量：抛出 RuntimeError 且原因含「实参个数不符」。
    func testGenericEnumArgumentCountMismatch() {
        let source = """
        [结果<T, E>]
        ok(T)
        err(E)

        main|func() -> ()
            var a = ok<I32>(42)
            return
        """
        XCTAssertThrowsError(try runProgram(source), "泛型枚举实参个数不符应抛错") { error in
            guard case RuntimeError.invalidOperation(let reason, _) = error,
                  reason.contains("实参个数不符") else {
                XCTFail("应为泛型枚举实参个数不符的 RuntimeError，实际: \(error)")
                return
            }
        }
    }

    /// 意图：类型层能识别泛型枚举声明与 match，不产生假阳性诊断（闭合 R1 的类型层一半）。
    /// 推进性测量：checkCollecting 返回空数组。
    func testGenericEnumTypeChecksNoDiagnostics() throws {
        let source = """
        [结果<T, E>]
        ok(T)
        err(E)

        main|func() -> ()
            var a = ok<I32, String>(42)
            match a:
                case ok(v):
                    print(v)
                    return
                case err(e):
                    print(e)
                    return
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "泛型枚举声明+match 应无类型错误，实际: \(diagnostics)")
    }
}

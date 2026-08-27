import XCTest
@testable import PiniCore

/// 运行时单态化（T10）端到端验证：泛型结构体在运行时能真正构造为特化实例，
/// 且成员方法派发到特化类型名（而非模板名），此前 `genericConstruct` 直接抛错。
final class GenericRuntimeTests: XCTestCase {

    /// 驱动链路：Lexer → Parser → Interpreter（与 CLI run 同构，绕过静态检查以专注运行时）。
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
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

    /// 意图：单类型参数泛型结构体构造后，成员方法需在「特化类型名」上派发并返回正确值。
    /// 推进性测量：输出精确为 "ok\n"（方法确实在特化实例上执行，而非静默无操作）。
    /// 驳回性测量：T10 修复前 `genericConstruct` 抛 RuntimeError，此处必须成功执行。
    func testGenericStructConstructionAndMethodDispatch() throws {
        let source = """
        (框<T>)

        ((框<T>))
        标识|self() -> (String,)
            return "ok"
        main|func() -> ()
            let f = 框<I32>()
            print(f.标识())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "ok\n", "特化实例成员方法应派发并返回 'ok'")
    }

    /// 意图：双类型参数泛型结构体（<I32, String>）在运行时能正确单态化构造。
    /// 推进性测量：输出精确为 "pair\n"。
    func testGenericStructTwoTypeParamsConstruction() throws {
        let source = """
        (对<K, V>)

        ((对<K, V>))
        标记|self() -> (String,)
            return "pair"
        main|func() -> ()
            let p = 对<I32, String>()
            print(p.标记())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "pair\n", "双类型参数特化实例应成功构造并派发方法")
    }

    /// 意图：泛型字段经方法读取在特化实例上不抛错（默认初值 0）。
    /// 推进性测量：输出精确为 "0\n"（字段读取路径在运行时走通）。
    func testGenericStructFieldReadViaMethod() throws {
        let source = """
        (计数器<T>)
        计数: I32 = 0

        ((计数器<T>))
        读|self() -> (I32,)
            return self.计数
        main|func() -> ()
            let c = 计数器<String>()
            print(c.读())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "0\n", "特化实例字段经方法读取应返回默认初值 0")
    }

    /// 意图：未定义的泛型类型构造必须仍抛错，防止 T10 修复把 `genericConstruct` 退化成静默返回 null。
    /// 推进性测量：抛出 RuntimeError（含「未定义的泛型类型」）。
    /// 驳回性测量：若实现退化为无脑返回 structInstance，此测试会失败。
    func testUndefinedGenericTypeStillThrows() {
        let source = """
        main|func() -> ()
            let x = 不存在<I32>()
            return
        """
        XCTAssertThrowsError(try runProgram(source), "未定义的泛型类型构造应抛错") { error in
            guard case RuntimeError.invalidOperation(let reason, _) = error,
                  reason.contains("未定义的泛型类型") else {
                XCTFail("应为未定义泛型类型的 RuntimeError，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 泛型函数调用点（P3-0 ① 端到端）

    /// 意图：泛型函数 identity<T> 在调用点单态化后立即执行，返回特化后的值。
    /// 推进性测量：输出精确为 "42\n"。
    /// 驳回性测量：若 genericConstruct 仅返回未执行的函数值（修复前语义），print 会输出函数值而非 42。
    func testGenericFunctionCallRuntime() throws {
        let source = """
        identity|func<T>(x: T) -> (T,)
            return x
        main|func() -> ()
            print(identity<I32>(x: 42))
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "42\n", "泛型函数调用应返回特化后的值 42")
    }

    /// 意图：泛型函数多次不同特化调用互不污染（I32 与 String 各自正确）。
    /// 推进性测量：输出精确为 "7\nhi\n"。
    func testGenericFunctionMultipleSpecializations() throws {
        let source = """
        identity|func<T>(x: T) -> (T,)
            return x
        main|func() -> ()
            print(identity<I32>(x: 7))
            print(identity<String>(x: "hi"))
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "7\nhi\n", "不同特化的泛型函数调用应各自返回正确值")
    }
}

import XCTest
import PiniCore
import Foundation

/// 歧义 case 裸名构造消歧测试（ADR-026 D1）
/// 意图：跨枚举同名 case 的裸名构造按期望类型/实参类型解析，而非按注册序猜测
final class AmbiguousCaseResolutionTests: XCTestCase {
    /// 意图：同名 case 实参类型可区分时，裸名构造各自命中正确父枚举
    /// 推进性测量：两个构造都成功执行（此前歧义名被排除出全局函数表，运行期无路可走）
    /// 驳回性测量：任一构造报「无匹配候选」或 undefined variable 均不合格
    func testBareConstructionResolvesByArgType() throws {
        let source = """
[ShpA]
mk(v: I32,)

[ShpB]
mk(v: String,)

main|func() -> ()
    print(mk(v: 7))
    print(mk(v: "s"))
    return
"""
        _ = try runSource(source)
    }

    /// 意图：同名 case 元数不同时，裸名构造按元数消歧（E4-005 错误参量数不再误报）
    /// 推进性测量：两种元数的构造都通过
    /// 驳回性测量：arity 报错即不合格
    func testAmbiguousArityResolves() throws {
        let source = """
[BoxA]
foo(a: I32,)

[BoxB]
foo(x: String, y: String,)

main|func() -> ()
    print(foo(1))
    print(foo("a", "b"))
    return
"""
        _ = try runSource(source)
    }

    private func runSource(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "ambiguous.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "ambiguous.pini")
        let module = try parser.parseModule()
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: Error? = nil
        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let e = thrown {
            throw e
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

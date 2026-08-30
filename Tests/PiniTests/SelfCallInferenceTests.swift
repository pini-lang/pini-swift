import XCTest
import PiniCore
import Foundation

/// self 调用类型传播测试（ADR-026 D3，自举缺口 G-P8）
/// 意图：方法体内 self 接收者的成员调用按声明签名传播类型，与外部接收者一致
final class SelfCallInferenceTests: XCTestCase {
    /// 意图：`let v = self.get()` 绑定获得声明返回类型，后续比较不再退化 Any 报 E4-001
    /// 推进性测量：方法体内 self 调用绑定 + 字面量比较照常运行
    /// 驳回性测量：E4-001 expected-Any 类报错即不合格
    func testSelfMethodCallTypePropagates() throws {
        let source = """
{box}
num: I32 = 0

{{box}}
get|self() -> (I32,)
    return self.num

probe|self() -> ()
    let v = self.get()
    if v == 0:
        self.num = 1
    return

main|func() -> ()
    let b = box()
    b.probe()
    print(b.get())
    return
"""
        let out = try runSource(source)
        XCTAssertTrue(out.contains("1"), out)
    }

    /// 意图：外部接收者路径不受影响（回归护栏）
    /// 推进性测量：同一对象的外部方法调用结果比较照常
    /// 驳回性测量：外部路径退化报错即不合格
    func testExternalReceiverStillWorks() throws {
        let source = """
{box}
num: I32 = 0

{{box}}
get|self() -> (I32,)
    return self.num

main|func() -> ()
    let b = box()
    let v = b.get()
    if v == 0:
        print("zero")
    return
"""
        let out = try runSource(source)
        XCTAssertTrue(out.contains("zero"), out)
    }

    /// 意图：无字段类型的扩展方法同样拥有 self（此前 self 注册以「有字段」为前提，
    /// 无字段类型的方法体内 self 调用退化 Any）
    /// 推进性测量：check 通过并输出 y
    /// 驳回性测量：E4-001 expected-Any 报错均不合格
    func testFieldlessObjectSelfCallPropagates() throws {
        let source = """
{o}

{{o}}
k_at|self(k: I32,) -> (String,)
    return "s"
use1|self() -> (String,)
    let k = self.k_at(0)
    if k == "s":
        return "y"
    return "n"

main|func() -> ()
    var a = o()
    print(a.use1())
    return
"""
        let out = try runSource(source)
        XCTAssertTrue(out.contains("y"), out)
    }

    private func runSource(_ source: String) throws -> String {
        // G-P8 复盘：本 harness 此前不跑 checker——E4-001 永不触发，测试空转
        // （假绿）。类型类测试的 harness 必须先 check 再 run。
        let lexer = Lexer(source: source, fileName: "selfcall.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "selfcall.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
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

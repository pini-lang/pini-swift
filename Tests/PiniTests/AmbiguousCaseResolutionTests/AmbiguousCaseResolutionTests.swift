import XCTest
import PiniCore
import Foundation

/// 歧义 case 裸名构造消歧测试（ADR-026 D1）
/// 意图：跨枚举同名 case 的裸名构造按期望类型/实参类型解析，而非按注册序猜测
final class AmbiguousCaseResolutionTests: XCTestCase {
    /// 意图：同名 case 实参类型可区分时，裸名构造各自命中正确父枚举
    /// 推进性测量：两个构造都成功执行（此前歧义名被排除出全局函数表，运行期无路可走）
    /// 驳回性测量：任一构造报「无匹配候选」或 undefined variable 均不合格
    /// 意图：歧义裸名构造无期望类型 → check 期拒绝并要求限定形式
    /// （ADR-026 D1 静态收敛版：运行期动态消歧已移除，2026-08-30 裁决）
    /// 推进性测量：check 期报错
    /// 驳回性测量：按实参类型静默解析均不合格
    func testBareConstructionRequiresQualification() throws {
        let source = try loadPiniFixture("testBareConstructionRequiresQualification", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "歧义裸名构造应被 check 拒绝")
    }

    /// 意图：同名 case 元数不同时，裸名构造按元数消歧（E4-005 错误参量数不再误报）
    /// 推进性测量：两种元数的构造都通过
    /// 驳回性测量：arity 报错即不合格
    /// 意图：同名 case 元数不同、无期望类型 → check 期拒绝（元数不再是消歧依据，
    /// ADR-026 D1 静态收敛版，2026-08-30 裁决）
    /// 推进性测量：check 期报错
    /// 驳回性测量：按元数静默解析均不合格
    func testAmbiguousArityRequiresQualification() throws {
        let source = try loadPiniFixture("testAmbiguousArityRequiresQualification", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "歧义裸名构造应被 check 拒绝")
    }

    /// 意图：match 模式按 scrutinee 类型解析（ADR-026 D2）——同名 case 不同元数时
    /// 各自绑定正确父枚举的字段（旧代码按单值反查绑错父枚举 → E4-005）
    /// 推进性测量：两个 match 的解构绑定都成功并输出正确值
    /// 驳回性测量：E4-005 arity 报错或绑定错值均不合格
    func testMatchResolvesByScrutineeType() throws {
        let source = try loadPiniFixture("testMatchResolvesByScrutineeType", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("5"), out)
        XCTAssertTrue(out.contains("7"), out)
    }

    /// 意图：裸名 case 构造且父枚举唯一时推断为父枚举类型（ADR-026 D5 缩窄版，G-P3）——
    /// case 值可在期望父枚举的 return 位置通过类型检查（此前 E4-001 expected-expr-got-case）
    /// 推进性测量：构造成功并输出正确字段值
    /// 驳回性测量：E2/E4 类型报错均不合格
    func testBareUniqueCaseConstructionInfersParentType() throws {
        let source = try loadPiniFixture("testBareUniqueCaseConstructionInfersParentType", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("9"), out)
    }

    private func runSource(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "ambiguous.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "ambiguous.pini")
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

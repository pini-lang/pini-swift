import XCTest
import PiniCore
import Foundation

/// 点号用例构造测试（proposal-dot-case-construction，D-1：与 Swift UnresolvedMemberExpr 同构）
/// 意图：前导点 `.caseName` = 成员意图标记——期望类型优先决议、不受本地位遮蔽影响、
/// 内建 Optional 直达、歧义无期望类型静态拒绝、LLVM 歧义显式 unsupported
/// 推进性测量：各场景按预期构造/拒绝
/// 驳回性测量：静默解析到错误父枚举、本地遮蔽劫持成员解析均不合格
final class DotCaseConstructionTests: XCTestCase {

    /// 意图：唯一名点号构造 `.轮子(4)` 直接构造（成员意图经构造器注册表，不经局部环境）
    /// 推进性测量：构造成功并输出用例值
    /// 驳回性测量：undefined/不可调用报错均不合格
    func testDotCaseUniqueConstruction() throws {
        let source = try loadPiniFixture("testDotCaseUniqueConstruction", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("轮子(4)"), out)
    }

    /// 意图：歧义名点号构造按期望类型标注静态决议（varDecl 标注位 + 实参位）
    /// 推进性测量：两处构造均命中正确父枚举（标注 形状 → 形状.圆）
    /// 驳回性测量：「缺少可解析的期望类型」或串味到 几何.圆 均不合格
    func testDotCaseAmbiguousResolvesByAnnotation() throws {
        let source = try loadPiniFixture("testDotCaseAmbiguousResolvesByAnnotation", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("3"), out)
        XCTAssertTrue(out.contains("2.5"), out)
    }

    /// 意图：歧义名点号构造无期望类型 → check 期拒绝（D1 第 3 档同轨）
    /// 推进性测量：check 期报错
    /// 驳回性测量：按注册序静默解析均不合格
    func testDotCaseAmbiguousNoExpectedTypeRejected() throws {
        let source = try loadPiniFixture("testDotCaseAmbiguousNoExpectedTypeRejected", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "歧义点号构造应被 check 拒绝")
    }

    /// 意图：内建 Optional 的 `.none` / `.some(7)` 直达（用户枚举候选为空时）
    /// 推进性测量：构造成功并输出 none / some(7)
    /// 驳回性测量：undefined variable 或 arity 报错均不合格
    func testDotCaseNoneAndSome() throws {
        let source = try loadPiniFixture("testDotCaseNoneAndSome", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("none"), out)
        XCTAssertTrue(out.contains("some(7)"), out)
    }

    /// 意图：点号构造的名字不是任何枚举用例 → check 期拒绝（成员意图落空）
    /// 推进性测量：check 期报错
    /// 驳回性测量：静默放行到运行期均不合格
    func testDotCaseUnknownNameRejected() throws {
        let source = try loadPiniFixture("testDotCaseUnknownNameRejected", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "未知点号构造应被 check 拒绝")
    }

    /// 意图：成员意图不受本地位遮蔽影响——本地变量与 case 同名时，`.caseName(...)`
    /// 仍构造用例（裸名构造在此场景会被局部变量劫持，这是点号形态的语义差异点）
    /// 推进性测量：构造成功并输出用例值
    /// 驳回性测量：解析到局部变量（not callable）均不合格
    func testDotCaseIgnoresLocalShadowing() throws {
        let source = try loadPiniFixture("testDotCaseIgnoresLocalShadowing", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("轮子(4)"), out)
    }

    /// 意图：LLVM 端歧义名点号构造显式 unsupported（D-3 裁决：报错 + 立案，解释器可用）
    /// 推进性测量：IR 生成期报 unsupportedFeature（E6-004 通路）
    /// 驳回性测量：静默解析到任一父枚举均不合格
    func testDotCaseAmbiguousUnsupportedViaIRGen() throws {
        let source = try loadPiniFixture("testDotCaseAmbiguousUnsupportedViaIRGen", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "dotcase.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "dotcase.pini")
        let module = try parser.parseModule()
        XCTAssertThrowsError(try IRGenerator().generate(module: module)) { error in
            guard case IRGenError.unsupportedFeature = error else {
                XCTFail("应为 unsupportedFeature，实际: \(error)")
                return
            }
        }
    }

    private func runSource(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "dotcase.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "dotcase.pini")
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

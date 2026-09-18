import XCTest
import PiniCore
import Foundation

/// 用户扩展方法覆盖内建成员方法（H-3，2026-08-31 落地）：
///   内建类型（String/Array）值的成员派发为三级——**用户扩展 > 语言内标准库 > 宿主原生**。
///   用户扩展按名匹配（非按签名），既可覆盖同名内建成员，也可新增内建表没有的方法。
///   后端面（**边界已关闭**，`G-6a`，2026-09-18）：扩展方法降载成普通 `module.functions`，
///   HIR 与 LLVM 两条通道都按名分派——实测 `emit` rc=0 且 IR 含 `方法__类型`，`run-llvm` 端到端执行正确。
/// 驱动链路与 CLI `pini run` 同构：stdout 捕获（确定性环境，dup2 接管）。
final class BuiltinOverrideTests: XCTestCase {

    /// 与 IOTests 同构的运行 harness：真实引擎 + stdout 收集（`ProgramRunner`）。
    ///
    /// `G-5` 曾把本文件判为「不可换腿」，依据是实测而非推断：换成 HIR 后 6 条用例红 4 条 ——
    /// `testArrayNewMethodOverride` / `testStringNewMethodAddition` 在**降载期**即被拒
    /// （`HIR lowering error … method 'len' calls are later grids`），而
    /// `testStringContainsOverride` / `testUnoverriddenStillBuiltin` 输出的
    /// 是**内建行为**（`true`）而期望**用户扩展行为**（`false`）——
    /// 即 HIR 侧**要么不实现、要么不遵守「用户扩展 > 语言内标准库 > 宿主原生」的三级派发**。
    ///
    /// ⇒ 当时本文件的 `Interpreter` **不是参照臂，而是被测能力的唯一实现** ——
    /// 它测的是「内建类型的用户扩展方法」（H-3），AST 引擎支持、HIR 引擎不支持。
    /// `G-6a` 把三级派发补到 HIR 之后，本 harness 随之换腿（该批实测两个后端都已可用），
    /// 本条分类结论因此只作**历史**保留：那台引擎已在 `G-6c` 退役。
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let runner = ProgramRunner()
        var segments: [String] = []
        runner.outputSink = { segments.append($0 + "\n") }
        try runner.run(module: module)
        return segments.joined(separator: "")
    }

    private func runFixture(_ name: String) throws -> String {
        try runProgram(try loadPiniFixture(name, filePath: #filePath) as String)
    }

    /// 意图：用户 String.contains 扩展覆盖内建成员——返回用户实现结果 false（原为内建 true）。
    func testStringContainsOverride() throws {
        let out = try runFixture("testStringContainsOverride")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "false",
                       "用户扩展应覆盖同名内建成员方法（H-3 用户优先）")
    }

    /// 意图：用户 Array.len 扩展（内建表没有的名字）作为新方法可用。
    func testArrayNewMethodOverride() throws {
        let out = try runFixture("testArrayNewMethodOverride")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "999",
                       "用户扩展可为内建类型新增方法（原被内建表 guard 拒绝）")
    }

    /// 意图：用户新增方法体内调用未覆盖的内建成员（self.upper()）正常派发。
    func testStringNewMethodAddition() throws {
        let out = try runFixture("testStringNewMethodAddition")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ABC!",
                       "用户新增方法应可用，且体内未覆盖成员仍走内建")
    }

    /// 意图：覆盖与非覆盖共存——contains 命中用户实现，upper 仍命中内建。
    func testUnoverriddenStillBuiltin() throws {
        let out = try runFixture("testUnoverriddenStillBuiltin")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "false\nHELLO",
                       "仅同名成员被覆盖，其余成员派发不变")
    }

    /// 意图：R-c 回归锁——与内建成员同名的自由函数按名调用命中用户函数（true），
    /// 无覆盖场景下成员调用命中内建（true），两条通道互不干扰。
    func testFreeFunctionSameNameRegression() throws {
        let out = try runFixture("testFreeFunctionSameNameRegression")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "true\ntrue",
                       "自由函数通道与成员通道互不影响")
    }

    /// **事实已变**（LR-4 `G-6a`，2026-09-18）：降载层现在**接受**内建类型的用户扩展方法，
    /// 原断言「`HIRLowerer` 抛 `E6-004`」不再成立，改为断言**降载成功**。
    ///
    /// 该边界（规范构造级索引表里 H-3 那行的「IR 后端对内建类型用户扩展不支持」）已在本批**关闭**：
    /// 扩展方法降载成普通 `module.functions`（IR 名 `方法__类型`），两个后端都按名分派 ⇒
    /// **无残留后端缺口** —— 区别于 `IRExecutionTests` 的字符内建那类「降载通了、LLVM 仍缺运行时段」。
    /// 实测（2026-09-18，当前构建）：`pini emit` 本夹具 **rc=0** 且 IR 含 `shout__String`；
    /// `pini run-llvm` **端到端输出 `!!!`**；覆盖支（`testStringContainsOverride`）得 `false`。
    ///
    /// 夹具名沿用发现时的 `testIRUnsupportedForBuiltinExtension`（与 `.pini` 同名，
    /// 与 `testIsLetterLowersAfterG2a` 同型：改名的是用例，不是夹具）。
    func testBuiltinExtensionLowersAfterG6a() throws {
        let source = try loadPiniFixture("testIRUnsupportedForBuiltinExtension", filePath: #filePath)
        let tokens = try Lexer(source: source, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        XCTAssertNoThrow(try HIRLowerer.lower(module: module, typeInference: nil))
    }
}

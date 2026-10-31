import Foundation
import Foundation
import Testing

@testable import PiniCore

/// 后端接缝：一条通道要接进 CLI，靠的是这份协议、这张注册表与一张能力表。
/// 判据钉在「接得上」的三件事上：名字与注册表不漂移、能力声明成表、哑后端能消费全部节点。
@Suite("后端接缝")
struct BackendSeamTests: Sendable {

    private func lowered(_ source: String) throws -> IRModule {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    @Test("注册表里的名字与后端自报的名字一致")
    func registryNamesMatchTheBackendsOwn() throws {
        #expect(!BackendRegistry.entries.isEmpty)
        for entry in BackendRegistry.entries {
            let backend = try #require(BackendRegistry.make(entry.identifier))
            #expect(type(of: backend).identifier == entry.identifier)
        }
    }

    @Test("认不出的名字返回 nil —— 不猜一个近似通道")
    func anUnknownNameYieldsNil() {
        #expect(BackendRegistry.make("no-such-backend") == nil)
        #expect(BackendRegistry.make("") == nil)
    }

    /// 默认通道必须是产目标码的那一条：`pini emit` 不带 `--backend` 时行为不变。
    @Test("默认通道产目标码")
    func theDefaultBackendProducesMachineCode() throws {
        let backend = try #require(BackendRegistry.make(BackendRegistry.defaultIdentifier))
        #expect(type(of: backend).capabilities.output == .machineCode)
    }

    /// 能力声明是一张表：族名与契约小节同名，未支持的族能一次列全。
    @Test("能力声明按族表态，未支持项可枚举")
    func capabilitiesAreATable() {
        #expect(BackendCapabilities.Family.allCases.count == 14)
        let partial = BackendCapabilities(output: .machineCode, supported: [.scalars, .calls])
        #expect(partial.unsupported.count == 12)
        #expect(!partial.supports(.concurrency))
        #expect(BackendCapabilities.full.unsupported.isEmpty)
    }

    /// 哑后端的价值：`IRStmt` 的 17 条与 `IRExpr` 的 53 条都被分派过，没有节点被漏掉。
    /// 这条用一份同时含控制流、集合、字符串与闭包的语料走一遍。
    @Test("哑后端消费全部节点并给出结构转储")
    func theDumbBackendConsumesEveryNode() throws {
        let module = try lowered(
            #"""
            mark|func() -> ():
                print("m")
                return

            main|func() -> ():
                let xs: Array<I32> = [1, 2, 3]
                var total = 0
                for (x,) in xs:
                    if x > 1:
                        total = total + x
                    else:
                        continue
                defer mark()
                let name = "pini"
                print(name.upper(), total, len(xs))
                return
            """#)
        let dump = JSONBackend().emit(module: module)
        #expect(dump.hasPrefix("{\"backend\":\"json\""))
        for kind in ["allocVar", "storeVar", "forInStmt", "ifStmt", "continueStmt", "deferStmt",
                     "exprStmt", "returnStmt"] {
            #expect(dump.contains("\"kind\":\"\(kind)\""), "转储里缺 \(kind)")
        }
        // 转储只记语句根节点的表达式名；子表达式由 `exprKind` 的穷尽分派保证被处理（编译期），
        // 不在这里逐层展开 —— 展开会让转储变成第二份节点树。
        for expr in ["arrayLiteral", "binary", "stringConst", "printMulti"] {
            // 两种出现形态：带字段名（`init=…`）与整条 detail（`exprStmt` 的 detail 就是表达式名）。
            #expect(dump.contains("=\(expr)") || dump.contains("detail\":\"\(expr)\""),
                    "转储里缺表达式 \(expr)")
        }
    }

    /// 转储要能被机器读：断言它是合法 JSON 的最省事方式是让 Foundation 解析一次。
    @Test("转储是合法 JSON")
    func theDumpIsValidJSON() throws {
        let module = try lowered(
            #"""
            main|func() -> ():
                print("a\"b")
                return
            """#)
        let dump = JSONBackend().emit(module: module)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any])
        #expect(parsed["backend"] as? String == "json")
        #expect((parsed["functions"] as? [Any])?.count == 1)
    }

    /// 换通道不该改变「能不能编过」以外的东西：两条通道对同一模块都必须给出非空输出。
    @Test("两条通道对同一模块都产出非空文本")
    func bothBackendsEmitSomething() throws {
        let module = try lowered(
            #"""
            main|func() -> ():
                let xs: Array<I32> = [1, 2]
                print(len(xs))
                return
            """#)
        for entry in BackendRegistry.entries {
            let backend = try #require(BackendRegistry.make(entry.identifier))
            #expect(!backend.emit(module: module).isEmpty, "\(entry.identifier) 产出了空文本")
        }
    }
}

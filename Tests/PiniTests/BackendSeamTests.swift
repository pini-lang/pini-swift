import Foundation
import Foundation
import Testing
import PiniSyntax

@testable import PiniCore
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackendLLVM

/// 后端接缝：一条通道要接进 CLI，靠的是这份协议、这张注册表与一张能力表。
/// 判据钉在「接得上」的三件事上：名字与注册表不漂移、能力声明成表、哑后端能消费全部节点。
@Suite("后端接缝")
struct BackendSeamTests: Sendable, PiniSourceLowering {

    @Test("注册表里的名字与后端自报的名字一致")
    func registryNamesMatchTheBackendsOwn() throws {
        #expect(!Backends.registry.entries.isEmpty)
        for entry in Backends.registry.entries {
            let backend = try #require(Backends.registry.make(entry.identifier))
            #expect(type(of: backend).identifier == entry.identifier)
        }
    }

    @Test("认不出的名字返回 nil —— 不猜一个近似通道")
    func anUnknownNameYieldsNil() {
        #expect(Backends.registry.make("no-such-backend") == nil)
        #expect(Backends.registry.make("") == nil)
    }

    /// 默认通道必须是产目标码的那一条：`pini emit` 不带 `--backend` 时行为不变。
    @Test("默认通道产目标码")
    func theDefaultBackendProducesMachineCode() throws {
        let backend = try #require(Backends.registry.make(Backends.registry.defaultIdentifier))
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
        let dump = try JSONBackend().emit(module: module)
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
        let dump = try JSONBackend().emit(module: module)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any])
        #expect(parsed["backend"] as? String == "json")
        #expect((parsed["functions"] as? [Any])?.count == 1)
    }

    /// 换通道不该改变「能不能编过」以外的东西：每条通道对同一模块都必须给出非空输出。
    /// 样例取各通道能力声明的交集（标量与变量），故一条只认子集的通道也能参与这条判据。
    @Test("每条通道对同一模块都产出非空文本")
    func everyBackendEmitsSomething() throws {
        /// 模块带一个 C 导出块：头文件通道的前提是发布面存在，没有它该通道本就该拒。
        let module = try lowered(
            #"""
            seam_value() -> (I32,):
                return 7

            [seam|c]
            seam_get = seam_value

            main|func() -> ():
                var n = 1
                n = n + 2
                print(n)
                return
            """#)
        for entry in Backends.registry.entries {
            let backend = try #require(Backends.registry.make(entry.identifier))
            #expect(try !backend.emit(module: module).isEmpty, "\(entry.identifier) 产出了空文本")
        }
    }

    /// 搬不动的元素类型必须是**拒绝**，不是崩溃：`Array<I64>` 的解释器臂跑得通，
    /// LLVM 臂没有 I64 的装箱 ABI —— 这条判据盯的是「用户拿到诊断还是拿到一个进程信号」。
    @Test("元素类型没有装箱 ABI 时抛 BackendError")
    func unboxableElementRefuses() throws {
        let module = try lowered(
            #"""
            main|func() -> ():
                var x: I64 = 7
                var a = [x, x]
                print(a[0])
                return
            """#)
        do {
            _ = try IREmitter().emit(module: module)
            #expect(Bool(false), "应当拒绝")
        } catch let refusal as BackendError {
            #expect(refusal.family == .collections)
            #expect(refusal.node == "arrayLiteral")
            #expect(refusal.reason.contains("i64"))
        } catch {
            #expect(Bool(false), "抛的不是 BackendError：\(error)")
        }
    }
}

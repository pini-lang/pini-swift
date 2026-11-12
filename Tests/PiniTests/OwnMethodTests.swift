import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// 本型方法以类型名为接收者：签名表与实例表分道，IR 名独立，方法体不带 self。
struct OwnMethodTests: Sendable, PiniSourceLowering {

    private func runLines(_ source: String) throws -> [String] {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    @Test("四类载体的本型方法按类型名静态派发")
    func fourCarriers() throws {
        let source = #"""
        (点)
        x: I32 = 0

        ((点))
        取数|own() -> (I32,):
            return 7

        {计}
        n: I32 = 0

        {{计}}
        取数|own() -> (I32,):
            return 2

        [配置|given]
        v: I32 = 5

        [[配置]]
        取数|own() -> (I32,):
            return 9

        [形状]
        圆(I32,)
        方(I32,)

        ((形状))
        取数|own() -> (I32,):
            return 3

        main|func() -> ():
            print(点.取数())
            print(计.取数())
            print(配置.取数())
            print(形状.取数())
            return
        """#
        #expect(try runLines(source) == ["7", "2", "9", "3"])
    }

    @Test("本型方法降载成不带 self 的顶层函数")
    func loweredShape() throws {
        let source = #"""
        (点)
        x: I32 = 0

        ((点))
        取数|own() -> (I32,):
            return 7

        main|func() -> ():
            print(点.取数())
            return
        """#
        let (module, checker) = try typeChecked(source)
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        let own = lowered.functions.first { $0.name == IRName.ownMethod("取数", on: "点") }
        #expect(own != nil)
        #expect(own?.params.isEmpty == true)
        #expect(own?.displayName == "点.取数")
    }

    @Test("类型上无此本型方法时点名类型与成员")
    func missingOwnMethod() throws {
        let source = #"""
        (点)
        x: I32 = 0

        main|func() -> ():
            print(点.取数())
            return
        """#
        let result = failure { _ = try typeChecked(source) }
        #expect(result?.code == "E4-009")
        #expect(result?.message.contains("点") == true)
    }

    /// 本型方法参与的同名在类型检查之前拒掉：错误落在声明期，不留给后端重定义。
    @Test("同一类型两处扩展块同名本型方法在声明期被拒")
    func duplicateOwnMethodRejectedAtDeclaration() throws {
        let source = #"""
        (点)
        x: I32 = 0

        ((点))
        取数|own() -> (I32,):
            return 7

        ((点))
        取数|own() -> (I32,):
            return 8

        main|func() -> ():
            print(点.取数())
            return
        """#
        let result = failure { _ = try typeChecked(source) }
        #expect(result?.code == "E3-004")
        #expect(result?.message.contains("取数") == true)
    }

    @Test("本型方法与实例方法同名在声明期被拒")
    func ownAndInstanceMethodSameNameRejected() throws {
        let source = #"""
        (点)
        x: I32 = 0

        ((点))
        取数|self() -> (I32,):
            return 1

        ((点))
        取数|own() -> (I32,):
            return 7

        main|func() -> ():
            print(点.取数())
            return
        """#
        let result = failure { _ = try typeChecked(source) }
        #expect(result?.code == "E3-004")
    }

    @Test("本型方法名与枚举用例名相同在声明期被拒")
    func ownMethodNameClashingWithEnumCaseRejected() throws {
        let source = #"""
        [形状]
        圆(I32,)
        方(I32,)

        ((形状))
        圆|own() -> (I32,):
            return 3

        main|func() -> ():
            print(形状.圆())
            return
        """#
        let result = failure { _ = try typeChecked(source) }
        #expect(result?.code == "E3-004")
        #expect(result?.message.contains("圆") == true)
    }
}

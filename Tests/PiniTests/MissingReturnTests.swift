import Foundation
import PiniSemantics
import PiniSyntax
import Testing

/// 值返回体的出口完整性：每条路径要么 `return`，要么末句交出值。
/// 判据分两侧：该报的报（尾句是语句、if 无 else、while 收尾、闭包里同样成立），该放的放（尾表达式、分支齐全、match 穷尽）。
@Suite("缺返回", .serialized)
struct MissingReturnTests: PiniSourceLowering {

    private func diagnosticCode(_ source: String) -> String? {
        do {
            _ = try typeChecked(source)
            return nil
        } catch {
            return (error as? any DiagnosticProviding)?.diagnosticCode
        }
    }

    @Test("尾表达式交值，放行")
    func trailingExpressionDelivers() {
        let source = #"""
        取|func() -> (I32,):
            40 + 2
        """#
        #expect(diagnosticCode(source) == nil)
    }

    @Test("尾句是声明，报缺返回")
    func trailingDeclarationIsRejected() {
        let source = #"""
        取|func() -> (I32,):
            2
            var 甲 = 1
        """#
        #expect(diagnosticCode(source) == "E4-041")
    }

    @Test("尾句是 void 调用，报缺返回")
    func trailingVoidCallIsRejected() {
        let source = #"""
        取|func() -> (I32,):
            print("x",)
        """#
        #expect(diagnosticCode(source) == "E4-041")
    }

    @Test("if 与 else 都交值，放行")
    func bothBranchesDeliver() {
        let source = #"""
        取|func(_甲: I32,) -> (I32,):
            if _甲 > 0:
                return 1
            else:
                return 2
        """#
        #expect(diagnosticCode(source) == nil)
    }

    @Test("if 无 else，报缺返回")
    func ifWithoutElseIsRejected() {
        let source = #"""
        取|func(_甲: I32,) -> (I32,):
            if _甲 > 0:
                return 1
        """#
        #expect(diagnosticCode(source) == "E4-041")
    }

    @Test("match 覆盖枚举全部用例，放行")
    func exhaustiveEnumMatchDelivers() {
        let source = #"""
        [形状]
        圆形
        方形

        取|func(_甲: 形状,) -> (I32,):
            match _甲:
                case 圆形:
                    return 1
                case 方形:
                    return 2
        """#
        #expect(diagnosticCode(source) == nil)
    }

    @Test("match 有兜底分支，放行")
    func wildcardMatchDelivers() {
        let source = #"""
        [形状]
        圆形
        方形

        取|func(_甲: 形状,) -> (I32,):
            match _甲:
                case 圆形:
                    return 1
                case _:
                    return 0
        """#
        #expect(diagnosticCode(source) == nil)
    }

    @Test("闭包同样受检")
    func closureIsCheckedToo() {
        let source = #"""
        外|func() -> (I32,):
            let 内 = func(_甲: I32,) -> (I32,):
                _甲 + 1
                var 乙 = 0
            return 内(1)
        """#
        #expect(diagnosticCode(source) == "E4-041")
    }

    @Test("尾位 pass 交出零，放行")
    func trailingPassDelivers() {
        let source = #"""
        取|func() -> (I32,):
            pass
        """#
        #expect(diagnosticCode(source) == nil)
    }

    @Test("异步体的 return ok 与尾表达式都放行")
    func asyncBodyDelivers() {
        let withReturn = #"""
        干活|func() => (I32,):
            return ok(1)
        """#
        #expect(diagnosticCode(withReturn) == nil)
        let trailing = #"""
        干活|func() => (I32,):
            ok(1)
        """#
        #expect(diagnosticCode(trailing) == nil)
    }

    @Test("异步体缺返回，报缺返回")
    func asyncBodyWithoutReturnIsRejected() {
        let source = #"""
        干活|func() => (I32,):
            var 甲 = 1
        """#
        #expect(diagnosticCode(source) == "E4-041")
    }

    @Test("match 漏用例由穷尽性诊断先拦，不重复报缺返回")
    func incompleteEnumMatchIsCaughtEarlier() {
        let source = #"""
        [形状]
        圆形
        方形
        三角

        取|func(_甲: 形状,) -> (I32,):
            match _甲:
                case 圆形:
                    return 1
                case 方形:
                    return 2
        """#
        #expect(diagnosticCode(source) == "E3-007")
    }
}

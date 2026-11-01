import Testing

@testable import PiniCore
@testable import PiniIR
@testable import PiniSemantics
@testable import PiniSyntax

/// 裸值判别式上的枚举用例名没有归属：参考 5.6 说 `a[i]` 给的是 `T`，match 条目说 `case` 的名字
/// 按被匹配值的类型解析、不属于该类型的用例是编译期错误。降载层守这一条 —— 否则它落成一条
/// 永不命中的分支，写的人以为在处理越界，实际什么都没发生。
@Suite("裸值判别式的用例名")
struct BareScrutineeMatchTests: Sendable, PiniSourceLowering {

    /// 降载被拒时返回诊断码；没被拒或抛了别的错，返回 nil 或那句别的话，好让断言自己说出来。
    private func rejectionCode(_ source: String) -> String? {
        do {
            _ = try lowered(source)
            return nil
        } catch let error as SemanticError {
            return error.diagnosticCode
        } catch {
            return "非预期错误：\(error)"
        }
    }

    @Test("标量判别式上写 some ⇒ 拒绝，码位 E3-006")
    func scalarWithCaseArmIsRejected() {
        let code = rejectionCode(
            #"""
            main|func() -> ():
                var x: I32 = 1
                match x:
                    case some(v):
                        print(v)
                    case none:
                        print(0)
                return
            """#)
        #expect(code == "E3-006")
    }

    @Test("下标读给的是裸元素，写 some 同样拒绝")
    func arrayElementWithCaseArmIsRejected() {
        let code = rejectionCode(
            #"""
            main|func() -> ():
                var a = [1, 2, 3]
                match a[0]:
                    case some(v):
                        print(v)
                    case none:
                        print(0)
                return
            """#)
        #expect(code == "E3-006")
    }

    @Test(".get(i) 给的是 Optional，some / none 照常命中")
    func optionalScrutineeStillMatches() throws {
        let module = try lowered(
            #"""
            main|func() -> ():
                var a = [1, 2, 3]
                match a.get(1):
                    case some(v):
                        print(v)
                    case none:
                        print(0)
                return
            """#)
        #expect(IRValidator.validate(module).isEmpty)
    }

    @Test("裸值上的字面量分支不受影响")
    func literalArmsOnBareValueStillWork() throws {
        let module = try lowered(
            #"""
            main|func() -> ():
                var x: I32 = 2
                match x:
                    case 1:
                        print(1)
                    case 2:
                        print(2)
                    case _:
                        print(0)
                return
            """#)
        #expect(IRValidator.validate(module).isEmpty)
    }
}

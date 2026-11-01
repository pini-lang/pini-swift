import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// `Result` 型 scrutinee 的 `match` 分派判据：`case ok(v)` 的绑定取载荷类型（窄化），而不是保留 scrutinee 类型。
/// `err` 侧取 `try-else` 已确立的类型擦除错误字 —— `Result` 的 IR 类型只带 ok 侧字段，没有可窄化的错误类型。
/// 故 `err` 绑定就是一个字，读消息须经 `pini.err.message`。分派在降载层完成，与执行后端无关；本件只覆盖解释器臂。
struct ResultNarrowingTests: Sendable, PiniSourceLowering {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 完整跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
        return lines
    }

    /// 把「抛出的诊断」摊平成「判定码 + 文案」；没抛则返回 nil。
    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    // MARK: - 判据 1：`ok` 绑定取载荷类型

    @Test("同步 match 一个 Result 时，ok 绑定取载荷类型（标注与直接打印两条路都通）")
    func okBindingTakesThePayloadType() throws {
        /// 意图：`case ok(v)` 的 `v` 是 `I32`、不是 `Result<I32>`。两条路各测一次：赋给载荷类型的标注（类型面），
        /// 与直接打印（既是类型面、也是八个并发样例的真实形态）。两条都要绿：前者验窄化，后者验打印门禁不再误触。
        let source = #"""
        造|func() -> (^I32,):
            return ok(5)

        main|func() -> ():
            let x = 造()
            match x:
                case ok(v):
                    let w: I32 = v
                    print(w)
                    print(v)
                case err(e):
                    print("err")
            return
        """#
        #expect(try runOutput(source) == ["5", "5"])
    }

    // MARK: - 判据 2：`ok` 绑定参与算术

    @Test("同步 match 一个 Result 时，ok 绑定可直接参与算术")
    func okBindingTakesPartInArithmetic() throws {
        /// 意图：单测算术面 —— 它覆盖的是「运算类型不符」那条报文，且**无门禁参与**，
        /// 故纯判类型推断是否拿到了载荷类型。修前必红。
        let source = #"""
        造|func() -> (^I32,):
            return ok(5)

        main|func() -> ():
            let x = 造()
            match x:
                case ok(v):
                    print(v + 1)
                case err(e):
                    print("err")
            return
        """#
        #expect(try runOutput(source) == ["6"])
    }

    // MARK: - 驳回性：`err` 侧仍是一擦除字（读它只经那一个读口）

    @Test("err 绑定仍是类型擦除的字：打印它得到消息，而不是那个字本身")
    func errBindingPrintsItsMessage() throws {
        // 意图：`err` 侧没有可窄化的类型（IR 类型不带错误类型），它沿用 `try-else` 的擦除字形态
        // ⇒ 打印不可能直接得到那个字：要么经运行时段取消息，要么什么都没有。本条把前者钉死。
        // 驳回性：若直接打印那个字，输出会变成一串数字，本用例转红。
        let source = #"""
        造|func() -> (^I32,):
            return err(Error("boom"))

        main|func() -> ():
            let x = 造()
            match x:
                case ok(v):
                    print(v)
                case err(e):
                    print(e)
            return
        """#
        #expect(try runOutput(source) == ["boom"])
    }
}

import Testing
import PiniSyntax

@testable import PiniSemantics

/// 同一个 `*T` 目标在导入面、导出面、声明级要得到同一个结论与同一句话。
/// 三处各写一套判据时，典型故障是「一个面拒绝、另一个面放行」，而作者拿到的理由还各不相同。
@Suite("指针目标三面同解")
struct PointerTargetConsistencyTests: Sendable, PiniSourceLowering {

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            let code = (error as? any DiagnosticProviding)?.diagnosticCode ?? ""
            return (code, String(describing: error))
        }
    }

    /// 声明级：函数体里的局部声明。只声明不调用，判据要的是签名位本身。
    private func declarationSource(target: String) -> String {
        """
        (点)
        x: F64 = 0.0

        main|func() -> ():
            var p: *\(target)
            return
        """
    }

    /// 导入面：外部函数签名。
    private func importSource(target: String) -> String {
        """
        (点)
        x: F64 = 0.0

        [libc|foreign]
        took: (*\(target),) -> ()

        main|func() -> ():
            return
        """
    }

    /// 导出面：`|c` 条目。块头名须等于文件名，故这里固定 `calc.pini`。
    private func exportSource(target: String) -> String {
        """
        (点)
        x: F64 = 0.0

        f|func(p: *\(target),) -> (I32,):
            return 0

        [calc|export]
        calc_f|c = f

        main|func() -> (I32,):
            return 0
        """
    }

    @Test("纯值结构体作目标：三面都拒绝，且都带同一句理由")
    func pureValueStructIsRejectedEverywhere() throws {
        let sentence = try #require(CPointerTarget.sentence(for: "点"))

        let declaration = try #require(failure { _ = try typeChecked(declarationSource(target: "点")) })
        let imported = try #require(failure { _ = try typeChecked(importSource(target: "点")) })
        let exported = try #require(
            failure { _ = try typeChecked(exportSource(target: "点"), fileName: "calc.pini") })

        for (face, failed) in [("声明级", declaration), ("导入面", imported), ("导出面", exported)] {
            #expect(failed.message.contains(sentence), "\(face) 实际：\(failed.message)")
        }
    }

    @Test("白名单标量作目标：三面都成立，收紧没有误伤")
    func scalarTargetIsAcceptedEverywhere() throws {
        _ = try typeChecked(declarationSource(target: "U8"))
        _ = try typeChecked(importSource(target: "U8"))
        _ = try typeChecked(exportSource(target: "U8"), fileName: "calc.pini")
    }
}

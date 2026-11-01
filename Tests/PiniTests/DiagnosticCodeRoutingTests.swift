import Testing
import PiniSyntax

@testable import PiniIR
@testable import PiniHost

/// 「该改程序」与「等它做完」必须分得开：E6-004 是能力缺口，E6-005 是类型不匹配。
/// 两者模板槽不同（`{feature}` vs `{expected}` / `{got}`），分派错了就把占位符字面量印给用户 ——
/// `fill` 只替换传入的 key，未填的原样留在句子里。
@Suite("IR 门控错误的码位分派")
struct DiagnosticCodeRoutingTests: Sendable {

    private func error(
        code: String, expected: String? = nil, got: String? = nil
    ) -> IRLowerer.IRLoweringError {
        IRLowerer.IRLoweringError(
            message: "fallback message",
            location: SourceLocation(line: 3, column: 5, fileName: "t.pini"),
            code: code,
            expected: expected,
            got: got
        )
    }

    @Test("E6-005 给两个槽，不再借用 {feature}")
    func typeMismatchFillsTwoSlots() {
        let args = ErrorFormatter.diagnosticArgs(
            of: error(code: "E6-005", expected: "(I32,) -> I32", got: "String")
        )
        #expect(args["expected"] == "(I32,) -> I32")
        #expect(args["got"] == "String")
        #expect(args["feature"] == nil, "E6-005 不该同时塞 {feature}")
    }

    @Test("其余码维持单槽 {feature}")
    func otherCodesKeepFeatureSlot() {
        let args = ErrorFormatter.diagnosticArgs(of: error(code: "E6-004"))
        #expect(args["feature"] == "fallback message")
        #expect(args["expected"] == nil)
        #expect(args["got"] == nil)
    }

    @Test("E6-005 缺一槽时退回 {feature}，不把占位符印给用户")
    func partialPayloadFallsBack() {
        let args = ErrorFormatter.diagnosticArgs(of: error(code: "E6-005", expected: "I32", got: nil))
        #expect(args["feature"] == "fallback message", "缺 {got} 时两槽都不该启用")
        #expect(args["expected"] == nil)
    }

    @Test("E6-005 渲染成「类型不匹配」整句，占位符不外露")
    func rendersTypeMismatchSentence() {
        let text = ErrorFormatter.formatDiagnostic(
            error(code: "E6-005", expected: "(I32,) -> I32", got: "String"),
            source: "\n\n\n\n",
            language: .zh
        )
        #expect(text.contains("类型不匹配"), "实际：\(text)")
        #expect(text.contains("(I32,) -> I32") && text.contains("String"), "两值都要进句子，实际：\(text)")
        #expect(!text.contains("{expected}") && !text.contains("{got}"), "占位符不许露出来，实际：\(text)")
    }
}

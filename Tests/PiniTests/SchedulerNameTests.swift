import Foundation
@testable import PiniCore
import Testing

/// 语言**预置**的调度特征名。
///
/// **这一件测什么**：调度面提案要把调度做成语言可见的可替换点，第一步是让 `调度器`
/// 这个名字在语言里**存在、且可被引用**。本件钉的就是这个名字**已被登记为特征**。
///
/// ⛔ 本件**不测**派发点如何取得默认实例，也**不测**默认实现的行为 —— 那是后续两段的事。
/// ⛔ 也**不测**这个特征有哪些抽象方法：抽象方法集当前刻意留空（策略层的接口形状
/// 由提供默认实例的那一段定），故本件对它不作任何断言 —— 断言一个尚未定形的形状，
/// 等于把形状钉死在判据里。
struct SchedulerNameTests {

    /// 把一段源过一遍管线，返回**类型层**的错误。
    /// 只走到类型层就够：名字能否被引用，是这个层的判定。
    private func typeErrors(_ source: String) throws -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        return TypeChecker().checkCollecting(module: module)
    }

    @Test("语言预置的调度特征名可被 `实现:` 引用")
    func theSchedulerTraitIsPredeclared() throws {
        /// 意图：`实现:` 位是这个名字**唯一**会被校验的位置（类型标注位对未知名字是宽容的），
        /// 所以它也是这个名字「是否已被语言预置」的唯一可判读面。
        let errors = try typeErrors("""
        (我的调度器)
            实现: 调度器

        main|func() -> ():
            return
        """)
        #expect(errors.isEmpty, "language-provided trait not recognised: \(errors)")
    }

    @Test("未登记的名字仍被拒 —— 上一条因此有区分力")
    func anUnregisteredTraitNameIsStillRejected() throws {
        /// 意图：这条是**阴性对照**，不是重复。`实现:` 位的名字若**本来就不被校验**，
        /// 那么上一条在「登记生效」与「根本没查」两种实现状态下**都会绿** ——
        /// 两者在读数上同形。本件据此把它们分开：没有这一条，上一条证明不了任何事。
        let errors = try typeErrors("""
        (狗)
            实现: 不存在的特征

        main|func() -> ():
            return
        """)
        #expect(!errors.isEmpty, "an unknown trait name slipped through: \(errors)")
    }
}

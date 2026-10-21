import Foundation
@testable import PiniCore
import Testing

/// 按位或 `|` 的**直写形态**（`a | b`）：解析、结合性、执行三面。
///
/// 右端 = **手写期望**（⛔ 不是从某次运行输出抄来的）。
///
/// 优先级判据取规范 A.3 表：`& | ^ << >>` **同级左结合**（与 C 系不同）——
/// 故 `1 | 2 << 2` = `(1|2) << 2` = 12、`5 | 3 & 1` = `(5|3) & 1` = 1；
/// 按 C 的分层会得 9 与 5，两个值都写进驳回性测量。
///
/// `|` 与声明修饰、标签、联合类型共用该符号（规范 A.4 规则 3.13）⇒ 本套件同时钉
/// 「位或可达」与「其余角色不被抢走」两件事，缺任一件都不算修好。
@Suite("位或直写")
struct BitwiseOrOperatorTests {

    // MARK: - 语料与手写期望

    /// 一行一个读数。`o5`–`o7` 是优先级/结合性判别式，`o8` 钉无空格形态，
    /// `o9` 钉同符号的标签角色（`outer|while`）仍归标签分派。
    /// ⚠️ raw 字符串：语料里若有 `\t` 一类转义，普通多行串会把它静默改写。
    private static let corpus = #"""
    main|func() -> ():
        var a: I32 = 5
        var b: I32 = 3
        print("o1", a | b)
        print("o2", a | 0)
        print("o3", 0 | b)
        print("o4", a | b | 1)
        print("o5", a | b & 1)
        print("o6", 1 | 2 << 2)
        print("o7", a ^ b | 8)
        print("o8", a|b)
        var n: I32 = 0
        outer|while n < 3:
            n = n + 1
        print("o9", n)
        return
    """#

    /// 手写期望（逐行；⛔ 不含尾换行 —— raw 串的尾换行被闭合符吃掉）。
    private static let expected = #"""
    o1 7
    o2 5
    o3 3
    o4 7
    o5 1
    o6 12
    o7 14
    o8 7
    o9 3
    """#

    // MARK: - 进程内装置

    /// 一段程序跑出来的结果。
    private enum Outcome: Equatable {
        /// 跑完了，附打印出来的行。
        case ran([String])
        /// 被拒了——文本是那条例外的说明。
        case refused(String)
    }

    /// 走与命令行同一条前端，并跑起来。
    private static func attempt(_ source: String) -> Outcome {
        let name = "位或直写探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(
                fileName: name,
                module: ConstantFolder.foldConstants(in: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "位或直写", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：`a | b` 直写形态逐行产生手写期望，且 `& | ^ << >>` 同级左结合。
    @Test("直写形态：解析与执行逐行等于手写期望")
    func literalFormMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        let body = lines.joined(separator: "\n")

        // 推进性测量：每一条读数都对上。
        #expect(body == Self.expected)

        // 驳回性测量（三条，各钉一种「不该出现」的形态）：
        // ① 解析期拒绝的报文不得出现（该形态的旧表现）；
        #expect(!body.contains("invalid expression"), "位或直写在解析期被拒")
        // ② C 系分层（`|` 低于 `<<`）会得 `o6 9`；
        #expect(!body.contains("o6 9"), "`|` 被当成比移位低一层")
        // ③ C 系分层（`|` 低于 `&`）会得 `o5 5`。
        #expect(!body.contains("o5 5"), "`|` 被当成比按位与低一层")
    }

    /// 意图：`|` 后跟控制流关键字时仍归标签分派（位或分派不得抢走它）。
    /// 这是驳回性测量：断言「位置这一侧不该被吃掉」——标签语句必须照旧跑起来。
    @Test("同符号的标签角色：`标签|while` 仍是标签")
    func labeledControlFlowStillParsesAsLabel() throws {
        let source = #"""
        main|func() -> ():
            var n: I32 = 0
            outer|while n < 4:
                n = n + 2
            print("n", n)
            return
        """#
        guard case .ran(let lines) = Self.attempt(source) else {
            Issue.record("标签形态应可跑，实际被拒")
            return
        }
        #expect(lines == ["n 4"])

        // 驳回性测量：若被按位或认领，这里会落成「位或 + 类型不符」而不是 4。
        #expect(!lines.contains("n 0"), "`标签|while` 被当成了按位或表达式")
    }
}

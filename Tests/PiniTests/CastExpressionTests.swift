import Foundation
import Testing
import PiniSyntax

@testable import PiniCore
@testable import PiniHost
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackendLLVM

/// `as` 显式转换：结果矩阵、优先级、拒绝面与两条通道的指令面。
/// `as` 是上下文关键字（不在关键字表内）⇒ 同时钉「转换可达」与「同名标识符不被抢走」。
@Suite("显式转换")
struct CastExpressionTests: Sendable, PiniSourceLowering {

    // MARK: - 语料与手写期望

    /// 一行一条读数。`c1`/`c2` 钉窄化取低位，`c4`/`c5` 钉符号与零扩展，
    /// `c9` 钉前缀一元比 `as` 紧（若 `as` 更紧会得 1），`c10`/`c11` 钉二元关系与连写。
    private static let corpus = #"""
    main|func() -> ():
        let x: I32 = 300
        print("c1", x as U8)
        print("c2", x as I8)
        let n: I32 = -1
        print("c3", n as U8)
        print("c4", n as I64)
        let b: U8 = 200 as U8
        print("c5", b as I32)
        print("c6", x as F64)
        print("c7", (300.7 as I32))
        print("c8", (-300.7 as I32))
        print("c9", -1 as U8)
        print("c10", 1 + 2 as I32)
        print("c11", ((1 as U8) as I64))
        return
    """#

    /// 手写期望，逐行对应上一条读数。
    private static let expected = #"""
    c1 44
    c2 44
    c3 255
    c4 -1
    c5 200
    c6 300.0
    c7 300
    c8 -300
    c9 255
    c10 3
    c11 1
    """#

    // MARK: - 进程内装置

    /// 一段程序跑出来的结果。
    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    /// 走与命令行同一条前端，并跑起来。
    private static func attempt(_ source: String) -> Outcome {
        let name = "显式转换探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(
                fileName: name,
                module: try FrontEnd.passes(module: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "显式转换", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：结果矩阵逐行等于手写期望，且不依赖哪条通道。
    @Test("解释器通道：逐行等于手写期望")
    func interpreterMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：发射器按源类型的符号性选指令，而不是按 LLVM 拼写猜。
    /// `U8` 与 `I8` 同拼 `i8` ⇒ 零扩展误发成符号扩展会在这里露出来。
    @Test("LLVM 通道：扩展、截断与整数浮点互转各自落到对应指令")
    func llvmEmitsTheRightConversions() throws {
        let ir = try IREmitter().emit(module: try lowered(Self.corpus))
        #expect(ir.contains("trunc i32"), "I32 → U8/I8 应是截断")
        #expect(ir.contains("zext i8"), "U8 → I32 应是零扩展")
        #expect(ir.contains("sext i32"), "I32 → I64 应是符号扩展")
        #expect(ir.contains("sitofp i32"), "I32 → F64 应是 sitofp")
        #expect(ir.contains("fptosi double"), "F64 → I32 应是 fptosi")
    }

    /// 意图：可转类型面之外一律在检查期被拒，不静默换算成零值。
    @Test("拒绝面：Bool 与 String 都不是可转目标")
    func nonNumericTargetsAreRejected() throws {
        let sources = [
            #"""
            main|func() -> ():
                let a = true as I32
                return
            """#,
            #"""
            main|func() -> ():
                let b = 1 as Bool
                return
            """#,
            #"""
            main|func() -> ():
                let c = 1 as String
                return
            """#,
        ]
        for source in sources {
            var rejected = false
            do {
                _ = try typeChecked(source)
            } catch {
                rejected = true
            }
            #expect(rejected, "非数值目标应在检查期被拒")
        }
    }

    /// 意图：`as` 只在「操作数已完整」的位置按转换解释，其余位置是普通标识符。
    @Test("同名标识符：`as` 仍可作变量名")
    func asStillWorksAsAnIdentifier() throws {
        let source = #"""
        main|func() -> ():
            let as = 7
            let y: I32 = as
            print("i1", y)
            return
        """#
        guard case .ran(let lines) = Self.attempt(source) else {
            Issue.record("`as` 作变量名的形态应可跑，实际被拒")
            return
        }
        #expect(lines == ["i1 7"])
    }
}

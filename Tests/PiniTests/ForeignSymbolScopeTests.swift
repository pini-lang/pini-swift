import Foundation
@testable import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniHost

/// 外部符号的模块级作用域：声明落在甲文件、使用落在乙文件，冲突按符号裁决而不是按文件裁决。
/// 判据分两路取证 —— 跨文件能用（跑通并读到 C 的返回值），六类冲突各报一条（码与消息都要对得上）。
struct ForeignSymbolScopeTests: Sendable {

    /// 一文件一段源，走与命令行同一条前端：词法 → 语法 → 常量折叠。
    private func fileUnit(_ name: String, _ source: String) throws -> FileUnit {
        let lexer = Lexer(source: source, fileName: name)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return FileUnit(
            fileName: name, module: try FrontEnd.passes(module: parsed.module))
    }

    /// 语义层整包分析的失败面。码与描述一并返回：只问「抛没抛」会让换错码的实现照样绿。
    private func failure(_ units: [FileUnit]) -> (code: String, detail: String)? {
        do {
            try SemanticAnalyzer().analyze(package: Package(name: "外部符号", fileUnits: units))
            return nil
        } catch let error as SemanticError {
            let code = (error as any DiagnosticProviding).diagnosticCode
            return (code, String(describing: error))
        } catch {
            return ("?", String(describing: error))
        }
    }

    /// 整包跑一遍，收集打印行。用真 C 符号（`atoi`）取证：跨文件可见与否，最终要落到「调得到」。
    private func run(_ units: [FileUnit]) throws -> [String] {
        let runner = ProgramRunner()
        var lines: [String] = []
        runner.outputSink = { lines.append($0) }
        try runner.run(package: Package(name: "跨文件外部符号", fileUnits: units))
        return lines
    }

    // MARK: - 跨文件可见

    @Test("甲文件声明、乙文件调用：跨文件可见并跑出 C 的返回值")
    func crossFileForeignSymbolIsCallable() throws {
        /// 意图：外部符号进模块符号表。没进去时乙文件报 E3-002「未定义函数」，
        /// 而声明明明写在同一个包里 —— 每个文件都得重抄一遍外部符号表正是这条缺陷的代价。
        let units = [
            try fileUnit(
                "甲.pini",
                """
                [libc|foreign]
                strlen: (String,) -> (U64,)
                """),
            try fileUnit(
                "乙.pini",
                """
                main|func() -> (I32,):
                    print(unsafe strlen("42"))
                    return 0
                """),
        ]
        #expect(try run(units) == ["2"], "跨文件调用没读到 C 的返回值")
    }

    @Test("同名同型的两处声明合并，不报冲突")
    func sameNameSameTypeMerges() throws {
        /// 意图：生成模块与手写块会大面积同名，同型合并是它们共存的前提。
        let units = [
            try fileUnit("甲.pini", "[libc|foreign]\nstrlen: (*U8,) -> (U64,)"),
            try fileUnit("乙.pini", "[other|foreign]\nstrlen: (*U8,) -> (U64,)"),
        ]
        #expect(failure(units) == nil, "同型重复声明被当成冲突")
    }

    // MARK: - 六类冲突

    @Test("同名异型：报签名冲突，并点名先声明的那份")
    func sameNameDifferentTypeIsRejected() throws {
        /// 意图：旧行为是后注册者覆盖前者，错误落到调用点 —— 作者按调用处找不出问题。
        /// 现在错在声明处，消息里带得上先声明的那份所在文件。
        let units = [
            try fileUnit("甲.pini", "[libc|foreign]\natoi: (*U8,) -> (I32,)"),
            try fileUnit("乙.pini", "[libc|foreign]\natoi: (String,) -> (I32,)"),
        ]
        let failed = try #require(failure(units), "异型同名未报错")
        #expect(failed.code == "E3-019", "实际：\(failed)")
        #expect(failed.detail.contains("atoi"), "消息应点出符号名，实际：\(failed.detail)")
    }

    @Test("与本地函数同名：按重声明拒绝")
    func clashesWithLocalFunction() throws {
        let units = [
            try fileUnit("甲.pini", "[libc|foreign]\nprobe: () -> (I32,)"),
            try fileUnit("乙.pini", "probe|func() -> (I32,):\n    return 1"),
        ]
        let failed = try #require(failure(units), "外部符号与本地函数同名未报错")
        #expect(failed.code == "E3-004", "实际：\(failed)")
    }

    @Test("与类型同名：按重声明拒绝")
    func clashesWithType() throws {
        let units = [
            try fileUnit("甲.pini", "[libc|foreign]\nBox: () -> (I32,)"),
            try fileUnit("乙.pini", "(Box)\n    值: I32 = 0"),
        ]
        let failed = try #require(failure(units), "外部符号与类型同名未报错")
        #expect(failed.code == "E3-004", "实际：\(failed)")
    }

    @Test("与导出名同名：同一个 C 符号不能既导入又导出")
    func clashesWithExportedName() throws {
        let units = [
            try fileUnit("甲.pini", "[libc|foreign]\ncalc_add: (I32, I32,) -> (I32,)"),
            try fileUnit(
                "calc.pini",
                """
                加法(a: I32, b: I32,) -> (I32,):
                    return a + b

                [calc|export]
                calc_add|c = 加法
                """),
        ]
        let failed = try #require(failure(units), "外部符号与导出名同名未报错")
        #expect(failed.code == "E3-004", "实际：\(failed)")
    }

    @Test("非 C 标识符：解析期放行，语义期必须拒")
    func rejectsNonCIdentifier() throws {
        /// 意图：名字就是 C 符号名。中文标识符是 Pini 的合法写法，但落到 `dlsym` 只会得到
        /// 「库里没有这个符号」，与真正写错名字的表现一样，分不出来。
        let units = [
            try fileUnit("甲.pini", "[libc|foreign]\n数量: I32"),
        ]
        let failed = try #require(failure(units), "非 C 标识符未报错")
        #expect(failed.code == "E3-020", "实际：\(failed)")
        #expect(failed.detail.contains("数量"), "消息应点出符号名，实际：\(failed.detail)")
    }
}

import Foundation
import PiniIR
import PiniSemantics
import PiniSyntax
import Testing

@testable import PiniHost

/// 宏常量的构建期求值：值来自 C 头文件，求不出来必须报错而不是消失。
/// 这些用例要真跑 `cc`，因此只在系统工具链可用时有意义——失败信息里带编译器输出，便于分辨。
@Suite("宏常量求值")
struct ForeignMacroTests {
    private let location = SourceLocation(line: 1, column: 1, fileName: "test.pini")

    private func symbol(_ name: String, _ type: String, flags: [String] = ["macro"]) -> ForeignSymbol {
        ForeignSymbol(
            name: name, annotation: .simple(name: type, location: location),
            flags: flags, location: location)
    }

    @Test("整数、浮点与位运算宏按声明类型求值")
    func evaluatesScalarMacros() throws {
        /// 意图：`EOF` 是十进制 -1，`M_PI` 是浮点字面量，`S_IRUSR` 是八进制 —— 三条词法路径各走一次。
        let symbols = [
            symbol("EOF", "I32"), symbol("M_PI", "F64"), symbol("S_IRUSR", "I32"),
        ]
        let constants = try ForeignMacroEvaluator.evaluate(
            symbols: symbols,
            config: FFIConfig(headers: ["<stdio.h>", "<math.h>", "<sys/stat.h>"]))
        let table = Dictionary(uniqueKeysWithValues: constants.map { ($0.name, $0.value) })
        #expect(table["EOF"] == .integer(-1))
        #expect(table["M_PI"] == .float(Double.pi))
        #expect(table["S_IRUSR"] == .integer(0o400))
    }

    @Test("未展开的标识符报错，不静默跳过")
    func rejectsUnexpandedIdentifier() throws {
        /// 意图：头文件里没有的宏，展开后仍是标识符，必须带原文报错——静默跳过正是要避免的失败方式。
        do {
            _ = try ForeignMacroEvaluator.evaluate(
                symbols: [symbol("PINI_NO_SUCH_MACRO", "I32")], config: FFIConfig(headers: ["<stdio.h>"]))
            Issue.record("未展开的标识符应报错")
        } catch let error as ForeignMacroError {
            #expect("\(error)".contains("PINI_NO_SUCH_MACRO"), "报错应点出符号名：\(error)")
        }
    }

    @Test("值放不进声明类型时报错")
    func rejectsOutOfRangeValue() throws {
        /// 意图：`EOF` 是 -1，声明成 `U8` 放不下；报错要说声明处的 `U8`，不是 LLVM 的 `i8`。
        do {
            _ = try ForeignMacroEvaluator.evaluate(
                symbols: [symbol("EOF", "U8")], config: FFIConfig(headers: ["<stdio.h>"]))
            Issue.record("越界值应报错")
        } catch let error as ForeignMacroError {
            #expect("\(error)".contains("U8"), "报错应写声明类型：\(error)")
        }
    }

    @Test("没有 headers 配置时报错并点名符号")
    func rejectsMissingHeaders() throws {
        /// 意图：单文件模式没有 `pini.toml`，声明宏就只能报「缺 headers」—— 值没有别的来源。
        do {
            _ = try ForeignMacroEvaluator.evaluate(
                symbols: [symbol("EOF", "I32")], config: .default)
            Issue.record("缺 headers 应报错")
        } catch let error as ForeignMacroError {
            #expect("\(error)".contains("EOF"), "报错应点出符号名：\(error)")
            #expect("\(error)".contains("headers"), "报错应指向 headers 配置：\(error)")
        }
    }
}

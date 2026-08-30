import XCTest
import PiniCore
import Foundation

/// 跨模块集成行为暂存区
/// 本文件集中存放**尚无专属特征测试文件**的跨模块端到端行为，避免其散落或随阶段壳被误删：
///  • 类型组合继承（字段 / 方法继承与覆盖）—— 当前无 TypeCompositionTests；
///  • match 的 default 边界语义（未匹配触发 / 命中不触发 / 无 default 且枚举值未匹配 → 抛 matchNotExhaustive，MED-1）—— 当前无 MatchTests；
///  • 枚举关联值位置化（规则 3.15：具名声明解析期报错 / 具名实参类型期报错 / 位置逐位绑定）—— 与 GenericEnumTests（泛型枚举特化）互补；
///  • defer 中使用未定义变量的语义检查路径 —— 与运行时 defer 测试互补。
/// 若未来为上述任一特性新建专属测试文件，应将对应用例迁出并删除本文件相关段落。
/// 范围契约：仅保留跨模块的端到端行为；纯词法 / 解析 / 类型层覆盖应归属对应模块测试。
final class IntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "integration.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "integration.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// 辅助：执行完整的静态检查流水线（lex → parse → semantic → typecheck）
    private func checkModule(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "check.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "check.pini")
        let module = try parser.parseModule()

        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)

        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 内嵌组合（embedding composition）

    /// 意图：内嵌组合应继承父类型的字段
    /// 推进性测量：子类型实例应能访问父类型字段
    /// 驳回性测量：未继承的字段访问应报错
    func testTypeCompositionInheritsFields() throws {
        let source = """
(基础点)
x: I32 = 10
y: I32 = 20

(颜色点)
基础点
颜色: String = "red"

main|func() -> ()
    let p = 颜色点()
    print(p.x)
    print(p.y)
    print(p.颜色)
    return
"""
        let output = try runProgram(source)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines, ["10", "20", "red"], "类型组合应继承父类型字段")
    }

    /// 意图：内嵌组合应继承父类型的方法
    func testTypeCompositionInheritsMethods() throws {
        let source = """
(计数器)
数值: I32 = 0

((计数器))
增加|self() -> ()
    self.数值 = self.数值 + 1
    return

(命名计数器)
计数器
名称: String = "默认"

main|func() -> ()
    let c = 命名计数器()
    c.增加()
    c.增加()
    print(c.数值)
    print(c.名称)
    return
"""
        let output = try runProgram(source)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines, ["2", "默认"], "类型组合应继承父类型方法")
    }

    /// 意图：子类型字段应覆盖父类型同名字段
    func testTypeCompositionOverridesFields() throws {
        let source = """
(父类)
值: I32 = 100

(子类)
父类
值: I32 = 200

main|func() -> ()
    let s = 子类()
    print(s.值)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "200", "子类型字段应覆盖父类型")
    }

    // MARK: - match default 分支语义（解释器特有的边界行为）

    /// 意图：match 未匹配任何 case 时应执行 default 分支
    func testMatchDefaultFiresOnNoMatch() throws {
        let source = """
[形状]
圆
矩形
三角形

main|func() -> ()
    var s = 三角形
    match s:
        case 圆:
            print("圆形")
        case 矩形:
            print("矩形")
        case _:
            print("未知形状")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "未知形状", "未匹配时应执行 default")
    }

    /// 意图：match 匹配到 case 时不应执行 default 分支（驳回性测量）
    func testMatchDefaultNotFiresOnMatch() throws {
        let source = """
[形状]
圆
矩形

main|func() -> ()
    var s = 圆
    match s:
        case 圆:
            print("命中")
        case _:
            print("默认")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "命中", "匹配到 case 时不应执行 default")
    }

    /// 意图（MED-1，P5）：match 无 default 且无匹配、且主体为枚举值时，运行期应抛
    /// `RuntimeError.matchNotExhaustive`（替代原静默跳过，提升可发现性、易调试）。
    func testMatchNoDefaultNoMatch() throws {
        let source = """
[形状]
圆
矩形
三角形

main|func() -> ()
    var s = 三角形
    match s:
        case 圆:
            print("圆形")
        case 矩形:
            print("矩形")
    print("结束")
    return
"""
        do {
            _ = try runProgram(source)
            XCTFail("无 default 且枚举值未匹配时应抛 matchNotExhaustive，而非静默跳过")
        } catch let error as RuntimeError {
            guard case .matchNotExhaustive(let value, _) = error else {
                XCTFail("期望 matchNotExhaustive，得到 \(error)")
                return
            }
            XCTAssertEqual(value, "三角形", "报错应携带未匹配的枚举 case 名")
        }
    }

    // MARK: - 枚举关联值位置化（ADR-016 规则 3.15）

    /// 意图：具名关联值决议（2026-08-29，推翻规则 3.15 具名拒绝）——具名形参声明
    /// `矩形(宽度: F64, 高度: F64,)` 合法，且 match 位置解构按位绑定。
    /// 推进性测量：check 零错误；运行输出 12.0（宽 3.0 × 高 4.0）。
    func testEnumNamedParamDeclarationAccepted() {
        let source = """
[形状]
矩形(宽度: F64, 高度: F64,)

面积|func(s: 形状,) -> (F64,)
    match s:
        case 矩形(w, h):
            return w * h

main|func() -> ()
    print(面积(矩形(3.0, 4.0,)))
    return
"""
        XCTAssertNoThrow(try checkModule(source), "具名形参声明应合法")
    }

    /// 意图：具名关联值全链路 E2E——具名声明 + 构造 + 三种 match 解构
    ///（位置绑定 / 具名绑定 / `_` 占位）。
    /// 推进性测量：输出 "x\n7\ny\n8\n9\n"。
    func testNamedAssociatedValuesEndToEnd() throws {
        let source = """
[Token]
identifier(text: String, loc: I32,)
plus

main|func() -> ()
    var t = identifier(text: "x", loc: 7,)
    match t:
        case identifier(text, loc):
            print(text)
            print(loc)
    var u = identifier(text: "y", loc: 8,)
    match u:
        case identifier(text: s, loc: l):
            print(s)
            print(l)
    var v = identifier(text: "z", loc: 9,)
    match v:
        case identifier(_, l2):
            print(l2)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "x\n7\ny\n8\n9\n", "三种解构应依次输出 x/7、y/8、9")
    }

    /// 意图：绑定数与关联值数不匹配应报 E4（argumentCountMismatch）——
    /// 此前静默错绑（首名绑整元组、其余 null）。
    /// 驳回性测量：3 绑定对 2 关联值必须报错。
    func testMatchBindingArityMismatchRejected() {
        let source = """
[Token]
identifier(text: String, loc: I32,)

main|func() -> ()
    var t = identifier("x", 7,)
    match t:
        case identifier(a, b, c):
            print(a)
    return
"""
        XCTAssertThrowsError(try checkModule(source), "绑定数不匹配应报类型错误") { error in
            guard case TypeError.argumentCountMismatch(let expected, let got, _) = error else {
                XCTFail("期望 argumentCountMismatch，得到 \(error)")
                return
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(got, 3)
        }
    }

    /// 意图：规则 3.15——枚举构造只接受位置实参，具名实参须在类型检查期报错
    ///（解析期 `圆(半径: 5.0)` 与普通函数具名调用同形，故只能在 callee 解析为枚举 case 后拒绝）
    /// 推进性测量：位置声明 + `矩形(高度: 4.0, 宽度: 3.0,)` 抛出 TypeError.enumCaseArgumentLabel
    /// 驳回性测量：具名实参被接受（旧「命名参数顺序无关」行为已随 3.15 废除）
    func testEnumNamedConstructionArgumentRejected() {
        let source = """
[形状]
矩形(F64, F64,)

main|func() -> ()
    var r = 矩形(高度: 4.0, 宽度: 3.0,)
    return
"""
        XCTAssertThrowsError(try checkModule(source), "规则 3.15：枚举构造具名实参应报类型错误") { error in
            guard case TypeError.enumCaseArgumentLabel(let label, let caseName, _) = error else {
                XCTFail("期望 TypeError.enumCaseArgumentLabel，得到 \(error)")
                return
            }
            XCTAssertEqual(caseName, "矩形", "报错应携带枚举 case 名")
            XCTAssertEqual(label, "高度", "报错应携带首个越权的具名实参标签")
        }
    }

    /// 意图：规则 3.15——位置式构造与匹配按声明顺序逐位绑定
    /// 推进性测量：`矩形(3.0, 4.0,)` 匹配 `case 矩形(w, h,)` 得 w=3.0 / h=4.0
    /// 驳回性测量：绑定错位或未命中
    func testEnumPositionalConstructionAndMatch() throws {
        let source = """
[形状]
矩形(F64, F64,)

main|func() -> ()
    var r = 矩形(3.0, 4.0,)
    match r:
        case 矩形(w, h,):
            print(w)
            print(h)
        case _:
            print(0.0)
    return
"""
        let output = try runProgram(source)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines, ["3.0", "4.0"], "位置实参应按声明顺序逐位绑定")
    }

    // MARK: - defer 错误路径（CodeGen 不覆盖的检查层路径）

    /// 意图：defer 中使用未定义变量应在语义检查阶段报错（非运行时）
    /// 推进性测量：正确抛出 SemanticError.undefinedVariable
    /// 驳回性测量：未定义变量不报错或错误类型不对
    func testDeferWithUndefinedVariable() throws {
        let source = """
main|func() -> ()
    while 1 < 2:
        defer undefinedVar = undefinedVar + 1
        return
    return
"""
        XCTAssertThrowsError(try checkModule(source), "defer 中使用未定义变量应报错") { error in
            guard case SemanticError.undefinedVariable = error else {
                XCTFail("应为 SemanticError.undefinedVariable，实际: \(error)")
                return
            }
        }
    }
}

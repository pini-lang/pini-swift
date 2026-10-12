import Foundation
import PiniCore
import Testing

/// 结构串（SIG）序列化器的宿主单测。
/// 右端 = 判据面手写期望（优先级/结合性判别式 14 条，逐字取自判据夹具的判别式段），
/// ⛔ 不是从某次运行输出抄来的；语料与期望同源同版。
@Suite("SignatureSerialization")
struct SignatureSerializationTests {

    /// 判据夹具判别式段的逐字语料（main 块内前 14 个语句 + return）。
    private static let corpus = #"""
main|func() -> ():
    ; 1  `a - b - c` 减号左结合
    a - b - c
    ; 2  `a + b * c` 乘优先于加
    a + b * c
    ; 3  `a & b == c` 位运算高于相等比较（⚠️ 依据是 §A.3 总表，⛔ 不是 §A.6.3 的措辞）
    a & b == c
    ; 4  `a << b + c` 加减高于移位
    a << b + c
    ; 5  `a || b && c` 与高于或
    a || b && c
    ; 6  `a == b != c` 同级左结合
    a == b != c
    ; 7  `-a + b` 一元高于二元
    -a + b
    ; 8  `a * b % c` 同级左结合
    a * b % c
    ; 9  `a && b || c` 同级左结合
    a && b || c
    ; 10 `a[i] + 1` 后缀先于二元
    a[i] + 1
    ; 11 `f(x).g` 后缀链
    f(x).g
    ; 12 `a[i][j] = v` 下标作写目标
    a[i][j] = v
    ; 13 `await f()` 前缀挂起 join
    await f()
    ; 14 `a <= b` 中缀比较（⛔ 不拆成 `<` `=`）
    a <= b
    return
"""#

    /// 判据④ 的手写期望（14 条判别式；第 3 条按优先级总表写，与形式文法附录的措辞相反）。
    private static let expectedSignatures: [(index: Int, signature: String)] = [
        (1, "exprStmt@0|binary@1|minus@2|left@2|binary@3|minus@4|left@4|a@5|right@4|b@5|right@2|c@3"),
        (2, "exprStmt@0|binary@1|plus@2|left@2|a@3|right@2|binary@3|multiply@4|left@4|b@5|right@4|c@5"),
        (3, "exprStmt@0|binary@1|equal@2|left@2|binary@3|bitwiseAnd@4|left@4|a@5|right@4|b@5|right@2|c@3"),
        (4, "exprStmt@0|binary@1|leftShift@2|left@2|a@3|right@2|binary@3|plus@4|left@4|b@5|right@4|c@5"),
        (5, "exprStmt@0|binary@1|or@2|left@2|a@3|right@2|binary@3|and@4|left@4|b@5|right@4|c@5"),
        (6, "exprStmt@0|binary@1|notEqual@2|left@2|binary@3|equal@4|left@4|a@5|right@4|b@5|right@2|c@3"),
        (7, "exprStmt@0|binary@1|plus@2|left@2|unary@3|minus@4|operand@4|a@5|right@2|b@3"),
        (8, "exprStmt@0|binary@1|modulo@2|left@2|binary@3|multiply@4|left@4|a@5|right@4|b@5|right@2|c@3"),
        (9, "exprStmt@0|binary@1|or@2|left@2|binary@3|and@4|left@4|a@5|right@4|b@5|right@2|c@3"),
        (10, "exprStmt@0|binary@1|plus@2|left@2|subscript@3|receiver@4|a@5|index@4|i@5|right@2|1@3"),
        (11, "exprStmt@0|member@1|call@2|callee@3|f@4|arg []:@3|x@4"),
        (12, "assign@0|target@1|subscript@2|receiver@3|subscript@4|receiver@5|a@6|index@5|i@6|index@3|j@4|value@1|v@2"),
        (13, "exprStmt@0|join@1|call@2|callee@3|f@4"),
        (14, "exprStmt@0|binary@1|lessThanOrEqual@2|left@2|a@3|right@2|b@3"),
    ]

    // MARK: - 私有 helper

    /// 与命令行同序：解析后折叠常量，再读结构串。
    private func signatures(of source: String) -> [String] {
        let lexer = Lexer(source: source, fileName: "signature-test.pini")
        guard let tokens = try? lexer.tokenize() else {
            Issue.record("语料词法失败（语料应可解析）")
            return []
        }
        let result = Parser(tokens: tokens, fileName: "signature-test.pini")
            .parseModuleCollectingErrors()
        if !result.errors.isEmpty {
            Issue.record("语料解析失败：\(result.errors.count) 条错误（语料应可解析）")
        }
        let module = ConstantFolder.foldConstants(in: result.module)
        return SignatureSerializer.signatureLines(module: module)
    }

    // MARK: - 推进性测量

    /// 意图：main 块内前 14 个语句的结构串逐条等于判据④ 的手写期望。
    @Test("判据④ 判别式逐条等于手写期望", arguments: Self.expectedSignatures)
    func precedenceDiscriminant(index: Int, signature: String) throws {
        let lines = signatures(of: Self.corpus)
        try #require(lines.count >= index, "语句位不足 \(index) 条（实得 \(lines.count)）——判据会空转")
        #expect(lines[index - 1] == "SIG|\(index)|\(signature)",
                "第 \(index) 条判别式不符：实得 <\(lines[index - 1])>")
    }

    /// 意图：语料的语句位计数与 14 条判别式 + return 相符（⛔ 不是空转的少条数）。
    @Test("语料语句位计数")
    func statementCount() throws {
        let lines = signatures(of: Self.corpus)
        #expect(lines.count == 15, "应为 14 条判别式 + return，实得 \(lines.count)")
        #expect(lines[14] == "SIG|15|(none)@1",
                "return 语句的结构串不符：实得 <\(lines[14])>")
    }

    /// 意图：只有 main 进判集——它之前的顶层声明不被抽取。
    @Test("main 之前的顶层声明不进判集")
    func declarationsBeforeMainAreIgnored() throws {
        let lines = signatures(of: #"""
helper|func() -> ():
    return

main|func() -> ():
    a - b
    return
"""#)
        #expect(lines.count == 2, "只应判 main 的两条语句，实得 \(lines.count)")
        #expect(lines[0] == "SIG|1|exprStmt@0|binary@1|minus@2|left@2|a@3|right@2|b@3",
                "main 首条不符：实得 <\(lines[0])>")
    }

    // MARK: - 驳回性测量

    /// 意图：无 main 的模块零行产出（⛔ 不伪造占位行）。
    @Test("无 main ⇒ 零行")
    func noMainYieldsNoSignatures() throws {
        let lines = signatures(of: #"""
helper|func() -> ():
    return
"""#)
        #expect(lines.isEmpty, "无 main 的模块应零行产出，实得 \(lines.count) 行")
    }

    /// 意图：op: 行被取值剥离——结构串里⛔ 不出现 op: 行原文。
    @Test("运算符行只留取值")
    func operatorLinesCarryValueOnly() throws {
        let lines = signatures(of: Self.corpus)
        try #require(lines.count >= 1, "语句位为空")
        #expect(!lines[0].contains("op:"), "结构串里出现了 op: 行原文：<\(lines[0])>")
        #expect(lines[0].contains("minus@2"), "第一条应含剥离出的运算符名 minus@2：<\(lines[0])>")
    }

    /// 意图：成员名头部内联——后缀链那条⛔ 不出现 name: 行，也⛔ 不出现 g 的成员元素。
    @Test("成员名不进元素")
    func memberNameIsNotAnElement() throws {
        let lines = signatures(of: Self.corpus)
        try #require(lines.count >= 11, "语句位不足 11 条")
        #expect(!lines[10].contains("name:"), "结构串里出现了 name: 行原文：<\(lines[10])>")
        #expect(!lines[10].contains("g@"), "结构串里出现了成员名元素：<\(lines[10])>")
    }
}

import Testing
import PiniSyntax

@testable import PiniCore

/// 临时值的去路：求值方新造的份额，要么被存储位接管，要么在消费位用完归还。
/// 判据取 `main` 的函数体切片 —— 产物里还有入口与内建装配的释放，混在一起数会失真。
@Suite("临时值的归位")
struct TemporaryOwnershipTests: Sendable {

    private func emitted(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        return try IREmitter().emit(module: lowered)
    }

    /// `main` 的函数体：从 `define i32 @main()` 到该函数的右花括号。
    private func mainBody(_ ir: String) throws -> String {
        let start = try #require(ir.range(of: "define i32 @main()"), "产物里没有 main")
        let rest = ir[start.lowerBound...]
        let end = try #require(rest.range(of: "\n}"), "main 没有闭合")
        return String(rest[..<end.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// 消费位：临时串印完即还，释放排在打印之前。
    @Test("直接打印的临时串在打印前归还")
    func aConsumedTemporaryIsReleasedBeforeThePrint() throws {
        let body = try mainBody(
            try emitted(
                #"""
                main|func() -> ():
                    let s = "abcdef"
                    print(s.substring(1, 4))
                    return
                """#))
        let allocated = try #require(body.range(of: "call ptr @bk_substring")).lowerBound
        let printed = try #require(body.range(of: "@fmt_string")).lowerBound
        let released = try #require(body.range(of: "call void @bk_str_release")).lowerBound
        let newline = try #require(body.range(of: "@fmt_newline")).lowerBound
        #expect(allocated < released, "先分配后释放")
        #expect(printed < released, "打印读完了才归还")
        #expect(released < newline, "消费位在本条语句之内归还，不留到块尾")
    }

    /// 存储位：份额归变量槽，释放留到块尾。
    @Test("被变量接管的临时值留到块尾才释放")
    func aStoredTemporaryIsReleasedAtTheBlockTail() throws {
        let body = try mainBody(
            try emitted(
                #"""
                main|func() -> ():
                    let s = "abcdef"
                    let t = s.substring(1, 4)
                    print(len(t))
                    return
                """#))
        let newline = try #require(body.range(of: "@fmt_newline")).lowerBound
        let released = try #require(body.range(of: "call void @bk_str_release")).lowerBound
        #expect(newline < released, "接管之后不再由消费点归还，留到清理栈")
    }

    /// 借用值不在账上：常量串直接打印，一条释放都不该发。
    @Test("借用值不发放")
    func aBorrowedValueIsNeverReleased() throws {
        let body = try mainBody(
            try emitted(
                #"""
                main|func() -> ():
                    print("abcdef")
                    return
                """#))
        #expect(occurrences(of: "call void @bk_str_release", in: body) == 0)
        #expect(occurrences(of: "call void @bk_array_destroy", in: body) == 0)
    }

    /// 内建的操作数也是消费位，只是它不出现在 `call` 的实参表里。
    @Test("切分结果的数组在长度查完之后销毁")
    func aSplitResultIsDestroyedAfterTheLengthQuery() throws {
        let body = try mainBody(
            try emitted(
                #"""
                main|func() -> ():
                    let s = "a,b"
                    print(len(s.split(",")))
                    return
                """#))
        #expect(occurrences(of: "call ptr @bk_string_split", in: body) == 1)
        let queried = try #require(body.range(of: "call i32 @bk_array_len")).lowerBound
        let destroyed = try #require(body.range(of: "call void @bk_array_destroy")).lowerBound
        #expect(queried < destroyed, "先查长度，再销毁")
    }

    /// `LazyRef` 的句柄与他族同一个计数头：别名点保留、退出销毁，两半缺一不可。
    @Test("LazyRef 的别名点保留与退出销毁成对")
    func lazyRefRetainsAndDestroys() throws {
        let body = try mainBody(
            try emitted(
                #"""
                main|func() -> ():
                    var r = LazyRef<I32>(func () -> (I32,):
                        return 42
                    )
                    var s = r
                    print(s.value)
                    return
                """#))
        #expect(occurrences(of: "call void @bk_handle_retain", in: body) == 1, "别名点留一份")
        #expect(occurrences(of: "call void @bk_lazyref_destroy", in: body) == 2, "每个持有者退出时还一份")
    }
}

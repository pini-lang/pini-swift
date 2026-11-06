import Testing

@testable import PiniBackendLLVM
@testable import PiniIR

/// 聚合的成员份额：`Optional` / `Result` / 元组里的计数成员由聚合本身持有 —— 构造时保留一份，
/// 槽退出或解构时归还。判据取发射产物里的调用，并用标量成员做反证，防止断言被别的路径带过。
@Suite(.serialized)
struct AggregateShareTests: PiniSourceLowering, Sendable {

    private func emitted(_ source: String) throws -> String {
        try IREmitter().emit(module: try lowered(source))
    }

    /// 截取两个标签之间的产物片段：份额动作落在哪条路径上，只有位置能说明。
    private func slice(_ ir: String, from start: String, to end: String) -> String {
        guard let head = ir.range(of: start),
            let tail = ir.range(of: end, range: head.upperBound..<ir.endIndex)
        else { return "" }
        return String(ir[head.lowerBound..<tail.lowerBound])
    }

    @Test("try 的成功载荷：写槽前保留一份，临时聚合在两条路径各归还一次")
    func try载荷份额() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                let v = try tryReadFile("/nope") else e: return
                print(v)
                return
            """)
        let ok = slice(ir, from: "try.ok.", to: "try.join.")
        #expect(!ok.isEmpty, "产物里该有 try 的成功标签")
        #expect(ok.contains("@bk_str_retain"), "借用的载荷要靠这一步才有独立份额")
        #expect(ok.contains("@bk_str_release"), "临时聚合那份要在收尾归还")
        let err = slice(ir, from: "try.err.", to: "try.ok.")
        #expect(err.contains("@bk_str_release"), "错误路径也要归还聚合，否则漏一份")
    }

    @Test("Optional<String>：构造保留一份，槽退出归还一份")
    func 可选串() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                let s = "x"
                var o: Optional<String> = .some(s)
                return
            """)
        #expect(ir.contains("call void @bk_str_retain"), "构造聚合要替成员保留一份")
        #expect(ir.contains("call void @bk_str_release"), "槽退出要逐成员归还")
    }

    @Test("Optional<I32> 不进份额通道：产物里没有保留与归还")
    func 标量可选() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                var o: Optional<I32> = .some(1)
                return
            """)
        #expect(!ir.contains("@bk_str_retain"), "标量成员不该被计数")
        #expect(!ir.contains("@bk_str_release"), "标量成员没有可归还的份额")
    }

    @Test("元组：计数成员逐个保留，退出逐个归还")
    func 元组() throws {
        let ir = try emitted(
            """
            main|func() -> ():
                let s = "x"
                var pair = (s, 1)
                return
            """)
        #expect(ir.contains("call void @bk_str_retain"), "元组成员要保留一份")
        #expect(ir.contains("call void @bk_str_release"), "元组退出要归还成员")
    }
}

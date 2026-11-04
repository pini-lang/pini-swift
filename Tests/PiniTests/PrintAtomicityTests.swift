import Foundation
import Testing

@testable import PiniBackendLLVM
@testable import PiniIR
@testable import PiniSemantics
@testable import PiniSyntax

/// 打印的行原子：一次 `print` 的所有 `printf` 必须夹在 `bk_print_lock` 与 `bk_print_unlock` 之间。
/// 这是并发程序输出可读的前提 —— 拼装期被别的线程插进来，两行就粘成一行。
@Suite(.serialized)
struct PrintAtomicityTests: PiniSourceLowering, Sendable {

    private func emitted(_ source: String) throws -> String {
        try IREmitter().emit(module: lowered(source))
    }

    /// 函数体：跳过模块头部的 `declare`，否则查到的第一个 `@bk_print_lock()` 是声明而不是调用。
    private func body(_ listing: String) throws -> Substring {
        let start = try #require(listing.range(of: "define ")?.lowerBound, "产物里没有函数定义")
        return listing[start...]
    }

    /// 打印语句的四个位置，按出现顺序返回；缺一即失败。
    private func keyPoints(_ code: Substring) throws -> [String.Index] {
        [
            try #require(code.range(of: "@bk_print_lock()")?.lowerBound, "没有加锁"),
            try #require(code.range(of: "(ptr, ...) @printf(ptr")?.lowerBound, "没有打印"),
            try #require(code.range(of: "@printf(ptr @fmt_newline)")?.lowerBound, "没有换行"),
            try #require(code.range(of: "@bk_print_unlock()")?.lowerBound, "没有解锁"),
        ]
    }

    private func calls(_ needle: String, in code: Substring) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    @Test("单参打印：锁在值之前，解锁在换行之后")
    func 单参打印整行加锁() throws {
        let code = try body(
            emitted(
                """
                main|func() -> ():
                    print("hi")
                    return
                """))
        let points = try keyPoints(code)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0 < $1 },
                "四步顺序应为 加锁 → 打印 → 换行 → 解锁")
    }

    @Test("多参打印：整行同处一个临界区，锁只取一次")
    func 多参打印整行加锁() throws {
        let code = try body(
            emitted(
                """
                main|func() -> ():
                    print(1, "x", 2)
                    return
                """))
        let points = try keyPoints(code)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0 < $1 },
                "四步顺序应为 加锁 → 打印 → 换行 → 解锁")
        #expect(calls(" call void @bk_print_lock()", in: code) == 1, "一次打印只该取一次锁")
    }

    @Test("两条打印各自成段，不共用一把锁")
    func 两条打印各自加锁() throws {
        let code = try body(
            emitted(
                """
                main|func() -> ():
                    print("a")
                    print("b")
                    return
                """))
        #expect(calls(" call void @bk_print_lock()", in: code) == 2, "两次打印应有两次加锁")
        #expect(calls(" call void @bk_print_unlock()", in: code) == 2, "两次打印应有两次解锁")
    }
}

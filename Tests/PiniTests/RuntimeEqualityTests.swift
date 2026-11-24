import Testing
import PiniSyntax
@testable import PiniHost

/// 解释通道的二元运算：枚举相等按用例名与载荷判，与 `Value` 的 `==` 同一判据。
/// 编译通道对同一份源码给出相同结果，两条通道因此不会在枚举比较上分叉。
struct RuntimeEqualityTests: Sendable {

    private func 枚举(_ 用例: String, _ 载荷: [Value] = []) -> Value {
        .enumValue(EnumValue(caseName: 用例, associatedValues: 载荷, parentEnum: "TokenKind"))
    }

    @Test func 枚举相等比用例名() throws {
        #expect(try RuntimeOps.binaryValue(枚举("newline"), .equal, 枚举("newline")) == .bool(true))
        #expect(try RuntimeOps.binaryValue(枚举("newline"), .equal, 枚举("identifier")) == .bool(false))
        #expect(try RuntimeOps.binaryValue(枚举("newline"), .notEqual, 枚举("identifier")) == .bool(true))
    }

    @Test func 枚举相等比载荷() throws {
        let 甲 = 枚举("some", [.int(1)])
        let 乙 = 枚举("some", [.int(1)])
        let 丙 = 枚举("some", [.int(2)])
        #expect(try RuntimeOps.binaryValue(甲, .equal, 乙) == .bool(true))
        #expect(try RuntimeOps.binaryValue(甲, .equal, 丙) == .bool(false))
    }
}

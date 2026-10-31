import Foundation
import Testing

@testable import PiniCore
@testable import PiniSemantics
@testable import PiniHost

/// 语言面名单与执行层分发表是同一批名字的两份记账：少一个，降载层放行而执行层无答案。
@Suite("内建名单")
struct BuiltinSurfaceTests: Sendable {

    @Test("字符内建名单与运行时分发表一致")
    func characterNamesMatchTheDispatchTable() {
        #expect(Set(RuntimeOps.characterBuiltins.keys) == BuiltinSurface.character)
    }

    @Test("同步并发内建名单与运行时分发表一致")
    func concurrencyNamesMatchTheDispatchTable() {
        #expect(Set(RuntimeOps.concurrencyBuiltins.keys) == BuiltinSurface.synchronousConcurrency)
    }
}

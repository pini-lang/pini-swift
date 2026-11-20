import Foundation
import Testing

/// 标准库源与宿主发行副本必须逐字节一致；漂移会让两条通道装配出不同标准库。
/// 以 bootstrap 源为准，副本只许由它同步生成，两份源之间留一个空行。
@Suite("StdlibSourceSync")
struct StdlibSourceSyncTests: Sendable {

    @Test("标准库资源与 bootstrap 源一致")
    func matchesBootstrapSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = root.appendingPathComponent("bootstrap/stdlib/src/api")
        let core = try Data(contentsOf: sourceDirectory.appendingPathComponent("core.pini"))
        let algorithms = try Data(contentsOf: sourceDirectory.appendingPathComponent("algorithms.pini"))
        let bundle = try Data(contentsOf: root.appendingPathComponent("Sources/PiniSyntax/Resources/stdlib.pini"))
        var expected = core
        expected.append(contentsOf: "\n".utf8)
        expected.append(contentsOf: algorithms)
        #expect(bundle == expected, "宿主资源副本应从 bootstrap 标准库源同步；不要反向改源")
    }
}

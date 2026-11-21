import Foundation
import PiniSemantics
import PiniSyntax
import Testing

/// 跨包裸 `.用例`：用例名与父枚举都住在被导入的包里，导入方靠 `_别名` 就能写 `.圆形`。
/// 名字关须认得被导入包的用例名，否则合法写法被判「未定义变量」；父枚举与可见性在声明侧定。
@Suite("跨包枚举用例", .serialized)
struct ImportedEnumCaseTests {

    /// 两包落地：`base` 出枚举，`app` 以 `_别名` 引入后写裸用例。清单与入口按包名现拼。
    private func makeWorkspace(app source: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pini-import-case-\(UUID().uuidString)")
        try writePackage(root, name: "base", source: """
            [形状]
            圆形
            方形
            """)
        try writePackage(root, name: "app", source: source)
        return root
    }

    private func writePackage(_ root: URL, name: String, source: String) throws {
        let packageRoot = root.appendingPathComponent(name)
        let api = packageRoot.appendingPathComponent("src/api")
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try """
            [package]
            name = "\(name)"

            [lib]
            name = "\(name)"
            entry = "src/api/\(name).pini"
            """.write(
                to: packageRoot.appendingPathComponent("pini.toml"), atomically: true,
                encoding: .utf8)
        try source.write(
            to: api.appendingPathComponent("\(name).pini"), atomically: true, encoding: .utf8)
    }

    /// 走与命令行同一条路：整包语义分析，再整包类型检查。失败按诊断抛出。
    private func check(_ root: URL, package name: String) throws {
        let package = try FileLoader.loadDirectory(
            path: root.appendingPathComponent(name).path)
        try SemanticAnalyzer().analyze(package: package)
        try TypeChecker().check(package: package)
    }

    @Test("导入方写被导入包的裸用例，不报未定义")
    func bareCaseFromImportedPackageResolves() throws {
        let root = try makeWorkspace(app: """
            [app|import]
            _base = "../../../base"

            看|func(_s: 形状,) -> (I32,):
                return 1

            main|func() -> ():
                print(看(.圆形,),)
                return
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        try check(root, package: "app")
    }

    @Test("拼错的用例名仍判未定义变量：导入面只放行真有的用例")
    func unknownCaseFromImportedPackageStillFails() throws {
        let root = try makeWorkspace(app: """
            [app|import]
            _base = "../../../base"

            看|func(_s: 形状,) -> (I32,):
                return 1

            main|func() -> ():
                print(看(.三角,),)
                return
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try check(root, package: "app")
            Issue.record("拼错的用例名没有被拒绝")
        } catch {
            let code = (error as? any DiagnosticProviding)?.diagnosticCode ?? "?"
            #expect(code == "E3-001")
        }
    }
}

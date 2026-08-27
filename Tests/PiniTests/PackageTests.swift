import XCTest
@testable import PiniCore

/// `Package` / `FileUnit` / `FileLoader` 增量模型测试。
/// 验证多文件加载能力，且**不破坏**既有单文件世界。
final class PackageTests: XCTestCase {

    private var tmpDir: String!

    override func setUp() {
        super.setUp()
        tmpDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_p4_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func write(_ name: String, _ content: String) -> String {
        let full = (tmpDir as NSString).appendingPathComponent(name)
        try! content.write(toFile: full, atomically: true, encoding: .utf8)
        return full
    }

    /// 单文件加载：返回 1 个 FileUnit，fileName 正确，声明非空。
    /// 意图：验证单文件加载返回含 1 个 FileUnit 的包：fileName 为传入路径、模块含 1 个声明、包名为目录名。
    func testLoadSingleFile() throws {
        let path = write("a.pini", "(点)\nx: I32 = 0\n")
        let pkg = try FileLoader.loadFile(path: path)

        XCTAssertEqual(pkg.fileUnits.count, 1)
        XCTAssertEqual(pkg.fileUnits[0].fileName, path)
        XCTAssertEqual(pkg.fileUnits[0].module.declarations.count, 1)
        XCTAssertEqual(pkg.name, (tmpDir as NSString).lastPathComponent)
    }

    /// 目录加载：递归扫描 `.pini`，返回 N 个 FileUnit，包名=目录名。
    /// 意图：验证目录加载递归扫描 .pini 文件，返回 2 个 FileUnit（struct A、B），包名为目录名。
    func testLoadDirectory() throws {
        write("a.pini", "(A)\nx: I32 = 0\n")
        write("b.pini", "(B)\ny: I32 = 0\n")
        let pkg = try FileLoader.loadDirectory(path: tmpDir)

        XCTAssertEqual(pkg.fileUnits.count, 2)
        XCTAssertEqual(pkg.name, (tmpDir as NSString).lastPathComponent)
        func firstStructName(_ unit: FileUnit) -> String {
            guard case .structDecl(let s) = unit.module.declarations.first! else { return "" }
            return s.name
        }
        let names = Set(pkg.fileUnits.map { firstStructName($0) })
        XCTAssertEqual(names, ["A", "B"])
    }

    /// 目录加载递归：嵌套子目录的 `.pini` 也被纳入（供后续包级可见性）。
    /// 意图：验证目录加载递归纳入嵌套子目录内的 .pini 文件，共返回 2 个 FileUnit。
    func testLoadDirectoryRecursive() throws {
        write("a.pini", "(A)\nx: I32 = 0\n")
        let sub = (tmpDir as NSString).appendingPathComponent("sub")
        try! FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: true, attributes: nil)
        try! "(S)\nz: I32 = 0\n".write(
            toFile: (sub as NSString).appendingPathComponent("s.pini"),
            atomically: true, encoding: .utf8)

        let pkg = try FileLoader.loadDirectory(path: tmpDir)
        XCTAssertEqual(pkg.fileUnits.count, 2)
    }

    /// 向后兼容：单文件世界等价于 1 个 FileUnit 的包。
    /// 意图：验证 Package.singleFile 构造等价于含 1 个 FileUnit 的包（向后兼容），包名正确。
    func testSingleFileBackwardCompat() {
        let module = Module(declarations: [], location: SourceLocation(line: 1, column: 1, fileName: "x.pini"))
        let pkg = Package.singleFile(name: "m", fileName: "x.pini", module: module)
        XCTAssertEqual(pkg.fileUnits.count, 1)
        XCTAssertEqual(pkg.name, "m")
    }

    /// 无法读取目录应抛 LoaderError。
    /// 意图：验证加载不存在的目录抛出 LoaderError.cannotReadDirectory（错误路径）。
    func testCannotReadMissingDirectory() {
        XCTAssertThrowsError(try FileLoader.loadDirectory(path: "/no/such/dir/pini")) { err in
            XCTAssertEqual(err as? LoaderError, .cannotReadDirectory(path: "/no/such/dir/pini"))
        }
    }
}

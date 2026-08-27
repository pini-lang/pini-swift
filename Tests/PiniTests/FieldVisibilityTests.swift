import XCTest
@testable import PiniCore

/// 字段级 type-private 强制（spec 2.5）。
///
/// 规则：`_`-前缀字段仅其**声明类型自身的方法**可访问；同文件普通函数 / 跨类型方法 / 跨文件
/// 访问均不可访问。静态（TypeChecker）与运行时（Interpreter）双重强制，确保即便漏掉静态路径
/// （如类型推断失败），运行时仍是最后一道硬墙。
///
/// 与声明级可见性（inaccessibleSymbol）不同：字段级依赖「当前访问者类型」，故仅在
/// 类型层（能拿到 `self` 类型）与运行时（能拿到 `currentEnv` 的 `self`）强制，语义层不做。
final class FieldVisibilityTests: XCTestCase {

    private func moduleFrom(_ source: String, fileName: String) -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let result = parser.parseModuleCollectingErrors()
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        return result.module
    }

    /// 由多个 (fileName, source) 构造一个多文件包。fileName 决定可见性锚点。
    private func pkg(_ units: [(fileName: String, source: String)]) -> Package {
        let fileUnits = units.map {
            FileUnit(fileName: $0.fileName, module: moduleFrom($0.source, fileName: $0.fileName))
        }
        return Package(name: "fieldvis", fileUnits: fileUnits)
    }

    private func typeError(_ package: Package) -> Error? {
        let checker = TypeChecker()
        do { try checker.check(package: package); return nil }
        catch { return error }
    }

    private func runError(_ package: Package) -> Error? {
        let interp = Interpreter()
        do { try interp.run(package: package); return nil }
        catch { return error }
    }

    // MARK: - 合法：声明类型自身方法读写自己的 _ 字段

    /// 意图：验证声明类型自身的方法可读写自己的 `_` 字段——取密/设密均访问 self._密钥，断言静态类型检查与运行时执行均无错误（合法路径）。
    func testOwnMethodCanReadAndWriteOwnPrivateField() {
        let p = pkg([("app.pini", """
        {保险箱}
        _密钥: I32 = 0

        {{保险箱}}
        取密|self() -> ()
            return self._密钥
        设密|self() -> ()
            self._密钥 = 42
            return
        main|func() -> ()
            let b = 保险箱()
            b.设密()
            print(b.取密())
            return
        """)])
        XCTAssertNil(typeError(p), "同类型方法读写自身 _ 字段不应报类型错误")
        XCTAssertNil(runError(p), "同类型方法读写自身 _ 字段运行时不应报错")
    }

    // MARK: - 非法（静态）：同文件普通函数访问 _ 字段

    /// 意图：验证同文件普通函数 main 访问类型 `_` 字段在类型层被拒——print(b._密钥)，断言抛 inaccessibleField(typeName: "保险箱", fieldName: "_密钥")。
    func testFreeFunctionCannotAccessPrivateFieldStatic() {
        let p = pkg([("app.pini", """
        {保险箱}
        _密钥: I32 = 0
        main|func() -> ()
            let b = 保险箱()
            print(b._密钥)
            return
        """)])
        guard let e = typeError(p) as? TypeError else {
            XCTFail("类型层应抛 TypeError"); return
        }
        guard case .inaccessibleField(let typeName, let fieldName, _) = e else {
            XCTFail("类型层应报 inaccessibleField，实际：\(e)"); return
        }
        XCTAssertEqual(typeName, "保险箱")
        XCTAssertEqual(fieldName, "_密钥")
    }

    // MARK: - 非法（静态）：跨类型方法访问 _ 字段（两类型须分属不同文件）

    /// 意图：验证跨类型方法访问 `_` 字段在类型层被拒——撬棍.撬 读保险箱._密钥（两类型分属不同文件），断言抛 inaccessibleField(保险箱, _密钥)。
    func testCrossTypeMethodCannotAccessPrivateFieldStatic() {
        let p = pkg([
            ("lib.pini", """
            {保险箱}
            _密钥: I32 = 0
            """),
            ("app.pini", """
            {撬棍}

            {{撬棍}}
            撬|self(b: 保险箱) -> ()
                print(b._密钥)
                return
            main|func() -> ()
                return
            """),
        ])
        guard let e = typeError(p) as? TypeError else {
            XCTFail("类型层应抛 TypeError"); return
        }
        guard case .inaccessibleField(let typeName, let fieldName, _) = e else {
            XCTFail("类型层应报 inaccessibleField，实际：\(e)"); return
        }
        XCTAssertEqual(typeName, "保险箱")
        XCTAssertEqual(fieldName, "_密钥")
    }

    // MARK: - 非法（静态 + 运行时）：跨文件访问 _ 字段

    /// 意图：验证跨文件访问 `_` 字段在类型层被拒——app.pini 的 main 读 _internals/helpers.pini 中账户._owner，断言抛 inaccessibleField(账户, _owner)。
    func testCrossFilePrivateFieldStatic() {
        let p = pkg([
            ("_internals/helpers.pini", """
            {账户}
            余额: I32 = 0
            _owner: I32 = 1

            {{账户}}
            查主人|self() -> ()
                return self._owner
            """),
            ("app.pini", """
            main|func() -> ()
                let acc = 账户()
                print(acc._owner)
                return
            """),
        ])
        guard let e = typeError(p) as? TypeError else {
            XCTFail("跨文件访问 _ 字段应抛 TypeError"); return
        }
        guard case .inaccessibleField(let typeName, let fieldName, _) = e else {
            XCTFail("跨文件应报 inaccessibleField，实际：\(e)"); return
        }
        XCTAssertEqual(typeName, "账户")
        XCTAssertEqual(fieldName, "_owner")
    }

    // MARK: - 非法（运行时）：_ 字段跨方法访问在运行时报错

    /// 意图：验证 `_` 字段跨方法访问在运行时也被强制拦截——即便静态推断缺失仍是最后一道硬墙，断言 runError 抛 RuntimeError 且为 inaccessibleField(保险箱, _密钥)。
    func testPrivateFieldAccessThrowsAtRuntime() {
        let p = pkg([("app.pini", """
        {保险箱}
        _密钥: I32 = 0
        main|func() -> ()
            let b = 保险箱()
            print(b._密钥)
            return
        """)])
        // 运行时强制：即便静态推断缺失，仍是最后一道硬墙。
        guard let e = runError(p) as? RuntimeError else {
            XCTFail("运行时层应抛 RuntimeError，实际：\(String(describing: runError(p)))"); return
        }
        guard case .inaccessibleField(let typeName, let fieldName, _) = e else {
            XCTFail("运行时层应报 inaccessibleField，实际：\(e)"); return
        }
        XCTAssertEqual(typeName, "保险箱")
        XCTAssertEqual(fieldName, "_密钥")
    }

    // MARK: - 回归：package-demo 活文档仍能通过类型检查与运行（其 `（非法）` 注释保持注释态）

    private func packageRoot() -> String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return url.path
    }

    /// 意图：回归验证 examples/package-demo 活文档仍能通过类型检查与正常运行——加载真实目录并断言 typeError/runError 均为 nil，防止其 `（非法）` 注释态示例被误改成可执行代码破坏演示。
    func testPackageDemoStillChecksAndRuns() throws {
        let dir = (packageRoot() as NSString).appendingPathComponent("examples/package-demo")
        let manifest = try FileLoader.loadManifest(directory: dir)
        let pkg = try FileLoader.loadDirectory(path: dir, manifest: manifest)
        XCTAssertNil(typeError(pkg), "package-demo 应通过类型检查")
        XCTAssertNil(runError(pkg), "package-demo 应可正常运行")
    }
}

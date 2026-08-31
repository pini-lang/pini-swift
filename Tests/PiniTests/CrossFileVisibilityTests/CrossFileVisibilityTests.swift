import XCTest
@testable import PiniCore

/// 跨文件符号解析 + 4 级可见性 enforce（语义 / 类型层，spec 2.5）。
///
/// 设计锚点：
/// - 单文件包（`fileUnits.count <= 1`）委托旧 `analyze(module:)` / `check(module:)`，行为与旧单文件世界完全等价（零回归）。
/// - 多文件包：构建包级符号索引，按「符号名 / 文件名 / 目录名 `_` 前缀」计算可见性，
///   引用点 enforce——private（`_` 符号）/ internal（`_` 文件）跨文件不可见 → 报错；
///   package（`_` 目录）/ public 跨文件可见 → 通过。
final class CrossFileVisibilityTests: XCTestCase {

    private func moduleFrom(_ source: String, fileName: String) -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let result = parser.parseModuleCollectingErrors()
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        return result.module
    }

    /// 由多个 (fileName, source) 构造一个多文件包。fileName 决定可见性锚点
    ///（如 `_lib.pini` 为 internal 文件、`_pkg/lib.pini` 为 package 目录）。
    private func pkg(_ units: [(fileName: String, source: String)]) -> Package {
        let fileUnits = units.map {
            FileUnit(fileName: $0.fileName, module: moduleFrom($0.source, fileName: $0.fileName))
        }
        return Package(name: "testpkg", fileUnits: fileUnits)
    }

    private func semanticError(_ package: Package) -> Error? {
        let analyzer = SemanticAnalyzer()
        do { try analyzer.analyze(package: package); return nil }
        catch { return error }
    }

    private func typeError(_ package: Package) -> Error? {
        let checker = TypeChecker()
        do { try checker.check(package: package); return nil }
        catch { return error }
    }

    // MARK: - 正确用法：应通过

    /// public 符号（无 `_` 前缀）跨文件引用 → 语义 / 类型层均通过。
    /// 意图：验证无 `_` 前缀的 public 函数跨文件引用在语义/类型层均无错误。
    func testPublicSymbolVisibleCrossFile() {
        let p = pkg([
            ("lib.pini", "helper() -> ():\n    return\n"),
            ("app.pini", "main() -> ():\n    helper()\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "public 跨文件引用应无语义错误")
        XCTAssertNil(typeError(p), "public 跨文件引用应无类型错误")
    }

    /// package 符号（`_` 目录）跨文件引用 → 同包内可见，通过。
    /// 意图：验证 `_` 目录内 package 级函数跨文件引用在语义/类型层均通过。
    func testPackageSymbolVisibleCrossFile() {
        let p = pkg([
            ("_pkg/lib.pini", "helper() -> ():\n    return\n"),
            ("app.pini", "main() -> ():\n    helper()\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "package 跨文件引用应无语义错误")
        XCTAssertNil(typeError(p), "package 跨文件引用应无类型错误")
    }

    /// 同文件内引用：即便符号 `_` 私有 / 文件 `_` internal，文件内恒可见。
    /// 意图：验证同文件内 `_` 私有符号/`_` 文件内的引用文件内恒可见，语义/类型均无错。
    func testSameFilePrivateVisible() {
        let p = pkg([
            ("_secretfile.pini",
             "_secret() -> ():\n    return\nmain() -> ():\n    _secret()\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "同文件内私有引用应可见")
        XCTAssertNil(typeError(p), "同文件内私有引用应可见")
    }

    /// 单文件包委托旧 analyse/check，与直接 analyze(module:) 行为完全一致（零回归）。
    /// 意图：验证单文件包委托旧 analyze/check 路径无异常（与直接 analyze(module:) 等价，零回归）。
    func testSingleFilePackageEquivalence() {
        let src = "main() -> ():\n    print(\"hi\")\n    return\n"
        let single = pkg([("app.pini", src)])
        XCTAssertNoThrow(try SemanticAnalyzer().analyze(package: single), "单文件包语义分析应无错")
        XCTAssertNoThrow(try TypeChecker().check(package: single), "单文件包类型检查应无错")
    }

    /// 顶层变量（`let`）跨文件：public 变量跨文件可见。
    /// 意图：验证 public 顶层 let 变量跨文件引用在语义/类型层均无错误。
    func testPublicVarVisibleCrossFile() {
        let p = pkg([
            ("lib.pini", "let greeting: String = \"hi\"\n"),
            ("app.pini", "main() -> ():\n    print(greeting)\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "public 顶层变量跨文件引用应无语义错误")
        XCTAssertNil(typeError(p), "public 顶层变量跨文件引用应无类型错误")
    }

    // MARK: - 误用：应报错

    /// private 符号（`_` 符号前缀）跨文件引用 → 不可见，语义 / 类型层均报 inaccessibleSymbol。
    /// 意图：验证 `_` 前缀 private 符号跨文件引用在语义/类型层均报 inaccessibleSymbol（错误路径）。
    func testPrivateSymbolNotVisibleCrossFile() {
        let p = pkg([
            ("lib.pini", "_secret() -> ():\n    return\n"),
            ("app.pini", "main() -> ():\n    _secret()\n    return\n"),
        ])
        if let e = semanticError(p) as? SemanticError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("语义层应报 inaccessibleSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("语义层应抛 inaccessibleSymbol")
        }
        if let e = typeError(p) as? TypeError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("类型层应报 inaccessibleSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("类型层应抛 inaccessibleSymbol")
        }
    }

    /// internal 符号（`_` 文件）跨文件引用 → 不可见，报 inaccessibleSymbol。
    /// 意图：验证 `_` 文件 internal 函数跨文件引用在语义/类型层均报 inaccessibleSymbol。
    func testInternalFileNotVisibleCrossFile() {
        let p = pkg([
            ("_lib.pini", "helper() -> ():\n    return\n"),
            ("app.pini", "main() -> ():\n    helper()\n    return\n"),
        ])
        if let e = semanticError(p) as? SemanticError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("语义层应报 inaccessibleSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("语义层应抛 inaccessibleSymbol")
        }
        if let e = typeError(p) as? TypeError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("类型层应报 inaccessibleSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("类型层应抛 inaccessibleSymbol")
        }
    }

    /// internal 顶层变量（`_` 文件）跨文件引用 → 不可见，报 inaccessibleSymbol。
    /// 意图：验证 `_` 文件 internal 顶层变量跨文件引用在语义层报 inaccessibleSymbol（错误路径）。
    func testInternalVarNotVisibleCrossFile() {
        let p = pkg([
            ("_lib.pini", "let secret: String = \"x\"\n"),
            ("app.pini", "main() -> ():\n    print(secret)\n    return\n"),
        ])
        if let e = semanticError(p) as? SemanticError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("语义层应报 inaccessibleSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("语义层应抛 inaccessibleSymbol")
        }
    }

    /// 跨文件同名顶级声明 → 包内命名空间共享，语义层报 redeclaredSymbol。
    /// 意图：验证跨文件同名顶级函数因包内命名空间共享在语义层报 redeclaredSymbol（错误路径）。
    func testCrossFileRedeclaration() {
        let p = pkg([
            ("a.pini", "helper() -> ():\n    return\n"),
            ("b.pini", "helper() -> ():\n    return\n"),
        ])
        if let e = semanticError(p) as? SemanticError {
            guard case .redeclaredSymbol = e else {
                XCTFail("语义层应报 redeclaredSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("语义层应抛 redeclaredSymbol（跨文件同名）")
        }
    }

    // MARK: - 类型名作为注解跨文件引用（P4 审查修复）

    /// public 类型（无 `_` 前缀）跨文件作为函数参数类型注解 → 类型层通过。
    /// 意图：验证 public 类型跨文件作为函数参数类型注解在语义/类型层均无错误。
    func testPublicTypeVisibleCrossFile() {
        let p = pkg([
            ("lib.pini", "{Point}\n数值: I32 = 0\n\n{{Point}}\n取数|self() -> (I32,):\n    return 数值\n\n"),
            ("app.pini", "use|func(s: Point) -> ():\n    return\nmain|func() -> ():\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "public 类型跨文件注解引用：语义层应无错")
        XCTAssertNil(typeError(p), "public 类型跨文件注解引用：类型层应无错")
    }

    /// package 类型（`_` 目录）跨文件作为函数参数类型注解 → 同包内可见，通过。
    /// 意图：验证 `_` 目录 package 类型跨文件作为参数类型注解在语义/类型层均通过。
    func testPackageTypeVisibleCrossFile() {
        let p = pkg([
            ("_pkg/lib.pini", "{Tag}\n数值: I32 = 0\n\n{{Tag}}\n取数|self() -> (I32,):\n    return 数值\n\n"),
            ("app.pini", "use|func(s: Tag) -> ():\n    return\nmain|func() -> ():\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "package 类型跨文件注解引用：语义层应无错")
        XCTAssertNil(typeError(p), "package 类型跨文件注解引用：类型层应无错")
    }

    /// internal 类型（`_` 文件）跨文件作为函数参数类型注解 → 不可见，
    /// 类型层报 inaccessibleSymbol（语义层只检查值引用、不查类型注解，故为 nil）。
    /// 意图：验证 `_` 文件 internal 类型跨文件作为参数注解在类型层报 inaccessibleSymbol，语义层不查类型注解故为 nil。
    func testInternalTypeNotVisibleCrossFile() {
        let p = pkg([
            ("_lib.pini", "{Secret}\n数值: I32 = 0\n\n{{Secret}}\n取数|self() -> (I32,):\n    return 数值\n\n"),
            ("app.pini", "use|func(s: Secret) -> ():\n    return\nmain|func() -> ():\n    return\n"),
        ])
        XCTAssertNil(semanticError(p), "语义层不检查类型名注解，应为 nil")
        if let e = typeError(p) as? TypeError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("类型层应报 inaccessibleSymbol，实际：\(e)"); return
            }
        } else {
            XCTFail("类型层应抛 inaccessibleSymbol（internal 类型跨文件作为注解引用）")
        }
    }

    /// internal 类型（`_` 文件）跨文件作为 object 字段类型注解 → 不可见，类型层报 inaccessibleSymbol。
    /// 意图：验证 internal 类型跨文件作为 object 字段类型注解在类型层报 inaccessibleSymbol，语义层为 nil。
    func testInternalTypeFieldNotVisibleCrossFile() {
        let p = pkg([
            ("_lib.pini", "{Secret}\n数值: I32 = 0\n\n{{Secret}}\n取数|self() -> (I32,):\n    return 数值\n\n"),
            ("app.pini", "{Holder}\n秘密: Secret\nmain|func() -> ():\n    return\n\n\n{{Holder}}\n取数|self() -> (I32,):\n    return 0\n"),
        ])
        XCTAssertNil(semanticError(p), "语义层不检查类型名注解，应为 nil")
        if let e = typeError(p) as? TypeError {
            guard case .inaccessibleSymbol = e else {
                XCTFail("类型层应报 inaccessibleSymbol（internal 类型作为跨文件字段类型），实际：\(e)"); return
            }
        } else {
            XCTFail("类型层应抛 inaccessibleSymbol（object 字段类型跨文件 internal）")
        }
    }
}

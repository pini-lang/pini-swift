import XCTest
import PiniCore

/// 示例一致性格栅（P2 交付合规）：examples/*.pini 必须全部通过 `pini check`
/// （解析 + 语义 + 类型三阶段零错误）。这是「示例即文档」的自动化防线——
/// 让 check 跑通全链路后，任何后续阶段破坏示例都会立即红灯。
final class ExamplesConformanceTests: XCTestCase {

    /// 从当前测试文件向上回溯到 Package.swift，定位包根目录（构建产物路径无关）。
    private func packageRoot() -> String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return url.path
    }

    /// 列出 examples/ 下全部 .pini 文件（按名排序，保证测试稳定）。
    private func exampleFiles() throws -> [String] {
        let examplesDir = (packageRoot() as NSString).appendingPathComponent("examples")
        let names = try FileManager.default.contentsOfDirectory(atPath: examplesDir)
            .filter { $0.hasSuffix(".pini") }
            .sorted()
        return names.map { (examplesDir as NSString).appendingPathComponent($0) }
    }

    /// 与 CLI `runCheckCommand` 完全一致的收集管线：
    /// 词法 + 解析（收集）→ 语义（收集）→ 仅当语义无错才类型（收集）。
    /// 返回聚合诊断字符串；空数组表示检查通过。
    private func checkExample(at path: String) throws -> [String] {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let fileName = (path as NSString).lastPathComponent

        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let parseResult = parser.parseModuleCollectingErrors()
        if !parseResult.errors.isEmpty {
            return parseResult.errors.map { "Parse: \($0)" }
        }

        let module = parseResult.module
        let semanticErrors = SemanticAnalyzer().analyzeCollecting(module: module)
        if !semanticErrors.isEmpty {
            return semanticErrors.map { "Semantic: \($0)" }
        }

        let typeErrors = TypeChecker().checkCollecting(module: module)
        return typeErrors.map { "Type: \($0)" }
    }

    // MARK: - 主栅

    /// 意图：examples/ 下每个 .pini 都应零错误通过 check，确保示例始终合法、可作为文档。
    /// 推进性测量：逐文件运行收集管线并断言诊断数组为空（含解析/语义/类型三阶段）。
    /// 驳回性测量：若任一样例产生诊断（或抛异常），汇总文件名与具体诊断后 XCTFail，
    /// 防止「示例漂移」——示例写得不合法却长期无人发现（P2 审计前即此状态）。
    func testAllExamplesConformToCheck() {
        let files: [String]
        do {
            files = try exampleFiles()
        } catch {
            XCTFail("无法枚举 examples/：\(error)")
            return
        }
        XCTAssertFalse(files.isEmpty, "examples/ 应至少含一个 .pini 文件")

        var failures: [(file: String, diags: [String])] = []
        for file in files {
            let name = (file as NSString).lastPathComponent
            do {
                let diags = try checkExample(at: file)
                if !diags.isEmpty {
                    failures.append((name, diags))
                }
            } catch {
                failures.append((name, ["Unexpected throw: \(error)"]))
            }
        }

        if !failures.isEmpty {
            let report = failures.map { f in
                "· \(f.file):\n" + f.diags.map { "    \($0)" }.joined(separator: "\n")
            }.joined(separator: "\n")
            XCTFail("以下示例未通过 check：\n\(report)")
        }
    }

    // MARK: - 驳回性测量：护栏非形同虚设

    /// 意图：确认 checkExample 管线确实能检出非法代码，避免「全绿」是因为校验被跳过。
    /// 推进性测量：对含未定义函数的片段运行管线，断言返回非空诊断。
    /// 驳回性测量：若合法片段（print(1)）被误报，则 XCTFail——护栏不应假阳性。
    func testConformanceGuardActuallyDetectsViolations() {
        // 推进：未定义函数 foo 必须被语义层报出。
        let broken = "main() -> ()\n    foo(1)\n    return\n"
        let diags = try? checkExampleSource(broken, fileName: "broken.pini")
        XCTAssertNotNil(diags)
        XCTAssertFalse(diags?.isEmpty ?? true, "护栏应检出未定义函数 foo，实际为空（校验被跳过？）")

        // 驳回：合法片段（仅调用内建 print）不应产生诊断。
        let valid = "main() -> ()\n    print(1)\n    return\n"
        let validDiags = try? checkExampleSource(valid, fileName: "valid.pini")
        XCTAssertTrue(validDiags?.isEmpty ?? false, "合法片段不应被误报，实际：\(validDiags ?? [])")
    }

    /// 直接对源码字符串运行收集管线（供驳回性测量复用，避免依赖文件系统）。
    private func checkExampleSource(_ source: String, fileName: String) throws -> [String] {
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let parseResult = parser.parseModuleCollectingErrors()
        if !parseResult.errors.isEmpty {
            return parseResult.errors.map { "Parse: \($0)" }
        }
        let module = parseResult.module
        let semanticErrors = SemanticAnalyzer().analyzeCollecting(module: module)
        if !semanticErrors.isEmpty {
            return semanticErrors.map { "Semantic: \($0)" }
        }
        return TypeChecker().checkCollecting(module: module).map { "Type: \($0)" }
    }
}

import Foundation
import PiniIR
import PiniSemantics
import PiniSyntax

/// 测试面的仓根与命令行产物定位。仓根由「向上找到 Package.swift」确定，不按 `#filePath` 数层数 ——
/// 数层数在顶层套件成立、在子目录套件少一层，症状是仓内明明有产物却记一条「未找到」。
enum PiniTestEnvironment {

    static let repositoryRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) { return directory }
            directory.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }()

    /// 仓内构建产物，按优先序。只给路径、不验可执行：调用方要自己区分「没有产物」与
    /// 「产物早于某个内建」两种情形。
    static var repositoryCLICandidates: [String] {
        ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
            .map { repositoryRoot.path + $0 }
    }

    /// 环境变量优先，其次仓内第一份可执行产物；都没有时 nil，由调用方决定怎么响亮跳过。
    static func cliPath() -> String? {
        let fromEnvironment = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnvironment.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnvironment) {
            return fromEnvironment
        }
        return repositoryCLICandidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}

/// 测试面共用的两级入口：源码 → 类型检查后的模块，再 → IR。
/// 每个套件各抄一份的话，抄的那份最容易与 CLI 的流水线分叉（少一次常量折叠、少开持久表），
/// 而分叉那天没有判据会响 —— 套件里降载出来的树，与真实编译走的那棵树不再是同一棵。
protocol PiniSourceLowering {}

extension PiniSourceLowering {

    /// 词法 → 语法 → 常量折叠 → 语义 → 类型检查。错误按 `TypeError` 抛出，与套件的 `throws:` 断言同型。
    func typeChecked(
        _ source: String, fileName: String = "inline.pini"
    ) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: fileName)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fileName)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        guard errors.isEmpty else { throw errors[0] }
        return (module, checker)
    }

    /// 降载：开持久表兜底，与 CLI 的 codegen 路径同规。
    func lowered(_ source: String, fileName: String = "inline.pini") throws -> IRModule {
        let (module, checker) = try typeChecked(source, fileName: fileName)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }
}

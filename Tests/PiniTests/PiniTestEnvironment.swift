import Foundation
import PiniBackendLLVM
import PiniIR
import PiniSemantics
import PiniSyntax
import Testing

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

    /// LLVM 工具链目录（`lli` 所在处）：复用 CLI 的同一个解析器，不另立一份。
    /// 各解析各的会让「测试齐备、CLI 找不到」同时成立 —— 判据绿着，用户那条路却是断的。
    static func llvmBinDirectory() -> String? {
        LLVMToolchain.lliPath.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// 子进程的环境：写入解析出来的两个路径。`run-llvm` 缺 `PINI_LLVM_BIN` 时会静默空跑，
    /// 故判据与子进程必须看同一份解析结果，各读各的环境变量就会一个说齐备、一个空跑。
    static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let cli = cliPath() { environment["PINI_CLI_BIN"] = cli }
        if let llvm = llvmBinDirectory() { environment["PINI_LLVM_BIN"] = llvm }
        return environment
    }

    /// 工具链齐备与否。缺一份时：`PINI_REQUIRE_TOOLCHAIN=1` 记一条**失败**，否则记一条 known issue。
    /// 裸跑允许跳过，CI 不允许 —— 否则「绿了」与「根本没跑」在读数上长得一样。
    static func requireToolchain(_ keys: [String]) -> Bool {
        let missing = keys.first { key in
            switch key {
            case "PINI_CLI_BIN": return cliPath() == nil
            case "PINI_LLVM_BIN": return llvmBinDirectory() == nil
            default: return (ProcessInfo.processInfo.environment[key] ?? "").isEmpty
            }
        }
        guard let missing else { return true }
        if ProcessInfo.processInfo.environment["PINI_REQUIRE_TOOLCHAIN"] == "1" {
            Issue.record("工具链缺 \(missing)：本批判据本次未取，而 PINI_REQUIRE_TOOLCHAIN=1 不允许跳过")
            return false
        }
        withKnownIssue("未提供 \(missing) ⇒ 本批判据本次未取（跳过 +1）") {
            Issue.record("判据未取：\(missing) 缺失")
        }
        return false
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

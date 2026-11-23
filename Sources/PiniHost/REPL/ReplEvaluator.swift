import Foundation
import PiniSyntax
import PiniSemantics
import PiniIR

/// 一次 REPL 求值：把输入行变成一次程序运行。求值逻辑放在 I/O 循环之外，
/// 因此不依赖会话也能驱动与断言；引擎固定，降载读取检查器的推导结果，
/// 所以无法通过类型检查的输入也降不了载，会作为 REPL 类型错误报出而不是被吞掉。
public final class ReplEvaluator {

    /// 跨输入累积的声明 —— REPL 的会话状态。每次求值都重新登记全部声明：
    /// 没有增量编译，累积再重跑就是全部机制，在 REPL 规模上瞬时完成。
    public private(set) var accumulatedDeclarations: [TopLevelDecl] = []

    public init() {}

    /// 丢弃累积的会话状态（`:clear`）。
    public func reset() {
        accumulatedDeclarations.removeAll()
    }

    /// 一次输入的结果类型。
    public enum Outcome: Equatable {
        /// 按表达式求值，包进临时 `main`。
        case expression
        /// 按声明累积，不生成临时 `main`。
        case declaration
    }

    /// 求值一次提交的输入。`output` 接收程序自己的行输出 —— 用参数而非 `print`，
    /// 是因为检查 REPL 行为的调用方需要看到片段打印了什么，stdout 不能当断言面。
    @discardableResult
    public func evaluate(
        _ lines: [String],
        output: @escaping (String) -> Void = { print($0) }
    ) throws -> Outcome {
        let source = lines.joined(separator: "\n")
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if isExpressionInput(trimmed) {
            // `print(...)` 不再包一层：再包会把 `print` 返回的 null 也打印出来，
            // `print(1)` 就会多出一行空白。
            let body =
                trimmed.hasPrefix("print(") || trimmed.hasPrefix("print ")
                ? trimmed
                : "print(\(trimmed))"
            let wrapped = "main|func() -> ():\n    \(body)\n    return\n"
            let expressionModule = try parse(wrapped)
            let runnable = moduleForRun(
                declarations: accumulatedDeclarations + expressionModule.declarations
            )
            try run(runnable, output: output, tolerateMissingMain: false)
            return .expression
        }

        // 声明输入：累积后重新登记，下一次输入才能引用它。
        // 只有声明、还没有 `main` 是这里的常态，`tolerateMissingMain` 就是为此存在。
        let module = try parse(source)
        accumulatedDeclarations.append(contentsOf: module.declarations)
        let runnable = moduleForRun(declarations: accumulatedDeclarations)
        try run(runnable, output: output, tolerateMissingMain: true)
        return .declaration
    }

    // MARK: - 运行

    private func run(
        _ module: Module,
        output: @escaping (String) -> Void,
        tolerateMissingMain: Bool
    ) throws {
        // 这条路径上检查器不可省：降载要靠它的推导给节点定类型，
        // 通不过类型检查的输入根本降不了载。它会作为 REPL 类型错误报出，不被吞掉。
        let checker = TypeChecker()
        let errors = checker.checkCollecting(
            module: module, foreignConstantFailures: [:])
        if !errors.isEmpty {
            throw ReplError.typeError(
                errors.map { ErrorFormatter.formatTypeError($0, source: "") }
                    .joined(separator: "\n")
            )
        }
        // 只有声明的会话是 REPL 的常态，而降载器视之为错误 —— 它要求存在可执行程序，会在降载中抛出。
        // 判据是问 `main` 是否存在，而不是匹配错误文本，否则措辞一改判据就失效。
        if tolerateMissingMain, !Self.hasMainFunction(module) { return }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let ir = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        let executor = IRExecutor()
        executor.outputSink = output
        do {
            try executor.run(module: ir)
        } catch let error as RuntimeError where tolerateMissingMain {
            if case .mainNotFound = error { return }
            throw error
        }
    }

    /// 模块是否声明了 `main`。REPL 在降载前先问：「还没有 main」在会话中途是常态，
    /// 对降载器却是错误。
    private static func hasMainFunction(_ module: Module) -> Bool {
        module.declarations.contains { declaration in
            if case .funcDecl(let function) = declaration { return function.name == "main" }
            return false
        }
    }

    /// 引擎真正运行的模块，每次求值重新组装 ——
    /// 每个求值一个新实例是 REPL 一贯的形状，在组装的这一处说明，而非每个引擎各说一遍。
    private func moduleForRun(declarations: [TopLevelDecl]) -> Module {
        Module(
            declarations: declarations,
            imports: [], exports: [],
            location: SourceLocation(line: 0, column: 0, fileName: Self.replFileName)
        )
    }

    // MARK: - 输入分类

    /// REPL 求值出的每个节点都带这个文件名。它是占位符，写法上就摆明：
    /// 诊断指到这里，读者一眼看出它不是真实文件。
    public static let replFileName = "<repl>"

    /// 声明起始词。以其中之一开头的输入按声明累积，其余一律当表达式。
    private static let declarationStarters: Set<String> = [
        "{", "object", "enum", "trait", "func",
        "let", "var", "import", "export",
    ]

    private func isExpressionInput(_ trimmed: String) -> Bool {
        for starter in Self.declarationStarters where trimmed.hasPrefix(starter) {
            return false
        }
        return !trimmed.isEmpty
    }

    private func parse(_ source: String) throws -> Module {
        switch FrontEnd.collect(source: source, fileName: Self.replFileName) {
        case .parsed(let module):
            return module
        case .lexFailed(let error):
            throw error
        case .parseFailed(_, let errors):
            throw ReplError.parseError(
                errors
                    .map { ErrorFormatter.formatParserError($0, source: source) }
                    .joined(separator: "\n")
            )
        case .expandFailed(let errors):
            // 整批一次报出：一条 unroll 里表和体可能各错一处，只报首个会让作者来回跑。
            throw ReplError.parseError(
                errors
                    .map { ErrorFormatter.formatDiagnostic($0, source: source) }
                    .joined(separator: "\n")
            )
        }
    }
}

// MARK: - 错误

/// REPL 侧错误：输入在能运行之前失败的两条路径。
public enum ReplError: LocalizedError {
    case parseError(String)
    case typeError(String)

    public var errorDescription: String? {
        switch self {
        case .parseError(let message): return "解析错误:\n\(message)"
        case .typeError(let message): return "类型错误:\n\(message)"
        }
    }
}

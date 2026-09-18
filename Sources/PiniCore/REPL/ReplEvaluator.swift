import Foundation

/// One REPL evaluation: turn input lines into "run a program".
///
/// WHY THIS EXISTS (LR-4 P4-4)
///
/// Evaluation used to live inside the CLI's `ReplSession`, and it constructed
/// `Interpreter()` directly. Both halves of that had the same consequence: the
/// REPL's evaluation path could **not** run on another engine, and — because the
/// test target depends on `PiniCore` and not on the executable — it could not be
/// tested either. The existing REPL suite therefore covers parsing only; it even
/// re-implements the expression wrap rather than drive the session, so nothing
/// asserted what the REPL does when it actually evaluates something.
///
/// Splitting evaluation out of the I/O loop is what let "REPL cases green on
/// the HIR engine" mean anything: evaluation used to construct `Interpreter()`
/// inside the loop, so it could neither run on another engine nor be tested.
///
/// Until `G-6c` the engine was a *parameter*, because two engines existed and
/// "which one runs" was the caller's decision — the shape P4-3 established with
/// `DebugRun`. The AST walk has retired, so that question has one answer left and
/// the parameter went with it.
///
/// TYPE-INCORRECT INPUT IS REFUSED
///
/// The checker is not optional on this path: lowering reads its inference to
/// type the nodes, so an input that does not typecheck cannot be lowered at all.
/// It is reported as a REPL type error rather than swallowed.
///
/// Until `G-6c` that was a *parity limit* as much as a behaviour — the walk ran
/// the semantic gate only, so the same input would run there and be refused
/// here, which the P4-2 survey registered as a behaviour change for interactive
/// input. With the walk gone there is one behaviour left, and it is this one.
public final class ReplEvaluator {

    /// Declarations accumulated across inputs — the REPL's session state.
    ///
    /// Every evaluation re-registers all of them: the REPL has no incremental
    /// compilation, so "accumulate and re-run" is the whole mechanism. At REPL
    /// scale (well under a hundred declarations) that is instant.
    public private(set) var accumulatedDeclarations: [TopLevelDecl] = []

    public init() {}

    /// Drops the accumulated session state (`:clear`).
    public func reset() {
        accumulatedDeclarations.removeAll()
    }

    /// What an input turned out to be.
    public enum Outcome: Equatable {
        /// Evaluated as an expression, wrapped into a temporary `main`.
        case expression
        /// Accumulated as declarations, without a temporary `main`.
        case declaration
    }

    /// Evaluates one submitted input.
    ///
    /// `output` receives the program's own line output. It is a parameter rather
    /// than `print` because a caller checking REPL behaviour has to see what the
    /// snippet printed, and reading it back off stdout is not a test.
    @discardableResult
    public func evaluate(
        _ lines: [String],
        output: @escaping (String) -> Void = { print($0) }
    ) throws -> Outcome {
        let source = lines.joined(separator: "\n")
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if isExpressionInput(trimmed) {
            // `print(...)` is left alone rather than wrapped again: wrapping it
            // would print the null a `print` call returns, so `print(1)` would
            // come out as an extra blank line.
            let body = trimmed.hasPrefix("print(") || trimmed.hasPrefix("print ")
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

        // Declaration input: accumulate, then re-register so the next input can
        // refer to it. A session with no `main` is the normal case here, which
        // is what `tolerateMissingMain` is for.
        let module = try parse(source)
        accumulatedDeclarations.append(contentsOf: module.declarations)
        let runnable = moduleForRun(declarations: accumulatedDeclarations)
        try run(runnable, output: output, tolerateMissingMain: true)
        return .declaration
    }

    // MARK: - Running

    private func run(
        _ module: Module,
        output: @escaping (String) -> Void,
        tolerateMissingMain: Bool
    ) throws {
        // The checker is not optional on this path: lowering reads its inference
        // to type the nodes, so an untypeable input cannot be lowered at all.
        // Reported as a REPL type error, not swallowed.
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        if !errors.isEmpty {
            throw ReplError.typeError(
                errors.map { ErrorFormatter.formatTypeError($0, source: "") }
                    .joined(separator: "\n")
            )
        }
        // A session that is still all declarations is the REPL's normal state,
        // and the lowerer treats it as an error -- it requires an executable
        // program and throws *while lowering*. Decided by asking whether `main`
        // exists rather than by matching the error message, which would drift
        // the day it is reworded.
        if tolerateMissingMain, !Self.hasMainFunction(module) { return }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let hir = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        let executor = HIRExecutor()
        executor.outputSink = output
        do {
            try executor.run(module: hir)
        } catch let error as RuntimeError where tolerateMissingMain {
            if case .mainNotFound = error { return }
            throw error
        }
    }

    /// Whether the module declares a `main`.
    ///
    /// The REPL asks this before lowering, because "no main yet" is a state the
    /// lowerer treats as an error and a state a REPL session is normally in.
    private static func hasMainFunction(_ module: Module) -> Bool {
        module.declarations.contains { declaration in
            if case .funcDecl(let function) = declaration { return function.name == "main" }
            return false
        }
    }

    /// The module the engine actually runs. Assembled fresh per evaluation —
    /// that is the "fresh instance per evaluation" shape the REPL has always
    /// had, now stated once instead of once per engine.
    private func moduleForRun(declarations: [TopLevelDecl]) -> Module {
        Module(
            declarations: declarations,
            imports: [], exports: [],
            location: SourceLocation(line: 0, column: 0, fileName: Self.replFileName)
        )
    }

    // MARK: - Input classification

    /// File name every REPL-evaluated node carries. It is a placeholder, and it
    /// is spelled as one so a diagnostic pointing here is visibly *not* a file.
    public static let replFileName = "<repl>"

    /// Declaration starters. Input beginning with one of these is accumulated
    /// rather than evaluated; everything else is treated as an expression.
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
        let lexer = Lexer(source: source, fileName: Self.replFileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: Self.replFileName)
        let result = parser.parseModuleCollectingErrors()
        if !result.errors.isEmpty {
            throw ReplError.parseError(
                result.errors
                    .map { ErrorFormatter.formatParserError($0, source: source) }
                    .joined(separator: "\n")
            )
        }
        return result.module
    }
}

// MARK: - Errors

/// REPL-facing errors: the two ways an input fails before it can run.
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

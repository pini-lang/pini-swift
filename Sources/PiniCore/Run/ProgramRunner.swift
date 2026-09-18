import Foundation

/// Runs a Pini program or package: the engine-agnostic entry point the test
/// suite drives, and the successor to `Interpreter`'s execution role.
///
/// WHY THIS EXISTS (LR-4 P4-beta)
///
/// "Run this program" used to be reached only through `Interpreter`, which
/// evaluates the AST directly. That made the test suite the last place still
/// pinned to the AST walk: 429 cases across 51 files drove `Interpreter` for
/// execution alone, so deleting the walk (P4-gamma) would have taken them with
/// it — and with them the only evidence that the HIR engine runs real
/// programs, as opposed to selected corpus fixtures.
///
/// This type keeps the surface those callers actually use and implements it as
///
///     check -> lower -> execute
///
/// on the engine the default flip (`P4-alpha`) selected. The front end is the
/// same `TypeChecker` and the same `HIRLowerer` the CLI's other HIR paths use,
/// which is what makes this a migration rather than a second implementation.
///
/// WHAT IT DOES NOT OFFER
///
/// The suspension back end that released the OS thread across an `await` is not
/// here, and that is a decision rather than a gap: `ADR-043` retired it, nothing
/// published ever reached it, and it went out with the walk it was built on. The
/// blocking join is the semantics this entry point runs.
///
/// The `runTests` entry point and dynamic-library FFI loading used to be on
/// this list. Both landed in P4-gamma `G-4`: the test entry points are
/// implemented on this type, and raw C bindings resolve through the same
/// `FFILoader` + `ForeignThunk` chain the interpreter uses. The list stays a
/// list of *what is missing* rather than being deleted, so the next reader can
/// still tell a deliberate boundary from an unbuilt one.
///
/// BEHAVIOUR CHANGE, STATED
///
/// This entry point type-checks before running. The AST walk's single-file path
/// ran the semantic gate only, so a type-incorrect program could run and
/// produce a value; here it is refused with the same type errors `pini run`
/// reports. That asymmetry is the change the P4-2 survey registered, met here
/// in its test-suite form; the cases it turns red are counted in the batch
/// record instead of being papered over.
public final class ProgramRunner: DebugHookHost {

    /// Receives the program's own line output.
    public var outputSink: (String) -> Void = { line in print(line) }

    /// Called at each statement boundary that carries a source position.
    public var debugHook: ((DebugContext) throws -> DebugAction)? = nil

    /// `argv()` as the program sees it.
    public var processArguments: [String] = []

    /// Manifest-declared entry files. Empty = undeclared, which means "do not
    /// narrow the search for `main`" (G52 Def-3).
    public var entryFiles: Set<String> = []

    /// The package's `[ffi]` table, carried so callers keep one construction
    /// shape.
    ///
    /// Consumed on both the run and test paths since P4-gamma `G-4`: it reaches
    /// the executor, which resolves raw C bindings against `search_paths`. That
    /// is what made a module with vendored libraries behave the same on both
    /// engines — before `G-4` the HIR side refused such a symbol outright,
    /// which was a capability regression on the default engine.
    public let ffiConfig: FFIConfig

    /// Directory the program's relative paths resolve against.
    public let programBase: String?

    public init(ffiConfig: FFIConfig = .default, programBase: String? = nil) {
        self.ffiConfig = ffiConfig
        self.programBase = programBase
    }

    // MARK: - Running

    /// Runs one module.
    public func run(module: Module) throws {
        try checkEntryConsistency(module)
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        guard errors.isEmpty else {
            throw ProgramRunError.typeCheck(
                errors.map { ErrorFormatter.formatTypeError($0, source: "") }
            )
        }
        // After the type check on purpose: the AST path reaches `mainNotFound`
        // last (declaration registration, then `executeMain`), so asking first
        // here would let "no main" mask a program's real type errors.
        try requireMain(module)
        // Same as every other lowering path: lowering re-infers match
        // scrutinees after the checker popped its scopes, so the table that
        // inference built has to outlive them.
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        // Import declarations live in the module itself, so a single file can
        // be a cross-module caller: `[main|import] helper = "../helper"` then
        // `helper.加法(1, 2)`. The package path merges the import targets
        // before lowering; this path used to go straight to the module
        // lowering, leaving the alias unresolved -- the alias name was then
        // read as a variable and reported as "reference to undeclared
        // variable 'helper'". Same merge, same entry, so the two paths cannot
        // disagree about what an import brings in.
        let (merged, aliasMap) = try HIRLowerer.mergedWithImports(module)
        let lowered = try HIRLowerer.lower(
            module: merged, typeInference: checker.typeInference, moduleAliases: aliasMap
        )
        try execute(lowered)
    }

    /// Runs a package.
    ///
    /// Mirrors `Interpreter.run(package:)`: a single-unit package *is* one
    /// module and goes down the module path; anything larger merges into one
    /// virtual module through `HIRLowerer.lower(package:)` — the same entry the
    /// LLVM package channel already uses.
    public func run(package: Package) throws {
        guard package.fileUnits.count > 1 else {
            let module = package.fileUnits.first?.module
                ?? Module(declarations: [], imports: [], exports: [],
                          location: SourceLocation(line: 0, column: 0, fileName: package.name))
            try run(module: module)
            return
        }
        let checker = TypeChecker()
        try checkEntryConsistency(in: package)
        try checker.check(package: package)
        // Same ordering rule as the module path: type errors first, "no main"
        // last, so the latter cannot mask the former.
        try requireMain(in: package)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try HIRLowerer.lower(package: package, typeInference: checker.typeInference)
        try execute(lowered)
    }

    private func execute(_ module: HIRModule) throws {
        let executor = HIRExecutor(programBase: programBase, ffiConfig: ffiConfig)
        executor.outputSink = outputSink
        executor.processArguments = processArguments
        executor.debugHook = debugHook
        try executor.run(module: module)
    }

    // MARK: - Test blocks

    /// One `|test` block's outcome, as `pini test` reports it.
    ///
    /// Declared here rather than on `Interpreter` because it has to outlive
    /// that type: `G-6` removes the AST walk, and a report shape both engines
    /// produce cannot go with one of them. Moving it now, while both are live,
    /// keeps the move checkable against the old definition.
    public struct TestRunResult {
        public let name: String
        public let passed: Bool
        public let message: String

        public init(name: String, passed: Bool, message: String) {
            self.name = name
            self.passed = passed
            self.message = message
        }
    }

    /// Runs every top-level `|test` function of one module.
    ///
    /// Mirrors `Interpreter.runTests(module:)` — collect, inject a zero value
    /// per declared parameter, run, record a failure instead of stopping, and
    /// never run `main` — with one deliberate difference: lowering is asked for
    /// `requiresMain: false`. A test-only file is a legitimate module with no
    /// `main` (two of the fixtures are exactly that), so requiring an entry
    /// function here would delete a working program shape rather than migrate
    /// it.
    ///
    /// Type checking happens first, and not to tighten anything: the HIR is a
    /// typed tree, so lowering cannot proceed without the checker's inference.
    /// The AST path's `runTests` did no checking of its own either — its
    /// callers checked — and that division is unchanged.
    public func runTests(module: Module) throws -> [TestRunResult] {
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        guard errors.isEmpty else {
            throw ProgramRunError.typeCheck(
                errors.map { ErrorFormatter.formatTypeError($0, source: "") }
            )
        }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let (merged, aliasMap) = try HIRLowerer.mergedWithImports(module)
        let lowered = try HIRLowerer.lower(
            module: merged, typeInference: checker.typeInference,
            moduleAliases: aliasMap, requiresMain: false
        )
        return try runCollectedTests(lowered)
    }

    /// Runs the `|test` functions of a package.
    ///
    /// `fileScope` narrows *which* tests run, never what they can see: the whole
    /// package is lowered into one module, so a test in one file still reaches
    /// another file's symbols, and only the selected files' tests are executed.
    /// That is the interpreter's rule — `pini test <path>` is a filter, not a
    /// smaller program — and the reason each lowered function carries the file
    /// it came from.
    public func runTests(package: Package, fileScope: ((String) -> Bool)? = nil) throws -> [TestRunResult] {
        let checker = TypeChecker()
        try checker.check(package: package)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try HIRLowerer.lower(
            package: package, typeInference: checker.typeInference, requiresMain: false
        )
        return try runCollectedTests(lowered, fileScope: fileScope)
    }

    /// Prepares the lowered module and runs only its `|test` functions.
    ///
    /// `prepare` (not `run`) on purpose: `run` would go looking for `main`,
    /// which a test-only module does not have.
    private func runCollectedTests(_ module: HIRModule,
                                   fileScope: ((String) -> Bool)? = nil) throws -> [TestRunResult] {
        let executor = HIRExecutor(programBase: programBase, ffiConfig: ffiConfig)
        executor.outputSink = outputSink
        executor.processArguments = processArguments
        try executor.prepare(module: module)
        var results: [TestRunResult] = []
        for function in module.functions where function.isTest {
            if let scope = fileScope, !scope(function.sourceFile) { continue }
            results.append(runOneTest(function, on: executor))
        }
        return results
    }

    /// One collected test: inject the parameters' zero values, then call it.
    ///
    /// A failing test is a result, not an abort — one failure must not hide the
    /// tests after it. Same rule as the AST path's `executeCollectedTest`.
    private func runOneTest(_ function: HIRFunction, on executor: HIRExecutor) -> TestRunResult {
        let args = function.params.map { Self.zeroValue(forTestParam: $0.type) }
        do {
            _ = try executor.callFunction(named: function.name, args: args)
            return TestRunResult(name: function.name, passed: true, message: "")
        } catch {
            return TestRunResult(name: function.name, passed: false, message: "\(error)")
        }
    }

    /// R4 parameter injection: the zero value of each declared type.
    ///
    /// Kept identical to `Interpreter.zeroValueForTestParam` (String → `""`,
    /// integer → `0`, Bool → `false`, float → `0.0`, anything else → `null`),
    /// because a test that passes on one engine and fails on the other would
    /// make the two channels disagree about the language rather than about the
    /// implementation.
    static func zeroValue(forTestParam type: HIRType) -> Value {
        switch type {
        case .i8, .u8, .i32, .i64, .u64: return .int(0)
        case .f64: return .float(0)
        case .boolean: return .bool(false)
        case .string: return .string("")
        default: return .null
        }
    }

    // MARK: - Entry consistency

    /// G52 Def-3: when the manifest declares entry files, `main` must be in one.
    ///
    /// Declaring an entry is a promise that "the program starts here"; a `main`
    /// elsewhere is configuration disagreeing with code, not a licence to find
    /// some other `main`. An empty set means undeclared and does not intervene.
    private func checkEntryConsistency(_ module: Module) throws {
        guard !entryFiles.isEmpty else { return }
        guard let declared = mainDeclaringLocation(module) else { return }
        try validateEntry(declared)
    }

    /// The same rule for a package. Checked on both paths because both paths
    /// can run a package: omitting it here would let a package whose manifest
    /// declares an entry run a `main` from some other file — exactly the
    /// configuration/code disagreement the check exists to catch.
    private func checkEntryConsistency(in package: Package) throws {
        guard !entryFiles.isEmpty else { return }
        guard let declared = mainDeclaringLocation(of: package) else { return }
        try validateEntry(declared)
    }

    private func validateEntry(_ declared: SourceLocation) throws {
        let declaredNorm = Self.normalizeEntryPath(declared.fileName)
        let hit = entryFiles.contains { entry in
            let entryNorm = Self.normalizeEntryPath(entry)
            return declaredNorm == entryNorm || declaredNorm.hasSuffix("/" + entryNorm)
        }
        guard !hit else { return }
        throw RuntimeError.entryMainMismatch(
            entries: entryFiles.sorted(),
            declaredIn: declared.fileName,
            location: declared
        )
    }

    private func mainDeclaringLocation(_ module: Module) -> SourceLocation? {
        for declaration in module.declarations {
            if case .funcDecl(let function) = declaration, function.name == "main" {
                return function.location
            }
        }
        return nil
    }

    private func mainDeclaringLocation(of package: Package) -> SourceLocation? {
        for unit in package.fileUnits {
            if let location = mainDeclaringLocation(unit.module) { return location }
        }
        return nil
    }

    // MARK: - Main presence

    /// Parity with the AST path's `RuntimeError.mainNotFound`.
    ///
    /// The two engines meet the same condition in different phases: the AST
    /// path runs a program and throws `mainNotFound` from `executeMain`, while
    /// the lowerer refuses a `main`-less module *while lowering*, because what
    /// it is building is an executable program. Asking the condition here —
    /// rather than catching the lowerer's error and matching its message —
    /// keeps the error type callers already assert on and survives a reword.
    private func requireMain(_ module: Module) throws {
        guard mainDeclaringLocation(module) == nil else { return }
        throw RuntimeError.mainNotFound(
            location: SourceLocation(line: 0, column: 0, fileName: "")
        )
    }

    private func requireMain(in package: Package) throws {
        guard mainDeclaringLocation(of: package) == nil else { return }
        throw RuntimeError.mainNotFound(
            location: SourceLocation(line: 0, column: 0, fileName: "")
        )
    }

    /// Collapses repeated separators and drops a leading `./`, for entry
    /// comparison. Not absolutised: both sides are built on the module root and
    /// the comparison also accepts a suffix match, which tolerates an absolute
    /// prefix on the caller's side.
    static func normalizeEntryPath(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        if normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        return normalized
    }
}

// MARK: - Errors

/// What can refuse a program before it runs on the HIR path.
public enum ProgramRunError: LocalizedError {
    /// The program does not type-check. The AST walk's single-file path did not
    /// check, so this is a new refusal rather than a new defect — see the
    /// "behaviour change" note on `ProgramRunner`.
    case typeCheck([String])

    public var errorDescription: String? {
        switch self {
        case .typeCheck(let messages):
            return "类型错误:\n" + messages.joined(separator: "\n")
        }
    }
}

import Foundation
import PiniSyntax
import PiniSemantics
import PiniIR

/// 运行 Pini 程序或包：测试套件与 CLI 共用的引擎无关入口，流程为 检查 → 降低 → 执行。
/// 执行前先过类型检查，类型错误因此在此被拒而非产出值；`await` 期间不释放线程，join 即阻塞语义。
/// `runTests` 与动态库 FFI 已在本类型落地：后者经 `FFILoader` + `ForeignThunk`，与解释器同一链路。
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

    /// 包的 `[ffi]` 表，随类型下传，使运行与测试两条路径共用一种构造形状。
    /// 执行器据此按 `search_paths` 解析裸 C 绑定，故带随附库的模块在两个引擎上行为一致。
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
        // 单文件也能跨模块调用：import 声明在模块内，别名需在降载前并入模块。
        // 与包路径共用同一合并入口，故两条路径对「import 带进来什么」不会给出不同答案。
        let (merged, aliasMap) = try IRLowerer.mergedWithImports(module)
        let lowered = try IRLowerer.lower(
            module: merged, typeInference: checker.typeInference, moduleAliases: aliasMap
        )
        try execute(lowered)
    }

    /// 运行一个包：单单元包即一个模块，走模块路径；多单元经 `IRLowerer.lower(package:)`
    /// 合并为一个虚拟模块，与 LLVM 包通道同一入口。
    public func run(package: Package) throws {
        guard package.fileUnits.count > 1 else {
            let module =
                package.fileUnits.first?.module
                ?? Module(
                    declarations: [], imports: [], exports: [],
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
        let lowered = try IRLowerer.lower(package: package, typeInference: checker.typeInference)
        try execute(lowered)
    }

    private func execute(_ module: IRModule) throws {
        let executor = IRExecutor(programBase: programBase, ffiConfig: ffiConfig)
        executor.outputSink = outputSink
        executor.processArguments = processArguments
        executor.debugHook = debugHook
        try executor.run(module: module)
    }

    // MARK: - Test blocks

    /// 一个 `|test` 块的结果，`pini test` 按此报告。放在此处而非 `Interpreter`：
    /// 它是两个引擎共用的报告形状，不应随任一引擎退役。
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

    /// 降载传 `requiresMain: false`：只有测试的文件是合法模块，强求入口会砍掉一种可用程序形状。
    /// 类型检查先行，因为 IR 是带类型的树——没有检查器的推断就无法降载。
    public func runTests(module: Module) throws -> [TestRunResult] {
        try runCollectedTests(lowerTests(module: module))
    }

    /// 测试模式的降载（不执行）：两条通道的「跑哪些测试、什么顺序」都出自这一步。
    /// 收窄范围（`isTest`/`sourceFile`）、零值注入规则与函数表顺序在此一次定下；
    /// 解释器通道执行它、LLVM 通道发射它，故两侧不会各自漂移。不跑测试、不建执行器。
    public func lowerTests(module: Module) throws -> IRModule {
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        guard errors.isEmpty else {
            throw ProgramRunError.typeCheck(
                errors.map { ErrorFormatter.formatTypeError($0, source: "") }
            )
        }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let (merged, aliasMap) = try IRLowerer.mergedWithImports(module)
        return try IRLowerer.lower(
            module: merged, typeInference: checker.typeInference,
            moduleAliases: aliasMap, requiresMain: false
        )
    }

    /// 跑一个包里被 `fileScope` 选中的 `|test`。筛选只决定跑哪些，不缩小可见范围：
    /// 整包降载为一个模块，跨文件符号仍可达，故每个降载函数都带着它的来源文件。
    public func runTests(package: Package, fileScope: ((String) -> Bool)? = nil) throws -> [TestRunResult] {
        try runCollectedTests(lowerTests(package: package), fileScope: fileScope)
    }

    /// 测试模式的**降载**（不执行），包级版。理由与 `lowerTests(module:)` 逐字相同
    /// （两通道共用一份降载），故不重复一遍。
    public func lowerTests(package: Package) throws -> IRModule {
        let checker = TypeChecker()
        try checker.check(package: package)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(
            package: package, typeInference: checker.typeInference, requiresMain: false
        )
    }

    /// 在已降载的模块上只跑 `|test`：用 `prepare` 而非 `run`，后者会去找 `main`。
    private func runCollectedTests(
        _ module: IRModule,
        fileScope: ((String) -> Bool)? = nil
    ) throws -> [TestRunResult] {
        let executor = IRExecutor(programBase: programBase, ffiConfig: ffiConfig)
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

    /// 跑一个收集到的测试：按参数类型注入零值后调用。失败是一条结果，不中断后续测试。
    /// 断言失败只取消息本体（不带 `at <位置>`）：那是空位置，且另一后端的报告须逐字节相同。
    /// 其余错误保留完整描述，含位置——那属于运行时故障，正是最需要位置的时候。
    private func runOneTest(_ function: IRFunction, on executor: IRExecutor) -> TestRunResult {
        let args = function.params.map { Self.zeroValue(forTestParam: $0.type) }
        do {
            _ = try executor.callFunction(named: function.name, args: args)
            return TestRunResult(name: function.name, passed: true, message: "")
        } catch let error as RuntimeError {
            if case .assertionFailed(let message, _) = error {
                return TestRunResult(name: function.name, passed: false, message: message)
            }
            return TestRunResult(name: function.name, passed: false, message: "\(error)")
        } catch {
            return TestRunResult(name: function.name, passed: false, message: "\(error)")
        }
    }

    /// 测试参数注入：整数 `0`、浮点 `0.0`、布尔 `false`、字符串 `""`、其余 `null`。
    /// 须与解释器侧逐项一致：同一测试在两引擎上结论不同，等于两通道对语言本身有分歧。
    static func zeroValue(forTestParam type: IRType) -> Value {
        switch type {
        case .i8, .u8, .i32, .i64, .u64: return .int(0)
        case .f64: return .float(0)
        case .boolean: return .bool(false)
        case .string: return .string("")
        /// `Char` 单列一臂并返回 `null`：语言没有「空字符」，任何注入零值都会违反单字素不变量。
        /// 写出来是为了让这个选择可见，而不是被 `default` 吸收。
        case .char: return .null
        default: return .null
        }
    }

    // MARK: - Entry consistency

    /// 清单声明了入口文件时，`main` 必须落在其中之一：声明入口即承诺「程序从这里开始」，
    /// 别处的 `main` 是配置与代码不一致。空集表示未声明，不干预。
    private func checkEntryConsistency(_ module: Module) throws {
        guard !entryFiles.isEmpty else { return }
        guard let declared = mainDeclaringLocation(module) else { return }
        try validateEntry(declared)
    }

    /// 包路径的同一条规则：两条路径都能跑包，漏掉这里就会放过配置与代码不一致。
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

    /// 与 AST 路径的 `RuntimeError.mainNotFound` 对齐：两个引擎在不同阶段遇到同一条件，
    /// 这里主动判条件而不是捕获降载器的报错再匹配文案，调用方断言的错误类型因此不变。
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

    /// 折叠重复分隔符并去掉前导 `./`，供入口比较。不做绝对化：两侧都以模块根为基，
    /// 比较还接受后缀匹配，调用方的绝对前缀不影响结论。
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

/// What can refuse a program before it runs on the IR path.
public enum ProgramRunError: LocalizedError {
    /// 程序未通过类型检查：AST 单文件路径不检查，故这是新增的拒绝，不是新增的缺陷。
    case typeCheck([String])

    public var errorDescription: String? {
        switch self {
        case .typeCheck(let messages):
            return "类型错误:\n" + messages.joined(separator: "\n")
        }
    }
}

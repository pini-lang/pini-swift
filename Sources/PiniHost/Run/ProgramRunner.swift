import Foundation
import PiniSyntax
import PiniSemantics
import PiniIR

/// 运行 Pini 程序或包：测试套件与 CLI 共用的引擎无关入口，流程为 检查 → 降低 → 执行。
/// 执行前先过类型检查，类型错误因此在此被拒而非产出值；`await` 期间不释放线程，join 即阻塞语义。
/// `runTests` 与动态库 FFI 已在本类型落地：后者经 `FFILoader` + `ForeignThunk`，与解释器同一链路。
public final class ProgramRunner: DebugHookHost {

    /// 接收程序自己的行输出。
    public var outputSink: (String) -> Void = { line in print(line) }

    /// 在每个带源码位置的语句边界上调用。
    public var debugHook: ((DebugContext) throws -> DebugAction)? = nil

    /// 程序看到的 `argv()`。
    public var processArguments: [String] = []

    /// 清单声明的入口文件。空集表示未声明，即「不缩小 `main` 的搜索范围」。
    public var entryFiles: Set<String> = []

    /// 包的 `[ffi]` 表，随类型下传，使运行与测试两条路径共用一种构造形状。
    /// 执行器据此按 `search_paths` 解析裸 C 绑定，故带随附库的模块在两个引擎上行为一致。
    public let ffiConfig: FFIConfig

    /// 程序的相对路径以此为基准解析。
    public let programBase: String?

    public init(ffiConfig: FFIConfig = .default, programBase: String? = nil) {
        self.ffiConfig = ffiConfig
        self.programBase = programBase
    }

    // MARK: - 运行

    /// Runs one module.
    /// 装配在入口做一次：CLI 已装配过的模块原样返回，进程内直接构造模块的调用方（测试、嵌入）也拿得到标准库。
    public func run(module: Module) throws {
        let assembled = FrontEnd.assemble(module: module)
        try checkEntryConsistency(assembled)
        let checker = TypeChecker()
        let errors = checker.checkCollecting(
            module: assembled, foreignConstantFailures: [:])
        guard errors.isEmpty else {
            throw ProgramRunError.typeCheck(
                errors.map { ErrorFormatter.formatTypeError($0, source: "") }
            )
        }
        // 放在类型检查之后是有意的：AST 路径最后才走到 `mainNotFound`
        // （先登记声明，再 `executeMain`），先问就会让「没有 main」掩盖真正的类型错误。
        try requireMain(assembled)
        // 与其他降载路径一致：检查器弹出作用域后，降载还要重新推导 match 的被检值，
        // 所以推导建的这张表必须活过作用域。
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        // 单文件也能跨模块调用：import 声明在模块内，别名需在降载前并入模块。
        // 与包路径共用同一合并入口，故两条路径对「import 带进来什么」不会给出不同答案。
        let (merged, aliasMap) = try IRLowerer.mergedWithImports(assembled)
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
        let assembled = package.assemblingStdlib()
        let checker = TypeChecker()
        try checkEntryConsistency(in: assembled)
        try checker.check(package: assembled, foreignConstantFailures: [:])
        // 与模块路径同一顺序规则：先报类型错误，「没有 main」最后，后者不能盖住前者。
        try requireMain(in: assembled)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(package: assembled, typeInference: checker.typeInference)
        try execute(lowered)
    }

    private func execute(_ module: IRModule) throws {
        let executor = IRExecutor(programBase: programBase, ffiConfig: ffiConfig)
        executor.outputSink = outputSink
        executor.processArguments = processArguments
        executor.debugHook = debugHook
        try executor.run(module: module)
    }

    // MARK: - 测试块

    /// 一个 `|test` 块的结果，`pini test` 按此报告。放在此处而非 `Interpreter`：
    /// 它是两个引擎共用的报告形状，不应随任一引擎退役。
    public struct TestRunResult {
        public let name: String
        public let passed: Bool
        public let message: String
        /// 声明该用例的文件。报告只在失败行带上它 —— 一句断言文案在几十个测试文件里定位不到。
        public let sourceFile: String
        /// 失败点位置：语句边界补齐的源码位置，断言在辅助函数里失败时指向那一行而不是测试声明处。
        /// 占位位置（行号 0）在这里折成 `nil`，报告据此退回「只带文件」。
        public let location: SourceLocation?

        public init(
            name: String, passed: Bool, message: String, sourceFile: String = "",
            location: SourceLocation? = nil
        ) {
            self.name = name
            self.passed = passed
            self.message = message
            self.sourceFile = sourceFile
            self.location = location
        }
    }

    /// 降载传 `requiresMain: false`：只有测试的文件是合法模块，强求入口会砍掉一种可用程序形状。
    /// 类型检查先行，因为 IR 是带类型的树——没有检查器的推断就无法降载。
    public func runTests(
        module: Module, nameFilter: String? = nil, nameSkip: [String] = []
    ) throws -> [TestRunResult] {
        try runCollectedTests(
            lowerTests(module: module), nameFilter: nameFilter, nameSkip: nameSkip)
    }

    /// 测试模式的降载（不执行）：两条通道的「跑哪些测试、什么顺序」都出自这一步。
    /// 收窄范围（`isTest`/`sourceFile`）、零值注入规则与函数表顺序在此一次定下；
    /// 解释器通道执行它、LLVM 通道发射它，故两侧不会各自漂移。不跑测试、不建执行器。
    public func lowerTests(module: Module) throws -> IRModule {
        let checker = TypeChecker()
        let errors = checker.checkCollecting(
            module: module, foreignConstantFailures: [:])
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

    /// 跑一个包里被 `fileScope` 与 `nameFilter` 选中的 `|test`。收窄只决定跑哪些，不缩小可见范围：
    /// 整包降载为一个模块，跨文件符号仍可达，故每个降载函数都带着它的来源文件。
    public func runTests(
        package: Package, fileScope: ((String) -> Bool)? = nil, nameFilter: String? = nil,
        nameSkip: [String] = []
    ) throws -> [TestRunResult] {
        try runCollectedTests(
            lowerTests(package: package), fileScope: fileScope, nameFilter: nameFilter,
            nameSkip: nameSkip)
    }

    /// 执行一份已降载的测试模块。调用方已按声明做一致性校验时，用它避免重复降载与重复校验。
    public func runLoweredTests(
        _ module: IRModule, nameFilter: String? = nil, nameSkip: [String] = []
    ) throws -> [TestRunResult] {
        try runCollectedTests(module, nameFilter: nameFilter, nameSkip: nameSkip)
    }

    /// 测试名是否被本次收窄选中：`nameFilter` 取子串命中，`nameSkip` 在其结果上排除。
    /// 收集侧据此计数、执行侧据此跳过——规则只写这一处，两边不会各判一套。
    public static func selectsTest(
        name: String, nameFilter: String?, nameSkip: [String]
    ) -> Bool {
        if let nameFilter, !name.contains(nameFilter) { return false }
        return !nameSkip.contains { !$0.isEmpty && name.contains($0) }
    }

    /// 测试模式的**降载**（不执行），包级版。理由与 `lowerTests(module:)` 逐字相同
    /// （两通道共用一份降载），故不重复一遍。
    public func lowerTests(package: Package) throws -> IRModule {
        let checker = TypeChecker()
        try checker.check(package: package, foreignConstantFailures: [:])
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(
            package: package, typeInference: checker.typeInference, requiresMain: false
        )
    }

    /// 在已降载的模块上只跑 `|test`：用 `prepare` 而非 `run`，后者会去找 `main`。
    /// 名字筛选在这里生效，故未匹配的用例不会被执行，其失败也不会被筛选掩盖。
    private func runCollectedTests(
        _ module: IRModule,
        fileScope: ((String) -> Bool)? = nil,
        nameFilter: String? = nil,
        nameSkip: [String] = []
    ) throws -> [TestRunResult] {
        let executor = IRExecutor(programBase: programBase, ffiConfig: ffiConfig)
        executor.outputSink = outputSink
        executor.processArguments = processArguments
        try executor.prepare(module: module)
        var results: [TestRunResult] = []
        for function in module.functions where function.isTest {
            if let scope = fileScope, !scope(function.sourceFile) { continue }
            guard Self.selectsTest(
                name: function.name, nameFilter: nameFilter, nameSkip: nameSkip) else { continue }
            results.append(runOneTest(function, on: executor))
        }
        return results
    }

    /// 跑一个收集到的测试：按参数类型注入零值后调用。失败是一条结果，不中断后续测试。
    /// 断言失败取消息本体、其余错误取运行时正文：位置不再拼进消息，改由失败行单独给出，
    /// 故另一后端的报告里同一格仍是同一个字符串。
    private func runOneTest(_ function: IRFunction, on executor: IRExecutor) -> TestRunResult {
        let args = function.params.map { Self.zeroValue(forTestParam: $0.type) }
        do {
            _ = try executor.callFunction(named: function.name, args: args)
            return TestRunResult(
                name: function.name, passed: true, message: "", sourceFile: function.sourceFile)
        } catch let error as RuntimeError {
            let message: String
            if case .assertionFailed(let text, _) = error {
                message = text
            } else {
                message = ErrorFormatter.runtimeMessage(error)
            }
            return TestRunResult(
                name: function.name, passed: false, message: message,
                sourceFile: function.sourceFile,
                location: error.location.isPlaceholder ? nil : error.location)
        } catch {
            return TestRunResult(
                name: function.name, passed: false, message: "\(error)",
                sourceFile: function.sourceFile)
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
        // `Char` 单列一臂并返回 `null`：语言没有「空字符」，任何注入零值都会违反单字素不变量。
        // 单独写出来是为了让这个选择可见，而不是被 `default` 吸收。
        case .char: return .null
        default: return .null
        }
    }

    // MARK: - 入口一致性

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

    // MARK: - main 是否存在

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

// MARK: - 错误

extension ProgramRunner.TestRunResult {
    /// 失败行的位置栏：有失败点就打 `文件:行:列`，只有声明文件就只打文件，两者都没有就整栏省掉。
    /// 报告的三处拼装（工作区、模块、单文件）都读这一处，免得同一条规则各写一遍。
    public var positionLabel: String {
        if let location { return "（\(location.reportPosition)）" }
        return sourceFile.isEmpty ? "" : "（\(sourceFile)）"
    }
}

/// IR 路径上程序开跑之前可能被拒的原因。
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

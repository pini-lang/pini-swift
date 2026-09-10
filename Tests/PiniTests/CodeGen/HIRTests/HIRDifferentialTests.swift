import XCTest
@testable import PiniCore

/// M4 batch 2 differential tests: the new HIR pipeline (HIRLowerer ->
/// IREmitter -> lli) must produce byte-identical stdout to the interpreter
/// for every slice fixture. Lockstep harness mirrors IRExecutionTests.
///
/// Excluded surface (tracked, not silently skipped):
/// - print(F64): %f vs the interpreter's shortest repr — LR-8 adjudicated to
///   shortest round-trip; lands with bk_double_to_string (batch B of the
///   pre-M5 float mini batch, issue-print-f64-format-parity-2026-09-07).
///   F64 *comparisons* are covered since the interpreter fix landed
///   (issue-interpreter-float-compare-2026-09-07, testDiffFloatCompare).
final class HIRDifferentialTests: XCTestCase {

    /// Locates the runtime dylib (swift build product in the repo-local
    /// .build/debug). Required since print(F64) routes through
    /// bk_double_to_string (LR-8).
    private func locateRuntimeDylib() -> String? {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) { break }
            url = url.deletingLastPathComponent()
        }
        let buildDir = (url.path as NSString).appendingPathComponent(".build/debug")
        for ext in ["dylib", "so"] {
            let cand = (buildDir as NSString).appendingPathComponent("libPiniRuntime.\(ext)")
            if FileManager.default.fileExists(atPath: cand) { return cand }
        }
        return nil
    }

    private func runNewPipeline(_ source: String) throws -> String {
        try LLVMGate.requireLLI()
        let dylib = try LLVMGate.requireRuntimeDylib(locateRuntimeDylib())
        let fileName = "test.pini"
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        XCTAssertTrue(errors.isEmpty, "slice sources must typecheck: \(errors)")
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let hir = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        let ir = IREmitter().emit(module: hir)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_hir_diff_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: tmpIR) }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let lli = LLVMToolchain.lliPath else {
            throw NSError(domain: "LLIUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "lli not available"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lli)
        process.arguments = ["--dlopen=\(dylib)", tmpIR]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("lli exited \(process.terminationStatus) for IR:\n\(ir)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runInterpreter(_ source: String) throws -> String {
        let fileName = "test.pini"
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let interpreter = Interpreter()
        try interpreter.run(module: module)

        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func assertParity(fixtureName: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try loadPiniFixture(fixtureName, filePath: #filePath)
        let interpreterOutput = try runInterpreter(source)
        let llvmOutput = try runNewPipeline(source)
        XCTAssertEqual(llvmOutput, interpreterOutput,
                       "\(fixtureName): HIR pipeline output must match interpreter byte-for-byte\n--- interpreter ---\n\(interpreterOutput)--- hir pipeline ---\n\(llvmOutput)",
                       file: file, line: line)
        XCTAssertFalse(llvmOutput.isEmpty, "\(fixtureName): expected non-empty output", file: file, line: line)
    }

    // MARK: - G13 batch 2: multi-file package differential

    /// Loads an examples/ corpus directory as a `Package` (same entry as the
    /// CLI's directory branch: manifest + recursive scan + deterministic sort).
    private func loadPackageCorpus(_ relPath: String) throws -> (Package, ModuleManifest?) {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) { break }
            url = url.deletingLastPathComponent()
        }
        let dir = url.appendingPathComponent(relPath).path
        let manifest = try FileLoader.loadManifest(directory: dir)
        let package = try FileLoader.loadDirectory(path: dir, manifest: manifest)
        return (package, manifest)
    }

    /// Absolute path of a repo-relative corpus file (examples/...).
    private func locateCorpusFile(_ relPath: String) -> String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) { break }
            url = url.deletingLastPathComponent()
        }
        return (url.path as NSString).appendingPathComponent(relPath)
    }

    /// Interpreter channel for a package: mirrors `Interpreter.run(package:)`
    /// (single-file delegate inside). The manifest's `[ffi]` table (if any)
    /// feeds the interpreter so foreign dlsym bindings resolve their search
    /// paths exactly like the CLI directory branch.
    private func runPackageInterpreter(_ package: Package, ffiConfig: FFIConfig = .default) throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let interpreter = Interpreter(ffiConfig: ffiConfig)
        try interpreter.run(package: package)

        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// HIR channel for a package: package semantic + type-check, then
    /// `HIRLowerer.lower(package:)` -> IREmitter -> lli (D3 in-process driver).
    private func runPackageNewPipeline(_ package: Package, extraDlopens: [String] = []) throws -> String {
        try LLVMGate.requireLLI()
        let dylib = try LLVMGate.requireRuntimeDylib(locateRuntimeDylib())
        let semantic = SemanticAnalyzer()
        try semantic.analyze(package: package)
        let checker = TypeChecker()
        try checker.check(package: package)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let hir = try HIRLowerer.lower(package: package, typeInference: checker.typeInference)
        let ir = IREmitter().emit(module: hir)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_hir_diff_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: tmpIR) }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let lli = LLVMToolchain.lliPath else {
            throw NSError(domain: "LLIUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "lli not available"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lli)
        // G14 (D-C=C1): foreign search-path libraries ride along as extra
        // --dlopen entries so dlsym-resolved symbols (ffi_atoi, ...) link
        // under lli exactly like the interpreter's FFILoader.
        process.arguments = extraDlopens.map { "--dlopen=\($0)" } + ["--dlopen=\(dylib)", tmpIR]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("lli exited \(process.terminationStatus) for IR:\n\(ir)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func assertPackageParity(_ relPath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (package, manifest) = try loadPackageCorpus(relPath)
        let interpreterOutput = try runPackageInterpreter(package, ffiConfig: manifest?.ffi ?? .default)
        // G14: resolve the manifest's foreign search-path libraries for the
        // extra --dlopen pass (lib<name>.dylib inside each search path).
        let ffi = manifest?.ffi
        let extraDlopens = (ffi?.libs ?? []).flatMap { lib -> [String] in
            (ffi?.searchPaths ?? []).compactMap { sp in
                let dylibPath = (sp as NSString).appendingPathComponent("lib\(lib).dylib")
                return FileManager.default.fileExists(atPath: dylibPath) ? dylibPath : nil
            }
        }
        let llvmOutput = try runPackageNewPipeline(package, extraDlopens: extraDlopens)
        XCTAssertEqual(llvmOutput, interpreterOutput,
                       "\(relPath): HIR pipeline output must match interpreter byte-for-byte\n--- interpreter ---\n\(interpreterOutput)--- hir pipeline ---\n\(llvmOutput)",
                       file: file, line: line)
        XCTAssertFalse(llvmOutput.isEmpty, "\(relPath): expected non-empty output", file: file, line: line)
    }

    // MARK: - Slice fixtures

    func testDiffArithmeticI32() throws { try assertParity(fixtureName: "testDiffArithmeticI32") }
    func testDiffArithmeticI64() throws { try assertParity(fixtureName: "testDiffArithmeticI64") }
    func testDiffBoolPrint() throws { try assertParity(fixtureName: "testDiffBoolPrint") }
    func testDiffStringPrint() throws { try assertParity(fixtureName: "testDiffStringPrint") }
    func testDiffStringEquality() throws { try assertParity(fixtureName: "testDiffStringEquality") }
    func testDiffIfElse() throws { try assertParity(fixtureName: "testDiffIfElse") }
    func testDiffIfElifElse() throws { try assertParity(fixtureName: "testDiffIfElifElse") }
    func testDiffWhileSum() throws { try assertParity(fixtureName: "testDiffWhileSum") }
    func testDiffNestedIfInWhile() throws { try assertParity(fixtureName: "testDiffNestedIfInWhile") }
    func testDiffCallFunction() throws { try assertParity(fixtureName: "testDiffCallFunction") }
    func testDiffRecursion() throws { try assertParity(fixtureName: "testDiffRecursion") }
    func testDiffUnary() throws { try assertParity(fixtureName: "testDiffUnary") }
    func testDiffVoidFunction() throws { try assertParity(fixtureName: "testDiffVoidFunction") }
    func testDiffMultiTypes() throws { try assertParity(fixtureName: "testDiffMultiTypes") }
    func testDiffCJKFunctionName() throws { try assertParity(fixtureName: "testDiffCJKFunctionName") }
    func testDiffNoTrailingReturn() throws { try assertParity(fixtureName: "testDiffNoTrailingReturn") }
    func testDiffComparisonSet() throws { try assertParity(fixtureName: "testDiffComparisonSet") }
    func testDiffFloatCompare() throws { try assertParity(fixtureName: "testDiffFloatCompare") }
    func testDiffFloatPrint() throws { try assertParity(fixtureName: "testDiffFloatPrint") }

    // MARK: - G1 try-else (Result explicit propagation, ADR-032)

    func testDiffTryElse() throws { try assertParity(fixtureName: "testDiffTryElse") }
    func testDiffTryElseOk() throws { try assertParity(fixtureName: "testDiffTryElseOk") }
    func testDiffTryElseSugar() throws { try assertParity(fixtureName: "testDiffTryElseSugar") }

    // MARK: - G2 array family (read path batch 1, write path batch 2,
    // optional/match/break batch 3)

    func testDiffArrayRead() throws { try assertParity(fixtureName: "testDiffArrayRead") }
    func testDiffArrayWrite() throws { try assertParity(fixtureName: "testDiffArrayWrite") }
    func testDiffArrayGetMatch() throws { try assertParity(fixtureName: "testDiffArrayGetMatch") }

    // MARK: - G2b slice & value formatting family

    func testDiffValueFormat() throws { try assertParity(fixtureName: "testDiffValueFormat") }
    func testDiffSlice() throws { try assertParity(fixtureName: "testDiffSlice") }

    // MARK: - G3 nominal types (struct value layout / object reference + methods + self)

    func testDiffObjectReference() throws { try assertParity(fixtureName: "testDiffObjectReference") }
    func testDiffStructValue() throws { try assertParity(fixtureName: "testDiffStructValue") }

    // MARK: - G7 Optional direct construction (some/nil literal, ?T sugar)

    func testDiffOptionalDirect() throws { try assertParity(fixtureName: "testDiffOptionalDirect") }

    // MARK: - G4 enum family (tagged union, case construction, enum match)

    func testDiffEnum() throws { try assertParity(fixtureName: "testDiffEnum") }
    func testDiffEnumNamed() throws { try assertParity(fixtureName: "testDiffEnumNamed") }

    // MARK: - G5 dict / set / minimal tuple family

    func testDiffDictSet() throws { try assertParity(fixtureName: "testDiffDictSet") }
    func testDiffCow() throws { try assertParity(fixtureName: "testDiffCow") }
    func testDiffCollections() throws { try assertParity(fixtureName: "testDiffCollections") }

    // MARK: - G8 tuple returns

    func testDiffTupleReturn() throws { try assertParity(fixtureName: "testDiffTupleReturn") }

    // MARK: - G9 string deepening (stdlib methods, defer, interpolation)

    func testDiffStdlib() throws { try assertParity(fixtureName: "testDiffStdlib") }
    func testDiffDefer() throws { try assertParity(fixtureName: "testDiffDefer") }
    func testDiffLexical() throws { try assertParity(fixtureName: "testDiffLexical") }

    // MARK: - G10 generic monomorphization

    func testDiffGenericStruct() throws { try assertParity(fixtureName: "testDiffGenericStruct") }
    func testDiffGenericFunc() throws { try assertParity(fixtureName: "testDiffGenericFunc") }

    // MARK: - G6 closures / higher-order functions (fat pointer ABI,
    // reference-capture env, named-function value adapters)

    func testDiffLambda() throws { try assertParity(fixtureName: "testDiffLambda") }
    func testDiffLambdaTyped() throws { try assertParity(fixtureName: "testDiffLambdaTyped") }
    func testDiffHigherOrder() throws { try assertParity(fixtureName: "testDiffHigherOrder") }
    func testDiffClosures() throws { try assertParity(fixtureName: "testDiffClosures") }

    // MARK: - G11 struct deepening (composition flattening, i8 fields,
    // nested arrays with unsafe subscript reads)

    func testDiffStructComposition() throws { try assertParity(fixtureName: "testDiffStructComposition") }
    func testDiffStructI8Fields() throws { try assertParity(fixtureName: "testDiffStructI8Fields") }
    func testDiffMultidimArray() throws { try assertParity(fixtureName: "testDiffMultidimArray") }

    // MARK: - G12 trait family (trait default-implementation dispatch,
    // exhaustive enum match)

    func testDiffTrait() throws { try assertParity(fixtureName: "testDiffTrait") }
    func testDiffValidatedMatch() throws { try assertParity(fixtureName: "testDiffValidatedMatch") }

    // MARK: - G13 batch 1: LazyRef (builtin generic wrapper, once-cache +
    // reference-semantics box; unlocks the G10 lazyref exemption)

    func testDiffLazyRef() throws { try assertParity(fixtureName: "testDiffLazyRef") }

    // MARK: - G13 batch 2: cross-file packages (multi-file HIR lowering)

    func testDiffPackageMultiFile() throws { try assertPackageParity("examples/multifile") }
    func testDiffPackageDemo() throws { try assertPackageParity("examples/package-demo") }

    // MARK: - G14 foreign / FFI family (foreign decl blocks, U64/U8 scalars,
    // *T pointers, load/store/addressof, shim + dlsym bindings)

    /// ffi.pini is a single-file corpus (libc symbols resolve via libSystem
    /// inside lli, no extra --dlopen needed), so it runs through the
    /// single-file differential channel (examples/ has 51 standalone .pini
    /// files each with its own main — loading the directory as one package
    /// would collide).
    func testDiffPackageFFI() throws {
        let source = try String(contentsOfFile: locateCorpusFile("examples/ffi.pini"), encoding: .utf8)
        let interpreterOutput = try runInterpreter(source)
        let llvmOutput = try runNewPipeline(source)
        XCTAssertEqual(llvmOutput, interpreterOutput,
                       "examples/ffi.pini: HIR pipeline output must match interpreter byte-for-byte\n--- interpreter ---\n\(interpreterOutput)--- hir pipeline ---\n\(llvmOutput)")
        XCTAssertFalse(llvmOutput.isEmpty, "examples/ffi.pini: expected non-empty output")
    }

    /// cstring.pini needs libffilib.dylib dlopened alongside the runtime
    /// (project-internal dependency resolved from examples/ffi_module/lib via
    /// the manifest's [ffi] search_paths). The ffi_module directory holds a
    /// single .pini source, so the package channel is safe here.
    func testDiffPackageFFIModule() throws { try assertPackageParity("examples/ffi_module") }
}

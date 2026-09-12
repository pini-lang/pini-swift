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

    /// `stdin` is injected identically on both channels when non-nil. Without
    /// it a fixture that reads stdin compares two different streams (the
    /// interpreter reads the test process's stdin, lli inherits its own), so
    /// the parity claim would be vacuous. The bytes carry no trailing newline
    /// for the `readLine` fixture — see `assertParityWithStdin`.
    /// `programBase` mirrors the CLI's program-base input (nil = the pre-G58
    /// behavior every earlier fixture relies on); `workingDirectory` sets the
    /// directory the lli process starts in. Both default to the old shape, so
    /// existing callers are unaffected. The pair exists so a fixture can
    /// prove the base is honored *while* the CWD points somewhere else — the
    /// only configuration in which base baking is observable.
    private func runNewPipeline(_ source: String, stdin: String? = nil,
                                programBase: String? = nil,
                                workingDirectory: String? = nil) throws -> String {
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
        let emitter = IREmitter()
        emitter.programBase = programBase
        let ir = emitter.emit(module: hir)

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
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let inputPipe = stdin.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        try process.run()
        if let stdin, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inputPipe.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("lli exited \(process.terminationStatus) for IR:\n\(ir)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runInterpreter(_ source: String, stdin inputText: String? = nil,
                                programBase: String? = nil) throws -> String {
        let fileName = "test.pini"
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        // Unbuffered stdin so the injected fd is what `readLine()` sees.
        var originalStdin: Int32 = -1
        if let inputText {
            let inputPipe = Pipe()
            originalStdin = dup(STDIN_FILENO)
            setvbuf(stdin, nil, _IONBF, 0)
            dup2(inputPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
            inputPipe.fileHandleForWriting.write(Data(inputText.utf8))
            inputPipe.fileHandleForWriting.closeFile()
        }

        let interpreter = Interpreter(programBase: programBase)
        try interpreter.run(module: module)

        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        if originalStdin >= 0 {
            dup2(originalStdin, STDIN_FILENO)
            close(originalStdin)
            // The run above read stdin to EOF, which latches the EOF flag on
            // the process-global stream. Restoring the descriptor alone is not
            // enough: every later reader in this process (IOTests injects its
            // own stdin the same way) would otherwise see an immediate EOF and
            // the suite would pass or fail by test ordering.
            clearerr(stdin)
        }
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

    /// Parity for fixtures whose program legitimately prints nothing (the
    /// multi-slot return fixtures only bind the result; nothing is emitted).
    /// The pre-fix failure mode is not a wrong value but a lowering throw or
    /// an lli trap, so empty output is the expected contract. The final
    /// assertion guards the assumption: if someone adds a print to such a
    /// fixture, this fails loudly and points at `assertParity` instead of
    /// silently weakening the check to "" == "".
    private func assertParityAllowingEmptyOutput(fixtureName: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try loadPiniFixture(fixtureName, filePath: #filePath)
        let interpreterOutput = try runInterpreter(source)
        let llvmOutput = try runNewPipeline(source)
        XCTAssertEqual(llvmOutput, interpreterOutput,
                       "\(fixtureName): HIR pipeline output must match interpreter byte-for-byte\n--- interpreter ---\n\(interpreterOutput)--- hir pipeline ---\n\(llvmOutput)",
                       file: file, line: line)
        XCTAssertTrue(interpreterOutput.isEmpty,
                      "\(fixtureName): this fixture is declared output-free; use assertParity instead",
                      file: file, line: line)
    }

    /// Parity for fixtures that read stdin. Both channels must see the SAME
    /// bytes — the interpreter reads the test process's stdin and lli
    /// inherits its own — so the input is injected explicitly. Callers pass
    /// input WITHOUT a trailing newline: the interpreter's `readLine()`
    /// strips it while both LLVM channels hand `fgets`' buffer straight to
    /// `print` (`%s`), trailing newline included. That difference is a
    /// pre-existing legacy/interpreter divergence the M6 flip preserves
    /// (registered in the rewrite plan, same class as print(F64)); the
    /// newline-free input is the slice on which byte parity actually holds.
    private func assertParityWithStdin(fixtureName: String, stdin: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try loadPiniFixture(fixtureName, filePath: #filePath)
        let interpreterOutput = try runInterpreter(source, stdin: stdin)
        let llvmOutput = try runNewPipeline(source, stdin: stdin)
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
    /// Contract entry 40 (`arrayJoin`) had no probe of its own: `testDiffStdlib`
    /// reached `join` among a dozen other features, so its result could not be
    /// attributed to this node. Added in P1-4 to settle the entry's "behaviour
    /// not measured this round" note.
    func testDiffArrayJoin() throws { try assertParity(fixtureName: "testDiffArrayJoin") }
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

    // MARK: - G15 control flow & builtins odds-and-ends family (for-in,
    // continue/labeled break, bitwise + compound-assign operators, io builtins)

    func testDiffForIn() throws { try assertParity(fixtureName: "testDiffForIn") }
    func testDiffContinueBreakLabel() throws { try assertParity(fixtureName: "testDiffContinueBreakLabel") }
    func testDiffBitwiseCompound() throws { try assertParity(fixtureName: "testDiffBitwiseCompound") }
    func testDiffIoFile() throws { try assertParity(fixtureName: "testDiffIoFile") }
    func testDiffStep() throws { try assertParity(fixtureName: "testDiffStep") }

    // MARK: - M6a G16 tuple family (fixtures inherited from the LLVM-driven
    // suites: multi-slot returns, positional index, destructuring, len(tuple),
    // unlabelled tuple construction)

    /// Multi-slot return (`-> (I32, I32,)`): distinct from the single-slot
    /// tuple return covered by G8 (the two are different declarations). The
    /// fixture prints nothing, hence the empty-output variant.
    func testDiffMultiReturnAddAndSub() throws { try assertParityAllowingEmptyOutput(fixtureName: "testDiffMultiReturnAddAndSub") }
    func testDiffMultiReturnSwap() throws { try assertParityAllowingEmptyOutput(fixtureName: "testDiffMultiReturnSwap") }

    func testDiffTupleIndexAccess() throws { try assertParity(fixtureName: "testDiffTupleIndexAccess") }
    func testDiffTupleDestructure() throws { try assertParity(fixtureName: "testDiffTupleDestructure") }
    func testDiffTupleLen() throws { try assertParity(fixtureName: "testDiffTupleLen") }
    func testDiffTupleConstruct() throws { try assertParity(fixtureName: "testDiffTupleConstruct") }
    func testDiffTupleConstructClang() throws { try assertParity(fixtureName: "testDiffTupleConstructClang") }

    // MARK: - M6a G17 builtins and type repair (fixtures inherited from the
    // LLVM-driven suites: readLine, is_ascii_digit, I8 field defaults,
    // unannotated-parameter fallback)

    /// `readLine()` — stdin injected on both channels (input without a
    /// trailing newline; see `assertParityWithStdin`).
    func testDiffReadLine() throws {
        try assertParityWithStdin(fixtureName: "testDiffReadLine", stdin: "hello_stdin")
    }

    func testDiffIsAsciiDigit() throws { try assertParity(fixtureName: "testDiffIsAsciiDigit") }
    func testDiffI8StructField() throws { try assertParity(fixtureName: "testDiffI8StructField") }
    func testDiffParamNoAnnotationVoid() throws { try assertParity(fixtureName: "testDiffParamNoAnnotationVoid") }
    func testDiffParamNoAnnotationReturn() throws { try assertParity(fixtureName: "testDiffParamNoAnnotationReturn") }

    // MARK: - M6a G18 trait default receiver and empty array literal
    // (fixtures inherited from the LLVM-driven suites, plus one fixture for a
    // field-resolution gap the probe exposed: a field declared with a user
    // type resolved only for built-in annotations, so the field read as absent)

    func testDiffTraitDefaultMethod() throws { try assertParity(fixtureName: "testDiffTraitDefaultMethod") }
    func testDiffEmptyArray() throws { try assertParity(fixtureName: "testDiffEmptyArray") }
    func testDiffEnumTypedField() throws { try assertParity(fixtureName: "testDiffEnumTypedField") }

    // MARK: - M6a cross-cutting item a5: program base baking (the CWD differs
    // from the script directory, so a channel that ignores the base is visible)

    /// Unique temp directory, torn down when the test ends (the same shape
    /// IOTests uses for its base-rule fixtures, kept local so this file stays
    /// self-contained).
    private func makeTempDir(_ label: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_hir_base_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// The program base is a code-generation input on every channel: an
    /// unprefixed relative path *literal* is baked against the directory the
    /// script lives in, so a program started from an unrelated CWD still finds
    /// its resource. `res.txt` deliberately exists in both directories with
    /// different contents — a channel that ignored the base would not fail
    /// loudly, it would silently read the decoy, and the byte comparison is
    /// what catches it. Before the base reached the HIR emitter, that channel
    /// resolved `res.txt` against lli's CWD and printed the decoy; the write
    /// half of the fixture fails the same way by landing in the CWD.
    func testDiffIoProgramBase() throws {
        let base = try makeTempDir("base")
        let cwd = try makeTempDir("cwd")
        try "base-resource".write(toFile: (base as NSString).appendingPathComponent("res.txt"),
                                  atomically: true, encoding: .utf8)
        try "cwd-decoy".write(toFile: (cwd as NSString).appendingPathComponent("res.txt"),
                              atomically: true, encoding: .utf8)

        let source = try loadPiniFixture("testDiffIoProgramBase", filePath: #filePath)
        let interpreterOutput = try runInterpreter(source, programBase: base)
        XCTAssertEqual(interpreterOutput, "base-resource\nwritten-to-base\n",
                       "the interpreter resolves an unprefixed path against the program base")

        let hirOutput = try runNewPipeline(source, programBase: base, workingDirectory: cwd)
        XCTAssertEqual(hirOutput, interpreterOutput,
                       "the HIR emitter must bake the base too, or lli reads the CWD decoy\n--- interpreter ---\n\(interpreterOutput)--- hir pipeline ---\n\(hirOutput)")

        XCTAssertEqual(try String(contentsOfFile: (base as NSString).appendingPathComponent("out.txt"),
                                  encoding: .utf8),
                       "written-to-base", "an unprefixed writeFile must land in the program base")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (cwd as NSString).appendingPathComponent("out.txt")),
                       "an unprefixed writeFile must not land in the runtime CWD")
    }
}

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
}

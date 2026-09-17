import XCTest
@testable import PiniCore

/// The LLVM channel, as a single source.
///
/// Three harnesses need to run one program through `HIRLowerer -> IREmitter ->
/// lli` and read its stdout: `HIRDifferentialTests` (the `ast` vs LLVM edge),
/// `RuntimeBackendTests`, and — since the criteria-gap batch — the three-channel
/// corpus check in `HIRExecutorTests`. A second copy of this invocation would be
/// a second thing to keep in sync, which is the failure mode the position-carrier
/// decision (`D-P4-16`) exists to avoid, so the invocation lives here once.
///
/// The gate is `LLVMGate`: an environment that names LLVM but lacks the tools
/// fails hard, an environment that never configured LLVM skips. Both are thrown
/// from here and surface at the calling test method, so a caller that wants the
/// non-LLVM assertions to survive must put its LLVM arm in its own test method —
/// a skip propagates to the whole method.
enum LLVMChannel {

    /// Locates the runtime dylib.
    ///
    /// Search order is deliberately the narrow one the existing callers used:
    /// the repo-root `.build/debug` build product. `swift test` builds into
    /// `.build` by default, so that path is the running scratch product. It is
    /// NOT a general resolver — `PINI_RUNTIME_LIB` is still honored by the CLI
    /// and the gate hint names it, but no caller here relied on it.
    static func locateRuntimeDylib() -> String? {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) { break }
            url = url.deletingLastPathComponent()
        }
        let buildDir = (url.path as NSString).appendingPathComponent(".build/debug")
        for ext in ["dylib", "so"] {
            let candidate = (buildDir as NSString).appendingPathComponent("libPiniRuntime.\(ext)")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Lowers `source` and runs it through `lli`, returning its stdout.
    ///
    /// `programBase` mirrors the CLI's program-base input (nil = the pre-G58
    /// behavior every earlier fixture relies on); `workingDirectory` sets the
    /// directory the `lli` process starts in. A non-zero `lli` exit is a hard
    /// failure rather than an empty string: an empty stdout would compare equal
    /// to another empty stdout and quietly pass.
    static func run(_ source: String, fileName: String = "test.pini",
                    stdin: String? = nil, programBase: String? = nil,
                    workingDirectory: String? = nil) throws -> String {
        try LLVMGate.requireLLI()
        let dylib = try LLVMGate.requireRuntimeDylib(locateRuntimeDylib())

        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        XCTAssertTrue(errors.isEmpty, "LLVM channel sources must typecheck: \(errors)")
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let hir = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        let emitter = IREmitter()
        emitter.programBase = programBase
        let ir = emitter.emit(module: hir)

        let tmpIR = FileManager.default.temporaryDirectory.path
            + "/pini_llvm_channel_\(UUID().uuidString).ll"
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
}

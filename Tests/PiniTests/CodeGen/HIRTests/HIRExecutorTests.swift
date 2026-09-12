import XCTest
@testable import PiniCore

/// P1-2 skeleton tests for `HIRExecutor`, the HIR execution engine.
///
/// Three properties are under test:
///
/// 1. **The minimal core executes, and agrees with the interpreter.** Parity is
///    asserted as byte equality of the whole output stream against the AST
///    interpreter, over the *existing* differential corpus — a whitelist of
///    fixtures that stay inside the skeleton's node set. Reusing the corpus
///    instead of inlining fresh sources is deliberate: the same bytes then feed
///    every channel, so "the channels agree" is a claim about shared input
///    rather than about two hand-written examples that happen to look alike.
///
/// 2. **Unimplemented nodes fail loud, by name.** A skeleton's whole value is
///    that its gaps are *visible*. A node that quietly returned `.null` would
///    make this channel look complete while computing nothing.
///
/// 3. **The step-block contract (ADR-014) holds.**
///
/// WHAT THE FIRST MUTATION RUN TAUGHT THIS FILE
///
/// The fail-loud probes below are built as **HIR nodes by hand**, one node per
/// case, rather than as Pini sources lowered into gaps. The first version used
/// sources, and a mutation that made `arrayLiteral` silently return `.null`
/// slipped past the specific-node assertion: the source `let a = [1, 2, 3]` /
/// `print(a[0])` reaches two gaps, so silencing the first let the second take
/// over and speak up, and the test failed for the wrong reason ("wrong name"
/// instead of "the gap stayed silent"). Hand-built nodes keep each probe down to
/// exactly one gap, so the assertion can only mean what it says.
///
/// The list is a representative sample per node family, not all 44 expression
/// nodes: the *existence* of an anchor for every contract node is
/// `tools/hir-contract-check.py`'s job (it counts 60/60 from the outside), while
/// this file's job is proving the fail-loud *behaviour* on real examples of it.
/// Each implemented grid deletes entries from here as the engine grows.
///
/// The third live channel (HIR → LLVM) is not exercised here; extending the
/// corpus to all three channels is P1-4.
final class HIRExecutorTests: XCTestCase {

    private static let fileName = "test.pini"

    // MARK: - Harness

    /// Lower a source the way every other HIR test does, so a failure here means
    /// the engine is wrong, not that the harness disagreed with the lowerer.
    private func lowerOnly(_ source: String) throws -> HIRModule {
        let tokens = try Lexer(source: source, fileName: HIRExecutorTests.fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: HIRExecutorTests.fileName).parseModule()
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        XCTAssertTrue(errors.isEmpty, "test sources must typecheck: \(errors)")
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// Run one source through both live channels and report what each wrote.
    ///
    /// Both engines are driven through `outputSink` rather than through process
    /// stdout: that is the same funnel the debugger redirects, and it keeps the
    /// comparison free of descriptor plumbing.
    private func runBothChannels(_ source: String) throws -> (ast: [String], hir: [String]) {
        let tokens = try Lexer(source: source, fileName: HIRExecutorTests.fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: HIRExecutorTests.fileName).parseModule()
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        XCTAssertTrue(errors.isEmpty, "test sources must typecheck: \(errors)")

        let interpreter = Interpreter()
        var astLines: [String] = []
        interpreter.outputSink = { astLines.append($0) }
        try interpreter.run(module: module)

        let hir = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        let executor = HIRExecutor()
        var hirLines: [String] = []
        executor.outputSink = { hirLines.append($0) }
        try executor.run(module: hir)

        return (astLines, hirLines)
    }

    /// Runs one source on both channels and requires identical output.
    private func assertParity(_ source: String, label: String) throws {
        let (ast, hir) = try runBothChannels(source)
        XCTAssertFalse(ast.isEmpty, "\(label) produced no output on either channel")
        XCTAssertEqual(hir, ast, "channel output diverged for \(label)")
    }

    // MARK: - Corpus parity

    /// Fixtures that stay inside the P1-2 node set.
    ///
    /// A whitelist, not a discovery rule: a fixture is not *assumed* to be in
    /// range, it is *declared* to be. Adding a name here is the assertion that
    /// the engine handles that fixture end to end, so the list grows with the
    /// implemented node set and never silently.
    private static let inRangeFixtures = [
        "testDiffArithmeticI32",
        "testDiffArithmeticI64",
        "testDiffBoolPrint",
        "testDiffCallFunction",
        "testDiffComparisonSet",
        "testDiffFloatPrint",
    ]

    private static func fixtureDirectory() -> URL {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                break
            }
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("Tests/PiniTests/CodeGen/HIRTests/HIRDifferentialTests")
    }

    /// Arithmetic, comparisons, booleans, floats and user calls, run on both
    /// channels over the shared corpus.
    func testCorpusFixturesAgreeWithTheInterpreter() throws {
        let directory = HIRExecutorTests.fixtureDirectory()
        var exercised = 0

        for name in HIRExecutorTests.inRangeFixtures {
            let path = directory.appendingPathComponent("\(name).pini").path
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                XCTFail("missing fixture \(name).pini at \(path)")
                continue
            }
            let (ast, hir) = try runBothChannels(source)
            XCTAssertFalse(ast.isEmpty, "fixture \(name) produced no output on either channel")
            XCTAssertEqual(hir, ast, "channel output diverged for fixture \(name)")
            exercised += 1
        }

        XCTAssertEqual(
            exercised, HIRExecutorTests.inRangeFixtures.count,
            "every declared in-range fixture must actually run"
        )
    }

    // MARK: - Hand-written parity cover

    /// `while`'s step block (ADR-014) runs once per iteration, after the body.
    ///
    /// No existing in-range fixture covers it (`testDiffStep` also uses `break`,
    /// which the skeleton does not implement), so the step contract would have
    /// shipped unguarded. The interpreter-side rule being mirrored is
    /// `Interpreter.executeWhile`.
    ///
    /// WHY THE LOOP IS DRIVEN BY A BOOLEAN, NOT BY A COUNTER
    ///
    /// The first version of this corpus advanced with `i = i + 1` under
    /// `while i < 3`. A mutation that mapped `add` onto `minus` then made `i`
    /// *decrease*, the condition stayed true forever, and the test **hung**
    /// instead of failing — a mutation that should have produced a red test
    /// produced a timeout, which reads as infrastructure flakiness rather than
    /// as a caught bug. Any loop whose termination depends on the operator under
    /// test has this failure mode.
    ///
    /// So the exit condition here is settled by a plain boolean assignment,
    /// which no arithmetic mutation can influence. The counter still moves — but
    /// in the step block, where a wrong operator changes the *output* (caught by
    /// the parity assertion) rather than the *termination*.
    func testWhileStepBlockAgreesWithTheInterpreter() throws {
        try assertParity("""
        main|func() -> ():
            var i = 0
            var keep = true
            while keep:
                print(i)
                keep = false
            step:
                i = i + 1
                print(i)
            return
        """, label: "while-step")
    }

    /// A function body that runs off its end yields the value of its last
    /// expression statement — the interpreter's `lastValue` rule.
    func testFallingOffTheEndReturnsTheLastExpressionValue() throws {
        try assertParity("""
        bump|func(x: I32,) -> (I32,):
            x + 1

        main|func() -> ():
            print(bump(41))
            return
        """, label: "fall-off-the-end value")
    }

    // MARK: - Fail-loud gaps

    /// One probe per gap. Each probe is a *single* node, so "the error names this
    /// node" cannot be satisfied by a neighbouring gap speaking up instead.
    private static let expressionGaps: [(node: String, expr: HIRExpr)] = [
        ("arrayLiteral", .arrayLiteral(
            elements: [.intConst(value: 1, type: .i32)],
            type: .array(element: .i32))),
        ("subscriptGet", .subscriptGet(
            container: .intConst(value: 0, type: .i32),
            index: .intConst(value: 0, type: .i32),
            type: .i32)),
        ("lenCall", .lenCall(argument: .intConst(value: 0, type: .i32))),
        ("printMulti", .printMulti(arguments: [.intConst(value: 1, type: .i32)])),
        ("stringConcat", .stringConcat(
            lhs: .stringConst(value: "a"),
            rhs: .stringConst(value: "b"))),
        ("stringCase", .stringCase(isUpper: true, receiver: .stringConst(value: "a"))),
        ("interpString", .interpString(parts: [.stringConst(value: "x")])),
        ("readLine", .readLine),
        ("pointerLoad", .pointerLoad(
            pointer: .intConst(value: 0, type: .i32),
            type: .i32)),
        ("closureLiteral", .closureLiteral(
            id: 0, paramNames: [], paramTypes: [], returnType: nil,
            captures: [], body: [], type: .function(params: [], returnType: nil))),
    ]

    private static let statementGaps: [(node: String, stmt: HIRStmt)] = [
        ("forInStmt", .forInStmt(
            pattern: ["v"], elementTypes: [.i32], kind: .array,
            iterable: .intConst(value: 0, type: .i32), body: [], step: nil)),
        ("deferStmt", .deferStmt(body: [])),
        ("tryStmt", .tryStmt(
            operand: .intConst(value: 0, type: .i32), errorVar: "e",
            handler: [], okTarget: nil, type: .i32)),
        ("subscriptStore", .subscriptStore(
            container: .intConst(value: 0, type: .i32),
            index: .intConst(value: 0, type: .i32),
            value: .intConst(value: 1, type: .i32),
            elementType: .i32)),
        ("breakStmt", .breakStmt(depth: 1)),
        ("continueStmt", .continueStmt(depth: 1)),
        ("panicStmt", .panicStmt(message: "boom")),
        ("matchStmt", .matchStmt(
            scrutinee: .intConst(value: 1, type: .i32), cases: [], scrutineeType: .i32)),
        ("fieldStore", .fieldStore(
            base: .intConst(value: 0, type: .i32), field: "f",
            value: .intConst(value: 1, type: .i32), fieldType: .i32)),
    ]

    private func assertGapSpeaks(_ node: String, body: [HIRStmt]) {
        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        let module = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil, body: body)
        ])

        XCTAssertThrowsError(try executor.run(module: module), "node '\(node)' must not run silently") { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("node '\(node)'") && text.contains("not implemented yet"),
                "expected a named gap for '\(node)', got: \(text)"
            )
            XCTAssertTrue(
                text.contains("<hir>"),
                "diagnostics from this engine carry the placeholder position, got: \(text)"
            )
        }
        XCTAssertTrue(lines.isEmpty, "node '\(node)' must produce no output before failing")
    }

    func testUnimplementedExpressionNodesFailLoudAndNameTheNode() {
        for probe in HIRExecutorTests.expressionGaps {
            assertGapSpeaks(probe.node, body: [.exprStmt(probe.expr)])
        }
    }

    func testUnimplementedStatementNodesFailLoudAndNameTheNode() {
        for probe in HIRExecutorTests.statementGaps {
            assertGapSpeaks(probe.node, body: [probe.stmt])
        }
    }

    /// `captureMarker` is the one node outside the executable core that is *not*
    /// a gap: the contract says it lowers to nothing (captures are resolved at
    /// the closure-literal creation point) and the interpreter's
    /// `captureStatement` is a no-op for the same reason. Failing loud on a
    /// defined no-op would misreport it as missing work.
    ///
    /// Asserted by running it, not by reading a list: a list would only restate
    /// the implementation.
    func testCaptureMarkerIsANoOpNotAGap() throws {
        let executor = HIRExecutor()
        let module = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil,
                        body: [.captureMarker(name: "x"), .captureMarker(name: "y")])
        ])
        XCTAssertNoThrow(try executor.run(module: module))
    }

    // MARK: - Debug surface

    /// The engine carries the debug surface (`DebugHookHost`) but has no pause
    /// site, because the HIR carries no source position. A pause wired today
    /// would report `noLocation`, and the debugger matches a breakpoint by line
    /// equality — so no breakpoint could ever fire, while entry-stop and
    /// stepping would stop at a line that does not exist.
    ///
    /// Asserted by running, not by reading the property back: the hook is
    /// installed to fail loudly if consulted, and a real program is then run to
    /// its end. Wiring a pause site before positions land turns this red, and
    /// that is the point — this test is the one place that says "not yet, and
    /// here is why", so the wiring cannot happen by accident.
    func testDebugHookIsDeclaredButDormantUntilPositionsExist() throws {
        let hir = try lowerOnly("""
        main|func() -> ():
            print(1)
            return
        """)

        let executor = HIRExecutor()
        var consulted: [SourceLocation] = []
        executor.debugHook = { ctx in
            consulted.append(ctx.location)
            return .quit
        }

        XCTAssertNoThrow(try executor.run(module: hir))
        XCTAssertTrue(
            consulted.isEmpty,
            "the HIR engine must not consult the debug hook before positions exist; "
                + "it reported \(consulted)"
        )
    }

    // MARK: - Guards

    /// Runaway recursion must end in a diagnosable error rather than a
    /// thread-stack smash with no output — the failure mode G-P9 was.
    func testRunawayRecursionEndsInADiagnosableError() throws {
        let hir = try lowerOnly("""
        rec|func(n: I32,) -> (I32,):
            return rec(n + 1)

        main|func() -> ():
            print(rec(0))
            return
        """)

        XCTAssertThrowsError(try HIRExecutor().run(module: hir)) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("call depth exceeded"),
                "expected the depth guard to fire, got: \(text)"
            )
        }
    }

    /// A call to a name that is not a module-level function must say so by name,
    /// not fall through as something else.
    func testUnknownCalleeIsRejectedByName() throws {
        let module = HIRModule(functions: [
            HIRFunction(name: "lonely", params: [], returnType: .i32,
                        body: [.returnStmt(value: .call(
                            function: "absent", arguments: [], returnType: .i32))]),
            HIRFunction(name: "main", params: [], returnType: nil,
                        body: [.exprStmt(.call(
                            function: "lonely", arguments: [], returnType: .i32))]),
        ])

        XCTAssertThrowsError(try HIRExecutor().run(module: module)) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("no module-level function named 'absent'"),
                "expected the callee name in the message, got: \(text)"
            )
        }
    }

    /// A module without `main` is a diagnosable configuration error, not a
    /// silent no-op run.
    func testMissingMainIsReported() {
        let module = HIRModule(functions: [
            HIRFunction(name: "helper", params: [], returnType: nil,
                        body: [])
        ])
        XCTAssertThrowsError(try HIRExecutor().run(module: module)) { error in
            XCTAssertTrue(
                String(describing: error).contains("main"),
                "expected a mainNotFound diagnostic, got: \(error)"
            )
        }
    }
}

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
/// The list is a representative sample per node family, not every node still
/// missing: the *existence* of an anchor for every contract node is
/// `tools/hir-contract-check.py`'s job (it counts 60/60 from the outside), while
/// this file's job is proving the fail-loud *behaviour* on real examples of it.
/// Each implemented grid deletes entries from here as the engine grows — and the
/// statement side of the list emptied out entirely in grid G5, at which point the
/// table itself went away.
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

        // The interpreter has run; lower the same module the way every shipping
        // path does. `persistAcrossScopesForCodegen` is what the CLI's `run`
        // (HIR engine), `emit`, `compile` and `run-llvm` each set before
        // lowering, and every other lowering harness in the suite sets it too —
        // without it a tuple literal's element types are gone once the checker
        // pops its scope, and lowering rejects a program that runs fine. This
        // harness was the only one that left it off.
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
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

    /// Fixtures that stay inside the implemented node set.
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
        "testDiffArrayRead",
        "testDiffArrayWrite",
        "testDiffCow",
        "testDiffDictSet",
        "testDiffEmptyArray",
        "testDiffTupleConstruct",
        "testDiffTupleConstructClang",
        "testDiffTupleDestructure",
        "testDiffTupleIndexAccess",
        "testDiffTupleLabels",
        "testDiffTupleLen",
        "testDiffTupleReturn",
        // G1: the four fixtures that stay inside the control-flow node set once
        // it lands. `testDiffArrayGetMatch` and `testDiffMultidimArray` also use
        // control flow but stop earlier, at the match/Optional family; that is a
        // later grid's job, not a reason to hold these back.
        "testDiffContinueBreakLabel",
        "testDiffDefer",
        "testDiffForIn",
        "testDiffStep",
        // Grid G6 (enum / Optional / Result / try). Each of these was the grid's
        // own evidence that a node ran: the eleven are exactly the fixtures whose
        // first gap was one of the six G6 nodes, so the probe's verdict on them
        // moved from "engine has not implemented this node yet" to `OK`, and
        // nothing else moved with it.
        // `testDiffSlice` and `testDiffValueFormat` are here because the grid
        // implemented `optionalConstruct` / `optionalGet` rather than deferring
        // them — without that, both fixtures would have stayed in the pending
        // list while silently covering less than they look like they cover
        // (`D-P2-5`).
        "testDiffArrayGetMatch",
        "testDiffEnum",
        "testDiffEnumNamed",
        "testDiffMultidimArray",
        "testDiffOptionalDirect",
        "testDiffSlice",
        "testDiffTryElse",
        "testDiffTryElseOk",
        "testDiffTryElseSugar",
        "testDiffValidatedMatch",
        "testDiffValueFormat",
        // Grid G5 (nominal types and fields). These eight are exactly the
        // fixtures whose first gap was `construct`, so the probe's verdict on
        // each moved from "engine has not implemented this node yet" to `OK` and
        // nothing else moved with it.
        //
        // The ninth of that group, `testDiffStructValue`, is **held back**: its
        // method body ends in `sqrt`, and a builtin callee is not resolved on
        // this channel — the grid chose not to delegate builtins to the
        // interpreter (the note on `call` says why), so the fixture now stops at
        // the call node instead of the field node it used to stop at. It stays
        // out until the builtin callee rule has an owner; naming it here as
        // "in range" would be the declaration this list exists to prevent.
        //
        // They carry the whole nominal family between them:
        // the struct shapes (`testDiffStruct*`, `testDiffI8StructField`), the
        // reference-type object (`testDiffObjectReference`), the generic struct
        // whose type argument the lowerer specialises rather than splitting the
        // node (`testDiffGenericStruct`), the embedded-parent shape whose methods
        // dispatch by receiver type (`testDiffStructComposition`), and the two
        // trait shapes whose method bodies are ordinary calls with the receiver
        // as the first argument (`testDiffTrait*`).
        "testDiffEnumTypedField",
        "testDiffGenericStruct",
        "testDiffI8StructField",
        "testDiffObjectReference",
        "testDiffStructComposition",
        "testDiffStructI8Fields",
        "testDiffTrait",
        "testDiffTraitDefaultMethod",
        // Grid G3 (closures and function values). Two of the grid's three nodes
        // appear here as the fixtures' own first gap: the probe's verdict on
        // `testDiffClosures` / `testDiffLambda` / `testDiffLambdaTyped` moved
        // from its engine-gap verdict naming `closureLiteral` to `OK`, and on
        // `testDiffHigherOrder` from `functionValue` to `OK`. Nothing else moved
        // with them.
        //
        // The third node, `indirectCall`, is covered by the same four fixtures —
        // each calls a function-valued variable or parameter — but it is not
        // what the probe's *baseline* run named, and the difference is worth
        // stating precisely because the first draft of this note got it wrong.
        //
        // Before this grid, a fixture that builds a closure and calls it was
        // reported as `closureLiteral`: the callee's node spoke first and the
        // call node behind it was never reached. Reading that as structural —
        // "an indirect call cannot be a first gap, because its callee must be
        // built first" — was a mistake, and the mutation round disproved it:
        // disabling `indirectCall` alone reddens all eight fixtures, each now
        // reporting `indirectCall` as its first gap. Nothing changed about the
        // programs; only the implementation progress did.
        //
        // So the masking is **relative to the implemented node set**, not a
        // property of programs: a node is invisible to the probe exactly as long
        // as every fixture that reaches it reaches an unimplemented node first.
        // That is a fact about the work queue (and about how many gaps a fixture
        // crosses), not a reason to distrust the probe.
        "testDiffClosures",
        "testDiffHigherOrder",
        "testDiffLambda",
        "testDiffLambdaTyped",
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
    /// Written while `testDiffStep` was out of range (it also uses `break`, which
    /// the skeleton did not implement). G1 brought that fixture in, so this case
    /// now overlaps it — deliberately kept, because it isolates one thing: the
    /// step runs on normal completion of the body, with no `break`, no `for-in`
    /// and no pattern variable in the picture. The interpreter-side rule being
    /// mirrored is `Interpreter.executeWhile`.
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

    /// Every `for-in` iterable family and pattern shape in one source.
    ///
    /// `testDiffForIn` covers array, dictionary, `_` and labeled break, but not
    /// sets and not a nested row read — and its dictionary arm is the one place
    /// where a row is built **positionally** instead of through
    /// `decomposePatternRow`, so the two paths deserve to be compared apart.
    /// Termination is structural here (the loops run over literals), which is why
    /// this case can carry a mutation that breaks an operator without hanging.
    func testForInIterableFamiliesAgreeWithTheInterpreter() throws {
        try assertParity("""
        main|func() -> ():
            for (v,) in [1, 2, 3]:
                print(v)
            for (_ ,) in [7, 8, 9]:
                print("slot")
            for (k, v,) in ["a"= 1, "b"= 2]:
                print(k)
                print(v)
            for (n,) in {5, 5, 6}:
                print(n)
            for (row,) in [[1, 2], [3, 4], [5, 6]]:
                print(row[0] + row[1])
            return
        """, label: "for-in families")
    }

    /// The `for-in` step block runs in the **loop** environment, and `break`
    /// skips it — the ADR-014 contract, stated for `for` rather than `while`.
    ///
    /// `testDiffStep` pins the environment half for a normal iteration; what is
    /// added here is the pair of exits that decide *whether* the step runs at
    /// all: a `break` aimed at this loop must skip it, and a `break` aimed at an
    /// outer loop must skip it too. Both are rethrown-or-consumed paths, so a
    /// wrong depth rule changes the output rather than merely the timing.
    func testForInStepFollowsTheBreakContract() throws {
        try assertParity("""
        main|func() -> ():
            for (v,) in [1, 2, 3, 4]:
                print(v)
                if v == 2:
                    break
            step:
                print("inner-step")
            print("after-break")
            return
        """, label: "for-in step and break")
    }

    /// `defer` runs when the block is left **by `break` or `return`**, not only
    /// by falling off its end.
    ///
    /// This is the line the contract used to carry as an ungated surface
    /// (`deferStmt` × break/return interplay: "not in the corpus"). It is gated
    /// now because both channels close a block's scope on *every* exit; the two
    /// exits that a normal-completion test cannot reach are exercised here, one
    /// through a loop and one through a function return.
    func testDeferRunsWhenBreakOrReturnLeavesTheBlock() throws {
        try assertParity("""
        main|func() -> ():
            print(helper(1))
            for (v,) in [1, 2]:
                defer print("loop-defer")
                if v == 1:
                    break
            print("after")
            return

        helper|func(n: I32,) -> (I32,):
            defer print("before-return")
            if n > 0:
                return n + 10
            return 0
        """, label: "defer on break/return")
    }

    /// Depth is what the HIR carries, so depth is what has to be right: an
    /// unwind aimed at an outer loop must cross the inner one **without running
    /// its step**, and must run the outer one's step for `continue`.
    ///
    /// Both loops are single-level in the corpus (`testDiffContinueBreakLabel`
    /// breaks two levels of `while`); what is only visible here is the *step*
    /// asymmetry the interpreter's label-mismatch rethrow produces, and the same
    /// rule holding when the two levels are different loop kinds.
    func testUnwindDepthCrossesMixedLoopKinds() throws {
        try assertParity("""
        main|func() -> ():
            row|for (a,) in [1, 2]:
                for (b,) in [1, 2]:
                    if b == 1:
                        continue row
                    print(a * 10 + b)
                step:
                    print("inner-step")
            step:
                print("outer-step")
            print("done")

            var keep = true
            tag|while keep:
                for (c,) in [1, 2]:
                    if c == 2:
                        break tag
                    print(c)
                keep = false
            print("end")
            return
        """, label: "unwind depth")
    }

    // MARK: - Control flow that cannot be compared

    /// `panicStmt` is compiler-generated and has no byte-comparable counterpart:
    /// on the AST channel the same program ends in an escaped `ControlSignal`,
    /// whose top-level text is Foundation's, not the language's. So the claim
    /// stops where it honestly can — it fails loud, carrying the lowerer's
    /// message and this engine's placeholder position.
    func testPanicStmtFailsLoudWithTheLowerersMessage() {
        let executor = HIRExecutor()
        let module = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil,
                        body: [.panicStmt(message: "Pini runtime error: break outside loop")])
        ])
        XCTAssertThrowsError(try executor.run(module: module)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("break outside loop"), "got: \(text)")
            XCTAssertTrue(text.contains("<hir>"), "got: \(text)")
        }
    }

    /// A `break` with no enclosing loop must not run on as if it had worked.
    ///
    /// The lowerer normally turns this into a `panicStmt`; the guarantee asserted
    /// here is the one that does not depend on the lowerer — a raw `breakStmt`
    /// reaching the executor leaves it by unwinding. On the AST channel the same
    /// program never gets this far, so this is asserted on one channel only, and
    /// says so.
    ///
    /// WHY THE ERROR TEXT IS PART OF THE CLAIM
    ///
    /// G1's mutation round ran this case against a disabled engine and it **passed**:
    /// a skeleton `breakStmt` throws too, and it stops the output too, so "it threw"
    /// and "nothing was printed after" are both satisfied by a node that was never
    /// implemented. Two assertions that a broken engine also satisfies are not a
    /// guard. The failure mode therefore has to be named — the call must leave on the
    /// unwind path, not on the "dispatched but not implemented" path.
    func testBreakWithoutAnEnclosingLoopDoesNotRunOnSilently() {
        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        let module = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil,
                        body: [.exprStmt(.printCall(argument: .stringConst(value: "before"))),
                               .breakStmt(depth: 1),
                               .exprStmt(.printCall(argument: .stringConst(value: "after")))])
        ])
        XCTAssertThrowsError(try executor.run(module: module)) { error in
            let text = String(describing: error)
            XCTAssertFalse(
                text.contains("not implemented"),
                "the break must be handled, not reported as an unimplemented node: \(text)")
        }
        XCTAssertEqual(lines, ["before"], "execution must stop at the break")
    }

    /// The slice sugar, both bounds spelled as integers.
    ///
    /// `testDiffSlice` is the only corpus fixture that reaches the slice node,
    /// and it also uses open bounds — `a[:2]`, `a[3:]`, `a[:]` — which the
    /// lowerer builds as optional constructors. That fixture therefore stops at
    /// the enum family before any bound is consumed, and the integer-bound path
    /// would ship **executed but never compared**: the run fails, so no output is
    /// checked. The parser desugars the subscript form into a `slice` member
    /// call, so this source reaches the same node the fixture does.
    ///
    /// Clamping (`1:100`), the fully out-of-range pair (`100:200`) and the
    /// negative tail count (`-2:-1`) are all covered here, on both `Array` and
    /// `String`.
    func testSliceSugarWithIntegerBoundsAgreesWithTheInterpreter() throws {
        try assertParity("""
        main|func() -> ():
            var a = [10, 20, 30, 40, 50]
            print(a[1:3])
            print(a[1:100])
            print(a[100:200])
            print(a[-2:-1])
            var s = "hello"
            print(s[1:4])
            print(s[-3:-1])
            return
        """, label: "slice-sugar")
    }

    /// Tuple labels are part of the value, not decoration: `print` renders
    /// `[商: 3, 余: 2]` for a labelled literal and `[3, 2]` for a positional one.
    ///
    /// No corpus fixture reaches this. Every one of the six tuple fixtures builds
    /// a positional tuple, so two things would ship uncompared: the labels
    /// `tupleConstruct` carries through to the value, and the labelled member
    /// read `t.商`, which is a *different* lowering path from the positional
    /// `t.0` (the lowerer resolves a label to an index at lowering time, so both
    /// arrive at the same node with a different provenance). The positional form
    /// is asserted here too, as the negative half of the pair — a case that only
    /// proved labels are present would pass just as well if labels were always
    /// fabricated.
    func testTupleLabelsAreCarriedIntoTheValue() throws {
        try assertParity("""
        main|func() -> ():
            let t = (商 = 3, 余 = 2,)
            print(t)
            print(t.商)
            print(t.0)
            var u = (1, 2.5)
            print(u)
            return
        """, label: "tuple-labels")
    }

    /// The named-return label model, arm against arm (P2a grid 2, F1+F2).
    ///
    /// The interpreter attaches the component names a signature declares at
    /// exactly two points, and the engine has to mirror both:
    ///
    /// 1. an explicit `return` (the value leaving the body adopts the declared
    ///    names — this is the half that was missing);
    /// 2. a binding whose slot type names components the initializer's own type
    ///    does not (`let t: (商: I32, 余: I32,) = ...`).
    ///
    /// The cases are chosen to be mutually discriminating rather than merely
    /// positive: `其余`'s implicit trailing expression is returned untouched by
    /// the interpreter, so an engine that relabels on *every* way out of a
    /// function, or on every tuple-typed binding, prints names here that the
    /// reference does not — the assertion is what holds that line.
    ///
    /// WHAT THE SECOND MUTATION RUN TAUGHT THIS CASE (2026-09-13)
    ///
    /// The rule now has one implementation shared by both engines
    /// (`Interpreter.relabelled`), so byte equality between the arms cannot see
    /// that implementation being removed — and a literal pin on the expected
    /// bytes was written here to cover it. The mutation run then showed the pin
    /// was **redundant**, and it was removed rather than kept as unexercised
    /// code: neutering the shared helper does not make the arms agree silently,
    /// it makes both of them *throw* (`未定义变量: 商` — a name read needs the
    /// label to resolve), which this harness already fails on; and a mutation
    /// that changes only the rendering hits the interpreter arm alone, which the
    /// differential judge against the LLVM arm already catches.
    func testNamedReturnLabelsFollowTheInterpretersTwoRules() throws {
        try assertParity("""
        除余|func(a: I32, b: I32,) -> (商: I32, 余: I32,):
            return (a / b, a % b)

        其余|func(a: I32, b: I32,) -> (商: I32, 余: I32,):
            (a / b, a % b)

        位置|func(a: I32, b: I32,) -> ((I32, I32,),):
            return (a / b, a % b)

        main|func() -> ():
            let r = 除余(17, 5)
            print(r)
            print(r.商)
            print(除余(17, 5))
            let s = 其余(17, 5)
            print(s)
            let t: (商: I32, 余: I32,) = (3, 2)
            print(t)
            print(t.商)
            let u: (商: I32, 余: I32,) = 位置(17, 5)
            print(u)
            return
        """, label: "named-return labels")
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

    /// A `match` over a **bare** scrutinee dispatches on literal arms, and
    /// `case _:` is the wildcard that makes the fall-through explicit.
    ///
    /// Why this needs a case of its own: every corpus fixture that reaches
    /// `matchStmt` is either Optional-typed or enum-typed, so the bare-value
    /// family — the one the lowerer routes through `HIRMatchLiteral` — would ship
    /// unasserted. Two facts are pinned at once: a literal arm fires on value
    /// equality, and the wildcard fires for everything else. The rule being
    /// mirrored is `Interpreter.matchArmMatches`, the shared value-level core.
    func testBareScrutineeMatchDispatchesOnLiteralsAndWildcard() throws {
        try assertParity("""
        main|func() -> ():
            var x = 2
            match x:
                case 1:
                    print("one")
                case 2:
                    print("two")
                case _:
                    print("other")
            var y = 9
            match y:
                case 1:
                    print("one")
                case _:
                    print("yes")
            return
        """, label: "bare-scrutinee literal match and wildcard")
    }

    /// A `defer` written inside a `match` arm runs when that arm's block ends,
    /// before anything after the `match`.
    ///
    /// No fixture covers it: `testDiffDefer` exercises `while` and `for-in` bodies
    /// only. The arm body is a block scope of its own (`Interpreter.executeMatch`
    /// calls `executeBlock` per arm), so its defers fire at arm exit, LIFO, while
    /// the arm's own bindings and the scrutinee binding are still in scope. The
    /// ordering of the two defers is the point — a flattened reversal would print
    /// `100` before `200`.
    func testDeferInsideAMatchArmRunsAtArmExit() throws {
        try assertParity("""
        main|func() -> ():
            var x = 5
            match x:
                case 5:
                    defer print(200)
                    defer print(100)
                    print(x)
                case _:
                    print("other")
            print("after")
            return
        """, label: "defer inside a match arm")
    }

    /// A `try` handler may end in `pass` at **statement** position.
    ///
    /// The lowerer rejects a `pass`-terminated handler in expression position (it
    /// can yield no value) but allows it in statement position, where the handler
    /// simply falls out and control continues after the `try`. Every `try`
    /// fixture terminates its handler with `return`, so that second half of the
    /// rule would otherwise be unexercised — and the two halves are easy to
    /// conflate into "handlers always jump".
    func testTryHandlerMayEndInPassAtStatementPosition() throws {
        try assertParity("""
        失败|func(flag: Bool,) -> (^String,):
            if flag:
                return err("boom")
            return ok("fine")

        main|func() -> ():
            try 失败(true) else 错误:
                print("caught")
                pass
            print("after")
            return
        """, label: "try handler terminating with pass")
    }

    /// `resultConstruct` at node level, through the one consumer a fixture cannot
    /// give it.
    ///
    /// No corpus fixture fails at `resultConstruct` first — a `try` operand
    /// evaluates it one node earlier — so the node that *builds* a Result value
    /// has no gap probe of its own. It is built here instead, together with the
    /// only cover for a **`Result` scrutinee**: the lowerer routes that through
    /// the bare-value family (a `Result` is neither an Optional nor a declared
    /// enum at that point), and no fixture matches on one. So this pins three
    /// things at once: `ok` produces the interpreter's `Result` value, a `match`
    /// dispatches over it by case name, and the arm binds the payload it carries.
    func testResultConstructorValueDispatchesThroughMatch() throws {
        let result: HIRType = .result(ok: .i32)
        let module = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil, body: [
                .allocVar(
                    name: "r", type: result, mutable: false,
                    initializer: .resultConstruct(
                        isOk: true, payload: .intConst(value: 7, type: .i32), type: result
                    )
                ),
                .matchStmt(
                    scrutinee: .load(name: "r", type: result),
                    cases: [
                        HIRMatchCase(
                            caseName: "ok", bindings: ["v"],
                            body: [.exprStmt(.printCall(argument: .load(name: "v", type: .i32)))]
                        ),
                        HIRMatchCase(
                            caseName: "err", bindings: ["e"],
                            body: [.exprStmt(.printCall(argument: .stringConst(value: "err")))]
                        ),
                    ],
                    scrutineeType: result
                ),
                .returnStmt(value: nil),
            ])
        ])

        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        XCTAssertNoThrow(try executor.run(module: module))
        XCTAssertEqual(lines, ["7"], "the ok arm must bind the payload the value carries")
    }

    /// The two ways a `match` falls off its end, both mirrored from the
    /// interpreter and both unreachable from source:
    ///
    /// - an **enum value** no arm names → `matchNotExhaustive`. Source cannot
    ///   reach it (the checker rejects a non-exhaustive enum match statically,
    ///   `E3-007`), which is exactly why the node is built here;
    /// - a **bare value** no literal arm matches → silent, no output. A literal's
    ///   value space is infinite, so falling through is the interpreter's rule
    ///   (R3) and not an oversight; a later "tidy-up" that turned it into a panic
    ///   would diverge from the AST channel, so it is asserted rather than left to
    ///   the reading of the code.
    func testMatchFallThroughIsLoudForEnumsAndSilentForBareValues() {
        let uncovered = HIRModule(
            functions: [HIRFunction(name: "main", params: [], returnType: nil, body: [
                .matchStmt(
                    scrutinee: .enumConstruct(
                        enumName: "E", caseName: "a", tag: 0, payloads: [], payloadTypes: [],
                        type: .enumeration(name: "E")
                    ),
                    cases: [HIRMatchCase(caseName: "b", bindings: [], body: [])],
                    scrutineeType: .enumeration(name: "E")
                ),
            ])],
            enums: [HIREnumDecl(name: "E", cases: [
                HIREnumCase(name: "a", tag: 0, paramNames: [], payloadTypes: []),
                HIREnumCase(name: "b", tag: 1, paramNames: [], payloadTypes: []),
            ])]
        )
        XCTAssertThrowsError(try HIRExecutor().run(module: uncovered)) { error in
            XCTAssertTrue(
                String(describing: error).contains("match 未穷尽"),
                "an unmatched enum value must report the match as non-exhaustive, got: \(error)"
            )
        }

        let bareMiss = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil, body: [
                .matchStmt(
                    scrutinee: .intConst(value: 4, type: .i32),
                    cases: [HIRMatchCase(caseName: "1", literal: .int(1), bindings: [], body: [
                        .exprStmt(.printCall(argument: .stringConst(value: "one")))
                    ])],
                    scrutineeType: .i32
                ),
            ])
        ])
        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        XCTAssertNoThrow(try executor.run(module: bareMiss))
        XCTAssertTrue(
            lines.isEmpty, "a bare value with no matching literal arm falls through silently"
        )
    }

    /// A reference-type object, aliased through a second binding, then written and
    /// read through a **plain variable base** rather than through `self`.
    ///
    /// The corpus reaches objects only through their methods, whose bodies write
    /// `self.字段` — so the two arms where the receiver is an ordinary variable,
    /// the read and the write of `fieldGet` / `fieldStore`, have no fixture. The
    /// shape matters because it is where the value/reference split becomes
    /// observable: `var b = a` **aliases** an object and must keep aliasing, so
    /// the write through `a` is read back through `b`.
    ///
    /// The output is asserted absolutely as well as by parity. Two channels that
    /// both failed to alias would agree with each other while being wrong, and
    /// this is exactly the rule whose absence shows up as a wrong number rather
    /// than as a divergence — so parity alone would be a hollow judge here.
    ///
    /// This test uses an object on purpose. The struct analogue of the same shape
    /// (`var b = a` where `a` is a struct) is the engine's one known semantic
    /// hole — `Interpreter.copyIfStruct` is not applied at this engine's binding
    /// sites — and the two channels would **diverge** on it today. It is filed as
    /// a defect with its own ticket rather than asserted here, because a test that
    /// pins a known-wrong answer is worse than no test.
    func testObjectAliasingThroughASecondBindingAndAPlainVariableBase() throws {
        let (ast, hir) = try runBothChannels("""
        {计数对象}
        数值: I32 = 0

        {{计数对象}}
        增加|self() -> ():
            self.数值 = self.数值 + 1
            return

        main|func() -> ():
            var a = 计数对象()
            var b = a
            b.增加()
            b.增加()
            a.数值 = 10
            print(a.数值)
            print(b.数值)
            return
        """)

        XCTAssertEqual(ast, ["10", "10"], "an object binding aliases, it does not copy")
        XCTAssertEqual(hir, ast, "channel output diverged for object aliasing")
    }

    /// The two nominal paths a *typechecking* program cannot reach, kept loud.
    ///
    /// Both are closed off before this engine runs rather than merely absent from
    /// the corpus: a read of a field the receiver's type does not declare is
    /// refused by the lowerer's static field resolution (`no field …`), and a field
    /// write whose receiver is not nominal is refused by the same `guard case
    /// .nominal`. So these nodes only ever arrive from a module and an engine that
    /// disagree, and the only acceptable answer to that is an error that says so.
    ///
    /// Each guards against a silent alternative — `.null` for the missing field, a
    /// no-op for the write that went nowhere — and both of those would look like a
    /// working program. That is why they are built as nodes and *run* instead of
    /// being left to a reading of the code.
    func testUnreachableNominalPathsFailLoudInsteadOfGoingSilent() {
        let missingField = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil, body: [
                .exprStmt(.fieldGet(
                    base: .construct(type: .nominal(name: "点", isObject: false)),
                    field: "nope",
                    type: .i32)),
            ])
        ])
        XCTAssertThrowsError(try HIRExecutor().run(module: missingField)) { error in
            XCTAssertTrue(
                String(describing: error).contains("no field 'nope'"),
                "a field the type does not carry must be reported, not read as null, got: \(error)"
            )
        }

        let nonNominalReceiver = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil, body: [
                .fieldStore(
                    base: .intConst(value: 0, type: .i32), field: "f",
                    value: .intConst(value: 1, type: .i32), fieldType: .i32),
            ])
        ])
        XCTAssertThrowsError(try HIRExecutor().run(module: nonNominalReceiver)) { error in
            XCTAssertTrue(
                String(describing: error).contains("无法赋值的对象类型"),
                "a write through a non-nominal receiver must be reported, got: \(error)"
            )
        }
    }

    // MARK: - Closures and function values (grid G3)

    /// A closure sees the environment it was **created** in, not the one it is
    /// called from.
    ///
    /// This is the grid's sharpest single assertion, and it is aimed at the one
    /// implementation gap the grid had to close: the engine built every callee's
    /// environment off the global one, which is right for a module-level
    /// function and wrong for a closure. The source is written so that both
    /// wrong answers are observably wrong rather than merely absent — `base` is
    /// not reachable from the global environment at all (a global parent fails
    /// loudly), and `main` binds its own `base = 1000` (a call-site parent
    /// yields 1005). Only the creating environment yields 15.
    func testAClosureSeesItsCreatingEnvironmentNotItsCallSite() throws {
        let hir = try lowerOnly("""
        造加法器|func(base: I32,) -> ((I32,) -> (I32,),):
            return func (n,) -> (I32,):
                capture base
                return n + base

        main|func() -> ():
            var base = 1000
            var add = 造加法器(10)
            print(add(5))
            return
        """)

        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        try executor.run(module: hir)

        XCTAssertEqual(lines, ["15"], "the closure must read the environment it was created in")
    }

    /// A capture is a **reference**, so a write to the captured variable after
    /// the closure was built stays visible through it.
    ///
    /// Asserted against literal output rather than through the two-channel
    /// comparison, because both channels share the value layer and the
    /// environment model: a mutation that turned captures into snapshots would
    /// have to move the interpreter's model with it, and a comparison is blind
    /// to a rule the two of them hold jointly. The second number is the whole
    /// test — a snapshot yields 15 twice.
    func testACaptureIsAReferenceNotASnapshot() throws {
        let hir = try lowerOnly("""
        main|func() -> ():
            var base = 10
            var addBase = func (n,) -> (I32,):
                capture base
                return n + base
            print(addBase(5))
            base = 100
            print(addBase(5))
            return
        """)

        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        try executor.run(module: hir)

        XCTAssertEqual(
            lines, ["15", "105"],
            "the capture must follow the variable, not its value at creation time"
        )
    }

    /// Two closures in one program keep two bodies.
    ///
    /// The engine's body table is keyed by value identity, and this is the test
    /// that says why it has to be: the parser gives every anonymous `func` the
    /// same name (`<anon>`), so a table keyed by name would hold one entry where
    /// the program has two, and the second closure would quietly run the first's
    /// body. The output makes that failure visible rather than subtle — the two
    /// closures compute different things from the same argument.
    ///
    /// The same rule holds for the corpus fixtures, which each build several
    /// closures; this case exists because a *pair* differing only in their bodies
    /// is the smallest program that isolates the key.
    func testTwoClosuresDoNotShareOneBody() throws {
        let hir = try lowerOnly("""
        main|func() -> ():
            var 加一 = func (x,) -> (I32,):
                return x + 1
            var 乘百 = func (x,) -> (I32,):
                return x * 100
            print(加一(1))
            print(乘百(1))
            return
        """)

        let executor = HIRExecutor()
        var lines: [String] = []
        executor.outputSink = { lines.append($0) }
        try executor.run(module: hir)

        XCTAssertEqual(lines, ["2", "100"], "each closure must keep its own body")
    }

    /// An indirect call whose callee is not a function value is a diagnosable
    /// error, not a `.null`.
    ///
    /// Hand-built, and unreachable from checked source — the checker rejects a
    /// call on a non-function before lowering ever sees it. It is here because
    /// the indirect-call arm is the one place this engine resolves a callee out
    /// of a *value* rather than out of a name, and a value-shaped lookup is
    /// exactly where "not found" can quietly become "nothing to do".
    ///
    /// Asserted on the error **case**, not on its rendering: the text a
    /// `RuntimeError` prints as is `ErrorFormatter`'s business and has changed
    /// before, while the case is the contract this arm owes. Matching the case
    /// also makes the test say which failure it is — a neighbouring arm's error
    /// would satisfy a substring check but not this one.
    func testIndirectCallThroughANonFunctionFailsLoud() throws {
        let module = HIRModule(functions: [
            HIRFunction(name: "main", params: [], returnType: nil, body: [
                .exprStmt(.indirectCall(
                    callee: .intConst(value: 1, type: .i32),
                    arguments: [],
                    returnType: nil)),
            ])
        ])

        XCTAssertThrowsError(try HIRExecutor().run(module: module)) { error in
            guard let runtime = error as? RuntimeError, case .notCallable = runtime else {
                return XCTFail(
                    "an indirect call on a non-function must be notCallable, got: \(error)"
                )
            }
        }
    }

    // MARK: - Fail-loud gaps

    /// One probe per gap. Each probe is a *single* node, so "the error names this
    /// node" cannot be satisfied by a neighbouring gap speaking up instead.
    ///
    /// `closureLiteral` left this table with grid G3, which implemented it: a
    /// probe for a node that runs asserts the opposite of the truth. What holds
    /// the three G3 nodes up instead is the corpus — the grid's four fixtures
    /// reach all three — plus the hand-written cases further down, which pin the
    /// one rule a fixture cannot settle on its own: that a capture is a
    /// *reference* to the creating environment rather than a copy taken at
    /// creation time. Their absence from this table is safe to read as coverage,
    /// not as a silence, and the rule that keeps it that way is the usual one —
    /// the list shrinks only when the node runs and something else fails loud
    /// about it being wrong.
    private static let expressionGaps: [(node: String, expr: HIRExpr)] = [
        ("printMulti", .printMulti(arguments: [.intConst(value: 1, type: .i32)])),
        ("stringCase", .stringCase(isUpper: true, receiver: .stringConst(value: "a"))),
        ("interpString", .interpString(parts: [.stringConst(value: "x")])),
        ("readLine", .readLine),
        ("pointerLoad", .pointerLoad(
            pointer: .intConst(value: 0, type: .i32),
            type: .i32)),
    ]

    /// The statement side of the contract is **complete** as of grid G5, and the
    /// table that used to live here (`statementGaps`) is gone rather than empty.
    ///
    /// It had one entry left, `fieldStore`, which G5 implemented — and a loop
    /// over an empty table passes while asserting nothing, which is the failure
    /// mode this whole file is built to avoid (`assertGapSpeaks` below is still
    /// used, by the expression side, where gaps remain). `tryStmt` / `matchStmt`
    /// (G6) and the control-flow family (G1) had already left for the same
    /// reason: a probe for a node that runs asserts the opposite of the truth.
    ///
    /// What holds the statement side up instead: the dispatch switch has no
    /// `default:` arm, so a missing case is a compile error rather than a silent
    /// hole; `tools/hir-contract-check.py` counts the anchors from outside
    /// (60/60, and it judges existence, not behaviour); the corpus parity run
    /// exercises every statement shape the language has; and the two control
    /// statements that could not be covered by a gap probe got their own tests
    /// instead — with the stronger form the G1 grid's mutation round forced
    /// (asserting the failure mode by name, because "it threw" and "nothing ran
    /// after" are both satisfied by a node that was never implemented).
    ///
    /// A combined `testEscapingControlFlowAndPanicTrapStayLoud` arrived with the
    /// G5 draft and covered these same two nodes. It was dropped in the merge
    /// rather than kept next to them: the break half rebuilt exactly the weak
    /// shape above (throw + no output, both of which a skeleton node satisfies),
    /// and the panic half's "must not continue" claim is already structural — a
    /// throw out of `run` cannot leave a later statement executing.
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

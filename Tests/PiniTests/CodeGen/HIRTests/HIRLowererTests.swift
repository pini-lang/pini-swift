import XCTest
@testable import PiniCore

/// M4 vertical-slice smoke tests for the HIR lowering stage: shape checks on
/// the typed tree and the single capability gate. Differential tests against
/// the interpreter land with the emitter (batch 2).
final class HIRLowererTests: XCTestCase {

    private func lower(_ source: String) throws -> HIRModule {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        XCTAssertEqual(errors.isEmpty, true, "slice sources must typecheck: \(errors)")
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    func testLowerArithmeticVarAndPrint() throws {
        let hir = try lower("""
        main|func() -> ():
            let a: I32 = 1 + 2 * 3
            print(a)
        """)
        let main = hir.mainFunction
        XCTAssertNotNil(main)
        XCTAssertEqual(main?.returnType, nil)
        XCTAssertEqual(main?.body.count, 2)
        // Statement 1: allocVar(a, I32, init binary)
        guard case .allocVar(let name, let type, _, let initializer)? = main?.body.first else {
            return XCTFail("expected allocVar first")
        }
        XCTAssertEqual(name, "a")
        XCTAssertEqual(type, .i32)
        guard case .binary(_, _, _, .i32) = initializer! else {
            return XCTFail("expected i32 binary initializer")
        }
        // Statement 2: expression statement wrapping printCall(load a)
        guard let lastStmt = main?.body.last else {
            return XCTFail("expected a final statement")
        }
        guard case .exprStmt(let inner) = lastStmt else {
            return XCTFail("expected expression statement last")
        }
        guard case .printCall(let argument) = inner else {
            return XCTFail("expected printCall")
        }
        guard case .load(let printed, .i32) = argument else {
            return XCTFail("expected print of an i32 load")
        }
        XCTAssertEqual(printed, "a")
    }

    func testWhileAndIfLowerToTreeStatements() throws {
        let hir = try lower("""
        main|func() -> ():
            var i: I32 = 0
            while i < 3:
                if i == 1:
                    print(1)
                else:
                    print(0)
                i = i + 1
        """)
        let body = hir.mainFunction?.body ?? []
        XCTAssertEqual(body.count, 2)
        guard case .whileStmt(let cond, let loopBody, _)? = body.last else {
            return XCTFail("expected while statement")
        }
        guard case .binary(let op, _, _, .boolean) = cond else {
            return XCTFail("expected boolean comparison condition")
        }
        XCTAssertEqual(op, .lessThan)
        // while body: if (1 stmt) + store
        XCTAssertEqual(loopBody.count, 2)
        guard case .ifStmt(_, let thenBody, let elseBody)? = loopBody.first else {
            return XCTFail("expected if inside loop")
        }
        XCTAssertEqual(thenBody.count, 1)
        XCTAssertEqual(elseBody?.count, 1)
    }

    func testUserFunctionCallAndSingleValueReturn() throws {
        let hir = try lower("""
        add|func(a: I32, b: I32) -> (I32,):
            return a + b

        main|func() -> ():
            print(add(1, 2))
        """)
        XCTAssertEqual(hir.functions.count, 2)
        let add = hir.function(named: "add")
        XCTAssertEqual(add?.returnType, .i32)
        // Pre-pass must capture add's signature even though main is declared
        // after add in source order.
        guard let firstStmt = hir.mainFunction?.body.first else {
            return XCTFail("expected a leading statement")
        }
        guard case .exprStmt(let inner) = firstStmt else {
            return XCTFail("expected expression statement")
        }
        guard case .printCall(let argument) = inner else {
            return XCTFail("expected printCall wrapping a call")
        }
        guard case .call(let callee, let args, .i32) = argument else {
            return XCTFail("expected call with i32 return")
        }
        XCTAssertEqual(callee, "add")
        XCTAssertEqual(args.count, 2)
    }

    func testLambdaLowersToClosureLiteral() throws {
        // G6 moved lambdas inside the slice (closure family): a bound lambda
        // lowers to a closure literal and its call site to an indirect call.
        // The boundary gate tracks the current grid, not the M4 snapshot.
        let hir = try lower("""
        main|func() -> ():
            var f = func (x,) -> (I32,):
                return x + 1
            print(f(41))
        """)
        guard let alloc = hir.mainFunction?.body.first,
              case .allocVar(_, let varType, _, .closureLiteral(_, let paramNames, let paramTypes, _, let captures, _, _)) = alloc else {
            return XCTFail("expected a closure-literal variable allocation")
        }
        guard case .function = varType else {
            return XCTFail("expected function-typed variable, got \(varType)")
        }
        XCTAssertEqual(paramNames, ["x"])
        XCTAssertEqual(paramTypes, [.i32])
        XCTAssertTrue(captures.isEmpty, "no captures in this corpus")
    }

    func testGateRejectsUnknownFunctionCall() {
        XCTAssertThrowsError(try lower("""
        main|func() -> ():
            print(foo(1))
        """)) { error in
            XCTAssertTrue(
                String(describing: error).contains("unknown function 'foo'"),
                "expected unknown-function gate error, got: \(error)"
            )
        }
    }

    func testPrinterDumpShowsTypedSignature() throws {
        let hir = try lower("""
        main|func() -> ():
            let a: I32 = 1
            print(a)
        """)
        let text = HIRPrinter.dump(module: hir)
        XCTAssertTrue(text.contains("func main():"))
        XCTAssertTrue(text.contains("let a: i32 = 1"))
    }

    /// G2 label model: the component names a signature declares for a
    /// multi-value return have to survive lowering.
    ///
    /// Both HIR arms need them off this type — the executor relabels the
    /// returned value with them (the interpreter's own return-site rule) and
    /// the emitter prints a tuple's labels straight from the type it is
    /// handed — so a label-less `returnType` silently un-names the value while
    /// the AST engine keeps the names.
    func testNamedReturnTypeCarriesItsComponentLabels() throws {
        let hir = try lower("""
        除余|func(a: I32, b: I32,) -> (商: I32, 余: I32,):
            return (a / b, a % b)

        main|func() -> ():
            return
        """)
        let dump = HIRPrinter.dump(module: hir)
        XCTAssertEqual(
            hir.function(named: "除余")?.returnType,
            .tuple(labels: ["商", "余"], fieldTypes: [.i32, .i32]),
            "declared return labels lost in lowering\n\(dump)"
        )
    }
}

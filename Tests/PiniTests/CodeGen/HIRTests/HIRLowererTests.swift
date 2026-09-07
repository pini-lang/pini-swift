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
        guard case .whileStmt(let cond, let loopBody)? = body.last else {
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

    func testGateRejectsDictionaryLiteral() {
        // G2 moved array literals inside the slice (read path batch 1);
        // dictionary / set literals remain outside it. The boundary gate
        // tracks the current grid, not the M4 snapshot.
        XCTAssertThrowsError(try lower("""
        main|func() -> ():
            let d = ["k" = 1]
        """)) { error in
            XCTAssertTrue(
                String(describing: error).contains("HIR lowering error"),
                "expected capability gate error, got: \(error)"
            )
        }
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
}

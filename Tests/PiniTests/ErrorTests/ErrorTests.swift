import XCTest
import PiniCore
import Foundation

final class ErrorTests: XCTestCase {
    /// 意图：LexerError.invalidCharacter 携带非法字符与位置，解包后须原样取回 "@" 与 loc。
    func testLexerErrorInvalidCharacter() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = LexerError.invalidCharacter("@", loc)

        switch error {
        case .invalidCharacter(let char, let errorLoc):
            XCTAssertEqual(char, "@")
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 invalidCharacter")
        }
    }

    /// 意图：LexerError.unterminatedString 携带错误位置，解包后须取回 loc。
    func testLexerErrorUnterminatedString() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = LexerError.unterminatedString(loc)

        switch error {
        case .unterminatedString(let errorLoc):
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 unterminatedString")
        }
    }

    /// 意图：LexerError.indentationError 携带错误位置，解包后须取回 loc。
    func testLexerErrorIndentationError() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = LexerError.indentationError(loc)

        switch error {
        case .indentationError(let errorLoc):
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 indentationError")
        }
    }

    /// 意图：ParserError.invalidExpression 携带 reason 与 location，解包后须原样取回 "test" 与 loc。
    func testParserErrorInvalidExpression() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = ParserError.invalidExpression(reason: "test", location: loc)

        switch error {
        case .invalidExpression(let reason, let errorLoc):
            XCTAssertEqual(reason, "test")
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 invalidExpression")
        }
    }

    /// 意图：RuntimeError.undefinedVariable 携带变量名与位置，解包后须取回 "x" 与 loc。
    func testRuntimeErrorUndefinedVariable() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = RuntimeError.undefinedVariable(name: "x", location: loc)

        switch error {
        case .undefinedVariable(let name, let errorLoc):
            XCTAssertEqual(name, "x")
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 undefinedVariable")
        }
    }

    /// 意图：RuntimeError.typeMismatch 携带期望/实际类型与位置，解包后须分别取回 "int"、"string"、loc。
    func testRuntimeErrorTypeMismatch() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = RuntimeError.typeMismatch(expected: "int", got: "string", location: loc)

        switch error {
        case .typeMismatch(let expected, let got, let errorLoc):
            XCTAssertEqual(expected, "int")
            XCTAssertEqual(got, "string")
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 typeMismatch")
        }
    }

    /// 意图：ControlSignal.returnSignal 携带返回值，解包后须取回 `.int(42)`。
    func testControlSignalReturn() {
        let signal = ControlSignal.returnSignal(.int(42))
        switch signal {
        case .returnSignal(let value):
            if case .int(42) = value {
            } else {
                XCTFail("返回值应为 42")
            }
        default:
            XCTFail("应为 returnSignal")
        }
    }

    /// 意图：ControlSignal.breakSignal 携带跳出标签，解包后须取回 "outer"。
    func testControlSignalBreak() {
        let signal = ControlSignal.breakSignal(label: "outer")
        switch signal {
        case .breakSignal(let label):
            XCTAssertEqual(label, "outer")
        default:
            XCTFail("应为 breakSignal")
        }
    }

    /// 意图：ControlSignal.continueSignal 携带继续标签，解包后须取回 "outer"。
    func testControlSignalContinue() {
        let signal = ControlSignal.continueSignal(label: "outer")
        switch signal {
        case .continueSignal(let label):
            XCTAssertEqual(label, "outer")
        default:
            XCTFail("应为 continueSignal")
        }
    }
}

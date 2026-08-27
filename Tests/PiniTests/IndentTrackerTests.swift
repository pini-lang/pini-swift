import XCTest
import PiniCore
import Foundation

final class IndentTrackerTests: XCTestCase {
    /// 意图：验证缩进跟踪基本行为：首行无缩进不产生 token、增缩进产生 INDENT、减缩进产生 DEDENT。
    func testIndentTrackerBasicIndentDedent() throws {
        var tracker = IndentTracker()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")

        let tokens1 = try tracker.processLineStart(whitespaceCount: 0, location: loc)
        XCTAssertTrue(tokens1.isEmpty, "首行无缩进不应产生 token")

        let tokens2 = try tracker.processLineStart(whitespaceCount: 4, location: loc)
        XCTAssertEqual(tokens2.count, 1, "增加缩进应产生 INDENT")
        if case .indent(_) = tokens2[0] {
        } else {
            XCTFail("应为 INDENT")
        }

        let tokens3 = try tracker.processLineStart(whitespaceCount: 0, location: loc)
        XCTAssertEqual(tokens3.count, 1, "减少缩进应产生 DEDENT")
        if case .dedent(_) = tokens3[0] {
        } else {
            XCTFail("应为 DEDENT")
        }
    }

    /// 意图：验证多层缩进栈：两级缩进各产生 INDENT，退回顶层时一次性产生两个 DEDENT。
    func testIndentTrackerMultipleLevels() throws {
        var tracker = IndentTracker()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")

        let t1 = try tracker.processLineStart(whitespaceCount: 4, location: loc)
        XCTAssertEqual(t1.count, 1, "第一层缩进")

        let t2 = try tracker.processLineStart(whitespaceCount: 8, location: loc)
        XCTAssertEqual(t2.count, 1, "第二层缩进")

        let t3 = try tracker.processLineStart(whitespaceCount: 0, location: loc)
        XCTAssertEqual(t3.count, 2, "返回顶层应产生两个 DEDENT")
    }

    /// 意图：验证 finalize 在文件结束收尾缩进栈，为剩余两级缩进补发 2 个 DEDENT。
    func testIndentTrackerFinalize() throws {
        var tracker = IndentTracker()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")

        _ = try tracker.processLineStart(whitespaceCount: 4, location: loc)
        _ = try tracker.processLineStart(whitespaceCount: 8, location: loc)

        let finalTokens = tracker.finalize(location: loc)
        XCTAssertEqual(finalTokens.count, 2, "最终化应产生剩余 DEDENT")
    }
}

import XCTest
@testable import PiniCore
import Foundation

/// MiniTOML 行内注释剥离（工单 issue-minitoml-inline-comment-2026-09-07）：
/// 值行 / 表头行 / 数组表头行的行内 `#` 须按引号感知方式剥离（引号串内部的 `#` 不算注释）。
/// 缺陷背景：宿主 MiniTOML 只跳过整行注释，行内注释残片污染值，G52 Def-3 入口校验
/// 据此误报 E5-018（selfhost 清单 entry 行实测复现，潜伏 3 天）。
final class MiniTOMLTests: XCTestCase {

    // MARK: - 值行行内注释

    func testValueLineInlineCommentStripped() {
        let doc = MiniTOML.parse("""
        [package]
        entry = "src/main.pini"      # Executable entry (top-level alternation root)
        """)
        XCTAssertEqual(doc.plain("package")["entry"], "src/main.pini",
                       "值行行内注释残片不得透传（E5-018 误报根因）")
    }

    func testBareValueInlineCommentStripped() {
        let doc = MiniTOML.parse("""
        [package]
        name = pini-bootstrap # bare value with comment
        """)
        XCTAssertEqual(doc.plain("package")["name"], "pini-bootstrap")
    }

    func testQuotedHashPreserved() {
        let doc = MiniTOML.parse("""
        [package]
        note = "a # b"
        """)
        XCTAssertEqual(doc.plain("package")["note"], "a # b",
                       "引号串内部的 # 是值的一部分，不是注释")
    }

    func testFullLineCommentStillSkipped() {
        let doc = MiniTOML.parse("""
        [package]
        # full-line comment
        name = "x"
        """)
        XCTAssertEqual(doc.plain("package")["name"], "x")
    }

    // MARK: - 表头行内注释

    func testTableHeaderInlineComment() {
        let doc = MiniTOML.parse("""
        [a]
        x = "1"
        [tool.pini]  # Provisional
        target = "native"
        """)
        XCTAssertEqual(doc.tables["tool.pini"]?["target"], "native",
                       "表头行内注释不得使表头失效（原缺陷：键被写进上一个表）")
        XCTAssertEqual(doc.tables["a"]?["target"], nil)
    }

    func testArrayTableHeaderInlineComment() {
        let doc = MiniTOML.parse("""
        [[bin]]  # executable target
        path = "src/main.pini"
        """)
        XCTAssertEqual(doc.arrayTables["bin"]?.first?["path"], "src/main.pini")
    }
}

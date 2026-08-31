import XCTest
import PiniCore
import Foundation

final class ASTTests: XCTestCase {
    /// 意图：验证 SourceLocation 的 Equatable 语义
    /// 推进性测量：行/列/文件全同则相等
    /// 驳回性测量：行、列或文件名任一不同则不等
    func testSourceLocationEquatable() {
        let loc1 = SourceLocation(line: 1, column: 2, fileName: "test.pini")
        let loc2 = SourceLocation(line: 1, column: 2, fileName: "test.pini")
        let loc3 = SourceLocation(line: 2, column: 2, fileName: "test.pini")
        let loc4 = SourceLocation(line: 1, column: 3, fileName: "test.pini")
        let loc5 = SourceLocation(line: 1, column: 2, fileName: "other.pini")

        XCTAssertEqual(loc1, loc2, "相同位置应相等")
        XCTAssertNotEqual(loc1, loc3, "不同行不应相等")
        XCTAssertNotEqual(loc1, loc4, "不同列不应相等")
        XCTAssertNotEqual(loc1, loc5, "不同文件不应相等")
    }

    /// 意图：验证 TypeAnnotation.simple 的等值性
    /// 推进性测量：相同类型名相等
    /// 驳回性测量：不同类型名不等
    func testTypeAnnotationSimple() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let type1 = TypeAnnotation.simple(name: "I32", location: loc)
        let type2 = TypeAnnotation.simple(name: "I32", location: loc)
        let type3 = TypeAnnotation.simple(name: "F64", location: loc)

        XCTAssertEqual(type1, type2, "相同类型名应相等")
        XCTAssertNotEqual(type1, type3, "不同类型名不应相等")
    }

    /// 意图：验证标识符表达式 Expression.identifier 的等值性
    /// 推进性测量：同名标识符相等
    /// 驳回性测量：不同名标识符不等
    func testExpressionIdentifierEquatable() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let expr1 = Expression.identifier(name: "x", location: loc)
        let expr2 = Expression.identifier(name: "x", location: loc)
        let expr3 = Expression.identifier(name: "y", location: loc)

        XCTAssertEqual(expr1, expr2, "相同标识符应相等")
        XCTAssertNotEqual(expr1, expr3, "不同标识符不应相等")
    }

    /// 意图：验证语句的 Equatable 语义
    /// 推进性测量：同类型同参数语句相等
    /// 驳回性测量：不同类型语句不等、同类型不同标签的 break 不等
    func testStatementEquatable() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let stmt1 = Statement.returnStatement(value: nil, location: loc)
        let stmt2 = Statement.returnStatement(value: nil, location: loc)
        let stmt3 = Statement.breakStatement(label: nil, location: loc)
        let stmt4 = Statement.breakStatement(label: "outer", location: loc)

        XCTAssertEqual(stmt1, stmt2, "相同返回语句应相等")
        XCTAssertNotEqual(stmt1, stmt3, "不同类型语句不应相等")
        XCTAssertNotEqual(stmt3, stmt4, "不同标签的break不应相等")
    }

    /// 意图：验证顶层函数声明 TopLevelDecl.funcDecl 的等值性
    /// 推进性测量：同名同构函数声明相等
    /// 驳回性测量：函数名不同的声明不等
    func testTopLevelDeclFuncDecl() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let funcDecl1 = FuncDecl(name: "foo", modifiers: [], genericParams: [], params: [], returnTypes: [], body: nil, location: loc)
        let funcDecl2 = FuncDecl(name: "foo", modifiers: [], genericParams: [], params: [], returnTypes: [], body: nil, location: loc)
        let funcDecl3 = FuncDecl(name: "bar", modifiers: [], genericParams: [], params: [], returnTypes: [], body: nil, location: loc)
        let tl1 = TopLevelDecl.funcDecl(funcDecl1)
        let tl2 = TopLevelDecl.funcDecl(funcDecl2)
        let tl3 = TopLevelDecl.funcDecl(funcDecl3)

        XCTAssertEqual(tl1, tl2, "相同函数声明应相等")
        XCTAssertNotEqual(tl1, tl3, "不同函数名不应相等")
    }

    /// 意图：验证字段声明 FieldDecl 的等值性
    /// 推进性测量：同名同类型字段相等
    /// 驳回性测量：字段名不同的声明不等
    func testFieldDeclEquatable() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let type = TypeAnnotation.simple(name: "I32", location: loc)
        let field1 = FieldDecl(name: "x", typeAnnotation: type, initializer: nil, location: loc)
        let field2 = FieldDecl(name: "x", typeAnnotation: type, initializer: nil, location: loc)
        let field3 = FieldDecl(name: "y", typeAnnotation: type, initializer: nil, location: loc)

        XCTAssertEqual(field1, field2, "相同字段应相等")
        XCTAssertNotEqual(field1, field3, "不同字段名不应相等")
    }
}

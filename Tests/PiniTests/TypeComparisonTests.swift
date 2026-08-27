import XCTest
import PiniCore

/// TypeAnnotation 结构等价（忽略 SourceLocation）+ describe 渲染。
/// 直接对类型注解做白盒校验。
/// 注：live 调用点比对中「实参推断为 .function 类型」或「特化泛型值类型」依赖 P3 一等函数值 / 单态化，
/// 当前推断器不产生这类类型，故函数/泛型的 *端到端* 调用点比对留待 P3；此处覆盖等价谓词本身的正确性。
final class TypeComparisonTests: XCTestCase {

    private func loc() -> SourceLocation {
        SourceLocation(line: 1, column: 1, fileName: "t.pini")
    }

    // MARK: - simple

    /// 意图：验证同名 simple 类型等价（忽略 SourceLocation 差异）、不同名不等价。
    func testSimpleEquivalenceIgnoresLocation() {
        let a = TypeAnnotation.simple(name: "I32", location: loc())
        let b = TypeAnnotation.simple(name: "I32", location: SourceLocation(line: 9, column: 9, fileName: "other.pini"))
        XCTAssertTrue(a.isStructurallyEquivalent(to: b), "同名 simple 应等价（忽略位置）")
        let c = TypeAnnotation.simple(name: "String", location: loc())
        XCTAssertFalse(a.isStructurallyEquivalent(to: c), "不同名 simple 不应等价")
    }

    // MARK: - tuple（P2-2.1 基础）

    /// 意图：验证 tuple 逐分量比较——分量全部相同才等价，分量类型或个数不同均不等价。
    func testTupleEquivalenceComponentWise() {
        let l = loc()
        let t1 = TypeAnnotation.tuple(labels: [], elements: [.simple(name: "I32", location: l), .simple(name: "String", location: l)], location: l)
        let t2 = TypeAnnotation.tuple(labels: [], elements: [.simple(name: "I32", location: l), .simple(name: "String", location: l)], location: l)
        let t3 = TypeAnnotation.tuple(labels: [], elements: [.simple(name: "I32", location: l), .simple(name: "I32", location: l)], location: l)
        let t4 = TypeAnnotation.tuple(labels: [], elements: [.simple(name: "I32", location: l)], location: l)
        XCTAssertTrue(t1.isStructurallyEquivalent(to: t2), "逐分量相同应等价")
        XCTAssertFalse(t1.isStructurallyEquivalent(to: t3), "第二分量不同应不等价")
        XCTAssertFalse(t1.isStructurallyEquivalent(to: t4), "分量个数不同应不等价")
    }

    // MARK: - generic（P2-2.4 基础）

    /// 意图：验证 generic 等价需类型名与泛型实参逐一相同，实参类型或个数不同均不等价。
    func testGenericEquivalence() {
        let l = loc()
        let g1 = TypeAnnotation.generic(name: "Box", params: [.simple(name: "I32", location: l)], location: l)
        let g2 = TypeAnnotation.generic(name: "Box", params: [.simple(name: "I32", location: l)], location: l)
        let g3 = TypeAnnotation.generic(name: "Box", params: [.simple(name: "String", location: l)], location: l)
        let g4 = TypeAnnotation.generic(name: "Box", params: [.simple(name: "I32", location: l), .simple(name: "I32", location: l)], location: l)
        XCTAssertTrue(g1.isStructurallyEquivalent(to: g2), "同名同实参应等价")
        XCTAssertFalse(g1.isStructurallyEquivalent(to: g3), "泛型实参不同应不等价")
        XCTAssertFalse(g1.isStructurallyEquivalent(to: g4), "泛型实参个数不同应不等价")
    }

    // MARK: - function（P2-2.2 基础）

    /// 意图：验证函数类型等价需参数/返回签名逐一相同，返回类型或参数个数不同均不等价。
    func testFunctionTypeEquivalence() {
        let l = loc()
        let f1 = TypeAnnotation.function(params: [.simple(name: "I32", location: l)], returns: [.simple(name: "I32", location: l)], captured: [], location: l)
        let f2 = TypeAnnotation.function(params: [.simple(name: "I32", location: l)], returns: [.simple(name: "I32", location: l)], captured: [], location: l)
        let f3 = TypeAnnotation.function(params: [.simple(name: "I32", location: l)], returns: [.simple(name: "String", location: l)], captured: [], location: l)
        let f4 = TypeAnnotation.function(params: [.simple(name: "I32", location: l), .simple(name: "String", location: l)], returns: [.simple(name: "I32", location: l)], captured: [], location: l)
        XCTAssertTrue(f1.isStructurallyEquivalent(to: f2), "签名相同应等价")
        XCTAssertFalse(f1.isStructurallyEquivalent(to: f3), "返回类型不同应不等价")
        XCTAssertFalse(f1.isStructurallyEquivalent(to: f4), "参数个数不同应不等价")
    }

    // MARK: - describe

    /// 意图：验证 describe() 对 tuple / generic / function 类型的渲染格式正确。
    func testDescribe() {
        let l = loc()
        // 推进性测量：各类型渲染为预期格式。
        let t = TypeAnnotation.tuple(labels: [], elements: [.simple(name: "I32", location: l), .simple(name: "String", location: l)], location: l)
        XCTAssertEqual(t.describe(), "(I32, String)")
        let g = TypeAnnotation.generic(name: "Box", params: [.simple(name: "I32", location: l)], location: l)
        XCTAssertEqual(g.describe(), "Box<I32>")
        let f = TypeAnnotation.function(params: [.simple(name: "I32", location: l)], returns: [.simple(name: "I32", location: l)], captured: [], location: l)
        XCTAssertEqual(f.describe(), "(I32) -> (I32)")
        let s = TypeAnnotation.simple(name: "I32", location: l)
        XCTAssertEqual(s.describe(), "I32")

        // 驳回性测量：渲染不得产生格式损坏（如连续逗号、错位括号），且嵌套应正确包裹。
        XCTAssertFalse(t.describe().contains(",,"), "describe 不应产生连续逗号（格式损坏），实际: \(t.describe())")
        XCTAssertFalse(t.describe().hasPrefix(",") || t.describe().hasSuffix(","), "describe 首尾不应有多余逗号，实际: \(t.describe())")
        let nested = TypeAnnotation.tuple(labels: [], elements: [t, .simple(name: "Bool", location: l)], location: l)
        XCTAssertEqual(nested.describe(), "((I32, String), Bool)", "嵌套元组应正确包裹，实际: \(nested.describe())")
    }
}

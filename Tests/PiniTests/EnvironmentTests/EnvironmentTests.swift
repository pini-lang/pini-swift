import XCTest
import PiniCore
import Foundation

final class EnvironmentTests: XCTestCase {
    /// 意图：变量 define 后 get 应能取回所存值 `.int(42)`，验证「定义后可得」的成功路径。
    func testEnvironmentDefineAndGet() {
        let env = Environment()

        env.define(name: "x", value: .int(42), isMutable: true)
        let result = try? env.get(name: "x")

        XCTAssertNotNil(result, "应能获取已定义的变量")
        if case .int(42) = result {
        } else {
            XCTFail("变量值应为 42")
        }
    }

    /// 意图：get 未定义变量 `nonexistent` 必须抛 RuntimeError.undefinedVariable（错误路径）。
    func testEnvironmentUndefinedVariable() {
        let env = Environment()

        XCTAssertThrowsError(try env.get(name: "nonexistent"), "未定义的变量应抛出错误") { error in
            guard case RuntimeError.undefinedVariable(name: "nonexistent", _) = error else {
                XCTFail("应为 undefinedVariable 错误")
                return
            }
        }
    }

    /// 意图：isMutable 变量的 assign 应成功生效——x 从 10 改写为 20 后 get 取回 20。
    func testEnvironmentAssignMutable() {
        let env = Environment()

        env.define(name: "x", value: .int(10), isMutable: true)
        try? env.assign(name: "x", value: .int(20))
        let result = try? env.get(name: "x")

        if case .int(20) = result {
        } else {
            XCTFail("可变变量应能被修改")
        }
    }

    /// 意图：不可变（let）变量再次 assign 必须抛错，运行时拒绝改写（错误路径）。
    func testEnvironmentAssignImmutable() {
        let env = Environment()

        env.define(name: "x", value: .int(10), isMutable: false)
        XCTAssertThrowsError(try env.assign(name: "x", value: .int(20)), "不可变变量不应能被修改")
    }

    /// 意图：内层作用域可沿 enclosing 链读取外层变量 outer=1，同时可访问自身变量 inner=2。
    func testEnvironmentNestedScope() {
        let outer = Environment()
        outer.define(name: "outer", value: .int(1), isMutable: true)

        let inner = Environment(enclosing: outer)
        inner.define(name: "inner", value: .int(2), isMutable: true)

        let outerFromInner = try? inner.get(name: "outer")
        let innerVal = try? inner.get(name: "inner")

        if case .int(1) = outerFromInner {
        } else {
            XCTFail("内层应能访问外层变量")
        }
        if case .int(2) = innerVal {
        } else {
            XCTFail("应能访问内层变量")
        }
    }

    /// 意图：同名变量在内存遮蔽外层——内层 x=20、外层 x 保持 10，两侧取值互不影响。
    func testEnvironmentShadowing() {
        let outer = Environment()
        outer.define(name: "x", value: .int(10), isMutable: true)

        let inner = Environment(enclosing: outer)
        inner.define(name: "x", value: .int(20), isMutable: true)

        let outerX = try? outer.get(name: "x")
        let innerX = try? inner.get(name: "x")

        if case .int(10) = outerX {
        } else {
            XCTFail("外层变量应保持不变")
        }
        if case .int(20) = innerX {
        } else {
            XCTFail("内层变量应被遮蔽")
        }
    }
}

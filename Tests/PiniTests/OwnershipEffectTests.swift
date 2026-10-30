import Testing

@testable import PiniCore

/// 求值效果表：一个表达式求值之后，求值方是不是新造了一份份额。
/// 这张表决定「临时值要不要在消费点归还」，所以它的每一条都要能被单独钉住。
@Suite("求值效果表")
struct OwnershipEffectTests: Sendable {

    private static func aString() -> IRExpr { .stringConst(value: "x") }
    private static func anArray() -> IRExpr { .arrayLiteral(elements: [], type: .array(element: .i32)) }

    @Test("标量与整块聚合不参与计数")
    func scalarsAndAggregatesAreInert() {
        #expect(IRExpr.intConst(value: 1, type: .i32).ownershipEffect == .inert)
        #expect(IRExpr.boolConst(value: true).ownershipEffect == .inert)
        #expect(IRExpr.lenCall(argument: Self.anArray()).ownershipEffect == .inert)
        #expect(IRExpr.resultConstruct(isOk: true, payload: .intConst(value: 1, type: .i32),
                                       type: .result(ok: .i32)).ownershipEffect == .inert)
    }

    @Test("变量读与全局常量是借用 —— 份额在别处")
    func loadsAndConstantsAreBorrowed() {
        #expect(IRExpr.load(name: "s", type: .string).ownershipEffect == .borrowed)
        #expect(Self.aString().ownershipEffect == .borrowed)
    }

    @Test("本次求值新造的份额：字符串内建 · 字面量 · 构造")
    func freshNodes() {
        #expect(IRExpr.stringSubstring(receiver: Self.aString(), start: .intConst(value: 0, type: .i32),
                                       length: .intConst(value: 1, type: .i32))
            .ownershipEffect == .fresh)
        #expect(IRExpr.stringCase(isUpper: true, receiver: Self.aString()).ownershipEffect == .fresh)
        #expect(IRExpr.stringTrimLeft(receiver: Self.aString()).ownershipEffect == .fresh)
        #expect(IRExpr.stringSplit(receiver: Self.aString(), delim: Self.aString(),
                                   type: .array(element: .string)).ownershipEffect == .fresh)
        #expect(IRExpr.stringConcat(lhs: Self.aString(), rhs: Self.aString()).ownershipEffect == .fresh)
        #expect(Self.anArray().ownershipEffect == .fresh)
        #expect(IRExpr.construct(type: .nominal(name: "Point", isObject: false)).ownershipEffect == .fresh)
    }

    /// `returnStmt` 的 `adopt` 已在被调方安排好份额，故调用点接手的一定是干净的一份。
    @Test("调用返回按新份额：交临时就是移交，交别名先保留")
    func callResultsAreFresh() {
        #expect(IRExpr.call(function: "f", arguments: [], returnType: .string).ownershipEffect == .fresh)
        let callee = IRExpr.load(
            name: "g", type: .function(params: [], returnType: .string, usingIndices: []))
        #expect(IRExpr.indirectCall(callee: callee, arguments: [], returnType: .string)
            .ownershipEffect == .fresh)
    }

    /// 结构不变式：别名点必然是借用 —— 反过来说，任何被判成「新份额」的节点都不能是别名点，
    /// 否则存储点会边 retain 边当成临时值接管。
    @Test("别名点与借用同边界")
    func aliasPointsImplyBorrowed() {
        let aliases: [IRExpr] = [
            .load(name: "s", type: .string),
            .subscriptGet(container: Self.anArray(), index: .intConst(value: 0, type: .i32), type: .i32),
            .fieldGet(base: .construct(type: .nominal(name: "P", isObject: false)),
                      field: "s", type: .string),
            .optionalGet(container: Self.anArray(), index: .intConst(value: 0, type: .i32), type: .i32),
        ]
        for node in aliases {
            #expect(node.yieldsAlias, "\(node) 应判为别名点")
            #expect(node.ownershipEffect == .borrowed, "\(node) 的来源在别处，只能是借用")
        }
    }

    /// `readLine` 返回 `fgets` 填的栈缓冲：既不是新份额，也不会在帧外存活。
    /// 把它判成 `fresh` 会让消费点去释放一块栈内存。
    @Test("readLine 的栈缓冲不是可释放的份额")
    func readLineIsBorrowed() {
        #expect(IRExpr.readLine.ownershipEffect == .borrowed)
    }
}

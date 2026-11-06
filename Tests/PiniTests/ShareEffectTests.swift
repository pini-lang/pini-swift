import Testing

@testable import PiniCore
@testable import PiniIR

/// 求值效果表：一个表达式求值之后，求值方是不是新造了一份份额。
/// 这张表决定「临时值要不要在消费点归还」，所以每个节点都要能被单独钉住 ——
/// 判定改一处，这里就得跟着改一处，改的人必须看见那一行。
@Suite("求值效果表")
struct ShareEffectTests: Sendable {

    private static var scalar: IRExpr { .intConst(value: 1, type: .i32) }
    private static var text: IRExpr { .stringConst(value: "x") }
    private static var array: IRExpr { .arrayLiteral(elements: [], type: .array(element: .i32)) }
    private static var strings: IRExpr { .arrayLiteral(elements: [], type: .array(element: .string)) }
    private static var construct: IRExpr { .construct(type: .nominal(name: "P", isObject: false)) }
    private static var address: IRExpr { .addressOfVar(name: "x", type: .i32) }
    private static var functionType: IRType { .function(params: [], returnType: nil, usingIndices: []) }
    private static var closure: IRExpr {
        .closureLiteral(
            id: 1, paramNames: [], paramTypes: [], returnType: nil, captures: [], body: IRBlock([]),
            type: functionType)
    }
    private static var result: IRExpr {
        .resultConstruct(isOk: true, payload: scalar, errorBaseCode: 0, errorTagged: false, errorCodes: nil, type: .result(ok: .i32))
    }
    private static var tuple: IRExpr {
        .tupleConstruct(labels: [nil], elements: [scalar], type: .tuple(labels: [nil], fieldTypes: [.i32]))
    }
    private static var optional: IRExpr {
        .optionalConstruct(isSome: false, payload: nil, type: .optional(wrapped: .i32))
    }

    /// 一行一个表达式节点：节点名 · 代表实例 · 期望效果。行数与契约第 2 节的 53 条相等。
    private static var catalogue: [(String, IRExpr, IRShareEffect)] { [
        ("intConst", scalar, .inert),
        ("floatConst", .floatConst(value: 1.5), .inert),
        ("boolConst", .boolConst(value: true), .inert),
        ("stringConst", text, .borrowed),
        ("load", .load(name: "s", type: .string), .borrowed),
        ("binary", .binary(op: .add, lhs: scalar, rhs: scalar, type: .i32), .inert),
        ("unary", .unary(op: .negate, operand: scalar, type: .i32), .inert),
        ("call", .call(function: "f", arguments: [], returnType: .i32), .fresh),
        ("printCall", .printCall(argument: scalar), .inert),
        ("resultConstruct", result, .inert),
        ("arrayLiteral", array, .fresh),
        ("subscriptGet", .subscriptGet(container: array, index: scalar, type: .i32), .borrowed),
        ("lenCall", .lenCall(argument: array), .inert),
        (
            "optionalGet",
            .optionalGet(container: array, index: scalar, type: .optional(wrapped: .i32)),
            .inert
        ),
        ("optionalConstruct", optional, .inert),
        ("sliceCall", .sliceCall(container: array, start: scalar, end: scalar, type: .array(element: .i32)), .fresh),
        ("construct", construct, .fresh),
        (
            "enumConstruct",
            .enumConstruct(
                enumName: "E", caseName: "c", tag: 0, payloads: [], payloadTypes: [],
                type: .enumeration(name: "E")), .fresh
        ),
        ("fieldGet", .fieldGet(base: construct, field: "f", type: .i32), .borrowed),
        ("dictLiteral", .dictLiteral(entries: [], type: .dict(key: .string, value: .i32)), .fresh),
        ("setLiteral", .setLiteral(elements: [], type: .set(element: .i32)), .fresh),
        ("tupleConstruct", tuple, .inert),
        ("tupleIndexGet", .tupleIndexGet(base: tuple, index: 0, type: .i32), .borrowed),
        ("closureLiteral", closure, .fresh),
        ("functionValue", .functionValue(functionName: "f", type: functionType), .borrowed),
        ("indirectCall", .indirectCall(callee: closure, arguments: [], returnType: .i32), .fresh),
        ("pointerLoad", .pointerLoad(pointer: address, type: .i32), .inert),
        ("pointerStore", .pointerStore(pointer: address, value: scalar, type: .i32), .inert),
        ("addressOfVar", address, .inert),
        ("printMulti", .printMulti(arguments: [scalar]), .inert),
        ("assertCall", .assertCall(condition: .boolConst(value: true), message: nil), .inert),
        ("fileWrite", .fileWrite(path: text, content: text), .inert),
        ("fileAppend", .fileAppend(path: text, content: text), .inert),
        ("fileRead", .fileRead(path: text), .fresh),
        ("fileTryWrite", .fileTryWrite(path: text, content: text), .inert),
        ("fileTryAppend", .fileTryAppend(path: text, content: text), .inert),
        ("fileTryRead", .fileTryRead(path: text), .fresh),
        ("readLine", .readLine, .borrowed),
        ("isAsciiDigit", .isAsciiDigit(argument: text), .inert),
        ("stringCase", .stringCase(isUpper: true, receiver: text), .fresh),
        ("stringContains", .stringContains(receiver: text, needle: text), .inert),
        ("stringSubstring", .stringSubstring(receiver: text, start: scalar, length: scalar), .fresh),
        ("stringSplit", .stringSplit(receiver: text, delim: text, type: .array(element: .string)), .fresh),
        ("stringTrimLeft", .stringTrimLeft(receiver: text), .fresh),
        ("stringTrimRight", .stringTrimRight(receiver: text), .fresh),
        ("stringIndexOf", .stringIndexOf(receiver: text, needle: text), .inert),
        ("arrayJoin", .arrayJoin(receiver: strings, separator: text), .fresh),
        ("stringConcat", .stringConcat(lhs: text, rhs: text), .fresh),
        ("interpString", .interpString(parts: [text]), .fresh),
        ("lazyRefConstruct", .lazyRefConstruct(closure: closure, type: .lazyRef(element: .i32)), .fresh),
        (
            "lazyRefValue",
            .lazyRefValue(handle: .load(name: "l", type: .lazyRef(element: .i32)), type: .i32),
            .borrowed
        ),
        (
            "join",
            .join(
                future: .load(name: "h", type: .future(ok: .i32)), type: .result(ok: .i32),
                form: .waits), .inert
        ),
        ("givenInstance", .givenInstance(type: .nominal(name: "P", isObject: false)), .borrowed),
    ] }

    @Test("53 个表达式节点逐一表态，一个不漏")
    func everyExpressionNodeIsPinned() {
        #expect(Self.catalogue.count == 53, "契约第 2 节是 53 个表达式节点，表里少了或多了一条")
        for (name, expression, expected) in Self.catalogue {
            #expect(
                expression.shareEffect == expected,
                "\(name) 的求值效果是 \(expression.shareEffect)，表里写的是 \(expected)")
        }
    }

    /// 结构不变式：不计数成员的别名点必然是借用 —— 任何被判成「新份额」的节点都不能是别名点，
    /// 否则存储点会边 retain 边当成临时值接管。计数成员是唯一的例外：解构时先保留一份。
    @Test("别名点与借用同边界")
    func aliasPointsImplyBorrowed() {
        let aliases: [IRExpr] = [
            .load(name: "s", type: .string),
            .subscriptGet(container: Self.array, index: Self.scalar, type: .i32),
            .fieldGet(base: Self.construct, field: "s", type: .string),
            .tupleIndexGet(base: Self.tuple, index: 0, type: .i32),
        ]
        for node in aliases {
            #expect(node.yieldsAlias, "\(node) 应判为别名点")
            #expect(node.shareEffect == .borrowed, "\(node) 的来源在别处，只能是借用")
        }
    }

    @Test("解构计数成员：先保留一份，故结果是新份额")
    func destructuringCountedMemberIsFresh() {
        let optionalString = IRType.optional(wrapped: .string)
        let tupleString = IRExpr.tupleConstruct(
            labels: [nil], elements: [Self.text], type: .tuple(labels: [nil], fieldTypes: [.string]))
        #expect(
            IRExpr.optionalGet(container: Self.array, index: Self.scalar, type: optionalString)
                .shareEffect == .fresh)
        #expect(
            IRExpr.tupleIndexGet(base: tupleString, index: 0, type: .string).shareEffect == .fresh)
        #expect(
            IRExpr.optionalConstruct(isSome: true, payload: Self.text, type: optionalString)
                .shareEffect == .fresh)
        /// 同一个 `join` 节点按载荷分派：串载荷是新份额，标量载荷仍是零动作。
        #expect(
            IRExpr.join(
                future: .load(name: "h", type: .future(ok: .string)), type: .result(ok: .string),
                form: .waits
            ).shareEffect == .fresh)
        #expect(
            IRExpr.join(
                future: .load(name: "h", type: .future(ok: .i32)), type: .result(ok: .i32),
                form: .waits
            ).shareEffect == .inert)
        /// 已结算值上的 `wait` 是原样透传：读到的是那个 `Result` 的槽，只能是借用。
        #expect(
            IRExpr.join(
                future: .load(name: "r", type: .result(ok: .string)), type: .result(ok: .string),
                form: .waits
            ).shareEffect == .borrowed)
    }

    @Test("聚合的份额名单只列计数成员，空名单就是零动作")
    func aggregateMemberRoster() {
        #expect(IRType.optional(wrapped: .string).holdsAShare)
        #expect(!IRType.optional(wrapped: .i32).holdsAShare)
        #expect(
            IRType.tuple(labels: [nil, nil], fieldTypes: [.i32, .string])
                .ownedAggregateMembers.map(\.slot) == [1])
        #expect(IRType.optional(wrapped: .string).ownedAggregateMembers.first?.tagSlot == 0)
        #expect(!Self.functionType.holdsAShare)
    }
}

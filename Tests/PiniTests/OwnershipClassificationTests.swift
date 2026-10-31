import Testing

@testable import PiniCore
@testable import PiniIR

/// 所有权分类的判据钉在 `IRType` 上，不钉 LLVM 拼写：拼写是后端的表示，换表示时它变，而分类一变，
/// 失效的形态是「某一族悄悄不再释放」。故每个 case 都要在表里表态，新增类型时这张表会先红。
@Suite("类型的所有权分类")
struct OwnershipClassificationTests: Sendable {

    /// 21 个 case 对应 22 行：名义箱按两种语义各占一行（结构体值语义、对象引用语义），它仍是同一个 case。
    /// 表由函数现取而不是静态属性：`IRType` 尚未声明 `Sendable`，静态属性在 Swift 6 下编不过。
    private static func cases() -> [(label: String, type: IRType, expected: IROwnershipClass)] {
        [
            ("I8", .i8, .inert),
            ("U8", .u8, .inert),
            ("I32", .i32, .inert),
            ("I64", .i64, .inert),
            ("U64", .u64, .inert),
            ("F64", .f64, .inert),
            ("Bool", .boolean, .inert),
            ("String", .string, .retained(.string)),
            ("Char", .char, .retained(.string)),
            ("Result", .result(ok: .i32), .aggregate),
            ("Future", .future(ok: .i32), .inert),
            ("Array", .array(element: .i32), .retained(.array)),
            ("Optional", .optional(wrapped: .i32), .aggregate),
            ("Struct", .nominal(name: "P", isObject: false), .valueBox),
            ("Object", .nominal(name: "P", isObject: true), .retained(.object)),
            ("Enum", .enumeration(name: "E"), .retained(.enumeration)),
            ("Dict", .dict(key: .string, value: .i32), .retained(.dict)),
            ("LazyRef", .lazyRef(element: .i32), .retained(.lazyRef)),
            ("Set", .set(element: .i32), .retained(.set)),
            ("Tuple", .tuple(labels: ["a"], fieldTypes: [.i32]), .aggregate),
            ("Function", .function(params: [.i32], returnType: .i32, usingIndices: []), .aggregate),
            ("Pointer", .pointer(element: .i32), .inert),
        ]
    }

    @Test("每个 IRType case 都有族 —— 表外的类型是漏判，不是不参与计数")
    func everyTypeDeclaresAClass() {
        let table = Self.cases()
        #expect(table.count == 22, "表应有 22 行（21 个 case，名义箱占两行）")
        for row in table {
            #expect(
                row.type.ownershipClass == row.expected,
                "\(row.label) 的分类应是 \(row.expected)，实际是 \(row.type.ownershipClass)"
            )
        }
        /// 行内不得重复：复制一行改标签是最容易犯的错，而它会让某个 case 从未被真正检查。
        #expect(Set(table.map(\.label)).count == table.count, "表里有重复的标签")
        let types = table.map { String(describing: $0.type) }
        #expect(Set(types).count == types.count, "表里有重复的类型")
    }

    @Test("结构体与对象分成两族 —— 值语义要拷贝，引用语义要保留")
    func valueBoxAndObjectPartCompany() {
        #expect(IRType.nominal(name: "P", isObject: false).ownershipClass == .valueBox)
        #expect(IRType.nominal(name: "P", isObject: true).ownershipClass == .retained(.object))
    }

    @Test("计数族只分符号不分规则 —— 七种都在 retained 里")
    func everyShareKindIsRetained() {
        let counted: [IRType] = [
            .string, .char, .array(element: .i32), .dict(key: .string, value: .i32),
            .set(element: .i32), .lazyRef(element: .i32),
            .nominal(name: "P", isObject: true), .enumeration(name: "E"),
        ]
        for type in counted {
            guard case .retained = type.ownershipClass else {
                Issue.record("\(type) 应归在计数族，实际是 \(type.ownershipClass)")
                return
            }
        }
    }

    @Test("拼写不参与分类 —— 外部指针与任务句柄都不计数，尽管它们会被拼成与计数族相同的字面")
    func spellingDoesNotDecideTheClass() {
        // `*T` 在元素的装箱 ABI 里拼成 `i8*`（与 String 同字面），但它是外呼指针，不握份额。
        #expect(IRType.pointer(element: .i32).ownershipClass == .inert)
        // 任务句柄拼成 `ptr`，同样不在计数族。
        #expect(IRType.future(ok: .i32).ownershipClass == .inert)
    }

    @Test("聚合按整块搬移 —— 内部的计数成员尚未单独保留，是缺口而不是可以不要份额")
    func aggregatesDoNotInheritTheirMembers() {
        #expect(IRType.optional(wrapped: .string).ownershipClass == .aggregate)
        #expect(IRType.result(ok: .array(element: .i32)).ownershipClass == .aggregate)
        // 这一条钉的是现状：聚合里的字符串 / 句柄不单独进账。若日后实现递归保留，这里会红，
        // 而它就是「缺口是否已被补上」的读数点。
        #expect(IRType.tuple(labels: ["s"], fieldTypes: [.string]).ownershipClass == .aggregate)
    }
}

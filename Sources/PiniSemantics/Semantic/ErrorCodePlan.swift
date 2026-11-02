import Foundation
import PiniSyntax

/// 一条 C 边界错误码。`derived` 由类型序与用例 tag 组合，`declared` 来自作者写的 `码()`，
/// `automatic` 是非 enum 未申报时的顺序兜底，`hashed` 由三段名字散列而来。
public struct PiniErrorCode: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case derived
        case declared
        case automatic
        case hashed
    }

    public let typeName: String
    /// enum 用例名；非 enum 载体为 nil。
    public let caseName: String?
    public let code: Int32
    public let source: Source
    /// 类型声明处：E7-004 等诊断要指到这里。
    public let location: SourceLocation
    /// 散列落点被前一个名字占用后顺延的步数；非散列来源恒为 0。
    public let probeSteps: Int

    public init(
        typeName: String, caseName: String?, code: Int32, source: Source,
        location: SourceLocation, probeSteps: Int = 0
    ) {
        self.typeName = typeName
        self.caseName = caseName
        self.code = code
        self.source = source
        self.location = location
        self.probeSteps = probeSteps
    }

    /// `calc_strerror` 的名字形态：`类型名.用例名`，非 enum 只有类型名。
    public var display: String {
        if let caseName { return "\(typeName).\(caseName)" }
        return typeName
    }
}

/// 码空间分段。固定码 `0`/`1`/`2` 之后依次是派生区、自动区、散列区，三段互不重叠：
/// 派生 `0x0100...0x3FFF`（63 类型 × 256 用例），自动从 `0x4000` 起，散列落 `0x1000_0000` 起。
public enum ErrorCodeSpace {
    public static let success: Int32 = 0
    public static let unclassified: Int32 = 1
    public static let cancelled: Int32 = 2
    /// 手写码的下界：三个固定值不可占用，占了这个错误就与成功/取消无从分辨。
    public static let reservedBelow: Int32 = 3
    public static let derivedBase: Int32 = 0x0100
    public static let derivedLimit: Int32 = 0x4000
    /// 派生区容量：类型序占一个字节，超出就从 `0x4000` 起与自动区重叠。
    public static let derivedCapacity = 63
    /// 单个类型可用的 tag 数：用例序占一个字节，超出就溢到下一个类型的基址。
    public static let casesPerType = 256
    public static let automaticBase: Int32 = 0x4000
    public static let hashedBase: Int32 = 0x1000_0000
    public static let hashedSpan: Int32 = 0x3000_0000
}

/// 码表发现的问题。校验与分配同源：只有真的排过码，才知道区间满没满、载体写没写对。
/// `reason` 是一句自成句子的说明，诊断头由格式化层加。
public struct ErrorCodeIssue: Equatable, Sendable {
    public let reason: String
    public let location: SourceLocation

    public init(reason: String, location: SourceLocation) {
        self.reason = reason
        self.location = location
    }
}

/// 导出面的错误码表。派生、手写、自动、散列四种来源同处一张表，查重也在一处做。
/// 表只收「导出函数写明的错误类型」：库内部错误不占码，也不刷警告。
public struct ErrorCodePlan: Equatable, Sendable {
    public let entries: [PiniErrorCode]
    /// 类型名 → 基址。导出桩把 enum 失败折成码时用它。
    public let byType: [String: Int32]
    /// 类型名 → 按用例 tag 索引的码表。只有散列来源需要它：码不再是 `基址 | tag`。
    public let hashedTables: [String: [Int32]]
    /// 导出面的块名（= 文件名），散列三段的第一段；没有 C 面时为 nil。
    public let surface: String?
    /// 阻碍这张表发出去的缺陷：非空时语义层报错，降载仍照常进行（诊断已在上游给出）。
    public let issues: [ErrorCodeIssue]

    public init(
        entries: [PiniErrorCode], byType: [String: Int32],
        hashedTables: [String: [Int32]], surface: String?, issues: [ErrorCodeIssue] = []
    ) {
        self.entries = entries
        self.byType = byType
        self.hashedTables = hashedTables
        self.surface = surface
        self.issues = issues
    }

    /// 自动分配的非 enum 码：E7-004 警告的输入。
    public var automaticEntries: [PiniErrorCode] {
        entries.filter { $0.source == .automatic }
    }

    /// 排码：派生区按类型序，手写码先占位（手动优先），散列与自动让开已占的位。
    /// 校验与分配同源 —— 区间满、用例溢出、载体写错都在排码时才看得见。
    public static func build(module: Module) -> ErrorCodePlan {
        let cBlocks = module.exports.filter { block in
            block.entries.contains { $0.target == .c }
        }
        let surface = cBlocks.first?.name
        let reachable = reachableErrorTypes(in: cBlocks, declarations: module.declarations)

        var derivedEnums: [(name: String, cases: [String], location: SourceLocation)] = []
        var hashedEnums: [HashedType] = []
        var nonEnums: [(name: String, location: SourceLocation)] = []
        var errorEnums: Set<String> = []
        for decl in module.declarations {
            switch decl {
            case .enumDecl(let e) where e.traits.contains(TypeChecker.errorTraitName):
                guard reachable.contains(e.name) else { continue }
                errorEnums.insert(e.name)
                let cases = e.cases.map { $0.name }
                if e.traits.contains(TypeChecker.stableCodeTraitName) {
                    hashedEnums.append(
                        HashedType(name: e.name, cases: cases, location: e.location))
                } else {
                    derivedEnums.append((e.name, cases, e.location))
                }
            case .structDecl(let s) where s.traits.contains(TypeChecker.errorTraitName):
                guard reachable.contains(s.name) else { continue }
                nonEnums.append((s.name, s.location))
            case .objectDecl(let o) where o.traits.contains(TypeChecker.errorTraitName):
                guard reachable.contains(o.name) else { continue }
                nonEnums.append((o.name, o.location))
            default:
                break
            }
        }

        var issues: [ErrorCodeIssue] = []
        for decl in module.declarations {
            guard case .extensionDecl(let ext) = decl, errorEnums.contains(ext.targetType),
                ext.methods.contains(where: { $0.name == "码" && $0.params.isEmpty })
            else { continue }
            issues.append(
                ErrorCodeIssue(
                    reason:
                        "`码()` 在 enum 上不生效：用例码由类型序与用例 tag 派生，"
                        + "要跨版本稳定请改写 `实现: 稳定码`",
                    location: ext.location))
        }

        var entries: [PiniErrorCode] = []
        var byType: [String: Int32] = [:]
        var used: Set<Int32> = []
        for (index, entry) in derivedEnums.sorted(by: { $0.name < $1.name }).enumerated() {
            if index == ErrorCodeSpace.derivedCapacity {
                issues.append(
                    ErrorCodeIssue(
                        reason:
                            "派生区只容 \(ErrorCodeSpace.derivedCapacity) 个错误类型，"
                            + "从 '\(entry.name)' 起与自动区重叠：多出的类型改用 `稳定码` 或手写码",
                        location: entry.location))
            }
            if entry.cases.count > ErrorCodeSpace.casesPerType {
                issues.append(
                    ErrorCodeIssue(
                        reason:
                            "'\(entry.name)' 有 \(entry.cases.count) 个用例，超出一个字节的 tag 空间"
                            + "（\(ErrorCodeSpace.casesPerType)）：多出的用例码会溢到下一个类型的基址",
                        location: entry.location))
            }
            let base = Int32(index + 1) << 8
            byType[entry.name] = base
            for (tag, caseName) in entry.cases.enumerated() {
                let code = base | Int32(tag)
                used.insert(code)
                entries.append(
                    PiniErrorCode(
                        typeName: entry.name, caseName: caseName, code: code,
                        source: .derived, location: entry.location))
            }
        }

        /// 申报过码的类型名（含申报不合格的）：这些类型不再进自动区。
        /// 不合格的码已由 E4-027 报出，再补一个「已自动分配」的警告只会自相矛盾。
        var claimedNames: Set<String> = []
        for entry in nonEnums.sorted(by: { $0.name < $1.name }) {
            switch declaredErrorCode(typeName: entry.name, declarations: module.declarations) {
            case .absent:
                continue
            case .invalid(let reason):
                claimedNames.insert(entry.name)
                issues.append(ErrorCodeIssue(reason: reason, location: entry.location))
            case .value(let code):
                claimedNames.insert(entry.name)
                byType[entry.name] = code
                used.insert(code)
                entries.append(
                    PiniErrorCode(
                        typeName: entry.name, caseName: nil, code: code,
                        source: .declared, location: entry.location))
            }
        }

        let hashed = allocateHashed(
            hashedEnums, surface: surface ?? "", occupied: used)
        entries += hashed.entries
        byType.merge(hashed.byType) { first, _ in first }
        used.formUnion(hashed.entries.map { $0.code })

        var nextAutomatic = ErrorCodeSpace.automaticBase
        for entry in nonEnums.sorted(by: { $0.name < $1.name })
        where !claimedNames.contains(entry.name) {
            while used.contains(nextAutomatic) { nextAutomatic += 1 }
            byType[entry.name] = nextAutomatic
            used.insert(nextAutomatic)
            entries.append(
                PiniErrorCode(
                    typeName: entry.name, caseName: nil, code: nextAutomatic,
                    source: .automatic, location: entry.location))
            nextAutomatic += 1
        }
        return ErrorCodePlan(
            entries: entries, byType: byType, hashedTables: hashed.tables, surface: surface,
            issues: issues)
    }

    /// 散列分配的单位：一个错误类型及其用例。
    struct HashedType {
        let name: String
        let cases: [String]
        let location: SourceLocation
    }

    /// 散列分配的结果。`tables` 按类型给出「tag → 码」，导出桩据此折算。
    struct HashedAllocation {
        let entries: [PiniErrorCode]
        let tables: [String: [Int32]]
        let byType: [String: Int32]
    }

    /// 散列区：码 = `散列(块名, 类型名, 用例名) % 区间长度 + 起点`。同一导出面内撞位时按名字序线性
    /// 顺延，并把步数留在条目上（头文件与警告据此说明「这个码不是落点」）。区间独占，故只可能自撞。
    static func allocateHashed(
        _ types: [HashedType], surface: String, occupied: Set<Int32>
    ) -> HashedAllocation {
        var used = occupied
        var entries: [PiniErrorCode] = []
        var tables: [String: [Int32]] = [:]
        var byType: [String: Int32] = [:]
        let ordered = types.sorted { $0.name < $1.name }
        for type in ordered {
            var table: [Int32] = []
            for caseName in type.cases {
                var code = hashedCode(surface: surface, type: type.name, case: caseName)
                var steps = 0
                while used.contains(code) && steps < Int(ErrorCodeSpace.hashedSpan) {
                    code = nextHashed(code)
                    steps += 1
                }
                used.insert(code)
                table.append(code)
                entries.append(
                    PiniErrorCode(
                        typeName: type.name, caseName: caseName, code: code,
                        source: .hashed, location: type.location, probeSteps: steps))
            }
            byType[type.name] = table.first ?? ErrorCodeSpace.unclassified
            tables[type.name] = table
        }
        return HashedAllocation(entries: entries, tables: tables, byType: byType)
    }

    /// 三段拼贴：块名 · 类型名 · 用例名，以 U+0000 分隔。分隔符不能出现在标识符里，拼接才无歧义。
    /// 散列取 FNV-1a 64 位后对区间长度取模；只要三段名字不动，码就不动。
    public static func hashedCode(surface: String, type: String, case caseName: String) -> Int32 {
        let key = "\(surface)\u{0}\(type)\u{0}\(caseName)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return ErrorCodeSpace.hashedBase + Int32(hash % UInt64(ErrorCodeSpace.hashedSpan))
    }

    /// 散列区内顺延一格，越过上界回绕到起点。
    static func nextHashed(_ code: Int32) -> Int32 {
        let offset = code - ErrorCodeSpace.hashedBase
        return ErrorCodeSpace.hashedBase + (offset + 1) % ErrorCodeSpace.hashedSpan
    }

    // MARK: - 导出面

    /// 导出面可达的错误类型：`|c` 条目指向的自由函数，其返回位写明的 E。
    private static func reachableErrorTypes(
        in blocks: [ExportDecl], declarations: [TopLevelDecl]
    ) -> Set<String> {
        var reachable: Set<String> = []
        for block in blocks {
            for entry in block.entries where entry.target == .c {
                guard let function = freeFunction(named: entry.symbol, in: declarations),
                    let errorType = declaredErrorType(of: function)
                else { continue }
                reachable.insert(errorType)
            }
        }
        return reachable
    }

    /// `Result<T, E>` 写明就用 E；`^T`（只带 ok）视作 `Result<T, Error>`。非 Result 返回 nil。
    private static func declaredErrorType(of function: FuncDecl) -> String? {
        guard let declared = function.returnTypes.first else { return nil }
        guard case .generic(let name, let params, _) = declared, name == "Result" else { return nil }
        if params.count >= 2, case .simple(let errorName, _) = params[1] { return errorName }
        return "Error"
    }

    private static func freeFunction(named name: String, in declarations: [TopLevelDecl]) -> FuncDecl? {
        for declaration in declarations {
            if case .funcDecl(let function) = declaration, function.name == name { return function }
        }
        return nil
    }

    /// 作者写的固定码：扩展块里 `码()` 的函数体只有一条 `return <整数字面量>`。
    /// 写了却没写对时报出来， 行不通  不能当作未申报 —— 作者会以为码已固定，实际拿到的是自动码。
    private enum DeclaredCode {
        case absent
        case invalid(String)
        case value(Int32)
    }

    private static func declaredErrorCode(
        typeName: String, declarations: [TopLevelDecl]
    ) -> DeclaredCode {
        for decl in declarations {
            guard case .extensionDecl(let ext) = decl, ext.targetType == typeName else { continue }
            for method in ext.methods where method.name == "码" && method.params.isEmpty {
                guard let body = method.body else {
                    return .invalid("`码()` 需要函数体：一条 `return <整数字面量>`")
                }
                guard body.statements.count == 1,
                    case .returnStatement(.integerLiteral(let value, _), _) = body.statements[0]
                else {
                    return .invalid("`码()` 的函数体只能是一条 `return <整数字面量>`：表达式算不出稳定码")
                }
                guard value >= Int(ErrorCodeSpace.reservedBelow) else {
                    return .invalid("手写码 \(value) 与固定码相撞：0 是成功、1 未归类、2 取消，三者不可占用")
                }
                guard value <= Int(Int32.max) else {
                    return .invalid("手写码 \(value) 超出 i32 范围")
                }
                return .value(Int32(value))
            }
        }
        return .absent
    }
}

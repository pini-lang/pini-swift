import Foundation

/// 一个 C 产物文件。名字由发射器按程序名决定，目录由调用方决定 —— 发射器不认识路径。
public struct CFile: Equatable {
    public let name: String
    public let contents: String

    public init(name: String, contents: String) {
        self.name = name
        self.contents = contents
    }
}

/// C 后端的失败信号。遇到未支持的节点一律抛它，⛔ 不静默降级：
/// 降级产出的 C 能编译、能运行，只是算错，那是比编译失败昂贵得多的失败模式。
public struct CBackendError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// IRModule → C 源文件。控件流走 C 的结构化语句（IR 本身是语句树），
/// 只有带标签的跳出落到 `goto`；类型、打印与所有权规则逐条镜像 LLVM 发射器，
/// 两边的差异只能靠逐字节对比发现，故不在此处「顺手改进」。
public final class CEmitter {

    /// 程序基准，口径同 LLVM 侧：nil ⇒ 不注入 `bk_set_program_base`，产物不含该常量。
    public var programBase: String?

    public init() {}

    public func emit(module: IRModule, programName: String) throws -> [CFile] {
        let functions = module.functions.filter { $0.sourceFile != PredefinedDecls.sourceName }
        guard functions.contains(where: { $0.name == "main" }) else {
            throw CBackendError(message: "C 后端：模块里没有 main，无法产出可执行程序")
        }
        // 方法体只挂在 `IRTypeDecl.methods` 上，不在 `module.functions` 里 ——
        // 漏掉这一处，产物只剩调用没有定义，链接期才报未定义符号。
        var methods: [IRFunction] = []
        for decl in module.types { methods.append(contentsOf: decl.methods) }
        methods = methods.filter { $0.sourceFile != PredefinedDecls.sourceName }

        let scope = CModuleScope(module: module, defined: Set((functions + methods).map(\.name)))
        var bodies: [String] = []
        for function in functions {
            bodies.append(try CFunctionEmitter(function: function, scope: scope, programBase: programBase).emit())
        }
        for method in methods {
            bodies.append(try CFunctionEmitter(function: method, scope: scope, programBase: programBase).emit())
        }
        let unresolved = scope.calledNames.subtracting(scope.defined)
        guard unresolved.isEmpty else {
            let names = unresolved.sorted().joined(separator: "、")
            throw CBackendError(message: "C 后端尚未支持：这些被调函数不在本模块内 —— \(names)")
        }

        var out = "// 由 Pini 编译器生成，勿手改。\n"
        out += "#include \"\(PiniRTHeader.fileName)\"\n\n"
        out += scope.forwardDeclarations()
        out += try scope.aggregateDefinitions()
        out += try scope.layoutAssertions()
        out += scope.copyFunctionDeclarations()
        out += scope.copyFunctionDefinitions()
        for constant in scope.constants {
            out += "static const char \(constant.name)[] = \(Self.cLiteral(constant.value));\n"
        }
        out += "\n"
        var prototypes = ""
        for function in functions + methods where function.name != "main" {
            prototypes += try CFunctionEmitter.prototype(of: function) + ";\n"
        }
        out += prototypes
        out += "\n"
        out += bodies.joined(separator: "\n")
        return [CFile(name: "\(programName).c", contents: out)]
    }

    /// C 字符串字面量。非 ASCII 原样输出（C23 源文件是 UTF-8），控制字符走三位八进制 ——
    /// 十六进制转义会吃掉紧随其后的十六进制数字，八进制定长不吃。
    static func cLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// 模块级共享状态：类型表、常量池、被调名账本，以及按需合成的拷贝函数。
/// 常量按需登记 —— 预扫全模块会把只在被剪掉的函数里出现的字符串也写进产物。
final class CModuleScope {
    let types: [IRTypeDecl]
    let enums: [IREnumDecl]
    let defined: Set<String>
    /// 类型标识：结构按声明序 1 起，枚举接在结构之后 —— 与 LLVM 侧同一套编号，
    /// 差一位就是两个通道写进对象头的 id 不同。
    private let structIDs: [String: Int32]
    private let enumIDs: [String: Int32]

    private var stringsByValue: [String: String] = [:]
    private(set) var constants: [(name: String, value: String)] = []
    var calledNames: Set<String> = []

    /// LLVM 头里以裸名 declare、由 libc / libm 提供的那些符号。⛔ 不按「不在本模块 ⇒ 外部」
    /// 推断：那会把真用户函数也当外部符号放过，错到链接期才现形。
    static let libcFunctions: Set<String> = [
        "printf", "sqrt", "free", "strlen", "strcat", "strcpy", "memcpy",
        "strtok", "strstr", "toupper", "tolower", "snprintf", "malloc",
    ]

    /// LLVM 内建在 C 侧的同义函数。
    static let intrinsicAliases: [String: String] = [
        "llvm.sin.f64": "sin", "llvm.cos.f64": "cos",
    ]

    /// 需要完整定义的聚合体（产物里真的读写了字段的那些），按登记序。
    private(set) var usedAggregates: [String] = []
    private var usedSet: Set<String> = []
    private var copySymbols: Set<String> = []
    private(set) var copyBodies: [(symbol: String, aggregate: String, source: String)] = []

    init(module: IRModule, defined: Set<String>) {
        self.types = module.types
        self.enums = module.enums
        self.defined = defined
        var ids: [String: Int32] = [:]
        for (index, decl) in module.types.enumerated() { ids[decl.name] = Int32(index + 1) }
        structIDs = ids
        var enumTable: [String: Int32] = [:]
        for (index, decl) in module.enums.enumerated() {
            enumTable[decl.name] = Int32(module.types.count + index + 1)
        }
        enumIDs = enumTable
    }

    func registerString(_ value: String) -> String {
        if let hit = stringsByValue[value] { return hit }
        let name = "k_str\(constants.count)"
        stringsByValue[value] = name
        constants.append((name: name, value: value))
        return name
    }

    func typeDecl(named name: String) -> IRTypeDecl? { types.first { $0.name == name } }

    func enumDecl(named name: String) -> IREnumDecl? { enums.first { $0.name == name } }

    func typeID(of type: IRType) -> Int32 {
        switch type {
        case .nominal(let name, _): return structIDs[name] ?? 0
        case .enumeration(let name): return enumIDs[name] ?? 0
        default: return 0
        }
    }

    /// 登记「这个聚合体的字段真的被读写了」。结构体的字段类型若是另一个聚合体，
    /// 那个也得有完整定义 —— 否则它的字段在 C 里是不可访问的不完整类型。
    func markUsed(_ name: String) {
        guard usedSet.insert(name).inserted else { return }
        usedAggregates.append(name)
        guard let decl = typeDecl(named: name) else { return }
        for field in decl.fields {
            if let sub = Self.aggregateName(of: field.type) { markUsed(sub) }
        }
    }

    static func aggregateName(of type: IRType) -> String? {
        switch type {
        case .nominal(let name, _), .enumeration(let name): return name
        default: return nil
        }
    }

    func reserveCopySymbol(_ symbol: String) -> Bool {
        copySymbols.insert(symbol).inserted
    }

    func appendCopyBody(symbol: String, aggregate: String, source: String) {
        copyBodies.append((symbol, aggregate, source))
    }

    /// 全部聚合体的前向声明。⛔ 顺序无关紧要：名义字段一律是指针，
    /// 完整定义可以出现在使用点之后。
    func forwardDeclarations() -> String {
        var out = ""
        for decl in types {
            let name = CTypeMap.aggregateName(decl.name)
            out += "typedef struct \(name) \(name);\n"
        }
        for decl in enums {
            let name = CTypeMap.aggregateName(decl.name)
            out += "typedef struct \(name) \(name);\n"
        }
        return out.isEmpty ? "" : out + "\n"
    }

    func aggregateDefinitions() throws -> String {
        var out = ""
        for name in usedAggregates {
            if let decl = typeDecl(named: name) {
                out += try definition(of: decl)
            } else if let decl = enumDecl(named: name) {
                out += try definition(of: decl)
            }
        }
        return out.isEmpty ? "" : out + "\n"
    }

    private func definition(of decl: IRTypeDecl) throws -> String {
        let aggregate = CTypeMap.aggregateName(decl.name)
        var out = "struct \(aggregate) {\n"
        out += "    PiniHeader hdr;\n"
        for (index, field) in decl.fields.enumerated() {
            out += "    \(try CTypeMap.spelling(of: field.type)) f\(index);  // \(field.name)\n"
        }
        return out + "};\n"
    }

    private func definition(of decl: IREnumDecl) throws -> String {
        let aggregate = CTypeMap.aggregateName(decl.name)
        var out = "struct \(aggregate) {\n"
        out += "    PiniHeader hdr;\n"
        out += "    int32_t tag;\n"
        for (index, slot) in decl.slotTypes.enumerated() {
            out += "    \(try CTypeMap.spelling(of: slot)) f\(index);\n"
        }
        return out + "};\n"
    }

    /// 逐类型的布局判据：发射层算出的偏移与总字节数写成常量，C 侧 `sizeof` / `offsetof` 对不上就编译失败。
    /// ⛔ 这一条是名义类型期唯一能把「字段顺序或宽度漂了」挡在产物之外的机制。
    func layoutAssertions() throws -> String {
        var out = ""
        for name in usedAggregates {
            let aggregate = CTypeMap.aggregateName(name)
            if let decl = typeDecl(named: name) {
                let layout = try CLayout.structure(decl)
                out += "_Static_assert(sizeof(\(aggregate)) == \(layout.size), \"布局漂移：\(aggregate)\");\n"
                for (index, offset) in layout.fieldOffsets.enumerated() {
                    out +=
                        "_Static_assert(offsetof(\(aggregate), f\(index)) == \(offset),"
                        + " \"布局漂移：\(aggregate).f\(index)\");\n"
                }
            } else if let decl = enumDecl(named: name) {
                let layout = try CLayout.enumeration(decl)
                out += "_Static_assert(sizeof(\(aggregate)) == \(layout.size), \"布局漂移：\(aggregate)\");\n"
                out += "_Static_assert(offsetof(\(aggregate), tag) == \(layout.tagOffset), \"布局漂移：\(aggregate).tag\");\n"
                for (index, offset) in layout.slotOffsets.enumerated() {
                    out +=
                        "_Static_assert(offsetof(\(aggregate), f\(index)) == \(offset),"
                        + " \"布局漂移：\(aggregate).f\(index)\");\n"
                }
            }
        }
        return out.isEmpty ? "" : out + "\n"
    }

    func copyFunctionDeclarations() -> String {
        guard !copyBodies.isEmpty else { return "" }
        var out = ""
        for entry in copyBodies {
            out += "static \(entry.aggregate) *\(entry.symbol)(\(entry.aggregate) *src);\n"
        }
        return out + "\n"
    }

    func copyFunctionDefinitions() -> String {
        guard !copyBodies.isEmpty else { return "" }
        return copyBodies.map(\.source).joined(separator: "\n") + "\n\n"
    }
}

/// 名义聚合体的 C 布局模型：按 ABI 的对齐规则推偏移，供 `_Static_assert` 比对。
/// 只覆盖生成器会用到的类型 —— 表外的类型抛错，⛔ 不猜一个宽度。
enum CLayout {
    static let headerSize = 24
    static let headerAlign = 8

    static func size(of type: IRType) throws -> (size: Int, align: Int) {
        switch type {
        case .boolean, .i8, .u8: return (1, 1)
        case .i32: return (4, 4)
        case .i64, .u64, .f64: return (8, 8)
        case .string, .char, .nominal, .enumeration: return (8, 8)
        default: throw CBackendError(message: "C 后端尚未支持的类型布局：\(CTypeMap.label(of: type))")
        }
    }

    static func structure(_ decl: IRTypeDecl) throws -> (size: Int, fieldOffsets: [Int]) {
        var offset = headerSize
        var maxAlign = headerAlign
        var offsets: [Int] = []
        for field in decl.fields {
            let (size, align) = try size(of: field.type)
            offset = roundUp(offset, align)
            offsets.append(offset)
            offset += size
            maxAlign = max(maxAlign, align)
        }
        return (roundUp(offset, maxAlign), offsets)
    }

    static func enumeration(_ decl: IREnumDecl) throws -> (size: Int, tagOffset: Int, slotOffsets: [Int]) {
        var offset = headerSize
        var maxAlign = headerAlign
        let tagOffset = roundUp(offset, 4)
        offset = tagOffset + 4
        var offsets: [Int] = []
        for slot in decl.slotTypes {
            let (size, align) = try size(of: slot)
            offset = roundUp(offset, align)
            offsets.append(offset)
            offset += size
            maxAlign = max(maxAlign, align)
        }
        return (roundUp(offset, maxAlign), tagOffset, offsets)
    }

    private static func roundUp(_ value: Int, _ align: Int) -> Int {
        guard align > 1 else { return value }
        return (value + align - 1) / align * align
    }
}

/// 单个函数的发射器。帧栈记的是「谁可以被 break / continue 指向」——
/// 带标签的 `if` 也是帧（`break 标签` 能跳出它），故不能只压循环。
final class CFunctionEmitter {
    private let function: IRFunction
    private let scope: CModuleScope
    private let programBase: String?
    private let writer = CWriter()
    private var frames: [Frame] = []
    private var labelSeq = 0
    private var tempSeq = 0
    private var terminated = false

    private struct Frame {
        let exit: String
        let header: String
        let isLoop: Bool
        let needsExit: Bool
        let needsHeader: Bool
    }

    init(function: IRFunction, scope: CModuleScope, programBase: String?) {
        self.function = function
        self.scope = scope
        self.programBase = programBase
    }

    private var isMain: Bool { function.name == "main" }

    func emit() throws -> String {
        writer.open(try signature())
        if isMain, let base = programBase {
            let constant = scope.registerString(base)
            writer.line("bk_set_program_base((void *)\(constant));")
        }
        try emitBlock(function.body)
        if !terminated {
            if isMain {
                writer.line("return 0;")
            } else if let returnType = function.returnType {
                writer.line("return \(try CTypeMap.zeroLiteral(of: returnType));")
            }
        }
        writer.close()
        return writer.output
    }

    static func prototype(of function: IRFunction) throws -> String {
        let name = "pini_\(IRName.mangle(function.name))"
        let ret = try function.returnType.map { try CTypeMap.spelling(of: $0) } ?? "void"
        let params = try function.params.map {
            "\(try CTypeMap.spelling(of: $0.type)) v_\(IRName.mangle($0.name))"
        }.joined(separator: ", ")
        return "static \(ret) \(name)(\(params.isEmpty ? "void" : params))"
    }

    private func signature() throws -> String {
        if isMain { return "int main(void)" }
        return try Self.prototype(of: function)
    }

    // MARK: - 语句

    private func emitBlock(_ block: IRBlock) throws {
        for statement in block.statements {
            try emitStmt(statement)
        }
    }

    private func emitStmt(_ statement: IRStmt) throws {
        switch statement {
        case .allocVar(let name, let type, _, let initializer):
            let spelling = try CTypeMap.spelling(of: type)
            let local = "v_\(IRName.mangle(name))"
            if let initializer {
                let value = try emitExpr(initializer)
                let stored = try emitValueForStorage(initializer, value, type: type)
                writer.line("\(spelling) \(local) = \(stored);")
            } else {
                writer.line("\(spelling) \(local);")
            }
            terminated = false

        case .storeVar(let name, let type, let value):
            let lowered = try emitExpr(value)
            let stored = try emitValueForStorage(value, lowered, type: type)
            writer.line("v_\(IRName.mangle(name)) = \(stored);")
            terminated = false

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            try emitIf(label: label, condition: condition, thenBody: thenBody, elseBody: elseBody)

        case .whileStmt(let condition, let body, let step):
            guard step == nil else {
                throw CBackendError(message: "C 后端尚未支持：带 step 块的 while")
            }
            try emitWhile(condition: condition, body: body)

        case .forInStmt:
            throw CBackendError(message: "C 后端尚未支持：for-in（需要容器运行时段）")

        case .returnStmt(let value):
            if let value {
                let lowered = try emitExpr(value)
                // 与 LLVM 侧同规：交出去的值先按值语义落定（结构体别名拷新箱），再 ret。
                let stored = try function.returnType.map {
                    try emitValueForStorage(value, lowered, type: $0)
                } ?? lowered
                writer.line("return \(stored);")
            } else if isMain {
                writer.line("return 0;")
            } else {
                writer.line("return;")
            }
            terminated = true

        case .exprStmt(let expr):
            let text = try emitExpr(expr)
            if !text.isEmpty { writer.line("\(text);") }
            terminated = false

        case .panicStmt(let message):
            let constant = scope.registerString(message)
            writer.line("bk_panic(\(constant));")
            terminated = true

        case .matchStmt(let scrutinee, let cases, let scrutineeType):
            try emitMatch(scrutinee: scrutinee, cases: cases, scrutineeType: scrutineeType)

        case .fieldStore(let base, let field, let value, let fieldType):
            let baseText = try emitExpr(base)
            let access = try fieldAccess(base: base, field: field, baseText: baseText)
            let lowered = try emitExpr(value)
            let stored = try emitValueForStorage(value, lowered, type: fieldType)
            writer.line("\(access) = \(stored);")
            terminated = false

        case .breakStmt(let depth):
            let frame = try frame(at: depth)
            if frame.isLoop && depth == 1 {
                writer.line("break;")
            } else if frame.needsExit {
                writer.line("goto \(frame.exit);")
            } else {
                throw CBackendError(message: "C 后端：break 的目标帧未落标号，扫描与发射不一致")
            }
            terminated = true

        case .continueStmt(let depth):
            let frame = try frame(at: depth)
            if frame.isLoop && depth == 1 {
                writer.line("continue;")
            } else if frame.isLoop && frame.needsHeader {
                writer.line("goto \(frame.header);")
            } else if !frame.isLoop && frame.needsExit {
                writer.line("goto \(frame.exit);")
            } else {
                throw CBackendError(message: "C 后端：continue 的目标帧未落标号，扫描与发射不一致")
            }
            terminated = true

        default:
            throw CBackendError(message: "C 后端尚未支持的语句：\(Self.nodeName(statement))")
        }
    }

    private func emitIf(
        label: String?, condition: IRExpr, thenBody: IRBlock, elseBody: IRBlock?
    ) throws {
        let cond = bareCondition(try emitExpr(condition))
        var frame: Frame?
        if label != nil {
            let exit = "end_if_\(nextLabelSeq())"
            let needsExit =
                scan(thenBody, nesting: 0, direct: true).brk
                || scan(elseBody, nesting: 0, direct: true).brk
            let pushed = Frame(
                exit: exit, header: exit, isLoop: false, needsExit: needsExit, needsHeader: false)
            frames.append(pushed)
            frame = pushed
        }
        writer.open("if (\(cond))")
        try emitBlock(thenBody)
        if let elseBody {
            writer.elseOpen()
            try emitBlock(elseBody)
            writer.close()
        } else {
            writer.close()
        }
        if let frame {
            frames.removeLast()
            if frame.needsExit { writer.line("\(frame.exit): ;") }
        }
        terminated = false
    }

    /// `while cond: body`。无标号需求时原样落 `while`，产物最好读；
    /// 一旦有内层 `break`/`continue` 指向它，就换成 `for (;;)`,以便开出显式标号 ——
    /// C 没有给条件挂标号的语法，`continue 标签` 要靠 `goto` 回到循环头。
    private func emitWhile(condition: IRExpr, body: IRBlock) throws {
        let info = scan(body, nesting: 0, direct: false)
        let id = nextLabelSeq()
        let exit = "end_\(id)"
        let header = "cont_\(id)"
        frames.append(
            Frame(
                exit: exit, header: header, isLoop: true,
                needsExit: info.brk, needsHeader: info.cont))
        let cond = bareCondition(try emitExpr(condition))
        if info.cont {
            writer.open("for (;;)")
            writer.line("\(header): ;")
            writer.line("if (!(\(cond))) break;")
        } else if info.brk {
            writer.open("for (;;)")
            writer.line("if (!(\(cond))) break;")
        } else {
            writer.open("while (\(cond))")
        }
        try emitBlock(body)
        writer.close()
        frames.removeLast()
        if info.brk { writer.line("\(exit): ;") }
        terminated = false
    }

    /// `match`：枚举按标签派发。⛔ 不用 `switch` —— 臂里的 `break` 在 C 里会绑到 `switch` 上，
    /// 而 Pini 的 `break` 指的是外层循环；`if` 链没有这个问题，也与 LLVM 侧的标签链同构。
    private func emitMatch(scrutinee: IRExpr, cases: [IRMatchCase], scrutineeType: IRType) throws {
        guard case .enumeration(let name) = scrutineeType, let decl = scope.enumDecl(named: name) else {
            throw CBackendError(
                message: "C 后端尚未支持的匹配对象类型：\(CTypeMap.label(of: scrutineeType))")
        }
        scope.markUsed(name)
        let pointer = try materialize(try emitExpr(scrutinee), type: scrutineeType)
        let tag = "t_\(nextTempSeq())"
        writer.line("int32_t \(tag) = \(pointer)->tag;")
        let panicMessage = scope.registerString("Pini runtime error: match value matched no case")

        var isFirst = true
        var hasWildcard = false
        for arm in cases {
            if arm.caseName == "_" {
                hasWildcard = true
                if isFirst { writer.open("if (1)") } else { writer.elseOpen() }
            } else {
                guard let enumCase = decl.cases.first(where: { $0.name == arm.caseName }) else {
                    throw CBackendError(message: "C 后端：匹配臂 '\(arm.caseName)' 不在枚举 \(name) 里")
                }
                let condition = "\(tag) == \(enumCase.tag)"
                if isFirst { writer.open("if (\(condition))") } else { writer.elseIfOpen(condition) }
                try emitBindings(arm: arm, enumCase: enumCase, decl: decl, pointer: pointer, enumName: name)
            }
            try emitBlock(arm.body)
            isFirst = false
        }
        if !hasWildcard {
            if isFirst { writer.open("if (1)") } else { writer.elseOpen() }
            writer.line("bk_panic(\(panicMessage));")
        }
        writer.close()
        terminated = false
    }

    private func emitBindings(
        arm: IRMatchCase, enumCase: IREnumCase, decl: IREnumDecl, pointer: String, enumName: String
    ) throws {
        for (slot, binding) in arm.bindings.enumerated() {
            guard let binding else { continue }
            guard slot < enumCase.payloadTypes.count else {
                throw CBackendError(
                    message: "C 后端：匹配臂 '\(arm.caseName)' 的绑定数超过其载荷数")
            }
            let type = enumCase.payloadTypes[slot]
            try checkSlotType(type, slot: slot, decl: decl, owner: "枚举 \(enumName) 的用例 \(enumCase.name)")
            writer.line(
                "\(try CTypeMap.spelling(of: type)) v_\(IRName.mangle(binding)) = \(pointer)->f\(slot);")
        }
    }

    /// 载荷槽在聚合体里只有一个静态类型（取最大元数用例的那份）。用例声明的载荷类型与它不同时
    /// fail loud：C 的赋值会静默截断或重解释，而 LLVM 侧只是读同一段字节。
    private func checkSlotType(_ type: IRType, slot: Int, decl: IREnumDecl, owner: String) throws {
        guard slot < decl.slotTypes.count else {
            throw CBackendError(message: "C 后端：\(owner) 的载荷槽 \(slot) 超出聚合体槽数")
        }
        guard decl.slotTypes[slot].llvmSpelling == type.llvmSpelling else {
            throw CBackendError(
                message: "C 后端尚未支持：\(owner) 的载荷槽 \(slot) 类型与聚合体槽位不一致"
                    + "（\(CTypeMap.label(of: type)) vs \(CTypeMap.label(of: decl.slotTypes[slot]))）")
        }
    }

    // MARK: - 表达式

    /// 返回 C 表达式文本。打印一类会写多条语句的节点返回空串，调用方据此判断是否加 `;`。
    private func emitExpr(_ expr: IRExpr) throws -> String {
        switch expr {
        case .intConst(let value, let type):
            return try CTypeMap.integerLiteral(value, type: type)

        case .floatConst(let value):
            return try CTypeMap.floatLiteral(value)

        case .boolConst(let value):
            return value ? "true" : "false"

        case .stringConst(let value):
            return scope.registerString(value)

        case .load(let name, _):
            return "v_\(IRName.mangle(name))"

        case .binary(let op, let lhs, let rhs, _):
            let left = try emitExpr(lhs)
            let right = try emitExpr(rhs)
            guard let spelling = Self.binarySpelling(op) else {
                throw CBackendError(message: "C 后端尚未支持的二元运算：\(op)")
            }
            return "((\(left)) \(spelling) (\(right)))"

        case .unary(let op, let operand, _):
            let value = try emitExpr(operand)
            switch op {
            case .negate: return "(-(\(value)))"
            case .logicalNot: return "(!(\(value)))"
            case .bitwiseNot: return "(~(\(value)))"
            case .abs:
                throw CBackendError(message: "C 后端尚未支持的一元运算：abs")
            }

        case .call(let name, let arguments, _):
            let args = try arguments.map { try emitExpr($0) }
            if name == "F64", args.count == 1 {
                return "((double)(\(args[0])))"
            }
            if let alias = CModuleScope.intrinsicAliases[name] {
                return "\(alias)(\(args.joined(separator: ", ")))"
            }
            let callee: String
            if scope.defined.contains(name) {
                callee = "pini_\(IRName.mangle(name))"
            } else if name.hasPrefix("bk_") || CModuleScope.libcFunctions.contains(name) {
                callee = name
            } else {
                callee = "pini_\(IRName.mangle(name))"
                scope.calledNames.insert(name)
            }
            return "\(callee)(\(args.joined(separator: ", ")))"

        case .construct(let type):
            return try emitConstruct(type)

        case .fieldGet(let base, let field, _):
            let baseText = try emitExpr(base)
            return try fieldAccess(base: base, field: field, baseText: baseText)

        case .enumConstruct(let enumName, _, let tag, let payloads, let payloadTypes, let type):
            return try emitEnumConstruct(
                enumName: enumName, tag: tag, payloads: payloads,
                payloadTypes: payloadTypes, type: type)

        case .assertCall(let condition, let message):
            let cond = try emitExpr(condition)
            let text = try message.map { try emitExpr($0) } ?? scope.registerString("assert failed")
            writer.open("if (!(\(cond)))")
            writer.line("printf(\"%s\", \(text));")
            writer.line("printf(\"\\n\");")
            writer.line("bk_panic(NULL);")
            writer.close()
            return ""

        case .printCall(let argument):
            try emitPrint(argument, newline: true)
            return ""

        case .printMulti(let arguments):
            try emitPrintMulti(arguments)
            return ""

        default:
            throw CBackendError(message: "C 后端尚未支持的表达式：\(Self.nodeName(expr))")
        }
    }

    /// 名义箱的构造：分配器写四格头，随后逐字段落初值（无默认值时落零）。
    /// ⛔ 与 LLVM 侧同规：默认值直接落槽，不经过 `emitValueForStorage` —— 那边也没绕。
    private func emitConstruct(_ type: IRType) throws -> String {
        guard case .nominal(let name, _) = type, let decl = scope.typeDecl(named: name) else {
            throw CBackendError(message: "C 后端：构造了未声明的名义类型 \(CTypeMap.label(of: type))")
        }
        scope.markUsed(name)
        let aggregate = CTypeMap.aggregateName(name)
        let temp = "t_\(nextTempSeq())"
        writer.line(
            "\(aggregate) *\(temp) = bk_nominal_alloc(sizeof(\(aggregate)), \(scope.typeID(of: type)));")
        for (index, field) in decl.fields.enumerated() {
            let value: String
            if let defaultValue = field.defaultValue {
                value = try emitExpr(defaultValue)
            } else {
                value = try CTypeMap.zeroLiteral(of: field.type)
            }
            writer.line("\(temp)->f\(index) = \(value);")
        }
        return temp
    }

    private func emitEnumConstruct(
        enumName: String, tag: Int, payloads: [IRExpr], payloadTypes: [IRType], type: IRType
    ) throws -> String {
        guard let decl = scope.enumDecl(named: enumName) else {
            throw CBackendError(message: "C 后端：构造了未声明的枚举 \(enumName)")
        }
        scope.markUsed(enumName)
        let aggregate = CTypeMap.aggregateName(enumName)
        let temp = "t_\(nextTempSeq())"
        writer.line(
            "\(aggregate) *\(temp) = bk_nominal_alloc(sizeof(\(aggregate)), \(scope.typeID(of: type)));")
        writer.line("\(temp)->tag = \(tag);")
        for (index, payload) in payloads.enumerated() {
            try checkSlotType(payloadTypes[index], slot: index, decl: decl, owner: "枚举 \(enumName)")
            let lowered = try emitExpr(payload)
            let stored = try emitValueForStorage(payload, lowered, type: payloadTypes[index])
            writer.line("\(temp)->f\(index) = \(stored);")
        }
        return temp
    }

    /// 字段访问。类型从 base 的 IR 类型问出来，字段序号按声明序 —— 与 LLVM 侧的 GEP 同一偏置。
    private func fieldAccess(base: IRExpr, field: String, baseText: String) throws -> String {
        guard let baseType = Self.type(of: base) else {
            throw CBackendError(message: "C 后端：字段访问的基址没有携带类型，无法定位字段")
        }
        switch baseType {
        case .nominal(let name, _):
            guard let decl = scope.typeDecl(named: name),
                let index = decl.fields.firstIndex(where: { $0.name == field })
            else {
                throw CBackendError(message: "C 后端：类型 \(name) 没有字段 \(field)")
            }
            scope.markUsed(name)
            return "((\(baseText))->f\(index))"
        default:
            throw CBackendError(
                message: "C 后端尚未支持的字段访问基址类型：\(CTypeMap.label(of: baseType))")
        }
    }

    /// 逐类型镜像 `IREmitter.emitScalarPrint` / `emitValuePrint`。两处必须逐字一致，
    /// 包括那两处看起来像缺陷的地方：`I64` 打印按 `%d` 收窄到 i32，`F64` 走运行时渲染再 `printf("%s")`。
    private func emitValuePrint(_ text: String, type: IRType) throws {
        switch type {
        case .boolean:
            writer.line("printf(\"%s\", (\(text)) ? \"true\" : \"false\");")
        case .string, .char:
            writer.line("printf(\"%s\", \(text));")
        case .i32:
            writer.line("printf(\"%d\", \(text));")
        case .i8:
            writer.line("printf(\"%d\", (int32_t)(int8_t)(\(text)));")
        case .u8:
            writer.line("printf(\"%d\", (int32_t)(int8_t)(\(text)));")
        case .i64, .u64:
            writer.line("printf(\"%d\", (int32_t)(\(text)));")
        case .f64:
            let temp = "t_text\(nextTempSeq())"
            writer.line("char *\(temp) = bk_double_to_string(\(text));")
            writer.line("printf(\"%s\", \(temp));")
            writer.line("bk_str_release(\(temp));")
        case .nominal(let name, _):
            try emitAggregatePrint(try materialize(text, type: type), name: name)
        case .enumeration(let name):
            try emitEnumPrint(try materialize(text, type: type), name: name)
        default:
            throw CBackendError(message: "C 后端尚未支持的打印类型：\(CTypeMap.label(of: type))")
        }
    }

    /// `Name{field: value, ...}`，字段按名字排序 —— 与解释器的 stringify 同序。
    private func emitAggregatePrint(_ pointer: String, name: String) throws {
        guard let decl = scope.typeDecl(named: name) else {
            throw CBackendError(message: "C 后端：打印了未声明的名义类型 \(name)")
        }
        scope.markUsed(name)
        writer.line("printf(\"%s\", \(scope.registerString(name + "{")));")
        let ordered = decl.fields.enumerated().sorted { $0.element.name < $1.element.name }
        for (position, entry) in ordered.enumerated() {
            if position > 0 { writer.line("printf(\"%s\", \(scope.registerString(", ")));") }
            writer.line("printf(\"%s\", \(scope.registerString("\(entry.element.name): ")));")
            try emitValuePrint("\(pointer)->f\(entry.offset)", type: entry.element.type)
        }
        writer.line("printf(\"%s\", \(scope.registerString("}")));")
    }

    /// `caseName(p1, p2)` / `caseName` —— 标签派发，载荷按声明的类型递归打印。
    private func emitEnumPrint(_ pointer: String, name: String) throws {
        guard let decl = scope.enumDecl(named: name) else {
            throw CBackendError(message: "C 后端：打印了未声明的枚举 \(name)")
        }
        scope.markUsed(name)
        let tag = "t_\(nextTempSeq())"
        writer.line("int32_t \(tag) = \(pointer)->tag;")
        if decl.cases.isEmpty {
            writer.line(
                "bk_panic(\(scope.registerString("Pini runtime error: enum value has unknown tag")));")
            return
        }
        for (index, enumCase) in decl.cases.enumerated() {
            let condition = "\(tag) == \(enumCase.tag)"
            if index == 0 { writer.open("if (\(condition))") } else { writer.elseIfOpen(condition) }
            if enumCase.payloadTypes.isEmpty {
                writer.line("printf(\"%s\", \(scope.registerString(enumCase.name)));")
            } else {
                writer.line("printf(\"%s\", \(scope.registerString(enumCase.name + "(")));")
                for (slot, payloadType) in enumCase.payloadTypes.enumerated() {
                    if slot > 0 { writer.line("printf(\"%s\", \(scope.registerString(", ")));") }
                    try emitValuePrint("\(pointer)->f\(slot)", type: payloadType)
                }
                writer.line("printf(\"%s\", \(scope.registerString(")")));")
            }
        }
        writer.elseOpen()
        writer.line("bk_panic(\(scope.registerString("Pini runtime error: enum value has unknown tag")));")
        writer.close()
    }

    private func emitPrint(_ argument: IRExpr, newline: Bool) throws {
        let text = try emitExpr(argument)
        guard let type = Self.type(of: argument) else {
            throw CBackendError(message: "C 后端：打印的实参没有携带类型，无法选定格式")
        }
        try emitValuePrint(text, type: type)
        if newline { writer.line("printf(\"\\n\");") }
    }

    /// `print(a, b, c)`：实参之间一个空格，行尾一个换行。与 LLVM 侧同序。
    private func emitPrintMulti(_ arguments: [IRExpr]) throws {
        for (index, argument) in arguments.enumerated() {
            if index > 0 { writer.line("printf(\" \");") }
            try emitPrint(argument, newline: false)
        }
        writer.line("printf(\"\\n\");")
    }

    /// 把值落到一个临时变量里再返回它的名字。聚合值要读多个字段，直接内联实参文本会把
    /// 带副作用的表达式求值多次 —— LLVM 侧只求值一次。
    private func materialize(_ text: String, type: IRType) throws -> String {
        let temp = "t_\(nextTempSeq())"
        writer.line("\(try CTypeMap.spelling(of: type)) \(temp) = \(text);")
        return temp
    }

    // MARK: - 所有权镜像

    /// 该表达式节点给的是已有箱的别名（结构体要按值拷贝），还是一个新箱的所有权（直接接管）。
    private static func yieldsAlias(_ node: IRExpr) -> Bool {
        switch node {
        case .load, .fieldGet: return true
        default: return false
        }
    }

    /// 把求值出来的值按值语义落到一个持有位置：结构体别名拷出新箱，其余直接接管。
    /// 释放胶水不在本期 —— 名义箱只分配不回收，这条差异不影响输出字节，但会漏内存。
    private func emitValueForStorage(_ node: IRExpr, _ text: String, type: IRType) throws -> String {
        guard Self.yieldsAlias(node) else { return text }
        guard case .nominal(let name, let isObject) = type, !isObject else { return text }
        guard let symbol = try copyFunction(for: type) else { return text }
        let aggregate = CTypeMap.aggregateName(name)
        let temp = "t_\(nextTempSeq())"
        writer.line("\(aggregate) *\(temp) = \(symbol)(\(text));")
        return temp
    }

    /// 结构体的逐类型拷贝胶水：新箱 + 逐字段搬（嵌套结构体递归拷，其余共享指针）。
    /// 与 LLVM 侧的 `__copy_struct_*` 同形；缺了它，`var b = a` 之后改 `b` 会连 `a` 一起改。
    private func copyFunction(for type: IRType) throws -> String? {
        guard case .nominal(let name, let isObject) = type, !isObject else { return nil }
        guard let decl = scope.typeDecl(named: name) else {
            throw CBackendError(message: "C 后端：为未声明的结构体合成拷贝函数 \(name)")
        }
        let symbol = "pini_copy_\(IRName.mangle(name))"
        guard scope.reserveCopySymbol(symbol) else { return symbol }
        scope.markUsed(name)
        let aggregate = CTypeMap.aggregateName(name)
        var lines: [String] = []
        lines.append("static \(aggregate) *\(symbol)(\(aggregate) *src) {")
        lines.append("    if (src == NULL) { return NULL; }")
        lines.append(
            "    \(aggregate) *dst = bk_nominal_alloc(sizeof(\(aggregate)), \(scope.typeID(of: type)));")
        for (index, field) in decl.fields.enumerated() {
            if case .nominal(_, false) = field.type, let sub = try copyFunction(for: field.type) {
                lines.append("    dst->f\(index) = \(sub)(src->f\(index));")
            } else {
                lines.append("    dst->f\(index) = src->f\(index);")
            }
        }
        lines.append("    return dst;")
        lines.append("}")
        scope.appendCopyBody(symbol: symbol, aggregate: aggregate, source: lines.joined(separator: "\n"))
        return symbol
    }

    // MARK: - 辅助

    private func frame(at depth: Int) throws -> Frame {
        guard depth >= 1, depth <= frames.count else {
            throw CBackendError(message: "C 后端：break/continue 的层数 \(depth) 超出帧栈")
        }
        return frames[frames.count - depth]
    }

    private func nextLabelSeq() -> Int {
        labelSeq += 1
        return labelSeq
    }

    private func nextTempSeq() -> Int {
        tempSeq += 1
        return tempSeq
    }

    /// 求「本帧是否被更内层的 break / continue 指名」：`depth == nesting + 1` 即指向本帧，
    /// 未加标签的 `if` 不压帧、故不改 `nesting`。`direct` 决定 nesting 为 0 的命中算不算数 ——
    /// 循环在那一层用 C 的 `break` / `continue`，不需要标号；`if` 帧只能走 `goto`。
    private func scan(_ block: IRBlock?, nesting: Int, direct: Bool) -> (brk: Bool, cont: Bool) {
        guard let block else { return (false, false) }
        func hits(_ depth: Int) -> Bool {
            depth == nesting + 1 && (nesting > 0 || direct)
        }
        var brk = false
        var cont = false
        for statement in block.statements {
            switch statement {
            case .breakStmt(let depth):
                if hits(depth) { brk = true }
            case .continueStmt(let depth):
                if hits(depth) { cont = true }
            case .whileStmt(_, let body, let step):
                let inner = scan(body, nesting: nesting + 1, direct: direct)
                brk = brk || inner.brk
                cont = cont || inner.cont
                let stepped = scan(step, nesting: nesting + 1, direct: direct)
                brk = brk || stepped.brk
                cont = cont || stepped.cont
            case .forInStmt(_, _, _, _, let body, let step):
                let inner = scan(body, nesting: nesting + 1, direct: direct)
                brk = brk || inner.brk
                cont = cont || inner.cont
                let stepped = scan(step, nesting: nesting + 1, direct: direct)
                brk = brk || stepped.brk
                cont = cont || stepped.cont
            case .ifStmt(let label, _, let thenBody, let elseBody):
                let inner = nesting + (label == nil ? 0 : 1)
                let a = scan(thenBody, nesting: inner, direct: direct)
                let b = scan(elseBody, nesting: inner, direct: direct)
                brk = brk || a.brk || b.brk
                cont = cont || a.cont || b.cont
            default:
                break
            }
        }
        return (brk, cont)
    }

    /// 条件已整体加过括号时去掉一层，避免 `while (((a) < (b)))` 这种三重括号。
    /// 本发射器产出的复合表达式一律整包，故「首尾都是括号」即表示整包，不会误伤 `f(x)`。
    private func bareCondition(_ text: String) -> String {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func binarySpelling(_ op: IRBinaryOp) -> String? {
        switch op {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .modulo: return "%"
        case .equal: return "=="
        case .notEqual: return "!="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .bitwiseAnd: return "&"
        case .bitwiseOr: return "|"
        case .bitwiseXor: return "^"
        case .leftShift: return "<<"
        case .rightShift: return ">>"
        case .minOf, .maxOf: return nil
        }
    }

    /// 表达式自带的类型。返回 nil 表示该节点不在当前的表达式面内 ——
    /// ⛔ 不退化成 `I32`：那会让一个聚合值按整数打出来，编得过、跑得通、结果是错的。
    static func type(of expr: IRExpr) -> IRType? {
        switch expr {
        case .intConst(_, let type): return type
        case .floatConst: return .f64
        case .boolConst: return .boolean
        case .stringConst: return .string
        case .load(_, let type): return type
        case .binary(_, _, _, let type): return type
        case .unary(_, _, let type): return type
        case .call(_, _, let returnType): return returnType ?? .i32
        case .construct(let type): return type
        case .fieldGet(_, _, let type): return type
        case .enumConstruct(_, _, _, _, _, let type): return type
        case .assertCall: return .i32
        case .printCall, .printMulti: return .i32
        default: return nil
        }
    }

    private static func nodeName(_ statement: IRStmt) -> String {
        let text = String(describing: statement)
        if let cut = text.firstIndex(where: { $0 == "(" }) { return String(text[..<cut]) }
        return text
    }

    private static func nodeName(_ expr: IRExpr) -> String {
        let text = String(describing: expr)
        if let cut = text.firstIndex(where: { $0 == "(" }) { return String(text[..<cut]) }
        return text
    }
}

/// 缩进与行管理。`open` / `close` 成对出现，`elseOpen` / `elseIfOpen` 承担 `} else {` 这一种夹缝形态。
private final class CWriter {
    private var lines: [String] = []
    private var depth = 0

    func open(_ text: String) {
        line(text + " {")
        depth += 1
    }

    func elseOpen() {
        depth -= 1
        line("} else {")
        depth += 1
    }

    func elseIfOpen(_ condition: String) {
        depth -= 1
        line("} else if (\(condition)) {")
        depth += 1
    }

    func close() {
        depth -= 1
        line("}")
    }

    func line(_ text: String) {
        lines.append(String(repeating: "    ", count: depth) + text)
    }

    var output: String { lines.joined(separator: "\n") + "\n" }
}

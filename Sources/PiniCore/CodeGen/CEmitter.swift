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

/// C 后端的失败信号。遇到未支持的节点一律抛它，注意 —— 不静默降级：
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
        // 声明面上的 Optional 先登记：签名与布局里出现的结构体名要先有定义，否则产物编不过。
        try Self.noteDeclaredOptionals(scope: scope, functions: functions + methods, module: module)
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
        if scope.usesClosureValues { out += Self.closureValueDeclaration }
        out += scope.forwardDeclarations()
        out += scope.optionalDefinitions()
        out += scope.tupleDefinitions()
        out += try scope.aggregateDefinitions()
        out += try scope.layoutAssertions()
        out += try scope.tupleLayoutAssertions()
        out += try scope.closureEnvDefinitions()
        out += scope.lazyRefWrapperDefinitions()
        out += scope.copyFunctionDeclarations()
        out += scope.releaseFunctionDeclarations()
        out += scope.copyFunctionDefinitions()
        out += scope.releaseFunctionDefinitions()
        for constant in scope.constants {
            // 不加 `const`：字符串变量要参与 `bk_str_retain` / `bk_str_release`，两者都收 `char *`。
            // 常量串不在运行时的登记表里，那两个调用对它是无操作 —— 不会写这块只读之外的内存。
            out += "static char \(constant.name)[] = \(Self.cLiteral(constant.value));\n"
        }
        out += "\n"
        var prototypes = ""
        for function in functions + methods where function.name != "main" {
            prototypes += try CFunctionEmitter.prototype(of: function) + ";\n"
        }
        out += prototypes
        out += scope.closurePrototypesText()
        out += "\n"
        out += bodies.joined(separator: "\n")
        out += scope.closureBodies()
        return [CFile(name: "\(programName).c", contents: out)]
    }

    /// 函数值的按值表示。与 LLVM 的 `{ ptr, ptr }` 同宽同序：`code` 在 0、`env` 在 8。
    /// 这段注释随产物落盘：平台边界必须写在读者看得到的地方，而不是只留在发射器源码里。
    static let closureValueDeclaration = #"""
    // 函数值 = { code, env }，与 LLVM 的 `{ ptr, ptr }` 同宽同序：code 在 0、env 在 8。
    // 注意 —— 平台边界：code 存成 `void *` 再转回函数指针调用，ISO C 不保证、POSIX 保证 —— 产物只承诺 POSIX。
    // env 是指向捕获变量槽的指针数组，malloc 分配；与 LLVM 侧同一分配器，同样不在出口回收。
    typedef struct PiniClosure {
        void *code;
        void *env;
    } PiniClosure;
    _Static_assert(sizeof(PiniClosure) == 16, "闭包值布局漂移");
    _Static_assert(offsetof(PiniClosure, code) == 0, "闭包值布局漂移：code");
    _Static_assert(offsetof(PiniClosure, env) == 8, "闭包值布局漂移：env");

    """#


    /// 声明面上出现的可选类型逐个登记：签名、字段与枚举载荷槽都在这个面上。
    /// 只在构造 / 取值点登记的写法会漏掉「声明了但从没构造过」的那种签名。
    private static func noteDeclaredOptionals(
        scope: CModuleScope, functions: [IRFunction], module: IRModule
    ) throws {
        for function in functions {
            for param in function.params { try scope.noteType(param.type) }
            if let returnType = function.returnType { try scope.noteType(returnType) }
        }
        for decl in module.types {
            for field in decl.fields { try scope.noteType(field.type) }
        }
        for decl in module.enums {
            for slot in decl.slotTypes { try scope.noteType(slot) }
        }
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
    /// 按源码名索引的函数（含方法）：函数值的适配器要照着原函数的形参生成签名。
    private let functions: [String: IRFunction]
    /// 类型标识：结构按声明序 1 起，枚举接在结构之后 —— 与 LLVM 侧同一套编号，
    /// 差一位就是两个通道写进对象头的 id 不同。
    private let structIDs: [String: Int32]
    private let enumIDs: [String: Int32]

    private var stringsByValue: [String: String] = [:]
    private(set) var constants: [(name: String, value: String)] = []
    var calledNames: Set<String> = []

    /// LLVM 头里以裸名 declare、由 libc / libm 提供的那些符号。注意 —— 不按「不在本模块 ⇒ 外部」
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
    private var releaseSymbols: Set<String> = []
    private(set) var releaseBodies: [(symbol: String, pointer: String, source: String)] = []
    /// 用到的 Optional 结构体定义，按登记序（被引用的载荷先于引用它的那个）。
    private var optionalNames: Set<String> = []
    private(set) var optionalBodies: [String] = []
    /// 用到的元组形状：名字与其字段表。名字去重，字段表留作 `_Static_assert` 的输入。
    private var tupleNames: Set<String> = []
    private(set) var tupleBodies: [String] = []
    private var tupleShapes: [(name: String, fieldTypes: [IRType])] = []
    /// LazyRef 的装箱入口，按元素类型去重。
    private var lazyRefWrapperNames: Set<String> = []
    private var lazyRefWrappers: [String] = []
    /// 每个闭包字面量一个 env 结构体：字段数即捕获数，按捕获序排。
    private var closureEnvNames: Set<String> = []
    private var closureEnvs: [(name: String, count: Int)] = []
    private var closurePrototypes: [String] = []
    private var closureBodyTexts: [String] = []
    /// 具名函数的适配器已生成过的（每个函数最多一份，与 LLVM 侧同一条去重账）。
    private var adapterSymbols: Set<String> = []
    private var adapterTexts: [String] = []
    /// 产物里出现过函数值：只有此时才落 `PiniClosure` 的 typedef 与布局断言。
    private(set) var usesClosureValues = false

    init(module: IRModule, defined: Set<String>) {
        self.types = module.types
        self.enums = module.enums
        self.defined = defined
        var table: [String: IRFunction] = [:]
        for function in module.functions + module.types.flatMap(\.methods) {
            table[function.name] = function
        }
        functions = table
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

    func function(named name: String) -> IRFunction? { functions[name] }

    /// 闭包字面量 `id` 的 env 结构体名，顺带登记其字段数。名字由 id 派生，
    /// 与 LLVM 的 `%__closure_env_<id>` 一一对应。
    func registerClosureEnv(id: Int, captureCount: Int) -> String {
        usesClosureValues = true
        let name = "PiniEnv_\(id)"
        guard closureEnvNames.insert(name).inserted else { return name }
        closureEnvs.append((name: name, count: captureCount))
        return name
    }

    /// 全部 env 结构体定义与逐字段偏移断言。env 的字宽与顺序必须与 LLVM 的 `{ ptr, ... }` 一致：
    /// 捕获变量的槽指针按捕获序落在 8 字节一格上，错一格闭包就读到别人的变量。
    func closureEnvDefinitions() throws -> String {
        guard !closureEnvs.isEmpty else { return "" }
        var out = ""
        for env in closureEnvs {
            out += "typedef struct \(env.name) {\n"
            for index in 0..<env.count { out += "    void *f\(index);\n" }
            out += "} \(env.name);\n"
            out += "_Static_assert(sizeof(\(env.name)) == \(env.count * 8), \"闭包环境布局漂移：\(env.name)\");\n"
            for index in 0..<env.count {
                out +=
                    "_Static_assert(offsetof(\(env.name), f\(index)) == \(index * 8),"
                    + " \"闭包环境布局漂移：\(env.name).f\(index)\");\n"
            }
        }
        return out + "\n"
    }

    func addClosure(prototype: String, body: String) {
        closurePrototypes.append(prototype)
        closureBodyTexts.append(body)
    }

    /// 闭包体的签名要排在所有函数体之前：闭包在创建点被引用，C 不允许用到未声明的函数。
    func closurePrototypesText() -> String {
        closurePrototypes.isEmpty ? "" : closurePrototypes.map { $0 + ";\n" }.joined()
    }

    func closureBodies() -> String {
        let all = closureBodyTexts + adapterTexts
        return all.isEmpty ? "" : "\n" + all.joined(separator: "\n")
    }

    /// 具名函数当值用时的适配器：间接调用的约定是 `代码(env, 实参...)`，而原函数没有 env 槽，
    /// 直接把它的地址塞进闭包会让每个实参错位一格 —— 这层转发补齐 env（与 LLVM 的 `__adapter_` 同形）。
    func registerAdapter(for function: IRFunction) throws -> String {
        usesClosureValues = true
        let mangled = IRName.mangle(function.name)
        let symbol = "pini_adapter_\(mangled)"
        guard adapterSymbols.insert(symbol).inserted else { return symbol }
        var params: [String] = ["void *env"]
        var callArgs: [String] = []
        for (index, param) in function.params.enumerated() {
            try noteType(param.type)
            params.append("\(try CTypeMap.spelling(of: param.type)) a\(index)")
            callArgs.append("a\(index)")
        }
        let returnSpelling = try function.returnType.map { try CTypeMap.spelling(of: $0) } ?? "void"
        closurePrototypes.append("static \(returnSpelling) \(symbol)(\(params.joined(separator: ", ")))")
        var lines: [String] = []
        lines.append("static \(returnSpelling) \(symbol)(\(params.joined(separator: ", "))) {")
        lines.append("    (void)env;")
        let call = "pini_\(mangled)(\(callArgs.joined(separator: ", ")))"
        lines.append(function.returnType == nil ? "    \(call);" : "    return \(call);")
        lines.append("}")
        adapterTexts.append(lines.joined(separator: "\n"))
        return symbol
    }

    /// 登记一个 Optional 载荷类型的具名结构体，返回结构体名。载荷本身也是 Optional 时先递归登记，
    /// 使定义序里被引用的那个在前；同载荷再次登记只是复用名字。
    func registerOptional(_ type: IRType) throws -> String {
        guard case .optional(let wrapped) = type else {
            throw CBackendError(message: "C 后端：为非 Optional 类型请求 Optional 定义")
        }
        let definition = try CTypeMap.optionalDefinition(type)
        guard optionalNames.insert(definition.name).inserted else { return definition.name }
        try noteType(wrapped)
        optionalBodies.append(definition.source)
        return definition.name
    }

    /// 类型需要在产物里落一个结构体定义就登记（Optional / 元组）。声明面上的类型要在这里过一遍：
    /// 只在使用点登记的写法会漏掉「声明了但没构造」的签名。
    func noteType(_ type: IRType) throws {
        // 函数类型出现在签名面也要算一次使用：`PiniClosure` 的 typedef 得排在原型之前。
        if case .function = type { usesClosureValues = true }
        if case .tuple = type {
            _ = try registerTuple(type)
            return
        }
        guard case .optional = type else { return }
        _ = try registerOptional(type)
    }

    /// 全部 Optional 结构体定义。注意 —— 排在聚合体前向声明之后：载荷可能是指向名义结构体的指针。
    func optionalDefinitions() -> String {
        optionalBodies.isEmpty ? "" : optionalBodies.joined(separator: "\n") + "\n"
    }

    /// 登记一个元组形状，返回它的 C 结构体名。字段类型先递归登记，使被嵌套的那个排在前面 ——
    /// C 要求被嵌的聚合体在使用点之前已有完整定义。
    func registerTuple(_ type: IRType) throws -> String {
        guard case .tuple(_, let fieldTypes) = type else {
            throw CBackendError(message: "C 后端：为非元组类型请求元组定义")
        }
        let definition = try CTypeMap.tupleDefinition(fieldTypes)
        guard tupleNames.insert(definition.name).inserted else { return definition.name }
        for fieldType in fieldTypes { try noteType(fieldType) }
        tupleBodies.append(definition.source)
        tupleShapes.append((name: definition.name, fieldTypes: fieldTypes))
        return definition.name
    }

    /// 全部元组结构体定义。排在 Optional 之后、名义聚合体之前：名义字段可能就是一个元组。
    func tupleDefinitions() -> String {
        tupleBodies.isEmpty ? "" : tupleBodies.joined(separator: "\n") + "\n"
    }

    /// 元组的布局判据：总字节数与逐字段偏移。少了它，字段序或宽度漂了只能到运行期看见。
    func tupleLayoutAssertions() throws -> String {
        var out = ""
        for shape in tupleShapes {
            let layout = try CLayout.tuple(shape.fieldTypes)
            out += "_Static_assert(sizeof(\(shape.name)) == \(layout.size), \"元组布局漂移：\(shape.name)\");\n"
            for (index, offset) in layout.offsets.enumerated() {
                out +=
                    "_Static_assert(offsetof(\(shape.name), f\(index)) == \(offset),"
                    + " \"元组布局漂移：\(shape.name).f\(index)\");\n"
            }
        }
        return out
    }

    /// LazyRef 的装箱入口：运行时段按统一 ABI 回调 `(code, env, out) -> out`，
    /// 元素类型决定调用的签名与写出的宽度 —— 后缀与 LLVM 的 `__lazyref_wrapper_<T>` 同源。
    func registerLazyRefWrapper(element: IRType) throws -> String {
        let suffix = Self.lazyRefWrapperSuffix(element)
        let name = "pini_lazyref_wrapper_\(suffix)"
        guard lazyRefWrapperNames.insert(name).inserted else { return name }
        let spelling = try CTypeMap.spelling(of: element)
        let parameter = "v_\(suffix)"
        var lines: [String] = []
        lines.append(
            "// LazyRef 的装箱入口：间接调用初始化闭包（首参恒为 env），把元素写进运行时给的堆盒再交回。")
        lines.append("static void *\(name)(void *code, void *env, void *out) {")
        lines.append("    \(spelling) \(parameter) = ((\(spelling) (*)(void *))code)(env);")
        lines.append("    *(\(spelling) *)out = \(parameter);")
        lines.append("    return out;")
        lines.append("}")
        lazyRefWrappers.append(lines.joined(separator: "\n"))
        return name
    }

    /// 后缀：字符串与字符同拼写故共用一个入口（ABI 相同即同一个 wrapper），其余按元素类型派生。
    static func lazyRefWrapperSuffix(_ element: IRType) -> String {
        switch element {
        case .i32: return "i32"
        case .f64: return "f64"
        case .boolean: return "i1"
        case .string, .char: return "ptr"
        default: return CTypeMap.label(of: element)
        }
    }

    func lazyRefWrapperDefinitions() -> String {
        lazyRefWrappers.isEmpty ? "" : lazyRefWrappers.joined(separator: "\n") + "\n\n"
    }

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

    func reserveReleaseSymbol(_ symbol: String) -> Bool {
        releaseSymbols.insert(symbol).inserted
    }

    func appendReleaseBody(symbol: String, pointer: String, source: String) {
        releaseBodies.append((symbol, pointer, source))
    }

    /// 全部聚合体的前向声明。注意 —— 顺序无关紧要：名义字段一律是指针，
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
    /// 注意 —— 这一条是名义类型期唯一能把「字段顺序或宽度漂了」挡在产物之外的机制。
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

    func releaseFunctionDeclarations() -> String {
        guard !releaseBodies.isEmpty else { return "" }
        var out = ""
        for entry in releaseBodies {
            out += "static void \(entry.symbol)(\(entry.pointer)box);\n"
        }
        return out
    }

    func releaseFunctionDefinitions() -> String {
        guard !releaseBodies.isEmpty else { return "" }
        return releaseBodies.map(\.source).joined(separator: "\n") + "\n\n"
    }
}

/// 名义聚合体的 C 布局模型：按 ABI 的对齐规则推偏移，供 `_Static_assert` 比对。
/// 只覆盖生成器会用到的类型 —— 表外的类型抛错，注意 —— 不猜一个宽度。
enum CLayout {
    static let headerSize = 24
    static let headerAlign = 8

    static func size(of type: IRType) throws -> (size: Int, align: Int) {
        switch type {
        case .boolean, .i8, .u8: return (1, 1)
        case .i32: return (4, 4)
        case .i64, .u64, .f64: return (8, 8)
        case .string, .char, .nominal, .enumeration: return (8, 8)
        // 容器字段是句柄指针；Optional 字段是「8 字节标签 + 载荷」的按值结构体。
        case .array, .dict, .set: return (8, 8)
        // 函数值字段是 `{ code, env }` 两个指针，按值嵌进聚合体。
        case .function: return (16, 8)
        // LazyRef 是句柄。
        case .lazyRef: return (8, 8)
        case .optional(let wrapped):
            let (size, align) = try self.size(of: wrapped)
            return (roundUp(8 + size, max(8, align)), max(8, align))
        // 元组的尺寸与对齐由字段表推出，与 LLVM 对同一份 `{ ... }` 的结论同源。
        case .tuple(_, let fieldTypes):
            let layout = try self.tuple(fieldTypes)
            return (layout.size, layout.align)
        default: throw CBackendError(message: "C 后端尚未支持的类型布局：\(CTypeMap.label(of: type))")
        }
    }

    /// 元组的 ABI 布局：从 0 起逐字段按各自对齐前推，总尺寸补齐到最大对齐。
    ///  注意 —— 起点是 0 而不是 `headerSize`：元组没有对象头，它不是名义箱。
    static func tuple(_ fieldTypes: [IRType]) throws -> (size: Int, align: Int, offsets: [Int]) {
        var offset = 0
        var maxAlign = 1
        var offsets: [Int] = []
        for type in fieldTypes {
            let (size, align) = try self.size(of: type)
            offset = roundUp(offset, align)
            offsets.append(offset)
            offset += size
            maxAlign = max(maxAlign, align)
        }
        return (roundUp(offset, maxAlign), maxAlign, offsets)
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
    private let function: IRFunction?
    private let scope: CModuleScope
    private let programBase: String?
    private let writer = CWriter()
    private var frames: [Frame] = []
    private var labelSeq = 0
    private var tempSeq = 0
    private var slotSeq = 0
    private var terminated = false

    /// 本发射器要落地的体与它的返回类型。闭包体与具名函数体共用同一套语句 / 表达式通道，
    /// 差别只在签名（闭包多一个 env 形参）与捕获名的解析。
    private let body: IRBlock
    private let bodyReturnType: IRType?
    /// 闭包体专用：`id` 定 env 结构体名；形参的 C 名与类型平行于 IR 的形参表。
    private let closureID: Int?
    private let closureParamNames: [String]
    private let closureParamTypes: [IRType]

    /// 捕获名 → 一次解引用拿到值、值本身就是槽指针。体里对捕获变量的读写都走这两条文本，
    /// 与 LLVM 侧 `load / store` 同一块外层存储 —— 引用捕获的可见性正来自这里。
    private var captureSlots: [String: CaptureSlot] = [:]

    private struct CaptureSlot {
        /// 读：`(*(T *)c_env->f0)`。
        let deref: String
        /// 再被内层闭包捕获时交给它的槽指针：就是 `c_env->f0` 里那个指针本身。
        let address: String
    }

    /// 作用域栈：Pini 名 → C 局部名。遮蔽必须换名，否则内层 `var x` 与外层同名时，
    /// 释放账本分不清两个持有者 —— 按名字查会释放错的那个。
    private var scopes: [[String: String]] = []
    /// 形参名 → C 名。形参不登记释放（调用方持有它的份额），但 `lookupVar` 要能找到它们。
    private let paramLocals: [String: String]
    /// 持有者账本：每层一个帧，与 `emitBlock` 同序压栈。块尾按逆序释放，`return` / `break` / `continue` 各发一份。
    private var releaseFrames: [[ReleaseEntry]] = []
    /// 每个打开作用域的 defer 体，与释放帧同序压栈。块尾按后进先出重放，终止边各发一份副本。
    private var deferFrames: [[IRBlock]] = []
    /// 正在重放 defer 体。注意 —— 重放期间的终止边（`defer` 体里写 `return`）不再触发重放 ——
    /// 否则同一帧被逐层再进一次，产物还没写出，编译器先栈溢出。
    private var isReplayingDefers = false

    /// 本层新分配、尚无持有者的临时箱 / 句柄：C 局部名 → 类型。入账：构造点；出账：被持有位置接管，
    /// 或在调用点 / 打印点就地还。
    private var ownedBoxes: [String: IRType] = [:]

    /// 本层亲手分配、尚无持有者的字符串临时值（C 局部名）。只有拼接与插值的产出点入账；
    /// 注意 —— 借来的值（常量串 / 变量槽 / 形参）不入账 —— 账本正是把两者分开，错判即提前释放。
    private var ownedStrings: Set<String> = []

    private struct ReleaseEntry {
        let local: String
        let type: IRType
    }

    private struct Frame {
        let exit: String
        let header: String
        let isLoop: Bool
        let needsExit: Bool
        let needsHeader: Bool
        /// 无标签 `continue` 的落点：for-in 要区分「转到 step 块」与「转到自增」，C 的 `continue` 分不出。
        /// nil ⇒ 用 C 自己的 `continue`。
        let continueLabel: String?
        /// 本帧入栈时的账本深度：跳出本帧要释放 `releaseFrames[releaseBase...]`。
        let releaseBase: Int
        /// 本帧入栈时的 defer 帧深度：跳出本帧要把 `deferFrames[deferBase...]` 的体重放一遍。
        let deferBase: Int
    }

    init(function: IRFunction, scope: CModuleScope, programBase: String?) {
        self.function = function
        self.scope = scope
        self.programBase = programBase
        body = function.body
        bodyReturnType = function.returnType
        closureID = nil
        closureParamNames = []
        closureParamTypes = []
        var params: [String: String] = [:]
        for param in function.params {
            params[param.name] = "v_\(IRName.mangle(param.name))"
        }
        paramLocals = params
    }

    /// 闭包体：形参按 `a_` 前缀落成 C 形参，捕获按 env 字段序解引用。注意 —— 捕获不登记释放 ——
    /// 槽归外层变量持有，闭包只是借用（与 LLVM 侧「captureSlots 不入 pendingReleases」同规）。
    init(
        closureID: Int, captures: [IRCapture], paramNames: [String], paramTypes: [IRType],
        returnType: IRType?, body: IRBlock, scope: CModuleScope, programBase: String?
    ) throws {
        self.function = nil
        self.scope = scope
        self.programBase = programBase
        self.body = body
        self.bodyReturnType = returnType
        self.closureID = closureID
        self.closureParamTypes = paramTypes
        self.closureParamNames = paramNames.map { "a_\(IRName.mangle($0))" }
        var params: [String: String] = [:]
        for (index, name) in paramNames.enumerated() where index < paramTypes.count {
            params[name] = "a_\(IRName.mangle(name))"
        }
        paramLocals = params
        for (index, capture) in captures.enumerated() {
            let spelling = try CTypeMap.spelling(of: capture.type)
            captureSlots[capture.name] = CaptureSlot(
                deref: "(*(\(spelling) *)c_env->f\(index))",
                address: "(void *)c_env->f\(index)")
        }
    }

    private var isMain: Bool { function?.name == "main" }

    func emit() throws -> String {
        writer.open(try signature())
        if isMain, let base = programBase {
            let constant = scope.registerString(base)
            writer.line("bk_set_program_base((void *)\(constant));")
        }
        try emitBlock(body)
        if !terminated {
            // 顶层作用域的持有者在落空边上释放；`return` 那条边自己发过一份，两条边不会同时走。
            try emitReleases(downTo: 0)
            if isMain {
                writer.line("return 0;")
            } else if let returnType = bodyReturnType {
                writer.line("return \(try CTypeMap.zeroLiteral(of: returnType));")
            } else if function != nil || closureID != nil {
                writer.line("return;")
            }
        }
        writer.close()
        return writer.output
    }

    /// 闭包体的定义：签名多一个 `void *env` 首参，体内先把 env 转成这一号 env 结构体。
    /// 三件事与 LLVM 侧逐条对齐：形参落栈、捕获取槽、落空边先释放再返回。
    func emitClosureDefinition() throws {
        let prototype = "static " + (try closureSignature())
        writer.open(prototype)
        if let id = closureID, !captureSlots.isEmpty {
            writer.line("PiniEnv_\(id) *c_env = (PiniEnv_\(id) *)env;")
        } else {
            writer.line("(void)env;")
        }
        try emitBlock(body)
        if !terminated {
            try emitReleases(downTo: 0)
            if let returnType = bodyReturnType {
                writer.line("return \(try CTypeMap.zeroLiteral(of: returnType));")
            } else {
                writer.line("return;")
            }
        }
        writer.close()
        scope.addClosure(prototype: prototype, body: writer.output)
    }

    /// `static <ret> pini_closure_<id>(void *env, <形参>...)`。返回类型是体自己声明的那个。
    private func closureSignature() throws -> String {
        var parts = ["void *env"]
        for (index, type) in closureParamTypes.enumerated() {
            try scope.noteType(type)
            let name = index < closureParamNames.count ? closureParamNames[index] : "a\(index)"
            parts.append("\(try CTypeMap.spelling(of: type)) \(name)")
        }
        let ret = try bodyReturnType.map { try CTypeMap.spelling(of: $0) } ?? "void"
        return "\(ret) pini_closure_\(closureID ?? 0)(\(parts.joined(separator: ", ")))"
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
        guard let function else {
            throw CBackendError(message: "C 后端：闭包体不走函数签名通道")
        }
        return try Self.prototype(of: function)
    }

    // MARK: - 语句

    /// 发射一个语句块：压入名字作用域与释放帧，块尾按落空 / 终止分别收口。
    /// 顶层块（`releaseBase == 0`）的持有者归函数出口处理，注意 —— 不在此释放 —— 那样 `return` 那条边会双份。
    private func emitBlock(_ block: IRBlock) throws {
        let deferBase = deferFrames.count
        deferFrames.append([])
        let releaseBase = releaseFrames.count
        releaseFrames.append([])
        scopes.append([:])
        for statement in block.statements {
            if terminated { break }
            try emitStmt(statement)
        }
        if terminated {
            // `return` / `break` / `continue` 已各发过一份它所跳过的帧；本块尾部不可达，只丢帧。
            if releaseBase > 0 { releaseFrames.removeLast() }
            deferFrames.removeLast()
        } else {
            // defers 排在释放之前：与 LLVM 侧逐句同序 —— 先跑完本作用域的 defer，再交还本块的持有者。
            try emitDefers(downTo: deferBase)
            if releaseBase > 0 {
                try emitReleases(downTo: releaseBase)
                releaseFrames.removeLast()
            }
            deferFrames.removeLast()
        }
        scopes.removeLast()
    }

    /// 把一个作用域的 defer 体按后进先出逐条重放：内层帧在先、帧内逆序，与 LLVM 侧 `flushDefers` 同序。
    /// 注意 —— 只重放不弹栈 —— 帧的归属仍留在 `emitBlock`，每条终止边各发一份副本。
    private func emitDefers(downTo base: Int) throws {
        guard base < deferFrames.count, !isReplayingDefers else { return }
        let wasTerminated = terminated
        isReplayingDefers = true
        terminated = false
        for frame in deferFrames[base...].reversed() {
            for body in frame.reversed() {
                for statement in body.statements {
                    if terminated { break }
                    try emitStmt(statement)
                }
            }
        }
        isReplayingDefers = false
        terminated = wasTerminated
    }

    /// 一个持有者在退出 / 被覆盖时要调的释放；nil = 该类型不参与计数。
    /// 容器句柄走 `bk_*_destroy`（对 NULL 无操作），与名义箱的合成胶水共用同一条登记通道。
    private func releaseSymbol(for type: IRType) throws -> String? {
        switch type {
        case .nominal, .enumeration: return try releaseFunction(for: type)
        case .string, .char: return "bk_str_release"
        case .array: return "bk_array_destroy"
        case .dict: return "bk_dict_destroy"
        case .set: return "bk_set_destroy"
        default: return nil
        }
    }

    /// 声明一个局部。同名遮蔽换后缀：两个持有者必须是两个 C 变量，否则账本按名字查会释放错的那个。
    private func declareLocal(_ name: String) -> String {
        let base = "v_\(IRName.mangle(name))"
        let taken = scopes.contains { $0.values.contains(base) } || paramLocals.values.contains(base)
        var local = base
        if taken {
            slotSeq += 1
            local = "\(base)_\(slotSeq)"
        }
        scopes[scopes.count - 1][name] = local
        return local
    }

    /// 变量名解析：内层作用域优先，其次形参，最后闭包捕获。
    private func lookupVar(_ name: String) -> String {
        for frame in scopes.reversed() {
            if let hit = frame[name] { return hit }
        }
        if let param = paramLocals[name] { return param }
        if let slot = captureSlots[name] { return slot.deref }
        return "v_\(IRName.mangle(name))"
    }

    /// 把本块新声明的持有者登记进当前帧。
    private func registerRelease(local: String, type: IRType) throws {
        guard try releaseSymbol(for: type) != nil else { return }
        guard !releaseFrames.isEmpty else { return }
        releaseFrames[releaseFrames.count - 1].append(ReleaseEntry(local: local, type: type))
    }

    /// 发一组释放：帧从内到外、帧内按声明的逆序。与 LLVM 侧的 `emitReleases(downTo:)` 同序 ——
    /// 顺序反了会在「两个持有者其实是同一个箱」时提前归零。
    private func emitReleases(downTo base: Int) throws {
        guard base < releaseFrames.count else { return }
        for frame in releaseFrames[base...].reversed() {
            for entry in frame.reversed() {
                guard let call = try releaseCall(local: entry.local, type: entry.type) else { continue }
                writer.line("\(call);")
            }
        }
    }

    private func releaseCall(local: String, type: IRType) throws -> String? {
        guard let symbol = try releaseSymbol(for: type) else { return nil }
        return "\(symbol)(\(local))"
    }

    /// 记下一个本层亲手分配、当前持有 +1 的临时箱。只由构造点调用：借用值（变量 / 字段 / 形参）从不入账。
    private func adoptOwnedBox(_ local: String, type: IRType) {
        ownedBoxes[local] = type
    }

    /// 交出所有权：该值已被某个持有位置（槽 / 字段 / 返回位 / 载荷槽）接管，此后由那里释放。
    /// 它与 `emitOwnedTemporaryRelease` 互斥，一个值只走一条；错成 claim 是泄漏（安全），错成 release 是悬垂。
    private func claimOwnedBox(_ text: String) {
        ownedBoxes.removeValue(forKey: text)
    }

    /// 就地还掉一个本层持有的临时值 —— 调用点与打印点的「用完即扔」。注意 —— 借用值不在账里 ⇒ 无操作。
    /// 判据是账本而不是节点形状：只有确实由本层分配、且没被持有位置接管的那些才在账上。
    private func emitOwnedTemporaryRelease(_ text: String) throws {
        if ownedStrings.remove(text) != nil {
            writer.line("bk_str_release(\(text));")
            return
        }
        guard let type = ownedBoxes.removeValue(forKey: text) else { return }
        guard let symbol = try releaseSymbol(for: type) else { return }
        writer.line("\(symbol)(\(text));")
    }

    /// 就地还掉一个字符串临时值 —— 拼接的两个操作数与内建实参。注意 —— 只在账上的才发调用：
    /// 常量串与槽值都在账外，错发一次就是读已回收内存。
    private func emitOwnedStringRelease(_ text: String) {
        guard ownedStrings.remove(text) != nil else { return }
        writer.line("bk_str_release(\(text));")
    }

    /// 记下一个本层亲手分配、当前持有 +1 的字符串。只由产出点（拼接 / 插值）调用。
    private func adoptOwnedString(_ local: String) {
        ownedStrings.insert(local)
    }

    /// 交出字符串的所有权：价值已被持有位置接管，此后由那里释放。与就地还互斥，一个值只走一条。
    private func claimOwnedString(_ text: String) {
        ownedStrings.remove(text)
    }

    /// 调用点的收尾：实参一律**借用**。被调方既不 retain 也不在出口释放（形参不登记），
    /// 于是临时值的 +1 份额留在调用方，返回后当场还；变量 / 字段的别名份额不在账上，一条也不碰。
    /// C 的一个表达式里塞不下「调用 + 释放」⇒ 调用先落进临时变量，调用点因此多一行。
    private func materializeCallReleasingArguments(
        _ call: String, returnType: IRType?, arguments: [String]
    ) throws -> String {
        let owed = arguments.filter { ownedBoxes[$0] != nil }
        guard !owed.isEmpty else { return call }
        guard let returnType else {
            writer.line("\(call);")
            for text in owed { try emitOwnedTemporaryRelease(text) }
            return ""
        }
        /// 拼不出返回类型（聚合 / Result）就不落临时变量：宁可留一份泄漏，也不让产物编不过。
        guard let spelling = try? CTypeMap.spelling(of: returnType) else { return call }
        let temp = "t_\(nextTempSeq())"
        writer.line("\(spelling) \(temp) = \(call);")
        for text in owed { try emitOwnedTemporaryRelease(text) }
        return temp
    }

    /// 局部被覆盖前释放它持有的份额。只对已登记的持有者做 —— 标量不在账本里，一个字节也不碰。
    private func emitReassignRelease(local: String, type: IRType) throws {
        let registered = releaseFrames.contains { frame in
            frame.contains { $0.local == local }
        }
        guard registered, let call = try releaseCall(local: local, type: type) else { return }
        writer.line("\(call);")
    }

    private func emitStmt(_ statement: IRStmt) throws {
        switch statement {
        case .allocVar(let name, let type, _, let initializer):
            try scope.noteType(type)
            let spelling = try CTypeMap.spelling(of: type)
            let local = declareLocal(name)
            if let initializer {
                let value = try emitExpr(initializer)
                let stored = try emitValueForStorage(initializer, value, type: type)
                writer.line("\(spelling) \(local) = \(stored);")
            } else if try releaseSymbol(for: type) != nil {
                // 无初值也必须落零：登记成持有者之后，退出时会对槽里的内容发释放，
                // 未初始化指针进去就是 SIGBUS。`NULL` / 0 对释放路径是无操作。
                writer.line("\(spelling) \(local) = \(try CTypeMap.zeroLiteral(of: type));")
            } else {
                writer.line("\(spelling) \(local);")
            }
            try registerRelease(local: local, type: type)
            terminated = false

        case .storeVar(let name, let type, let value):
            let local = lookupVar(name)
            let lowered = try emitExpr(value)
            // 三行的顺序就是语义：新值先站住（拷贝 / retain），再释放旧值，最后写。
            // 颠倒则 `a = a` 先回收掉新值要读的箱。
            let stored = try emitValueForStorage(value, lowered, type: type)
            try emitReassignRelease(local: local, type: type)
            writer.line("\(local) = \(stored);")
            terminated = false

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            try emitIf(label: label, condition: condition, thenBody: thenBody, elseBody: elseBody)

        case .whileStmt(let condition, let body, let step):
            try emitWhile(condition: condition, body: body, step: step)

        case .forInStmt(let pattern, let elementTypes, let kind, let iterable, let body, let step):
            try emitForIn(
                pattern: pattern, elementTypes: elementTypes, kind: kind,
                iterable: iterable, body: body, step: step)

        case .subscriptStore(let container, let index, let value, let elementType):
            try emitSubscriptStore(container: container, index: index, value: value, elementType: elementType)

        case .returnStmt(let value):
            // defers 先跑、返回值后求值：与 LLVM 侧同序 —— defer 体改过的变量，返回值读到的就是改后的值。
            try emitDefers(downTo: 0)
            if let value {
                let lowered = try emitExpr(value)
                // 与 LLVM 侧同规：交出去的值先按值语义落定（结构体别名拷新箱），再释放、再 ret。
                let stored = try bodyReturnType.map {
                    try emitValueForStorage(value, lowered, type: $0)
                } ?? lowered
                try emitReleases(downTo: 0)
                writer.line("return \(stored);")
            } else {
                try emitReleases(downTo: 0)
                if isMain {
                    writer.line("return 0;")
                } else {
                    writer.line("return;")
                }
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

        case .deferStmt(let body):
            // 只登记，不发射：体在离开本作用域时按后进先出重放（`emitDefers`）。
            deferFrames[deferFrames.count - 1].append(body)

        case .captureMarker:
            // 捕获在字面量的创建点就落进 env 了，标记语句本身不产生代码（与 LLVM 侧同）。
            break

        case .matchStmt(let scrutinee, let cases, let scrutineeType):
            try emitMatch(scrutinee: scrutinee, cases: cases, scrutineeType: scrutineeType)

        case .fieldStore(let base, let field, let value, let fieldType):
            let baseText = try emitExpr(base)
            let access = try fieldAccess(base: base, field: field, baseText: baseText)
            let lowered = try emitExpr(value)
            // 顺序同 `storeVar`：新值先站住，再释放字段旧值，最后写。字段是持有者。
            let stored = try emitValueForStorage(value, lowered, type: fieldType)
            if let call = try releaseCall(local: access, type: fieldType) {
                writer.line("\(call);")
            }
            writer.line("\(access) = \(stored);")
            terminated = false

        case .breakStmt(let depth):
            let frame = try frame(at: depth)
            try emitDefers(downTo: frame.deferBase)
            try emitReleases(downTo: frame.releaseBase)
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
            try emitDefers(downTo: frame.deferBase)
            try emitReleases(downTo: frame.releaseBase)
            if frame.isLoop && depth == 1 && frame.continueLabel == nil {
                writer.line("continue;")
            } else if frame.isLoop && depth == 1, let target = frame.continueLabel {
                // for-in 的 `continue` 分两种落点（step 块 / 自增），C 的 `continue` 表达不了。
                writer.line("goto \(target);")
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
                exit: exit, header: exit, isLoop: false, needsExit: needsExit, needsHeader: false,
                continueLabel: nil, releaseBase: releaseFrames.count, deferBase: deferFrames.count)
            frames.append(pushed)
            frame = pushed
        }
        writer.open("if (\(cond))")
        try emitBlock(thenBody)
        if let elseBody {
            // `terminated` 属于上一条分支：不清掉的话 `emitBlock` 会在第一条语句前就 break，
            // 整个 else 体消失 —— 编译能过，只是那半边永远不执行。
            terminated = false
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

    /// `while cond: body [step: block]`。带 step 时它坐在体与回边之间：体内无标签的 `continue` 落到 step 入口，
    /// 两块的 `break` 都直接跳出并跳过 step。注意 —— 有内层跳出指向本循环时换成 `for (;;)`，C 没给条件挂标号的语法。
    private func emitWhile(condition: IRExpr, body: IRBlock, step: IRBlock?) throws {
        let info = scan(body, nesting: 0, direct: false)
        let stepInfo = scan(step, nesting: 0, direct: false)
        let id = nextLabelSeq()
        let exit = "end_\(id)"
        let header = "cont_\(id)"
        let stepLabel = "while_step_\(id)"
        let stepEnd = "while_step_end_\(id)"
        frames.append(
            Frame(
                exit: exit, header: header, isLoop: true,
                needsExit: info.brk || stepInfo.brk, needsHeader: info.cont,
                continueLabel: step != nil ? stepLabel : nil,
                releaseBase: releaseFrames.count, deferBase: deferFrames.count))
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
        if let step {
            // 体的终止不封住 step：它还有 `continue` 那条入口，故照样落标号并重放。
            terminated = false
            writer.line("\(stepLabel): ;")
            frames.append(
                Frame(
                    exit: exit, header: header, isLoop: true, needsExit: stepInfo.brk,
                    needsHeader: true, continueLabel: stepEnd,
                    releaseBase: releaseFrames.count, deferBase: deferFrames.count))
            try emitBlock(step)
            frames.removeLast()
            writer.line("\(stepEnd): ;")
        }
        writer.close()
        frames.removeLast()
        if info.brk || stepInfo.brk { writer.line("\(exit): ;") }
        terminated = false
    }

    /// `match`：枚举按标签派发。注意 —— 不用 `switch` —— 臂里的 `break` 在 C 里会绑到 `switch` 上，
    /// 而 Pini 的 `break` 指的是外层循环；`if` 链没有这个问题，也与 LLVM 侧的标签链同构。
    private func emitMatch(scrutinee: IRExpr, cases: [IRMatchCase], scrutineeType: IRType) throws {
        if case .optional(let wrapped) = scrutineeType {
            try emitOptionalMatch(scrutinee: scrutinee, cases: cases, wrapped: wrapped)
            return
        }
        guard case .enumeration(let name) = scrutineeType else {
            // 裸判别式：字面量臂与通配臂在 LLVM 侧走标量比较，本层还没有那张表（拒绝）；
            // 两者都没有的 match 是死匹配 —— 只求值判别式，一条臂都不进，与解释器同结论。
            if cases.contains(where: { $0.literal != nil }) || cases.contains(where: { $0.caseName == "_" }) {
                throw CBackendError(message: "C 后端尚未支持的标量 match（字面量臂或通配臂）")
            }
            _ = try emitExpr(scrutinee)
            return
        }
        guard let decl = scope.enumDecl(named: name) else {
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
            // 臂自带一层名字作用域：绑定只在臂内可见，且不登记释放 —— 它们是枚举箱里的载荷，箱由扫描对象持有。
            scopes.append([:])
            terminated = false
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
            scopes.removeLast()
            isFirst = false
        }
        if !hasWildcard {
            if isFirst { writer.open("if (1)") } else { writer.elseOpen() }
            writer.line("bk_panic(\(panicMessage));")
        }
        writer.close()
        terminated = false
    }

    /// `match opt:`：标签 0 = some、1 = none。臂链用 `if` 而非 `switch` —— 臂里的 `break`
    /// 指的是外层循环，C 的 `switch` 会把它接走。
    private func emitOptionalMatch(
        scrutinee: IRExpr, cases: [IRMatchCase], wrapped: IRType
    ) throws {
        let local = try materialize(try emitExpr(scrutinee), type: .optional(wrapped: wrapped))
        let panicMessage = scope.registerString("Pini runtime error: match value matched no case")
        var isFirst = true
        var hasWildcard = false
        for arm in cases {
            scopes.append([:])
            terminated = false
            if arm.caseName == "_" {
                hasWildcard = true
                if isFirst { writer.open("if (1)") } else { writer.elseOpen() }
            } else {
                let condition = "\(local).tag == \(arm.caseName == "some" ? 0 : 1)"
                if isFirst { writer.open("if (\(condition))") } else { writer.elseIfOpen(condition) }
                if let binding = arm.bindings.first ?? nil {
                    let name = declareLocal(binding)
                    writer.line("\(try CTypeMap.spelling(of: wrapped)) \(name) = \(local).value;")
                }
            }
            try emitBlock(arm.body)
            scopes.removeLast()
            isFirst = false
        }
        if !hasWildcard {
            if isFirst { writer.open("if (1)") } else { writer.elseOpen() }
            writer.line("bk_panic(\(panicMessage));")
        }
        writer.close()
        terminated = false
    }

    private func emitBindings(        arm: IRMatchCase, enumCase: IREnumCase, decl: IREnumDecl, pointer: String, enumName: String
    ) throws {
        for (slot, binding) in arm.bindings.enumerated() {
            guard let binding else { continue }
            guard slot < enumCase.payloadTypes.count else {
                throw CBackendError(
                    message: "C 后端：匹配臂 '\(arm.caseName)' 的绑定数超过其载荷数")
            }
            let type = enumCase.payloadTypes[slot]
            try checkSlotType(type, slot: slot, decl: decl, owner: "枚举 \(enumName) 的用例 \(enumCase.name)")
            let local = declareLocal(binding)
            writer.line("\(try CTypeMap.spelling(of: type)) \(local) = \(pointer)->f\(slot);")
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
            return lookupVar(name)

        case .arrayLiteral(let elements, let type):
            return try emitArrayLiteral(elements: elements, type: type)

        case .dictLiteral(let entries, let type):
            return try emitDictLiteral(entries: entries, type: type)

        case .setLiteral(let elements, let type):
            return try emitSetLiteral(elements: elements, type: type)

        case .tupleConstruct(_, let elements, let type):
            return try emitTupleConstruct(elements: elements, type: type)

        case .tupleIndexGet(let base, let index, let type):
            return try emitTupleIndexGet(base: base, index: index, type: type)

        case .sliceCall(let container, let start, let end, let type):
            return try emitSliceCall(container: container, start: start, end: end, type: type)

        case .lazyRefConstruct(let closure, let type):
            return try emitLazyRefConstruct(closure: closure, type: type)

        case .lazyRefValue(let handle, let type):
            return try emitLazyRefValue(handle: handle, type: type)

        case .subscriptGet(let container, let index, let type):
            return try emitSubscriptGet(container: container, index: index, type: type)

        case .lenCall(let argument):
            return try emitLen(argument)

        case .optionalConstruct(let isSome, let payload, let type):
            return try emitOptionalConstruct(isSome: isSome, payload: payload, type: type)

        case .optionalGet(let container, let index, let type):
            return try emitOptionalGet(container: container, index: index, type: type)

        case .arrayJoin(let receiver, let separator):
            return try emitArrayJoin(receiver: receiver, separator: separator)

        case .stringConcat(let lhs, let rhs):
            return try emitStringConcat(lhs: lhs, rhs: rhs)

        case .interpString(let parts):
            return try emitInterpString(parts: parts)

        case .stringCase(let isUpper, let receiver):
            return try emitStringCase(isUpper: isUpper, receiver: receiver)

        case .stringContains(let receiver, let needle):
            return try emitStringContains(receiver: receiver, needle: needle)

        case .stringSubstring(let receiver, let start, let end):
            return try emitStringSubstring(receiver: receiver, start: start, end: end)

        case .stringSplit(let receiver, let delim, let type):
            return try emitStringSplit(receiver: receiver, delim: delim, type: type)

        case .fileWrite(let path, let content):
            return try emitFileWrite(path: path, content: content, append: false)

        case .fileAppend(let path, let content):
            return try emitFileWrite(path: path, content: content, append: true)

        case .fileRead(let path):
            return try emitFileRead(path: path)

        case .binary(let op, let lhs, let rhs, _):
            // min/max 是 I32 上的选择，不是运算符：两侧各求值一次，再比一次 —— 与 LLVM 的 select 同形。
            if op == .minOf || op == .maxOf {
                let left = try materialize(try emitExpr(lhs), type: .i32)
                let right = try materialize(try emitExpr(rhs), type: .i32)
                return "(\(left) \(op == .minOf ? "<" : ">") \(right) ? \(left) : \(right))"
            }
            let left = try emitExpr(lhs)
            let right = try emitExpr(rhs)
            guard let spelling = Self.binarySpelling(op) else {
                throw CBackendError(message: "C 后端尚未支持的二元运算：\(op)")
            }
            return "((\(left)) \(spelling) (\(right)))"

        case .unary(let op, let operand, _):
            if op == .abs {
                // `sub 0, x` 同形：负值取反走无符号，`-INT_MIN` 在 C 里是未定义、在 LLVM 里是回绕。
                let value = try materialize(try emitExpr(operand), type: .i32)
                return "(\(value) < 0 ? (int32_t)(0u - (uint32_t)(\(value))) : \(value))"
            }
            let value = try emitExpr(operand)
            switch op {
            case .negate: return "(-(\(value)))"
            case .logicalNot: return "(!(\(value)))"
            case .bitwiseNot: return "(~(\(value)))"
            case .abs:
                throw CBackendError(message: "C 后端尚未支持的一元运算：abs")
            }

        case .call(let name, let arguments, let returnType):
            // `append` 以具名调用到达，不是专门的节点；元素装箱与别名点 retain 与下标写同规。
            if name == "Array.append" {
                return try emitArrayAppend(arguments: arguments, returnType: returnType)
            }
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
            /// 调用点的所有权：实参一律**借用** —— 被调方不 retain 也不在出口释放（形参不登记）。
            return try materializeCallReleasingArguments(
                "\(callee)(\(args.joined(separator: ", ")))", returnType: returnType, arguments: args)

        case .closureLiteral(let id, let paramNames, let paramTypes, let returnType, let captures, let body, _):
            return try emitClosureLiteral(
                id: id, paramNames: paramNames, paramTypes: paramTypes, returnType: returnType,
                captures: captures, body: body)

        case .functionValue(let functionName, _):
            return try emitFunctionValue(functionName)

        case .indirectCall(let callee, let arguments, let returnType):
            return try emitIndirectCall(callee: callee, arguments: arguments, returnType: returnType)

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
            /// 陷阱去向与 `panicStmt` 同规：消息进 stderr、退出码 1、stdout 一个字节不动。
            writer.line("bk_panic(\(text));")
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

    // MARK: - 闭包与函数值

    /// 闭包字面量：先按捕获序把外层变量的槽指针塞进 env（`malloc` 分配，与 LLVM 侧同一分配器），
    /// 再拼出 `{ code, env }`。体落成模块末尾一个独立函数，创建点只留一句取值。
    /// 注意 —— 捕获不留份额、env 不回收 —— 与 LLVM 侧逐条相同：外层槽自有其持有者，闭包只是借用。
    private func emitClosureLiteral(
        id: Int, paramNames: [String], paramTypes: [IRType], returnType: IRType?,
        captures: [IRCapture], body: IRBlock
    ) throws -> String {
        let env: String
        if captures.isEmpty {
            env = "NULL"
        } else {
            let envName = scope.registerClosureEnv(id: id, captureCount: captures.count)
            let temp = "t_\(nextTempSeq())"
            writer.line("\(envName) *\(temp) = malloc(sizeof(\(envName)));")
            for (index, capture) in captures.enumerated() {
                try scope.noteType(capture.type)
                writer.line("\(temp)->f\(index) = \(try captureAddress(capture.name));")
            }
            env = "(void *)\(temp)"
        }
        let child = try CFunctionEmitter(
            closureID: id, captures: captures, paramNames: paramNames, paramTypes: paramTypes,
            returnType: returnType, body: body, scope: scope, programBase: programBase)
        try child.emitClosureDefinition()
        let value = "t_\(nextTempSeq())"
        writer.line("PiniClosure \(value) = { (void *)pini_closure_\(id), \(env) };")
        return value
    }

    /// 捕获点要交给 env 的槽指针：本层局部取地址；已是本层的捕获就把它那一格里的指针原样传下去
    /// （再取一层地址会让内层闭包写到 env 结构体上，而不是外层变量）。
    private func captureAddress(_ name: String) throws -> String {
        for frame in scopes.reversed() {
            if let hit = frame[name] { return "(void *)&\(hit)" }
        }
        if let param = paramLocals[name] { return "(void *)&\(param)" }
        if let slot = captureSlots[name] { return slot.address }
        throw CBackendError(message: "C 后端：捕获 '\(name)' 在本层找不到可见的槽")
    }

    /// 具名函数当值用：交出适配器的地址（env 为空）。适配器补上间接调用的 env 槽，
    /// 与原函数共享同一套参数与所有权规则 —— 它不做 retain，也不在出口释放任何实参。
    private func emitFunctionValue(_ functionName: String) throws -> String {
        guard functionName != "main" else {
            throw CBackendError(message: "C 后端尚未支持：把 main 当函数值传递")
        }
        guard let target = scope.function(named: functionName), scope.defined.contains(functionName) else {
            throw CBackendError(message: "C 后端尚未支持：函数值引用了本模块之外的函数 \(functionName)")
        }
        let symbol = try scope.registerAdapter(for: target)
        let value = "t_\(nextTempSeq())"
        writer.line("PiniClosure \(value) = { (void *)\(symbol), NULL };")
        return value
    }

    /// 间接调用：从 `{ code, env }` 取出两格，按函数类型拼出具体签名再调。
    /// 实参求值一次、按位置传；`using` 形参在本 IR 里不改变调用约定（LLVM 侧同样不读它），故一律按值。
    private func emitIndirectCall(
        callee: IRExpr, arguments: [IRExpr], returnType: IRType?
    ) throws -> String {
        guard let calleeType = Self.type(of: callee), case .function(let params, _, _) = calleeType else {
            throw CBackendError(message: "C 后端：间接调用的被调值不是函数类型")
        }
        guard params.count == arguments.count else {
            throw CBackendError(
                message: "C 后端：间接调用给了 \(arguments.count) 个实参，函数类型要 \(params.count) 个")
        }
        let signature = try closureSignature(params: params, returnType: returnType)
        let closure = try materialize(try emitExpr(callee), type: calleeType)
        var callArguments = ["\(closure).env"]
        var argumentTexts: [String] = []
        for (index, argument) in arguments.enumerated() {
            try scope.noteType(params[index])
            let text = try emitExpr(argument)
            argumentTexts.append(text)
            callArguments.append(text)
        }
        if let returnType { try scope.noteType(returnType) }
        let call = "((\(signature))\(closure).code)(\(callArguments.joined(separator: ", ")))"
        return try materializeCallReleasingArguments(
            call, returnType: returnType, arguments: argumentTexts)
    }

    /// 间接调用点的函数指针类型：首参恒为 env（与 LLVM 的 `call ret code(ptr env, args...)` 同形）。
    private func closureSignature(params: [IRType], returnType: IRType?) throws -> String {
        var parts = ["void *"]
        for type in params { parts.append(try CTypeMap.spelling(of: type)) }
        let ret = try returnType.map { try CTypeMap.spelling(of: $0) } ?? "void"
        return "\(ret) (*)(\(parts.joined(separator: ", ")))"
    }

    /// 名义箱的构造：分配器写四格头，随后逐字段落初值（无默认值时落零）。
    /// 注意 —— 与 LLVM 侧同规：默认值直接落槽，不经过 `emitValueForStorage` —— 那边也没绕。
    private func emitConstruct(_ type: IRType) throws -> String {
        guard case .nominal(let name, _) = type, let decl = scope.typeDecl(named: name) else {
            throw CBackendError(message: "C 后端：构造了未声明的名义类型 \(CTypeMap.label(of: type))")
        }
        scope.markUsed(name)
        let aggregate = CTypeMap.aggregateName(name)
        let temp = "t_\(nextTempSeq())"
        writer.line(
            "\(aggregate) *\(temp) = bk_nominal_alloc(sizeof(\(aggregate)), \(scope.typeID(of: type)));")
        /// 新箱起始 +1，此刻没有持有者 ⇒ 入账，等持有位置接管或在调用点就地还。
        adoptOwnedBox(temp, type: type)
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
        /// 新箱起始 +1，此刻没有持有者 ⇒ 入账，等持有位置接管或在调用点就地还。
        adoptOwnedBox(temp, type: type)
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
        case .array(let elementType):
            try emitSequencePrint(
                handle: try materialize(text, type: type), elementType: elementType,
                open: "[", close: "]", lengthSymbol: "bk_array_len", accessor: "bk_array_get")
        case .set(let elementType):
            try emitSequencePrint(
                handle: try materialize(text, type: type), elementType: elementType,
                open: "{", close: "}", lengthSymbol: "bk_set_len", accessor: "bk_set_at")
        case .dict(let keyType, let valueType):
            try emitDictPrint(
                handle: try materialize(text, type: type), keyType: keyType, valueType: valueType)
        case .optional(let wrapped):
            try emitOptionalPrint(text, wrapped: wrapped)
        case .tuple(let labels, let fieldTypes):
            try emitTuplePrint(try materialize(text, type: type), labels: labels, fieldTypes: fieldTypes)
        default:
            throw CBackendError(message: "C 后端尚未支持的打印类型：\(CTypeMap.label(of: type))")
        }
    }

    /// `[v1, v2]`，带标签的字段写成 `label: v` —— 与解释器 stringify、LLVM 的 `.tuple` 分支同形。
    /// 元素之间一个 `", "`，标签与值之间一个 `": "`，两侧方括号各一次。
    private func emitTuplePrint(_ local: String, labels: [String?], fieldTypes: [IRType]) throws {
        writer.line("printf(\"%s\", \(scope.registerString("[")));")
        for (index, fieldType) in fieldTypes.enumerated() {
            if index > 0 { writer.line("printf(\"%s\", \(scope.registerString(", ")));") }
            if index < labels.count, let label = labels[index] {
                writer.line("printf(\"%s\", \(scope.registerString("\(label): ")));")
            }
            try emitValuePrint("\(local).f\(index)", type: fieldType)
        }
        writer.line("printf(\"%s\", \(scope.registerString("]")));")
    }

    /// `[a, b]` / `{a, b}`：长度取一次、逐下标取元素、元素之间一个 `", "` —— 与解释器 stringify 同形。
    private func emitSequencePrint(
        handle: String, elementType: IRType, open: String, close: String,
        lengthSymbol: String, accessor: String
    ) throws {
        writer.line("printf(\"%s\", \(scope.registerString(open)));")
        let count = "t_\(nextTempSeq())"
        writer.line("int32_t \(count) = \(lengthSymbol)(\(handle));")
        let index = "i_\(nextTempSeq())"
        writer.open("for (int32_t \(index) = 0; \(index) < \(count); \(index) = \(index) + 1)")
        writer.open("if (\(index) > 0)")
        writer.line("printf(\"%s\", \(scope.registerString(", ")));")
        writer.close()
        let box = "b_\(nextTempSeq())"
        writer.line("void *\(box) = \(accessor)(\(handle), \(index));")
        try emitValuePrint(try boxLoad(box, type: elementType), type: elementType)
        writer.close()
        writer.line("printf(\"%s\", \(scope.registerString(close)));")
    }

    /// `{k: v, ...}`：键与值按下标成对取出，各自按自己的类型递归打印。
    private func emitDictPrint(handle: String, keyType: IRType, valueType: IRType) throws {
        writer.line("printf(\"%s\", \(scope.registerString("{")));")
        let count = "t_\(nextTempSeq())"
        writer.line("int32_t \(count) = bk_dict_len(\(handle));")
        let index = "i_\(nextTempSeq())"
        writer.open("for (int32_t \(index) = 0; \(index) < \(count); \(index) = \(index) + 1)")
        writer.open("if (\(index) > 0)")
        writer.line("printf(\"%s\", \(scope.registerString(", ")));")
        writer.close()
        let keyBox = "b_\(nextTempSeq())"
        writer.line("void *\(keyBox) = bk_dict_key_at(\(handle), \(index));")
        try emitValuePrint(try boxLoad(keyBox, type: keyType), type: keyType)
        writer.line("printf(\"%s\", \(scope.registerString(": ")));")
        let valueBox = "b_\(nextTempSeq())"
        writer.line("void *\(valueBox) = bk_dict_val_at(\(handle), \(index));")
        try emitValuePrint(try boxLoad(valueBox, type: valueType), type: valueType)
        writer.close()
        writer.line("printf(\"%s\", \(scope.registerString("}")));")
    }

    /// `some(v)` / `none`：按标签分支，载荷按声明类型递归打印。
    private func emitOptionalPrint(_ text: String, wrapped: IRType) throws {
        let local = try materialize(text, type: .optional(wrapped: wrapped))
        writer.open("if (\(local).tag == 0)")
        writer.line("printf(\"%s\", \(scope.registerString("some(")));")
        try emitValuePrint("\(local).value", type: wrapped)
        writer.line("printf(\"%s\", \(scope.registerString(")")));")
        writer.elseOpen()
        writer.line("printf(\"%s\", \(scope.registerString("none")));")
        writer.close()
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
        /// 打印是消费点：临时值印完即还，变量 / 字段的份额不在账上 ⇒ 那一条不动作。
        try emitOwnedTemporaryRelease(text)
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

    // MARK: - 容器族与 Optional

    /// 容器元素的装箱 ABI：与 LLVM 侧的 `arrayElementABI` 逐格对齐。宽度与 tag 必须一致，
    /// 否则运行时深拷 / 释放会按错的族处理同一个 box。
    private func elementABI(_ type: IRType) throws -> (spelling: String, width: Int, tag: Int32) {
        switch type {
        case .i32: return ("int32_t", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("bool", 1, 2)
        case .string, .char: return ("char *", 8, 3)
        case .array, .dict, .set: return ("void *", 8, 4)
        default:
            throw CBackendError(message: "C 后端尚未支持的容器元素类型：\(CTypeMap.label(of: type))")
        }
    }

    private static func isContainer(_ type: IRType) -> Bool {
        switch type {
        case .array, .dict, .set: return true
        default: return false
        }
    }

    /// 读一个运行时 box：box 是 `void *`，值按自己的拼写重解释。对齐由运行时分配器保证。
    private func boxLoad(_ box: String, type: IRType) throws -> String {
        "*(\(try CTypeMap.spelling(of: type)) *)\(box)"
    }

    /// 把值放进一个可取址的临时变量：运行时的 `*_set` / `*_add` 都要「值的地址 + 宽度」。
    private func boxValue(_ text: String, type: IRType) throws -> String {
        let local = "b_\(nextTempSeq())"
        writer.line("\(try CTypeMap.spelling(of: type)) \(local) = \(text);")
        return local
    }

    /// 别名点留份额。临时值被箱接管，不再有动作 —— 与 LLVM 侧 `emitRetainIfAliased` 同判据。
    private func emitRetainIfAliased(_ node: IRExpr, local: String, type: IRType) throws {
        guard Self.yieldsAlias(node), let retain = try retainSymbol(for: type) else { return }
        writer.line("\(retain)(\(local));")
    }

    /// 负值尾计数：`i < 0 ? count + i : i`。下标在调用点先求值、这里只落临时变量，保证只求值一次。
    private func emitTailCountIndex(_ indexText: String, count: String) throws -> String {
        let raw = "t_\(nextTempSeq())"
        writer.line("int32_t \(raw) = (int32_t)(\(indexText));")
        let adjusted = "t_\(nextTempSeq())"
        writer.line("int32_t \(adjusted) = \(count) + \(raw);")
        let effective = "t_\(nextTempSeq())"
        writer.line("int32_t \(effective) = (\(raw) < 0) ? \(adjusted) : \(raw);")
        return effective
    }

    /// `[e1, e2, ...]`：先造句柄，逐元素装箱写进第 i 格。`bk_array_set` 返回的句柄必须接住，
    /// 它可能与入参不同（COW 分裂）。
    private func emitArrayLiteral(elements: [IRExpr], type: IRType) throws -> String {
        guard case .array(let elementType) = type else {
            throw CBackendError(message: "C 后端：数组字面量的类型不是 Array（\(CTypeMap.label(of: type))）")
        }
        let (spelling, width, tag) = try elementABI(elementType)
        let handle = "t_\(nextTempSeq())"
        writer.line("void *\(handle) = bk_array_create(\(elements.count));")
        /// 新句柄起始 shares == 1，此刻没有持有者 ⇒ 入账，等持有位置接管或在调用点就地还。
        adoptOwnedBox(handle, type: type)
        for (index, element) in elements.enumerated() {
            let box = "b_\(nextTempSeq())"
            writer.line("\(spelling) \(box) = \(try emitExpr(element));")
            try emitRetainIfAliased(element, local: box, type: elementType)
            writer.line("\(handle) = bk_array_set(\(handle), \(index), (void *)&\(box), \(width), \(tag));")
        }
        return handle
    }

    /// `[k = v, ...]`：空字典起手，逐条写入。键与值各自按自己的类型装箱。
    private func emitDictLiteral(entries: [IRDictEntry], type: IRType) throws -> String {
        guard case .dict(let keyType, let valueType) = type else {
            throw CBackendError(message: "C 后端：字典字面量的类型不是 Dictionary（\(CTypeMap.label(of: type))）")
        }
        let (_, keyWidth, keyTag) = try elementABI(keyType)
        let (valueSpelling, valueWidth, valueTag) = try elementABI(valueType)
        let handle = "t_\(nextTempSeq())"
        writer.line("void *\(handle) = bk_dict_create();")
        /// 新句柄起始 shares == 1，此刻没有持有者 ⇒ 入账，等持有位置接管或在调用点就地还。
        adoptOwnedBox(handle, type: type)
        for entry in entries {
            let key = try boxValue(try emitExpr(entry.key), type: keyType)
            try emitRetainIfAliased(entry.key, local: key, type: keyType)
            let value = "b_\(nextTempSeq())"
            writer.line("\(valueSpelling) \(value) = \(try emitExpr(entry.value));")
            try emitRetainIfAliased(entry.value, local: value, type: valueType)
            writer.line(
                "\(handle) = bk_dict_set(\(handle), (void *)&\(key), \(keyWidth), \(keyTag),"
                + " (void *)&\(value), \(valueWidth), \(valueTag));")
        }
        return handle
    }

    /// `{e1, e2, ...}`：保序去重由运行时做，本层只逐元素 `bk_set_add`。
    private func emitSetLiteral(elements: [IRExpr], type: IRType) throws -> String {
        guard case .set(let elementType) = type else {
            throw CBackendError(message: "C 后端：集合字面量的类型不是 Set（\(CTypeMap.label(of: type))）")
        }
        let (spelling, width, tag) = try elementABI(elementType)
        let handle = "t_\(nextTempSeq())"
        writer.line("void *\(handle) = bk_set_create();")
        /// 新句柄起始 shares == 1，此刻没有持有者 ⇒ 入账，等持有位置接管或在调用点就地还。
        adoptOwnedBox(handle, type: type)
        for element in elements {
            let box = "b_\(nextTempSeq())"
            writer.line("\(spelling) \(box) = \(try emitExpr(element));")
            try emitRetainIfAliased(element, local: box, type: elementType)
            writer.line("\(handle) = bk_set_add(\(handle), (void *)&\(box), \(width), \(tag));")
        }
        return handle
    }

    // MARK: - 元组 / 切片 / LazyRef

    /// `(a, b)`：先落一个按值结构体，再按序写字段。逐个赋值的顺序与 LLVM 逐条 `insertvalue` 相同 ——
    /// 元素表达式带副作用时，顺序就是语义。注意 —— 不在这里 retain：LLVM 也不 retain，元组不持有份额。
    private func emitTupleConstruct(elements: [IRExpr], type: IRType) throws -> String {
        guard case .tuple(_, let fieldTypes) = type else {
            throw CBackendError(message: "C 后端：元组构造的类型不是 Tuple（\(CTypeMap.label(of: type))）")
        }
        guard elements.count == fieldTypes.count else {
            throw CBackendError(
                message: "C 后端：元组给了 \(elements.count) 个元素，类型要 \(fieldTypes.count) 个")
        }
        let name = try scope.registerTuple(type)
        let temp = "t_\(nextTempSeq())"
        writer.line("\(name) \(temp);")
        for (index, element) in elements.enumerated() {
            writer.line("\(temp).f\(index) = \(try emitExpr(element));")
        }
        return temp
    }

    /// `base.label`：按声明序取字段。基址先落临时变量，保证带副作用的基址只求值一次。
    private func emitTupleIndexGet(base: IRExpr, index: Int, type: IRType) throws -> String {
        guard let baseType = Self.type(of: base), case .tuple(_, let fieldTypes) = baseType else {
            throw CBackendError(message: "C 后端：元组读字段的基址不是 Tuple")
        }
        guard index >= 0, index < fieldTypes.count else {
            throw CBackendError(message: "C 后端：元组字段下标 \(index) 超出 \(fieldTypes.count) 个字段")
        }
        guard fieldTypes[index].llvmSpelling == type.llvmSpelling else {
            throw CBackendError(
                message: "C 后端：元组字段 \(index) 的类型与读取处不一致"
                    + "（\(CTypeMap.label(of: type)) vs \(CTypeMap.label(of: fieldTypes[index]))）")
        }
        _ = try scope.registerTuple(baseType)
        let local = try materialize(try emitExpr(base), type: baseType)
        return "\(local).f\(index)"
    }

    /// `c.slice(lo, hi)`：数组是组合出来的（create / 逐格 get+set），字符串整段交给运行时段。
    /// 负值尾计数与两端夹取都在本层做 —— 与 LLVM 的 select 链同一个顺序，夹在谁之后决定结果。
    private func emitSliceCall(
        container: IRExpr, start: IRExpr, end: IRExpr, type: IRType
    ) throws -> String {
        let containerText = try emitExpr(container)
        switch type {
        case .array(let elementType):
            guard let containerType = Self.type(of: container) else {
                throw CBackendError(message: "C 后端：切片的容器没有携带类型")
            }
            let (_, width, tag) = try elementABI(elementType)
            let raw = try materialize(containerText, type: containerType)
            let count = "t_\(nextTempSeq())"
            writer.line("int32_t \(count) = bk_array_len(\(raw));")
            let low = try resolveSliceBound(start, count: count, defaultValue: "0")
            let high = try resolveSliceBound(end, count: count, defaultValue: count)
            let length = "t_\(nextTempSeq())"
            writer.line("int32_t \(length) = \(high) - \(low);")
            let handle = "t_\(nextTempSeq())"
            writer.line("void *\(handle) = bk_array_create(\(length));")
            let index = "i_\(nextTempSeq())"
            writer.open("for (int32_t \(index) = 0; \(index) < \(length); \(index) = \(index) + 1)")
            let box = "b_\(nextTempSeq())"
            writer.line("void *\(box) = bk_array_get(\(raw), \(low) + \(index));")
            /// 嵌套容器元素：源数组仍持有它那一份，故新数组额外留一份 —— 判据与 LLVM 逐字相同。
            if case .array = elementType {
                writer.line("bk_handle_retain(*(void **)\(box));")
            }
            writer.line(
                "\(handle) = bk_array_set(\(handle), \(index), \(box), \(width), \(tag));")
            writer.close()
            return handle
        case .string:
            /// 开界传标志位而不传哨兵：`s[-1:]` 合法，拿 -1 当「开」会与真实下标撞车；开界也不求值。
            let startOpen = Self.sliceBoundIsOpen(start)
            let endOpen = Self.sliceBoundIsOpen(end)
            let startOperand = startOpen ? "0" : "(int32_t)(\(try emitExpr(start)))"
            let endOperand = endOpen ? "0" : "(int32_t)(\(try emitExpr(end)))"
            let sliced = "t_\(nextTempSeq())"
            writer.line(
                "char *\(sliced) = bk_string_slice(\(containerText), \(startOpen ? 0 : 1), \(startOperand),"
                    + " \(endOpen ? 0 : 1), \(endOperand));")
            return sliced
        default:
            throw CBackendError(
                message: "C 后端尚未支持的切片类型：\(CTypeMap.label(of: type))")
        }
    }

    /// 切片的界是开界吗。判据是语法节点（`optionalConstruct` 的 `isSome == false`）而不是值 ⇒
    /// 发射期即可定死，与 LLVM 的 `sliceBoundIsOpen` 同一条判据。
    private static func sliceBoundIsOpen(_ bound: IRExpr) -> Bool {
        if case .optionalConstruct(let isSome, _, _) = bound, !isSome { return true }
        return false
    }

    /// 一个数组切片界：缺省取默认值，整数负值转尾计数，再夹到 `[0, count]` —— 三步顺序不能换。
    ///  注意 —— 字符串切片不走这里：它的界与夹取全在运行时段（`bk_string_slice`）。
    private func resolveSliceBound(
        _ bound: IRExpr, count: String, defaultValue: String
    ) throws -> String {
        if case .optionalConstruct(let isSome, _, _) = bound, !isSome { return defaultValue }
        let raw = "t_\(nextTempSeq())"
        writer.line("int32_t \(raw) = (int32_t)(\(try emitExpr(bound)));")
        let adjusted = "t_\(nextTempSeq())"
        writer.line("int32_t \(adjusted) = \(count) + \(raw);")
        let tailCounted = "t_\(nextTempSeq())"
        writer.line("int32_t \(tailCounted) = (\(raw) < 0) ? \(adjusted) : \(raw);")
        let floored = "t_\(nextTempSeq())"
        writer.line("int32_t \(floored) = (\(tailCounted) < 0) ? 0 : \(tailCounted);")
        let clamped = "t_\(nextTempSeq())"
        writer.line("int32_t \(clamped) = (\(floored) > \(count)) ? \(count) : \(floored);")
        return clamped
    }

    /// LazyRef 的元素装箱 ABI（字节数 + 元素 tag）。与容器的 `elementABI` 差在字符串：
    /// 这里用裸指针 tag 4 而不是数组族的 3 —— 字符串没有 share 计数，按句柄回收会踩坏账。
    private func lazyRefElemABI(_ type: IRType) throws -> (spelling: String, bytes: Int, tag: Int) {
        switch type {
        case .i32: return ("int32_t", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("bool", 1, 2)
        // Char 与 String 表示相同，故同一个 tag：一个字素同样没有 share 计数。
        case .string, .char: return ("char *", 8, 4)
        default:
            throw CBackendError(
                message: "C 后端尚未支持的 LazyRef 元素类型：\(CTypeMap.label(of: type))")
        }
    }

    /// `LazyRef<T>(closure)`：取出闭包的两格交给运行时段，换回不透明句柄。
    /// 句柄的回收不在此处记账 —— LLVM 侧同样不产 `bk_lazyref_destroy` 调用点。
    private func emitLazyRefConstruct(closure: IRExpr, type: IRType) throws -> String {
        guard case .lazyRef(let element) = type else {
            throw CBackendError(message: "C 后端：LazyRef 构造的类型不是 LazyRef")
        }
        let (_, bytes, tag) = try lazyRefElemABI(element)
        let closureType = Self.type(of: closure) ?? .function(params: [], returnType: nil, usingIndices: [])
        try scope.noteType(closureType)
        let wrapper = try scope.registerLazyRefWrapper(element: element)
        let value = try materialize(try emitExpr(closure), type: closureType)
        let handle = "t_\(nextTempSeq())"
        writer.line(
            "void *\(handle) = bk_lazyref_create((void *)\(wrapper), \(value).code, \(value).env,"
                + " \(bytes), \(tag));")
        return handle
    }

    /// `r.value`：运行时段保证「恰一次」初始化，交回元素盒；本层只把元素读出来。
    private func emitLazyRefValue(handle: IRExpr, type: IRType) throws -> String {
        guard let handleType = Self.type(of: handle), case .lazyRef = handleType else {
            throw CBackendError(message: "C 后端：LazyRef 取值的手柄不是 LazyRef 类型")
        }
        let box = "b_\(nextTempSeq())"
        writer.line("void *\(box) = bk_lazyref_value(\(try emitExpr(handle)));")
        return try boxLoad(box, type: type)
    }

    /// 下标读。字典按键、数组按下标；负数下标从尾部计数（安全断言通道留在运行时里）。
    private func emitSubscriptGet(container: IRExpr, index: IRExpr, type: IRType) throws -> String {
        guard let containerType = Self.type(of: container) else {
            throw CBackendError(message: "C 后端：下标读的容器没有携带类型")
        }
        switch containerType {
        case .dict(let keyType, _):
            let (_, keyWidth, keyTag) = try elementABI(keyType)
            let handle = try materialize(try emitExpr(container), type: containerType)
            let key = try boxValue(try emitExpr(index), type: keyType)
            let box = "b_\(nextTempSeq())"
            writer.line("void *\(box) = bk_dict_get(\(handle), (void *)&\(key), \(keyWidth), \(keyTag));")
            return try boxLoad(box, type: type)
        case .array:
            let handle = try materialize(try emitExpr(container), type: containerType)
            let indexText = try emitExpr(index)
            let count = "t_\(nextTempSeq())"
            writer.line("int32_t \(count) = bk_array_len(\(handle));")
            let effective = try emitTailCountIndex(indexText, count: count)
            let box = "b_\(nextTempSeq())"
            writer.line("void *\(box) = bk_array_get(\(handle), \(effective));")
            return try boxLoad(box, type: type)
        default:
            throw CBackendError(
                message: "C 后端尚未支持的取下标的容器类型：\(CTypeMap.label(of: containerType))")
        }
    }

    /// 下标写（COW 契约）：容器句柄 → 值（别名点 retain）→ `bk_*_set` → 把分裂出的句柄写回槽。
    /// 注意 —— 不回写 ⇒ 新句柄没人接住 ⇒ 这次写会静默丢失。
    private func emitSubscriptStore(
        container: IRExpr, index: IRExpr, value: IRExpr, elementType: IRType
    ) throws {
        guard case .load(let name, let slotType) = container else {
            throw CBackendError(
                message: "C 后端尚未支持：非变量槽容器的下标写（嵌套或字段容器）")
        }
        let local = lookupVar(name)
        if case .dict(let keyType, let valueType) = slotType {
            let (_, keyWidth, keyTag) = try elementABI(keyType)
            let (valueSpelling, valueWidth, valueTag) = try elementABI(valueType)
            let key = try boxValue(try emitExpr(index), type: keyType)
            let box = "b_\(nextTempSeq())"
            writer.line("\(valueSpelling) \(box) = \(try emitExpr(value));")
            try emitRetainIfAliased(value, local: box, type: valueType)
            writer.line(
                "\(local) = bk_dict_set(\(local), (void *)&\(key), \(keyWidth), \(keyTag),"
                + " (void *)&\(box), \(valueWidth), \(valueTag));")
            return
        }
        let (spelling, width, tag) = try elementABI(elementType)
        let indexText = "t_\(nextTempSeq())"
        writer.line("int32_t \(indexText) = (int32_t)(\(try emitExpr(index)));")
        let box = "b_\(nextTempSeq())"
        writer.line("\(spelling) \(box) = \(try emitExpr(value));")
        try emitRetainIfAliased(value, local: box, type: elementType)
        writer.line("\(local) = bk_array_set(\(local), \(indexText), (void *)&\(box), \(width), \(tag));")
    }

    /// `len(x)`：三个容器族各问自己的长度；字符串按字素簇计（运行时段同一份实现）。
    private func emitLen(_ argument: IRExpr) throws -> String {
        guard let type = Self.type(of: argument) else {
            throw CBackendError(message: "C 后端：len 的实参没有携带类型")
        }
        let symbol: String
        switch type {
        case .dict: symbol = "bk_dict_len"
        case .set: symbol = "bk_set_len"
        case .array: symbol = "bk_array_len"
        case .string, .char: symbol = "bk_string_count"
        default:
            throw CBackendError(message: "C 后端尚未支持的 len 实参类型：\(CTypeMap.label(of: type))")
        }
        let value = try materialize(try emitExpr(argument), type: type)
        let count = "t_\(nextTempSeq())"
        writer.line("int32_t \(count) = \(symbol)(\(value));")
        return count
    }

    /// `Optional.some(v)` / `Optional.none`：标签 0 = some、1 = none，与 LLVM 侧同一编号。
    /// 载荷是裸值插入，不在这里留份额（与 LLVM 侧同一个插入点）。
    private func emitOptionalConstruct(isSome: Bool, payload: IRExpr?, type: IRType) throws -> String {
        guard case .optional(let wrapped) = type else {
            throw CBackendError(message: "C 后端：Optional 构造的类型不是 Optional（\(CTypeMap.label(of: type))）")
        }
        let temp = "t_\(nextTempSeq())"
        writer.line("\(try scope.registerOptional(type)) \(temp);")
        writer.line("\(temp).tag = \(isSome ? 0 : 1);")
        if isSome, let payload {
            writer.line("\(temp).value = \(try emitExpr(payload));")
        } else {
            writer.line("\(temp).value = \(try CTypeMap.zeroLiteral(of: wrapped));")
        }
        return temp
    }

    /// `arr.get(i)` / `s.get(i)`：容错读。界内给 some(元素)、界外（含尾计数后仍越界）给 none。
    /// 字符串的「字符」= 字素簇（与 `len` 同一定义），取值走运行时段，与数组同一个夹取顺序。
    private func emitOptionalGet(container: IRExpr, index: IRExpr, type: IRType) throws -> String {
        guard case .optional(let wrapped) = type else {
            throw CBackendError(message: "C 后端：容错读的类型不是 Optional（\(CTypeMap.label(of: type))）")
        }
        guard let containerType = Self.type(of: container) else {
            throw CBackendError(message: "C 后端：容错读的容器没有携带类型")
        }
        let isString = containerType.isStringFaced
        switch containerType {
        case .string, .char, .array: break
        default:
            throw CBackendError(
                message: "C 后端尚未支持的容错读容器：\(CTypeMap.label(of: containerType))")
        }
        let handle = try materialize(try emitExpr(container), type: containerType)
        let indexText = try emitExpr(index)
        let count = "t_\(nextTempSeq())"
        writer.line(
            "int32_t \(count) = \(isString ? "bk_string_count" : "bk_array_len")(\(handle));")
        let effective = try emitTailCountIndex(indexText, count: count)
        let result = "t_\(nextTempSeq())"
        writer.line("\(try scope.registerOptional(type)) \(result);")
        writer.open("if (\(effective) >= 0 && \(effective) < \(count))")
        let box = "b_\(nextTempSeq())"
        if isString {
            // 到此 `effective` 必在 `[0, count)` ⇒ 运行时段不会 panic（容错通道）。
            writer.line("char *\(box) = bk_string_char_at(\(handle), \(effective));")
            writer.line("\(result).tag = 0;")
            writer.line("\(result).value = \(box);")
        } else {
            writer.line("void *\(box) = bk_array_get(\(handle), \(effective));")
            writer.line("\(result).tag = 0;")
            writer.line("\(result).value = \(try boxLoad(box, type: wrapped));")
        }
        writer.elseOpen()
        writer.line("\(result).tag = 1;")
        writer.line("\(result).value = \(try CTypeMap.zeroLiteral(of: wrapped));")
        writer.close()
        return result
    }

    /// `arr.append(x)`：产出**新**句柄，输入句柄与其内容都不动；元素 ABI 与下标写同一张表。
    private func emitArrayAppend(arguments: [IRExpr], returnType: IRType?) throws -> String {
        guard arguments.count == 2, case .array(let elementType)? = returnType else {
            throw CBackendError(message: "C 后端：append 需要接收者加一个元素，且结果类型是 Array")
        }
        let (spelling, width, tag) = try elementABI(elementType)
        let handle = try materialize(try emitExpr(arguments[0]), type: .array(element: elementType))
        let box = "b_\(nextTempSeq())"
        writer.line("\(spelling) \(box) = \(try emitExpr(arguments[1]));")
        try emitRetainIfAliased(arguments[1], local: box, type: elementType)
        let next = "t_\(nextTempSeq())"
        writer.line("void *\(next) = bk_array_append(\(handle), (void *)&\(box), \(width), \(tag));")
        return next
    }

    /// `arr.join(sep)`：逐元素 strcat 进栈缓冲，交出前复制到堆 —— 结果会离开本帧。
    /// 注意 —— 元素必须是字符串面：解释器对任意元素先 stringify，本层只搬裸 C 串，别的类型一律拒绝。
    private func emitArrayJoin(receiver: IRExpr, separator: IRExpr) throws -> String {
        guard let receiverType = Self.type(of: receiver), case .array(let elementType) = receiverType,
            elementType.isStringFaced
        else {
            throw CBackendError(message: "C 后端尚未支持：非字符串元素数组的 join（元素要先 stringify）")
        }
        let handle = try materialize(try emitExpr(receiver), type: receiverType)
        let sep = try materialize(try emitExpr(separator), type: .string)
        let buffer = "c_\(nextTempSeq())"
        writer.line("char \(buffer)[4096];")
        writer.line("\(buffer)[0] = 0;")
        let count = "t_\(nextTempSeq())"
        writer.line("int32_t \(count) = bk_array_len(\(handle));")
        let index = "i_\(nextTempSeq())"
        writer.open("for (int32_t \(index) = 0; \(index) < \(count); \(index) = \(index) + 1)")
        writer.open("if (\(index) > 0)")
        writer.line("strcat(\(buffer), \(sep));")
        writer.close()
        let box = "b_\(nextTempSeq())"
        writer.line("void *\(box) = bk_array_get(\(handle), \(index));")
        writer.line("strcat(\(buffer), \(try boxLoad(box, type: .string)));")
        writer.close()
        let dup = "t_\(nextTempSeq())"
        writer.line("char *\(dup) = bk_str_dup(\(buffer));")
        return dup
    }

    /// `for (pattern,) in iterable`：长度取一次、每轮按下标取元素。模式绑定是持有者，
    /// 一轮一份份额、body 尾按逆序释放 —— 与 LLVM 侧的种子帧同序。
    private func emitForIn(
        pattern: [String], elementTypes: [IRType], kind: IRForIterableKind,
        iterable: IRExpr, body: IRBlock, step: IRBlock?
    ) throws {
        guard let iterableType = Self.type(of: iterable) else {
            throw CBackendError(message: "C 后端：for-in 的被迭代值没有携带类型")
        }
        let lengthSymbol: String
        switch kind {
        case .array: lengthSymbol = "bk_array_len"
        case .set: lengthSymbol = "bk_set_len"
        case .dict: lengthSymbol = "bk_dict_len"
        }
        let handle = try materialize(try emitExpr(iterable), type: iterableType)
        let count = "t_\(nextTempSeq())"
        writer.line("int32_t \(count) = \(lengthSymbol)(\(handle));")
        let index = "i_\(nextTempSeq())"
        writer.line("int32_t \(index) = 0;")

        let info = scan(body, nesting: 0, direct: false)
        let stepInfo = scan(step, nesting: 0, direct: false)
        let id = nextLabelSeq()
        let header = "for_inc_\(id)"
        let stepLabel = "for_step_\(id)"
        let exit = "for_end_\(id)"
        frames.append(
            Frame(
                exit: exit, header: header, isLoop: true, needsExit: info.brk || stepInfo.brk,
                needsHeader: true, continueLabel: step != nil ? stepLabel : header,
                releaseBase: releaseFrames.count, deferBase: deferFrames.count))

        writer.open("for (;;)")
        writer.line("if (!(\(index) < \(count))) break;")
        scopes.append([:])
        var seeded: [ReleaseEntry] = []
        for (position, name) in pattern.enumerated() {
            guard name != "_" else { continue }
            guard position < elementTypes.count else {
                throw CBackendError(message: "C 后端：for-in 的模式第 \(position) 位没有元素类型")
            }
            let elementType = elementTypes[position]
            let accessor = try forInAccessor(kind: kind, position: position)
            let local = declareLocal(name)
            let box = "b_\(nextTempSeq())"
            writer.line("void *\(box) = \(accessor)(\(handle), \(index));")
            writer.line("\(try CTypeMap.spelling(of: elementType)) \(local) = \(try boxLoad(box, type: elementType));")
            // 只有容器元素进账本：与 LLVM 侧同一个判据（`collectionDestroySymbol` 只覆盖三族）。
            if Self.isContainer(elementType) { seeded.append(ReleaseEntry(local: local, type: elementType)) }
        }
        releaseFrames.append(seeded)
        try emitBlock(body)
        if !terminated { try emitReleases(downTo: releaseFrames.count - 1) }
        releaseFrames.removeLast()
        if let step {
            terminated = false
            writer.line("\(stepLabel): ;")
            frames.append(
                Frame(
                    exit: exit, header: header, isLoop: true, needsExit: stepInfo.brk,
                    needsHeader: true, continueLabel: header,
                    releaseBase: releaseFrames.count, deferBase: deferFrames.count))
            try emitBlock(step)
            frames.removeLast()
        }
        terminated = false
        writer.line("\(header):")
        writer.line("\(index) = \(index) + 1;")
        writer.close()
        frames.removeLast()
        scopes.removeLast()
        if info.brk || stepInfo.brk { writer.line("\(exit): ;") }
        terminated = false
    }

    private func forInAccessor(kind: IRForIterableKind, position: Int) throws -> String {
        switch kind {
        case .array: return "bk_array_get"
        case .set: return "bk_set_at"
        case .dict: return position == 0 ? "bk_dict_key_at" : "bk_dict_val_at"
        }
    }

    // MARK: - 字符串族与文件 IO

    /// `s1 + s2`：两次 `strlen` 后分配一条带计数头的新串，`strcpy` + `strcat` 拼进去 —— 与 LLVM 侧同形。
    /// 两个操作数到此用完（只被读过，没有持有者接管），在账上的就地还；新串入账，等持有位置接管。
    private func emitStringConcat(lhs: IRExpr, rhs: IRExpr) throws -> String {
        let left = try emitExpr(lhs)
        let right = try emitExpr(rhs)
        let buffer = "t_\(nextTempSeq())"
        writer.line(
            "char *\(buffer) = bk_str_alloc("
                + "(int64_t)strlen(\(left)) + (int64_t)strlen(\(right)) + 1);")
        writer.line("strcpy(\(buffer), \(left));")
        writer.line("strcat(\(buffer), \(right));")
        emitOwnedStringRelease(left)
        emitOwnedStringRelease(right)
        adoptOwnedString(buffer)
        return buffer
    }

    /// `"x=\(e)"`：片段各自转成 C 串，`strcat` 进栈缓冲；结果要离开本帧 ⇒ 交出前复制到堆并入账。
    private func emitInterpString(parts: [IRExpr]) throws -> String {
        let buffer = "c_\(nextTempSeq())"
        writer.line("char \(buffer)[4096];")
        writer.line("\(buffer)[0] = 0;")
        for part in parts {
            let piece = try emitStringPiece(part)
            writer.line("strcat(\(buffer), \(piece));")
        }
        let copy = "t_\(nextTempSeq())"
        writer.line("char *\(copy) = bk_str_dup(\(buffer));")
        adoptOwnedString(copy)
        return copy
    }

    /// 一个插值片段的 C 串。字符串面直接给；别的类型走 `stringify`（与 print 同一套渲染规则）。
    private func emitStringPiece(_ part: IRExpr) throws -> String {
        guard let type = Self.type(of: part) else {
            throw CBackendError(message: "C 后端：插值片段没有携带类型，无法选定渲染")
        }
        let text = try emitExpr(part)
        switch type {
        case .string, .char: return text
        default: return try stringify(text, type: type)
        }
    }

    /// 值 → 文本，镜像 LLVM 侧 `stringifyValue`：标量落一块栈缓冲，数组按 `[a, b]` 递归。
    /// 注意 —— 规则必须与 `emitValuePrint` 一致，否则插值与 print 会给出两种文本。
    private func stringify(_ text: String, type: IRType) throws -> String {
        switch type {
        case .i32:
            let buffer = "c_\(nextTempSeq())"
            writer.line("char \(buffer)[32];")
            writer.line("snprintf(\(buffer), 32, \"%d\", \(text));")
            return buffer
        case .f64:
            // 运行时段渲染，与 `print(F64)` 同一个入口 ⇒ 定点 / 指数切换规则不会分叉。
            let rendered = "t_\(nextTempSeq())"
            writer.line("char *\(rendered) = bk_double_to_string(\(text));")
            return rendered
        case .boolean:
            return "((\(text)) ? \"true\" : \"false\")"
        case .string, .char:
            return text
        case .array(let elementType):
            let handle = try materialize(text, type: type)
            let buffer = "c_\(nextTempSeq())"
            writer.line("char \(buffer)[4096];")
            writer.line("\(buffer)[0] = 0;")
            writer.line("strcat(\(buffer), \(scope.registerString("[")));")
            let count = "t_\(nextTempSeq())"
            writer.line("int32_t \(count) = bk_array_len(\(handle));")
            let index = "i_\(nextTempSeq())"
            writer.open("for (int32_t \(index) = 0; \(index) < \(count); \(index) = \(index) + 1)")
            writer.open("if (\(index) > 0)")
            writer.line("strcat(\(buffer), \(scope.registerString(", ")));")
            writer.close()
            let box = "b_\(nextTempSeq())"
            writer.line("void *\(box) = bk_array_get(\(handle), \(index));")
            let piece = try stringify(try boxLoad(box, type: elementType), type: elementType)
            writer.line("strcat(\(buffer), \(piece));")
            writer.close()
            writer.line("strcat(\(buffer), \(scope.registerString("]")));")
            return buffer
        default:
            throw CBackendError(
                message: "C 后端尚未支持的插值片段类型：\(CTypeMap.label(of: type))")
        }
    }

    /// `s.upper()` / `s.lower()`：Unicode 语义在运行时段（逐字节 `toupper` 在非 ASCII 上就错）。
    private func emitStringCase(isUpper: Bool, receiver: IRExpr) throws -> String {
        let source = try emitExpr(receiver)
        let symbol = isUpper ? "bk_string_upper" : "bk_string_lower"
        let converted = "t_\(nextTempSeq())"
        writer.line("char *\(converted) = \(symbol)(\(source));")
        return converted
    }

    /// `s.contains(needle)`：字素级判定在运行时段，回 i32 ⇒ 这里收敛成布尔表达式（条件里不求值第二次）。
    private func emitStringContains(receiver: IRExpr, needle: IRExpr) throws -> String {
        let haystack = try emitExpr(receiver)
        let needleText = try emitExpr(needle)
        let hit = "t_\(nextTempSeq())"
        writer.line("int32_t \(hit) = bk_string_contains(\(haystack), \(needleText));")
        return "(\(hit) != 0)"
    }

    /// `s.substring(start, end)`：第 2 个参数是**绝对下标**；负值尾计数与双端夹取都在运行时段。
    private func emitStringSubstring(receiver: IRExpr, start: IRExpr, end: IRExpr) throws -> String {
        let source = try emitExpr(receiver)
        let startText = try emitExpr(start)
        let endText = try emitExpr(end)
        let slice = "t_\(nextTempSeq())"
        writer.line(
            "char *\(slice) = bk_substring(\(source), (int32_t)(\(startText)), (int32_t)(\(endText)));")
        return slice
    }

    /// `s.split(sep)`：切出真的 `Array<String>`；空定界符逐字素、省略空子串都由运行时段定。
    private func emitStringSplit(receiver: IRExpr, delim: IRExpr, type: IRType) throws -> String {
        guard case .array = type else {
            throw CBackendError(
                message: "C 后端：split 的结果类型不是 Array（\(CTypeMap.label(of: type))）")
        }
        let source = try emitExpr(receiver)
        let delimiter = try emitExpr(delim)
        let handle = "t_\(nextTempSeq())"
        writer.line("void *\(handle) = bk_string_split(\(source), \(delimiter));")
        return handle
    }

    /// `writeFile` / `appendFile`：整份内容一次交给运行时段，失败即陷阱。两个实参都是借用，
    /// 且都不产生值 —— 返回空串，调用方据此不再补分号。
    private func emitFileWrite(path: IRExpr, content: IRExpr, append: Bool) throws -> String {
        let pathText = try emitExpr(path)
        let contentText = try emitExpr(content)
        writer.line("\(append ? "bk_append_file" : "bk_write_file")(\(pathText), \(contentText));")
        return ""
    }

    /// `readFile`：整份读回，NULL 即陷阱 —— 消息与出口同 LLVM 侧，路径不进文案。
    private func emitFileRead(path: IRExpr) throws -> String {
        let pathText = try emitExpr(path)
        let content = "t_\(nextTempSeq())"
        writer.line("char *\(content) = bk_read_file(\(pathText));")
        let message = scope.registerString("Pini runtime error: readFile could not read the file")
        writer.line("if (\(content) == NULL) { bk_panic(\(message)); }")
        return content
    }

    // MARK: - 所有权镜像

    /// 该表达式节点给的是已有箱的别名（结构体要按值拷贝），还是一个新箱的所有权（直接接管）。
    /// 与 LLVM 侧同一组节点：下标读与容错读交出的也是别的持有者的份额。
    private static func yieldsAlias(_ node: IRExpr) -> Bool {
        switch node {
        case .load, .subscriptGet, .fieldGet, .optionalGet: return true
        default: return false
        }
    }

    /// 把求值出来的值按值语义落到一个持有位置：结构体别名拷出新箱，对象 / 枚举 / 字符串别名留一份份额，
    /// 临时值直接接管。注意 —— 结构体那一支必须排在 retain 之前 —— 拷贝本身就是一次独立持有。
    private func emitValueForStorage(_ node: IRExpr, _ text: String, type: IRType) throws -> String {
        guard Self.yieldsAlias(node) else {
            /// 临时值被持有位置接管 ⇒ 所有权转移，本层不再负责释放它。
            claimOwnedBox(text)
            claimOwnedString(text)
            return text
        }
        if case .nominal(let name, let isObject) = type, !isObject,
            let symbol = try copyFunction(for: type)
        {
            let aggregate = CTypeMap.aggregateName(name)
            let temp = "t_\(nextTempSeq())"
            writer.line("\(aggregate) *\(temp) = \(symbol)(\(text));")
            return temp
        }
        if let retain = try retainSymbol(for: type) {
            writer.line("\(retain)(\(text));")
        }
        return text
    }

    /// 别名点要调的留份额符号。结构体不走这条（它拷新箱）。
    private func retainSymbol(for type: IRType) throws -> String? {
        switch type {
        case .nominal, .enumeration:
            return "bk_nominal_retain"
        case .string, .char:
            return "bk_str_retain"
        // 三个容器族共用类型无关的 share 计数。
        case .array, .dict, .set:
            return "bk_handle_retain"
        default:
            return nil
        }
    }

    /// 结构体的逐类型拷贝胶水：新箱 + 逐字段搬。嵌套结构体递归拷；对象 / 枚举 / 字符串字段共享并留一份。
    /// 与 LLVM 侧的 `__copy_struct_*` 同形；缺了 retain 那一半，拷贝与原件会争同一份份额 —— 先到者释放即悬垂。
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
                if let retain = try retainSymbol(for: field.type) {
                    lines.append("    \(retain)(dst->f\(index));")
                }
            }
        }
        lines.append("    return dst;")
        lines.append("}")
        scope.appendCopyBody(symbol: symbol, aggregate: aggregate, source: lines.joined(separator: "\n"))
        return symbol
    }

    /// 逐类型合成的释放胶水：先减头格，返回非零（归零）才进清仓、逐字段释放、`free`。
    /// 枚举按标签分派，未选中 case 的载荷槽不碰 —— 那些槽里是别的类型的字节。
    private func releaseFunction(for type: IRType) throws -> String {
        let symbol = "pini_release_" + Self.glueSuffix(type)
        guard scope.reserveReleaseSymbol(symbol) else { return symbol }
        var lines: [String] = []
        lines.append("static void \(symbol)(\(try CTypeMap.spelling(of: type))box) {")
        lines.append("    if (box == NULL) { return; }")
        lines.append("    if (!bk_nominal_release(box)) { return; }")
        switch type {
        case .nominal(let name, _):
            guard let decl = scope.typeDecl(named: name) else {
                throw CBackendError(message: "C 后端：为未声明的名义类型合成释放函数 \(name)")
            }
            scope.markUsed(name)
            for (index, field) in decl.fields.enumerated() {
                guard let call = try releaseCall(local: "box->f\(index)", type: field.type) else { continue }
                // 容器字段可能是 NULL（没写过）：与 LLVM 侧的字段释放同形，先判空再调。
                if Self.isContainer(field.type) {
                    lines.append("    if (box->f\(index) != NULL) { \(call); }")
                } else {
                    lines.append("    \(call);")
                }
            }
        case .enumeration(let name):
            guard let decl = scope.enumDecl(named: name) else {
                throw CBackendError(message: "C 后端：为未声明的枚举合成释放函数 \(name)")
            }
            scope.markUsed(name)
            let releasing = decl.cases.filter { entry in
                entry.payloadTypes.contains { Self.needsRelease($0) }
            }
            if !releasing.isEmpty {
                lines.append("    switch (box->tag) {")
                for enumCase in releasing {
                    lines.append("    case \(enumCase.tag):")
                    for (slot, payloadType) in enumCase.payloadTypes.enumerated() {
                        try checkSlotType(payloadType, slot: slot, decl: decl, owner: "枚举 \(name)")
                        guard let call = try releaseCall(local: "box->f\(slot)", type: payloadType)
                        else { continue }
                        lines.append("        \(call);")
                    }
                    lines.append("        break;")
                }
                lines.append("    default: break;")
                lines.append("    }")
            }
        default:
            throw CBackendError(message: "C 后端：为非聚合类型合成释放函数")
        }
        lines.append("    free(box);")
        lines.append("}")
        scope.appendReleaseBody(symbol: symbol, pointer: try CTypeMap.spelling(of: type), source: lines.joined(separator: "\n"))
        return symbol
    }

    /// 胶水符号的后缀。结构体与枚举同名时不能撞在一起，故带族前缀。
    private static func glueSuffix(_ type: IRType) -> String {
        switch type {
        case .nominal(let name, let isObject): return (isObject ? "object_" : "struct_") + IRName.mangle(name)
        case .enumeration(let name): return "enum_" + IRName.mangle(name)
        default: return "scalar"
        }
    }

    /// 该类型在释放胶水里有没有动作。分派结构必须在合成之前算出来，
    /// 否则会为只有标量载荷的 case 生成空 arm。容器载荷也是持有者。
    private static func needsRelease(_ type: IRType) -> Bool {
        switch type {
        case .nominal, .enumeration, .string, .char, .array, .dict, .set: return true
        default: return false
        }
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
    /// 注意 —— 不退化成 `I32`：那会让一个聚合值按整数打出来，编得过、跑得通、结果是错的。
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
        case .arrayLiteral(_, let type): return type
        case .dictLiteral(_, let type): return type
        case .setLiteral(_, let type): return type
        case .subscriptGet(_, _, let type): return type
        case .lenCall: return .i32
        case .closureLiteral(_, _, _, _, _, _, let type): return type
        case .functionValue(_, let type): return type
        case .indirectCall(_, _, let returnType): return returnType ?? .i32
        case .optionalConstruct(_, _, let type): return type
        case .optionalGet(_, _, let type): return type
        case .tupleConstruct(_, _, let type): return type
        case .tupleIndexGet(_, _, let type): return type
        case .sliceCall(_, _, _, let type): return type
        case .lazyRefConstruct(_, let type): return type
        case .lazyRefValue(_, let type): return type
        case .arrayJoin: return .string
        case .stringConcat, .interpString, .stringCase, .stringSubstring: return .string
        case .stringContains: return .boolean
        case .stringSplit(_, _, let type): return type
        case .fileRead: return .string
        case .fileWrite, .fileAppend: return .i32
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

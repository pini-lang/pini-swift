import Foundation
import PiniIR

/// 一份头文件翻译出来的一条跳过项：名字，以及**为什么**不生成。跳过不是失败，
/// 但每条都要说得出理由，否则「少了一半符号」只能靠人对着头文件数。
public struct CHeaderSkip: Equatable, Sendable {
    public let name: String
    public let reason: String
    /// 跳过的是宏：只有这一类会进构建计划的跳过段，供使用点报 E4-046。
    /// 其余跳过项（静态函数、typedef、枚举）没有「已知但未翻译」的语义，混进去会指错方向。
    public let isMacro: Bool

    public init(name: String, reason: String, isMacro: Bool = false) {
        self.name = name
        self.reason = reason
        self.isMacro = isMacro
    }
}

/// 一次翻译的结果。`text` 可直接写成 `.pini`；`skipped` 是构建产物的一部分，不是控制台噪声。
public struct CHeaderTranslation: Sendable {
    public let blockName: String
    public let text: String
    public let skipped: [CHeaderSkip]
    /// 条目中来自被包含头文件的声明条数。只作读数：它们照样生成，报出来是为了让
    /// 「这个块为什么这么大」有答案。
    public let fromIncludedHeaders: Int

    public init(blockName: String, text: String, skipped: [CHeaderSkip], fromIncludedHeaders: Int) {
        self.blockName = blockName
        self.text = text
        self.skipped = skipped
        self.fromIncludedHeaders = fromIncludedHeaders
    }
}

public enum CHeaderTranslationError: Error, CustomStringConvertible, LocalizedError {
    case headerNotFound(path: String)
    case clangNotFound
    case compilerFailed(command: String, output: String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .headerNotFound(let path):
            return "头文件不存在：\(path)"
        case .clangNotFound:
            return "找不到 clang：AST 只有 clang 会输出。装一份，或用 PINI_CLANG 指定路径"
        case .compilerFailed(let command, let output):
            return "C 工具执行失败：`\(command)`\n\(output)"
        }
    }
}

/// 头文件 → Pini 外部声明块。两段：clang 出 C 语义（类型拼写、变参、目标宽度），
/// 映射段按白名单写成 Pini。宽度取自 clang 的预定义宏，不按类型名猜。
public enum CHeaderTranslator {
    public struct Options: Sendable {
        public var header: String
        public var includePaths: [String]
        public var defines: [String]
        public var blockName: String?

        public init(
            header: String, includePaths: [String] = [], defines: [String] = [], blockName: String? = nil
        ) {
            self.header = header
            self.includePaths = includePaths
            self.defines = defines
            self.blockName = blockName
        }
    }

    /// 输入指纹：整棵包含树的预处理结果、宏定义、目标宽度与翻译器版本。
    /// 只按头文件字节算是不够的：宏定义与被包含的文件都能改产物，漏掉任一项都会静默沿用旧块。
    public static func inputDigest(_ options: Options) throws -> String {
        let header = URL(fileURLWithPath: options.header).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: header) else {
            throw CHeaderTranslationError.headerNotFound(path: header)
        }
        guard let clang = CTool.clangPath() else { throw CHeaderTranslationError.clangNotFound }
        let target = try CTarget.probe(clang: clang)
        let arguments =
            ["-E", "-dD", "-P"] + options.includePaths.map { "-I\($0)" }
            + options.defines.map { "-D\($0)" } + [header]
        let text = try CTool.run(clang, arguments)
        let widths = "\(target.intWidth)/\(target.longWidth)/\(target.longLongWidth)/\(target.pointerWidth)"
        let key = [BuildPlan.translator, widths, text].joined(separator: "\u{0}")
        return SHA256.hexDigest(Data(key.utf8))
    }

    public static func translate(_ options: Options) throws -> CHeaderTranslation {
        let header = URL(fileURLWithPath: options.header).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: header) else {
            throw CHeaderTranslationError.headerNotFound(path: header)
        }
        guard let clang = CTool.clangPath() else { throw CHeaderTranslationError.clangNotFound }

        let arguments = compilerArguments(options: options, header: header)
        let target = try CTarget.probe(clang: clang)
        // `-fno-builtin` 关掉 clang 自带的 `strlen` / `memcpy` 等预声明：开着它们，头文件里的
        // 声明会被合并进内建声明，类型变成 `__size_t` 这种只有 clang 认识的拼写。
        let ast = try runJSON(
            clang: clang,
            arguments: ["-Xclang", "-ast-dump=json", "-fsyntax-only", "-fno-builtin"] + arguments)
        let scanned = try ASTScanner.scan(ast, header: header)

        let mapper = TypeMapper(target: target, typedefs: scanned.typedefs)
        var entries: [String] = []
        var skipped = scanned.skipped
        var seen: Set<String> = []
        for decl in scanned.declarations {
            let name: String
            let entry: String?
            switch decl {
            case .function(let function):
                name = function.name
                entry = mapper.functionEntry(function, skipped: &skipped)
            case .variable(let variable):
                name = variable.name
                entry = mapper.variableEntry(variable, skipped: &skipped)
            }
            guard let entry = entry else { continue }
            // 被包含头文件之间常重复声明同一符号。生成物是给 foreign 块用的，同名只留一处，
            // 否则第二处会把整块判成异型冲突（E3-019）。
            guard seen.insert(name).inserted else {
                skipped.append(CHeaderSkip(name: name, reason: "同名重复声明，保留第一处"))
                continue
            }
            entries.append(entry)
        }

        let macros = try MacroScanner.scan(clang: clang, options: options, header: header)
        for entry in macros.entries { entries.append(entry) }
        skipped.append(contentsOf: macros.skipped)

        let block = options.blockName ?? defaultBlockName(header: header)
        let text = render(
            block: block, entries: entries, skipped: skipped,
            options: options, header: header, tool: clangVersion(clang: clang))
        return CHeaderTranslation(
            blockName: block, text: text, skipped: skipped,
            fromIncludedHeaders: scanned.fromIncludedHeaders)
    }

    /// 生成文本：头注释只写事实（来源、工具、参数、不许手改），空行之后是块体。
    /// 排序完全由 AST 与预处理的输出顺序决定，同一输入两次生成逐字节相同。
    private static func render(
        block: String, entries: [String], skipped: [CHeaderSkip],
        options: Options, header: String, tool: String
    ) -> String {
        var lines: [String] = []
        lines.append("; 由 C 头文件翻译生成，勿手改。")
        lines.append("; 来源: \(header)")
        lines.append("; 工具: \(tool)")
        var parameters = options.includePaths.map { "-I\($0)" } + options.defines.map { "-D\($0)" }
        if parameters.isEmpty { parameters = ["（无）"] }
        lines.append("; 参数: \(parameters.joined(separator: " "))")
        lines.append("; 指针一律 `*U8`；类型区分交给手写的给定块，原拼写见来源头文件。")
        if entries.contains(where: { $0.contains("|macro:") }) {
            lines.append("; 本块含 |macro 条目：用到它们时，[ffi].headers 要声明来源头文件。")
        }
        lines.append("; 跳过 \(skipped.count) 条（结构体 / 枚举 / 函数式宏 / 认不出的类型），理由见 bind 报告。")
        lines.append("")
        lines.append("[\(block)|foreign]")
        lines.append(contentsOf: entries)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func compilerArguments(options: Options, header: String) -> [String] {
        options.includePaths.map { "-I\($0)" } + options.defines.map { "-D\($0)" } + [header]
    }

    /// 生成物里记工具版本：同一份头文件换 clang 大版本，类型结论可能不同，事后要能对上是哪一版。
    private static func clangVersion(clang: String) -> String {
        let output = (try? CTool.run(clang, ["--version"])) ?? ""
        return output.split(separator: "\n").first.map(String.init) ?? clang
    }

    private static func runJSON(clang: String, arguments: [String]) throws -> Any {
        let output: String
        do {
            output = try CTool.run(clang, arguments)
        } catch let error as CToolError {
            throw CHeaderTranslationError.compilerFailed(
                command: ([clang] + arguments).joined(separator: " "),
                output: error.description)
        }
        guard let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw CHeaderTranslationError.compilerFailed(
                command: ([clang] + arguments).joined(separator: " "),
                output: "AST 输出不是 JSON")
        }
        return json
    }

    /// 块名的默认值：头文件名去扩展名，非字母数字一律换成 `_`，首字符是数字时补 `_`。
    static func defaultBlockName(header: String) -> String {
        let base = URL(fileURLWithPath: header).deletingPathExtension().lastPathComponent
        var name = String(
            base.map { character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            })
        if let first = name.first, first.isNumber { name = "_" + name }
        return name.isEmpty ? "c" : name
    }
}

/// 目标平台宽度：取 clang 的预定义宏。按类型名猜是错的 —— `long` 在 LP64 是 8 字节、
/// 在 LLP64 是 4 字节，猜错的表现是 ABI 对不上，不是报错。
struct CTarget {
    let intWidth: Int
    let longWidth: Int
    let longLongWidth: Int
    let pointerWidth: Int

    static func probe(clang: String) throws -> CTarget {
        let output = try CTool.run(clang, ["-dM", "-E", "-x", "c", "/dev/null"])
        var values: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "#define" else { continue }
            if let value = Int(parts[2]) { values[parts[1]] = value }
        }
        return CTarget(
            intWidth: values["__SIZEOF_INT__"] ?? 4,
            longWidth: values["__SIZEOF_LONG__"] ?? 8,
            longLongWidth: values["__SIZEOF_LONG_LONG__"] ?? 8,
            pointerWidth: values["__SIZEOF_POINTER__"] ?? 8)
    }
}

/// 扫描 AST：顶级函数与数据符号全部取出（含被包含头文件的），结构体 / 枚举 / typedef 记跳过。
/// 与 Zig 的 translate-c 同口径：一个头文件的翻译结果 = 它整棵包含树的声明面。
enum ASTScanner {
    enum Declaration {
        case function(RawFunction)
        case variable(RawVariable)
    }

    struct RawFunction {
        let name: String
        let returnType: String
        let params: [String]
        let isVariadic: Bool
        let isStatic: Bool
        let isDeleted: Bool
    }

    struct RawVariable {
        let name: String
        let type: String
        let isStatic: Bool
    }

    struct Result {
        var declarations: [Declaration] = []
        var skipped: [CHeaderSkip] = []
        var fromIncludedHeaders = 0
        /// typedef 名 → 展开后的拼写。跨文件也收：`__size_t` 这种名字本身不在映射表里，
        /// 少了它，`unsigned long` 就会被判成「认不出的类型」。
        var typedefs: [String: String] = [:]
    }

    static func scan(_ json: Any, header: String) throws -> Result {
        guard let root = json as? [String: Any], let inner = root["inner"] as? [[String: Any]] else {
            return Result()
        }
        var scanner = Walker(header: URL(fileURLWithPath: header).standardizedFileURL.path)
        for node in inner { scanner.visitTopLevel(node) }
        return scanner.result
    }

    /// 位置里的 `file` 只在变化时出现，故必须按 dump 顺序走完整棵树再判归属；
    /// 只看顶级节点的 `loc` 会把「沿用上一个文件」误判成当前文件。
    private struct Walker {
        let header: String
        var result = Result()
        var currentFile: String?

        init(header: String) { self.header = header }

        mutating func visitTopLevel(_ node: [String: Any]) {
            updateFile(node)
            let inHeader = currentFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path == header } ?? false
            // typedef 表先于任何过滤收集：它只用于展开类型拼写，不是生成物。
            if node["kind"] as? String == "TypedefDecl", let name = node["name"] as? String {
                result.typedefs[name] = Walker.typeSpelling(node["type"] as? [String: Any])
            }
            defer { descend(node) }
            guard node["isImplicit"] as? Bool != true else { return }
            guard let kind = node["kind"] as? String else { return }
            let name = node["name"] as? String
            switch kind {
            case "FunctionDecl":
                guard let name = name else { return }
                if !inHeader { result.fromIncludedHeaders += 1 }
                result.declarations.append(.function(function(node, name: name)))
            case "VarDecl":
                guard let name = name else { return }
                if !inHeader { result.fromIncludedHeaders += 1 }
                let type = Self.typeSpelling(node["type"] as? [String: Any])
                result.declarations.append(
                    .variable(
                        RawVariable(
                            name: name, type: type,
                            isStatic: node["storageClass"] as? String == "static")))
            case "RecordDecl":
                guard inHeader, let name = name else { return }
                let what = node["tagUsed"] as? String == "union" ? "联合" : "结构体"
                result.skipped.append(CHeaderSkip(name: name, reason: "按值\(what)不生成：Pini 的 ABI 面接不住"))
            case "EnumDecl":
                guard inHeader, let name = name else { return }
                result.skipped.append(
                    CHeaderSkip(name: name, reason: "枚举不生成：常量不是宏，`cc -E` 展不开"))
            case "TypedefDecl":
                guard inHeader, let name = name else { return }
                result.skipped.append(CHeaderSkip(name: name, reason: "typedef 不生成：它是 C 侧的名字，不是符号"))
            default:
                return
            }
        }

        private mutating func updateFile(_ node: [String: Any]) {
            guard let loc = node["loc"] as? [String: Any] else { return }
            if let file = loc["file"] as? String { currentFile = file }
        }

        private mutating func descend(_ node: [String: Any]) {
            for child in node["inner"] as? [[String: Any]] ?? [] {
                updateFile(child)
                descend(child)
            }
        }

        private func function(_ node: [String: Any], name: String) -> RawFunction {
            let type = Walker.typeSpelling(node["type"] as? [String: Any])
            let children = node["inner"] as? [[String: Any]] ?? []
            let params = children.compactMap { child -> String? in
                guard child["kind"] as? String == "ParmVarDecl" else { return nil }
                return Walker.typeSpelling(child["type"] as? [String: Any])
            }
            let returnType = String(type.split(separator: "(", maxSplits: 1).first ?? "")
            return RawFunction(
                name: name, returnType: returnType, params: params,
                isVariadic: type.contains("..."),
                isStatic: node["storageClass"] as? String == "static",
                isDeleted: node["explicitlyDeleted"] as? Bool == true)
        }

        /// 类型拼写优先取 `desugaredQualType`：typedef 名（`__size_t`）本身不在映射表里，
        /// 展开后的 `unsigned long` 才是宽度与符号性的依据。
        static func typeSpelling(_ type: [String: Any]?) -> String {
            guard let type = type else { return "" }
            let raw = type["desugaredQualType"] as? String ?? type["qualType"] as? String ?? ""
            return raw.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// C 类型拼写 → Pini 类型。只认白名单：认不出的一律返回 nil，由调用方记一条跳过。
struct TypeMapper {
    let target: CTarget
    /// typedef 名 → 展开拼写。clang 对某些内置声明只给 `__size_t` 这样的名字，
    /// 宽度与符号性得靠这张表回到 `unsigned long`。
    let typedefs: [String: String]

    private static let qualifiers: Set<String> = [
        "const", "volatile", "restrict", "__restrict", "__restrict__",
        "_Nonnull", "_Nullable", "__nonnull", "__nullable", "_Atomic",
    ]

    func functionEntry(_ function: ASTScanner.RawFunction, skipped: inout [CHeaderSkip]) -> String? {
        guard !function.isStatic else {
            skipped.append(CHeaderSkip(name: function.name, reason: "静态函数没有外部符号，链接期找不到它"))
            return nil
        }
        guard !function.isDeleted else {
            skipped.append(CHeaderSkip(name: function.name, reason: "声明为 = delete"))
            return nil
        }
        var params: [String] = []
        for (index, spelling) in function.params.enumerated() {
            guard let mapped = piniParam(spelling) else {
                skipped.append(
                    CHeaderSkip(
                        name: function.name,
                        reason: "第 \(index + 1) 个形参 `\(spelling)` 超出 Pini 的 ABI 面"))
                return nil
            }
            params.append(mapped)
        }
        guard let result = piniReturn(function.returnType) else {
            skipped.append(
                CHeaderSkip(name: function.name, reason: "返回类型 `\(function.returnType)` 超出 Pini 的 ABI 面"))
            return nil
        }
        let flag = function.isVariadic ? "|varargs" : ""
        let paramsText = params.map { "\($0)," }.joined(separator: " ")
        let resultText = result.isEmpty ? "()" : "(\(result),)"
        return "\(function.name)\(flag): (\(paramsText)) -> \(resultText)"
    }

    func variableEntry(_ variable: ASTScanner.RawVariable, skipped: inout [CHeaderSkip]) -> String? {
        guard !variable.isStatic else { return nil }
        let spelling = Self.stripAttributes(variable.type)
        // 只认顶层 `const`（`const int x`）。`const char *` 是「指向不可写」，不是只读符号，
        // 故判据看拼写的第一个词，而不是看整串里有没有 const。
        let firstWord = spelling.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init)
        let isReadonly = firstWord == "const"
        guard let mapped = piniValue(spelling) ?? piniPointer(spelling, isParam: false) else {
            skipped.append(
                CHeaderSkip(name: variable.name, reason: "类型 `\(variable.type)` 超出 Pini 的 ABI 面"))
            return nil
        }
        let flag = isReadonly ? "|readonly" : ""
        return "\(variable.name)\(flag): \(mapped)"
    }

    /// 形参位：`const char *` 借出成 `String`，其余指针一律 `*U8`。
    func piniParam(_ spelling: String) -> String? {
        if let callback = piniCallback(spelling, isParam: true) { return callback }
        return piniValue(spelling) ?? piniPointer(spelling, isParam: true)
    }

    /// 返回位：函数指针返回一律不接（Pini 没有可在 C 边界上往返的函数指针值）。
    func piniReturn(_ spelling: String) -> String? {
        let trimmed = Self.stripAttributes(spelling).trimmingCharacters(in: .whitespaces)
        if trimmed == "void" { return "" }
        if Self.isFunctionPointer(trimmed) { return nil }
        return piniValue(trimmed) ?? piniPointer(trimmed, isParam: false)
    }

    /// 标量与枚举名。指针与函数指针不进这里 —— 它们由调用方先分流。
    func piniValue(_ spelling: String) -> String? {
        piniValue(spelling, depth: 0)
    }

    private func piniValue(_ spelling: String, depth: Int) -> String? {
        let trimmed = Self.stripAttributes(spelling).trimmingCharacters(in: .whitespaces)
        if Self.isFunctionPointer(trimmed) || Self.pointerDepth(trimmed) > 0 { return nil }
        let words = Self.tokens(trimmed)
        switch words {
        case ["void"]: return nil
        case ["_Bool"], ["bool"]: return "Bool"
        case ["double"], ["long", "double"]: return "F64"
        case ["signed", "char"]: return "I8"
        case ["unsigned", "char"]: return "U8"
        case ["char"], ["float"], ["short"], ["short", "int"], ["signed", "short"],
            ["unsigned", "short"], ["unsigned", "short", "int"]:
            return nil
        default: break
        }
        let isUnsigned = words.contains("unsigned")
        let longCount = words.filter { $0 == "long" }.count
        if longCount >= 2 { return isUnsigned ? "U64" : "I64" }
        if longCount == 1 {
            if target.longWidth == 8 { return isUnsigned ? "U64" : "I64" }
            if target.longWidth == 4 { return isUnsigned ? nil : "I32" }
            return nil
        }
        if words.contains("int") || words == ["signed"] || words == ["unsigned"] {
            // `unsigned int` 是 U32，IR 里没有这个宽度；`short` 同理。跳过比截断诚实。
            return isUnsigned ? nil : "I32"
        }
        // 单个未知词再查一次 typedef：展开是有终点的，深度上限只是防环。
        if words.count == 1, depth < 4, let underlying = typedefs[words[0]] {
            return piniValue(underlying, depth: depth + 1)
        }
        return nil
    }

    func piniPointer(_ spelling: String, isParam: Bool) -> String? {
        let trimmed = Self.stripAttributes(spelling).trimmingCharacters(in: .whitespaces)
        guard Self.pointerDepth(trimmed) > 0 else { return nil }
        let base = Self.pointeeWords(trimmed)
        // 判 `const` 要看原拼写：`tokens` 已把限定符滤掉，在那里找永远找不到。
        let isConstPointee = Self.rawTokens(trimmed).contains("const")
        if isParam, Self.pointerDepth(trimmed) == 1, base == ["char"], isConstPointee {
            return "String"
        }
        // 指针一律退化成 `*U8`：类型区分交给手写的给定块，原拼写由来源头文件负责。
        return "*U8"
    }

    /// `R (*)(A, B)` 形态：参数位可承接成回调类型，返回位一律拒。
    /// 回调里不收 `String`：C 传的是裸字节，Pini 串是带头的堆对象，两侧表示不同（E4-032），
    /// 故这里按「非形参位」映射，`const char *` 得到 `*U8`。
    func piniCallback(_ spelling: String, isParam: Bool) -> String? {
        guard let shape = Self.functionPointer(spelling) else { return nil }
        guard isParam else { return nil }
        guard let result = piniReturn(shape.returnType) else { return nil }
        var params: [String] = []
        for param in shape.params {
            guard let mapped = piniValue(param) ?? piniPointer(param, isParam: false) else {
                return nil
            }
            params.append(mapped)
        }
        let paramsText = params.map { "\($0)," }.joined(separator: " ")
        let resultText = result.isEmpty ? "()" : "(\(result),)"
        return "(\(paramsText)) -> \(resultText)"
    }

    // MARK: - 拼写工具

    static func stripAttributes(_ spelling: String) -> String {
        var text = spelling
        while let range = text.range(of: "__attribute__((") {
            var depth = 0
            var end = range.lowerBound
            var cursor = range.lowerBound
            while cursor < text.endIndex {
                if text[cursor] == "(" { depth += 1 }
                if text[cursor] == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = text.index(after: cursor)
                        break
                    }
                }
                cursor = text.index(after: cursor)
            }
            text.removeSubrange(range.lowerBound..<end)
        }
        return text
    }

    static func tokens(_ spelling: String) -> [String] {
        rawTokens(spelling).filter { !qualifiers.contains($0) }
    }

    /// 未去限定符的分词：判顶层 `const` 要用它 —— `tokens` 已经把限定符滤掉了。
    static func rawTokens(_ spelling: String) -> [String] {
        var spaced = spelling
        for symbol in ["*", "(", ")", ","] {
            spaced = spaced.replacingOccurrences(of: symbol, with: " \(symbol) ")
        }
        return spaced.split(separator: " ").map(String.init)
    }

    static func pointerDepth(_ spelling: String) -> Int {
        tokens(spelling).filter { $0 == "*" }.count
    }

    /// 被指类型的词序列：去掉末尾的 `*` 与限定符。
    static func pointeeWords(_ spelling: String) -> [String] {
        var words = rawTokens(spelling)
        while let last = words.last, last == "*" { words.removeLast() }
        return words.filter { !qualifiers.contains($0) && $0 != "*" }
    }

    static func isFunctionPointer(_ spelling: String) -> Bool {
        functionPointer(spelling) != nil
    }

    static func functionPointer(_ spelling: String) -> (returnType: String, params: [String])? {
        let compact = spelling.trimmingCharacters(in: .whitespaces)
        guard let marker = compact.range(of: "(*)") else { return nil }
        let returnType = String(compact[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = compact[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        let inner = String(rest.dropFirst().dropLast())
        return (returnType, splitParams(inner))
    }

    /// 按顶层逗号切形参表；括号里的逗号（嵌套函数指针）不切。
    static func splitParams(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.filter { $0 != "void" }
    }
}

/// 宏常量：只收本头文件里定义、能展开成数值的对象式宏。函数式宏要展开与求值，
/// 等于在 Pini 里写一遍 C 预处理器；枚举常量不是宏，`cc -E` 也展不开。
enum MacroScanner {
    struct Output {
        var entries: [String] = []
        var skipped: [CHeaderSkip] = []
    }

    private struct RawMacro {
        let name: String
        let body: String
        let isFunctionLike: Bool
        let file: String
    }

    static func scan(
        clang: String, options: CHeaderTranslator.Options, header: String
    ) throws -> Output {
        let macros = try collect(clang: clang, options: options, header: header)
        let objectLike = macros.filter { !$0.isFunctionLike && !$0.body.isEmpty }
        var output = Output()
        for macro in macros where macro.file == header {
            if macro.isFunctionLike {
                output.skipped.append(
                    CHeaderSkip(
                        name: macro.name,
                        reason: "函数式宏要实参才能展开，不能取成常量；要用请写 C shim",
                        isMacro: true))
            } else if macro.body.isEmpty {
                output.skipped.append(
                    CHeaderSkip(name: macro.name, reason: "空宏没有值", isMacro: true))
            }
        }
        guard !objectLike.isEmpty else { return output }
        let bodies = try expand(
            clang: clang, options: options, header: header, names: objectLike.map(\.name))
        for (macro, body) in zip(objectLike, bodies) {
            guard let value = try? MacroExpressionParser.evaluate(body, symbol: macro.name),
                let type = piniType(of: value)
            else {
                if macro.file == header {
                    output.skipped.append(
                        CHeaderSkip(
                            name: macro.name,
                            reason: "展开结果 `\(body)` 不是数值常量",
                            isMacro: true))
                }
                continue
            }
            output.entries.append("\(macro.name)|macro: \(type)")
        }
        return output
    }

    /// `-E -dD` 保留所有 `#define` 与行标记，据此判宏定义在哪个文件。
    /// `-dM` 只有名字没有位置，会把编译器的预定义宏一并算进来。
    private static func collect(
        clang: String, options: CHeaderTranslator.Options, header: String
    ) throws -> [RawMacro] {
        let arguments =
            ["-E", "-dD"] + options.includePaths.map { "-I\($0)" }
            + options.defines.map { "-D\($0)" } + [header]
        let text = try CTool.run(clang, arguments)
        var currentFile: String?
        var seen: Set<String> = []
        var macros: [RawMacro] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let textLine = String(line)
            if textLine.hasPrefix("# ") {
                currentFile = markerFile(textLine)
                continue
            }
            guard let currentFile = currentFile, textLine.hasPrefix("#define ") else { continue }
            // `<built-in>` 与 `<command line>` 不是头文件，收进来只会污染清单。
            guard !currentFile.hasPrefix("<") else { continue }
            let normalized = URL(fileURLWithPath: currentFile).standardizedFileURL.path
            let rest = textLine.dropFirst("#define ".count)
            let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            guard !name.isEmpty, !isReserved(name), seen.insert(name).inserted else { continue }
            let afterName = rest.dropFirst(name.count)
            let isFunctionLike = afterName.hasPrefix("(")
            let body = isFunctionLike ? "" : afterName.trimmingCharacters(in: .whitespaces)
            macros.append(
                RawMacro(name: name, body: body, isFunctionLike: isFunctionLike, file: normalized))
        }
        return macros
    }

    /// 一次 `cc -E` 展开全部名字：标记行是未定义标识符，预处理器原样保留。
    private static func expand(
        clang: String, options: CHeaderTranslator.Options, header: String, names: [String]
    ) throws -> [String] {
        var source = ["#include \"\(header)\""]
        for (index, name) in names.enumerated() {
            source.append("PINI_BIND_MACRO_\(index)__ \(name)")
        }
        let arguments =
            ["-E", "-P"] + options.includePaths.map { "-I\($0)" }
            + options.defines.map { "-D\($0)" } + ["-"]
        let text = try CTool.run(
            clang, arguments, stdin: source.joined(separator: "\n") + "\n")
        var bodies = Array(repeating: "", count: names.count)
        var current: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let textLine = String(line)
            if let range = textLine.range(of: "PINI_BIND_MACRO_"),
                let end = textLine[range.upperBound...].firstIndex(of: "_"),
                let index = Int(textLine[range.upperBound..<end]), index < names.count
            {
                current = index
                bodies[index] += textLine.replacingOccurrences(
                    of: "PINI_BIND_MACRO_\(index)__", with: "")
                continue
            }
            if let index = current { bodies[index] += " " + textLine }
        }
        return bodies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 值的类型按值域定：装得进 I32 就是 I32，否则 I64；浮点一律 F64。
    /// 宏没有声明类型可依，这是唯一不猜的办法 —— 猜类型名就是猜 ABI。
    private static func piniType(of value: IRForeignConstantValue) -> String? {
        switch value {
        case .float: return "F64"
        case .integer(let value):
            if Int32(exactly: value) != nil { return "I32" }
            return "I64"
        }
    }

    private static func markerFile(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\""),
            let last = line.lastIndex(of: "\""), first < last
        else { return nil }
        return unescape(String(line[line.index(after: first)..<last]))
    }

    /// 行标记是 C 字面量：非 ASCII 字节写成三位八进制（`\350\257\255`），反斜杠与引号各自转义。
    /// 不还原时含非 ASCII 的路径比不中，宏的归属会整体丢失。
    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var bytes: [UInt8] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\\", index < scalars.count else {
                bytes.append(contentsOf: String(scalar).utf8)
                continue
            }
            let next = scalars[index]
            if next.value >= 48, next.value <= 55 {
                var value = 0
                var taken = 0
                while taken < 3, index < scalars.count,
                    scalars[index].value >= 48, scalars[index].value <= 55
                {
                    value = value * 8 + Int(scalars[index].value - 48)
                    index += 1
                    taken += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                continue
            }
            index += 1
            switch next {
            case "n": bytes.append(0x0A)
            case "t": bytes.append(0x09)
            case "r": bytes.append(0x0D)
            case "\\": bytes.append(0x5C)
            case "\"": bytes.append(0x22)
            default: bytes.append(contentsOf: String(next).utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 双下划线开头、或 `_` + 大写字母开头的是实现保留名，不该出现在生成物里。
    private static func isReserved(_ name: String) -> Bool {
        if name.hasPrefix("__") { return true }
        guard name.hasPrefix("_") else { return false }
        guard let second = name.dropFirst().first else { return true }
        return second.isUppercase
    }
}

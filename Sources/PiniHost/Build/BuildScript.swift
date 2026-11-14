import Foundation
import PiniSemantics
import PiniSyntax

/// `build.pini` 里的一条翻译步：翻哪个头文件、带哪些包含路径与宏定义。
/// 输出路径不在这里 —— 它由构建布局按包与步骤名算，写死在配置里就绕开了布局的唯一出口。
public struct TranslateStepSpec: Equatable, Sendable {
    public let name: String
    public let header: String
    public let includePaths: [String]
    public let defines: [String]

    public init(name: String, header: String, includePaths: [String] = [], defines: [String] = []) {
        self.name = name
        self.header = header
        self.includePaths = includePaths
        self.defines = defines
    }
}

public enum BuildScriptError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case syntax(path: String, reason: String)
    case invalidStepName(name: String, path: String)
    case duplicateStep(name: String, path: String)
    case unknownField(step: String, field: String, path: String)
    case missingField(step: String, field: String, path: String)
    case literalRequired(step: String, field: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "`\(path)` 读不出来：\(reason)"
        case .syntax(let path, let reason):
            return "`\(path)` 语法不过关：\(reason)"
        case .invalidStepName(let name, let path):
            return "`\(path)` 的翻译步名 `\(name)` 不能当文件名：不许为空、不许含 `/` 或 `..`"
        case .duplicateStep(let name, let path):
            return "`\(path)` 里翻译步 `\(name)` 出现了两次：步骤名即产物文件名，必须唯一"
        case .unknownField(let step, let field, let path):
            return "`\(path)` 的翻译步 `\(step)` 有不认识的字段 `\(field)`；只认 头文件 / 包含路径 / 定义"
        case .missingField(let step, let field, let path):
            return "`\(path)` 的翻译步 `\(step)` 缺字段 `\(field)`：必须给初值"
        case .literalRequired(let step, let field, let path):
            return "`\(path)` 的翻译步 `\(step)` 的 `\(field)` 只收字符串字面量或字符串数组字面量"
        }
    }
}

/// `build.pini` 的读法：**只解析，不执行**。每个 `[名称|given]` 块是一条翻译步，
/// 块名即步骤名，字段初值即参数。给定块的「字段必带初值」正好是这份配置要的完整性，
/// 而声明式读法让配置期天然纯净：不查 clang、不读环境、不跑用户代码。
public enum BuildScript {
    public static let fileName = "build.pini"

    public static func path(packageRoot: String) -> String {
        (packageRoot as NSString).appendingPathComponent(fileName)
    }

    public static func exists(packageRoot: String) -> Bool {
        FileManager.default.fileExists(atPath: path(packageRoot: packageRoot))
    }

    /// 无 `build.pini` 返回 nil；有但读不通一律抛错，不退回「没有翻译步」。
    public static func steps(packageRoot: String) throws -> [TranslateStepSpec]? {
        let file = path(packageRoot: packageRoot)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        let source: String
        do {
            source = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            throw BuildScriptError.unreadable(path: file, reason: error.localizedDescription)
        }
        switch FrontEnd.syntaxOnly(source: source, fileName: file).outcome {
        case .parsed(let module):
            return try steps(in: module, path: file)
        case .lexFailed(let error):
            throw BuildScriptError.syntax(path: file, reason: "\(error)")
        case .parseFailed(_, let errors):
            throw BuildScriptError.syntax(
                path: file, reason: errors.map { "\($0)" }.joined(separator: "；"))
        case .expandFailed(let errors):
            throw BuildScriptError.syntax(
                path: file, reason: errors.map { "\($0)" }.joined(separator: "；"))
        }
    }

    private static func steps(in module: Module, path: String) throws -> [TranslateStepSpec] {
        var result: [TranslateStepSpec] = []
        var seen: Set<String> = []
        for decl in module.declarations {
            guard case .givenDecl(let block) = decl else { continue }
            guard isStepName(block.name) else {
                throw BuildScriptError.invalidStepName(name: block.name, path: path)
            }
            guard seen.insert(block.name).inserted else {
                throw BuildScriptError.duplicateStep(name: block.name, path: path)
            }
            var fields: [String: Expression] = [:]
            for field in block.fields {
                guard let initializer = field.initializer else {
                    throw BuildScriptError.missingField(
                        step: block.name, field: field.name, path: path)
                }
                fields[field.name] = initializer
            }
            for name in fields.keys where !knownFields.contains(name) {
                throw BuildScriptError.unknownField(step: block.name, field: name, path: path)
            }
            guard let headerExpression = fields["头文件"],
                let header = string(headerExpression)
            else {
                throw BuildScriptError.missingField(step: block.name, field: "头文件", path: path)
            }
            let includePaths = try strings(
                fields["包含路径"], step: block.name, field: "包含路径", path: path)
            let defines = try strings(fields["定义"], step: block.name, field: "定义", path: path)
            result.append(
                TranslateStepSpec(
                    name: block.name, header: header,
                    includePaths: includePaths, defines: defines))
        }
        return result
    }

    private static let knownFields: Set<String> = ["头文件", "包含路径", "定义"]

    private static func isStepName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
    }

    private static func string(_ expression: Expression) -> String? {
        if case .stringLiteral(let value, _) = expression { return value }
        return nil
    }

    private static func strings(
        _ expression: Expression?, step: String, field: String, path: String
    ) throws -> [String] {
        guard let expression = expression else { return [] }
        guard case .arrayLiteral(let elements, _) = expression else {
            throw BuildScriptError.literalRequired(step: step, field: field, path: path)
        }
        var values: [String] = []
        for element in elements {
            guard let value = string(element) else {
                throw BuildScriptError.literalRequired(step: step, field: field, path: path)
            }
            values.append(value)
        }
        return values
    }
}

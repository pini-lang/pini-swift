import Foundation
import PiniBackendKit
import PiniIR

/// C 头文件通道：把 export 块的 `|c` 条目写成一份 C 声明，不产实现。
/// 结构体只镜像给定块的字段区，取址函数返回它的首地址；布局断言让错位在 C 编译期就红。
public struct CHeaderBackend: PiniBackend {

    public static var identifier: String { "c" }
    public static var capabilities: BackendCapabilities { .structural }

    public init() {}

    public func emit(module: IRModule) throws -> String {
        guard let export = module.export else {
            throw CHeaderError.noExportBlock
        }
        var out = ""
        out += "/* \(export.name).h —— 由 `pini emit --backend c` 生成，勿手改。 */\n"
        let guardName = "PINI_\(export.name.uppercased())_H"
        out += "#ifndef \(guardName)\n#define \(guardName)\n\n"
        out += "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n"

        for storage in export.storages {
            out += try structDeclaration(storage)
        }
        if !export.errorCodes.isEmpty {
            out += errorCodeConstants(export)
        }
        for function in export.functions {
            out += functionDeclaration(function) + "\n"
        }
        out += "void \(export.initName)(void);\n"
        out += "void \(export.shutdownName)(void);\n\n"
        out += "#endif /* \(guardName) */\n"
        return out
    }

    // MARK: - 错误码

    /// 错误码常量。名字取用例名（非 enum 取类型名）的 ASCII 形式，值就是导出桩返回的码。
    /// `automatic` 来源的码不承诺跨版本稳定，注释里逐条标出。
    private func errorCodeConstants(_ export: IRExportBlock) -> String {
        var out = "/* 错误码：0 成功，1 未归类，2 取消；其余由错误集分配。 */\n"
        for entry in export.errorCodes where entry.code != 0 {
            let base = entry.caseName ?? entry.typeName
            let note = entry.source == .automatic ? "（自动分配，不承诺跨版本稳定）" : ""
            out += "/* \(entry.display)\(note) */\n"
            out += "#define \(export.name)_err_\(asciiName(base)) \(entry.code)\n"
        }
        return out + "\n"
    }

    /// 非 ASCII 转 `_u` 加 6 位十六进制，ASCII 原样——与导出名的转写规则一致。
    /// 这里单独一份是因为头文件通道只依赖 IR，不引语义层的 `CName`。
    private func asciiName(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let isASCII = scalar.value < 128
            let isWord = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
            if isASCII && isWord {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "_u%06X", scalar.value)
            }
        }
        return out
    }

    // MARK: - 给定块

    private func structDeclaration(_ storage: IRExportStorage) throws -> String {
        guard let layout = cLayout(of: storage.fields) else {
            throw CHeaderError.unrepresentableField(type: storage.typeName)
        }
        var out = "/* 给定块 \(storage.typeName) 的字段区；箱头在指针之前，C 侧不需要知道它多宽。 */\n"
        out += "typedef struct \(storage.cName)_s {\n"
        for field in storage.fields {
            out += "    \(cType(field.type)) \(field.name);\n"
        }
        out += "} \(storage.cName)_t;\n\n"
        out += "_Static_assert(sizeof(\(storage.cName)_t) == \(layout.size), \"\(storage.cName)_t 的大小与 Pini 布局不符\");\n"
        for (index, field) in storage.fields.enumerated() {
            out +=
                "_Static_assert(offsetof(\(storage.cName)_t, \(field.name)) == \(layout.offsets[index]), "
                + "\"\(field.name) 的偏移与 Pini 布局不符\");\n"
        }
        out += "\n\(storage.cName)_t* \(storage.getterName)(void);\n\n"
        return out
    }

    /// 支持的字段类型都是定宽标量或指针，C 布局规则因此只有「对齐到自身、结构体补齐到最大对齐」两条。
    private func cLayout(of fields: [IRExportStorage.Field]) -> (size: Int, offsets: [Int])? {
        var offset = 0
        var maxAlign = 1
        var offsets: [Int] = []
        for field in fields {
            guard let (size, align) = cSizeAndAlign(of: field.type) else { return nil }
            offset = (offset + align - 1) / align * align
            offsets.append(offset)
            offset += size
            maxAlign = max(maxAlign, align)
        }
        let size = (offset + maxAlign - 1) / maxAlign * maxAlign
        return (size, offsets)
    }

    private func cSizeAndAlign(of type: IRType) -> (size: Int, align: Int)? {
        switch type {
        case .i8, .u8, .boolean: return (1, 1)
        case .i32: return (4, 4)
        case .i64, .u64, .f64: return (8, 8)
        case .pointer, .nominal, .enumeration: return (8, 8)
        default: return nil
        }
    }

    // MARK: - 函数

    private func functionDeclaration(_ function: IRExportFunction) -> String {
        var params = function.cParamTypes.map { cType($0) }
        let returnSpelling: String
        if let payload = function.statusPayload {
            returnSpelling = "int32_t"
            params.append("\(cType(payload))* out")
        } else if let returnType = function.returnType {
            returnSpelling = cType(returnType)
        } else {
            returnSpelling = "void"
        }
        let list = params.isEmpty ? "void" : params.joined(separator: ", ")
        var out = "\(returnSpelling) \(function.cName)(\(list));\n"
        if function.statusPayload != nil {
            out += "/* 返回 0 成功、1 失败；错误消息不跨边界。 */\n"
        }
        return out
    }

    // MARK: - 类型映射

    private func cType(_ type: IRType) -> String {
        switch type {
        case .i8: return "int8_t"
        case .u8: return "uint8_t"
        case .i32: return "int32_t"
        case .i64: return "int64_t"
        case .u64: return "uint64_t"
        case .f64: return "double"
        case .boolean: return "bool"
        case .pointer(let element):
            /// 目标不透明时给 `void*`：C 侧不需要 Pini 的结构体定义，也不该依赖它。
            if let spelling = cScalar(element) { return "\(spelling)*" }
            return "void*"
        default: return "void*"
        }
    }

    private func cScalar(_ type: IRType) -> String? {
        switch type {
        case .i8: return "int8_t"
        case .u8: return "uint8_t"
        case .i32: return "int32_t"
        case .i64: return "int64_t"
        case .u64: return "uint64_t"
        case .f64: return "double"
        case .boolean: return "bool"
        default: return nil
        }
    }
}

/// 没有 `|c` 条目时不出空文件：静默产出一个空头文件，调用方要等 C 编译报错才发现名字不对。
public enum CHeaderError: Error, CustomStringConvertible, LocalizedError {
    case noExportBlock
    case unrepresentableField(type: String)

    public var description: String {
        switch self {
        case .noExportBlock:
            return "模块没有带 `|c` 条目的 export 块，头文件无内容"
        case .unrepresentableField(let type):
            return "给定块 `\(type)` 有字段无法写成 C 类型"
        }
    }

    public var errorDescription: String? { description }
}

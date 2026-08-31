import Foundation

public struct IRTypeMapper {

 private var knownStructs: Set<String> = []
 private var knownObjects: Set<String> = []
 private var knownEnums: Set<String> = []
 private var structIRName: [String: String] = [:] // 原始名→IR mangled 名
 private var objectIRName: [String: String] = [:]
 private var enumIRName: [String: String] = [:]

 public init() {}

 /// 由 IRGenerator 在生成前注入已收集的 struct 类型名，使命名 struct 类型
 /// 能映射为 `%struct.Name*`（按指针传递/存储，与解释器值语义一致）。
 public mutating func setKnownStructs(_ names: Set<String>) {
 knownStructs = names
 }

 /// 由 IRGenerator 在生成前注入已收集的 object 类型名，使命名 object 类型
 /// 能映射为 `%object.Name*`（引用语义，按指针传递/存储）。
 public mutating func setKnownObjects(_ names: Set<String>) {
 knownObjects = names
 }

 /// 由 IRGenerator 在生成前注入已收集的 enum 类型名，使命名 enum 类型
 /// 能映射为 `%enum.Name*`（按 tagged-union 指针传递/存储）。
 public mutating func setKnownEnums(_ names: Set<String>) {
 knownEnums = names
 }
 /// 追加单个原始类型名（双注册：mangled + 原始名）
 public mutating func addKnownStruct(name: String, irName: String) {
 knownStructs.insert(name); structIRName[name] = irName
 }
 public mutating func addKnownObject(name: String, irName: String) {
 knownObjects.insert(name); objectIRName[name] = irName
 }
 public mutating func addKnownEnum(name: String, irName: String) {
 knownEnums.insert(name); enumIRName[name] = irName
 }

 public func map(_ type: TypeAnnotation) throws -> String {
 switch type {
 case .simple(let name, let loc):
 switch name {
 case "I32": return "i32"
 case "F64": return "double"
 case "Bool": return "i1"
 case "String": return "ptr"
 case "Void", "Unit": return "void"
 // Phase 0：补齐整型/浮点 primitive → IR 映射，解锁含这些类型的 struct 字段访问
 // 与运算（此前仅 I32/F64/Bool/String 可映射，其余抛 unsupportedType）。
 case "I8": return "i8"
 case "I16": return "i16"
 case "I64": return "i64"
 case "U8": return "i8"
 case "U16": return "i16"
 case "U32": return "i32"
 case "U64": return "i64"
 case "F32": return "float"
 default:
 if knownStructs.contains(name) {
 return "%struct.\(structIRName[name] ?? name)*"
 }
 if knownObjects.contains(name) {
 return "%object.\(objectIRName[name] ?? name)*"
 }
 if knownEnums.contains(name) {
 return "%enum.\(enumIRName[name] ?? name)*"
 }
 throw IRGenError.unsupportedType(name:name, loc)
 }
 case .generic(let name, _, let loc):
 if name == "Optional" {
 // 内建 Optional 在 IR 中以单一 tagged-union 表示（payload 槽预留，none 不读 payload）。
 return "%enum.Optional*"
 }
 throw IRGenError.unsupportedType(name:"generic(\(name))", loc)
 case .tuple(_, let elements, _):
 let mapped = try elements.map { try map($0) }
 return "{ " + mapped.joined(separator: ", ") + " }"
 case .function(_, _, _, _):
 // 阶段 B：函数类型（含匿名函数/闭包）统一映射为 fat pointer
 // `{ ptr code, ptr env }`——code 为函数指针，env 为捕获环境指针（无捕获时为 null）。
 return "{ ptr, ptr }"
 case .pointer(_, _):
 // Phase 2a（ADR-015 FFI）：`*T` 在 IR 中为裸指针（C ABI， 不泄漏 Swift 类型）。
 // 元素类型不参与 IR 形状（仅解引用时按元素类型 load），故直接映射 ptr。
 return "ptr"
 }
 }
}

import Foundation

/// 类型系统基础定义
public enum MethodType: Equatable {
 case instance
 case `static`
 case unspecified
}

public struct GenericParam: Equatable {
 public let name: String
 public let constraint: TypeAnnotation?

 public init(name: String, constraint: TypeAnnotation? = nil) {
 self.name = name
 self.constraint = constraint
 }
}

public struct Parameter: Equatable {
 public let name: String
 public let typeAnnotation: TypeAnnotation?

 public init(name: String, typeAnnotation: TypeAnnotation? = nil) {
 self.name = name
 self.typeAnnotation = typeAnnotation
 }
}

/// 类型注解。`indirect`：`.pointer(element:)` 递归引用自身（Phase 2a `*T`，ADR-015）。
public indirect enum TypeAnnotation: Equatable {
 case simple(name: String, location: SourceLocation)
 /// 元组类型。labels[i] 对应 elements[i] 的可选标签（nil = 位置元素）；
 /// 命名元组 `(a: I32, b: String,)` 的 labels = ["a", "b"]（草稿 A2，批次 1.3，D1）。
 case tuple(labels: [String?], elements: [TypeAnnotation], location: SourceLocation)
 case generic(name: String, params: [TypeAnnotation], location: SourceLocation)
 case function(params: [TypeAnnotation], returns: [TypeAnnotation], captured: [TypeAnnotation], location: SourceLocation)
 /// Phase 2a（ADR-015 FFI， `*T`）：原始指针类型。element 须为 C 兼容类型
 /// （标量、纯值结构体、或另一指针），禁 object 及含 object 字段的复合类型。
 case pointer(element: TypeAnnotation, location: SourceLocation)
}

extension TypeAnnotation {
 /// 结构等价（忽略 SourceLocation），用于类型比对。
 /// P2-2：元组逐分量、泛型同名同元数、函数签名（参数+返回）逐位比较。
 public func isStructurallyEquivalent(to other: TypeAnnotation) -> Bool {
 switch (self, other) {
 case (.simple(let a, _), .simple(let b, _)):
 return a == b
 case (.tuple(_, let a, _), .tuple(_, let b, _)):
 // 标签不参与结构等价：位置元组与命名元组按元素类型序列比对即可互赋
 // （标签仅用于 `.名称` 访问解析，草稿 A2，批次 1.3，D1）。
 return a.count == b.count
 && zip(a, b).allSatisfy { $0.isStructurallyEquivalent(to: $1) }
 case (.generic(let a, let pa, _), .generic(let b, let pb, _)):
 return a == b
 && pa.count == pb.count
 && zip(pa, pb).allSatisfy { $0.isStructurallyEquivalent(to: $1) }
 case (.function(let ap, let ar, _, _), .function(let bp, let br, _, _)):
 return ap.count == bp.count
 && zip(ap, bp).allSatisfy { $0.isStructurallyEquivalent(to: $1) }
 && ar.count == br.count
 && zip(ar, br).allSatisfy { $0.isStructurallyEquivalent(to: $1) }
 case (.pointer(let a, _), .pointer(let b, _)):
 return a.isStructurallyEquivalent(to: b)
 default:
 return false
 }
 }

 /// 人类可读描述，用于诊断信息（忽略 SourceLocation）。
 public func describe() -> String {
 switch self {
 case .simple(let name, _):
 return name
 case .tuple(let labels, let elements, _):
 let parts = elements.enumerated().map { i, t in
 if let l = labels.indices.contains(i) ? labels[i] : nil {
 return "\(l): \(t.describe())"
 }
 return t.describe()
 }
 return "(" + parts.joined(separator: ", ") + ")"
 case .generic(let name, let params, _):
 return name + "<" + params.map { $0.describe() }.joined(separator: ", ") + ">"
 case .function(let params, let returns, _, _):
 return "(" + params.map { $0.describe() }.joined(separator: ", ")
 + ") -> (" + returns.map { $0.describe() }.joined(separator: ", ") + ")"
 case .pointer(let element, _):
 return "*" + element.describe()
 }
 }
}

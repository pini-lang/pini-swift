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
    /// ADR-001（取用参数 `using`，P1）：参数写成 `using 名: 类型` 时为真。
    ///
    /// 只记「这个参数是由取用位引入的」这一事实；**由谁来提供实参**（默认实例的物化）
    /// 与**强制规则**（值位引用即须声明）都不在此层，属后续批次。
    /// 缺省 `false` ⇒ 既有构造点零改动，且非取用参数与今日逐字同形。
    public let isUsing: Bool

    public init(name: String, typeAnnotation: TypeAnnotation? = nil, isUsing: Bool = false) {
        self.name = name
        self.typeAnnotation = typeAnnotation
        self.isUsing = isUsing
    }
}

/// 类型注解。`indirect`：`.pointer(element:)` 递归引用自身（Phase 2a `*T`，FFI 子系统）。
public indirect enum TypeAnnotation: Equatable {
    case simple(name: String, location: SourceLocation)
    /// 元组类型。labels[i] 对应 elements[i] 的可选标签（nil = 位置元素）；
    /// 命名元组 `(a: I32, b: String,)` 的 labels = ["a", "b"]（草稿 A2，批次 1.3，D1）。
    case tuple(labels: [String?], elements: [TypeAnnotation], location: SourceLocation)
    case generic(name: String, params: [TypeAnnotation], location: SourceLocation)
    case function(params: [TypeAnnotation], returns: [TypeAnnotation], captured: [TypeAnnotation], usingIndices: Set<Int>, location: SourceLocation)
    /// Phase 2a（FFI 子系统， `*T`）：原始指针类型。element 须为 C 兼容类型
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
        case (.function(let ap, let ar, _, _, _), .function(let bp, let br, _, _, _)):
            // ⚠️ 第 4 个关联值（取用下标集合，ADR-001 §2.6）**刻意用 `_` 接住、不参与比较**：
            // 取用位是「声明 ↔ 调用」的配对信息，不是类型恒等的一部分（用户 2026-09-19 裁定）。
            // IR 面的同口径落在 `IRLowerer.labelInsensitiveEqual` 的 `.function` 分支，
            // 两处必须同口径 —— 判据各钉一条。
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
        case .function(let params, let returns, _, _, _):
            return "(" + params.map { $0.describe() }.joined(separator: ", ")
                + ") -> (" + returns.map { $0.describe() }.joined(separator: ", ") + ")"
        case .pointer(let element, _):
            return "*" + element.describe()
        }
    }
}

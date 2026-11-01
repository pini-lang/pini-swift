import Foundation
import Foundation
import PiniIR

/// 后端接缝：一条通道要接进 CLI，只做两件事 —— 实现本协议，在装配表里加一行。
/// 契约第 5 节约束的是**怎么翻**；本协议只管**接得上**：叫什么、声明支持什么、从哪个入口产出目标表示。
///  注意  不要求引用类型：需要可变配置（如模块基准）的通道用 class，一次性的用 struct。
public protocol PiniBackend {
    /// 装配表与 `--backend` 用的名字。
    static var identifier: String { get }
    /// 这个通道声明支持哪些节点族。来源必须是一张表，不是散在各处的 `if`。
    static var capabilities: BackendCapabilities { get }
    /// 模块基准路径。需要它的通道覆写，其余保持默认。
    func setProgramBase(_ path: String)
    /// 把模块翻成目标表示。越出能力声明的节点必须抛错，不得静默跳过 —— 跳过会产出能读却错的码。
    func emit(module: IRModule) throws -> String
}

extension PiniBackend {
    /// 默认不关心模块基准：只有解析相对路径的通道才需要它。
    public func setProgramBase(_ path: String) {}
}

/// 打通不了的那一处：节点名 · 所属族 · 一句为什么。能力表是声明，本类型是声明的执行面。
/// 所属族取契约里该节点所在的小节（§2.x 或 §3），供读者翻回节点表；缺的是哪种能力写在 reason 里。
public struct BackendError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let node: String
    public let family: BackendCapabilities.Family
    public let reason: String

    public init(node: String, family: BackendCapabilities.Family, reason: String) {
        self.node = node
        self.family = family
        self.reason = reason
    }

    public var description: String {
        "后端不支持 \(node)（族 \(family.rawValue)）：\(reason)"
    }
}

/// 一个通道支持什么。按**节点族**表态，不按节点逐个表态 —— 逐个表态会变成第二份节点表，
/// 与契约第 2、3 节的节点集必然漂移，而漂移那天没有任何门禁会响。
public struct BackendCapabilities: Sendable {

    /// 节点族。十三个族与契约第 2 节的十三个小节同名，另加「控制流」一档收语句节点 —— 说「这个
    /// 通道不支持 X」时读者能直接翻到那一节。
    public enum Family: String, CaseIterable, Sendable {
        // 语句侧
        case controlFlow
        // 表达式侧与契约第 2 节同名
        case scalars
        case variablesAndOperators
        case calls
        case resultAndOptional
        case collections
        case nominals
        case pointers
        case fileIO
        case catchableIO
        case strings
        case lazyRef
        case concurrency
        case givenInstances
    }

    /// 这个通道产出什么。三种都不是「能力不足」：只转储的通道也可以对每个族表态「支持」。
    public enum Output: String, Sendable {
        /// 本机可执行的目标表示。
        case machineCode
        /// 交给对端虚拟机执行的字节码。
        case bytecode
        /// 只陈述结构，不产目标码。
        case structuralDump
    }

    public let output: Output
    public let supported: Set<Family>

    public init(output: Output, supported: Set<Family>) {
        self.output = output
        self.supported = supported
    }

    /// 全部十四个族都支持，产本机码。
    public static let full = BackendCapabilities(
        output: .machineCode, supported: Set(Family.allCases))

    /// 全部十四个族都支持，但只转储结构。
    public static let structural = BackendCapabilities(
        output: .structuralDump, supported: Set(Family.allCases))

    public func supports(_ family: Family) -> Bool { supported.contains(family) }

    /// 声明了却不支持的族 —— 用于在接缝处把「我跳过了什么」显式化，而不是让它静默漏过。
    public var unsupported: [Family] { Family.allCases.filter { !supported.contains($0) } }
}

/// 装配表的一项。`identifier` 与后端自己声明的同名，两处由构造时对齐。
public struct BackendEntry {
    public let identifier: String
    public let make: () -> any PiniBackend

    public init(identifier: String, make: @escaping () -> any PiniBackend) {
        self.identifier = identifier
        self.make = make
    }
}

/// 后端接缝：一条通道要接进 CLI，只做两件事 —— 实现本协议，在注册表里加一行。契约第 5 节的五条
/// 约束的是**怎么翻**；本节只管**接得上**：叫什么、声明支持什么、从哪个入口产出目标表示。
///  注意  不要求引用类型：需要可变配置（如模块基准）的通道用 class，一次性的用 struct。
public protocol PiniBackend {
    /// 注册表与 `--backend` 用的名字。
    static var identifier: String { get }
    /// 这个通道声明支持哪些节点族。来源必须是一张表，不是散在各处的 `if`。
    static var capabilities: BackendCapabilities { get }
    /// 模块基准路径。需要它的通道覆写，其余保持默认。
    func setProgramBase(_ path: String)
    /// 把模块翻成目标表示。
    func emit(module: IRModule) -> String
}

extension PiniBackend {
    /// 默认不关心模块基准：只有解析相对路径的通道才需要它。
    public func setProgramBase(_ path: String) {}
}

/// 一个通道支持什么。按**节点族**表态，不按节点逐个表态 —— 逐个表态会变成第二份节点表，
/// 与契约第 2、3 节的节点集必然漂移，而漂移那天没有任何门禁会响。
public struct BackendCapabilities: Sendable {

    /// 节点族。十三个族与契约第 2 节的十三个小节同名，另加「控制流」一档收语句节点 —— 说「这个
    /// 通道不支持 X」时读者能直接翻到那一节。逐个节点表态会变成第二份节点表，与第 2、3 节必然漂移。
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

    /// 这个通道产出什么。结构转储也是一种后端：它证明节点集被完整消费，但不产目标码。
    ///  注意  它不等于「能力不足」—— 一个只转储的通道仍然可以对每个族表态「支持」。
    public enum Output: String, Sendable {
        /// 产出可执行的目标表示。
        case machineCode
        /// 只陈述结构，不产目标码。
        case structuralDump
    }

    public let output: Output
    public let supported: Set<Family>

    public init(output: Output, supported: Set<Family>) {
        self.output = output
        self.supported = supported
    }

    /// 全部十四个族都支持，产目标码。
    public static let full = BackendCapabilities(
        output: .machineCode, supported: Set(Family.allCases))

    /// 全部十四个族都支持，但只转储结构。
    public static let structural = BackendCapabilities(
        output: .structuralDump, supported: Set(Family.allCases))

    public func supports(_ family: Family) -> Bool { supported.contains(family) }

    /// 声明了却不支持的族 —— 用于在接缝处把「我跳过了什么」显式化，而不是让它静默漏过。
    public var unsupported: [Family] { Family.allCases.filter { !supported.contains($0) } }
}

/// 注册表的一项。`identifier` 与后端自己声明的同名，两处由构造时对齐。
public struct BackendEntry {
    public let identifier: String
    public let make: () -> any PiniBackend

    public init(identifier: String, make: @escaping () -> any PiniBackend) {
        self.identifier = identifier
        self.make = make
    }
}

public enum BackendRegistry {

    /// 接入新后端的唯一一处：加一行。
    ///  注意  `nonisolated(unsafe)`：表构造后只读、闭包不捕获外部状态；`any PiniBackend` 是可变
    /// 对象，Swift 无法替它验证 Sendable，而这张表不需要跨线程可变性。
    nonisolated(unsafe) public static let entries: [BackendEntry] = [
        BackendEntry(identifier: IREmitter.identifier) { IREmitter() },
        BackendEntry(identifier: JSONBackend.identifier) { JSONBackend() }
    ]

    public static var identifiers: [String] { entries.map(\.identifier) }

    /// CLI 不带 `--backend` 时用的通道。
    public static var defaultIdentifier: String { IREmitter.identifier }

    /// 按名字取一条通道。名字不认识时返回 nil —— 由调用方报错并列出可选名字，
    /// 不在注册表里猜一个近似值。
    public static func make(_ name: String) -> (any PiniBackend)? {
        entries.first { $0.identifier == name }?.make()
    }
}

extension IREmitter: PiniBackend {
    public static var identifier: String { "llvm" }
    public static var capabilities: BackendCapabilities { .full }
    public func setProgramBase(_ path: String) { programBase = path }
}

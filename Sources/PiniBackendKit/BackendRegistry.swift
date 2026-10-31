/// 装配表：一份不可变名单，由最上层装配、由 CLI 与测试消费。
/// 本类型只描述名单的形状，不含名单的内容 —— 内容写在这里，接缝层就要认识所有后端。

///  注意  名单里的每一项都持有构造闭包，故不是 `Sendable`；装配在进程启动时一次完成，之后只读。
public struct BackendRegistry {
    public let entries: [BackendEntry]
    /// CLI 不带 `--backend` 时用的通道。
    public let defaultIdentifier: String

    public init(entries: [BackendEntry], defaultIdentifier: String) {
        self.entries = entries
        self.defaultIdentifier = defaultIdentifier
    }

    public var identifiers: [String] { entries.map(\.identifier) }

    /// 按名字取一条通道。名字不认识时返回 nil —— 由调用方报错并列出可选名字，不在这里猜近似值。
    public func make(_ name: String) -> (any PiniBackend)? {
        entries.first { $0.identifier == name }?.make()
    }
}

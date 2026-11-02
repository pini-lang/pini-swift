import PiniBackendEmbedded
import PiniBackendKit
import PiniBackendLLVM

/// 全部通道的装配点：新增一条后端 = 这里加一行。
/// 装配放在最上层，故每条通道只认识接缝、不认识彼此 —— 否则加一个后端会把别的后端的代码拖进来，
/// 「边际成本」也就无从谈起。
public enum Backends {

    ///  注意  `nonisolated(unsafe)`：装配表构造后只读，闭包不捕获外部状态；
    /// 闭包返回的 `any PiniBackend` 是可变对象，Swift 无法替它验证 Sendable。
    nonisolated(unsafe) public static let registry = BackendRegistry(
        entries: [
            BackendEntry(identifier: IREmitter.identifier) { IREmitter() },
            BackendEntry(identifier: CHeaderBackend.identifier) { CHeaderBackend() },
            BackendEntry(identifier: JSONBackend.identifier) { JSONBackend() },
            BackendEntry(identifier: EmbeddedMinBackend.identifier) { EmbeddedMinBackend() },
        ],
        defaultIdentifier: IREmitter.identifier)
}

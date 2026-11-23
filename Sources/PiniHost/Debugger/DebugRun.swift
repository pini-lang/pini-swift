import Foundation

/// 一台已就绪、可被调试的引擎：协议面，加上协议面故意留出的那一件事 —— 启动。
/// `DebugHookHost` 不含入口点，因为各引擎接受的输入不同，选哪一种由降载决定；
/// 做出决定的调用方在这里拼出 `lower → run`，引擎名不外泄。
public struct DebugRun {

    /// 要挂接的引擎：调试器需要的一切都在这里，唯独没有启动。
    public let host: any DebugHookHost

    /// 启动程序，跑完才返回。抛出会传给启动本次运行的一方 ——
    /// `DebuggerError.quit` 正是这样结束会话的，两引擎在暂停点遵守同一契约。
    public let start: () throws -> Void

    public init(host: any DebugHookHost, start: @escaping () throws -> Void) {
        self.host = host
        self.start = start
    }
}

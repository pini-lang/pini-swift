import Foundation

/// 引擎的调试面：调试器挂接一台引擎所需的全部，不涉及怎么启动。
/// 两台引擎都遵守它，持有 `any DebugHookHost` 的调用方无需知道背后是哪一台；
/// 但遵守协议不等于具备功能 —— 每台引擎都必须自己拥有一个喂钩子的暂停点。
public protocol DebugHookHost: AnyObject {

    /// 在引擎即将执行的每条语句之前被询问。返回 `.quit` 会抛 `DebuggerError.quit` 结束程序；
    /// `nil` 表示没有挂调试器，所以判空必须在构造任何暂停上下文之前。
    var debugHook: ((DebugContext) throws -> DebugAction)? { get set }

    /// 程序的行输出通道。可重定向，好让被调试程序自己的输出不混进协议流 ——
    /// DAP 适配器会把它作为 `output` 事件发送。
    var outputSink: (String) -> Void { get set }
}

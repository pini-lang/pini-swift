import Foundation

/// An engine's debug surface: everything a debugger needs from an engine it attaches to, and nothing about how to
/// start one. Both engines conform, so a caller holding `any DebugHookHost` installs a debugger without knowing
/// which engine is behind it; conformance is not function — each engine must own a pause site that feeds the hook.
public protocol DebugHookHost: AnyObject {

    /// Consulted before each statement the engine is about to execute. Returning `.quit` ends the program by throwing
    /// `DebuggerError.quit`; `nil` means no debugger is attached, so the check must come before building any pause context.
    var debugHook: ((DebugContext) throws -> DebugAction)? { get set }

    /// The program's line output channel. Redirectable so a debuggee's own output stays off the protocol stream —
    /// the DAP adapter sends it as an `output` event instead.
    var outputSink: (String) -> Void { get set }
}

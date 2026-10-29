import Foundation

/// One engine ready to be debugged: the protocol surface plus the one thing that surface leaves out — a start.
/// `DebugHookHost` stops short of an entry point because the engines take different inputs and choosing one is
/// what lowering decides; the caller that decided builds `lower → run` here, so no engine name leaks out.
public struct DebugRun {

    /// The engine to attach to: everything the debugger needs, except the start.
    public let host: any DebugHookHost

    /// Starts the program; returns when it finishes. A throw propagates to whoever started the run — which is how
    /// `DebuggerError.quit` ends a session, the same contract both engines honour at their pause sites.
    public let start: () throws -> Void

    public init(host: any DebugHookHost, start: @escaping () throws -> Void) {
        self.host = host
        self.start = start
    }
}

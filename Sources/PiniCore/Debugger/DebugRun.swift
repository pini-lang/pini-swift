import Foundation

/// One engine, ready to be debugged: the protocol surface plus the single
/// thing the protocol deliberately does not carry — a way to start.
///
/// WHY THIS EXISTS (LR-4 P4-3)
///
/// `DebugHookHost` unifies what a debugger needs *from* an engine and stops
/// short of the entry point on purpose: the interpreter runs an already-checked
/// `Module`/`Package`, the HIR executor runs an `HIRModule`, and **choosing the
/// engine is what lowering decides**, so a `run` on the protocol would have to
/// pretend both engines take the same program.
///
/// The host still has to start *something*, and until this type existed it
/// started a concrete `Interpreter`: `pini debug` carried one copy of its setup
/// per input shape (`module` and `package`), and `DAPServer` could not attach
/// to any engine but the AST one. Two consequences, both of them work that P4
/// would otherwise have to redo: the debugger subsystem knew one engine by
/// name, and switching the default engine meant editing both hosts.
///
/// This closes that gap **without moving lowering**. The caller that already
/// decided which engine to use builds the closure — `lower → run` on the HIR
/// side — and the debugger subsystem holds only a protocol reference plus a way
/// to start. Which engine runs stays a decision made in one place, by the party
/// that has the information to make it.
public struct DebugRun {

    /// The engine to attach to: everything the debugger needs, except the start.
    public let host: any DebugHookHost

    /// Starts the program; returns when it finishes.
    ///
    /// A throw propagates to whoever started the run, which is how
    /// `DebuggerError.quit` ends a session — the same contract both engines
    /// already honour at their pause sites.
    public let start: () throws -> Void

    public init(host: any DebugHookHost, start: @escaping () throws -> Void) {
        self.host = host
        self.start = start
    }
}

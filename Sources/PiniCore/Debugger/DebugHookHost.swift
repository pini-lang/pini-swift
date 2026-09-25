import Foundation

/// An execution engine's debug surface — the whole of what a debugger needs
/// from an engine it attaches to.
///
/// WHY THIS TYPE EXISTS
///
/// LR-4 gives the language two live execution engines (the AST interpreter and
/// the IR executor) and one debugger. Before this protocol, "attach a debugger
/// to the engine" could only be written against `Interpreter`, so the debugger
/// subsystem and the AST engine were effectively one unit: a second engine had
/// to re-invent the attachment, and nothing recorded that the two surfaces were
/// meant to have the same shape. The protocol turns that shape into a named,
/// checkable thing — both engines conform, and a caller holding only
/// `any DebugHookHost` installs a debugger without knowing which engine is
/// behind it.
///
/// WHAT IS DELIBERATELY ABSENT
///
/// **The execution entry point.** The interpreter runs an already-checked
/// `Module` or `Package`; the IR executor runs an `IRModule`. Those inputs
/// differ, so a single `run` requirement would have to pretend the engines take
/// the same program — and choosing the engine *is* what lowering decides, so the
/// choice belongs to the caller rather than to the engine. A caller therefore
/// keeps a concrete reference to drive the run and reaches the debugger through
/// this protocol.
///
/// The engine's introspection state is absent for the same reason: call depth,
/// call stack and the variable snapshot are read by the pause site on the
/// engine's own terms, and nothing outside an engine consumes them yet.
///
/// CONFORMANCE IS NOT FUNCTION
///
/// Declaring the surface says nothing about whether an engine has a pause site.
/// Both live engines now do — the IR executor's was the last one missing, and
/// the reason it was missing is worth keeping: the IR carried no source
/// position, so a pause there could only have reported a placeholder and stopped
/// at a line that does not exist. The position had to reach the representation
/// first (LR-4 P4-3 — see `IRBlock`), and the dormancy assertion that guarded
/// the gap was inverted rather than deleted, so the boundary stays witnessed
/// from both sides.
/// See IR 契约 (IR contract) and LLVM 后端重写 (a capability conclusion must rest on
/// a real run, not on the absence of a path).
public protocol DebugHookHost: AnyObject {

    /// Consulted before each statement the engine is about to execute.
    ///
    /// Returning `.quit` ends the program by throwing `DebuggerError.quit`.
    /// `nil` means no debugger is attached and must stay free of runtime cost, so
    /// an engine checks this *before* building any pause context.
    var debugHook: ((DebugContext) throws -> DebugAction)? { get set }

    /// The program's line output channel.
    ///
    /// Redirectable so a debuggee's own output can be kept off the protocol
    /// stream: the DAP adapter sends it as an `output` event instead.
    var outputSink: (String) -> Void { get set }
}

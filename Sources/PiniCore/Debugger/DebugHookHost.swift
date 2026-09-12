import Foundation

/// An execution engine's debug surface — the whole of what a debugger needs
/// from an engine it attaches to.
///
/// WHY THIS TYPE EXISTS
///
/// LR-4 gives the language two live execution engines (the AST interpreter and
/// the HIR executor) and one debugger. Before this protocol, "attach a debugger
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
/// `Module` or `Package`; the HIR executor runs an `HIRModule`. Those inputs
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
/// A conforming engine may still have no pause site. The HIR executor declares
/// `debugHook` today and never consults it, because the HIR carries no source
/// position; its own suite asserts that dormancy, so wiring a pause before
/// positions exist fails a test rather than shipping a stop that points nowhere.
/// See ADR-034 (HIR contract) and ADR-031 (a capability conclusion must rest on
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

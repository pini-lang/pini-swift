import Foundation

/// Which execution engine to run a program on (LR-4).
///
/// This lived in the CLI until P4-4, next to the environment switch that reads
/// it. It moved because it is an *engine* concept rather than a CLI one: the
/// REPL's evaluation core has to dispatch on it, and that core has to be
/// testable — and the test target depends on `PiniCore`, not on the executable.
/// A switch that only the CLI could name was enough to keep the REPL's
/// evaluation path both engine-bound and untested, which is the state P4-4 was
/// filed to end.
///
/// The two cases are two independent implementations of the same semantics —
/// that is what makes the three-channel probe a comparison of real
/// implementations rather than of a pipeline against itself.
public enum InterpreterEngine: String, CaseIterable, Sendable {

    /// The AST interpreter: the default engine, and the one that retires at P4.
    case ast

    /// The HIR executor: the engine the unification is moving to.
    case hir
}

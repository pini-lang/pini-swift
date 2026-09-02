# Test Directory Taxonomy — measured proposal (2026-09-03)

- **Status**: PROPOSED — **not executed**. Directory moves happen only after sign-off.
- **Scope**: `Tests/PiniTests/` — 108 top-level directories, 110 test classes,
  111 `.swift` files, 861 `.pini` fixtures.
- **Purpose**: decide whether the 108 flat directories should be grouped, and on what axis.

---

## 1. Measurement: pass-based grouping does not fit this suite

Screened every test `.swift` for host pass symbols (`Lexer(`/`tokenize`, `Parser(`/
`parseModule`, `SemanticAnalyzer`, `TypeChecker`/`TypeError`, `Interpreter(`/
`RuntimeError`, `IRGenerator`/`LLVMToolchain`, `ModuleToolchain`/`pini.toml`, `LSP`,
`Debugger`):

| Metric | Result |
|---|---|
| Files driving the full Lexer → Parser → Interpreter pipeline | **61 / 111 (55%)** |
| Files touching exactly one pass | **8 / 111 (7%)** |
| Passes hit per file (distribution) | 0:6 · 1:8 · 2:12 · 3:45 · 4:24 · 5:15 · 6:1 |

**Conclusion**: a `Lex/Parse/Sema/Type/Interp/…` taxonomy would put 55% of the suite in
one bucket and leave the remaining 45% with genuinely ambiguous membership. The cause is
structural, not sloppiness: these tests are named for the **behaviour** they verify, and
most behaviours can only be observed by running the whole pipeline.

Pass symbols are still useful as one input; they are not a partition.

## 2. Proposal: group by subject

Subject clusters follow how the tests are already named, so a reader who knows the
feature can find the directory without knowing the pass. Machine-checked for partition
completeness (every one of the 110 classes assigned exactly once; no duplicates, no
invalid names).

| Group | n | Members |
|---|---|---|
| **Runtime** | 11 | `InterpreterTests` `EnvironmentTests` `ValueSemanticsTests` `RuntimeCOWTests` `RuntimeBackendTests` `ARCManagerTests` `WeakRefTests` `LazyRefTests` `StackGuardTests` `StdlibTests` `BuiltinFunctionTests` |
| **Syntax** | 10 | `ParenEqualsTests` `LabelValidationTests` `BlockLabelTests` `StepBlockTests` `TestBlockTests` `FuncLiteralTests` `CaptureStmtTests` `IfElifElseLevelTests` `DeferBlockTests` `TryExceptTests` |
| **Concurrency** | 9 | `ConcurrencyTests` `JoinAllTests` `JoinWithinTests` `StructuredConcurrencyTests` `TaskIsolationTests` `CancellationTests` `SuspendRuntimeTests` `StarvationTests` `CPSDifferentialTests` |
| **Module** | 9 | `ModuleSystemTests` `ModuleTestCollectionTests` `ModuleToolchainTests` `ImportExportTests` `ImportInjectionTests` `CrossFileRuntimeTests` `CrossFileVisibilityTests` `PackageTests` `CLIDirectoryTests` |
| **Tooling** | 9 | `LSPTests` `DebuggerTests` `ReplTests` `PassTests` `ConstantFolderTests` `DiagnosticTests` `SuggestionTests` `ErrorTests` `ErrorFormatterTests` |
| **Parser** | 8 | `ParserTests` `ParserBodyRecoveryTests` `ParserErrorCollectionTests` `ParserRestructureTests` `ParseProjectionTests` `FrontendMultiErrorTests` `GrammarConsistencyTests` `DisambiguationTests` |
| **Match** | 7 | `MatchErrorTests` `MatchNewSyntaxTests` `MatchScalarPatternTests` `MatchWildcardTests` `ValidatedMatchTests` `AmbiguousCaseResolutionTests` `EnumNamespaceTests` |
| **TraitMember** | 7 | `TraitConstraintTests` `TraitDefaultTests` `MethodSelfModifierTests` `MemberMethodCallTests` `SelfCallInferenceTests` `BuiltinOverrideTests` `BuiltinMemberValidationTests` |
| **ValueTypes** | 7 | `StructTests` `FieldVisibilityTests` `CollectionsTests` `OptionalTests` `FloatValueTests` `ResultUnwrapTests` `ASTTests` |
| **Lexer** | 6 | `LexerTests` `LexerCrosslineTests` `LexicalTests` `IndentTrackerTests` `BacktickEscapeTests` `SymbolDisambiguationTests` |
| **Type** | 6 | `TypeCheckerTests` `TypeCheckerMultiErrorTests` `TypeComparisonTests` `TypeSubstitutorTests` `ReturnTypeConsistencyTests` `SemanticRedeclarationTests` |
| **Generic** | 6 | `GenericArityTests` `GenericConstraintTests` `GenericEnumTests` `GenericFunctionTests` `GenericRuntimeTests` `GenericTypeTests` |
| **TupleCall** | 5 | `TupleDestructureTests` `TupleIndexTests` `TupleNamedTests` `CallSiteTupleTests` `CallSiteValidationTests` |
| **Gates** | 4 | `ExamplesRunTests` `ExamplesConformanceTests` `BootstrapLanguageContractTests` `IntegrationTests` |
| **CodeGen** | 3 | `IRGeneratorTests` `IRExecutionTests` `IRPrintGoldenTests` *(already grouped)* |
| **FFI** | 2 | `FFITests` `FFIModuleTests` |
| **IO** | 1 | `IOTests` |

**Total 110.**

## 3. Judgement calls the reader should challenge

These placements are arguable; each is a reason to review rather than rubber-stamp.

- `GrammarConsistencyTests` → Parser (it cross-checks lexer *and* parser productions).
- `DisambiguationTests` → Parser (name is pass-neutral; screens as Lexer+Parser only).
- `BuiltinFunctionTests` → Runtime (could equally be ValueTypes or its own group; it is
  the second-largest fixture owner at 29 `.pini`).
- `CPSDifferentialTests` → Concurrency (it is a differential harness, not a feature test).
- `IntegrationTests` / `Gates` → a bucket defined by *purpose*, not subject — the one
  place this taxonomy admits a non-subject criterion.
- `Tooling` mixes LSP, Debugger, REPL and diagnostics; it is "everything that is not the
  language proper". Arguably 2–3 groups.

## 4. Cost if approved

- 107 directory moves (`CodeGen/` already grouped).
- ~11 documentation path references to sync: `issue-module-batch1` (3), `evidence-table.toml`
  `code_ref` (~7), `issue-ffi-module` (1, already dangling — fixed this round).
- **Low technical risk**: SwiftPM discovers `Tests/PiniTests` recursively, fixtures resolve
  via `#filePath` (path-independent), and CI runs only `swift test --disable-sandbox` with
  no path hard-coding.

## 5. The alternative: keep it flat

Flat has one real advantage: `ls` lists all 108 alphabetically, and you never have to guess
which group a test was filed under. The argument for grouping is that at 110 classes the
alphabetical listing no longer conveys relationships.

**Not a partition is the strongest argument against moving at all** — §3 lists six placements
that a reasonable reviewer could place differently.

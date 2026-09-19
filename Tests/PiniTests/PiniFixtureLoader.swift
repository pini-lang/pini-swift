import Foundation

/// Loads a Pini fixture that belongs to the suite in `<TestFileName>/`:
///   <TestFileName>/Fixtures/<name>.pini
///
/// `filePath` must be passed explicitly as `#filePath` from the CALL SITE --
/// a default value would evaluate at this definition, pointing at this file.
///
/// Why a `Fixtures/` level rather than sitting beside the suite: SwiftPM calls
/// every non-source file inside a target "unhandled" until it is declared as a
/// resource or excluded, and `exclude` matches by path only -- there is no way
/// to exclude by extension. Giving the fixtures a directory of their own is
/// what lets the manifest clear the whole set with a single line. Measured
/// 2026-09-19: pointing `resources:` at a suite directory instead makes SwiftPM
/// stop compiling the `.swift` inside it, which silently drops the whole suite
/// (the build still exits 0 and the warning still disappears).
///
/// The inlined-source form is being retired: Pini sources embedded in Swift
/// multiline strings are shaped by Swift's indentation and escaping rules
/// rather than by Pini's, which is a recurring source of false failures
func loadPiniFixture(_ name: String, filePath: String) throws -> String {
    let url = URL(fileURLWithPath: filePath)
    let dir = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    // `name` may already carry the .pini suffix
    let file = name.hasSuffix(".pini") ? name : name + ".pini"
    // when the test file itself lives inside its same-named directory, the
    // fixtures sit in its Fixtures/ subdirectory; otherwise they sit in <base>/
    // next to it. No fallback to the sibling layout: a missing fixture should
    // read as a missing fixture, not as some later, unrelated failure.
    let fixtureDir =
        dir.lastPathComponent == base
        ? dir.appendingPathComponent("Fixtures")
        : dir.appendingPathComponent(base)
    return try String(
        contentsOf: fixtureDir.appendingPathComponent(file),
        encoding: .utf8)
}

import Foundation

/// Reads `<TestFileName>/Fixtures/<name>.pini`. `filePath` must come from the CALL SITE as `#filePath`, not a default.
/// The `Fixtures/` level lets one path-only `exclude` line clear the set; `resources:` on a suite dir drops its `.swift`.
/// Inlined Pini sources take Swift's escaping, not Pini's — a recurring source of false failures; fixtures stay files.
func loadPiniFixture(_ name: String, filePath: String) throws -> String {
    let url = URL(fileURLWithPath: filePath)
    let dir = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    // `name` may already carry the .pini suffix
    let file = name.hasSuffix(".pini") ? name : name + ".pini"
    /// When the test file sits inside its same-named directory, fixtures live in its `Fixtures/` subdirectory;
    /// otherwise in `<base>/` beside it. No fallback to the sibling layout: a missing fixture must read as a
    /// missing fixture, not as some later, unrelated failure.
    let fixtureDir =
        dir.lastPathComponent == base
        ? dir.appendingPathComponent("Fixtures")
        : dir.appendingPathComponent(base)
    return try String(
        contentsOf: fixtureDir.appendingPathComponent(file),
        encoding: .utf8)
}
